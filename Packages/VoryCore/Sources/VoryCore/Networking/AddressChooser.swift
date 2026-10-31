import Foundation

/// What a gateway's public status says about which gateway it is (#283). Hermes's
/// `/api/status` carries no id; an open gateway (no sign-in) names its home and config
/// paths, and every gateway names its sign-in shape. Two answers from the same gateway agree
/// on all of these; a stranger's device that happens to sit at a home address seldom does.
public struct GatewayIdentity: Codable, Equatable, Sendable {
    public var hermesHome: String?
    public var configPath: String?
    public var authRequired: Bool?
    public var authFlows: [String]?
    public var authProviders: [String]?

    public init(hermesHome: String? = nil, configPath: String? = nil, authRequired: Bool? = nil, authFlows: [String]? = nil, authProviders: [String]? = nil) {
        self.hermesHome = hermesHome
        self.configPath = configPath
        self.authRequired = authRequired
        self.authFlows = authFlows
        self.authProviders = authProviders
    }

    /// Whether this answer can be the gateway that last answered as `known`: every field both
    /// have must agree (the lists as sets). Nothing known yet agrees with anything.
    public func matches(_ known: GatewayIdentity?) -> Bool {
        guard let known else { return true }
        if let a = hermesHome, let b = known.hermesHome, a != b { return false }
        if let a = configPath, let b = known.configPath, a != b { return false }
        if let a = authRequired, let b = known.authRequired, a != b { return false }
        if let a = authFlows, let b = known.authFlows, Set(a) != Set(b) { return false }
        if let a = authProviders, let b = known.authProviders, Set(a) != Set(b) { return false }
        return true
    }
}

/// Picks which of a gateway's two addresses to connect to (#283): both are asked for their
/// public status at once; the one that worked last has a short head start, then the first
/// good answer wins. A good answer is a 200 whose body is Hermes's status and agrees with what
/// this gateway said before (`GatewayIdentity`). The probe carries no credentials at all, so
/// an address that turns out to be someone else's device (a home address seen from another
/// network) never sees the gateway's token: no session token, no bearer, no cookies, and
/// Cloudflare Access headers only to a public https host (whose name TLS vouches for).
public enum AddressChooser {
    /// How long the address that worked last is waited for before another answer is taken.
    public static let headStart: Duration = .milliseconds(300)
    /// How long a probe may take: past this the address counts as not answering.
    public static let timeout: TimeInterval = 2.5

    public struct Choice: Sendable, Equatable {
        public var index: Int
        public var identity: GatewayIdentity
    }

    /// The status fields the probe reads: enough to tell Hermes from anything else answering.
    struct Status: Decodable {
        var version: String?
        var gatewayRunning: Bool?
        var gatewayState: String?
        var authRequired: Bool?
        var authFlows: [String]?
        var authProviders: [String]?
        var hermesHome: String?
        var configPath: String?

        enum CodingKeys: String, CodingKey {
            case version, gatewayRunning = "gateway_running", gatewayState = "gateway_state"
            case authRequired = "auth_required", authFlows = "auth_flows", authProviders = "auth_providers"
            case hermesHome = "hermes_home", configPath = "config_path"
        }

        /// Hermes's status: a version, the gateway's running state and the sign-in shape.
        var isHermes: Bool { version?.isEmpty == false && authRequired != nil && (gatewayRunning != nil || gatewayState != nil) }
        var identity: GatewayIdentity {
            GatewayIdentity(hermesHome: hermesHome, configPath: configPath, authRequired: authRequired, authFlows: authFlows, authProviders: authProviders)
        }
    }

    /// One address's answer as an identity, or nil when it is not this gateway's kind of answer.
    public typealias Probe = @Sendable (GatewayURL) async -> GatewayIdentity?

    /// Chooses between `addresses` (two). `lastGood` is the index that worked last (it gets the
    /// head start); `known` is what this gateway said before. Nil when no address gave a good
    /// answer in time: the caller keeps to the address it would have used anyway.
    public static func choose(addresses: [GatewayURL], lastGood: Int?, known: GatewayIdentity?,
                              probe: @escaping Probe, headStart: Duration = AddressChooser.headStart) async -> Choice? {
        guard !addresses.isEmpty else { return nil }
        let preferred = lastGood.flatMap { addresses.indices.contains($0) ? $0 : nil } ?? 0
        return await withTaskGroup(of: (Int, GatewayIdentity?).self) { group in
            for (i, a) in addresses.enumerated() { group.addTask { (i, await probe(a)) } }
            group.addTask { try? await Task.sleep(for: headStart); return (-1, nil) }
            var waiting: Choice?          // a good answer from another address, waiting out the head start
            var headStartOver = false
            var preferredOut = false      // the preferred address answered badly or not at all
            var answers = 0
            var chosen: Choice?
            for await (i, identity) in group {
                if i == -1 {
                    headStartOver = true
                    if let waiting { chosen = waiting; break }
                    continue
                }
                answers += 1
                if let identity, identity.matches(known) {
                    let c = Choice(index: i, identity: identity)
                    if i == preferred || headStartOver || preferredOut { chosen = c; break }
                    if waiting == nil { waiting = c }
                } else if i == preferred {
                    preferredOut = true
                    if let waiting { chosen = waiting; break }
                }
                if answers == addresses.count { chosen = waiting; break }
            }
            group.cancelAll()
            return chosen
        }
    }

    /// The real probe: `GET /api/status` on a session that keeps nothing (no cookies, no cache),
    /// follows no redirect and sends no credentials; Cloudflare Access headers only to a public
    /// https host.
    public static func statusProbe(accessHeaders: [String: String], configuration: URLSessionConfiguration = probeConfiguration()) -> Probe {
        statusProbe(accessHeaders: accessHeaders, session: URLSession(configuration: configuration))
    }

    /// The probe on a session the caller keeps (one per runtime, invalidated when it stops: a
    /// session made per choice would be kept alive by URLSession until invalidated, and a long
    /// outage asks again every few seconds).
    public static func statusProbe(accessHeaders: [String: String], session: URLSession) -> Probe {
        return { address in
            var request = URLRequest(url: address.api("/api/status"), timeoutInterval: timeout)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if address.base.scheme == "https", !address.isPrivateHost {
                for (k, v) in accessHeaders { request.setValue(v, forHTTPHeaderField: k) }
            }
            guard let (data, response) = try? await session.data(for: request, delegate: NoRedirects()),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let status = try? JSONDecoder().decode(Status.self, from: data), status.isHermes
            else { return nil }
            return status.identity
        }
    }

    public static func probeConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.waitsForConnectivity = false
        return c
    }

    /// A redirect is not an answer: a captive portal or a login page, never followed.
    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// The words for an address where the gateway is named (#283): a home
    /// network address, a Tailscale one, or else its host.
    public static func label(for address: GatewayURL) -> String {
        if address.isTailscaleHost { return "Tailscale" }
        if address.isPrivateHost { return "Home network" }
        return address.host
    }
}

/// What this device remembers about a gateway with two addresses: which answered last and what
/// the gateway said about itself. Per device, not synced: which address works depends on the
/// network this device is on.
public struct AddressMemory {
    public let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func lastGood(for id: UUID) -> Int? { defaults.object(forKey: "gateway.lastAddress.\(id.uuidString)") as? Int }
    public func setLastGood(_ index: Int, for id: UUID) { defaults.set(index, forKey: "gateway.lastAddress.\(id.uuidString)") }

    public func identity(for id: UUID) -> GatewayIdentity? {
        defaults.data(forKey: "gateway.identity.\(id.uuidString)").flatMap { try? JSONDecoder().decode(GatewayIdentity.self, from: $0) }
    }
    public func setIdentity(_ identity: GatewayIdentity, for id: UUID) {
        if let d = try? JSONEncoder().encode(identity) { defaults.set(d, forKey: "gateway.identity.\(id.uuidString)") }
    }
}
