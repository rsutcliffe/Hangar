import Foundation

/// Scripted data mirroring the prototype so the UI can be checked with no token or VMs.
/// Enabled with the `--demo` launch argument.
final class DemoBackend: MonitorBackend, @unchecked Sendable {
    enum Scenario: String { case stalled, failed, unreachable, offline, permission, pressure }
    let scenario: Scenario
    private let lock = NSLock()
    private var restarted: [String: Date] = [:]
    private let t0 = Date()

    init(scenario: Scenario) { self.scenario = scenario }

    func poll(config: Config) async throws -> BackendSnapshot {
        let now = Date()
        func job(_ id: Int, _ repo: String, _ wf: String, _ n: Int, steps: Int, step: Int, ran: Double, silent: Double) -> ActiveJob {
            ActiveJob(id: id, repo: repo, workflow: wf, runNumber: n, branch: "main", totalSteps: steps, currentStep: step,
                      startedAt: now.addingTimeInterval(-ran), lastOutputAt: now.addingTimeInterval(-silent))
        }
        var a1 = job(482, "api-server", "build", 482, steps: 9, step: 6, ran: 720, silent: 20)
        a1.url = GitHubLink.safe("https://github.com/rsutcliffe/Hangar")        // a real page, so the link can be tried in the demo
        var a2 = job(1190, "web", "test", 1190, steps: 7, step: 3, ran: 1500, silent: 840)
        if scenario == .failed {
            a1.failedStep = 4; a1.exitCode = 1; a1.currentStep = 4; a1.failedStepName = "Run unit tests"
            a2.lastOutputAt = now.addingTimeInterval(-30)
        }
        func obs(_ id: String, _ arch: Arch, _ cpus: Int, _ mem: Double, busy: Bool, job: ActiveJob?, cpu: Double, used: Double, ended: Double?,
                 host: String = "", up: Bool = true) -> RunnerObservation {
            let down = lock.withLock { restarted[id].map { now.timeIntervalSince($0) < 12 } ?? false }
            return RunnerObservation(id: id, arch: arch, cpus: cpus, memoryGB: mem, vmRunning: !down, ghOnline: !down,
                                     listenerRunning: up, busy: busy, host: host, job: job, cpuPercent: cpu, memUsedGB: used,
                                     lastJobEndedAt: ended.map { now.addingTimeInterval(-$0) },
                                     runnerCPU: cpu, cpuSupported: true,
                                     diskFreeKB: id == "x86-01" ? 6_500_000 : 60_000_000, diskUsedPct: id == "x86-01" ? 84 : 40,
                                     version: id == "arm-01" ? "2.337.0" : "2.338.0",
                                     hostMemory: id == "arm-02" ? HostMemory(pressureLevel: scenario == .pressure ? 2 : 1, swapUsedMB: 4172, swapTotalMB: 5120, ramGB: 16) : nil)
        }
        let wob = Double(Int(now.timeIntervalSince(t0)) % 7)
        // In the unreachable scenario the second host drops out after 10 seconds, as if its SSH connection failed.
        let hostDown = scenario == .unreachable && now.timeIntervalSince(t0) > 10
        var runners = [obs("arm-01", .arm64, 4, 8, busy: true, job: a1, cpu: 72 + wob, used: 5.1, ended: nil, host: scenario == .unreachable ? "this Mac" : "")]
        if !hostDown {
            runners += [
                obs("arm-02", .arm64, 4, 8, busy: true, job: a2, cpu: scenario == .failed ? 66 : 2, used: 6.8, ended: nil, host: scenario == .unreachable ? "mac-mini" : ""),
                // In the offline scenario this runner's listener stops responding after 10 seconds, like a crash.
                obs("x86-01", .x86, 2, 4, busy: false, job: nil, cpu: 1, used: 1.2, ended: 180, host: scenario == .unreachable ? "mac-mini" : "",
                    up: !(scenario == .offline && now.timeIntervalSince(t0) > 10)),
            ]
        }
        func q(_ id: Int, _ repo: String, _ wf: String, _ br: String, _ n: Int, _ arch: Arch, _ wait: Double,
               eligible: [String]? = nil, missing: [String] = []) -> QueuedJob {
            QueuedJob(id: id, repo: repo, workflow: wf, branch: br, runNumber: n, arch: arch, queuedAt: now.addingTimeInterval(-wait),
                      labels: ["self-hosted"], eligible: eligible, missingLabels: missing)
        }
        let queue = [
            q(1, "api-server", "Lint", "main", 483, .arm64, 120), q(2, "web", "E2E tests", "feat/checkout", 1191, .arm64, 240),
            q(3, "api-server", "Build", "fix/auth-timeout", 484, .arm64, 360, eligible: ["arm-01"]), q(4, "ios-app", "Unit tests", "main", 77, .x86, 30, eligible: [], missing: ["xcode-26"]),
            q(5, "web", "Lint", "main", 1192, .arm64, 20),
        ]
        var snap = BackendSnapshot(runners: runners, queue: queue)
        snap.latestRunner = "2.338.0"; snap.latestRunnerPublished = Date().addingTimeInterval(-20 * 86400)
        if scenario == .permission {
            // A Mac Mini that macOS has not yet been allowed to reach, and a newer release to download.
            let p = LocalNetwork.explain(target: "192.168.1.20", reason: "ssh: connect to host 192.168.1.20 port 22: No route to host")
            snap.warnings = [p.message]; snap.needsLocalNetwork = p.needsLocalNetwork
            snap.latestApp = AppRelease(version: "0.2.0", name: "Hangar 0.2.0", url: URL(string: "https://github.com/rsutcliffe/Hangar/releases")!)
        }
        if scenario == .unreachable {
            snap.tokenExpiry = now.addingTimeInterval(9 * 86_400)
            if hostDown { snap.unreachable = ["mac-mini"]; snap.warnings = ["mac-mini unreachable (ssh: connect to host mac-mini port 22: Operation timed out)"] }
        }
        return snap
    }

    func restart(_ id: String, config: Config) async throws { lock.withLock { restarted[id] = Date() } }
    func setRunnerService(_ id: String, running: Bool, config: Config) async throws {}
    func diagnose(config: Config) async -> ConnectionReport {
        ConnectionReport(lines: [ConnectionReport.host("this Mac", error: nil, runners: 1), ConnectionReport.host("mac-mini", error: "ssh: connect to host mac-mini port 22: Operation timed out", runners: 0),
                                 ConnectionReport.repo("widgets", error: nil), ConnectionReport.repo("gadgets", error: GitHubError.http(403))])
    }
}
