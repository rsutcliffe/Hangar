import Foundation

/// Scripted data mirroring the prototype so the UI can be checked with no token or VMs.
/// Enabled with the `--demo` launch argument.
final class DemoBackend: MonitorBackend, @unchecked Sendable {
    enum Scenario: String { case stalled, failed }
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
        var a2 = job(1190, "web", "test", 1190, steps: 7, step: 3, ran: 1500, silent: 840)
        if scenario == .failed {
            a1.failedStep = 4; a1.exitCode = 1; a1.currentStep = 4
            a2.lastOutputAt = now.addingTimeInterval(-30)
        }
        func obs(_ id: String, _ arch: Arch, _ cpus: Int, _ mem: Double, busy: Bool, job: ActiveJob?, cpu: Double, used: Double, ended: Double?) -> RunnerObservation {
            let down = lock.withLock { restarted[id].map { now.timeIntervalSince($0) < 12 } ?? false }
            return RunnerObservation(id: id, arch: arch, cpus: cpus, memoryGB: mem, vmRunning: !down, ghOnline: !down,
                                     busy: busy, job: job, cpuPercent: cpu, memUsedGB: used,
                                     lastJobEndedAt: ended.map { now.addingTimeInterval(-$0) },
                                     runnerCPU: cpu, cpuSupported: true)
        }
        let wob = Double(Int(now.timeIntervalSince(t0)) % 7)
        let runners = [
            obs("arm-01", .arm64, 4, 8, busy: true, job: a1, cpu: 72 + wob, used: 5.1, ended: nil),
            obs("arm-02", .arm64, 4, 8, busy: true, job: a2, cpu: scenario == .failed ? 66 : 2, used: 6.8, ended: nil),
            obs("x86-01", .x86, 2, 4, busy: false, job: nil, cpu: 1, used: 1.2, ended: 180),
        ]
        func q(_ id: Int, _ repo: String, _ wf: String, _ br: String, _ n: Int, _ arch: Arch, _ wait: Double) -> QueuedJob {
            QueuedJob(id: id, repo: repo, workflow: wf, branch: br, runNumber: n, arch: arch, queuedAt: now.addingTimeInterval(-wait))
        }
        let queue = [
            q(1, "api-server", "Lint", "main", 483, .arm64, 120), q(2, "web", "E2E tests", "feat/checkout", 1191, .arm64, 240),
            q(3, "api-server", "Build", "fix/auth-timeout", 484, .arm64, 360), q(4, "ios-app", "Unit tests", "main", 77, .x86, 30),
            q(5, "web", "Lint", "main", 1192, .arm64, 20),
        ]
        return BackendSnapshot(runners: runners, queue: queue)
    }

    func restart(_ id: String, config: Config) async throws { lock.withLock { restarted[id] = Date() } }
    func setRunnerService(_ id: String, running: Bool, config: Config) async throws {}
}
