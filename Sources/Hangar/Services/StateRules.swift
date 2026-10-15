import Foundation

/// Raw facts about one runner from a single poll. State is derived from these plus user intent.
struct RunnerObservation: Equatable, Sendable {
    var id: String
    var arch: Arch
    var cpus: Int
    var memoryGB: Double
    var vmRunning: Bool
    var ghOnline: Bool
    var listenerRunning = true
    var busy: Bool
    var host = ""
    var native = false
    var standby = false
    var job: ActiveJob?
    var cpuPercent: Double
    var memUsedGB: Double
    var lastJobEndedAt: Date?
    /// CPU of this runner's own process tree, percent of one core; nil until two polls have been taken.
    var runnerCPU: Double? = nil
    /// The probe can read per-runner CPU on this host.
    var cpuSupported = false
}

/// What the user has asked for, plus what the app has already acted on.
struct RunnerIntent: Equatable, Sendable {
    var restartingSince: Date?
    var draining = false
    var paused = false
}

enum StallDetector {
    /// Busy and silent for at least the threshold.
    static func isStalled(lastOutputAt: Date, now: Date, threshold: TimeInterval) -> Bool {
        now.timeIntervalSince(lastOutputAt) >= threshold
    }
}

enum StateRules {
    static let failedHold: TimeInterval = 150      // 2.5 min

    /// `failureSeenAt` is when the app first saw this job's failure; nil if no failure to show.
    /// A silent but busy runner is only stalled when its own processes are also idle.
    static let stallCPUCeiling = 5.0

    static func derive(_ o: RunnerObservation, intent: RunnerIntent, failureSeenAt: Date?,
                       now: Date, stallThreshold: TimeInterval, runnerCPUAvg: Double? = nil) -> RunnerState {
        if let since = intent.restartingSince {
            // Restarting lasts until the VM and runner report online again (after at least one poll).
            // Wait for GitHub to show the runner online; give up after the timeout and let it read as offline.
            if !RestartWatch.timedOut(since: since, now: now),
               !(o.vmRunning && o.ghOnline && o.listenerRunning) || now.timeIntervalSince(since) < 1 { return .restarting }
        }
        if intent.paused { return .paused }
        if !o.vmRunning || !o.ghOnline || !o.listenerRunning { return .offline }
        if let job = o.job, job.failedStep != nil || job.exitCode != nil,
           let seen = failureSeenAt, now.timeIntervalSince(seen) < failedHold { return .failed }
        if o.busy, let job = o.job {
            guard StallDetector.isStalled(lastOutputAt: job.lastOutputAt, now: now, threshold: stallThreshold) else { return .running }
            guard o.cpuSupported else { return .stalled }                       // cannot read CPU: silence alone, as before
            guard let avg = runnerCPUAvg else { return .running }              // CPU readable but not enough samples yet
            return avg < stallCPUCeiling ? .stalled : .running
        }
        return .idle
    }
}

enum StaleRule {
    static let window: TimeInterval = 24 * 3600

    /// Hide a runner that is offline and has not been active for a day (or ever, since Hangar first saw it).
    /// One that has just gone down stays visible so a crash is not hidden.
    static func isStale(state: RunnerState, lastActive: Date?, now: Date) -> Bool {
        guard state == .offline else { return false }
        guard let last = lastActive else { return true }
        return now.timeIntervalSince(last) > window
    }
}
