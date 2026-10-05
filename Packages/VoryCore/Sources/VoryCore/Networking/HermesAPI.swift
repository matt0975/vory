import Foundation

public enum HermesAPIError: LocalizedError, Sendable {
    case transport(String)
    case htmlResponse(status: Int)
    case http(status: Int, detail: String)
    case unauthorized(String)
    case decoding(String)
    case sessionExpired

    public var errorDescription: String? {
        switch self {
        case .transport(let m): return m
        case .htmlResponse:
            return "This URL is not the Hermes dashboard API (got an HTML login/page). Use the `hermes serve` / dashboard URL, add Access service-token headers if Cloudflare Access is on, and confirm the tunnel upgrades WebSockets."
        case .http(let status, let detail): return detail.isEmpty ? "HTTP \(status)" : "\(detail) (HTTP \(status))"
        case .unauthorized(let d): return d.isEmpty ? "The gateway rejected the credentials (401)." : d
        case .decoding(let m): return "Unexpected response from the gateway: \(m)"
        case .sessionExpired: return "Your session has expired. Sign in again."
        }
    }

    public var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        if case .sessionExpired = self { return true }
        return false
    }
}

public struct EmptyBody: Encodable, Sendable { public init() {} }

/// REST client for one gateway. Applies auth + Access headers, `?profile=`, 401→refresh→retry, and HTML detection.
public actor HermesAPI {
    public let gateway: GatewayURL
    public private(set) var signer: RequestSigner
    private let urlSession: URLSession
    /// Called on 401 for bearer modes; returns a refreshed signer or throws.
    public var refresher: (@Sendable () async throws -> RequestSigner)?
    private var refreshInFlight: Task<RequestSigner, Error>?

    public typealias Relay = @Sendable (RelayedRequest) async throws -> RelayedResponse
    /// A second way to the gateway (the watch's iPhone) and when to take it.
    private var relay: Relay?
    /// Whether the relay can take a call right now (the phone within reach); nil = assume so.
    private var relayReachable: (@Sendable () -> Bool)?
    public private(set) var route: GatewayRoute = .direct
    /// Automatic: calls go to the relay first until then, after the direct route failed.
    private var relayFirstUntil: Date?
    /// How long a direct route that failed is passed over before it is tried again.
    public static let directRetryAfter: TimeInterval = 180
    /// How long a direct read waits for a byte when the relay could carry it instead.
    public static let directTimeoutWithRelay: TimeInterval = 10
    /// Whether the last call that got an answer went through the relay; `onRouteUsed` hears
    /// each change.
    public private(set) var lastRelayed = false
    private var onRouteUsed: (@Sendable (Bool) -> Void)?

    public init(gateway: GatewayURL, signer: RequestSigner, urlSession: URLSession = HermesAPI.makeSession()) {
        self.gateway = gateway
        self.signer = signer
        self.urlSession = urlSession
    }

    public static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }

    public func updateSigner(_ s: RequestSigner) { signer = s }
    public func setRefresher(_ r: (@Sendable () async throws -> RequestSigner)?) { refresher = r }

    /// The watch: its iPhone as a second route, taken by `route`. `reachable` says cheaply
    /// whether the relay could take a call now, so a direct read is cut short only then.
    public func setRelay(_ r: Relay?, route: GatewayRoute, reachable: (@Sendable () -> Bool)? = nil, onRouteUsed: (@Sendable (Bool) -> Void)? = nil) {
        relay = r
        relayReachable = reachable
        self.route = r == nil ? .direct : route
        relayFirstUntil = nil
        lastRelayed = false
        self.onRouteUsed = onRouteUsed
    }

    // MARK: Typed helpers

    public func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], profile: String? = nil, authenticated: Bool = true) async throws -> T {
        let (data, _) = try await raw("GET", path, query: query, profile: profile, body: nil, authenticated: authenticated)
        return try decode(data)
    }

    /// `directOnly`: never through a relay (the socket's ticket: one minted by the phone is no
    /// use to a watch whose own route to the gateway is down).
    public func send<T: Decodable, B: Encodable & Sendable>(_ method: String, _ path: String, query: [URLQueryItem] = [], profile: String? = nil, body: B, directOnly: Bool = false) async throws -> T {
        let encoded = try JSONEncoder().encode(body)
        let (data, _) = try await raw(method, path, query: query, profile: profile, body: (encoded, "application/json"), authenticated: true, directOnly: directOnly)
        return try decode(data)
    }

    public func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], profile: String? = nil, json: JSONValue) async throws -> T {
        let encoded = try JSONEncoder().encode(json)
        let (data, _) = try await raw(method, path, query: query, profile: profile, body: (encoded, "application/json"), authenticated: true)
        return try decode(data)
    }

    public func sendMultipart<T: Decodable>(_ path: String, query: [URLQueryItem] = [], profile: String? = nil, fields: [String: String], fileField: String, filename: String, fileData: Data, mimeType: String) async throws -> T {
        let boundary = "Vory-\(UUID().uuidString)"
        var body = Data()
        for (k, v) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let (data, _) = try await raw("POST", path, query: query, profile: profile, body: (body, "multipart/form-data; boundary=\(boundary)"), authenticated: true)
        return try decode(data)
    }

    /// Downloads a file to a temporary location (caller moves/deletes it).
    public func download(_ path: String, query: [URLQueryItem] = []) async throws -> URL {
        var request = URLRequest(url: gateway.api(path, query: query))
        signer.apply(to: &request)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (tmp, response) = try await urlSession.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw HermesAPIError.transport("No HTTP response") }
        if http.statusCode >= 400 {
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            throw Self.error(for: http, data: data)
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value.map { ($0 as NSString).lastPathComponent } ?? "download"
        let final = dest.appendingPathComponent(name.isEmpty ? "download" : name)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: tmp, to: final)
        return final
    }

    // MARK: Core

    public func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], profile: String? = nil, body: (Data, String)?, authenticated: Bool, directOnly: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var items = query
        if let profile, !profile.isEmpty, !items.contains(where: { $0.name == "profile" }) {
            items.append(URLQueryItem(name: "profile", value: profile))
        }
        let (data, http, refreshed) = try await answered(method, path, items: items, body: body, authenticated: authenticated, directOnly: directOnly)
        if http.statusCode >= 400 { throw Self.error(for: http, data: data) }
        // The retry after a renewal is judged by its status alone, as before.
        if !refreshed, Self.looksLikeHTML(http: http, data: data) { throw HermesAPIError.htmlResponse(status: http.statusCode) }
        return (data, http)
    }

    /// A call made for another device (the watch, through its iPhone): the gateway's answer as
    /// it came, errors in the status, after this client's own sign-in renewal on a 401.
    public func forward(_ r: RelayedRequest) async throws -> RelayedResponse {
        let body = r.body.map { ($0, r.contentType ?? "application/json") }
        let (data, http, _) = try await answered(r.method, r.path, items: r.query, body: body, authenticated: r.authenticated)
        return RelayedResponse(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data)
    }

    /// One call and, on a 401 for a bearer sign-in, one renewal and a retry. Not after a
    /// relayed 401: the relay renewed its own sign-in already, and the watch has nothing to
    /// renew with. `refreshed`: the answer is the retry's.
    private func answered(_ method: String, _ path: String, items: [URLQueryItem], body: (Data, String)?, authenticated: Bool, directOnly: Bool = false) async throws -> (Data, HTTPURLResponse, refreshed: Bool) {
        let (data, http, relayed) = try await perform(method, path, items: items, body: body, authenticated: authenticated, directOnly: directOnly)
        if http.statusCode == 401, !relayed, authenticated, signer.authMode.usesBearer, let refresher {
            let refreshed = try await coalescedRefresh(refresher)
            signer = refreshed
            let (data2, http2, _) = try await perform(method, path, items: items, body: body, authenticated: authenticated, directOnly: directOnly)
            return (data2, http2, true)
        }
        return (data, http, false)
    }

    private func coalescedRefresh(_ refresher: @Sendable @escaping () async throws -> RequestSigner) async throws -> RequestSigner {
        if let t = refreshInFlight { return try await t.value }
        let t = Task { try await refresher() }
        refreshInFlight = t
        defer { refreshInFlight = nil }
        return try await t.value
    }

    /// One exchange by the route in force. `relayed`: the relay carried it.
    private func perform(_ method: String, _ path: String, items: [URLQueryItem], body: (Data, String)?, authenticated: Bool, directOnly: Bool = false) async throws -> (Data, HTTPURLResponse, relayed: Bool) {
        guard let relay, route != .direct, !directOnly else {
            let (d, h) = try await direct(method, path, items: items, body: body, authenticated: authenticated, timeout: nil, soft: false)
            return (d, h, false)
        }
        if route == .relayOnly {
            do { return try await relayed(relay, method, path, items: items, body: body, authenticated: authenticated) }
            catch let u as RelayUnavailable { throw HermesAPIError.transport(u.message) }
        }
        // Automatic. A read can be asked twice; a write that may have reached the gateway is
        // never sent a second time.
        let repeatable = method == "GET" || method == "HEAD"
        var away: String?
        // The direct route failed a moment ago, so the relay goes first. With the relay away,
        // or a read it could not carry, the direct route is tried after all.
        if let until = relayFirstUntil, until > Date() {
            do { return try await relayed(relay, method, path, items: items, body: body, authenticated: authenticated) }
            catch let u as RelayUnavailable { away = u.message }
            catch let e as HermesAPIError {
                guard case .transport = e else { throw e }
                relayFirstUntil = nil
                if !repeatable { throw e }
            }
        }
        // A direct answer kept while the relay is asked, for when the relay cannot help.
        var answer: (Data, HTTPURLResponse)?
        var failure = ""
        do {
            // Cut short only when the relay could take over.
            let short = repeatable && away == nil && (relayReachable?() ?? true) ? Self.directTimeoutWithRelay : nil
            let (d, h) = try await direct(method, path, items: items, body: body, authenticated: authenticated, timeout: short, soft: true)
            if !Self.shouldTryRelay(http: h, data: d) {
                relayFirstUntil = nil
                noteRoute(relayed: false)
                return (d, h, false)
            }
            if away != nil { noteRoute(relayed: false); return (d, h, false) }
            answer = (d, h)
        } catch let e as DirectFailure {
            if e.cancelled { throw CancellationError() }
            if !repeatable, !e.beforeSend { throw HermesAPIError.transport(e.message) }
            if let away { throw HermesAPIError.transport([e.message, away].joined(separator: " ")) }
            failure = e.message
        }
        relayFirstUntil = Date().addingTimeInterval(Self.directRetryAfter)
        do { return try await relayed(relay, method, path, items: items, body: body, authenticated: authenticated) }
        catch is CancellationError { throw CancellationError() }
        catch {
            // The relay could not carry it either: the direct route stays first, and its answer
            // stands (a 401 still gets its renewal); no answer at all says both.
            relayFirstUntil = nil
            if let (d, h) = answer { noteRoute(relayed: false); return (d, h, false) }
            if let u = error as? RelayUnavailable { throw HermesAPIError.transport([failure, u.message].filter { !$0.isEmpty }.joined(separator: " ")) }
            throw error
        }
    }

    /// An answer that says the direct route did not reach the gateway (an Access sign-in page,
    /// a captive portal, credentials only the relay has fresh), not that the gateway refused.
    public nonisolated static func shouldTryRelay(http: HTTPURLResponse, data: Data) -> Bool {
        http.statusCode == 401 || looksLikeHTML(http: http, data: data)
    }

    /// A direct call that got no answer; `cancelled` is the caller giving up, not the network;
    /// `beforeSend`: it failed before anything reached the gateway.
    private struct DirectFailure: Error { var message: String; var cancelled: Bool; var beforeSend: Bool }

    private static let failsBeforeSending: Set<URLError.Code> = [
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
        .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
        .clientCertificateRejected, .clientCertificateRequired, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
        .appTransportSecurityRequiresSecureConnection, .cannotLoadFromNetwork,
    ]

    /// `soft`: a failure comes back as `DirectFailure`, for the relay to be tried.
    private func direct(_ method: String, _ path: String, items: [URLQueryItem], body: (Data, String)?, authenticated: Bool, timeout: TimeInterval?, soft: Bool) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: gateway.api(path, query: items))
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        signer.apply(to: &request, includeCredential: authenticated)
        if let (data, type) = body {
            request.httpBody = data
            request.setValue(type, forHTTPHeaderField: "Content-Type")
        }
        let result: (Data, URLResponse)
        do { result = try await urlSession.data(for: request) }
        catch {
            let code = (error as? URLError)?.code
            let cancelled = error is CancellationError || code == .cancelled
            if soft { throw DirectFailure(message: error.localizedDescription, cancelled: cancelled, beforeSend: code.map(Self.failsBeforeSending.contains) ?? false) }
            if let e = error as? HermesAPIError { throw e }
            throw HermesAPIError.transport(error.localizedDescription)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw HermesAPIError.transport("No HTTP response") }
        return (result.0, http)
    }

    private func relayed(_ relay: Relay, _ method: String, _ path: String, items: [URLQueryItem], body: (Data, String)?, authenticated: Bool) async throws -> (Data, HTTPURLResponse, relayed: Bool) {
        let r: RelayedResponse
        do { r = try await relay(RelayedRequest(method: method, path: path, query: items, body: body?.0, contentType: body?.1, authenticated: authenticated)) }
        catch let e as RelayUnavailable { throw e }
        catch let e as HermesAPIError { throw e }
        catch is CancellationError { throw CancellationError() }
        catch { throw HermesAPIError.transport(error.localizedDescription) }
        var headers: [String: String] = [:]
        if let t = r.contentType { headers["Content-Type"] = t }
        guard let http = HTTPURLResponse(url: gateway.api(path, query: items), statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw HermesAPIError.transport("No HTTP response")
        }
        noteRoute(relayed: true)
        return (r.body, http, true)
    }

    private func noteRoute(relayed: Bool) {
        guard relayed != lastRelayed else { return }
        lastRelayed = relayed
        onRouteUsed?(relayed)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONCoding.decoder.decode(T.self, from: data) }
        catch { throw HermesAPIError.decoding(String(describing: error).prefix(200).description) }
    }

    public nonisolated static func looksLikeHTML(http: HTTPURLResponse, data: Data) -> Bool {
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.contains("text/html") { return true }
        if type.contains("application/json") { return false }
        let prefix = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return prefix.hasPrefix("<!doctype") || prefix.hasPrefix("<html")
    }

    public nonisolated static func error(for http: HTTPURLResponse, data: Data) -> HermesAPIError {
        if looksLikeHTML(http: http, data: data) { return .htmlResponse(status: http.statusCode) }
        var detail = ""
        if let obj = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if let d = obj["detail"]?.stringValue { detail = d }
            else if let d = obj["detail"] { detail = d.displayText }
            else if let e = obj["error"]?.stringValue { detail = e }
            if obj["error"]?.stringValue == "session_expired" { return .sessionExpired }
        } else if let s = String(data: data, encoding: .utf8), s.count < 300 { detail = s }
        if http.statusCode == 401 { return .unauthorized(detail) }
        return .http(status: http.statusCode, detail: detail)
    }
}
