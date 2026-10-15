import Foundation

/// How fresh the data is (issue 8).
enum Freshness {
    /// Stale after three missed polls, or when the last success is older than three poll intervals.
    static func isStale(lastSuccess: Date?, now: Date, pollSeconds: Int, consecutiveFailures: Int) -> Bool {
        if consecutiveFailures >= 3 { return true }
        guard let last = lastSuccess else { return false }                    // nothing yet: not stale, just empty
        return now.timeIntervalSince(last) > TimeInterval(max(1, pollSeconds)) * 3
    }

    static func ageText(lastSuccess: Date?, now: Date) -> String {
        guard let last = lastSuccess else { return "waiting for first update" }
        let s = Int(max(0, now.timeIntervalSince(last)))
        if s < 5 { return "updated just now" }
        if s < 60 { return "updated \(s)s ago" }
        return "updated \(Format.duration(TimeInterval(s))) ago"
    }
}

/// Rate-limit delays from GitHub's response headers (issue 9).
enum RateLimit {
    static let maxDelay: TimeInterval = 15 * 60

    /// Seconds to wait, from `retry-after` (seconds) or `x-ratelimit-reset` (epoch seconds); nil if neither is usable.
    static func delay(retryAfter: String?, resetEpoch: String?, now: Date) -> TimeInterval? {
        var d: TimeInterval?
        if let r = retryAfter.flatMap(TimeInterval.init) { d = r }
        else if let e = resetEpoch.flatMap(TimeInterval.init) { d = Date(timeIntervalSince1970: e).timeIntervalSince(now) }
        guard let d else { return nil }
        return min(maxDelay, max(1, d))
    }

    /// Transient errors worth one quick retry.
    static func isTransient(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains(u.code)
    }
}

/// A restart is only done when GitHub shows the runner online again (issue 11).
enum RestartWatch {
    static let timeout: TimeInterval = 180

    static func timedOut(since: Date, now: Date) -> Bool { now.timeIntervalSince(since) >= timeout }
}

/// Low disk space on a runner's filesystem (issue 15).
enum DiskRule {
    static let minFreeGB = 10.0
    static let maxUsedPct = 90

    static func warning(freeKB: Int?, usedPct: Int?, vm: Bool = false) -> String? {
        guard let freeKB else { return nil }
        let free = Double(freeKB) / 1_048_576
        let low = free < minFreeGB || (usedPct ?? 0) >= maxUsedPct
        guard low else { return nil }
        // Short enough for a card: free space when it is the problem, otherwise how full the disk is.
        let name = vm ? "VM disk" : "Disk"
        if free < minFreeGB { return String(format: "\(name) low: %.1f GB free", free) }
        return "\(name) \(usedPct ?? 0)% full"
    }
}

/// Runner version drift (issue 16).
enum VersionCheck {
    /// "v2.338.0" and "2.338.0" both parse; anything else is nil.
    static func parse(_ s: String) -> [Int]? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "v" || $0 == "V" }
        let parts = t.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    static func isBehind(current: String, latest: String) -> Bool {
        guard let c = parse(current), let l = parse(latest) else { return false }
        for i in 0..<max(c.count, l.count) {
            let a = i < c.count ? c[i] : 0, b = i < l.count ? l[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}

/// An optional window in which non-urgent notifications are held (issue 17). Hours are 0-23; it may cross midnight.
enum QuietHours {
    static func isQuiet(hour: Int, minute: Int, startHour: Int, endHour: Int, enabled: Bool) -> Bool {
        guard enabled, startHour != endHour else { return false }
        let now = hour * 60 + minute, s = startHour * 60, e = endHour * 60
        return s < e ? (now >= s && now < e) : (now >= s || now < e)
    }

    static func isQuiet(_ date: Date, config: Config, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return isQuiet(hour: c.hour ?? 0, minute: c.minute ?? 0, startHour: config.quietStart, endHour: config.quietEnd, enabled: config.quietEnabled)
    }
}

/// Learned job durations and failure streaks, kept on disk; keys and numbers only (issues 13 and 14).
struct JobHistory: Codable, Equatable, Sendable {
    static let keepLast = 20
    static let minSamples = 5

    var durations: [String: [Double]] = [:]
    var streaks: [String: Int] = [:]

    static func key(repo: String, workflow: String, job: String) -> String { "\(repo)|\(workflow)|\(job)" }
    static func streakKey(runner: String, jobKey: String) -> String { "\(runner)|\(jobKey)" }

    mutating func recordSuccess(jobKey: String, runner: String, seconds: Double) {
        guard seconds > 0 else { return }
        durations[jobKey] = Array(((durations[jobKey] ?? []) + [seconds]).suffix(Self.keepLast))
        streaks[Self.streakKey(runner: runner, jobKey: jobKey)] = nil
    }

    mutating func recordFailure(jobKey: String, runner: String) { streaks[Self.streakKey(runner: runner, jobKey: jobKey), default: 0] += 1 }

    func median(jobKey: String) -> Double? {
        guard let d = durations[jobKey], d.count >= Self.minSamples else { return nil }
        let s = d.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// How many times longer than usual, when it is over twice the median and over ten minutes.
    func longRunFactor(jobKey: String, elapsed: Double) -> Double? {
        guard let m = median(jobKey: jobKey), m > 0, elapsed > 600, elapsed > 2 * m else { return nil }
        return elapsed / m
    }

    /// The longest current streak for this runner, if it reached three.
    func streak(runner: String) -> Int? {
        let prefix = runner + "|"
        let n = streaks.filter { $0.key.hasPrefix(prefix) }.map(\.value).max() ?? 0
        return n >= 3 ? n : nil
    }
}

extension JobHistory {
    static func defaultURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Hangar", isDirectory: true).appendingPathComponent("jobs.json")
    }

    static func load(from url: URL? = defaultURL()) -> JobHistory {
        guard let url, let d = try? Data(contentsOf: url), let h = try? JSONDecoder().decode(JobHistory.self, from: d) else { return JobHistory() }
        return h
    }

    func save(to url: URL? = defaultURL()) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: url, options: .atomic) }
    }
}
