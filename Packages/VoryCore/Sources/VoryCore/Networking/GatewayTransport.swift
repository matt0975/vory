import Foundation

/// What a gateway socket reads and writes its text frames on. Over the network it is a
/// `URLSessionWebSocketTask` (`WebSocketPipe`); the demo (#392) gives the socket a pipe of its
/// own that never leaves the process. Everything above it, the socket's JSON-RPC, its ready
/// wait, timeouts, heartbeat, event batches and reconnects, is the same for both.
public protocol GatewayFramePipe: AnyObject, Sendable {
    /// Starts the connection (the handshake, for a web socket).
    func resume()
    /// One text frame out.
    func send(_ text: String) async throws
    /// The next frame in, as text. Throws once the pipe has closed or failed.
    func receive() async throws -> String
    /// Closes the pipe as the client going away.
    func close()
    /// Why the pipe closed, once `receive` has thrown: the close code (0 when there was none)
    /// and the reason the other end gave.
    var closeInfo: (code: Int, reason: String) { get }
    /// What answered the handshake when it was not a socket (a Cloudflare page, a redirect to a sign-in), for the
    /// socket to say why it can't connect (#423); nil when there was no HTTP answer, or no handshake at all.
    var upgradeResponse: HTTPURLResponse? { get }
}

extension GatewayFramePipe {
    /// A pipe with no HTTP handshake (the demo's) has no answer to give.
    public var upgradeResponse: HTTPURLResponse? { nil }
}

/// A gateway on the network: a URLSession web socket.
final class WebSocketPipe: GatewayFramePipe, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    /// The session made for this pipe alone, invalidated with it; nil for a shared one.
    private let ownSession: URLSession?

    /// `shared`: a session the caller keeps for its sockets (the board's events); nil makes one
    /// for this pipe, as the gateway socket always has.
    init(request: URLRequest, session shared: URLSession? = nil) {
        let session: URLSession
        if let shared {
            session = shared
            ownSession = nil
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpShouldSetCookies = false
            cfg.waitsForConnectivity = false
            cfg.timeoutIntervalForRequest = 20
            session = URLSession(configuration: cfg)
            ownSession = session
        }
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024
    }

    func resume() { task.resume() }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let s): return s
        case .data(let d): return String(decoding: d, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        ownSession?.invalidateAndCancel()
    }

    var closeInfo: (code: Int, reason: String) {
        (task.closeCode.rawValue, task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    var upgradeResponse: HTTPURLResponse? { task.response as? HTTPURLResponse }
}

/// How a runtime reaches its gateway: over the network, for every gateway a person adds, or in
/// process, for the demo (`GatewayConnection.demo`). Chosen once, when the runtime is made; the
/// API, the socket and the board's events take what they need from it, and nothing above them
/// knows which it is.
public struct GatewayTransport: Sendable {
    /// The session `HermesAPI` makes every request through.
    public var makeHTTPSession: @Sendable () -> URLSession
    /// The pipe a socket reads and writes frames on, for a request to open it. The session is
    /// one the caller keeps for its sockets (the board's), or nil.
    public var makeFramePipe: @Sendable (URLRequest, URLSession?) -> any GatewayFramePipe
    /// The runtime has stopped: what the transport holds for it goes (the demo's binding of its requests to its gateway).
    public var stop: @Sendable () -> Void
    /// Answered in process, with nothing on the network (the demo's): a runtime on it keeps nothing, whatever its
    /// connection (`GatewayRuntime.isEphemeral`), so a runtime made for a moment on the demo (onboarding's tour, #388)
    /// is covered as the demo connection is.
    public var isInProcess: Bool

    public init(makeHTTPSession: @escaping @Sendable () -> URLSession,
                makeFramePipe: @escaping @Sendable (URLRequest, URLSession?) -> any GatewayFramePipe,
                stop: @escaping @Sendable () -> Void = {}, isInProcess: Bool = false) {
        self.makeHTTPSession = makeHTTPSession
        self.makeFramePipe = makeFramePipe
        self.stop = stop
        self.isInProcess = isInProcess
    }

    /// A gateway on the network, as every connection has always been reached.
    public static let network = GatewayTransport(makeHTTPSession: { HermesAPI.makeSession() },
                                                 makeFramePipe: { WebSocketPipe(request: $0, session: $1) })
}
