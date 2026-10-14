import Foundation
import Security

/// The GitHub token lives only here. It is never written to UserDefaults, disk or logs.
enum Keychain {
    /// Read once per launch and cached. Every poll reading the Keychain would re-prompt each time access is denied.
    nonisolated(unsafe) private static var cache: String??
    private static let lock = NSLock()

    static func token() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        let v = read()
        cache = .some(v)
        return v
    }

    private static func invalidate() { lock.lock(); cache = nil; lock.unlock() }

    private static let service = "hangar.github-token"
    private static let account = "default"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ token: String) -> Bool {
        defer { invalidate() }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete() }
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        defer { invalidate() }
        let s = SecItemDelete(base as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }
}
