import Foundation

enum HostRetention {
    /// Runners from hosts that could not be reached this poll, carried over greyed out with the time they were last seen.
    /// A runner that is merely absent from a reachable host (stopped, deregistered) is not carried over.
    static func carryOver(previous: [Runner], current: [Runner], unreachable: Set<String>, lastSeen: [String: Date]) -> [Runner] {
        let present = Set(current.map(\.id))
        return previous.filter { !present.contains($0.id) && unreachable.contains($0.host) }.map { old in
            var r = old
            r.state = .unreachable
            r.job = nil
            r.draining = false
            r.lastSeenAt = old.lastSeenAt ?? lastSeen[old.id]
            return r
        }
    }
}

enum TokenExpiry {
    /// GitHub's header format is not in its REST reference, so accept the shapes it is reported to use.
    static func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for f in ["yyyy-MM-dd HH:mm:ss 'UTC'", "yyyy-MM-dd HH:mm:ss 'GMT'", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss ZZZZZ", "yyyy-MM-dd"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "UTC"); df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }

    /// Shown from 14 days out, and after expiry; nothing when the date is unknown or far away.
    static func warning(expiry: Date?, now: Date) -> String? {
        guard let e = expiry else { return nil }
        if e <= now { return "The GitHub token has expired" }
        let days = Int((e.timeIntervalSince(now) / 86_400).rounded(.up))
        guard days <= 14 else { return nil }
        return days <= 1 ? "The GitHub token expires within a day" : "The GitHub token expires in \(days) days"
    }
}
