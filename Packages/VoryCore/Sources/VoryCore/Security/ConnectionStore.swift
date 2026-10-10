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
    @ObservationIgnored public lazy var remembered: RememberedSignInVault = .standard()
    public var activeConnectionID: UUID? {
        didSet { UserDefaults.standard.set(activeConnectionID?.uuidString, forKey: Self.activeKey) }
    }

    public init() {
        connections = Keychain.getCodable([GatewayConnection].self, account: Self.indexAccount) ?? []
        if let s = UserDefaults.standard.string(forKey: Self.activeKey), let id = UUID(uuidString: s), connections.contains(where: { $0.id == id }) {
            activeConnectionID = id
        } else {
            activeConnectionID = connections.first?.id
        }
    }

    public var active: GatewayConnection? { connections.first { $0.id == activeConnectionID } }

    public func connection(id: UUID) -> GatewayConnection? { connections.first { $0.id == id } }

    public func upsert(_ connection: GatewayConnection, secrets: GatewaySecrets) throws {
        var c = connection
        c.hasAccessHeaders = secrets.access.isConfigured
        // Write the Keychain first so a failure leaves the in-memory list untouched.
        try Keychain.setCodable(secrets, account: secretsAccount(c.id))
        var updated = connections
        if let i = updated.firstIndex(where: { $0.id == c.id }) { updated[i] = c } else { updated.append(c) }
        try Keychain.setCodable(updated, account: Self.indexAccount)
        connections = updated
        if activeConnectionID == nil { activeConnectionID = c.id }
    }

    public func updateMetadata(_ connection: GatewayConnection) {
        if let i = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[i] = connection
            try? persistIndex()
        }
    }

    public func secrets(for id: UUID) -> GatewaySecrets {
        Keychain.getCodable(GatewaySecrets.self, account: secretsAccount(id)) ?? GatewaySecrets()
    }

    public func saveSecrets(_ secrets: GatewaySecrets, for id: UUID) {
        try? Keychain.setCodable(secrets, account: secretsAccount(id))
        if let i = connections.firstIndex(where: { $0.id == id }) {
            connections[i].hasAccessHeaders = secrets.access.isConfigured
            try? persistIndex()
        }
    }

    public func delete(id: UUID) {
        connections.removeAll { $0.id == id }
        Keychain.delete(account: secretsAccount(id))
        // A sign-in remembered for it goes with it (a delete needs no Face ID).
        remembered.forget(id)
        try? persistIndex()
        if activeConnectionID == id { activeConnectionID = connections.first?.id }
    }

    private func secretsAccount(_ id: UUID) -> String { "secrets." + id.uuidString }

    private func persistIndex() throws { try Keychain.setCodable(connections, account: Self.indexAccount) }
}
