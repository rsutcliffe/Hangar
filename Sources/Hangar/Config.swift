import Foundation

/// Non-secret settings, kept in UserDefaults. The GitHub token is NOT here: see Keychain.
struct Config: Equatable, Sendable {
    enum Key {
        static let profiles = "profiles"
        static let stallMinutes = "stallMinutes"
        static let pollSeconds = "pollSeconds"
    }

    /// Colima profiles to scan. Runners (and the repos they serve) are discovered inside each VM.
    var profiles: [String] = ["default"]
    var stallMinutes = 10
    var pollSeconds = 15

    var stallThreshold: TimeInterval { TimeInterval(stallMinutes * 60) }
    var isConfigured: Bool { !profiles.isEmpty }

    static func load(_ d: UserDefaults = .standard) -> Config {
        var c = Config()
        let profiles = list(d.string(forKey: Key.profiles))
        if !profiles.isEmpty { c.profiles = profiles }
        let stall = d.integer(forKey: Key.stallMinutes)
        if stall > 0 { c.stallMinutes = stall }
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

    /// Runner directory is interpolated into a remote shell line.
    static func isSafePath(_ s: String) -> Bool {
        !s.isEmpty && !s.contains("..") && s.allSatisfy { $0.isLetter || $0.isNumber || "-_./~".contains($0) }
    }
}
