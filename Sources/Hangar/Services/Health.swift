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

enum RunnerUpdate {
    /// How long a new runner release is left to install itself before Hangar calls the runner overdue.
    static let grace: TimeInterval = 14 * 86400
}

/// A Mac's own memory state. A Linux VM cannot see it: when macOS is short of memory it pushes the VM's pages out to disk,
/// and everything in the VM slows down with no error and nothing in the VM's own logs.
struct HostMemory: Equatable, Sendable {
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    var pressureLevel: Int
    var swapUsedMB: Double
    var swapTotalMB: Double
    var ramGB: Double

    /// `sysctl -n` output of the pressure level, vm.swapusage and hw.memsize, one per line.
    static func parse(_ out: String) -> HostMemory? {
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3, let level = Int(lines[0]), let bytes = Double(lines[2]) else { return nil }
        func mb(_ key: String) -> Double? {
            guard let r = lines[1].range(of: "\(key) = ") else { return nil }
            let rest = lines[1][r.upperBound...].prefix { !$0.isWhitespace }
            guard let unit = rest.last, let n = Double(rest.dropLast()) else { return nil }
            return unit == "G" ? n * 1024 : unit == "K" ? n / 1024 : n
        }
        guard let used = mb("used"), let total = mb("total") else { return nil }
        return HostMemory(pressureLevel: level, swapUsedMB: used, swapTotalMB: total, ramGB: bytes / 1_073_741_824)
    }
}

extension HostMemory {
    /// The fourth line of the same output: the Mac's hostname, as "iMac.local".
    static func parseName(_ out: String) -> String? {
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.count >= 4 && !lines[3].isEmpty ? lines[3] : nil
    }
}

enum MemoryRule {
    static let swapFullPct = 75
    static let swapMinUsedMB = 2048.0

    /// A card line and its tooltip, when the Mac is short of memory: the system says so, or most of its swap is in use.
    static func warning(_ m: HostMemory?) -> (text: String, help: String)? {
        guard let m else { return nil }
        let used = String(format: "%.1f of %.1f GB swap in use", m.swapUsedMB / 1024, m.swapTotalMB / 1024)
        let why = "A Linux VM on this Mac slows down when macOS is short of memory, with no error inside the VM. \(used)."
        if m.pressureLevel >= 4 { return ("Mac memory pressure: critical", why) }
        if m.pressureLevel >= 2 { return ("Mac memory pressure: high", why) }
        let pct = m.swapTotalMB > 0 ? Int((m.swapUsedMB / m.swapTotalMB * 100).rounded()) : 0
        if pct >= swapFullPct, m.swapUsedMB >= swapMinUsedMB { return ("Mac swap \(pct)% full", why) }
        return nil
    }
}

/// "Failed N times in a row" is only useful while it is current: an hour after the last failure it leaves the main window.
/// The failures themselves stay in the Capacity window's list.
enum StreakRule {
    static let window: TimeInterval = 3600

    static func shown(_ streak: Int?, lastFailure: Date?, now: Date) -> Int? {
        guard let streak, let lastFailure, now.timeIntervalSince(lastFailure) <= window else { return nil }
        return streak
    }
}

/// Under memory pressure, keep a Mac to the job it is already running: idle runners wait, and busy ones are never touched.
enum ThrottleRule {
    /// How long memory has to stay normal before held runners are let go.
    static let calmFor: TimeInterval = 300

    struct Candidate: Equatable, Sendable {
        var id: String
        var busy: Bool
        /// Idle, online, and not already paused or restarting by the user.
        var canHold: Bool
        var held: Bool
    }

    struct Decision: Equatable, Sendable { var hold: [String] = []; var release: [String] = [] }

    /// One Mac's runners. Held runners come back when memory has been normal for `calmFor`, when nothing on the Mac is running
    /// (so queued work cannot wait forever on a stale reading), or when the setting is switched off.
    static func decide(_ runners: [Candidate], protect: Bool, underPressure: Bool, calmSince: Date?, now: Date) -> Decision {
        let anyBusy = runners.contains { $0.busy }
        var d = Decision()
        if protect, underPressure, anyBusy { d.hold = runners.filter { $0.canHold && !$0.held }.map(\.id) }
        let calm = !underPressure && calmSince.map { now.timeIntervalSince($0) >= calmFor } == true
        if !protect || calm || !anyBusy { d.release = runners.filter(\.held).map(\.id) }
        return d
    }
}
