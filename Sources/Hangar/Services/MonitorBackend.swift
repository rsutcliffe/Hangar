import Foundation

struct BackendSnapshot: Sendable {
    var runners: [RunnerObservation]
    var queue: [QueuedJob]
    var warnings: [String] = []
    /// Labels of hosts that could not be reached this poll.
    var unreachable: [String] = []
    var tokenExpiry: Date? = nil
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
    private let hosts = HostService()
    private let lock = NSLock()
    private var located: [String: Place] = [:]          // runner name -> where it lives
    private var labels: [String: String] = [:]          // host target -> label from the last successful probe

    struct Place: Sendable { var host: HostSpec; var profile: String?; var dir: String }

    /// One VM or one native host, probed.
    struct Machine: Sendable {
        var label: String
        var info: VMInfo?
        var snap: VMSnapshot
        var native: Bool
        var host: HostSpec
        var profile: String?
    }

    func poll(config: Config) async throws -> BackendSnapshot {
        guard config.isConfigured else { throw BackendError.notConfigured }
        guard let token = Keychain.token() else { throw GitHubError.noToken }
        let hosts = self.hosts

        // Probe every host concurrently; an unreachable host is a warning, not a failure.
        var machines: [Machine] = []
        var warnings: [String] = []
        var unreachable: [String] = []
        await withTaskGroup(of: ([Machine], String?, String?).self) { group in
            for h in config.hosts.map(HostSpec.init) {
                group.addTask {
                    var out: [Machine] = []
                    var hostname = ""
                    var reached = false
                    var why = ""
                    func note(_ e: Error) {
                        if case ShellError.failed(_, let m) = e { why = m.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "" }
                        else if case ShellError.timedOut = e { why = "timed out" }
                        else if case ShellError.notFound(let p) = e { why = "\(p) not found" }
                    }
                    var vmsOrNil: [String: VMInfo]?
                    do { vmsOrNil = try await hosts.listVMs(h) } catch { note(error) }
                    if let vms = vmsOrNil {
                        reached = true
                        for p in config.profiles where vms[p]?.running == true {
                            if let snap = try? await hosts.vmSnapshot(h, profile: p) {
                                hostname = snap.hostname
                                out.append(Machine(label: "", info: vms[p], snap: snap, native: false, host: h, profile: p))
                            }
                        }
                    }
                    var nativeOrNil: VMSnapshot?
                    do { nativeOrNil = try await hosts.nativeSnapshot(h) } catch { if !reached { note(error) } }
                    if let snap = nativeOrNil {
                        reached = true; hostname = snap.hostname
                        out.append(Machine(label: "", info: nil, snap: snap, native: true, host: h, profile: nil))
                    }
                    let label = h.isLocal ? "this Mac" : SnapshotParser.shortName(hostname.isEmpty ? (h.target ?? "") : hostname)
                    out = out.map { var m = $0; m.label = label; return m }
                    if reached, let t = h.target { self.lock.withLock { self.labels[t] = label } }
                    let down = reached ? nil : (h.target.flatMap { t in self.lock.withLock { self.labels[t] } } ?? h.target ?? "this Mac")
                    return (out, reached ? nil : "\(h.target ?? "This Mac") unreachable" + (why.isEmpty ? "" : " (\(why))"), down)
                }
            }
            for await (m, w, down) in group { machines += m; if let w { warnings.append(w) }; if let down { unreachable.append(down) } }
        }

        var map: [String: Place] = [:]
        for m in machines { for r in m.snap.runners { map[r.name] = Place(host: m.host, profile: m.profile, dir: r.dir) } }
        lock.withLock { located = map }

        let repos = Set(machines.flatMap { $0.snap.runners }.map { RepoRef(owner: $0.owner, repo: $0.repo) })
        let github = self.github
        let (runners, jobs) = try await withThrowingTaskGroup(of: ([GHRunner], [GHJob]).self) { group in
            for r in repos {
                group.addTask {
                    async let rs = github.runners(owner: r.owner, repo: r.repo, token: token)
                    async let js = github.jobs(owner: r.owner, repo: r.repo, token: token)
                    let (runners, jobs) = try await (rs, js)
                    return (runners.map { var x = $0; x.repo = r.repo; return x }, jobs)
                }
            }
            var allR: [GHRunner] = [], allJ: [GHJob] = []
            for try await (rs, js) in group { allR += rs; allJ += js }
            return (allR, allJ)
        }
        var snap = Self.assemble(machines: machines, runners: runners, jobs: jobs, now: Date())
        snap.warnings = warnings.sorted()
        snap.unreachable = unreachable.sorted()
        snap.tokenExpiry = await github.tokenExpiry()
        return snap
    }

    private func place(_ id: String) throws -> Place {
        guard let p = lock.withLock({ located[id] }) else { throw ShellError.failed(2, "Runner \(id) not found on any host") }
        return p
    }

    func restart(_ id: String, config: Config) async throws {
        let p = try place(id)
        try await hosts.restartRunner(p.host, profile: p.profile, dir: p.dir)
    }

    func setRunnerService(_ id: String, running: Bool, config: Config) async throws {
        let p = try place(id)
        try await hosts.setService(p.host, profile: p.profile, dir: p.dir, running: running)
    }

    struct RepoRef: Hashable, Sendable { var owner: String; var repo: String }

    /// Pure join of the sources; unit-tested.
    static func assemble(machines: [Machine], runners: [GHRunner], jobs: [GHJob], now: Date) -> BackendSnapshot {
        var obs: [RunnerObservation] = []
        for m in machines {
            for f in m.snap.runners {
                let gh = runners.first { $0.name == f.name }
                let mine = jobs.filter { gh != nil && $0.runnerName == f.name }
                var job: ActiveJob?
                if let j = mine.first(where: { $0.status == "in_progress" }) {
                    job = activeJob(j, lastOutput: f.lastOutputAt)
                } else if let j = mine.filter({ $0.conclusion == "failure" && now.timeIntervalSince($0.completedAt ?? .distantPast) < 600 })
                            .max(by: { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }) {
                    job = activeJob(j, lastOutput: j.completedAt)
                }
                obs.append(RunnerObservation(id: f.name, arch: m.info?.arch ?? .arm64,
                                             cpus: m.snap.cpus ?? m.info?.cpus ?? 0, memoryGB: m.snap.memTotalGB ?? m.info?.memoryGB ?? 0,
                                             vmRunning: true, ghOnline: gh?.online ?? false,
                                             listenerRunning: f.listenerRunning, busy: gh?.busy ?? false,
                                             host: m.label, native: m.native, standby: gh?.isStandby ?? false,
                                             job: job, cpuPercent: m.snap.cpuPercent, memUsedGB: m.snap.memUsedGB, lastJobEndedAt: nil,
                                             runnerCPU: f.runnerCPU, cpuSupported: f.cpuSeconds != nil))
            }
        }
        return BackendSnapshot(runners: obs, queue: queue(from: jobs, runners: runners))
    }

    static func activeJob(_ j: GHJob, lastOutput: Date?) -> ActiveJob {
        let failed = j.conclusion == "failure" ? j.steps.first { $0.conclusion == "failure" } : nil
        let failedStep = failed?.number
        let current = j.steps.first { $0.status == "in_progress" }?.number
            ?? (j.steps.filter { $0.status == "completed" }.count + 1)
        let started = j.startedAt ?? j.createdAt
        return ActiveJob(id: j.id, repo: j.repo, workflow: j.workflow, runNumber: j.runNumber, branch: j.branch,
                         totalSteps: j.steps.count, currentStep: min(current, max(j.steps.count, 1)),
                         startedAt: started, lastOutputAt: lastOutput ?? started,
                         failedStep: j.conclusion == "failure" ? (failedStep ?? current) : nil, exitCode: nil,
                         failedStepName: failed.flatMap { $0.name.isEmpty ? nil : $0.name }, url: GitHubLink.safe(j.htmlURL))
    }

    static func queue(from jobs: [GHJob], runners: [GHRunner]? = nil) -> [QueuedJob] {
        var seen = Set<Int>()
        return jobs.filter { $0.status == "queued" && $0.labels.contains("self-hosted") && seen.insert($0.id).inserted }
            .sorted { $0.createdAt < $1.createdAt }
            .map { j in
                let l = j.labels.map { $0.lowercased() }
                let arch: Arch = l.contains(where: { $0.contains("x64") || $0.contains("x86") }) ? .x86 : .arm64
                var q = QueuedJob(id: j.id, repo: j.repo, workflow: j.workflow, branch: j.branch,
                                  runNumber: j.runNumber, arch: arch, queuedAt: j.createdAt, job: j.name, labels: j.labels)
                q.url = GitHubLink.safe(j.htmlURL)
                if let runners {
                    q.eligible = QueueAnalysis.eligible(labels: j.labels, repo: j.repo, runners: runners)
                    if q.eligible?.isEmpty == true { q.missingLabels = QueueAnalysis.missingLabels(labels: j.labels, repo: j.repo, runners: runners) }
                }
                return q
            }
    }
}
