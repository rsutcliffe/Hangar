import AppKit
import Foundation
import Observation

@Observable @MainActor
final class MonitorStore {
    private(set) var runners: [Runner] = []
    private(set) var queue: [QueuedJob] = []
    private(set) var lastUpdated: Date?
    private(set) var errorMessage: String?
    private(set) var notificationsOff = false
    private(set) var tokenWarning: String?
    private(set) var needsLocalNetwork = false
    private(set) var update: AppRelease?
    private(set) var settingUp = false
    var showWelcome = false
    private(set) var tokenExpiry: Date?
    private(set) var lastSuccess: Date?
    private(set) var consecutiveFailures = 0
    private var backoffUntil: Date?

    func isStale(now: Date = Date()) -> Bool {
        Freshness.isStale(lastSuccess: lastSuccess, now: now, pollSeconds: Config.load().pollSeconds, consecutiveFailures: consecutiveFailures)
    }

    private let backend: MonitorBackend
    private let notifier = NotificationService()
    private var intents: [String: RunnerIntent] = [:]
    private var failureSeen: [Int: Date] = [:]          // job id -> first seen failed
    private var dismissedFailures: Set<Int> = []
    private var quietFailures: Set<Int> = []              // job ids that failed again: shown on the card, no notification
    private var history: [String: [Double]] = [:]
    private var runnerCPUHistory: [String: [Double]] = [:]      // last 3 per-runner CPU samples
    private var lastEnded: [String: Date] = [:]
    private var lastSeen: [String: Date] = [:]
    private var outageTracker = OutageTracker()
    private var failedRestarts: Set<String> = []
    private var jobHistory = JobHistory.load()
    private(set) var failures = FailureLog.load()
    private var latestRunner: String?
    private var noticesSent: Set<String> = []
    private var calmSince: [String: Date] = [:]            // host -> when its memory last became normal
    private var staleHeld: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "heldRunners") ?? [])
    private(set) var utilisation = UtilisationLog.load()
    var recordHistory = true
    private var lastActive: [String: Date] = {
        (UserDefaults.standard.dictionary(forKey: "lastActive") as? [String: Double] ?? [:]).mapValues(Date.init(timeIntervalSince1970:))
    }()
    private var pollTask: Task<Void, Never>?
    var windowVisible = true

    init(backend: MonitorBackend) { self.backend = backend }

    /// Write the capacity history now (also called when the app quits or loses focus). Does nothing in demo mode.
    func flushHistory(to url: URL? = UtilisationLog.defaultURL(), failuresTo failuresURL: URL? = FailureLog.defaultURL()) {
        guard recordHistory else { return }
        utilisation.save(to: url)
        failures.save(to: failuresURL)
    }

    func start(demoAction: ((MonitorStore) -> Void)? = nil) {
        for name in [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushHistory() }
            }
        }
        notifier.requestAuthorization { [weak self] in self?.notificationsOff = true }
        showWelcome = demoAction == nil && recordHistory && Welcome.shouldShow()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            var first = true
            // Touch each SSH host once before the first poll, so macOS asks for Local Network access now.
            if self.recordHistory {
                self.settingUp = true
                await withTaskGroup(of: Void.self) { g in
                    for t in Config.load().hosts where t != "local" { g.addTask { await LocalNetwork.prime(target: t) } }
                }
                self.settingUp = false
            }
            while !Task.isCancelled {
                await self.refresh()
                if first { first = false; demoAction?(self) }
                var secs = self.windowVisible ? max(5, Config.load().pollSeconds) : 60
                if let until = self.backoffUntil { secs = max(secs, Int(until.timeIntervalSinceNow.rounded(.up))) }
                try? await Task.sleep(for: .seconds(secs))
            }
        }
    }

    func refresh() async {
        let config = Config.load()
        var attempt = 0
        while true {
            do {
                let snap = try await backend.poll(config: config)
                errorMessage = snap.warnings.isEmpty ? nil : snap.warnings.joined(separator: "; ")
                tokenExpiry = snap.tokenExpiry
            needsLocalNetwork = snap.needsLocalNetwork
            update = config.checkUpdates ? AppInfo.update(current: AppInfo.version, latest: snap.latestApp) : nil
            latestRunner = snap.latestRunner
                tokenWarning = TokenExpiry.warning(expiry: snap.tokenExpiry, now: Date())
                apply(snap, config: config, now: Date())
                lastSuccess = Date(); consecutiveFailures = 0; backoffUntil = nil
                return
            } catch {
                // One quick retry for a brief network failure; anything else waits for the next poll.
                if attempt == 0, RateLimit.isTransient(error) { attempt += 1; try? await Task.sleep(for: .seconds(2)); continue }
                consecutiveFailures += 1
                if case GitHubError.rateLimited(let until) = error { backoffUntil = until }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Poll failed"
                return
            }
        }
    }

    private func apply(_ snap: BackendSnapshot, config: Config, now: Date) {
        queue = snap.queue.sorted { $0.queuedAt < $1.queuedAt }
        throttle(snap, config: config, now: now)
        var out: [Runner] = []
        // Runners in one Colima VM share its root disk, so they report identical figures: say it once, on the first.
        // The same pick every poll (probe order is not stable), so a note does not jump between cards.
        var diskOwner: [String: String] = [:], memoryOwner: [String: String] = [:]
        for o in snap.runners.sorted(by: { $0.id < $1.id }) {
            if o.diskFreeKB != nil { diskOwner[Self.diskKey(o)] = diskOwner[Self.diskKey(o)] ?? o.id }
            if o.hostMemory != nil { memoryOwner[o.host] = memoryOwner[o.host] ?? o.id }
        }
        for o in snap.runners {
            var obs = o
            let showDisk = o.diskFreeKB == nil || diskOwner[Self.diskKey(o)] == o.id
            let showMemory = o.hostMemory != nil && memoryOwner[o.host] == o.id
            var h = history[o.id, default: []]; h.append(o.cpuPercent); history[o.id] = Array(h.suffix(10))
            var intent = intents[o.id] ?? RunnerIntent()

            if let j = obs.job, j.failedStep != nil || j.exitCode != nil {
                if dismissedFailures.contains(j.id) { obs.job = nil }
                else if failureSeen[j.id] == nil {
                    failureSeen[j.id] = min(now, j.lastOutputAt)                // hold counts from when it failed
                    jobHistory.recordFailure(jobKey: j.historyKey, runner: o.id)
                    let record = FailureRecord(jobID: j.id, runner: o.id, repo: j.repo, workflow: j.workflow, job: j.jobName,
                                               stepName: j.failedStepName, stepNumber: j.failedStep, at: min(now, j.lastOutputAt),
                                               url: j.url?.absoluteString)
                    if failures.isRepeat(record) { quietFailures.insert(j.id) }
                    failures.record(record, now: now)
                }
            }
            let seen = obs.job.flatMap { failureSeen[$0.id] }
            if let c = o.runnerCPU { runnerCPUHistory[o.id] = Array((runnerCPUHistory[o.id, default: []] + [c]).suffix(3)) }
            let cpuAvg = Self.average(runnerCPUHistory[o.id] ?? [], minimum: 2)
            var state = StateRules.derive(obs, intent: intent, failureSeenAt: seen, now: now, stallThreshold: config.stallThreshold,
                                          runnerCPUAvg: cpuAvg)
            if let since = intent.restartingSince, state != .restarting {
                if state == .offline, RestartWatch.timedOut(since: since, now: now) {
                    if failedRestarts.insert(o.id).inserted { notifier.notifyRestartFailed(runner: o.id, host: o.host) }
                }
                intent.restartingSince = nil
            }
            if state != .offline { failedRestarts.remove(o.id) }

            if intent.draining, !intent.paused, state == .idle {
                intent.paused = true; state = .paused
                stopService(o.id, config: config)
            }
            intents[o.id] = intent

            let shown = [.running, .stalled, .failed].contains(state) ? obs.job : nil
            // A job that ended without failing teaches the usual duration and clears the failure streak.
            if let was = runners.first(where: { $0.id == o.id }), let prev = was.job, prev.id != shown?.id,
               prev.failedStep == nil, was.state == .running || was.state == .stalled {
                jobHistory.recordSuccess(jobKey: prev.historyKey, runner: o.id, seconds: now.timeIntervalSince(prev.startedAt))
            }
            let longRun = (state == .running || state == .stalled) ? shown.flatMap { jobHistory.longRunFactor(jobKey: $0.historyKey, elapsed: now.timeIntervalSince($0.startedAt)) } : nil
            let streak = StreakRule.shown(jobHistory.streak(runner: o.id), lastFailure: failures.lastFailure(runner: o.id), now: now)
            notices(o, showDisk: showDisk, showMemory: showMemory, longRun: longRun, streak: streak, job: shown, config: config, now: now)
            if let p = runners.first(where: { $0.id == o.id }), p.job != nil, shown == nil, state != .restarting { lastEnded[o.id] = now }
            if let j = shown {
                let silent = Int(now.timeIntervalSince(j.lastOutputAt) / 60)
                if state == .stalled { notifier.notify(.stalled, jobId: j.id, runner: o.id, job: j, silentMinutes: silent) }
                if state == .failed, !quietFailures.contains(j.id) { notifier.notify(.failed, jobId: j.id, runner: o.id, job: j, silentMinutes: 0) }
            }
            if outageTracker.observe(id: o.id, state: state) { notifier.notifyOffline(runner: o.id, host: o.host) }
            if o.listenerRunning || o.busy { lastActive[o.id] = now }
            if StaleRule.isStale(state: state, lastActive: lastActive[o.id], now: now) { continue }
            out.append(Runner(id: o.id, arch: o.arch, cpus: o.cpus, memoryGB: o.memoryGB, state: state,
                              draining: intent.draining, job: shown, cpuHistory: history[o.id] ?? [],
                              memUsedGB: o.memUsedGB, lastJobEndedAt: o.lastJobEndedAt ?? lastEnded[o.id],
                              failedAt: seen, host: o.host, standby: o.standby, runnerCPU: cpuAvg,
                              restartFailed: failedRestarts.contains(o.id), diskFreeKB: showDisk ? o.diskFreeKB : nil, diskUsedPct: showDisk ? o.diskUsedPct : nil, diskIsVM: !o.native, held: intent.held, hostMemory: showMemory ? o.hostMemory : nil,
                              version: o.version, latestVersion: snap.latestRunner, latestPublished: snap.latestRunnerPublished, longRunFactor: longRun, failStreak: streak))
        }
        if recordHistory {
            let longest = queue.map { now.timeIntervalSince($0.queuedAt) }.max() ?? 0
            utilisation.record(at: now, runners: out.filter { $0.state != .unreachable }.map { ($0.id, $0.job != nil && ($0.state == .running || $0.state == .stalled)) },
                               queueLength: queue.count, longestWait: longest)
            if Int(now.timeIntervalSince1970) / 60 % 5 == 0 || utilisation.hours.count <= 1 { utilisation.save() }
        }
        if recordHistory { jobHistory.save(); failures.save() }
        for r in out { lastSeen[r.id] = now }
        out += HostRetention.carryOver(previous: runners, current: out, unreachable: Set(snap.unreachable), lastSeen: lastSeen)
        runners = out
        lastUpdated = now
        let problems = ProblemBadge.count(out, outages: outageTracker.outages)
        NSApplication.shared.dockTile.badgeLabel = ProblemBadge.label(problems)
        notifier.setBadge(problems)
        UserDefaults.standard.set(lastActive.mapValues(\.timeIntervalSince1970), forKey: "lastActive")
    }

    /// Keeps a Mac under memory pressure to the job it is already running. See ThrottleRule.
    private func throttle(_ snap: BackendSnapshot, config: Config, now: Date) {
        func resume(_ id: String) {
            Task { await run { try await backend.setRunnerService(id, running: true, config: config) }; await refresh() }
        }
        // A previous run of Hangar may have held runners and then quit: it cannot have resumed them, so do that first.
        for o in snap.runners where staleHeld.remove(o.id) != nil { resume(o.id) }
        for (host, rs) in Dictionary(grouping: snap.runners, by: \.host) {
            let memory = rs.compactMap(\.hostMemory).first
            let underPressure = (memory?.pressureLevel ?? 1) >= 2
            if memory != nil { if underPressure { calmSince[host] = nil } else if calmSince[host] == nil { calmSince[host] = now } }
            let candidates = rs.map { o -> ThrottleRule.Candidate in
                let i = intents[o.id] ?? RunnerIntent()
                let free = !o.busy && o.ghOnline && o.listenerRunning && !i.draining && !i.paused && i.restartingSince == nil
                return .init(id: o.id, busy: o.busy, canHold: free, held: i.held)
            }
            let d = ThrottleRule.decide(candidates, protect: config.protectJobs, underPressure: underPressure, calmSince: calmSince[host], now: now)
            for id in d.hold {
                var i = intents[id] ?? RunnerIntent(); i.held = true; i.paused = true; intents[id] = i
                stopService(id, config: config)
            }
            for id in d.release {
                var i = intents[id] ?? RunnerIntent(); i.held = false; i.paused = false; i.restartingSince = now; intents[id] = i
                resume(id)
            }
            if !d.hold.isEmpty {
                notifier.notifyNotice(title: "Idle runners held back", body: "\(host.isEmpty ? "This Mac" : host) is low on memory. \(d.hold.joined(separator: ", ")) paused until it eases, so the running job can finish.")
            }
        }
        if recordHistory { UserDefaults.standard.set(intents.filter(\.value.held).map(\.key), forKey: "heldRunners") }
    }

    nonisolated static func diskKey(_ o: RunnerObservation) -> String { "\(o.host)|\(o.native)|\(o.diskFreeKB ?? -1)|\(o.diskUsedPct ?? -1)" }

    nonisolated static func average(_ xs: [Double], minimum: Int) -> Double? {
        xs.count >= minimum ? xs.reduce(0, +) / Double(xs.count) : nil
    }

    /// Demo only: seed a day of readings so the Capacity window has something to show.
    func loadDemoHistory() {
        utilisation = UtilisationLog.demo(now: Date())
        failures = FailureLog.demo(now: Date())
        jobHistory.durations[JobHistory.key(repo: "api-server", workflow: "build", job: "")] = [300, 290, 310, 305, 295, 300]
        jobHistory.streaks[JobHistory.streakKey(runner: "arm-02", jobKey: JobHistory.key(repo: "web", workflow: "test", job: ""))] = 3
    }

    func diagnose() async -> ConnectionReport { await backend.diagnose(config: Config.load()) }

    func dismissWelcome() { showWelcome = false; Welcome.dismiss() }

    // MARK: actions

    func restart(_ id: String) {
        guard let r = runners.first(where: { $0.id == id }), r.state != .restarting, r.state != .unreachable else { return }
        if let j = r.job { dismissedFailures.insert(j.id) }
        var i = intents[id] ?? RunnerIntent()
        i.restartingSince = Date(); i.paused = false; i.draining = false
        failedRestarts.remove(id)
        intents[id] = i
        setState(id, .restarting)
        let config = Config.load()
        Task {
            await run { try await backend.restart(id, config: config) }
            await refresh()
        }
    }

    func toggleDrain(_ id: String) {
        guard let r = runners.first(where: { $0.id == id }), r.state != .restarting, r.state != .unreachable else { return }
        var i = intents[id] ?? RunnerIntent()
        let config = Config.load()
        if i.draining || i.paused {
            i.draining = false; i.paused = false
            intents[id] = i
            Task { await run { try await backend.setRunnerService(id, running: true, config: config) }; await refresh() }
        } else {
            i.draining = true
            if r.state == .idle { i.paused = true; stopService(id, config: config) }
            intents[id] = i
            setState(id, i.paused ? .paused : r.state, draining: true)
        }
        if i.draining || i.paused || !i.draining { Task { await refresh() } }
    }

    /// Non-urgent notices go out once, and wait while quiet hours are on. They are shown as notes on the card regardless.
    private func notices(_ o: RunnerObservation, showDisk: Bool, showMemory: Bool, longRun: Double?, streak: Int?, job: ActiveJob?, config: Config, now: Date) {
        let quiet = QuietHours.isQuiet(now, config: config)
        func once(_ key: String, active: Bool, title: String, body: String) {
            let k = "\(o.id)|\(key)"
            guard active else { noticesSent.remove(k); return }
            guard !quiet, noticesSent.insert(k).inserted else { return }           // quiet: not marked, so it is sent when quiet ends
            notifier.notifyNotice(title: title, body: body)
        }
        let disk = showDisk ? DiskRule.warning(freeKB: o.diskFreeKB, usedPct: o.diskUsedPct, vm: !o.native) : nil
        once("disk", active: disk != nil, title: o.native ? "Runner disk low" : "VM disk low", body: "\(o.id)\(o.host.isEmpty ? "" : " on \(o.host)"): \(disk ?? "")")
        let mem = showMemory ? MemoryRule.warning(o.hostMemory) : nil
        once("memory", active: mem != nil, title: "Mac low on memory", body: "\(o.host.isEmpty ? "This Mac" : o.host): \(mem?.text ?? ""). Jobs in its VMs will run slowly.")
        once("streak", active: streak != nil, title: "Same job keeps failing", body: "\(o.id) has failed the same job \(streak ?? 0) times in a row.")
        once("long", active: longRun != nil, title: "Job running long", body: "\(o.id): a job is taking \(String(format: "%.1f", longRun ?? 0))x longer than usual.")
    }

    private func stopService(_ id: String, config: Config) {
        Task { await run { try await backend.setRunnerService(id, running: false, config: config) } }
    }

    /// Runs a side effect and shows the failure in the window instead of swallowing it.
    private func run(_ op: () async throws -> Void) async {
        do { try await op() } catch {
            if case ShellError.failed(_, let msg) = error {
                errorMessage = msg.split(separator: "\n").last.map(String.init) ?? "Command failed"
            } else { errorMessage = (error as? LocalizedError)?.errorDescription ?? "Command failed" }
        }
    }

    private func setState(_ id: String, _ s: RunnerState, draining: Bool? = nil) {
        guard let i = runners.firstIndex(where: { $0.id == id }) else { return }
        runners[i].state = s
        if s == .restarting { runners[i].job = nil }
        if let d = draining { runners[i].draining = d }
    }
}
