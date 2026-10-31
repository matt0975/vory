import CryptoKit
import Foundation

/// The developer-run push relay (see server/push-relay). The app mints three secrets per install
/// — an install id, a relay secret and an AES-256 key — keeps them in the shared Keychain group,
/// registers the device token with the relay, and hands the id/secret/key to the user's own
/// gateway through the device file so `hermes-push` can post encrypted notifications. The relay
/// never learns the key.
public enum PushRelay {
    public struct Credentials: Codable, Sendable, Equatable {
        public var installID: String
        public var secret: String
        public var payloadKey: String   // base64, 32 bytes
    }

    public static let credentialsAccount = "push.relay.credentials"

    /// Base URL baked into the build (`VoryPushRelayURL` in Info.plist); nil means no relay.
    #if DEBUG
    /// A relay for the unit tests to point at (#501): Debug builds have none baked in, so a test that says nothing reaches
    /// the relay would otherwise pass without the relay path ever running. An `.invalid` host, caught by the test's
    /// URLProtocol before anything leaves the machine. DEBUG only, checked absent from Release at each cut.
    nonisolated(unsafe) public static var testURL: URL?
    #endif

    public static var url: URL? {
        #if DEBUG
        if let testURL { return testURL }
        #endif
        guard let s = Bundle.main.object(forInfoDictionaryKey: "VoryPushRelayURL") as? String,
              let u = URL(string: s.trimmingCharacters(in: .whitespaces)), u.scheme?.hasPrefix("http") == true else { return nil }
        return u
    }

    public static var isConfigured: Bool { url != nil }

    /// Existing credentials, or freshly minted ones written to the Keychain.
    public static func credentials() -> Credentials {
        if let c = Keychain.getCodable(Credentials.self, account: credentialsAccount) { return c }
        let c = Credentials(installID: UUID().uuidString.lowercased(),
                            secret: randomToken(48),
                            payloadKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() })
        try? Keychain.setCodable(c, account: credentialsAccount)
        return c
    }

    private static func randomToken(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Fields for the device registration file the gateway's relay reads.
    public static func deviceFileFields() -> [String: JSONValue] {
        guard let url else { return [:] }
        let c = credentials()
        return ["relay": .object(["url": .string(url.absoluteString), "install_id": .string(c.installID), "secret": .string(c.secret)]),
                "payload_key": .string(c.payloadKey)]
    }

    /// Registers (or refreshes) this device with the relay. Safe to call on every token change.
    public static func register(deviceToken: String, platform: String, bundleID: String, environment: String, liveActivityToken: String? = nil) async throws {
        guard let url else { return }
        let c = credentials()
        var body: [String: JSONValue] = ["install_id": .string(c.installID), "secret": .string(c.secret), "device_token": .string(deviceToken),
                                         "platform": .string(platform), "bundle_id": .string(bundleID), "environment": .string(environment)]
        if let t = liveActivityToken { body["live_activity_token"] = .string(t) }
        var req = URLRequest(url: url.appending(path: "v1/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RelayError.rejected(String(data: data, encoding: .utf8) ?? "")
        }
    }

    public static func unregister() async {
        guard let url else { return }
        let c = credentials()
        var req = URLRequest(url: url.appending(path: "v1/register"))
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(JSONValue.object(["install_id": .string(c.installID), "secret": .string(c.secret)]))
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Opens a payload the gateway encrypted with this install's key: base64(nonce ‖ ciphertext ‖ tag).
    public static func decrypt(_ encBase64: String, keyBase64: String) throws -> [String: JSONValue] {
        guard let key = Data(base64Encoded: keyBase64), let combined = Data(base64Encoded: encBase64) else { throw RelayError.badPayload }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: key))
        let value = try JSONDecoder().decode(JSONValue.self, from: plain)
        return value.objectValue ?? [:]
    }

    public enum RelayError: LocalizedError {
        case rejected(String), badPayload
        public var errorDescription: String? {
            switch self {
            case .rejected(let s): return "The push relay refused the registration: \(s)"
            case .badPayload: return "Notification payload could not be decrypted."
            }
        }
    }
}
