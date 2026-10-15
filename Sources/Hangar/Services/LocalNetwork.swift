import Foundation
import Network

/// Local Network permission helpers (issue 21). macOS has no "ask now" call: the prompt appears the first time an app
/// tries to reach another machine on the network, and until it is allowed the attempt fails with "No route to host".
enum LocalNetwork {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    /// "me@mac-mini.local" -> "mac-mini.local"; "192.168.1.5" -> "192.168.1.5".
    static func hostName(fromTarget target: String) -> String {
        target.split(separator: "@").last.map(String.init) ?? target
    }

    /// Addresses the Local Network permission governs: private IPv4 ranges, link-local, and .local names.
    static func isLocalAddress(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.hasSuffix(".local") || h.hasSuffix(".lan") || h.hasSuffix(".home.arpa") { return true }
        let p = h.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (p[0], p[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    struct Problem: Equatable {
        var message: String
        var needsLocalNetwork: Bool
    }

    /// What to tell the user when `target` could not be reached. Only "No route to host" to a local address is blamed on
    /// the permission; anything else (host off, key refused, timeout) keeps its real text.
    static func explain(target: String, reason: String) -> Problem {
        let host = hostName(fromTarget: target)
        let raw = "\(target) unreachable" + (reason.isEmpty ? "" : " (\(reason))")
        if isLocalAddress(host), reason.localizedCaseInsensitiveContains("no route to host") {
            return Problem(message: "Can't reach \(host). If macOS has not asked yet, allow Hangar under Local Network: it needs that to reach your other Macs.",
                           needsLocalNetwork: true)
        }
        return Problem(message: raw, needsLocalNetwork: false)
    }

    /// One brief connection to an SSH host's port so the permission prompt appears now, not after the first failed poll.
    /// Result is ignored; it returns as soon as the attempt succeeds, fails, or three seconds pass.
    static func prime(target: String, port: UInt16 = 22, timeout: TimeInterval = 3) async {
        let host = hostName(fromTarget: target)
        guard let p = NWEndpoint.Port(rawValue: port), !host.isEmpty else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled: if once.take() { conn.cancel(); cont.resume() }
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if once.take() { conn.cancel(); cont.resume() } }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}

/// The one-time first-launch note (issue 21).
enum Welcome {
    static let key = "welcomeDismissed"
    static let text = "macOS will ask Hangar for Notifications and for Local Network access (to reach your other Macs). Please allow both."

    static func shouldShow(_ d: UserDefaults = .standard) -> Bool { !d.bool(forKey: key) }
    static func dismiss(_ d: UserDefaults = .standard) { d.set(true, forKey: key) }
}
