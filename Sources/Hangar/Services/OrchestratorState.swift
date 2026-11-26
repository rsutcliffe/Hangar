import Foundation

/// `state.json` version 1, written by the runner orchestrator on the Mac that runs it. Only the version and heartbeat are
/// required. Classes, kinds, rules, faults and map keys stay free strings, so a new one never makes the file unreadable.
struct OrchestratorState: Codable, Equatable, Sendable {
    var version: Int
    var heartbeat: Date
    var problems: [Problem]? = nil
    /// Newest last.
    var events: [Event]? = nil
    var eventsTotal24h: Int? = nil
    var recommendations: [Recommendation]? = nil
    /// Five-minute buckets, oldest first.
    var throughput: [Bucket]? = nil
    /// The latest failed jobs, oldest first.
    var failures: [Failure]? = nil
    /// Newest last.
    var days: [Day]? = nil

    struct Problem: Codable, Equatable, Sendable {
        var id: String? = nil
        /// Empty for a problem that belongs to no host.
        var host: String? = nil
        var `class`: String? = nil
        var text: String? = nil
        var since: Date? = nil
    }

    struct Event: Codable, Equatable, Sendable {
        var time: Date? = nil
        var kind: String? = nil
        var host: String? = nil
        var set: String? = nil
        var job: String? = nil
        var text: String? = nil
        var attributed: Bool? = nil
    }

    struct Recommendation: Codable, Equatable, Sendable {
        var id: String? = nil
        var rule: String? = nil
        var text: String? = nil
    }

    struct Bucket: Codable, Equatable, Sendable {
        var start: Date? = nil
        /// Jobs, successes and failures.
        var completed: Int? = nil
        /// Workflow runs, so not comparable job for job with `completed`.
        var failed: Int? = nil
        var running: Int? = nil
        var waiting: Int? = nil
    }

    struct Failure: Codable, Equatable, Sendable {
        var time: Date? = nil
        var set: String? = nil
        /// A repository name without its owner.
        var repo: String? = nil
        var job: String? = nil
        /// Not GitHub's numeric job id.
        var jobId: String? = nil
        var runner: String? = nil
        /// 0 when unknown.
        var runId: Int? = nil
        /// Empty when the orchestrator saw no fault of its own.
        var fault: String? = nil
    }

    struct Day: Codable, Equatable, Sendable {
        /// A UTC date, "2026-11-26".
        var date: String? = nil
        var waitingSec: Int? = nil
        var sets: [String: SetNumbers]? = nil
        var hosts: [String: HostNumbers]? = nil
    }

    struct SetNumbers: Codable, Equatable, Sendable {
        var runs: Int? = nil
        var waitP50Sec: Int? = nil
        var waitP90Sec: Int? = nil
        var failed: Int? = nil
        var memoryKills: Int? = nil
        var waitSamplesSec: [Int]? = nil
    }

    struct HostNumbers: Codable, Equatable, Sendable {
        var refusedSec: [String: Int]? = nil
        var noRoomSec: [String: Int]? = nil
        var hungReleased: Int? = nil
        var failedStarts: Int? = nil
    }
}

extension OrchestratorState {
    /// The UserDefaults key holding the label of the host that last supplied a state.
    static let seenOnKey = "orchestratorSeenOn"
    static let staleAfter: TimeInterval = 300

    /// nil when the text is not valid JSON, lacks the version or heartbeat, or is another version.
    static func parse(_ text: String) -> OrchestratorState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601        // the writer uses whole seconds
        guard let state = try? decoder.decode(OrchestratorState.self, from: Data(text.utf8)), state.version == 1 else { return nil }
        return state
    }

    func isStale(now: Date) -> Bool { now.timeIntervalSince(heartbeat) > Self.staleAfter }

    /// The newest heartbeat among the last good state and this poll's reads. A read that failed or does not parse is not a
    /// candidate. `host` is the label of the host that supplied the result, nil when no read did.
    // shortcut: if the writer's clock is set back, the last state wins until the clock passes it or Hangar restarts.
    static func newest(_ reads: [(host: String, text: String?)], keeping last: OrchestratorState?) -> (state: OrchestratorState?, host: String?) {
        var best = last
        var from: String?
        for read in reads {
            guard let state = read.text.flatMap(parse), best.map({ state.heartbeat >= $0.heartbeat }) ?? true else { continue }
            best = state; from = read.host
        }
        return (best, from)
    }
}
