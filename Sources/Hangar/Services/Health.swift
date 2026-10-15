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
