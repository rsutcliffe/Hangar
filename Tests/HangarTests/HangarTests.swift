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
    func testAssembleMatchesRunnerByExactName() {
        var c = Config(); c.profiles = ["default"]
        let now = Date()
        let job = GHJob(id: 1, runId: 9, repo: "hoci", workflow: "build", runNumber: 482, branch: "main", status: "in_progress", conclusion: nil,
                        labels: ["self-hosted"], runnerName: "colima-scoreview-ci", createdAt: now, startedAt: now, completedAt: nil,
                        steps: [.init(number: 1, status: "in_progress", conclusion: nil)])
        let facts = [RunnerFacts(dir: "/h/actions-runner-hoci", name: "colima-scoreview-ci", owner: "rsutcliffe", repo: "hoci", listenerRunning: true, lastOutputAt: now),
                     RunnerFacts(dir: "/h/actions-runner", name: "colima-tenantsafe-ci", owner: "rsutcliffe", repo: "TenantShield", listenerRunning: false, lastOutputAt: nil)]
        let snap = LiveBackend.assemble(config: c, vms: ["default": VMInfo(running: true, arch: .arm64, cpus: 6, memoryGB: 8)],
                                        snaps: ["default": VMSnapshot(cpuPercent: 12, memUsedGB: 3, runners: facts)],
                                        runners: [GHRunner(name: "colima-scoreview-ci", online: true, busy: true, labels: [])], jobs: [job], now: now)
        XCTAssertEqual(snap.runners.map(\.id), ["colima-scoreview-ci", "colima-tenantsafe-ci"])
        XCTAssertEqual(snap.runners[0].job?.id, 1)
        XCTAssertFalse(snap.runners[1].listenerRunning)
        XCTAssertNil(snap.runners[1].job)
    }
}

final class VMSnapshotParserTests: XCTestCase {
    func testParse() {
        let out = """
        cpu  200 0 200 1400 200 0 0 0 0 0
        ---
        MemTotal:        8388608 kB
        MemAvailable:    3145728 kB
        ---
        1000
        R|/home/u/actions-runner-hoci|colima-scoreview-ci|https://github.com/rsutcliffe/hoci|1|940
        R|/home/u/actions-runner|colima-tenantsafe-ci|https://github.com/rsutcliffe/TenantShield|0|none

        """
        let prev = ProcParser.cpuTimes(fromStatLine: "cpu  100 0 100 700 100 0 0 0 0 0")
        let (snap, _) = VMSnapshotParser.parse(out, prevCPU: prev)!
        XCTAssertEqual(snap.cpuPercent, 20, accuracy: 0.01)
        XCTAssertEqual(snap.memUsedGB, 5, accuracy: 0.001)
        XCTAssertEqual(snap.runners.map(\.name), ["colima-scoreview-ci", "colima-tenantsafe-ci"])
        XCTAssertEqual(snap.runners[0].repo, "hoci"); XCTAssertTrue(snap.runners[0].listenerRunning)
        XCTAssertEqual(snap.runners[0].lastOutputAt!.timeIntervalSinceNow, -60, accuracy: 2)
        XCTAssertNil(snap.runners[1].lastOutputAt); XCTAssertFalse(snap.runners[1].listenerRunning)
        XCTAssertNil(VMSnapshotParser.ownerRepo(fromURL: "https://github.com/a;b/c"))
    }
}

final class ConfigTests: XCTestCase {
    func testSafety() {
        XCTAssertTrue(Config.isSafeName("arm-01")); XCTAssertFalse(Config.isSafeName("a;rm -rf /"))
        XCTAssertTrue(Config.isSafePath("~/actions-runner")); XCTAssertFalse(Config.isSafePath("~/a b; ls")); XCTAssertFalse(Config.isSafePath("../x"))
        XCTAssertEqual(Config.list("a, b c\nd"), ["a", "b", "c", "d"])
        XCTAssertEqual(Config().profiles, ["default"])
    }
}
