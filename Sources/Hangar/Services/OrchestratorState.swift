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
    /// The UserDefaults keys remembering which host last supplied a state: the label shown for it, and its configured entry,
    /// which (unlike the label) is known without reaching it.
    static let seenOnKey = "orchestratorSeenOn"
    static let seenTargetKey = "orchestratorSeenTarget"
    static let staleAfter: TimeInterval = 300

    /// nil when the text is not valid JSON, lacks the version or heartbeat, or is another version.
    static func parse(_ text: String) -> OrchestratorState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601        // the writer uses whole seconds
        guard let state = try? decoder.decode(OrchestratorState.self, from: Data(text.utf8)), state.version == 1 else { return nil }
        return state
    }

    func isStale(now: Date) -> Bool { now.timeIntervalSince(heartbeat) > Self.staleAfter }

    /// Valid JSON with a version other than 1: the orchestrator writes a format this Hangar does not know.
    static func isOtherVersion(_ text: String) -> Bool {
        struct Versioned: Decodable { var version: Int }
        guard let file = try? JSONDecoder().decode(Versioned.self, from: Data(text.utf8)) else { return false }
        return file.version != 1
    }

    /// One host's read in one poll. `target` is its configured entry, `host` the label shown for it.
    struct Read: Sendable {
        var target: String
        var host: String
        var text: String?
    }

    /// The last good state since launch and the host that supplied it.
    struct Held: Equatable, Sendable {
        var state: OrchestratorState? = nil
        var target: String? = nil
        var host: String? = nil
        /// The latest poll read a file of another version.
        var otherVersion = false

        /// A read that failed or does not parse changes nothing. The supplying host's own file always replaces what is held;
        /// another host's replaces it only when it ranks at least as high. A host no longer in `hosts` is forgotten.
        func updated(with reads: [Read], hosts: [String], now: Date) -> Held {
            var next = target.map(hosts.contains) == true ? self : Held()
            let own = next.target
            let parsed = reads.compactMap { read in read.text.flatMap(OrchestratorState.parse).map { (read: read, state: $0) } }
            for (read, state) in parsed.filter({ $0.read.target == own }) + parsed.filter({ $0.read.target != own }) {
                guard read.target == own || next.state.map({ state.rank(now: now) >= $0.rank(now: now) }) ?? true else { continue }
                next.state = state; next.target = read.target; next.host = read.host
            }
            next.otherVersion = reads.contains { $0.text.map(OrchestratorState.isOtherVersion) ?? false }
            return next
        }

        static func remembered(in d: UserDefaults) -> Held {
            Held(target: d.string(forKey: OrchestratorState.seenTargetKey), host: d.string(forKey: OrchestratorState.seenOnKey))
        }

        func remember(in d: UserDefaults) {
            d.set(target, forKey: OrchestratorState.seenTargetKey)          // setting nil removes the key
            d.set(host, forKey: OrchestratorState.seenOnKey)
        }
    }

    /// A current heartbeat beats one from more than `staleAfter` in the future (a wrong clock), which beats a stale one;
    /// within a kind the newer wins.
    private func rank(now: Date) -> (Int, Date) {
        let ahead = heartbeat.timeIntervalSince(now) > Self.staleAfter
        return (isStale(now: now) ? 0 : ahead ? 1 : 2, heartbeat)
    }

    struct Notice: Equatable, Sendable {
        var key: String
        var title: String
        var body: String
    }

    /// What is worth announcing now: each open problem and each memory kill tied to a job, or only that the orchestrator
    /// has stopped reporting. A stale state's own problems and events are old news. `waitingSince` is when Hangar started.
    static func notices(state: OrchestratorState?, seen: Bool, otherVersion: Bool, waitingSince: Date, now: Date) -> [Notice] {
        func notReporting(_ body: String) -> [Notice] {
            // A file of another version means it is reporting, and the card says what to do about it.
            otherVersion ? [] : [Notice(key: "orch|stale", title: "Orchestrator not reporting", body: body)]
        }
        guard let state else {
            return seen && now.timeIntervalSince(waitingSince) > staleAfter ? notReporting("No heartbeat read since Hangar started.") : []
        }
        if state.isStale(now: now) { return notReporting("Last heartbeat \(Format.duration(now.timeIntervalSince(state.heartbeat))) ago.") }
        func body(_ host: String?, _ text: String) -> String { (host ?? "").isEmpty ? text : "\(host ?? ""): \(text)" }
        let problems = (state.problems ?? []).compactMap { p in
            p.id.map { Notice(key: "orch|\($0)", title: "Orchestrator problem", body: body(p.host, p.text ?? p.class ?? "Unnamed problem")) }
        }
        // Newest first, so the most recent kills are the ones that get through the burst cap.
        let kills = (state.events ?? []).reversed().filter { $0.kind == "memory_kill" && $0.attributed == true }.map { e in
            Notice(key: "orch|kill|\(e.time.map { $0.formatted(.iso8601) } ?? "")|\(e.host ?? "")", title: "Job killed for memory",
                   body: body(e.host, e.text ?? e.job ?? "A job was killed for memory"))
        }
        return problems + kills
    }
}

/// Which orchestrator notices are due. Each is offered once while its condition lasts; the notifier's cooldown and burst cap
/// still apply to what is offered.
struct OrchestratorAnnouncer {
    private var sent: Set<String> = []

    /// `fresh` is false when there is no current state: marks are then kept, so its old problems are not announced again
    /// when it comes back. During quiet hours nothing is marked, so it is sent when they end.
    mutating func due(_ current: [OrchestratorState.Notice], fresh: Bool, quiet: Bool) -> [OrchestratorState.Notice] {
        if fresh { sent.formIntersection(current.map(\.key)) }
        return quiet ? [] : current.filter { sent.insert($0.key).inserted }
    }
}
