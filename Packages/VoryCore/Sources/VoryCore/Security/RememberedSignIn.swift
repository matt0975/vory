import Foundation
import LocalAuthentication
import Observation
import Security

/// What signs a gateway in again with nobody typing: the username and password of a password
/// sign-in, kept only when the person turns on "Remember sign-in on this device". It lives in a
/// Keychain item of its own (see `KeychainRememberedSignInBackend`), never in `GatewaySecrets`,
/// so nothing that copies those (the iCloud backup, the watch's context) can carry it.
public struct RememberedSignIn: Codable, Equatable, Sendable {
    public var provider: String
    public var username: String
    public var password: String

    public init(provider: String, username: String, password: String) {
        self.provider = provider
        self.username = username
        self.password = password
    }
}

/// Never printed: a log line, a `print` or a `dump` says there is one, not what it holds.
extension RememberedSignIn: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "RememberedSignIn(provider: \(provider), credentials hidden)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["provider": provider], displayStyle: .struct) }
}

/// Where remembered sign-ins are kept: the device Keychain in the app, a dictionary in tests and
/// in the demo copy (which has no Keychain it may use).
public protocol RememberedSignInBackend: AnyObject {
    func write(_ data: Data, account: String) throws
    /// The item's data, read with `context`: an already evaluated Face ID or passcode check, so
    /// the Keychain does not ask a second time. nil when there is no item.
    func read(account: String, context: LAContext?) throws -> Data?
    func delete(account: String)
    /// Every account that has an item, from the attributes alone: nothing is unlocked or asked.
    func accounts() -> [String]
}

/// The device Keychain, with the strictest protection it offers: this device only, never
/// synced, only while a passcode is set, and only after Face ID, Touch ID or the passcode.
public final class KeychainRememberedSignInBackend: RememberedSignInBackend {
    /// A service of its own, apart from `Keychain.service` and `Keychain.cloudService`: the
    /// access-group migration and the iCloud copy read every item of theirs, which for these
    /// would mean a Face ID prompt at launch, or a password on its way to iCloud.
    public static let service = Keychain.baseBundleID + ".remembered"
    /// Only on this device and only while it has a passcode: turning the passcode off deletes
    /// the item, and no backup restores it anywhere else.
    public static var protection: CFString { kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
    /// Face ID or Touch ID, or the passcode (the Mac's password) when biometry is not set up.
    public static let accessFlags: SecAccessControlCreateFlags = .userPresence

    public init() {}

    /// What finds one item. Never synchronizable, so iCloud Keychain does not carry it.
    public static func query(account: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: false]
        if let account { q[kSecAttrAccount as String] = account }
        if let g = Keychain.accessGroup { q[kSecAttrAccessGroup as String] = g }
        #if os(macOS)
        // The iOS-style keychain on the Mac too: the legacy file keychain ignores access control.
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    public static func accessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, protection, accessFlags, &error) else {
            throw error.map { $0.takeRetainedValue() as Error } ?? KeychainError(status: errSecParam)
        }
        return control
    }

    /// Everything a new item is written with. The access control carries the protection class,
    /// so `kSecAttrAccessible` is not set beside it (the two together are refused).
    public static func addAttributes(_ data: Data, account: String) throws -> [String: Any] {
        var q = query(account: account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessControl as String] = try accessControl()
        return q
    }

    public func write(_ data: Data, account: String) throws {
        // Replaced rather than updated: changing a protected item asks for Face ID, deleting
        // one does not, and the person just signed in by hand.
        SecItemDelete(Self.query(account: account) as CFDictionary)
        let status = SecItemAdd(try Self.addAttributes(data, account: account) as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func read(account: String, context: LAContext?) throws -> Data? {
        var q = Self.query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context { q[kSecUseAuthenticationContext as String] = context }
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return out as? Data
    }

    public func delete(account: String) {
        SecItemDelete(Self.query(account: account) as CFDictionary)
    }

    public func accounts() -> [String] {
        var q = Self.query(account: nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        // Attributes need no unlock; a context that may not ask makes sure nothing does.
        let quiet = LAContext()
        quiet.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = quiet
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// A dictionary: the tests' Keychain, and the demo copy's.
public final class MemoryRememberedSignInBackend: RememberedSignInBackend {
    public private(set) var items: [String: Data] = [:]
    /// How many reads were given an evaluated context, for tests that check the prompt's
    /// answer is what opens the item.
    public private(set) var readsWithContext = 0
    public init() {}
    public func write(_ data: Data, account: String) throws { items[account] = data }
    public func read(account: String, context: LAContext?) throws -> Data? {
        if context != nil { readsWithContext += 1 }
        return items[account]
    }
    public func delete(account: String) { items[account] = nil }
    public func accounts() -> [String] { Array(items.keys) }
}

/// The sign-ins remembered on this device, one per gateway, and which gateways have one.
@MainActor
@Observable
public final class RememberedSignInVault {
    /// Gateways with a sign-in remembered here, known without a prompt.
    public private(set) var ids: Set<UUID> = []
    private let backend: any RememberedSignInBackend

    public init(backend: any RememberedSignInBackend) {
        self.backend = backend
        ids = Set(backend.accounts().compactMap(Self.id(account:)))
    }

    /// The device Keychain; in the demo copy, memory.
    public static func standard() -> RememberedSignInVault {
        #if DEBUG
        if Keychain.memoryOnly { return RememberedSignInVault(backend: MemoryRememberedSignInBackend()) }
        #endif
        return RememberedSignInVault(backend: KeychainRememberedSignInBackend())
    }

    nonisolated static func account(_ id: UUID) -> String { "signin." + id.uuidString }
    nonisolated static func id(account: String) -> UUID? {
        account.hasPrefix("signin.") ? UUID(uuidString: String(account.dropFirst("signin.".count))) : nil
    }

    public func contains(_ id: UUID) -> Bool { ids.contains(id) }

    public func remember(_ signIn: RememberedSignIn, for id: UUID) throws {
        try backend.write(JSONEncoder().encode(signIn), account: Self.account(id))
        ids.insert(id)
    }

    /// The remembered sign-in, opened with `context` (the evaluated Face ID or passcode check).
    /// nil when it is gone: the passcode was turned off, which deletes it, or it was forgotten.
    public func signIn(for id: UUID, context: LAContext?) throws -> RememberedSignIn? {
        guard let data = try backend.read(account: Self.account(id), context: context) else {
            ids.remove(id)
            return nil
        }
        return try JSONDecoder().decode(RememberedSignIn.self, from: data)
    }

    /// Deleting needs no Face ID, so this works from anywhere, the gateway's removal included.
    public func forget(_ id: UUID) {
        backend.delete(account: Self.account(id))
        ids.remove(id)
    }
}
