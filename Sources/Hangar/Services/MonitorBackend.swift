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

struct LiveBackend: MonitorBackend {
    let github = GitHubService()
    let colima = ColimaService()

    func poll(config: Config) async throws -> BackendSnapshot {
        guard config.isConfigured else { throw BackendError.notConfigured }
        guard let token = Keychain.read() else { throw GitHubError.noToken }
        let vms = try await colima.list()

        async let ghRunners = github.runners(owner: config.owner, repos: config.repos, token: token)
        async let ghJobs = withThrowingTaskGroup(of: [GHJob].self) { group in
            for r in config.repos { group.addTask { try await github.jobs(owner: config.owner, repo: r, token: token) } }
            var all: [GHJob] = []
            for try await jobs in group { all += jobs }
            return all
        }
        var samples: [String: VMSample] = [:]
        for p in config.profiles where vms[p]?.running == true {
            samples[p] = try? await colima.sample(profile: p, runnerDir: config.runnerDir)
        }
        let (runners, jobs) = try await (ghRunners, ghJobs)
        return Self.assemble(config: config, vms: vms, samples: samples, runners: runners, jobs: jobs, now: Date())
    }

    func restart(_ id: String, config: Config) async throws {
        try await colima.restart(profile: id)
        try await colima.setRunnerService(profile: id, runnerDir: config.runnerDir, running: true)
    }

    func setRunnerService(_ id: String, running: Bool, config: Config) async throws {
        try await colima.setRunnerService(profile: id, runnerDir: config.runnerDir, running: running)
    }

    /// Pure join of the three sources; unit-tested.
    static func assemble(config: Config, vms: [String: VMInfo], samples: [String: VMSample],
                         runners: [GHRunner], jobs: [GHJob], now: Date) -> BackendSnapshot {
        let obs = config.profiles.map { p -> RunnerObservation in
            let vm = vms[p]
            let gh = runners.first { $0.name.contains(p) }
            let mine = jobs.filter { gh != nil && $0.runnerName == gh?.name }
            var job: ActiveJob?
            if let j = mine.first(where: { $0.status == "in_progress" }) {
                job = activeJob(j, lastOutput: samples[p]?.lastOutputAt)
            } else if let j = mine.filter({ $0.conclusion == "failure" && now.timeIntervalSince($0.completedAt ?? .distantPast) < 600 })
                        .max(by: { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }) {
                job = activeJob(j, lastOutput: j.completedAt)
            }
            return RunnerObservation(id: p, arch: vm?.arch ?? .arm64, cpus: vm?.cpus ?? 0, memoryGB: vm?.memoryGB ?? 0,
                                     vmRunning: vm?.running ?? false, ghOnline: gh?.online ?? false, busy: gh?.busy ?? false,
                                     job: job, cpuPercent: samples[p]?.cpuPercent ?? 0, memUsedGB: samples[p]?.memUsedGB ?? 0,
                                     lastJobEndedAt: nil)
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
