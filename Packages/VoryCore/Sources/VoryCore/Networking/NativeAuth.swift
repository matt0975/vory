import AuthenticationServices
import CryptoKit
import Foundation
import Network
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum NativeAuthError: LocalizedError {
    case cancelled
    case noCallback
    case stateMismatch
    case invalidResponse(String)
    case providerRequired([AuthProvider])

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .noCallback: return "The sign-in finished in the browser, but the gateway never sent the app its code. Usual causes: Hermes on the gateway is older than native sign-in (update it), or a reverse proxy rule blocked the sign-in request. A session token from the dashboard always works as a fallback."
        case .stateMismatch: return "Sign-in state mismatch; try again."
        case .invalidResponse(let s): return s
        case .providerRequired(let p): return "Choose a sign-in provider: \(p.map(\.name).joined(separator: ", "))."
        }
    }
}

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Data(bytes).base64URLEncodedString()
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

public extension Data {
    public func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// RFC 8252 native sign-in against the gateway's `/auth/native/*` endpoints, plus the password twin and refresh.
@MainActor
public final class NativeAuthClient: NSObject {
    #if !os(watchOS)
    private var webSession: ASWebAuthenticationSession?
    #endif

    // MARK: Providers

    public static func providers(gateway: GatewayURL, access: CloudflareAccess) async throws -> [AuthProvider] {
        let api = HermesAPI(gateway: gateway, signer: RequestSigner(authMode: .oauth, access: access))
        let r: AuthProvidersResponse = try await api.get("/api/auth/providers", authenticated: false)
        return r.providers
    }

    // MARK: Browser (OAuth / OIDC / Nous Portal)

    #if !os(watchOS)
    public func signInWithBrowser(gateway: GatewayURL, provider: String?, access: CloudflareAccess) async throws -> GatewaySecrets {
        try await Self.checkNativeSignIn(gateway: gateway, access: access)
        let pkce = PKCE()
        let state = UUID().uuidString
        let listener = try LoopbackCallbackServer()
        let port = try await listener.start()
        let redirect = "http://127.0.0.1:\(port)/callback"
        var items = [URLQueryItem(name: "code_challenge", value: pkce.challenge),
                     URLQueryItem(name: "code_challenge_method", value: "S256"),
                     URLQueryItem(name: "redirect_uri", value: redirect),
                     URLQueryItem(name: "state", value: state)]
        if let provider, !provider.isEmpty { items.insert(URLQueryItem(name: "provider", value: provider), at: 0) }
        let url = gateway.api("/auth/native/authorize", query: items)

        let callback: (code: String, state: String) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(code: String, state: String), Error>) in
                let finished = LockedFlag()
                let finish: @Sendable (Result<(code: String, state: String), Error>) -> Void = { result in
                    guard finished.claim() else { return }
                    Task { @MainActor in
                        self.webSession?.cancel()
                        self.webSession = nil
                        listener.stop()
                        cont.resume(with: result)
                    }
                }
                listener.onCallback = { code, st in finish(.success((code, st))) }
                // Not the main actor's: on the Mac the system calls this back on its own queue.
                // Written in a main-actor method the closure was taken for a main-actor one,
                // and the runtime's check stopped the app the moment the browser sheet closed.
                let session = ASWebAuthenticationSession(url: url, callback: .customScheme("hermesremote")) { @Sendable _, error in
                    if let error {
                        if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { finish(.failure(NativeAuthError.cancelled)) }
                        else { finish(.failure(error)) }
                    } else {
                        finish(.failure(NativeAuthError.noCallback))
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.webSession = session
                if !session.start() { finish(.failure(NativeAuthError.invalidResponse("Could not open the sign-in browser."))) }
            }
        } onCancel: {
            Task { @MainActor in listener.stop(); self.webSession?.cancel() }
        }
        guard callback.state == state else { throw NativeAuthError.stateMismatch }
        return try await Self.exchange(gateway: gateway, code: callback.code, verifier: pkce.verifier, access: access)
    }
    #endif

    /// Whether the gateway knows the native sign-in route at all. A Hermes from before it answers
    /// 404 (or its dashboard page), and the browser would then "sign in" straight into the
    /// dashboard with nothing ever coming back to the app; better to say so first. A gateway
    /// that has the route answers 400 for the missing parameters. Anything else (a proxy's own
    /// answer, a network blip) is not held against it.
    public static func checkNativeSignIn(gateway: GatewayURL, access: CloudflareAccess) async throws {
        var req = URLRequest(url: gateway.api("/auth/native/authorize"))
        req.timeoutInterval = 15
        for (k, v) in access.headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return }
        // Only a real 404 counts: an access login page in front of the gateway (Cloudflare
        // Access without a service token) also answers 200 with HTML, and the browser flow can
        // still get through that.
        if http.statusCode == 404 {
            throw NativeAuthError.invalidResponse("This gateway's Hermes does not have native sign-in yet (the /auth/native/authorize route is missing), so the browser would sign in to the dashboard without handing anything back to the app. Update Hermes on the gateway, or use a session token from the dashboard.")
        }
        if http.statusCode == 403, String(data: data, encoding: .utf8)?.lowercased().contains("nginx") == true {
            throw NativeAuthError.invalidResponse("The reverse proxy in front of the gateway refused the sign-in request (403). If it is Nginx Proxy Manager with Block Common Exploits, this build encodes the request so that rule no longer matches; otherwise allow /auth/ through the proxy.")
        }
    }

    // MARK: Username / password (dashboard basic-auth provider) → bearer tokens, no browser

    public static func signInWithPassword(gateway: GatewayURL, provider: String, username: String, password: String, access: CloudflareAccess) async throws -> GatewaySecrets {
        let pkce = PKCE()
        let state = UUID().uuidString
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: cfg)
        let headers = access.headers

        // 1. Register a broker authorization (sets the gateway's PKCE cookie; redirects to /login for password providers).
        var authorize = URLRequest(url: gateway.api("/auth/native/authorize", query: [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:1/callback"),
            URLQueryItem(name: "state", value: state)]))
        for (k, v) in headers { authorize.setValue(v, forHTTPHeaderField: k) }
        let (aData, aResp) = try await session.data(for: authorize)
        if let http = aResp as? HTTPURLResponse, http.statusCode >= 400 { throw HermesAPI.error(for: http, data: aData) }

        // 2. Password login with the broker cookie → `{ok, next}` where next carries code+state.
        var login = URLRequest(url: gateway.api("/auth/password-login"))
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { login.setValue(v, forHTTPHeaderField: k) }
        login.httpBody = try JSONEncoder().encode(["provider": provider, "username": username, "password": password])
        let (lData, lResp) = try await session.data(for: login)
        guard let http = lResp as? HTTPURLResponse else { throw HermesAPIError.transport("No HTTP response") }
        if http.statusCode >= 400 { throw HermesAPI.error(for: http, data: lData) }
        guard let obj = try? JSONDecoder().decode(JSONValue.self, from: lData), let next = obj["next"]?.stringValue,
              let comps = URLComponents(string: next), let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw NativeAuthError.invalidResponse("The gateway did not return a native sign-in code. Enable a password provider on the dashboard (HERMES_DASHBOARD_BASIC_AUTH_*).")
        }
        guard comps.queryItems?.first(where: { $0.name == "state" })?.value == state else { throw NativeAuthError.stateMismatch }
        return try await exchange(gateway: gateway, code: code, verifier: pkce.verifier, access: access)
    }

    // MARK: Exchange / refresh

    public static func exchange(gateway: GatewayURL, code: String, verifier: String, access: CloudflareAccess) async throws -> GatewaySecrets {
        let api = HermesAPI(gateway: gateway, signer: RequestSigner(authMode: .oauth, access: access))
        let r: NativeTokenResponse = try await api.send("POST", "/auth/native/token", body: ["code": code, "code_verifier": verifier])
        return GatewaySecrets(accessToken: r.accessToken, refreshToken: r.refreshToken, expiresAt: r.expiresAt, provider: r.provider, userId: r.userId, access: access)
    }

    public static func refresh(gateway: GatewayURL, secrets: GatewaySecrets) async throws -> GatewaySecrets {
        guard let rt = secrets.refreshToken, !rt.isEmpty else { throw HermesAPIError.sessionExpired }
        let api = HermesAPI(gateway: gateway, signer: RequestSigner(authMode: .oauth, access: secrets.access))
        do {
            let r: NativeTokenResponse = try await api.send("POST", "/auth/native/refresh", body: ["refresh_token": rt, "provider": secrets.provider ?? ""])
            var s = secrets
            s.accessToken = r.accessToken
            s.refreshToken = r.refreshToken ?? rt
            s.expiresAt = r.expiresAt
            s.provider = r.provider ?? secrets.provider
            s.userId = r.userId ?? secrets.userId
            return s
        } catch let e as HermesAPIError where e.isUnauthorized {
            throw HermesAPIError.sessionExpired
        }
    }
}

/// Minimal loopback HTTP listener that receives the `?code=&state=` redirect from the system browser.
public final class LoopbackCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Vory.loopback")
    private let lock = NSLock()
    private var delivered = false
    public var onCallback: (@Sendable (String, String) -> Void)?

    public init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener.port?.rawValue, resumed.claim() { cont.resume(returning: port) }
                case .failed(let e):
                    if resumed.claim() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let firstLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            var body = "<html><body style=\"font-family:-apple-system;text-align:center;padding-top:4em\"><h2>Signed in</h2><p>You can return to Vory.</p></body></html>"
            if parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]),
               let code = comps.queryItems?.first(where: { $0.name == "code" })?.value {
                let state = comps.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
                self.lock.lock(); let first = !self.delivered; self.delivered = true; self.lock.unlock()
                if first { self.onCallback?(code, state) }
            } else {
                body = "<html><body><p>Waiting for the gateway…</p></body></html>"
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

public final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if value { return false }; value = true; return true }
}

// The browser sign-in needs ASWebAuthenticationSession, which watchOS does not have; the watch
// signs in with a session token or password, or receives credentials from the phone.
#if !os(watchOS)
extension NativeAuthClient: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        #else
        NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #endif
    }
}
#endif
