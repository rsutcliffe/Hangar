import Foundation

/// One hour of observations. Counts only: no job names, repos, or anything else from a workflow.
struct HourBucket: Codable, Equatable, Sendable {
    var busy: [String: Int] = [:]       // runner -> polls seen busy
    var total: [String: Int] = [:]      // runner -> polls seen at all
    var peakQueue = 0
    var longestWaitSeconds = 0
}

/// Hourly utilisation history for the Capacity window, kept on disk for 8 days.
struct UtilisationLog: Codable, Equatable, Sendable {
    static let retention: TimeInterval = 8 * 24 * 3600

    private(set) var hours: [Int: HourBucket] = [:]     // key: hours since 1970-01-01 UTC

    static func key(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 3600) }

    /// Record one poll. `busy` is the runners currently running or stalled with a job.
    mutating func record(at date: Date, runners: [(id: String, busy: Bool)], queueLength: Int, longestWait: TimeInterval) {
        let k = Self.key(date)
        var b = hours[k] ?? HourBucket()
        for r in runners {
            b.total[r.id, default: 0] += 1
            if r.busy { b.busy[r.id, default: 0] += 1 }
        }
        b.peakQueue = max(b.peakQueue, queueLength)
        b.longestWaitSeconds = max(b.longestWaitSeconds, Int(longestWait))
        hours[k] = b
        prune(now: date)
    }

    mutating func prune(now: Date) {
        let oldest = Self.key(now.addingTimeInterval(-Self.retention))
        hours = hours.filter { $0.key >= oldest }
    }

    /// The last `count` hours ending at `now`, oldest first; hours with no data are nil.
    func recent(count: Int, now: Date) -> [(hour: Date, bucket: HourBucket?)] {
        let end = Self.key(now)
        return (0..<count).map { i in
            let k = end - (count - 1 - i)
            return (Date(timeIntervalSince1970: TimeInterval(k) * 3600), hours[k])
        }
    }

    /// Fraction of polls in the bucket that found this runner busy; nil if it was not seen.
    static func busyFraction(_ b: HourBucket?, runner: String) -> Double? {
        guard let b, let t = b.total[runner], t > 0 else { return nil }
        return Double(b.busy[runner] ?? 0) / Double(t)
    }

    var runnerIDs: [String] { Array(Set(hours.values.flatMap { $0.total.keys })).sorted() }

    // MARK: persistence (Application Support, never anything secret)

    static func defaultURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Hangar", isDirectory: true).appendingPathComponent("utilisation.json")
    }

    static func load(from url: URL? = defaultURL(), now: Date = Date()) -> UtilisationLog {
        guard let url, let data = try? Data(contentsOf: url), var log = try? JSONDecoder().decode(UtilisationLog.self, from: data) else { return UtilisationLog() }
        log.prune(now: now)
        return log
    }

    func save(to url: URL? = defaultURL()) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }

    /// A day of plausible data so the window can be checked without waiting a day. Used by the demo only.
    static func demo(now: Date) -> UtilisationLog {
        var log = UtilisationLog()
        let ids = ["arm-01", "arm-02", "x86-01"]
        for h in stride(from: 23, through: 0, by: -1) {
            let t = now.addingTimeInterval(-Double(h) * 3600)
            let hour = Calendar.current.component(.hour, from: t)
            let working = (9...18).contains(hour)
            for poll in 0..<10 {
                let runners = ids.enumerated().map { (i, id) in (id: id, busy: working ? (poll + i) % 4 != 0 : (poll + i) % 9 == 0) }
                log.record(at: t, runners: runners, queueLength: working ? (poll % 5) + (h % 3) : 0, longestWait: working ? Double(60 * ((poll % 6) + 1) * (1 + h % 3)) : 0)
            }
        }
        return log
    }
}
