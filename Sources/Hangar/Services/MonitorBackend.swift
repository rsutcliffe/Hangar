import Foundation

/// A job that failed on an on-demand runner. It has no card, so it is carried to the failure list and notifications apart.
struct OnDemandFailure: Sendable {
    var set: String
    var job: ActiveJob
    var failedAt: Date
}

/// What ties one of the orchestrator's failures to a job read from GitHub.
struct RunnerJobKey: Hashable, Sendable {
    var runId: Int
    var runner: String
}

struct BackendSnapshot: Sendable {
    var onDemandFailures: [OnDemandFailure] = []
    /// The first failed step's name, for each failed job read this poll that has one.
    var failedSteps: [RunnerJobKey: String] = [:]
    var runners: [RunnerObservation]
    var queue: [QueuedJob]
    /// Live runners the orchestrator started for single jobs; they have no folder on any host, so they come from GitHub's list.
    var onDemand: [OnDemandRunner] = []
    var warnings: [String] = []
    /// Labels of hosts that could not be reached this poll.
    var unreachable: [String] = []
    var tokenExpiry: Date? = nil
    /// The newest published Hangar release, when update checks are on.
    var latestApp: AppRelease? = nil
    /// A host failed in a way that points at the Local Network permission.
    var needsLocalNetwork = false
    /// Latest actions/runner release (e.g. "2.338.0"), if known.
    var latestRunner: String? = nil
    var latestRunnerPublished: Date? = nil
    /// The orchestrator's last good state since launch; nil when none has been read. It may be stale (`isStale`).
    var orchestrator: OrchestratorState? = nil
    /// The host that last supplied a state, remembered across launches. Set while `orchestrator` is nil means the
    /// orchestrator was seen before and has not reported since launch; nil means it has never been seen.
    var orchestratorSeenOn: String? = nil
    /// This poll read a state file of a version Hangar does not know.
    var orchestratorOtherVersion = false
}

/// Source of raw facts and the place side effects happen. Live = GitHub + Colima, Demo = scripted.
protocol MonitorBackend: Sendable {
    func poll(config: Config) async throws -> BackendSnapshot
    func restart(_ id: String, config: Config) async throws
    func setRunnerService(_ id: String, running: Bool, config: Config) async throws
    func diagnose(config: Config) async -> ConnectionReport
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
    private var permissionHint = false
    private var labels: [String: String] = [:]          // host target -> label from the last successful probe
    private var orchestrator = OrchestratorState.Held.remembered(in: .standard)      // the last good state and who supplied it

    struct Place: Sendable { var host: HostSpec; var profile: String?; var dir: String }

    /// One VM or one native host, probed.
    struct Machine: Sendable {
        var label: String
        var info: VMInfo?
        var snap: VMSnapshot
        var native: Bool
        var host: HostSpec
        var profile: String?
        var hostMemory: HostMemory? = nil
    }

    func poll(config: Config) async throws -> BackendSnapshot {
        guard config.isConfigured else { throw BackendError.notConfigured }
        guard let token = Keychain.token() else { throw GitHubError.noToken }
        let hosts = self.hosts

        // Probe every host concurrently; an unreachable host is a warning, not a failure.
        var machines: [Machine] = []
        var warnings: [String] = []
        var unreachable: [String] = []
        var hostOf: [String: String] = [:]                  // on-demand runner name -> the Mac whose orchestrator VM runs it
        var stateReads: [OrchestratorState.Read] = []
        self.lock.withLock { self.permissionHint = false }
        await withTaskGroup(of: ([Machine], String?, String?, [String: String], OrchestratorState.Read).self) { group in
            for h in config.hosts.map(HostSpec.init) {
                group.addTask {
                    // Read alongside the probe, so it lengthens the poll only when it is slower than the whole probe.
                    async let stateText = hosts.orchestratorState(h)
                    var out: [Machine] = []
                    var hostname = ""
                    var reached = false
                    var why = ""
                    var vmsOrNil: [String: VMInfo]?
                    do { vmsOrNil = try await hosts.listVMs(h) } catch { why = Self.reason(error, fallback: "") }
                    if let vms = vmsOrNil {
                        reached = true
                        for (p, snap) in await Self.vmSnapshots(hosts, h, vms: vms, profiles: config.profiles) {
                            hostname = snap.hostname
                            out.append(Machine(label: "", info: vms[p], snap: snap, native: false, host: h, profile: p))
                        }
                    }
                    var nativeOrNil: VMSnapshot?
                    do { nativeOrNil = try await hosts.nativeSnapshot(h) } catch { if !reached { why = Self.reason(error, fallback: "") } }
                    if let snap = nativeOrNil {
                        reached = true; hostname = snap.hostname
                        out.append(Machine(label: "", info: nil, snap: snap, native: true, host: h, profile: nil))
                    }
                    let probe = reached ? await hosts.hostProbe(h) : (memory: nil, name: nil)
                    let label = h.isLocal ? "this Mac" : SnapshotParser.shortName(probe.name ?? (hostname.isEmpty ? (h.target ?? "") : hostname))
                    let committed = (vmsOrNil ?? [:]).values.filter(\.running).reduce(0) { $0 + $1.memoryGB }
                    var hostMemory = probe.memory
                    hostMemory?.vmCommittedGB = committed
                    out = out.map { var m = $0; m.label = label; m.hostMemory = hostMemory; return m }
                    if reached, let t = h.target { self.lock.withLock { self.labels[t] = label } }
                    let reported = Self.reportedLabel(reached: reached, label: label, target: h.target,
                                                      cached: h.target.flatMap { t in self.lock.withLock { self.labels[t] } })
                    let down = reached ? nil : reported
                    var warning: String?
                    var perm = false
                    if !reached {
                        let p = LocalNetwork.explain(target: h.target ?? "This Mac", reason: why)
                        warning = p.message; perm = p.needsLocalNetwork
                    }
                    if perm { self.lock.withLock { self.permissionHint = true } }
                    // Only a running orchestrator VM can hold on-demand runners; skip the extra call otherwise.
                    // A Mac with a second Docker daemon has `orchestrator2` as well.
                    var here: [String: String] = [:]
                    for p in SnapshotParser.orchestratorProfiles(in: vmsOrNil ?? [:]) {
                        for n in await hosts.onDemandNames(h, profile: p) { here[n] = label }
                    }
                    return (out, warning, down, here, OrchestratorState.Read(target: h.target ?? "local", host: reported, text: await stateText))
                }
            }
            for await (m, w, down, here, state) in group {
                machines += m; if let w { warnings.append(w) }; if let down { unreachable.append(down) }
                hostOf.merge(here) { a, _ in a }
                stateReads.append(state)
            }
        }
        // Kept before the GitHub calls, so a poll they fail does not lose what was read.
        let orchestrator = lock.withLock {
            self.orchestrator = self.orchestrator.updated(with: stateReads, hosts: config.hosts, now: Date())
            self.orchestrator.remember(in: .standard)
            return self.orchestrator
        }

        // Repos seen before still count when their runner VM is stopped (see RepoMemory).
        let found = Set(machines.flatMap { $0.snap.runners }.map { RepoRef(owner: $0.owner, repo: $0.repo) })
        let repos = RepoMemory.merge(found: found, remembered: (UserDefaults.standard.stringArray(forKey: RepoMemory.key) ?? []) + RepoMemory.lines(UserDefaults.standard.string(forKey: Config.Key.repos) ?? ""))
        UserDefaults.standard.set(RepoMemory.encode(repos), forKey: RepoMemory.key)
        machines = machines.map { m in
            var m = m
            m.snap.runners = m.snap.runners.map { f in
                var f = f
                let ref = RepoMemory.spelled(RepoRef(owner: f.owner, repo: f.repo), in: repos)
                f.owner = ref.owner; f.repo = ref.repo
                return f
            }
            return m
        }

        var map: [String: Place] = [:]
        let dup = Self.duplicateNames(machines)
        for m in machines { for r in m.snap.runners { map[Self.runnerID(r, duplicates: dup)] = Place(host: m.host, profile: m.profile, dir: r.dir) } }
        lock.withLock { located = map }

        let github = self.github
        // One repo the token cannot see is a warning for that repo; it must not stop every other card updating.
        let (runners, jobs, repoWarnings) = try await withThrowingTaskGroup(of: ([GHRunner], [GHJob], String?).self) { group in
            for r in repos {
                group.addTask {
                    do {
                        async let rs = github.runners(owner: r.owner, repo: r.repo, token: token)
                        async let js = github.jobs(owner: r.owner, repo: r.repo, token: token)
                        let (runners, jobs) = try await (rs, js)
                        return (runners.map { var x = $0; x.repo = r.repo; return x }, jobs, nil)
                    } catch {
                        guard let w = Self.repoWarning(repo: r.repo, error: error) else { throw error }
                        return ([], [], w)
                    }
                }
            }
            var allR: [GHRunner] = [], allJ: [GHJob] = [], allW: [String] = []
            for try await (rs, js, w) in group { allR += rs; allJ += js; if let w { allW.append(w) } }
            return (allR, allJ, allW)
        }
        var snap = Self.assemble(machines: machines, runners: runners, jobs: jobs, now: Date(), hostOf: hostOf)
        snap.orchestrator = orchestrator.state
        snap.orchestratorSeenOn = orchestrator.host
        snap.orchestratorOtherVersion = orchestrator.otherVersion
        snap.warnings = (warnings + repoWarnings).sorted()
        snap.unreachable = unreachable.sorted()
        snap.tokenExpiry = await github.tokenExpiry()
        let rel = await github.latestRunnerRelease()
        snap.latestRunner = rel?.version; snap.latestRunnerPublished = rel?.published
        snap.needsLocalNetwork = lock.withLock { permissionHint }
        if config.checkUpdates { snap.latestApp = await github.latestAppRelease() }
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

    /// Settings > Test connection. Reads only; the report never contains the token.
    func diagnose(config: Config) async -> ConnectionReport {
        var report = ConnectionReport()
        var repos = Set<RepoRef>()
        for h in config.hosts.map(HostSpec.init) {
            let label = h.isLocal ? "this Mac" : (h.target ?? "host")
            var count = 0
            var failure: String?
            do {
                let vms = try await hosts.listVMs(h)
                for (_, s) in await Self.vmSnapshots(hosts, h, vms: vms, profiles: config.profiles) {
                    count += s.runners.count; s.runners.forEach { repos.insert(RepoRef(owner: $0.owner, repo: $0.repo)) }
                }
            } catch { failure = Self.reason(error) }
            if let s = try? await hosts.nativeSnapshot(h) { failure = nil; count += s.runners.count; s.runners.forEach { repos.insert(RepoRef(owner: $0.owner, repo: $0.repo)) } }
            report.lines.append(ConnectionReport.host(label, error: count == 0 ? failure : nil, runners: count))
        }
        guard let token = Keychain.token() else { report.lines.append(ConnectionReport.noToken); return report }
        for r in RepoMemory.merge(found: repos, remembered: []).sorted(by: { $0.repo < $1.repo }) {
            do { _ = try await github.runners(owner: r.owner, repo: r.repo, token: token); report.lines.append(ConnectionReport.repo(r.repo, error: nil)) }
            catch { report.lines.append(ConnectionReport.repo(r.repo, error: error)) }
        }
        if repos.isEmpty { report.lines.append(.init(ok: false, text: "No repos discovered, so the token could not be checked.")) }
        return report
    }

    /// The name a host goes by this poll. One that was not reached keeps its name from the last successful probe, else its
    /// configured entry.
    static func reportedLabel(reached: Bool, label: String, target: String?, cached: String?) -> String {
        reached ? label : cached ?? target ?? "this Mac"
    }

    private static func reason(_ e: Error, fallback: String = "failed") -> String {
        if case ShellError.failed(_, let m) = e { return m.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? fallback }
        if case ShellError.timedOut = e { return "timed out" }
        if case ShellError.notFound(let p) = e { return "\(p) not found" }
        return fallback
    }

    /// The configured profiles that are running, each probed; a VM that does not answer is left out.
    private static func vmSnapshots(_ hosts: HostService, _ h: HostSpec, vms: [String: VMInfo], profiles: [String]) async -> [(profile: String, snap: VMSnapshot)] {
        var out: [(profile: String, snap: VMSnapshot)] = []
        for p in profiles where vms[p]?.running == true {
            if let s = try? await hosts.vmSnapshot(h, profile: p) { out.append((p, s)) }
        }
        return out
    }

    /// Names that two repos' runners share. Such a runner is shown, and found for Restart, with its repo after the name.
    static func duplicateNames(_ machines: [Machine]) -> Set<String> {
        let all = machines.flatMap { $0.snap.runners }
        return Set(Dictionary(grouping: all, by: \.name).filter { Set($0.value.map(\.repo)).count > 1 }.keys)
    }

    static func runnerID(_ f: RunnerFacts, duplicates: Set<String>) -> String {
        duplicates.contains(f.name) ? "\(f.name) (\(f.repo))" : f.name
    }

    struct RepoRef: Hashable, Sendable { var owner: String; var repo: String }

    /// A warning for a repo the token cannot read (403 or 404); nil for any other error, which still fails the poll
    /// (a bad token, a rate limit or a network failure affects every repo).
    static func repoWarning(repo: String, error: Error) -> String? {
        guard case GitHubError.http(let code) = error, code == 403 || code == 404 else { return nil }
        return "\(repo): the token cannot read this repo (it needs Actions and Administration: read)"
    }

    /// Pure join of the sources; unit-tested.
    static func assemble(machines: [Machine], runners: [GHRunner], jobs: [GHJob], now: Date, hostOf: [String: String] = [:]) -> BackendSnapshot {
        var obs: [RunnerObservation] = []
        let dup = duplicateNames(machines)
        for m in machines {
            for f in m.snap.runners {
                let gh = runners.first { $0.name == f.name && $0.repo == f.repo }
                let mine = jobs.filter { gh != nil && $0.runnerName == f.name && $0.repo == f.repo }
                var job: ActiveJob?
                if let j = mine.first(where: { $0.status == "in_progress" }) {
                    job = activeJob(j, lastOutput: f.lastOutputAt)
                } else if let j = mine.filter({ $0.conclusion == "failure" && now.timeIntervalSince($0.completedAt ?? .distantPast) < 600 })
                            .max(by: { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }) {
                    job = activeJob(j, lastOutput: j.completedAt)
                }
                obs.append(RunnerObservation(id: runnerID(f, duplicates: dup), arch: m.info?.arch ?? .arm64,
                                             cpus: m.snap.cpus ?? m.info?.cpus ?? 0, memoryGB: m.snap.memTotalGB ?? m.info?.memoryGB ?? 0,
                                             vmRunning: true, ghOnline: gh?.online ?? false,
                                             listenerRunning: f.listenerRunning, busy: gh?.busy ?? false,
                                             host: m.label, native: m.native, standby: gh?.isStandby ?? false,
                                             job: job, cpuPercent: m.snap.cpuPercent, memUsedGB: m.snap.memUsedGB,
                                             // Idle: the newest worker log was last written when the last job ended, even a job shorter than a poll.
                                             lastJobEndedAt: job == nil ? f.lastOutputAt : nil,
                                             runnerCPU: f.runnerCPU, cpuSupported: f.cpuSeconds != nil,
                                             diskFreeKB: f.diskFreeKB, diskUsedPct: f.diskUsedPct, version: f.version, hostMemory: m.hostMemory,
                                             succeededKeys: succeededKeys(mine)))
            }
        }
        var snap = BackendSnapshot(runners: obs, queue: queue(from: jobs, runners: runners))
        snap.onDemandFailures = onDemandFailures(jobs: jobs, now: now)
        snap.failedSteps = failedSteps(jobs: jobs)
        snap.onDemand = onDemandRunners(runners: runners, jobs: jobs, known: Set(machines.flatMap { $0.snap.runners }.map { "\($0.repo)/\($0.name)" }), hostOf: hostOf)
        return snap
    }

    /// Online runners with an orchestrator name that no host folder explains. GitHub keeps dead ephemeral runners listed for a
    /// while, so offline ones are left out.
    static func onDemandRunners(runners: [GHRunner], jobs: [GHJob], known: Set<String>, hostOf: [String: String] = [:]) -> [OnDemandRunner] {
        runners.compactMap { r -> OnDemandRunner? in
            guard r.online, !known.contains("\(r.repo)/\(r.name)"), let set = OnDemandRunner.setName(of: r.name) else { return nil }
            let mine = jobs.first { $0.status == "in_progress" && $0.runnerName == r.name && $0.repo == r.repo }
            return OnDemandRunner(name: r.name, repo: r.repo, set: set, busy: r.busy, job: mine.map { activeJob($0, lastOutput: nil) }, host: hostOf[r.name])
        }.sorted { $0.name < $1.name }
    }

    /// Jobs that failed in the last 10 minutes on an on-demand runner, oldest first. They come from the jobs already read, and
    /// no more are asked for, so some are never seen: only runs still going, or that ended as failed in the same window, have
    /// their jobs read. Missed: a run that ended cancelled or successful before a poll saw the failed job; a long run that has
    /// left the newest 20 and ends between two polls; and jobs past the first 100 of a run.
    static func onDemandFailures(jobs: [GHJob], now: Date) -> [OnDemandFailure] {
        var seen = Set<Int>()
        return jobs.compactMap { j -> OnDemandFailure? in
            guard j.conclusion == "failure", QueueAnalysis.isOnDemand(labels: j.labels), let done = j.completedAt,
                  now.timeIntervalSince(done) < 600, let set = j.runnerName.flatMap(OnDemandRunner.setName(of:)),
                  seen.insert(j.id).inserted else { return nil }
            return OnDemandFailure(set: set, job: activeJob(j, lastOutput: done), failedAt: done)
        }.sorted { $0.failedAt < $1.failedAt }
    }

    static func failedSteps(jobs: [GHJob]) -> [RunnerJobKey: String] {
        var out: [RunnerJobKey: String] = [:]
        for j in jobs where j.conclusion == "failure" {
            guard let runner = j.runnerName, !runner.isEmpty,
                  let step = j.steps.first(where: { $0.conclusion == "failure" })?.name, !step.isEmpty else { continue }
            out[RunnerJobKey(runId: j.runId, runner: runner)] = step
        }
        return out
    }

    /// The keys of jobs whose newest completed run on this runner succeeded. Only the newest counts: a success older than a failure
    /// must not end that failure's streak.
    static func succeededKeys(_ jobs: [GHJob]) -> [String] {
        let done = jobs.filter { $0.completedAt != nil && $0.conclusion != nil }
        let newest = Dictionary(grouping: done) { JobHistory.key(repo: $0.repo, workflow: $0.workflow, job: $0.name) }
            .compactMapValues { $0.max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) } }
        return newest.filter { $0.value.conclusion == "success" }.keys.sorted()
    }

    static func activeJob(_ j: GHJob, lastOutput: Date?) -> ActiveJob {
        let failed = j.conclusion == "failure" ? j.steps.first { $0.conclusion == "failure" } : nil
        let failedStep = failed?.number
        let current = j.steps.first { $0.status == "in_progress" }?.number
            ?? (j.steps.filter { $0.status == "completed" }.count + 1)
        let started = j.startedAt ?? j.createdAt
        return ActiveJob(id: j.id, repo: j.repo, workflow: j.workflow, runNumber: j.runNumber, branch: j.branch,
                         totalSteps: j.steps.count, currentStep: min(current, max(j.steps.count, 1)),
                         startedAt: started, lastOutputAt: max(lastOutput ?? started, started),     // a log older than the job is the previous job's
                         failedStep: j.conclusion == "failure" ? (failedStep ?? current) : nil, exitCode: nil,
                         failedStepName: failed.flatMap { $0.name.isEmpty ? nil : $0.name }, url: GitHubLink.safe(j.htmlURL), jobName: j.name)
    }

    static func queue(from jobs: [GHJob], runners: [GHRunner]? = nil) -> [QueuedJob] {
        var seen = Set<Int>()
        return jobs.filter { $0.status == "queued" && ($0.labels.contains("self-hosted") || QueueAnalysis.isOnDemand(labels: $0.labels)) && seen.insert($0.id).inserted }
            .sorted { $0.createdAt < $1.createdAt }
            .map { j in
                let l = j.labels.map { $0.lowercased() }
                let arch: Arch = l.contains(where: { $0.contains("x64") || $0.contains("x86") }) ? .x86 : .arm64
                var q = QueuedJob(id: j.id, repo: j.repo, workflow: j.workflow, branch: j.branch,
                                  runNumber: j.runNumber, arch: arch, queuedAt: j.createdAt, job: j.name, labels: j.labels)
                q.url = GitHubLink.safe(j.htmlURL)
                q.onDemand = QueueAnalysis.isOnDemand(labels: j.labels)
                if !q.onDemand, let runners {
                    q.eligible = QueueAnalysis.eligible(labels: j.labels, repo: j.repo, runners: runners)
                    if q.eligible?.isEmpty == true { q.missingLabels = QueueAnalysis.missingLabels(labels: j.labels, repo: j.repo, runners: runners) }
                }
                return q
            }
    }
}
