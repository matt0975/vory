import Foundation
import Observation

/// Saved gateways. Metadata and secrets both live in the Keychain; only the active id is in UserDefaults.
@MainActor
@Observable
public final class ConnectionStore {
    private static let indexAccount = "connections.index"
    private static let activeKey = "activeConnectionID"

    public private(set) var connections: [GatewayConnection] = []
    /// Sign-ins the person asked this device to remember, behind Face ID or the passcode. Apart
    /// from `secrets(for:)`, so nothing that copies those (iCloud, the watch) ever sees them.
    /// Opened on first use, so a process that never asks (the extensions) never reads it.
    @ObservationIgnored public lazy var remembered: RememberedSignInVault =
        keepsNothing ? RememberedSignInVault(backend: MemoryRememberedSignInBackend()) : .standard()
    /// The gateway in use. `GatewayConnection.demoID` makes the demo the one in use until another
    /// id is set; the demo is never written anywhere (`demo`).
    public var activeConnectionID: UUID? {
        get { demo?.id ?? savedActiveID }
        set {
            if newValue == GatewayConnection.demoID { demo = .demo; return }
            demo = nil
            savedActiveID = newValue
        }
    }
    /// The saved gateway in use, kept in the defaults (this device's own, never synced).
    private var savedActiveID: UUID? {
        didSet { if !keepsNothing { defaults.set(savedActiveID?.uuidString, forKey: Self.activeKey) } }
    }
    private let defaults: UserDefaults
    /// A store that never reaches the Keychain or the defaults (`demoOnly()`).
    private let keepsNothing: Bool
    /// The demo while it runs (#392), in memory only: never in the Keychain, the defaults or
    /// iCloud, so a relaunch, after a crash mid-demo too, comes back on the saved gateway, and no
    /// other device ever switches to it.
    public private(set) var demo: GatewayConnection?

    /// Leaves the demo: the saved gateway that was in use before it (kept all along) is the one in use again.
    public func leaveDemo() { demo = nil }

    public convenience init() {
        self.init(defaults: .standard, connections: Keychain.getCodable([GatewayConnection].self, account: Self.indexAccount) ?? [])
    }

    /// A store with the demo in it and nothing else, for a demo that is not the app's gateway in use (onboarding's tour,
    /// #388, runs one of its own). Nothing it is asked reaches the Keychain or the defaults: no saved list is read, a
    /// save or a sign-in goes nowhere, and a remembered sign-in is kept in memory.
    public static func demoOnly() -> ConnectionStore {
        let store = ConnectionStore(defaults: .standard, connections: [], keepsNothing: true)
        store.activeConnectionID = GatewayConnection.demoID
        return store
    }

    /// The saved list as read, and the defaults the gateway in use is kept in (tests give their own).
    init(defaults: UserDefaults, connections: [GatewayConnection], keepsNothing: Bool = false) {
        self.defaults = defaults
        self.connections = connections
        self.keepsNothing = keepsNothing
        if !keepsNothing, let s = defaults.string(forKey: Self.activeKey), let id = UUID(uuidString: s), connections.contains(where: { $0.id == id }) {
            savedActiveID = id
        } else {
            savedActiveID = connections.first?.id
        }
    }

    public var active: GatewayConnection? { demo ?? connections.first { $0.id == savedActiveID } }

    public func connection(id: UUID) -> GatewayConnection? {
        if id == GatewayConnection.demoID { return demo }
        return connections.first { $0.id == id }
    }

    public func upsert(_ connection: GatewayConnection, secrets: GatewaySecrets) throws {
        // The demo is never saved, nor anything in a store that keeps nothing.
        guard !connection.isDemo, !keepsNothing else { return }
        var c = connection
        c.hasAccessHeaders = secrets.access.isConfigured
        // Write the Keychain first so a failure leaves the in-memory list untouched.
        try Keychain.setCodable(secrets, account: secretsAccount(c.id))
        var updated = connections
        if let i = updated.firstIndex(where: { $0.id == c.id }) { updated[i] = c } else { updated.append(c) }
        try Keychain.setCodable(updated, account: Self.indexAccount)
        connections = updated
        if savedActiveID == nil { savedActiveID = c.id }
    }

    public func updateMetadata(_ connection: GatewayConnection) {
        if connection.isDemo { if demo != nil { demo = connection }; return }
        if let i = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[i] = connection
            try? persistIndex()
        }
    }

    public func secrets(for id: UUID) -> GatewaySecrets {
        if id == GatewayConnection.demoID || keepsNothing { return GatewaySecrets() }
        return Keychain.getCodable(GatewaySecrets.self, account: secretsAccount(id)) ?? GatewaySecrets()
    }

    public func saveSecrets(_ secrets: GatewaySecrets, for id: UUID) {
        guard id != GatewayConnection.demoID, !keepsNothing else { return }
        try? Keychain.setCodable(secrets, account: secretsAccount(id))
        if let i = connections.firstIndex(where: { $0.id == id }) {
            connections[i].hasAccessHeaders = secrets.access.isConfigured
            try? persistIndex()
        }
    }

    public func delete(id: UUID) {
        if id == GatewayConnection.demoID { demo = nil; return }
        guard !keepsNothing else { return }
        connections.removeAll { $0.id == id }
        Keychain.delete(account: secretsAccount(id))
        // A sign-in remembered for it goes with it (a delete needs no Face ID).
        remembered.forget(id)
        try? persistIndex()
        if savedActiveID == id { savedActiveID = connections.first?.id }
    }

    private func secretsAccount(_ id: UUID) -> String { "secrets." + id.uuidString }

    private func persistIndex() throws {
        guard !keepsNothing else { return }
        try Keychain.setCodable(connections, account: Self.indexAccount)
    }
}
