import Foundation

/// Raw facts about one runner from a single poll. State is derived from these plus user intent.
struct RunnerObservation: Equatable, Sendable {
    var id: String
    var arch: Arch
    var cpus: Int
    var memoryGB: Double
    var vmRunning: Bool
    var ghOnline: Bool
    var busy: Bool
    var job: ActiveJob?
    var cpuPercent: Double
    var memUsedGB: Double
    var lastJobEndedAt: Date?
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
    static func derive(_ o: RunnerObservation, intent: RunnerIntent, failureSeenAt: Date?,
                       now: Date, stallThreshold: TimeInterval) -> RunnerState {
        if let since = intent.restartingSince {
            // Restarting lasts until the VM and runner report online again (after at least one poll).
            if !(o.vmRunning && o.ghOnline) || now.timeIntervalSince(since) < 1 { return .restarting }
        }
        if intent.paused { return .paused }
        if !o.vmRunning || !o.ghOnline { return .offline }
        if let job = o.job, job.failedStep != nil || job.exitCode != nil,
           let seen = failureSeenAt, now.timeIntervalSince(seen) < failedHold { return .failed }
        if o.busy, let job = o.job {
            return StallDetector.isStalled(lastOutputAt: job.lastOutputAt, now: now, threshold: stallThreshold)
                ? .stalled : .running
        }
        return .idle
    }
}
