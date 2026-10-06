import Foundation

/// How a client reaches its gateway. The watch's own connection can fail where its iPhone's
/// works (a Cloudflare Access policy, a home network, a VPN only the phone runs), so the watch
/// can hand a call to the phone, which makes it with its own credentials and sends back the answer.
public enum GatewayRoute: String, Sendable, CaseIterable {
    /// Its own connection only (the phone, the Mac).
    case direct
    /// Its own connection while the gateway answers there, through the relay when it does not.
    case automatic
    /// Through the relay only.
    case relayOnly
}

/// A call handed to the relay: what `HermesAPI` would have sent, before any signing.
public struct RelayedRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    /// Every query item, the bot's included.
    public var query: [URLQueryItem]
    public var body: Data?
    public var contentType: String?
    public var authenticated: Bool

    public init(method: String, path: String, query: [URLQueryItem], body: Data?, contentType: String?, authenticated: Bool) {
        self.method = method; self.path = path; self.query = query; self.body = body; self.contentType = contentType; self.authenticated = authenticated
    }
}

/// The gateway's answer, as the relay got it: errors are in the status, not thrown.
public struct RelayedResponse: Sendable, Equatable {
    public var status: Int
    public var contentType: String?
    public var body: Data

    public init(status: Int, contentType: String?, body: Data) {
        self.status = status; self.contentType = contentType; self.body = body
    }
}

/// Thrown by a relay that cannot carry the call at all (the phone is away or asleep), as
/// opposed to carrying it and the gateway failing it.
public struct RelayUnavailable: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The watch ↔ iPhone wire format for relayed calls (WatchConnectivity messages). A message
/// holds about 64 KB, so bodies go compressed and, when still too big, in parts: the request's
/// parts ahead of it (`http.put`), the answer's after it (`http.part`).
public enum RelayWire {
    public static let op = "http"
    public static let putOp = "http.put"
    public static let partOp = "http.part"
    /// The most body bytes one message carries, well under the observed limit.
    public static let partSize = 48_000

    /// The request as a message, with its body in `body` (compressed) or sent ahead as
    /// `bodyRef`'s `parts`.
    public static func message(_ r: RelayedRequest, gateway: String, bodyRef: String? = nil, parts: Int = 0, inlineBody: Data? = nil) -> [String: Any] {
        var m: [String: Any] = ["op": op, "gateway": gateway, "method": r.method, "path": r.path,
                                "query": r.query.map { [$0.name, $0.value ?? ""] }, "auth": r.authenticated]
        if let t = r.contentType { m["type"] = t }
        if let bodyRef { m["bodyRef"] = bodyRef; m["parts"] = parts } else if let inlineBody { m["body"] = inlineBody }
        return m
    }

    /// The request back out of a message; `assembled` is a body sent ahead in parts.
    public static func request(from m: [String: Any], assembled: Data? = nil) -> RelayedRequest? {
        guard let method = m["method"] as? String, let path = m["path"] as? String, isAllowed(path: path) else { return nil }
        let query = (m["query"] as? [[String]] ?? []).compactMap { $0.count == 2 ? URLQueryItem(name: $0[0], value: $0[1]) : nil }
        let packed = assembled ?? (m["body"] as? Data)
        let body: Data?
        if let packed { guard let d = decompress(packed) else { return nil }; body = d } else { body = nil }
        return RelayedRequest(method: method, path: path, query: query, body: body, contentType: m["type"] as? String, authenticated: m["auth"] as? Bool ?? true)
    }

    /// Only the gateway's API, and nothing that climbs out of it.
    public static func isAllowed(path: String) -> Bool {
        path.hasPrefix("/api/") && !path.contains("..") && !path.contains("://")
    }

    public static func compress(_ d: Data) -> Data {
        guard !d.isEmpty, let z = try? (d as NSData).compressed(using: .lzfse) as Data else { return Data() }
        return z
    }

    public static func decompress(_ d: Data) -> Data? {
        if d.isEmpty { return Data() }
        return try? (d as NSData).decompressed(using: .lzfse) as Data
    }

    /// `d` cut into message-sized parts (one empty part for an empty body).
    public static func split(_ d: Data, size: Int = partSize) -> [Data] {
        guard d.count > size else { return [d] }
        return stride(from: 0, to: d.count, by: size).map { d.subdata(in: $0..<min($0 + size, d.count)) }
    }

    /// The answer's first message; `more` names the rest when there are `parts` > 1.
    public static func reply(_ r: RelayedResponse, firstPart: Data, more: String?, parts: Int) -> [String: Any] {
        var m: [String: Any] = ["ok": true, "status": r.status, "body": firstPart, "parts": parts]
        if let t = r.contentType { m["type"] = t }
        if let more { m["more"] = more }
        return m
    }

    /// Why the relay failed, for the side that asked: "expired" is a sign-in that has run out
    /// on the phone too, anything else a call that did not get through.
    public static func failure(_ error: Error) -> [String: Any] {
        if let e = error as? HermesAPIError, case .sessionExpired = e { return ["ok": false, "kind": "expired", "error": e.localizedDescription] }
        return ["ok": false, "kind": "transport", "error": error.localizedDescription]
    }

    /// A failure before the gateway was asked (a part lost, a gateway the phone does not have,
    /// the phone out of time): the asking side treats it as the relay being away.
    public static func unavailable(_ message: String) -> [String: Any] { ["ok": false, "kind": "unavailable", "error": message] }

    /// Whether a failed reply is `unavailable`.
    public static func isUnavailable(_ m: [String: Any]) -> Bool { m["kind"] as? String == "unavailable" }

    /// The error a failed reply stands for.
    public static func error(from m: [String: Any]) -> HermesAPIError {
        if m["kind"] as? String == "expired" { return .sessionExpired }
        return .transport(m["error"] as? String ?? "The iPhone could not reach the gateway.")
    }
}
