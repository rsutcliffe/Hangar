import Foundation

struct BackendSnapshot: Sendable {
    var runners: [RunnerObservation]
    var queue: [QueuedJob]
}

/// Source of raw facts and the place side effects happen. Live = GitHub + Colima, Demo = scripted.
protocol MonitorBackend: Sendable {
    func poll(config: Config) async throws -> BackendSnapshot
    func restart(_ id: String, config: Config) async throws
    func setRunnerService(_ id: String, running: Bool, config: Config) async throws
}

enum BackendError: Error, LocalizedError {
    case notConfigured
    var errorDescription: String? { "Open Settings (⌘,) to add your org, repos and Colima profiles" }
}

final class LiveBackend: MonitorBackend, @unchecked Sendable {
    private let github = GitHubService()
    private let colima = ColimaService()
    private let lock = NSLock()
    private var located: [String: (profile: String, dir: String)] = [:]    // runner name -> where it lives

    func poll(config: Config) async throws -> BackendSnapshot {
        guard config.isConfigured else { throw BackendError.notConfigured }
        guard let token = Keychain.read() else { throw GitHubError.noToken }
        let vms = try await colima.list()

        var snaps: [String: VMSnapshot] = [:]
        for p in config.profiles where vms[p]?.running == true { snaps[p] = try? await colima.snapshot(profile: p) }
        var map: [String: (profile: String, dir: String)] = [:]
        for (p, s) in snaps { for r in s.runners { map[r.name] = (p, r.dir) } }
        lock.withLock { located = map }

        let repos = Set(snaps.values.flatMap { $0.runners }.map { RepoRef(owner: $0.owner, repo: $0.repo) })
        let github = self.github
        let (runners, jobs) = try await withThrowingTaskGroup(of: ([GHRunner], [GHJob]).self) { group in
            for r in repos {
                group.addTask {
                    async let rs = github.runners(owner: r.owner, repo: r.repo, token: token)
                    async let js = github.jobs(owner: r.owner, repo: r.repo, token: token)
                    return try await (rs, js)
                }
            }
            var allR: [GHRunner] = [], allJ: [GHJob] = []
            for try await (rs, js) in group { allR += rs; allJ += js }
            return (allR, allJ)
        }
        return Self.assemble(config: config, vms: vms, snaps: snaps, runners: runners, jobs: jobs, now: Date())
    }

    private func place(_ id: String) throws -> (profile: String, dir: String) {
        guard let p = lock.withLock({ located[id] }) else { throw ShellError.failed(2, "Runner \(id) not found in VM") }
        return p
    }

    func restart(_ id: String, config: Config) async throws {
        let p = try place(id)
        try await colima.restartRunner(profile: p.profile, dir: p.dir)
    }

    func setRunnerService(_ id: String, running: Bool, config: Config) async throws {
        let p = try place(id)
        try await colima.setRunnerService(profile: p.profile, dir: p.dir, running: running)
    }

    struct RepoRef: Hashable, Sendable { var owner: String; var repo: String }

    /// Pure join of the three sources; unit-tested.
    static func assemble(config: Config, vms: [String: VMInfo], snaps: [String: VMSnapshot],
                         runners: [GHRunner], jobs: [GHJob], now: Date) -> BackendSnapshot {
        var obs: [RunnerObservation] = []
        for profile in config.profiles {
            guard let snap = snaps[profile] else { continue }
            let vm = vms[profile]
            for f in snap.runners {
                let gh = runners.first { $0.name == f.name }
                let mine = jobs.filter { gh != nil && $0.runnerName == f.name }
                var job: ActiveJob?
                if let j = mine.first(where: { $0.status == "in_progress" }) {
                    job = activeJob(j, lastOutput: f.lastOutputAt)
                } else if let j = mine.filter({ $0.conclusion == "failure" && now.timeIntervalSince($0.completedAt ?? .distantPast) < 600 })
                            .max(by: { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }) {
                    job = activeJob(j, lastOutput: j.completedAt)
                }
                obs.append(RunnerObservation(id: f.name, arch: vm?.arch ?? .arm64, cpus: vm?.cpus ?? 0, memoryGB: vm?.memoryGB ?? 0,
                                             vmRunning: vm?.running ?? false, ghOnline: gh?.online ?? false,
                                             listenerRunning: f.listenerRunning, busy: gh?.busy ?? false,
                                             job: job, cpuPercent: snap.cpuPercent, memUsedGB: snap.memUsedGB, lastJobEndedAt: nil))
            }
        }
        return BackendSnapshot(runners: obs, queue: queue(from: jobs))
    }

    static func activeJob(_ j: GHJob, lastOutput: Date?) -> ActiveJob {
        let failedStep = j.conclusion == "failure" ? j.steps.first { $0.conclusion == "failure" }?.number : nil
        let current = j.steps.first { $0.status == "in_progress" }?.number
            ?? (j.steps.filter { $0.status == "completed" }.count + 1)
        let started = j.startedAt ?? j.createdAt
        return ActiveJob(id: j.id, repo: j.repo, workflow: j.workflow, runNumber: j.runNumber, branch: j.branch,
                         totalSteps: j.steps.count, currentStep: min(current, max(j.steps.count, 1)),
                         startedAt: started, lastOutputAt: lastOutput ?? started,
                         failedStep: j.conclusion == "failure" ? (failedStep ?? current) : nil, exitCode: nil)
    }

    static func queue(from jobs: [GHJob]) -> [QueuedJob] {
        var seen = Set<Int>()
        return jobs.filter { $0.status == "queued" && $0.labels.contains("self-hosted") && seen.insert($0.id).inserted }
            .sorted { $0.createdAt < $1.createdAt }
            .map { j in
                let l = j.labels.map { $0.lowercased() }
                let arch: Arch = l.contains(where: { $0.contains("x64") || $0.contains("x86") }) ? .x86 : .arm64
                return QueuedJob(id: j.id, repo: j.repo, workflow: j.workflow, branch: j.branch,
                                 runNumber: j.runNumber, arch: arch, queuedAt: j.createdAt)
            }
    }
}
