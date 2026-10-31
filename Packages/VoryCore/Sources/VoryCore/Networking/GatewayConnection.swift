import Foundation

public enum AuthMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case sessionToken
    case password
    case oauth

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .sessionToken: return "Session token"
        case .password: return "Username & password"
        case .oauth: return "Sign in with browser"
        }
    }
    public var usesBearer: Bool { self != .sessionToken }
}

/// Optional Cloudflare Access service-token pair. Headers are attached only when BOTH values are set.
public struct CloudflareAccess: Hashable, Codable, Sendable {
    public var clientId: String = ""
    public var clientSecret: String = ""

    public var isConfigured: Bool { !clientId.isEmpty && !clientSecret.isEmpty }
    public var isPartiallyConfigured: Bool { !isConfigured && (!clientId.isEmpty || !clientSecret.isEmpty) }

    public static let clientIdHeader = "CF-Access-Client-Id"
    public static let clientSecretHeader = "CF-Access-Client-Secret"

    public var headers: [String: String] {
        guard isConfigured else { return [:] }
        return [Self.clientIdHeader: clientId, Self.clientSecretHeader: clientSecret]
    }

    public init(clientId: String = "", clientSecret: String = "") {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }
}

/// Non-secret metadata for one saved gateway. Secrets live in `GatewaySecrets` (Keychain).
public struct GatewayConnection: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var gateway: GatewayURL
    public var authMode: AuthMode
    public var authProvider: String?
    public var createdAt: Date = Date()
    public var lastProfile: String?
    public var hasAccessHeaders: Bool = false
    public var lastVersion: String?
    /// How the phone reaches the gateway ("local", "tailscale", "cloudflare", "other"); only
    /// for the form's help and the list's label, the URL and headers do the work.
    public var connectionKind: String?
    /// A second address for the same gateway (#283), for reaching it both at home and away: a
    /// home-network address beside a Tailscale or tunnel one. Optional, so gateways saved
    /// before it (and by a device that has not got it yet) still decode.
    public var alternate: GatewayURL?

    public init(id: UUID = UUID(), name: String, gateway: GatewayURL, authMode: AuthMode, authProvider: String? = nil, createdAt: Date = Date(), lastProfile: String? = nil, hasAccessHeaders: Bool = false, lastVersion: String? = nil, connectionKind: String? = nil, alternate: GatewayURL? = nil) {
        self.id = id
        self.name = name
        self.gateway = gateway
        self.authMode = authMode
        self.authProvider = authProvider
        self.createdAt = createdAt
        self.lastProfile = lastProfile
        self.hasAccessHeaders = hasAccessHeaders
        self.lastVersion = lastVersion
        self.connectionKind = connectionKind
        self.alternate = alternate
    }

    /// The gateway's addresses: the primary, then the backup when there is one.
    public var addresses: [GatewayURL] { [gateway] + (alternate.map { [$0] } ?? []) }

    /// The same gateway as reached at one of its addresses: that address as `gateway`, the other
    /// as the backup. For what talks to the gateway at the address in use (signing in again);
    /// the saved gateway keeps its primary, which is its identity everywhere else.
    public func using(_ address: GatewayURL) -> GatewayConnection {
        guard address != gateway, address == alternate else { return self }
        var c = self
        c.alternate = gateway
        c.gateway = address
        return c
    }

    /// The demo's gateway (#392): one fixed connection, reached in process (`GatewayTransport`),
    /// never saved, synced or remembered. Its id is the one check everything that persists asks
    /// (`isDemo`, `GatewayRuntime.isEphemeral`); nothing compares its name or address.
    public static let demoID = UUID(uuidString: "D3A0D3A0-0000-4000-8000-00000000DE30")!
    /// `.invalid` never resolves, and only the demo's own transport ever sees it.
    public static let demo = GatewayConnection(id: demoID, name: "Vory demo", gateway: try! GatewayURL.normalize("http://demo.invalid"), authMode: .sessionToken)
    public var isDemo: Bool { id == Self.demoID }
}

/// Everything sensitive for one gateway, stored in the Keychain under the connection id.
public struct GatewaySecrets: Codable, Hashable, Sendable {
    public var sessionToken: String?
    public var accessToken: String?
    public var refreshToken: String?
    public var expiresAt: Double?
    public var provider: String?
    public var userId: String?
    public var access: CloudflareAccess = CloudflareAccess()

    public var bearer: String? { accessToken?.isEmpty == false ? accessToken : nil }
    public var accessTokenExpiresSoon: Bool {
        guard let expiresAt else { return false }
        return Date(timeIntervalSince1970: expiresAt).timeIntervalSinceNow < 60
    }

    public init(sessionToken: String? = nil, accessToken: String? = nil, refreshToken: String? = nil, expiresAt: Double? = nil, provider: String? = nil, userId: String? = nil, access: CloudflareAccess = CloudflareAccess()) {
        self.sessionToken = sessionToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.provider = provider
        self.userId = userId
        self.access = access
    }
}
