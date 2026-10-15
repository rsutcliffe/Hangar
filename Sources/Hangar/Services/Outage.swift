import Foundation

/// Decides when a runner has gone offline unexpectedly, as opposed to being drained, paused or restarted by the user.
struct OutageTracker {
    /// Polls in a row a runner must be offline before it is called an outage.
    static let confirmPolls = 2

    private var up: Set<String> = []                 // was running, idle, stalled or failed at its last observation
    private var offlinePolls: [String: Int] = [:]
    private var alerted: Set<String> = []

    /// Ids with a confirmed, still-open outage.
    var outages: Set<String> { alerted }

    /// Feed each runner's state once per poll. Returns true exactly once per outage, when it is confirmed.
    mutating func observe(id: String, state: RunnerState) -> Bool {
        switch state {
        case .running, .idle, .stalled, .failed:
            up.insert(id); offlinePolls[id] = nil; alerted.remove(id)
            return false
        case .offline:
            guard up.contains(id) else { return false }          // never seen up this session: not a new outage
            let n = (offlinePolls[id] ?? 0) + 1
            offlinePolls[id] = n
            return n >= Self.confirmPolls && alerted.insert(id).inserted
        case .paused, .restarting, .unreachable:
            // Chosen by the user, or a problem with the whole host: not a runner crash.
            up.remove(id); offlinePolls[id] = nil; alerted.remove(id)
            return false
        }
    }
}

enum NotificationText {
    static func offline(runner: String, host: String) -> (title: String, body: String) {
        ("Runner offline", host.isEmpty ? "\(runner) stopped responding." : "\(runner) on \(host) stopped responding.")
    }
}
