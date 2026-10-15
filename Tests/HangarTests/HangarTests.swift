import XCTest
@testable import Hangar

final class FormatTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(Format.duration(30), "<1m")
        XCTAssertEqual(Format.duration(14 * 60), "14m")
        XCTAssertEqual(Format.duration(65 * 60), "1h 5m")
        XCTAssertEqual(Format.duration(120 * 60), "2h")
        XCTAssertEqual(Format.gb(8), "8 GB")
        XCTAssertEqual(Format.gb(5.1), "5.1 GB")
    }
}

final class StateRulesTests: XCTestCase {
    let now = Date()
    func obs(busy: Bool = true, silent: TimeInterval = 20, failed: Bool = false, vm: Bool = true, gh: Bool = true) -> RunnerObservation {
        let job = ActiveJob(id: 1, repo: "r", workflow: "w", runNumber: 1, branch: "main", totalSteps: 9, currentStep: 4,
                            startedAt: now - 900, lastOutputAt: now - silent, failedStep: failed ? 4 : nil, exitCode: nil)
        return RunnerObservation(id: "arm-01", arch: .arm64, cpus: 4, memoryGB: 8, vmRunning: vm, ghOnline: gh, busy: busy,
                                 job: busy || failed ? job : nil, cpuPercent: 10, memUsedGB: 1, lastJobEndedAt: nil)
    }
    func derive(_ o: RunnerObservation, _ i: RunnerIntent = .init(), seen: Date? = nil) -> RunnerState {
        StateRules.derive(o, intent: i, failureSeenAt: seen, now: now, stallThreshold: 600)
    }
    func testRunningStalledIdle() {
        XCTAssertEqual(derive(obs()), .running)
        XCTAssertEqual(derive(obs(silent: 600)), .stalled)
        XCTAssertEqual(derive(obs(busy: false)), .idle)
    }
    func testOfflineAndPaused() {
        XCTAssertEqual(derive(obs(vm: false)), .offline)
        XCTAssertEqual(derive(obs(gh: false)), .offline)
        XCTAssertEqual(derive(obs(busy: false), RunnerIntent(paused: true)), .paused)
    }
    func testFailedHeldTwoAndAHalfMinutes() {
        XCTAssertEqual(derive(obs(busy: false, failed: true), seen: now - 100), .failed)
        XCTAssertEqual(derive(obs(busy: false, failed: true), seen: now - 151), .idle)
    }
    func testRestarting() {
        XCTAssertEqual(derive(obs(), RunnerIntent(restartingSince: now - 30)), .running)   // back online
        XCTAssertEqual(derive(obs(vm: false), RunnerIntent(restartingSince: now - 30)), .restarting)
        XCTAssertEqual(derive(obs(busy: false), RunnerIntent(restartingSince: now - 30)), .idle)
    }
}

final class ProcParserTests: XCTestCase {
    func testCPU() {
        let a = ProcParser.cpuTimes(fromStatLine: "cpu  100 0 100 700 100 0 0 0 0 0")!
        let b = ProcParser.cpuTimes(fromStatLine: "cpu  200 0 200 1400 200 0 0 0 0 0")!
        XCTAssertEqual(ProcParser.cpuPercent(prev: a, now: b)!, 20, accuracy: 0.01)
        XCTAssertNil(ProcParser.cpuTimes(fromStatLine: "intr 1"))
    }
    func testMem() {
        let t = "MemTotal:        8388608 kB\nMemAvailable:    3145728 kB\n"
        XCTAssertEqual(ProcParser.memUsedGB(fromMeminfo: t)!, 5.0, accuracy: 0.001)
    }
}

final class GitHubParseTests: XCTestCase {
    func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8)) }
    func testRunnersRunsJobsAndQueue() {
        let runners = GitHubService.parseRunners(json(#"{"runners":[{"name":"arm-01-x","status":"online","busy":true,"labels":[{"name":"self-hosted"},{"name":"ARM64"}]}]}"#))
        XCTAssertEqual(runners, [GHRunner(name: "arm-01-x", online: true, busy: true, labels: ["self-hosted", "ARM64"])])
        XCTAssertFalse(runners[0].isStandby)
        XCTAssertTrue(GHRunner(name: "x", online: true, busy: false, labels: ["self-hosted", "MacBook-Standby"]).isStandby)
        let runs = GitHubService.parseRuns(json(#"{"workflow_runs":[{"id":9,"name":"build","run_number":482,"head_branch":"main","status":"in_progress","updated_at":"2026-10-14T10:00:00Z"}]}"#))
        XCTAssertEqual(runs.first?.number, 482)
        let jobs = GitHubService.parseJobs(json(#"""
        {"jobs":[
         {"id":1,"status":"in_progress","labels":["self-hosted","ARM64"],"runner_name":"arm-01-x","created_at":"2026-10-14T09:50:00Z","started_at":"2026-10-14T09:51:00Z",
          "steps":[{"number":1,"status":"completed","conclusion":"success"},{"number":2,"status":"in_progress"},{"number":3,"status":"queued"}]},
         {"id":2,"status":"queued","labels":["self-hosted","X64"],"created_at":"2026-10-14T09:55:00Z","steps":[]},
         {"id":3,"status":"queued","labels":["ubuntu-latest"],"created_at":"2026-10-14T09:56:00Z","steps":[]}]}
        """#), repo: "api", run: runs[0])
        XCTAssertEqual(jobs.count, 3)
        let q = LiveBackend.queue(from: jobs)
        XCTAssertEqual(q.map(\.id), [2])                // hosted-runner job excluded
        XCTAssertEqual(q.first?.arch, .x86)
        let a = LiveBackend.activeJob(jobs[0], lastOutput: nil)
        XCTAssertEqual(a.currentStep, 2); XCTAssertEqual(a.totalSteps, 3)
    }
    func testAssembleAcrossMachines() {
        let now = Date()
        let job = GHJob(id: 1, runId: 9, repo: "hoci", workflow: "build", runNumber: 482, branch: "main", status: "in_progress", conclusion: nil,
                        labels: ["self-hosted"], runnerName: "m4-scoreview-ci", createdAt: now, startedAt: now, completedAt: nil,
                        steps: [.init(number: 1, status: "in_progress", conclusion: nil)])
        let vm = LiveBackend.Machine(label: "mac-mini", info: VMInfo(running: true, arch: .arm64, cpus: 6, memoryGB: 12),
            snap: VMSnapshot(cpuPercent: 12, memUsedGB: 3, runners: [
                RunnerFacts(dir: "/h/a", name: "m4-scoreview-ci", owner: "rsutcliffe", repo: "hoci", listenerRunning: true, lastOutputAt: now)]),
            native: false, host: HostSpec("192.0.2.10"), profile: "default")
        let nat = LiveBackend.Machine(label: "mac-mini", info: nil,
            snap: VMSnapshot(cpuPercent: 40, memUsedGB: 9, runners: [
                RunnerFacts(dir: "/Users/u/actions-runner", name: "mac-mini-m4", owner: "rsutcliffe", repo: "CertsVault", listenerRunning: true, lastOutputAt: nil)],
                             hostname: "mac-mini.local", cpus: 10, memTotalGB: 16),
            native: true, host: HostSpec("192.0.2.10"), profile: nil)
        let snap = LiveBackend.assemble(machines: [vm, nat], runners: [GHRunner(name: "m4-scoreview-ci", online: true, busy: true, labels: []),
                                                                        GHRunner(name: "mac-mini-m4", online: true, busy: false, labels: [])],
                                        jobs: [job], now: now)
        XCTAssertEqual(snap.runners.map(\.id), ["m4-scoreview-ci", "mac-mini-m4"])
        XCTAssertEqual(snap.runners[0].job?.id, 1); XCTAssertEqual(snap.runners[0].cpus, 6)
        XCTAssertFalse(snap.runners[0].standby)
        XCTAssertEqual(snap.runners[1].cpus, 10); XCTAssertEqual(snap.runners[1].memoryGB, 16, accuracy: 0.001); XCTAssertTrue(snap.runners[1].native)
    }
}

final class SnapshotParserTests: XCTestCase {
    func testParseVM() {
        let out = """
        cpu  200 0 200 1400 200 0 0 0 0 0
        ---
        MemTotal:        8388608 kB
        MemAvailable:    3145728 kB
        ---
        1000
        H|colima
        R|/home/u/actions-runner-hoci|colima-scoreview-ci|https://github.com/rsutcliffe/hoci|1|940
        R|/home/u/actions-runner|colima-tenantsafe-ci|https://github.com/rsutcliffe/TenantShield|0|none

        """
        let prev = ProcParser.cpuTimes(fromStatLine: "cpu  100 0 100 700 100 0 0 0 0 0")
        let (snap, _) = SnapshotParser.parseVM(out, prevCPU: prev)!
        XCTAssertEqual(snap.cpuPercent, 20, accuracy: 0.01)
        XCTAssertEqual(snap.memUsedGB, 5, accuracy: 0.001)
        XCTAssertEqual(snap.hostname, "colima")
        XCTAssertEqual(snap.runners.map(\.name), ["colima-scoreview-ci", "colima-tenantsafe-ci"])
        XCTAssertEqual(snap.runners[0].lastOutputAt!.timeIntervalSinceNow, -60, accuracy: 2)
        XCTAssertNil(snap.runners[1].lastOutputAt); XCTAssertFalse(snap.runners[1].listenerRunning)
        XCTAssertNil(SnapshotParser.ownerRepo(fromURL: "https://github.com/a;b/c"))
    }
    func testParseNative() {
        let out = """
        H|mac-mini.local
        D|2000
        N|10|17179869184
        C|45.5
        M|8589934592
        R|/Users/u/actions-runner|mac-mini-m4|https://github.com/rsutcliffe/CertsVault|1|1990

        """
        let s = SnapshotParser.parseNative(out)!
        XCTAssertEqual(s.cpus, 10); XCTAssertEqual(s.memTotalGB!, 16, accuracy: 0.001)
        XCTAssertEqual(s.memUsedGB, 8, accuracy: 0.001); XCTAssertEqual(s.cpuPercent, 45.5, accuracy: 0.01)
        XCTAssertEqual(s.runners.first?.repo, "CertsVault")
        XCTAssertNil(SnapshotParser.parseNative("NONE\n"))
        XCTAssertEqual(SnapshotParser.shortName("mac-mini.local"), "mac-mini")
    }
}

final class StaleRuleTests: XCTestCase {
    func testHide() {
        let now = Date()
        XCTAssertTrue(StaleRule.isStale(state: .offline, lastActive: nil, now: now))
        XCTAssertTrue(StaleRule.isStale(state: .offline, lastActive: now - 25 * 3600, now: now))
        XCTAssertFalse(StaleRule.isStale(state: .offline, lastActive: now - 3600, now: now))     // just crashed: stay visible
        XCTAssertFalse(StaleRule.isStale(state: .idle, lastActive: nil, now: now))
    }
}

final class ConfigTests: XCTestCase {
    func testSafety() {
        XCTAssertTrue(Config.isSafeName("arm-01")); XCTAssertFalse(Config.isSafeName("a;rm -rf /"))
        XCTAssertTrue(Config.isSafePath("~/actions-runner")); XCTAssertFalse(Config.isSafePath("~/a b; ls")); XCTAssertFalse(Config.isSafePath("../x"))
        XCTAssertEqual(Config.list("a, b c\nd"), ["a", "b", "c", "d"])
        XCTAssertEqual(Config().profiles, ["default"]); XCTAssertEqual(Config().hosts, ["local"])
        XCTAssertTrue(Config.isSafeHost("192.0.2.10")); XCTAssertTrue(Config.isSafeHost("me@mac-mini.local"))
        XCTAssertFalse(Config.isSafeHost("-oProxyCommand=x")); XCTAssertFalse(Config.isSafeHost("a b;c"))
    }
}

final class AccessibilityTests: XCTestCase {
    func testSummary() {
        let now = Date()
        let job = ActiveJob(id: 1, repo: "web", workflow: "test", runNumber: 1190, branch: "main", totalSteps: 7, currentStep: 3,
                            startedAt: now - 1500, lastOutputAt: now - 840)
        var r = Runner(id: "arm-02", arch: .arm64, cpus: 4, memoryGB: 8, state: .stalled, job: job)
        XCTAssertEqual(r.accessibilitySummary(now: now), "arm-02, Stalled, test · web #1190, no output for 14m")
        r.state = .running; r.job?.lastOutputAt = now
        XCTAssertEqual(r.accessibilitySummary(now: now), "arm-02, Running, test · web #1190, step 3 of 7, 42 percent")
        XCTAssertEqual(Runner(id: "x", arch: .x86, cpus: 2, memoryGB: 4, state: .offline).accessibilitySummary(now: now), "x, Offline")
        var s = Runner(id: "y", arch: .x86, cpus: 2, memoryGB: 4, state: .idle); s.standby = true
        XCTAssertEqual(s.accessibilitySummary(now: now), "y, Idle, standby")
    }
}

final class StallCPUTests: XCTestCase {
    let now = Date()
    func obs(silent: TimeInterval, cpuSupported: Bool) -> RunnerObservation {
        let job = ActiveJob(id: 1, repo: "r", workflow: "w", runNumber: 1, branch: "main", totalSteps: 9, currentStep: 4,
                            startedAt: now - 3000, lastOutputAt: now - silent)
        return RunnerObservation(id: "a", arch: .arm64, cpus: 4, memoryGB: 8, vmRunning: true, ghOnline: true, busy: true,
                                 job: job, cpuPercent: 10, memUsedGB: 1, lastJobEndedAt: nil, cpuSupported: cpuSupported)
    }
    func state(_ o: RunnerObservation, avg: Double?) -> RunnerState {
        StateRules.derive(o, intent: .init(), failureSeenAt: nil, now: now, stallThreshold: 600, runnerCPUAvg: avg)
    }
    func testSilentButBusyStaysRunning() { XCTAssertEqual(state(obs(silent: 900, cpuSupported: true), avg: 80), .running) }
    func testSilentAndIdleStalls() { XCTAssertEqual(state(obs(silent: 900, cpuSupported: true), avg: 1), .stalled) }
    func testNotSilentNeverStalls() { XCTAssertEqual(state(obs(silent: 60, cpuSupported: true), avg: 0), .running) }
    func testCPUReadableButNoSamplesYetWaits() { XCTAssertEqual(state(obs(silent: 900, cpuSupported: true), avg: nil), .running) }
    func testCPUUnreadableFallsBackToSilence() { XCTAssertEqual(state(obs(silent: 900, cpuSupported: false), avg: nil), .stalled) }
    func testBoundary() {
        XCTAssertEqual(state(obs(silent: 900, cpuSupported: true), avg: 4.99), .stalled)
        XCTAssertEqual(state(obs(silent: 900, cpuSupported: true), avg: 5.0), .running)
    }
    func testAverageNeedsTwoSamples() {
        XCTAssertNil(MonitorStore.average([3], minimum: 2))
        XCTAssertEqual(MonitorStore.average([2, 4, 6], minimum: 2)!, 4, accuracy: 0.001)
    }
}

final class RunnerCPUTests: XCTestCase {
    func testRate() {
        let t0 = Date()
        XCTAssertNil(CPURate.percent(prev: nil, now: (10, t0)))
        XCTAssertEqual(CPURate.percent(prev: (10, t0), now: (25, t0 + 30))!, 50, accuracy: 0.001)
        XCTAssertNil(CPURate.percent(prev: (25, t0), now: (10, t0 + 30)))          // counter fell: processes exited
        XCTAssertNil(CPURate.percent(prev: (10, t0), now: (11, t0 + 0.2)))         // too little time elapsed
    }
    func testRunnerLineCarriesCPUSeconds() {
        let out = """
        H|vm
        D|2000
        R|/h/actions-runner|n1|https://github.com/o/r|1|1990|102.50
        R|/h/actions-runner-2|n2|https://github.com/o/r|0|none|none
        """
        let s = SnapshotParser.parseNative(out)!
        XCTAssertEqual(s.runners[0].cpuSeconds!, 102.5, accuracy: 0.001)
        XCTAssertNil(s.runners[1].cpuSeconds)
    }
    /// Runs the real awk program the probe sends, on both ps time formats.
    func testProcessTreeSumWithTheProbeAwk() throws {
        let ps = """
          1     0 5
        100     1 0:02.50
        101   100 1:30.00
        102   101 7
        200     1 99
        300   200 4
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
        p.arguments = ["-v", "root=100", HostService.treeAwk]
        let i = Pipe(), o = Pipe()
        p.standardInput = i; p.standardOutput = o
        try p.run()
        i.fileHandleForWriting.write(Data(ps.utf8)); try i.fileHandleForWriting.close()
        let out = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(Double(out)!, 99.5, accuracy: 0.01)     // 2.5 + 90 + 7; the unrelated tree is excluded
    }
}
