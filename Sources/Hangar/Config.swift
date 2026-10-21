import Foundation

/// Non-secret settings, kept in UserDefaults. The GitHub token is NOT here: see Keychain.
struct Config: Equatable, Sendable {
    enum Key {
        static let profiles = "profiles"
        static let hosts = "hosts"
        static let quietEnabled = "quietEnabled"
        static let checkUpdates = "checkUpdates"
        static let protectJobs = "protectJobs"
        static let quietStart = "quietStart"
        static let quietEnd = "quietEnd"
        static let stallMinutes = "stallMinutes"
        static let pollSeconds = "pollSeconds"
    }

    /// Colima profiles to scan. Runners (and the repos they serve) are discovered inside each VM.
    var profiles: [String] = ["default"]
    /// "local" or an SSH target (key auth only). Each host is scanned for a Colima VM and native runner dirs.
    var hosts: [String] = ["local"]
    var stallMinutes = 10
    var quietEnabled = false
    /// Look for a newer Hangar release on GitHub (on unless switched off).
    var checkUpdates = true
    /// Hold back idle runners on a Mac that reports memory pressure, so the job already running can finish. Off unless switched on.
    var protectJobs = false
    var quietStart = 22
    var quietEnd = 7
    var pollSeconds = 15

    var stallThreshold: TimeInterval { TimeInterval(stallMinutes * 60) }
    var isConfigured: Bool { !profiles.isEmpty }

    static func load(_ d: UserDefaults = .standard) -> Config {
        var c = Config()
        let profiles = list(d.string(forKey: Key.profiles))
        if !profiles.isEmpty { c.profiles = profiles }
        let hosts = list(d.string(forKey: Key.hosts)).filter { $0 == "local" || isSafeHost($0) }
        if !hosts.isEmpty { c.hosts = hosts }
        let stall = d.integer(forKey: Key.stallMinutes)
        if stall > 0 { c.stallMinutes = stall }
        c.quietEnabled = d.bool(forKey: Key.quietEnabled)
        c.protectJobs = d.bool(forKey: Key.protectJobs)
        if d.object(forKey: Key.checkUpdates) != nil { c.checkUpdates = d.bool(forKey: Key.checkUpdates) }
        if d.object(forKey: Key.quietStart) != nil { c.quietStart = min(23, max(0, d.integer(forKey: Key.quietStart))) }
        if d.object(forKey: Key.quietEnd) != nil { c.quietEnd = min(23, max(0, d.integer(forKey: Key.quietEnd))) }
        let poll = d.integer(forKey: Key.pollSeconds)
        if poll > 0 { c.pollSeconds = poll }
        return c
    }

    static func list(_ s: String?) -> [String] {
        (s ?? "").split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map(String.init).filter { !$0.isEmpty }
    }

    /// Profile names and repo names are interpolated into commands and URLs, so keep them boring.
    static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }

    /// An SSH target goes on a command line: no leading dash, no shell characters.
    static func isSafeHost(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && s.allSatisfy { $0.isLetter || $0.isNumber || "-_.@".contains($0) }
    }

    /// Runner directory is interpolated into a remote shell line.
    static func isSafePath(_ s: String) -> Bool {
        !s.isEmpty && !s.contains("..") && s.allSatisfy { $0.isLetter || $0.isNumber || "-_./~".contains($0) }
    }
}
