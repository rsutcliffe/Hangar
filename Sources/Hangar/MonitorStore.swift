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

    private let backend: MonitorBackend
    private let notifier = NotificationService()
    private var intents: [String: RunnerIntent] = [:]
    private var failureSeen: [Int: Date] = [:]          // job id -> first seen failed
    private var dismissedFailures: Set<Int> = []
    private var history: [String: [Double]] = [:]
    private var runnerCPUHistory: [String: [Double]] = [:]      // last 3 per-runner CPU samples
    private var lastEnded: [String: Date] = [:]
    private var lastActive: [String: Date] = {
        (UserDefaults.standard.dictionary(forKey: "lastActive") as? [String: Double] ?? [:]).mapValues(Date.init(timeIntervalSince1970:))
    }()
    private var pollTask: Task<Void, Never>?
    var windowVisible = true

    init(backend: MonitorBackend) { self.backend = backend }

    func start(demoAction: ((MonitorStore) -> Void)? = nil) {
        notifier.requestAuthorization { [weak self] in self?.notificationsOff = true }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                if first { first = false; demoAction?(self) }
                let secs = self.windowVisible ? max(5, Config.load().pollSeconds) : 60
                try? await Task.sleep(for: .seconds(secs))
            }
        }
    }

    func refresh() async {
        let config = Config.load()
        do {
            let snap = try await backend.poll(config: config)
            errorMessage = snap.warnings.isEmpty ? nil : snap.warnings.joined(separator: "; ")
            apply(snap, config: config, now: Date())
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Poll failed"
        }
    }

    private func apply(_ snap: BackendSnapshot, config: Config, now: Date) {
        queue = snap.queue.sorted { $0.queuedAt < $1.queuedAt }
        var out: [Runner] = []
        for o in snap.runners {
            var obs = o
            var h = history[o.id, default: []]; h.append(o.cpuPercent); history[o.id] = Array(h.suffix(10))
            var intent = intents[o.id] ?? RunnerIntent()

            if let j = obs.job, j.failedStep != nil || j.exitCode != nil {
                if dismissedFailures.contains(j.id) { obs.job = nil } else if failureSeen[j.id] == nil { failureSeen[j.id] = min(now, j.lastOutputAt) }   // hold counts from when it failed
            }
            let seen = obs.job.flatMap { failureSeen[$0.id] }
            if let c = o.runnerCPU { runnerCPUHistory[o.id] = Array((runnerCPUHistory[o.id, default: []] + [c]).suffix(3)) }
            let cpuAvg = Self.average(runnerCPUHistory[o.id] ?? [], minimum: 2)
            var state = StateRules.derive(obs, intent: intent, failureSeenAt: seen, now: now, stallThreshold: config.stallThreshold,
                                          runnerCPUAvg: cpuAvg)
            if intent.restartingSince != nil && state != .restarting { intent.restartingSince = nil }

            if intent.draining, !intent.paused, state == .idle {
                intent.paused = true; state = .paused
                stopService(o.id, config: config)
            }
            intents[o.id] = intent

            let shown = [.running, .stalled, .failed].contains(state) ? obs.job : nil
            if let p = runners.first(where: { $0.id == o.id }), p.job != nil, shown == nil, state != .restarting { lastEnded[o.id] = now }
            if let j = shown {
                let silent = Int(now.timeIntervalSince(j.lastOutputAt) / 60)
                if state == .stalled { notifier.notify(.stalled, jobId: j.id, runner: o.id, job: j, silentMinutes: silent) }
                if state == .failed { notifier.notify(.failed, jobId: j.id, runner: o.id, job: j, silentMinutes: 0) }
            }
            if o.listenerRunning || o.busy { lastActive[o.id] = now }
            if StaleRule.isStale(state: state, lastActive: lastActive[o.id], now: now) { continue }
            out.append(Runner(id: o.id, arch: o.arch, cpus: o.cpus, memoryGB: o.memoryGB, state: state,
                              draining: intent.draining, job: shown, cpuHistory: history[o.id] ?? [],
                              memUsedGB: o.memUsedGB, lastJobEndedAt: o.lastJobEndedAt ?? lastEnded[o.id],
                              failedAt: seen, host: o.host, standby: o.standby, runnerCPU: cpuAvg))
        }
        runners = out
        lastUpdated = now
        let problems = ProblemBadge.count(out)
        NSApplication.shared.dockTile.badgeLabel = ProblemBadge.label(problems)
        notifier.setBadge(problems)
        UserDefaults.standard.set(lastActive.mapValues(\.timeIntervalSince1970), forKey: "lastActive")
    }

    nonisolated static func average(_ xs: [Double], minimum: Int) -> Double? {
        xs.count >= minimum ? xs.reduce(0, +) / Double(xs.count) : nil
    }

    // MARK: actions

    func restart(_ id: String) {
        guard let r = runners.first(where: { $0.id == id }), r.state != .restarting else { return }
        if let j = r.job { dismissedFailures.insert(j.id) }
        var i = intents[id] ?? RunnerIntent()
        i.restartingSince = Date(); i.paused = false; i.draining = false
        intents[id] = i
        setState(id, .restarting)
        let config = Config.load()
        Task {
            await run { try await backend.restart(id, config: config) }
            await refresh()
        }
    }

    func toggleDrain(_ id: String) {
        guard let r = runners.first(where: { $0.id == id }), r.state != .restarting else { return }
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
