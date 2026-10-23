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
        let job = GHJob(id: 1, runId: 9, repo: "gadgets", workflow: "build", runNumber: 482, branch: "main", status: "in_progress", conclusion: nil,
                        labels: ["self-hosted"], runnerName: "m4-web-ci", createdAt: now, startedAt: now, completedAt: nil,
                        steps: [.init(number: 1, status: "in_progress", conclusion: nil)])
        let vm = LiveBackend.Machine(label: "mac-mini", info: VMInfo(running: true, arch: .arm64, cpus: 6, memoryGB: 12),
            snap: VMSnapshot(cpuPercent: 12, memUsedGB: 3, runners: [
                RunnerFacts(dir: "/h/a", name: "m4-web-ci", owner: "example-org", repo: "gadgets", listenerRunning: true, lastOutputAt: now)]),
            native: false, host: HostSpec("192.0.2.10"), profile: "default")
        let nat = LiveBackend.Machine(label: "mac-mini", info: nil,
            snap: VMSnapshot(cpuPercent: 40, memUsedGB: 9, runners: [
                RunnerFacts(dir: "/Users/u/actions-runner", name: "mini-native", owner: "example-org", repo: "vault", listenerRunning: true, lastOutputAt: nil)],
                             hostname: "mac-mini.local", cpus: 10, memTotalGB: 16),
            native: true, host: HostSpec("192.0.2.10"), profile: nil)
        let snap = LiveBackend.assemble(machines: [vm, nat], runners: [GHRunner(name: "m4-web-ci", online: true, busy: true, labels: []),
                                                                        GHRunner(name: "mini-native", online: true, busy: false, labels: [])],
                                        jobs: [job], now: now)
        XCTAssertEqual(snap.runners.map(\.id), ["m4-web-ci", "mini-native"])
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
        R|/home/u/actions-runner-gadgets|colima-app-ci|https://github.com/example-org/gadgets|1|940
        R|/home/u/actions-runner|colima-db-ci|https://github.com/example-org/widgets|0|none

        """
        let prev = ProcParser.cpuTimes(fromStatLine: "cpu  100 0 100 700 100 0 0 0 0 0")
        let (snap, _) = SnapshotParser.parseVM(out, prevCPU: prev)!
        XCTAssertEqual(snap.cpuPercent, 20, accuracy: 0.01)
        XCTAssertEqual(snap.memUsedGB, 5, accuracy: 0.001)
        XCTAssertEqual(snap.hostname, "colima")
        XCTAssertEqual(snap.runners.map(\.name), ["colima-app-ci", "colima-db-ci"])
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
        R|/Users/u/actions-runner|mini-native|https://github.com/example-org/vault|1|1990

        """
        let s = SnapshotParser.parseNative(out)!
        XCTAssertEqual(s.cpus, 10); XCTAssertEqual(s.memTotalGB!, 16, accuracy: 0.001)
        XCTAssertEqual(s.memUsedGB, 8, accuracy: 0.001); XCTAssertEqual(s.cpuPercent, 45.5, accuracy: 0.01)
        XCTAssertEqual(s.runners.first?.repo, "vault")
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

final class QueueAnalysisTests: XCTestCase {
    func runner(_ n: String, online: Bool = true, repo: String = "ts", _ labels: [String]) -> GHRunner {
        var r = GHRunner(name: n, online: online, busy: false, labels: labels); r.repo = repo; return r
    }
    let rs: [GHRunner] = []
    func testSubsetMatchIsCaseInsensitive() {
        let runners = [runner("a", ["self-hosted", "Linux", "ARM64", "api-ci", "db-tests"]),
                       runner("b", ["self-hosted", "Linux", "ARM64", "api-ci"])]
        XCTAssertEqual(QueueAnalysis.eligible(labels: ["self-hosted", "linux", "api-ci"], repo: "ts", runners: runners), ["a", "b"])
        XCTAssertEqual(QueueAnalysis.eligible(labels: ["self-hosted", "linux", "db-tests"], repo: "ts", runners: runners), ["a"])
    }
    func testOfflineRunnersNeverCount() {
        let runners = [runner("a", online: false, ["self-hosted", "db-tests"]), runner("b", ["self-hosted"])]
        XCTAssertEqual(QueueAnalysis.eligible(labels: ["self-hosted", "db-tests"], repo: "ts", runners: runners), [])
        XCTAssertEqual(QueueAnalysis.missingLabels(labels: ["self-hosted", "db-tests"], repo: "ts", runners: runners), ["db-tests"])
    }
    func testRunnersOnlyServeTheirOwnRepo() {
        let runners = [runner("a", repo: "gadgets", ["self-hosted"])]
        XCTAssertEqual(QueueAnalysis.eligible(labels: ["self-hosted"], repo: "ts", runners: runners), [])
        XCTAssertEqual(QueueAnalysis.eligible(labels: ["self-hosted"], repo: "gadgets", runners: runners), ["a"])
    }
    func testQueueCarriesEligibilityAndStuckCount() {
        let now = Date()
        func job(_ id: Int, _ labels: [String]) -> GHJob {
            GHJob(id: id, runId: 1, repo: "ts", workflow: "CI", runNumber: 1, branch: "main", status: "queued", conclusion: nil,
                  labels: labels, runnerName: nil, createdAt: now, startedAt: nil, completedAt: nil, steps: [], name: "j\(id)")
        }
        let runners = [runner("a", ["self-hosted", "Linux", "x"])]
        let q = LiveBackend.queue(from: [job(1, ["self-hosted", "linux", "x"]), job(2, ["self-hosted", "gpu"])], runners: runners)
        XCTAssertEqual(q.map(\.eligible), [["a"], []])
        XCTAssertEqual(q.stuckCount, 1)
        XCTAssertEqual(q[1].missingLabels, ["gpu"])
        XCTAssertNil(LiveBackend.queue(from: [job(3, ["self-hosted"])], runners: nil)[0].eligible)    // unknown, not "stuck"
    }
    func testNotes() {
        var j = QueuedJob(id: 1, repo: "ts", workflow: "CI", branch: "main", runNumber: 1, arch: .arm64, queuedAt: Date(), labels: ["self-hosted"])
        XCTAssertNil(UpNextCard.note(for: j))
        j.eligible = ["m4-a"]
        XCTAssertEqual(UpNextCard.note(for: j)?.text, "Only m4-a can run this")
        j.eligible = ["a", "b"]; XCTAssertNil(UpNextCard.note(for: j))
        j.eligible = []; j.missingLabels = ["gpu"]
        XCTAssertEqual(UpNextCard.note(for: j)?.text, "No online runner has: gpu"); XCTAssertEqual(UpNextCard.note(for: j)?.stuck, true)
    }
}

final class FailureDetailTests: XCTestCase {
    func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8)) }

    func testParsesStepNamesAndJobLink() {
        let run = GitHubService.Run(id: 9, name: "CI", number: 5, branch: "main", status: "completed", conclusion: "failure", updatedAt: Date())
        let jobs = GitHubService.parseJobs(json(#"""
        {"jobs":[{"id":1,"status":"completed","conclusion":"failure","labels":["self-hosted"],"runner_name":"r",
          "created_at":"2026-10-14T09:50:00Z","started_at":"2026-10-14T09:51:00Z","completed_at":"2026-10-14T09:53:00Z",
          "html_url":"https://github.com/o/r/actions/runs/9/job/1",
          "steps":[{"number":1,"name":"Set up job","status":"completed","conclusion":"success"},
                   {"number":2,"name":"Checkout","status":"completed","conclusion":"failure"}]}]}
        """#), repo: "r", run: run)
        let a = LiveBackend.activeJob(jobs[0], lastOutput: nil)
        XCTAssertEqual(a.failedStep, 2)
        XCTAssertEqual(a.failedStepName, "Checkout")
        XCTAssertEqual(a.url?.absoluteString, "https://github.com/o/r/actions/runs/9/job/1")
        XCTAssertEqual(RunnerCard.failureText(a), "Failed: Checkout")
    }

    func testFallsBackToStepNumberWhenNoName() {
        var a = ActiveJob(id: 1, repo: "r", workflow: "w", runNumber: 1, branch: "main", totalSteps: 3, currentStep: 2,
                          startedAt: Date(), lastOutputAt: Date(), failedStep: 2, exitCode: nil)
        XCTAssertEqual(RunnerCard.failureText(a), "Failed at step 2")
        a.exitCode = 1
        XCTAssertEqual(RunnerCard.failureText(a), "Exit 1 at step 2")
    }

    func testOnlyGitHubHttpsLinksOpen() {
        XCTAssertNotNil(GitHubLink.safe("https://github.com/o/r/actions/runs/1"))
        XCTAssertNotNil(GitHubLink.safe("https://www.github.com/o/r"))
        XCTAssertNil(GitHubLink.safe("http://github.com/o/r"))                 // not https
        XCTAssertNil(GitHubLink.safe("https://github.com.evil.example/o/r"))   // look-alike host
        XCTAssertNil(GitHubLink.safe("https://evil.example/github.com"))
        XCTAssertNil(GitHubLink.safe("file:///etc/passwd"))
        XCTAssertNil(GitHubLink.safe(""))
    }
}

private final class FakeLoginItem: LoginItemService {
    var state: LoginItemState = .off
    var failNext = false
    var openedSettings = false
    func set(_ on: Bool) throws {
        if failNext { failNext = false; throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "denied"]) }
        state = on ? .on : .off
    }
    func openLoginItemsSettings() { openedSettings = true }
}

@MainActor
final class LoginItemTests: XCTestCase {
    func testToggleFollowsTheSystemState() {
        let f = FakeLoginItem(); let m = LoginItemModel(service: f)
        XCTAssertFalse(m.isOn)
        m.setOn(true); XCTAssertTrue(m.isOn); XCTAssertEqual(m.state, .on)
        m.setOn(false); XCTAssertFalse(m.isOn)
    }
    func testChangeMadeInSystemSettingsIsPickedUpOnRefresh() {
        let f = FakeLoginItem(); let m = LoginItemModel(service: f)
        f.state = .needsApproval; m.refresh()
        XCTAssertTrue(m.isOn); XCTAssertEqual(m.state, .needsApproval)
        m.openSettings(); XCTAssertTrue(f.openedSettings)
        f.state = .off; m.refresh(); XCTAssertFalse(m.isOn)
    }
    func testFailureIsShownAndStateStaysTrue() {
        let f = FakeLoginItem(); f.failNext = true
        let m = LoginItemModel(service: f)
        m.setOn(true)
        XCTAssertNotNil(m.error); XCTAssertFalse(m.isOn)
    }
}

final class ProblemBadgeTests: XCTestCase {
    func r(_ s: RunnerState) -> Runner { Runner(id: "x", arch: .arm64, cpus: 1, memoryGB: 1, state: s) }
    func testCountsStalledAndFailedOnly() {
        XCTAssertEqual(ProblemBadge.count([r(.running), r(.stalled), r(.failed), r(.idle), r(.paused), r(.offline), r(.restarting)]), 2)
        XCTAssertEqual(ProblemBadge.count([]), 0)
    }
    func testLabelIsNilAtZero() {
        XCTAssertNil(ProblemBadge.label(0)); XCTAssertEqual(ProblemBadge.label(3), "3")
    }
}

final class StaleHostTests: XCTestCase {
    func r(_ id: String, host: String, _ s: RunnerState = .idle) -> Runner {
        var x = Runner(id: id, arch: .arm64, cpus: 2, memoryGB: 4, state: s); x.host = host; return x
    }
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testRunnersOfAnUnreachableHostAreCarriedOverGreyed() {
        let prev = [r("a", host: "this Mac"), r("b", host: "mac-mini", .running), r("c", host: "mac-mini")]
        let cur = [r("a", host: "this Mac")]
        let out = HostRetention.carryOver(previous: prev, current: cur, unreachable: ["mac-mini"], lastSeen: ["b": t0, "c": t0])
        XCTAssertEqual(out.map(\.id), ["b", "c"])
        XCTAssertTrue(out.allSatisfy { $0.state == .unreachable && $0.job == nil && $0.lastSeenAt == t0 })
    }
    func testAReachableHostsMissingRunnerIsNotCarriedOver() {
        let out = HostRetention.carryOver(previous: [r("b", host: "mac-mini")], current: [], unreachable: [], lastSeen: ["b": t0])
        XCTAssertTrue(out.isEmpty)
    }
    func testLastSeenKeepsTheFirstTimeWhileStillUnreachable() {
        var already = r("b", host: "mac-mini", .unreachable); already.lastSeenAt = t0
        let out = HostRetention.carryOver(previous: [already], current: [], unreachable: ["mac-mini"], lastSeen: ["b": t0 + 600])
        XCTAssertEqual(out.first?.lastSeenAt, t0)
    }
    func testRecoveredRunnerIsNotDuplicated() {
        let out = HostRetention.carryOver(previous: [r("b", host: "mac-mini", .unreachable)], current: [r("b", host: "mac-mini")],
                                          unreachable: [], lastSeen: [:])
        XCTAssertTrue(out.isEmpty)
    }
    func testUnreachableIsNotAProblemForTheBadge() {
        XCTAssertFalse(RunnerState.unreachable.isProblem)
        XCTAssertEqual(r("b", host: "x", .unreachable).accessibilitySummary(now: t0), "b, Unreachable")
    }
}

final class TokenExpiryTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = utc
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))!
    }
    func testParsesTheReportedFormatsLeniently() {
        let want = date(2027, 1, 12, 14, 14, 1)
        XCTAssertEqual(TokenExpiry.parse("2027-01-12 14:14:01 UTC"), want)
        XCTAssertEqual(TokenExpiry.parse("2027-01-12 14:14:01 GMT"), want)
        XCTAssertEqual(TokenExpiry.parse("2027-01-12 14:14:01 +0000"), want)
        XCTAssertEqual(TokenExpiry.parse("2027-01-12T14:14:01Z"), want)
        XCTAssertEqual(TokenExpiry.parse(" 2027-01-12 "), date(2027, 1, 12))
        XCTAssertNil(TokenExpiry.parse("never")); XCTAssertNil(TokenExpiry.parse(""))
    }
    func testWarningWindow() {
        let exp = date(2027, 1, 12)
        XCTAssertNil(TokenExpiry.warning(expiry: nil, now: date(2026, 12, 1)))
        XCTAssertNil(TokenExpiry.warning(expiry: exp, now: date(2026, 12, 1)))                         // 42 days out
        XCTAssertNil(TokenExpiry.warning(expiry: exp, now: date(2026, 12, 28)))                        // 15 days out
        XCTAssertEqual(TokenExpiry.warning(expiry: exp, now: date(2026, 12, 29)), "The GitHub token expires in 14 days")   // edge: shown
        XCTAssertEqual(TokenExpiry.warning(expiry: exp, now: date(2026, 12, 30)), "The GitHub token expires in 13 days")
        XCTAssertEqual(TokenExpiry.warning(expiry: exp, now: date(2027, 1, 3)), "The GitHub token expires in 9 days")
        XCTAssertEqual(TokenExpiry.warning(expiry: exp, now: date(2027, 1, 11, 20)), "The GitHub token expires within a day")
        XCTAssertEqual(TokenExpiry.warning(expiry: exp, now: date(2027, 1, 13)), "The GitHub token has expired")
    }
}

final class OutageTests: XCTestCase {
    func testAlertsOnceWhenOfflineForTwoPollsInARow() {
        var t = OutageTracker()
        XCTAssertFalse(t.observe(id: "a", state: .idle))
        XCTAssertFalse(t.observe(id: "a", state: .offline))        // 1st offline poll: wait
        XCTAssertTrue(t.observe(id: "a", state: .offline))         // 2nd: confirmed
        XCTAssertFalse(t.observe(id: "a", state: .offline))        // still down: no repeat
        XCTAssertEqual(t.outages, ["a"])
    }
    func testABlipThatRecoversNeverAlerts() {
        var t = OutageTracker()
        _ = t.observe(id: "a", state: .running)
        XCTAssertFalse(t.observe(id: "a", state: .offline))
        XCTAssertFalse(t.observe(id: "a", state: .running))
        XCTAssertFalse(t.observe(id: "a", state: .offline))        // counter restarted
        XCTAssertTrue(t.outages.isEmpty)
    }
    func testAnotherAlertOnlyAfterRecoveryAndAFreshOutage() {
        var t = OutageTracker()
        _ = t.observe(id: "a", state: .idle)
        _ = t.observe(id: "a", state: .offline); XCTAssertTrue(t.observe(id: "a", state: .offline))
        _ = t.observe(id: "a", state: .idle); XCTAssertTrue(t.outages.isEmpty)
        _ = t.observe(id: "a", state: .offline); XCTAssertTrue(t.observe(id: "a", state: .offline))
    }
    func testDrainPauseRestartAndUnreachableNeverAlert() {
        var t = OutageTracker()
        for s: RunnerState in [.paused, .restarting, .unreachable] {
            _ = t.observe(id: "a", state: .idle)
            _ = t.observe(id: "a", state: s)
            XCTAssertFalse(t.observe(id: "a", state: .offline), "after \(s)")      // forgot it was up
            XCTAssertFalse(t.observe(id: "a", state: .offline), "after \(s)")
        }
    }
    func testARunnerNeverSeenUpIsNotAnOutage() {
        var t = OutageTracker()
        XCTAssertFalse(t.observe(id: "stale", state: .offline)); XCTAssertFalse(t.observe(id: "stale", state: .offline))
    }
    func testOutagesCountTowardTheBadge() {
        func r(_ id: String, _ s: RunnerState) -> Runner { Runner(id: id, arch: .arm64, cpus: 1, memoryGB: 1, state: s) }
        let rs = [r("a", .offline), r("b", .offline), r("c", .stalled)]
        XCTAssertEqual(ProblemBadge.count(rs), 1)
        XCTAssertEqual(ProblemBadge.count(rs, outages: ["a"]), 2)
    }
    func testMessage() {
        XCTAssertEqual(NotificationText.offline(runner: "m4-x", host: "mac-mini").body, "m4-x on mac-mini stopped responding.")
        XCTAssertEqual(NotificationText.offline(runner: "m4-x", host: "").body, "m4-x stopped responding.")
        XCTAssertEqual(NotificationText.offline(runner: "m4-x", host: "").title, "Runner offline")
    }
}

final class UtilisationLogTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_800_000_000)      // an arbitrary instant

    func testBucketsByHourAndKeepsPeaks() {
        var log = UtilisationLog()
        log.record(at: base, runners: [("a", true), ("b", false)], queueLength: 3, longestWait: 120)
        log.record(at: base + 60, runners: [("a", false), ("b", false)], queueLength: 1, longestWait: 30)
        let h = log.recent(count: 1, now: base)[0].bucket!
        XCTAssertEqual(h.total, ["a": 2, "b": 2]); XCTAssertEqual(h.busy, ["a": 1])
        XCTAssertEqual(h.peakQueue, 3); XCTAssertEqual(h.longestWaitSeconds, 120)
        XCTAssertEqual(UtilisationLog.busyFraction(h, runner: "a")!, 0.5, accuracy: 0.001)
        XCTAssertNil(UtilisationLog.busyFraction(h, runner: "zzz"))
    }
    func testNextHourIsAnotherBucketAndGapsAreNil() {
        var log = UtilisationLog()
        log.record(at: base, runners: [("a", true)], queueLength: 0, longestWait: 0)
        log.record(at: base + 3 * 3600, runners: [("a", true)], queueLength: 0, longestWait: 0)
        let r = log.recent(count: 4, now: base + 3 * 3600)
        XCTAssertEqual(r.map { $0.bucket != nil }, [true, false, false, true])
        XCTAssertEqual(r.count, 4)
    }
    func testRetentionDropsAnythingOlderThanEightDays() {
        var log = UtilisationLog()
        log.record(at: base, runners: [("a", true)], queueLength: 1, longestWait: 1)
        log.record(at: base + 9 * 86_400, runners: [("a", true)], queueLength: 1, longestWait: 1)
        XCTAssertEqual(log.hours.count, 1)
        var kept = UtilisationLog()
        kept.record(at: base, runners: [("a", true)], queueLength: 1, longestWait: 1)
        kept.record(at: base + 7 * 86_400, runners: [("a", true)], queueLength: 1, longestWait: 1)
        XCTAssertEqual(kept.hours.count, 2)
    }
    func testJSONRoundTripAndMissingFile() throws {
        var log = UtilisationLog()
        log.record(at: base, runners: [("a", true), ("b", false)], queueLength: 2, longestWait: 90)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-test-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("utilisation.json")
        log.save(to: url)
        XCTAssertEqual(UtilisationLog.load(from: url, now: base), log)
        XCTAssertEqual(UtilisationLog.load(from: dir.appendingPathComponent("none.json"), now: base), UtilisationLog())
        try? FileManager.default.removeItem(at: dir)
    }
    func testStoredDataHoldsNoJobContent() throws {
        var log = UtilisationLog()
        log.record(at: base, runners: [("m4-runner", true)], queueLength: 2, longestWait: 90)
        let json = String(decoding: try JSONEncoder().encode(log), as: UTF8.self)
        XCTAssertTrue(json.contains("m4-runner"))
        for forbidden in ["repo", "branch", "workflow", "token", "http"] { XCTAssertFalse(json.contains(forbidden), forbidden) }
    }
    func testSummaryText() {
        var b = HourBucket(); b.total = ["a": 4]; b.busy = ["a": 3]; b.peakQueue = 5; b.longestWaitSeconds = 600
        XCTAssertEqual(CapacityView.summary(hours: [b, nil], runner: "a"), "75% busy")
        XCTAssertEqual(CapacityView.summary(hours: [nil], runner: "a"), "not seen")
        XCTAssertEqual(CapacityView.queueSummary([b]), "peak 5 queued · longest wait 10m")
    }
}

final class FreshnessTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000)
    func testStaleAfterThreeMissedPollsOrThreeIntervals() {
        XCTAssertFalse(Freshness.isStale(lastSuccess: now - 20, now: now, pollSeconds: 15, consecutiveFailures: 0))
        XCTAssertFalse(Freshness.isStale(lastSuccess: now - 44, now: now, pollSeconds: 15, consecutiveFailures: 2))
        XCTAssertTrue(Freshness.isStale(lastSuccess: now - 46, now: now, pollSeconds: 15, consecutiveFailures: 0))
        XCTAssertTrue(Freshness.isStale(lastSuccess: now - 5, now: now, pollSeconds: 15, consecutiveFailures: 3))
        XCTAssertFalse(Freshness.isStale(lastSuccess: nil, now: now, pollSeconds: 15, consecutiveFailures: 0))
        XCTAssertTrue(Freshness.isStale(lastSuccess: nil, now: now, pollSeconds: 15, consecutiveFailures: 3))
    }
    func testAgeText() {
        XCTAssertEqual(Freshness.ageText(lastSuccess: nil, now: now), "waiting for first update")
        XCTAssertEqual(Freshness.ageText(lastSuccess: now - 2, now: now), "updated just now")
        XCTAssertEqual(Freshness.ageText(lastSuccess: now - 40, now: now), "updated 40s ago")
        XCTAssertEqual(Freshness.ageText(lastSuccess: now - 125, now: now), "updated 2m ago")
    }
}

final class RateLimitTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000)
    func testRetryAfterWinsAndResetEpochWorks() {
        XCTAssertEqual(RateLimit.delay(retryAfter: "30", resetEpoch: "9999999999", now: now), 30)
        XCTAssertEqual(RateLimit.delay(retryAfter: nil, resetEpoch: "\(Int(now.timeIntervalSince1970) + 120)", now: now), 120)
        XCTAssertNil(RateLimit.delay(retryAfter: nil, resetEpoch: nil, now: now))
        XCTAssertNil(RateLimit.delay(retryAfter: "soon", resetEpoch: nil, now: now))
    }
    func testDelayIsCappedAndNeverNegative() {
        XCTAssertEqual(RateLimit.delay(retryAfter: "99999", resetEpoch: nil, now: now), 900)
        XCTAssertEqual(RateLimit.delay(retryAfter: nil, resetEpoch: "\(Int(now.timeIntervalSince1970) - 50)", now: now), 1)
    }
    func testOnlyBriefNetworkErrorsAreRetried() {
        XCTAssertTrue(RateLimit.isTransient(URLError(.timedOut)))
        XCTAssertTrue(RateLimit.isTransient(URLError(.networkConnectionLost)))
        XCTAssertFalse(RateLimit.isTransient(URLError(.badURL)))
        XCTAssertFalse(RateLimit.isTransient(GitHubError.unauthorized))
    }
    func testMessageNamesTheTime() {
        let msg = GitHubError.rateLimited(until: now).errorDescription!
        XCTAssertTrue(msg.hasPrefix("GitHub rate limit: next poll at "))
        XCTAssertEqual(GitHubError.rateLimited(until: nil).errorDescription, "GitHub rate limit reached")
    }
}

final class ConnectionReportTests: XCTestCase {
    func testHostLines() {
        XCTAssertTrue(ConnectionReport.host("mac-mini", error: nil, runners: 3).ok)
        XCTAssertEqual(ConnectionReport.host("mac-mini", error: nil, runners: 1).text, "mac-mini: reachable, 1 runner found.")
        XCTAssertFalse(ConnectionReport.host("mac-mini", error: nil, runners: 0).ok)
        let down = ConnectionReport.host("mac-mini", error: "timed out", runners: 0)
        XCTAssertFalse(down.ok); XCTAssertTrue(down.text.contains("SSH key login"))
    }
    func testRepoLinesNameWhatToFix() {
        XCTAssertTrue(ConnectionReport.repo("widgets", error: nil).ok)
        XCTAssertTrue(ConnectionReport.repo("widgets", error: GitHubError.http(403)).text.contains("Administration: read"))
        XCTAssertTrue(ConnectionReport.repo("widgets", error: GitHubError.http(404)).text.contains("not found"))
        XCTAssertTrue(ConnectionReport.repo("widgets", error: GitHubError.unauthorized).text.contains("rejected"))
        XCTAssertTrue(ConnectionReport.repo("widgets", error: GitHubError.rateLimited(until: nil)).text.contains("rate limit"))
    }
    func testAllOKAndNoSecretsInAnyLine() {
        var r = ConnectionReport(lines: [ConnectionReport.host("a", error: nil, runners: 1), ConnectionReport.repo("w", error: nil)])
        XCTAssertTrue(r.allOK)
        r.lines.append(ConnectionReport.noToken)
        XCTAssertFalse(r.allOK)
        XCTAssertFalse(ConnectionReport().allOK)
        let all = (r.lines.map(\.text) + [ConnectionReport.repo("w", error: GitHubError.unauthorized).text]).joined()
        for bad in ["ghp_", "github_pat_", "Bearer"] { XCTAssertFalse(all.contains(bad)) }
    }
}

final class RestartWatchTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 3_000_000)
    func obs(online: Bool) -> RunnerObservation {
        RunnerObservation(id: "a", arch: .arm64, cpus: 1, memoryGB: 1, vmRunning: true, ghOnline: online, busy: false,
                          job: nil, cpuPercent: 0, memUsedGB: 0, lastJobEndedAt: nil)
    }
    func state(online: Bool, since: TimeInterval) -> RunnerState {
        StateRules.derive(obs(online: online), intent: RunnerIntent(restartingSince: now - since), failureSeenAt: nil, now: now, stallThreshold: 600)
    }
    func testStaysRestartingUntilGitHubShowsItOnline() {
        XCTAssertEqual(state(online: false, since: 30), .restarting)
        XCTAssertEqual(state(online: false, since: 179), .restarting)
        XCTAssertEqual(state(online: true, since: 30), .idle)
    }
    func testGivesUpAfterThreeMinutesAndReadsOffline() {
        XCTAssertEqual(state(online: false, since: 180), .offline)
        XCTAssertEqual(state(online: false, since: 600), .offline)
    }
    func testComingBackLateIsStillFine() { XCTAssertEqual(state(online: true, since: 400), .idle) }
    func testTimeoutBoundary() {
        XCTAssertFalse(RestartWatch.timedOut(since: now - 179.9, now: now))
        XCTAssertTrue(RestartWatch.timedOut(since: now - 180, now: now))
    }
    func testFailedRestartCountsTowardTheBadge() {
        var r = Runner(id: "a", arch: .arm64, cpus: 1, memoryGB: 1, state: .offline)
        XCTAssertEqual(ProblemBadge.count([r]), 0)
        r.restartFailed = true
        XCTAssertEqual(ProblemBadge.count([r]), 1)
    }
}

@MainActor
final class HistoryFlushTests: XCTestCase {
    func testFlushWritesTheLatestReadingsAndDemoDoesNot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-flush-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("u.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = MonitorStore(backend: DemoBackend(scenario: .stalled))
        live.recordHistory = true
        live.flushHistory(to: url, failuresTo: dir.appendingPathComponent("f.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let demo = MonitorStore(backend: DemoBackend(scenario: .stalled))
        demo.recordHistory = false
        let other = dir.appendingPathComponent("none.json")
        demo.flushHistory(to: other, failuresTo: dir.appendingPathComponent("f2.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }
}

final class DiskRuleTests: XCTestCase {
    func testWarnsBelowTenGBOrAtNinetyPercent() {
        XCTAssertNil(DiskRule.warning(freeKB: 47_000_000, usedPct: 76))
        XCTAssertEqual(DiskRule.warning(freeKB: 3_832_728, usedPct: 81), "Disk low: 3.7 GB free")
        XCTAssertEqual(DiskRule.warning(freeKB: 50_000_000, usedPct: 90), "Disk 90% full")
        XCTAssertNil(DiskRule.warning(freeKB: 50_000_000, usedPct: 89))
        XCTAssertNotNil(DiskRule.warning(freeKB: 10_485_759, usedPct: 10))          // just under 10 GB
        XCTAssertNil(DiskRule.warning(freeKB: 10_485_760, usedPct: 10))             // exactly 10 GB is fine
        XCTAssertNil(DiskRule.warning(freeKB: nil, usedPct: 99))                    // unknown: say nothing
    }
    func testVMDiskIsNamedAsTheVMDisk() {
        XCTAssertEqual(DiskRule.warning(freeKB: 8_900_000, usedPct: 54, vm: true), "VM disk low: 8.5 GB free")
        XCTAssertEqual(DiskRule.warning(freeKB: 50_000_000, usedPct: 92, vm: true), "VM disk 92% full")
    }
    func testRunnersSharingADiskShowItsWarningOnlyOnce() async {
        func obs(_ id: String, host: String, free: Int) -> RunnerObservation {
            RunnerObservation(id: id, arch: .arm64, cpus: 2, memoryGB: 4, vmRunning: true, ghOnline: true, busy: false, host: host,
                              job: nil, cpuPercent: 1, memUsedGB: 1, lastJobEndedAt: nil, diskFreeKB: free, diskUsedPct: 54)
        }
        let snap = BackendSnapshot(runners: [obs("a", host: "box", free: 8_900_000), obs("b", host: "box", free: 8_900_000),
                                             obs("c", host: "other", free: 8_900_000)], queue: [])
        let s = await MainActor.run { () -> MonitorStore in let s = MonitorStore(backend: FakeBackend([.success(snap)])); s.recordHistory = false; return s }
        await s.refresh()
        let notes = await s.runners.sorted { $0.id < $1.id }.map { $0.notes.map(\.text) }
        XCTAssertEqual(notes[0], ["VM disk low: 8.5 GB free"])
        XCTAssertEqual(notes[1], [])                                           // same host, same figures
        XCTAssertEqual(notes[2], ["VM disk low: 8.5 GB free"])                  // a different host is its own disk
    }
    func testProbeLineCarriesDiskAndVersion() {
        let out = """
        H|vm
        D|2000
        R|/h/actions-runner|r1|https://github.com/o/r|1|1990|12.00|3832728|81|2.337.0
        R|/h/actions-runner-2|r2|https://github.com/o/r|0|none|none|||
        """
        let s = SnapshotParser.parseNative(out)!
        XCTAssertEqual(s.runners[0].diskFreeKB, 3_832_728); XCTAssertEqual(s.runners[0].diskUsedPct, 81)
        XCTAssertEqual(s.runners[0].version, "2.337.0")
        XCTAssertNil(s.runners[1].diskFreeKB); XCTAssertNil(s.runners[1].version)
    }
    func testNotesShowDiskFirstAndCapAtTwoOnTheCard() {
        var r = Runner(id: "a", arch: .arm64, cpus: 1, memoryGB: 1, state: .idle)
        r.diskFreeKB = 1_000_000; r.diskUsedPct = 95; r.failStreak = 4; r.longRunFactor = 2.4
        XCTAssertEqual(r.notes.map(\.text), ["Disk low: 1.0 GB free", "Failed 4 times in a row here", "Running 2.4x longer than usual"])
    }
}

final class VersionCheckTests: XCTestCase {
    func testParsesTagsAndCompares() {
        XCTAssertEqual(VersionCheck.parse("v2.338.0"), [2, 338, 0]); XCTAssertEqual(VersionCheck.parse("2.337.0"), [2, 337, 0])
        XCTAssertNil(VersionCheck.parse("latest")); XCTAssertNil(VersionCheck.parse(""))
        XCTAssertTrue(VersionCheck.isBehind(current: "2.337.0", latest: "v2.338.0"))
        XCTAssertTrue(VersionCheck.isBehind(current: "2.9.0", latest: "2.10.0"))              // numeric, not text, order
        XCTAssertFalse(VersionCheck.isBehind(current: "2.338.0", latest: "2.338.0"))
        XCTAssertFalse(VersionCheck.isBehind(current: "2.339.0", latest: "2.338.0"))
        XCTAssertFalse(VersionCheck.isBehind(current: "garbage", latest: "2.338.0"))
    }
    func testUpdateNoteIsMutedNotUrgent() {
        var r = Runner(id: "a", arch: .arm64, cpus: 1, memoryGB: 1, state: .idle)
        r.version = "2.337.0"; r.latestVersion = "2.338.0"
        XCTAssertEqual(r.notes, [Runner.Note(text: "Runner update available: 2.338.0", urgent: false, help: "GitHub Actions runner 2.337.0 is installed; 2.338.0 is the latest release")])
        r.version = "2.338.0"; XCTAssertTrue(r.notes.isEmpty)
    }
    func testRunnerUpdateIsQuietForTwoWeeksThenOverdue() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var r = Runner(id: "a", arch: .arm64, cpus: 1, memoryGB: 1, state: .idle)
        r.version = "2.337.0"; r.latestVersion = "2.338.0"
        r.latestPublished = now.addingTimeInterval(-10 * 86400)
        XCTAssertTrue(r.notes(now: now).isEmpty)                                    // still within the time a runner takes to update itself
        r.latestPublished = now.addingTimeInterval(-15 * 86400)
        XCTAssertEqual(r.notes(now: now).map(\.text), ["Runner update overdue: 2.338.0"])
        XCTAssertTrue(r.notes(now: now)[0].urgent)
        r.version = "2.338.0"; XCTAssertTrue(r.notes(now: now).isEmpty)             // caught up
    }
}

final class QuietHoursTests: XCTestCase {
    func q(_ h: Int, _ m: Int = 0, s: Int = 22, e: Int = 7, on: Bool = true) -> Bool {
        QuietHours.isQuiet(hour: h, minute: m, startHour: s, endHour: e, enabled: on)
    }
    func testWindowCrossingMidnight() {
        XCTAssertTrue(q(22)); XCTAssertTrue(q(23, 59)); XCTAssertTrue(q(0)); XCTAssertTrue(q(6, 59))
        XCTAssertFalse(q(7)); XCTAssertFalse(q(12)); XCTAssertFalse(q(21, 59))
    }
    func testSameDayWindowAndDisabledAndEmpty() {
        XCTAssertTrue(q(13, s: 12, e: 14)); XCTAssertFalse(q(14, s: 12, e: 14)); XCTAssertFalse(q(11, 59, s: 12, e: 14))
        XCTAssertFalse(q(23, on: false))
        XCTAssertFalse(q(3, s: 5, e: 5))                                  // start == end: no window
    }
}

final class JobHistoryTests: XCTestCase {
    let k = JobHistory.key(repo: "r", workflow: "w", job: "j")
    func testMedianNeedsFiveSamplesAndKeepsTwenty() {
        var h = JobHistory()
        for s in [100.0, 200, 300, 400] { h.recordSuccess(jobKey: k, runner: "a", seconds: s) }
        XCTAssertNil(h.median(jobKey: k))
        h.recordSuccess(jobKey: k, runner: "a", seconds: 500)
        XCTAssertEqual(h.median(jobKey: k), 300)
        for _ in 0..<30 { h.recordSuccess(jobKey: k, runner: "a", seconds: 100) }
        XCTAssertEqual(h.durations[k]?.count, 20); XCTAssertEqual(h.median(jobKey: k), 100)
    }
    func testLongRunNeedsTwiceTheMedianAndTenMinutes() {
        var h = JobHistory()
        for _ in 0..<5 { h.recordSuccess(jobKey: k, runner: "a", seconds: 400) }
        XCTAssertNil(h.longRunFactor(jobKey: k, elapsed: 700))            // not over 2x
        XCTAssertEqual(h.longRunFactor(jobKey: k, elapsed: 1000)!, 2.5, accuracy: 0.001)
        var quick = JobHistory(); for _ in 0..<5 { quick.recordSuccess(jobKey: k, runner: "a", seconds: 60) }
        XCTAssertNil(quick.longRunFactor(jobKey: k, elapsed: 300))        // over 2x but under ten minutes
        XCTAssertNil(JobHistory().longRunFactor(jobKey: k, elapsed: 5000)) // no history: silent
    }
    func testStreakAppearsAtThreeResetsOnSuccessAndIsPerRunner() {
        var h = JobHistory()
        h.recordFailure(jobKey: k, runner: "a"); h.recordFailure(jobKey: k, runner: "a")
        XCTAssertNil(h.streak(runner: "a"))
        h.recordFailure(jobKey: k, runner: "a"); XCTAssertEqual(h.streak(runner: "a"), 3)
        XCTAssertNil(h.streak(runner: "b")); XCTAssertNil(h.streak(runner: "aa"))     // prefix must not leak across runners
        h.recordSuccess(jobKey: k, runner: "a", seconds: 100); XCTAssertNil(h.streak(runner: "a"))
    }
    func testRoundTripHoldsOnlyNamesAndNumbers() throws {
        var h = JobHistory(); h.recordSuccess(jobKey: k, runner: "a", seconds: 12); h.recordFailure(jobKey: k, runner: "a")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-jobs-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("jobs.json"); defer { try? FileManager.default.removeItem(at: dir) }
        h.save(to: url); XCTAssertEqual(JobHistory.load(from: url), h)
        let json = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        for bad in ["token", "http", "Bearer", "log"] { XCTAssertFalse(json.contains(bad)) }
    }
}

// MARK: - Live-path tests: recorded (anonymised) GitHub responses through the real client, and the poll loop with a fake backend

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var headers: [String: String] = [:]; var body = "{}" }
    nonisolated(unsafe) static var replies: [String: Reply] = [:]          // "path?query" -> reply
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        let url = request.url!
        let key = url.path + (url.query.map { "?" + $0 } ?? "")
        let r = Self.replies[key] ?? Reply(status: 404, body: #"{"message":"Not Found"}"#)
        let resp = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(r.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: c)
    }
}

final class GitHubClientTests: XCTestCase {
    override func setUp() { StubURLProtocol.replies = [:]; StubURLProtocol.seen = [] }

    func testRunnersAndJobsThroughTheRealClient() async throws {
        StubURLProtocol.replies["/repos/example-org/widgets/actions/runners?per_page=100"] = .init(
            headers: ["GitHub-Authentication-Token-Expiration": "2027-01-12 14:14:01 UTC"],
            body: #"{"total_count":2,"runners":[{"name":"runner-a","status":"online","busy":true,"labels":[{"name":"self-hosted"},{"name":"ARM64"}]},{"name":"runner-b","status":"offline","busy":false,"labels":[{"name":"self-hosted"},{"name":"macbook-standby"}]}]}"#)
        StubURLProtocol.replies["/repos/example-org/widgets/actions/runs?per_page=20"] = .init(
            body: #"{"workflow_runs":[{"id":7,"name":"CI","run_number":12,"head_branch":"main","status":"in_progress","updated_at":"2026-10-14T10:00:00Z"},{"id":6,"name":"CI","run_number":11,"head_branch":"main","status":"completed","conclusion":"success","updated_at":"2026-10-14T09:00:00Z"}]}"#)
        StubURLProtocol.replies["/repos/example-org/widgets/actions/runs/7/jobs?per_page=100"] = .init(
            body: #"{"jobs":[{"id":70,"name":"unit","status":"in_progress","labels":["self-hosted","ARM64"],"runner_name":"runner-a","created_at":"2026-10-14T09:50:00Z","started_at":"2026-10-14T09:51:00Z","html_url":"https://github.com/example-org/widgets/actions/runs/7/job/70","steps":[{"number":1,"name":"Checkout","status":"completed","conclusion":"success"},{"number":2,"name":"Test","status":"in_progress"}]}]}"#)
        let gh = GitHubService(session: StubURLProtocol.session())

        let runners = try await gh.runners(owner: "example-org", repo: "widgets", token: "test-token")
        XCTAssertEqual(runners.map(\.name), ["runner-a", "runner-b"])
        XCTAssertTrue(runners[1].isStandby); XCTAssertTrue(runners[0].busy)

        let jobs = try await gh.jobs(owner: "example-org", repo: "widgets", token: "test-token", now: Date(timeIntervalSince1970: 1_792_000_000))
        XCTAssertEqual(jobs.count, 1)                                  // the completed success run is not fetched
        XCTAssertEqual(jobs[0].steps.map(\.name), ["Checkout", "Test"])
        XCTAssertEqual(GitHubLink.safe(jobs[0].htmlURL)?.host, "github.com")

        let exp = await gh.tokenExpiry()
        XCTAssertNotNil(exp)
        // The token goes only in the Authorization header, never in the URL.
        XCTAssertTrue(StubURLProtocol.seen.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
        XCTAssertTrue(StubURLProtocol.seen.allSatisfy { !($0.url!.absoluteString.contains("test-token")) })
    }

    func testStatusCodesMapToHelpfulErrors() async {
        let gh = GitHubService(session: StubURLProtocol.session())
        let path = "/repos/example-org/widgets/actions/runners?per_page=100"
        for (status, expect) in [(401, "rejected"), (403, "permission"), (404, "not found")] {
            StubURLProtocol.replies[path] = .init(status: status, body: "{}")
            do { _ = try await gh.runners(owner: "example-org", repo: "widgets", token: "t"); XCTFail("expected an error") }
            catch { XCTAssertTrue(((error as? LocalizedError)?.errorDescription ?? "").lowercased().contains(expect), "status \(status)") }
        }
    }

    func testRateLimitCarriesTheWaitFromTheHeaders() async {
        let gh = GitHubService(session: StubURLProtocol.session())
        let reset = Int(Date().timeIntervalSince1970) + 120
        StubURLProtocol.replies["/repos/example-org/widgets/actions/runners?per_page=100"] = .init(
            status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(reset)"], body: "{}")
        do { _ = try await gh.runners(owner: "example-org", repo: "widgets", token: "t"); XCTFail("expected a rate limit") }
        catch GitHubError.rateLimited(let until) {
            let wait = until!.timeIntervalSinceNow
            XCTAssertTrue(wait > 100 && wait <= 121, "wait was \(wait)")
        } catch { XCTFail("wrong error \(error)") }
    }

    func testLatestRunnerVersionIsCachedAndSendsNoToken() async {
        StubURLProtocol.replies["/repos/actions/runner/releases/latest"] = .init(body: #"{"tag_name":"v2.338.0","published_at":"2026-10-06T13:55:11Z"}"#)
        let gh = GitHubService(session: StubURLProtocol.session())
        let a = await gh.latestRunnerVersion(), b = await gh.latestRunnerVersion()
        XCTAssertEqual(a, "2.338.0"); XCTAssertEqual(b, "2.338.0")
        let rel = await gh.latestRunnerRelease()
        XCTAssertEqual(rel?.published, ISO8601DateFormatter().date(from: "2026-10-06T13:55:11Z"))
        XCTAssertEqual(StubURLProtocol.seen.count, 1)                       // second call served from the cache
        XCTAssertNil(StubURLProtocol.seen[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testAnUnreadableLatestVersionIsIgnored() async {
        StubURLProtocol.replies["/repos/actions/runner/releases/latest"] = .init(body: #"{"tag_name":"nightly"}"#)
        let v = await GitHubService(session: StubURLProtocol.session()).latestRunnerVersion()
        XCTAssertNil(v)
    }
}

final class FakeBackend: MonitorBackend, @unchecked Sendable {
    nonisolated(unsafe) var script: [Result<BackendSnapshot, Error>]
    nonisolated(unsafe) private(set) var polls = 0
    init(_ script: [Result<BackendSnapshot, Error>]) { self.script = script }
    func poll(config: Config) async throws -> BackendSnapshot {
        polls += 1
        let r = script.isEmpty ? .failure(URLError(.badServerResponse)) : script.removeFirst()
        return try r.get()
    }
    func restart(_ id: String, config: Config) async throws {}
    func setRunnerService(_ id: String, running: Bool, config: Config) async throws {}
    func diagnose(config: Config) async -> ConnectionReport { ConnectionReport() }
}

@MainActor
final class PollLoopTests: XCTestCase {
    func snapshot(_ ids: [String] = ["runner-a"]) -> BackendSnapshot {
        BackendSnapshot(runners: ids.map {
            RunnerObservation(id: $0, arch: .arm64, cpus: 2, memoryGB: 4, vmRunning: true, ghOnline: true, busy: false,
                              job: nil, cpuPercent: 3, memUsedGB: 1, lastJobEndedAt: nil)
        }, queue: [])
    }
    func store(_ b: FakeBackend) -> MonitorStore { let s = MonitorStore(backend: b); s.recordHistory = false; return s }

    func testSuccessThenFailuresGoStaleThenRecover() async {
        let b = FakeBackend([.success(snapshot()), .failure(GitHubError.http(500)), .failure(GitHubError.http(500)), .failure(GitHubError.http(500)),
                             .success(snapshot())])
        let s = store(b)
        await s.refresh()
        XCTAssertEqual(s.runners.map(\.id), ["runner-a"]); XCTAssertNotNil(s.lastSuccess); XCTAssertFalse(s.isStale())
        for _ in 0..<2 { await s.refresh() }
        XCTAssertEqual(s.consecutiveFailures, 2); XCTAssertFalse(s.isStale())
        XCTAssertEqual(s.runners.map(\.id), ["runner-a"], "old data stays visible while polls fail")
        await s.refresh()
        XCTAssertEqual(s.consecutiveFailures, 3); XCTAssertTrue(s.isStale())
        await s.refresh()
        XCTAssertEqual(s.consecutiveFailures, 0); XCTAssertFalse(s.isStale()); XCTAssertNil(s.errorMessage)
    }

    func testABriefNetworkErrorIsRetriedOnce() async {
        let b = FakeBackend([.failure(URLError(.timedOut)), .success(snapshot())])
        let s = store(b)
        await s.refresh()
        XCTAssertEqual(b.polls, 2); XCTAssertEqual(s.consecutiveFailures, 0); XCTAssertNotNil(s.lastSuccess)
    }

    func testANonTransientErrorIsNotRetriedAndIsShown() async {
        let b = FakeBackend([.failure(GitHubError.unauthorized)])
        let s = store(b)
        await s.refresh()
        XCTAssertEqual(b.polls, 1); XCTAssertEqual(s.consecutiveFailures, 1); XCTAssertEqual(s.errorMessage, "GitHub rejected the token")
    }

    func testRateLimitIsReportedWithTheTime() async {
        let b = FakeBackend([.failure(GitHubError.rateLimited(until: Date().addingTimeInterval(300)))])
        let s = store(b)
        await s.refresh()
        XCTAssertTrue(s.errorMessage?.hasPrefix("GitHub rate limit: next poll at") == true)
    }

    func testUnreachableHostKeepsItsRunnersGreyedThenRecovers() async {
        var first = snapshot(["a", "b"])
        first.runners[1].host = "far-host"
        var second = snapshot(["a"]); second.unreachable = ["far-host"]
        var third = snapshot(["a", "b"]); third.runners[1].host = "far-host"
        let s = store(FakeBackend([.success(first), .success(second), .success(third)]))
        await s.refresh(); await s.refresh()
        XCTAssertEqual(s.runners.first { $0.id == "b" }?.state, .unreachable)
        await s.refresh()
        XCTAssertEqual(s.runners.first { $0.id == "b" }?.state, .idle)
    }
}

final class ChunkTests: XCTestCase {
    func testChunksOfThreeKeepOrderAndTheShortLastRow() {
        XCTAssertEqual([1, 2, 3, 4, 5].chunked(into: 3), [[1, 2, 3], [4, 5]])
        XCTAssertEqual([1, 2, 3].chunked(into: 3), [[1, 2, 3]])
        XCTAssertEqual([Int]().chunked(into: 3), [])
        XCTAssertEqual([1, 2].chunked(into: 0), [])
    }
}

final class FailureLogTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func rec(_ id: Int, runner: String = "a", step: String? = "Checkout", at: Date? = nil) -> FailureRecord {
        FailureRecord(jobID: id, runner: runner, repo: "widgets", workflow: "CI", job: "unit", stepName: step, stepNumber: 2, at: at ?? t0, url: "https://github.com/example-org/widgets/actions/runs/1/job/\(id)")
    }
    func testRecordedOnceHoweverManyPollsSeeIt() {
        var log = FailureLog()
        XCTAssertTrue(log.record(rec(1), now: t0)); XCTAssertFalse(log.record(rec(1), now: t0 + 15)); XCTAssertFalse(log.record(rec(1), now: t0 + 30))
        XCTAssertEqual(log.entries.count, 1)
    }
    func testNewestFirstAndFilterByRunner() {
        var log = FailureLog()
        log.record(rec(1, runner: "a", at: t0 - 100), now: t0); log.record(rec(2, runner: "b", at: t0 - 10), now: t0); log.record(rec(3, runner: "a", at: t0 - 50), now: t0)
        XCTAssertEqual(log.recent(10).map(\.jobID), [2, 3, 1])
        XCTAssertEqual(log.recent(10, runner: "a").map(\.jobID), [3, 1])
        XCTAssertEqual(log.recent(1).map(\.jobID), [2])
    }
    func testRetentionThirtyDaysAndTwoHundredEntries() {
        var log = FailureLog()
        log.record(rec(1, at: t0 - 31 * 86_400), now: t0)
        XCTAssertTrue(log.entries.isEmpty, "older than 30 days is dropped")
        log.record(rec(2, at: t0 - 29 * 86_400), now: t0)
        XCTAssertEqual(log.entries.count, 1)
        for i in 100..<400 { log.record(rec(i, at: t0 - Double(i)), now: t0) }
        XCTAssertEqual(log.entries.count, 200)
        XCTAssertEqual(log.entries.first?.jobID, 100, "the newest are the ones kept")
    }
    func testReasonFallsBackToTheStepNumber() {
        XCTAssertEqual(rec(1).reason, "Checkout")
        XCTAssertEqual(rec(1, step: nil).reason, "step 2")
        var r = rec(1, step: ""); r.stepNumber = nil
        XCTAssertEqual(r.reason, "unknown step")
        XCTAssertEqual(rec(1).title, "CI / unit")
        var same = rec(1); same.job = "CI"; XCTAssertEqual(same.title, "CI")
    }
    func testRoundTripAndWhatIsStored() throws {
        var log = FailureLog(); log.record(rec(1), now: t0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-fail-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("failures.json"); defer { try? FileManager.default.removeItem(at: dir) }
        log.save(to: url); XCTAssertEqual(FailureLog.load(from: url, now: t0), log)
        XCTAssertEqual(FailureLog.load(from: dir.appendingPathComponent("none.json"), now: t0), FailureLog())
        let json = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        for bad in ["token", "Bearer", "output", "log"] { XCTAssertFalse(json.contains(bad), bad) }
        XCTAssertTrue(json.contains("Checkout"))
    }
    func testStoreRecordsAFailureFromAPollOnlyOnce() async {
        let job = ActiveJob(id: 55, repo: "widgets", workflow: "CI", runNumber: 1, branch: "main", totalSteps: 5, currentStep: 2,
                            startedAt: Date().addingTimeInterval(-300), lastOutputAt: Date().addingTimeInterval(-60), failedStep: 2, exitCode: nil,
                            failedStepName: "Checkout", url: nil, jobName: "unit")
        let obs = RunnerObservation(id: "runner-a", arch: .arm64, cpus: 2, memoryGB: 4, vmRunning: true, ghOnline: true, busy: false,
                                    job: job, cpuPercent: 1, memUsedGB: 1, lastJobEndedAt: nil)
        let snap = BackendSnapshot(runners: [obs], queue: [])
        let s = await MainActor.run { () -> MonitorStore in let s = MonitorStore(backend: FakeBackend([.success(snap), .success(snap), .success(snap)])); s.recordHistory = false; return s }
        for _ in 0..<3 { await s.refresh() }
        // The store also loads the real failures file from this Mac, so look only at this test's job.
        let entries = await s.failures.entries.filter { $0.jobID == 55 }
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries.first?.stepName, "Checkout"); XCTAssertEqual(entries.first?.runner, "runner-a")
    }
}

final class LocalNetworkTests: XCTestCase {
    func testWhichAddressesTheMacOSPermissionCovers() {
        for h in ["192.168.4.100", "10.0.0.5", "172.16.0.1", "172.31.255.1", "169.254.1.1", "mac-mini.local", "nas.home.arpa", "box.LAN"] {
            XCTAssertTrue(LocalNetwork.isLocalAddress(h), h)
        }
        for h in ["172.15.0.1", "172.32.0.1", "8.8.8.8", "build.example.com", "300.1.1.1", ""] {
            XCTAssertFalse(LocalNetwork.isLocalAddress(h), h)
        }
    }
    func testUserIsStrippedFromTheTarget() {
        XCTAssertEqual(LocalNetwork.hostName(fromTarget: "me@mac-mini.local"), "mac-mini.local")
        XCTAssertEqual(LocalNetwork.hostName(fromTarget: "192.168.4.100"), "192.168.4.100")
    }
    func testNoRouteToALocalHostPointsAtThePermission() {
        let p = LocalNetwork.explain(target: "192.168.4.100", reason: "ssh: connect to host 192.168.4.100 port 22: No route to host")
        XCTAssertTrue(p.needsLocalNetwork)
        XCTAssertTrue(p.message.contains("Local Network")); XCTAssertTrue(p.message.contains("192.168.4.100"))
    }
    func testOtherFailuresKeepTheirRealText() {
        let off = LocalNetwork.explain(target: "192.168.4.100", reason: "ssh: connect to host 192.168.4.100 port 22: Operation timed out")
        XCTAssertFalse(off.needsLocalNetwork); XCTAssertTrue(off.message.contains("Operation timed out"))
        let key = LocalNetwork.explain(target: "me@mac-mini.local", reason: "Permission denied (publickey)")
        XCTAssertFalse(key.needsLocalNetwork); XCTAssertTrue(key.message.contains("Permission denied"))
        let remote = LocalNetwork.explain(target: "build.example.com", reason: "No route to host")
        XCTAssertFalse(remote.needsLocalNetwork, "a public host is not governed by the Local Network permission")
        XCTAssertEqual(LocalNetwork.explain(target: "x", reason: "").message, "x unreachable")
    }
    func testSettingsLinkIsTheSystemPane() {
        XCTAssertEqual(LocalNetwork.settingsURL.scheme, "x-apple.systempreferences")
        XCTAssertTrue(LocalNetwork.settingsURL.absoluteString.contains("Privacy_LocalNetwork"))
    }
    func testPrimingReturnsPromptlyEvenWhenNothingAnswers() async {
        let start = Date()
        await LocalNetwork.prime(target: "192.0.2.1", timeout: 1)         // documentation address: never answers
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}

final class WelcomeTests: XCTestCase {
    func testShownOnceThenNever() {
        let d = UserDefaults(suiteName: "hangar-welcome-\(UUID().uuidString)")!
        XCTAssertTrue(Welcome.shouldShow(d))
        Welcome.dismiss(d)
        XCTAssertFalse(Welcome.shouldShow(d))
    }
    func testTextNamesBothPermissions() {
        XCTAssertTrue(Welcome.text.contains("Notifications")); XCTAssertTrue(Welcome.text.contains("Local Network"))
    }
}

final class UpdateCheckTests: XCTestCase {
    let page = "https://github.com/rsutcliffe/Hangar/releases/tag/v0.1.3"
    func data(_ s: String) -> Data { Data(s.utf8) }

    func testParsesALatestRelease() {
        let r = GitHubService.parseAppRelease(data(#"{"tag_name":"v0.1.3","name":"Hangar 0.1.3: Test","html_url":"\#(page)","draft":false,"prerelease":false}"#))
        XCTAssertEqual(r?.version, "0.1.3"); XCTAssertEqual(r?.url.absoluteString, page)
    }
    func testRejectsDraftsPrereleasesBadTagsAndForeignLinks() {
        XCTAssertNil(GitHubService.parseAppRelease(data(#"{"tag_name":"v0.1.3","html_url":"\#(page)","draft":true}"#)))
        XCTAssertNil(GitHubService.parseAppRelease(data(#"{"tag_name":"v0.1.3","html_url":"\#(page)","prerelease":true}"#)))
        XCTAssertNil(GitHubService.parseAppRelease(data(#"{"tag_name":"nightly","html_url":"\#(page)"}"#)))
        XCTAssertNil(GitHubService.parseAppRelease(data(#"{"tag_name":"v0.1.3","html_url":"https://evil.example/x"}"#)))
        XCTAssertNil(GitHubService.parseAppRelease(data("not json")))
    }
    func testOnlyANewerReleaseIsOffered() {
        let r = AppRelease(version: "0.1.3", name: "", url: URL(string: page)!)
        XCTAssertEqual(AppInfo.update(current: "0.1.2", latest: r)?.version, "0.1.3")
        XCTAssertNil(AppInfo.update(current: "0.1.3", latest: r))
        XCTAssertNil(AppInfo.update(current: "0.2.0", latest: r))
        XCTAssertNil(AppInfo.update(current: "0.1.2", latest: nil))
        XCTAssertEqual(AppInfo.update(current: "0.1.9", latest: AppRelease(version: "0.1.10", name: "", url: URL(string: page)!))?.version, "0.1.10")
    }
    func testOnByDefaultAndSwitchedOffInSettings() {
        let d = UserDefaults(suiteName: "hangar-upd-\(UUID().uuidString)")!
        XCTAssertTrue(Config.load(d).checkUpdates)
        d.set(false, forKey: Config.Key.checkUpdates)
        XCTAssertFalse(Config.load(d).checkUpdates)
    }
    func testClientFetchesCachesAndSendsNoToken() async {
        StubURLProtocol.replies = [:]; StubURLProtocol.seen = []
        StubURLProtocol.replies["/repos/rsutcliffe/Hangar/releases/latest"] = .init(body: #"{"tag_name":"v0.1.3","html_url":"\#(page)"}"#)
        let gh = GitHubService(session: StubURLProtocol.session())
        let a = await gh.latestAppRelease(), b = await gh.latestAppRelease()
        XCTAssertEqual(a?.version, "0.1.3"); XCTAssertEqual(b, a)
        XCTAssertEqual(StubURLProtocol.seen.count, 1, "second call is served from the cache")
        XCTAssertNil(StubURLProtocol.seen[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testOutputFromBeforeTheJobStartedDoesNotCountAsItsOutput() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let j = GHJob(id: 1, runId: 1, repo: "r", workflow: "W", runNumber: 1, branch: "main", status: "in_progress", conclusion: nil,
                      labels: [], runnerName: "a", createdAt: start, startedAt: start, completedAt: nil, steps: [])
        // The runner's newest log is the previous job's, written an hour before this one began.
        XCTAssertEqual(LiveBackend.activeJob(j, lastOutput: start.addingTimeInterval(-3600)).lastOutputAt, start)
        XCTAssertEqual(LiveBackend.activeJob(j, lastOutput: start.addingTimeInterval(90)).lastOutputAt, start.addingTimeInterval(90))
        XCTAssertEqual(LiveBackend.activeJob(j, lastOutput: nil).lastOutputAt, start)
    }

    func testFailureTimeShowsTheDateAndTime() {
        let d = Date(timeIntervalSince1970: 1_792_470_000)            // 2026-10-20 04:20 UTC
        let utc = TimeZone(identifier: "UTC")!, gb = Locale(identifier: "en_GB")
        XCTAssertEqual(Format.shortDateTime(d, locale: gb, timeZone: utc), "20 Oct at 04:20")
    }

    func testHostMemoryParsesSysctlOutput() {
        let m = HostMemory.parse("1\nvm.swapusage: total = 5120.00M  used = 4172.31M  free = 947.69M  (encrypted)\n17179869184\n")!
        XCTAssertEqual(m.pressureLevel, 1); XCTAssertEqual(m.swapTotalMB, 5120, accuracy: 0.01)
        XCTAssertEqual(m.swapUsedMB, 4172.31, accuracy: 0.01); XCTAssertEqual(m.ramGB, 16, accuracy: 0.001)
        XCTAssertEqual(HostMemory.parse("1\ntotal = 2.00G  used = 1.00G  free = 1.00G\n8589934592")?.swapTotalMB, 2048)
        XCTAssertNil(HostMemory.parse("")); XCTAssertNil(HostMemory.parse("x\ny\nz"))
        let withName = "1\ntotal = 1024.00M  used = 497.00M  free = 527.00M  (encrypted)\n17179869184\niMac.local\n"
        XCTAssertEqual(HostMemory.parseName(withName), "iMac.local"); XCTAssertEqual(SnapshotParser.shortName(HostMemory.parseName(withName)!), "iMac")
        XCTAssertNil(HostMemory.parseName("1\ntotal = 1.00M  used = 1.00M  free = 0.00M\n1024\n"))
    }
    func testMemoryRuleWarnsOnPressureOrMostlyFullSwap() {
        func m(_ level: Int, _ used: Double, _ total: Double) -> HostMemory { HostMemory(pressureLevel: level, swapUsedMB: used, swapTotalMB: total, ramGB: 16) }
        XCTAssertNil(MemoryRule.warning(nil))
        XCTAssertNil(MemoryRule.warning(m(1, 500, 5120)))                          // swap barely used
        XCTAssertNil(MemoryRule.warning(m(1, 1500, 2000)))                         // mostly full but small: nothing to worry about
        XCTAssertEqual(MemoryRule.warning(m(1, 4172, 5120))?.text, "Mac swap 81% full")
        XCTAssertEqual(MemoryRule.warning(m(2, 0, 0))?.text, "Mac memory pressure: high")
        XCTAssertEqual(MemoryRule.warning(m(4, 0, 0))?.text, "Mac memory pressure: critical")
    }
    func testMemoryNoteShowsOnOneRunnerPerHostWhateverTheProbeOrder() async {
        func obs(_ id: String) -> RunnerObservation {
            RunnerObservation(id: id, arch: .arm64, cpus: 2, memoryGB: 4, vmRunning: true, ghOnline: true, busy: false, host: "box",
                              job: nil, cpuPercent: 1, memUsedGB: 1, lastJobEndedAt: nil,
                              hostMemory: HostMemory(pressureLevel: 2, swapUsedMB: 4000, swapTotalMB: 5000, ramGB: 16))
        }
        for order in [["b", "a", "c"], ["c", "a", "b"]] {
            let snap = BackendSnapshot(runners: order.map(obs), queue: [])
            let s = await MainActor.run { () -> MonitorStore in let s = MonitorStore(backend: FakeBackend([.success(snap)])); s.recordHistory = false; s.memorySustain = 0; return s }
            await s.refresh()
            let withNote = await s.runners.filter { !$0.notes.filter { $0.text.hasPrefix("Mac memory") }.isEmpty }.map(\.id)
            XCTAssertEqual(withNote, ["a"])
        }
    }

    func testFailureStreakLeavesTheMainWindowAnHourAfterTheLastFailure() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(StreakRule.shown(10, lastFailure: now.addingTimeInterval(-59 * 60), now: now), 10)
        XCTAssertEqual(StreakRule.shown(10, lastFailure: now.addingTimeInterval(-3600), now: now), 10)     // exactly an hour: still shown
        XCTAssertNil(StreakRule.shown(10, lastFailure: now.addingTimeInterval(-3601), now: now))
        XCTAssertNil(StreakRule.shown(10, lastFailure: nil, now: now))                                       // no recorded failure: not current
        XCTAssertNil(StreakRule.shown(nil, lastFailure: now, now: now))
        var log = FailureLog()
        func rec(_ id: Int, _ runner: String, _ ago: TimeInterval) -> FailureRecord {
            FailureRecord(jobID: id, runner: runner, repo: "r", workflow: "W", job: "j", stepName: nil, stepNumber: nil, at: now.addingTimeInterval(-ago), url: nil)
        }
        log.record(rec(1, "a", 7200), now: now); log.record(rec(2, "a", 600), now: now); log.record(rec(3, "b", 90_000), now: now)
        XCTAssertEqual(log.lastFailure(runner: "a"), now.addingTimeInterval(-600))
        XCTAssertNil(log.lastFailure(runner: "c"))
    }

    func testThrottleHoldsIdleRunnersOnlyWhileAnotherJobRunsUnderPressure() {
        func c(_ id: String, busy: Bool = false, held: Bool = false) -> ThrottleRule.Candidate { .init(id: id, busy: busy, canHold: !busy && !held, held: held) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // Pressure with one job running: the idle ones wait, the busy one is not touched.
        XCTAssertEqual(ThrottleRule.decide([c("a", busy: true), c("b"), c("c")], protect: true, underPressure: true, calmSince: nil, now: now).hold, ["b", "c"])
        // Switched off, or no pressure, or nothing running: nothing is held.
        XCTAssertTrue(ThrottleRule.decide([c("a", busy: true), c("b")], protect: false, underPressure: true, calmSince: nil, now: now).hold.isEmpty)
        XCTAssertTrue(ThrottleRule.decide([c("a", busy: true), c("b")], protect: true, underPressure: false, calmSince: now, now: now).hold.isEmpty)
        XCTAssertTrue(ThrottleRule.decide([c("a"), c("b")], protect: true, underPressure: true, calmSince: nil, now: now).hold.isEmpty)
    }
    func testThrottleReleasesAfterFiveCalmMinutesOrWhenNothingRuns() {
        func c(_ id: String, busy: Bool = false, held: Bool = false) -> ThrottleRule.Candidate { .init(id: id, busy: busy, canHold: false, held: held) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let held = [c("a", busy: true), c("b", held: true)]
        XCTAssertTrue(ThrottleRule.decide(held, protect: true, underPressure: true, calmSince: nil, now: now).release.isEmpty)               // still pressured, job still running
        XCTAssertTrue(ThrottleRule.decide(held, protect: true, underPressure: false, calmSince: now.addingTimeInterval(-299), now: now).release.isEmpty)
        XCTAssertEqual(ThrottleRule.decide(held, protect: true, underPressure: false, calmSince: now.addingTimeInterval(-300), now: now).release, ["b"])
        XCTAssertEqual(ThrottleRule.decide([c("a"), c("b", held: true)], protect: true, underPressure: true, calmSince: nil, now: now).release, ["b"])   // nothing running: do not strand queued work
        XCTAssertEqual(ThrottleRule.decide(held, protect: false, underPressure: true, calmSince: nil, now: now).release, ["b"])                         // setting switched off
    }
    func testStoreHoldsAnIdleRunnerUnderPressureAndNeverTouchesABusyOne() async {
        UserDefaults.standard.set(true, forKey: Config.Key.protectJobs); defer { UserDefaults.standard.removeObject(forKey: Config.Key.protectJobs) }
        func obs(_ id: String, busy: Bool) -> RunnerObservation {
            RunnerObservation(id: id, arch: .arm64, cpus: 2, memoryGB: 4, vmRunning: true, ghOnline: true, busy: busy, host: "box",
                              job: nil, cpuPercent: 1, memUsedGB: 1, lastJobEndedAt: nil,
                              hostMemory: HostMemory(pressureLevel: 2, swapUsedMB: 4000, swapTotalMB: 5000, ramGB: 16))
        }
        let snap = BackendSnapshot(runners: [obs("a", busy: true), obs("b", busy: false)], queue: [])
        let backend = FakeBackend([.success(snap)])
        let s = await MainActor.run { () -> MonitorStore in let s = MonitorStore(backend: backend); s.recordHistory = false; s.memorySustain = 0; return s }
        await s.refresh()
        let held = await s.runners.filter(\.held).map(\.id)
        XCTAssertEqual(held, ["b"])
    }

    func testARepeatOfTheSameFailingJobIsQuiet() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func rec(_ id: Int, _ runner: String, _ job: String, _ ago: TimeInterval) -> FailureRecord {
            FailureRecord(jobID: id, runner: runner, repo: "r", workflow: "CI", job: job, stepName: nil, stepNumber: nil, at: now.addingTimeInterval(-ago), url: nil)
        }
        var log = FailureLog()
        XCTAssertFalse(log.isRepeat(rec(1, "a", "e2e", 0)))                              // the first failure still alerts
        log.record(rec(1, "a", "e2e", 3600), now: now)
        XCTAssertTrue(log.isRepeat(rec(2, "a", "e2e", 0)))                               // an hour later, same job: quiet
        XCTAssertTrue(log.isRepeat(rec(3, "b", "e2e", 0)))                               // on another runner too
        XCTAssertFalse(log.isRepeat(rec(4, "a", "unit", 0)))                             // a different job alerts
        log.record(rec(5, "a", "e2e", 4 * 3600 + 1), now: now)
        XCTAssertFalse(FailureLog().isRepeat(rec(6, "a", "e2e", 0)))
        var old = FailureLog(); old.record(rec(7, "a", "e2e", 4 * 3600), now: now)
        XCTAssertFalse(old.isRepeat(rec(8, "a", "e2e", 0)))                              // last failure 4h ago: the incident is over, alert again
        XCTAssertFalse(log.isRepeat(rec(1, "a", "e2e", 3600)))                           // a job is never a repeat of itself
    }

    func testNotifyGateCooldownBurstCapAndPersistence() throws {
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        var g = NotifyGate()
        XCTAssertEqual(g.allow("a", cooldown: 3600, now: t0), .send)
        XCTAssertEqual(g.allow("a", cooldown: 3600, now: t0.addingTimeInterval(3599)), .suppressed)      // same thing, inside the cooldown
        XCTAssertEqual(g.allow("a", cooldown: 3600, now: t0.addingTimeInterval(3601)), .send)            // after it
        // Persisted: a reopened Hangar still knows what it said.
        var reopened = try JSONDecoder().decode(NotifyGate.self, from: JSONEncoder().encode(g))
        XCTAssertEqual(reopened.allow("a", cooldown: 3600, now: t0.addingTimeInterval(3700)), .suppressed)
        // Burst cap: four go out in ten minutes, the rest fold into one summary.
        var b = NotifyGate()
        for k in 0..<4 { XCTAssertEqual(b.allow("k\(k)", cooldown: 60, now: t0), .send) }
        XCTAssertEqual(b.allow("k4", cooldown: 60, now: t0), .burst(needsSummary: true))
        XCTAssertEqual(b.allow("k5", cooldown: 60, now: t0.addingTimeInterval(1)), .burst(needsSummary: false))
        XCTAssertEqual(b.allow("k6", cooldown: 60, now: t0.addingTimeInterval(601)), .send)               // the window has passed
        XCTAssertEqual(b.allow("k4", cooldown: 3600, now: t0.addingTimeInterval(700)), .suppressed)       // a folded alert is not repeated later
    }

    func testAShortMemoryWarningIsNotReportedUntilItHasLasted() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let warn = HostMemory(pressureLevel: 2, swapUsedMB: 100, swapTotalMB: 5000, ramGB: 16)
        XCTAssertEqual(MemoryRule.debounced(warn, since: nil, now: now)?.pressureLevel, 1)                                  // first sighting
        XCTAssertEqual(MemoryRule.debounced(warn, since: now.addingTimeInterval(-299), now: now)?.pressureLevel, 1)        // under 5 minutes
        XCTAssertEqual(MemoryRule.debounced(warn, since: now.addingTimeInterval(-300), now: now)?.pressureLevel, 2)        // sustained
        let ok = HostMemory(pressureLevel: 1, swapUsedMB: 100, swapTotalMB: 5000, ramGB: 16)
        XCTAssertEqual(MemoryRule.debounced(ok, since: now.addingTimeInterval(-3600), now: now), ok)
        XCTAssertNil(MemoryRule.debounced(nil, since: nil, now: now))
        // Through the store with the real five-minute rule: a first poll at level 2 says nothing yet.
        func obs(_ id: String) -> RunnerObservation {
            RunnerObservation(id: id, arch: .arm64, cpus: 2, memoryGB: 4, vmRunning: true, ghOnline: true, busy: false, host: "box",
                              job: nil, cpuPercent: 1, memUsedGB: 1, lastJobEndedAt: nil, hostMemory: warn)
        }
        let snap = BackendSnapshot(runners: [obs("a")], queue: [])
        let s = await MainActor.run { () -> MonitorStore in let s = MonitorStore(backend: FakeBackend([.success(snap)])); s.recordHistory = false; return s }
        await s.refresh()
        let notes = await s.runners.flatMap { $0.notes.map(\.text) }
        XCTAssertFalse(notes.contains { $0.hasPrefix("Mac memory") }, "\(notes)")
    }
}
