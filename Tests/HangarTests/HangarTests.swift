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
