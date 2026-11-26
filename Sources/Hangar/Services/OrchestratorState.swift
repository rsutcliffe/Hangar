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

        var summary: String { text.nonEmpty ?? self.class.nonEmpty ?? "Unnamed problem" }
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

        /// A read that failed or does not parse changes nothing, and one whose heartbeat is far in the future is ignored.
        /// Otherwise the supplying host's own file always replaces what is held, and another host's replaces it when it is
        /// at least as new. A host no longer in `hosts` is forgotten.
        func updated(with reads: [Read], hosts: [String], now: Date) -> Held {
            var next = target.map(hosts.contains) == true ? self : Held()
            if next.state?.isAhead(now: now) == true { next.state = nil }        // this Mac's clock was set back
            let own = next.target
            let parsed = reads.compactMap { read in read.text.flatMap(OrchestratorState.parse).map { (read: read, state: $0) } }
            let usable = parsed.filter { !$0.state.isAhead(now: now) }
            for (read, state) in usable.filter({ $0.read.target == own }) + usable.filter({ $0.read.target != own }) {
                guard read.target == own || next.state.map({ state.heartbeat >= $0.heartbeat }) ?? true else { continue }
                next.state = state; next.target = read.target; next.host = read.host
            }
            // With nothing but an ignored file, the orchestrator still counts as seen: the card then says it is not
            // reporting, where no card at all would hide a wrong clock.
            if next.target == nil, let ignored = parsed.first { next.target = ignored.read.target; next.host = ignored.read.host }
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

    /// A heartbeat this far in the future means a wrong clock. Trusted, it would not go stale until the clock caught up.
    private func isAhead(now: Date) -> Bool { heartbeat.timeIntervalSince(now) > Self.staleAfter }

    struct Notice: Equatable, Sendable {
        var key: String
        var title: String
        var body: String
    }

    /// What is worth announcing now: each open problem, and each memory kill tied to a job since just before this run of
    /// Hangar (`startedAt`), or only that the orchestrator has stopped reporting, once `silenceConfirmed`. A stale state's
    /// own problems and events are old news.
    static func notices(state: OrchestratorState?, silenceConfirmed: Bool, startedAt: Date, now: Date) -> [Notice] {
        guard let state, !state.isStale(now: now) else {
            guard silenceConfirmed else { return [] }
            let body = state.map { "Last heartbeat \(Format.duration(now.timeIntervalSince($0.heartbeat))) ago." }
            return [Notice(key: "orch|stale", title: "Orchestrator not reporting", body: body ?? "No heartbeat read since Hangar started.")]
        }
        func body(_ host: String?, _ text: String) -> String { (host ?? "").isEmpty ? text : "\(host ?? ""): \(text)" }
        let problems = (state.problems ?? []).compactMap { p in
            p.id.map { Notice(key: "orch|\($0)", title: "Orchestrator problem", body: body(p.host, p.summary)) }
        }
        // Older kills stay on the card only: announced again at every launch, they would crowd out newer alerts.
        let earliest = startedAt.addingTimeInterval(-staleAfter)
        // Newest first, so the most recent kills are the ones that get through the burst cap.
        let kills = (state.events ?? []).reversed().filter {
            $0.kind == "memory_kill" && $0.attributed == true && $0.time.map { $0 >= earliest } == true
        }.map { e in
            Notice(key: "orch|kill|\(e.time.map { $0.formatted(.iso8601) } ?? "")|\(e.host ?? "")", title: "Job killed for memory",
                   body: body(e.host, e.text.nonEmpty ?? e.job.nonEmpty ?? "A job was killed for memory"))
        }
        return problems + kills
    }
}

extension String? {
    /// The writer sends "" for a field it has nothing for.
    var nonEmpty: String? { self?.isEmpty == false ? self : nil }
}

/// What the throughput card shows, worked out from the state file.
extension OrchestratorState {
    struct Throughput: Equatable {
        struct Point: Equatable {
            var start: Date
            var completed: Int
            var failed: Int
            var running: Int
            var waiting: Int
            /// Rises after a missing bucket, so a line is not drawn across time nothing is known about.
            var segment: Int
        }

        /// One failed run (or one job, when its run is unknown).
        struct Entry: Equatable {
            var time: Date?
            var repo: String
            var job: String
            /// The fault and the failed step; empty when neither is known.
            var detail: String
            /// Further failed jobs of the same run among those the file keeps.
            var more: Int
        }

        /// The six hours of the charts' shared time axis.
        var domain: ClosedRange<Date>
        var points: [Point]
        var doneLastHour: Int?
        var failed6h: Int?
        var runningNow: Int?
        var waitingNow: Int?
        var typicalWait: String?
        /// The latest runs with a failure in the six hours, newest first.
        var failures: [Entry]
        /// All such runs among the failed jobs the file keeps; nil when the file has no list.
        var failureTotal: Int?
    }

    static let bucketLength: TimeInterval = 300

    static func faultLabel(_ fault: String?) -> String? {
        guard let fault, !fault.isEmpty else { return nil }
        return fault == "memory_kill" ? "Out of memory" : "Runner fault: \(fault.replacingOccurrences(of: "_", with: " "))"
    }

    /// nil when there is no card: no `throughput` array, or a stale state, whose numbers are not current.
    ///
    /// "Last hour" and "6 hours" are spans of time ending at the heartbeat, not the last 12 or 72 entries, which would reach
    /// further back across a gap or in an old file. The heartbeat, not this Mac's clock: it comes from the same clock as the
    /// bucket starts, so a difference between two Macs' clocks moves nothing, and the stale rule keeps it within five
    /// minutes of now.
    func throughputSummary(failedSteps: [RunnerJobKey: String], now: Date) -> Throughput? {
        guard let throughput, !isStale(now: now) else { return nil }
        let length = Self.bucketLength
        let end = (heartbeat.timeIntervalSince1970 / length).rounded(.down) * length + length
        // Bounded so that no number from a file can overflow a sum or a chart's axis.
        func count(_ n: Int?) -> Int { min(1_000_000, max(0, n ?? 0)) }
        func within(_ start: Date, _ span: TimeInterval) -> Bool { start <= heartbeat && heartbeat.timeIntervalSince(start) < span }

        var byStart: [Date: Bucket] = [:]
        for b in throughput { if let start = b.start, within(start, 6 * 3600) { byStart[start] = b } }
        var segment = 0
        var previous: Date?
        let points = byStart.keys.sorted().map { start in
            if let previous, start.timeIntervalSince(previous) > length { segment += 1 }
            previous = start
            let b = byStart[start]
            return Throughput.Point(start: start, completed: count(b?.completed), failed: count(b?.failed),
                                    running: count(b?.running), waiting: count(b?.waiting), segment: segment)
        }
        let hour = points.filter { within($0.start, 3600) }
        // "Now" is only the bucket holding the heartbeat.
        let current = points.last.flatMap { within($0.start, length) ? $0 : nil }
        func total(_ points: [Throughput.Point], _ value: KeyPath<Throughput.Point, Int>) -> Int? {
            points.isEmpty ? nil : points.reduce(0) { $0 + $1[keyPath: value] }
        }

        // The file lists failed jobs oldest first, of any age. A run is listed when one of its jobs is in the tile's six hours,
        // measured as the tile does: by the start of the job's bucket. It makes one entry, named by the earliest such job;
        // "more" and the fault look at all its kept jobs, older ones too. Run 0 is unknown, so it never groups.
        func inSpan(_ f: Failure) -> Bool {
            f.time.map { within(Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / length).rounded(.down) * length), 6 * 3600) } ?? false
        }
        let all = failures ?? []
        let jobsOfRun = Dictionary(grouping: all.filter { ($0.runId ?? 0) != 0 }) { $0.runId ?? 0 }
        var listed = Set<Int>()
        let runs = all.filter(inSpan).filter { f in (f.runId ?? 0) == 0 || listed.insert(f.runId ?? 0).inserted }
        let entries = runs.reversed().prefix(6).map { first in
            let jobs = jobsOfRun[first.runId ?? 0] ?? [first]
            var detail: [String] = []
            if let label = Self.faultLabel(first.fault) { detail.append(label) }
            else if let label = jobs.lazy.compactMap({ Self.faultLabel($0.fault) }).first { detail.append("\(label) (another job)") }
            if let id = first.runId, id != 0, let runner = first.runner, let step = failedSteps[RunnerJobKey(runId: id, runner: runner)] {
                detail.append(step)
            }
            return Throughput.Entry(time: first.time, repo: first.repo ?? "", job: first.job ?? "",
                                    detail: detail.joined(separator: " · "), more: jobs.count - 1)
        }

        return Throughput(domain: Date(timeIntervalSince1970: end - 6 * 3600)...Date(timeIntervalSince1970: end), points: points,
                          doneLastHour: total(hour, \.completed), failed6h: total(points, \.failed),
                          runningNow: current?.running, waitingNow: current?.waiting,
                          typicalWait: OrchestratorCard.typicalWait(days: days) { $0 == OrchestratorCard.utcDay(now) },
                          failures: Array(entries), failureTotal: failures == nil ? nil : runs.count)
    }

    /// The time and value of the bucket under the pointer.
    static func hoverText(at date: Date, points: [Throughput.Point], value: KeyPath<Throughput.Point, Int>) -> String {
        func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
        if let p = points.last(where: { $0.start <= date && date.timeIntervalSince($0.start) < bucketLength }) {
            return "\(time(p.start)) · \(p[keyPath: value])"
        }
        let start = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / bucketLength).rounded(.down) * bucketLength)
        return "\(time(start)) · no data"
    }

    /// A chart's accessibility label.
    static func spoken(_ title: String, points: [Throughput.Point], value: KeyPath<Throughput.Point, Int>) -> String {
        guard let last = points.last, let peak = points.map({ $0[keyPath: value] }).max() else { return "\(title): no data" }
        return "\(title): latest \(last[keyPath: value]), peak \(peak)"
    }
}

/// Which orchestrator notices are due. Each is offered once while its condition lasts; the notifier's cooldown and burst cap
/// still apply to what is offered.
struct OrchestratorAnnouncer {
    private var sent: Set<String> = []
    /// How long successful polls have seen the orchestrator silent, with nothing current in between.
    private var silentFor: TimeInterval = 0
    private var lastPoll: (at: Date, awake: TimeInterval, silent: Bool)?
    private var failedSinceLastPoll = false

    /// One of Hangar's own polls failed: the time since the last successful one was not watched.
    mutating func pollFailed() { failedSinceLastPoll = true }

    /// Called after each successful poll. Only the time between two successful polls that both saw silence is counted,
    /// with no failed poll between them, and it is measured on `awake` (`systemUptime`), which stands still during sleep.
    /// More than `maxGap` of wall-clock time since the last successful poll (a sleep, or an outage) starts the count again.
    ///
    /// With no current state, marks are kept, so old problems are not announced again when it comes back. During quiet
    /// hours nothing is marked, so it is sent when they end.
    mutating func due(state: OrchestratorState?, seen: Bool, otherVersion: Bool, startedAt: Date, now: Date, awake: TimeInterval,
                      maxGap: TimeInterval, quiet: Bool) -> [OrchestratorState.Notice] {
        let fresh = state.map { !$0.isStale(now: now) } ?? false
        // A file of another version means it is reporting, and the card says what to do about it.
        let silent = !fresh && !otherVersion && (state != nil || seen)
        if !silent { silentFor = 0 }
        if let last = lastPoll {
            if now.timeIntervalSince(last.at) > maxGap { silentFor = 0 }
            else if silent, last.silent, !failedSinceLastPoll { silentFor += max(0, awake - last.awake) }
        }
        lastPoll = (now, awake, silent)
        failedSinceLastPoll = false
        let current = OrchestratorState.notices(state: state, silenceConfirmed: silent && silentFor >= OrchestratorState.staleAfter,
                                                startedAt: startedAt, now: now)
        if fresh { sent.formIntersection(current.map(\.key)) }
        return quiet ? [] : current.filter { sent.insert($0.key).inserted }
    }
}
