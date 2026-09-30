import Foundation
import Security

/// Thin wrapper over the generic-password keychain. Items live in `accessGroup` when one is set,
/// which is how the app, its widgets and the watch app read the same gateways and the same
/// widget snapshot without an App Group.
public enum Keychain {
    /// Keyed on the app's bundle id even inside an extension (the notification service, widgets,
    /// the watch app), so every process reads the same items.
    public static let service = baseBundleID + ".gateways"

    /// The host app's bundle id, with any extension / companion suffix stripped.
    public static var baseBundleID: String {
        var base = Bundle.main.bundleIdentifier ?? "Vory"
        for marker in [".watchkitapp", ".LiveActivity", ".widgets", ".complications", ".notifications"] {
            if let r = base.range(of: marker) { base = String(base[..<r.lowerBound]) }
        }
        return base
    }
    /// `TEAMID.com.vorantx.vory.shared` (from `keychain-access-groups`); nil keeps the default group.
    nonisolated(unsafe) public static var accessGroup: String?

    private static func base(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let g = accessGroup { q[kSecAttrAccessGroup as String] = g }
        return dataProtected(q)
    }

    /// On macOS `SecItem*` defaults to the legacy file keychain, where access groups and the
    /// accessibility class mean nothing; this flag selects the iOS-style keychain instead, so the
    /// Mac app and its extensions share items the same way the iPhone does. A no-op elsewhere.
    private static func dataProtected(_ q: [String: Any]) -> [String: Any] {
        #if os(macOS)
        var q = q
        q[kSecUseDataProtectionKeychain as String] = true
        return q
        #else
        return q
        #endif
    }

    public static func set(_ data: Data, account: String) throws {
        let query = base(account)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            let add = query.merging(attrs) { $1 }
            let s2 = SecItemAdd(add as CFDictionary, nil)
            guard s2 == errSecSuccess else { throw KeychainError(status: s2) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public static func get(account: String) -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    public static func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    public static func setCodable<T: Encodable>(_ value: T, account: String) throws {
        try set(try JSONEncoder().encode(value), account: account)
    }

    public static func getCodable<T: Decodable>(_ type: T.Type, account: String) -> T? {
        get(account: account).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    /// Moves items written before `accessGroup` existed into the group so widgets can see them.
    /// Runs in a few milliseconds and is a no-op once everything has moved.
    public static func migrateToAccessGroupIfNeeded() {
        guard let group = accessGroup else { return }
        let q: [String: Any] = dataProtected([kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: service,
                                              kSecReturnAttributes as String: true,
                                              kSecReturnData as String: true,
                                              kSecMatchLimit as String: kSecMatchLimitAll])
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return }
        for item in items where (item[kSecAttrAccessGroup as String] as? String) != group {
            guard let account = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data else { continue }
            if (try? set(data, account: account)) != nil {
                var old: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
                if let g = item[kSecAttrAccessGroup as String] as? String { old[kSecAttrAccessGroup as String] = g }
                SecItemDelete(dataProtected(old) as CFDictionary)
            }
        }
    }

    /// Resolves the shared group from the bundle: `<AppIdentifierPrefix><base bundle id>.shared`,
    /// where the base id strips `.watchkitapp…` / `.LiveActivity` / other extension suffixes.
    public static func sharedGroupFromBundle() -> String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String, !prefix.isEmpty else { return nil }
        return prefix + baseBundleID + ".shared"
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
    public var errorDescription: String? { "Keychain error \(status)" }
}
