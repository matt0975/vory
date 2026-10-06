import Foundation
import OSLog

public enum SocketState: Sendable, Equatable {
    case idle
    case connecting
    case open
    case reconnecting(attempt: Int, delay: Double)
    case authRejected(String)
    case failed(String)

    public var isOpen: Bool { self == .open }
    public var label: String {
        switch self {
        case .idle: return "Offline"
        case .connecting: return "Connecting…"
        case .open: return "Connected"
        case .reconnecting(let n, _): return "Reconnecting (\(n))…"
        case .authRejected: return "Sign in required"
        case .failed: return "Connection failed"
        }
    }
}

public enum SocketError: LocalizedError, Sendable {
    case notConnected
    case timeout(String)
    case closed(code: Int, reason: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the gateway."
        case .timeout(let m): return "Timed out waiting for \(m)."
        case .closed(let code, let reason): return "WebSocket closed (\(code))\(reason.isEmpty ? "" : ": \(reason)")"
        case .cancelled: return "Cancelled."
        }
    }
}

/// JSON-RPC 2.0 over `/api/ws`. Reconnects with backoff; re-mints tickets via `urlProvider` on every attempt.
public actor GatewaySocket {
    public typealias URLProvider = @Sendable () async throws -> (URL, [String: String])
    public typealias EventSink = @Sendable (GatewayEvent) -> Void
    /// Handed each new batch once, when its first event arrives (see `GatewayEventBatch`).
    public typealias EventBatchSink = @Sendable (GatewayEventBatch) -> Void
    public typealias StateSink = @Sendable (SocketState) -> Void
    public typealias RequestHandler = @Sendable (ServerRequest) async -> JSONValue?
    public typealias ReconnectHook = @Sendable () async -> Void

    private let log = Logger(subsystem: "Vory", category: "ws")
    private let urlProvider: URLProvider
    private let onEvents: EventBatchSink
    /// The batch being filled, until the app takes it or a reply closes it.
    private var openBatch: GatewayEventBatch?
    private let onState: StateSink
    private let onServerRequest: RequestHandler
    private let onReconnected: ReconnectHook

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveLoop: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    public private(set) var state: SocketState = .idle
    private var wantConnected = false
    private var everConnected = false
    private var attempt = 0

    /// Events in batches: the sink is called once per batch, as it opens, and whoever takes
    /// the batch later gets everything that arrived in the meantime.
    public init(urlProvider: @escaping URLProvider, onEvents: @escaping EventBatchSink, onState: @escaping StateSink,
         onServerRequest: @escaping RequestHandler, onReconnected: @escaping ReconnectHook) {
        self.urlProvider = urlProvider
        self.onEvents = onEvents
        self.onState = onState
        self.onServerRequest = onServerRequest
        self.onReconnected = onReconnected
    }

    /// Events one at a time, each as it arrives.
    public init(urlProvider: @escaping URLProvider, onEvent: @escaping EventSink, onState: @escaping StateSink,
         onServerRequest: @escaping RequestHandler, onReconnected: @escaping ReconnectHook) {
        self.init(urlProvider: urlProvider, onEvents: { batch in for e in batch.take() { onEvent(e) } },
                  onState: onState, onServerRequest: onServerRequest, onReconnected: onReconnected)
    }

    // MARK: Lifecycle

    public func connect() {
        wantConnected = true
        guard reconnectTask == nil, task == nil else { return }
        attempt = 0
        reconnectTask = Task { await self.runConnectLoop() }
    }

    public func disconnect() {
        wantConnected = false
        reconnectTask?.cancel(); reconnectTask = nil
        teardown(reason: "disconnect")
        setState(.idle)
    }

    /// Resolves once `gateway.ready` has been observed (or throws after `timeout`).
    public func waitUntilReady(timeout: Double = 20) async throws {
        if state == .open { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    Task { await self.addReadyWaiter(c) }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw SocketError.timeout("gateway.ready")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func addReadyWaiter(_ c: CheckedContinuation<Void, Error>) {
        if state == .open { c.resume(); return }
        readyWaiters.append(c)
    }

    private func runConnectLoop() async {
        defer { reconnectTask = nil }
        while wantConnected, !Task.isCancelled {
            attempt += 1
            setState(attempt == 1 && !everConnected ? .connecting : .reconnecting(attempt: attempt, delay: 0))
            do {
                let (url, headers) = try await urlProvider()
                try await open(url: url, headers: headers)
                try await waitUntilReady(timeout: 20)
                let wasReconnect = everConnected
                everConnected = true
                attempt = 0
                if wasReconnect { await onReconnected() }
                return
            } catch let e as HermesAPIError where e.isUnauthorized {
                teardown(reason: "auth")
                setState(.authRejected(e.localizedDescription))
                return
            } catch let e as SocketError {
                if case .closed(let code, let reason) = e, code == 4401 {
                    teardown(reason: "auth")
                    setState(.authRejected(reason.isEmpty ? "The gateway rejected the WebSocket credential (4401)." : reason))
                    return
                }
                teardown(reason: "error")
                log.warning("connect failed: \(e.localizedDescription, privacy: .public)")
            } catch {
                teardown(reason: "error")
                log.warning("connect failed: \(error.localizedDescription, privacy: .public)")
            }
            guard wantConnected else { return }
            let delay = min(30.0, pow(2.0, Double(min(attempt, 5)))) * Double.random(in: 0.8...1.2)
            setState(.reconnecting(attempt: attempt, delay: delay))
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
    }

    private func open(url: URL, headers: [String: String]) async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 20
        let s = URLSession(configuration: cfg)
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let t = s.webSocketTask(with: req)
        t.maximumMessageSize = 64 * 1024 * 1024
        session = s
        task = t
        t.resume()
        receiveLoop = Task { await self.receive(on: t) }
    }

    private func teardown(reason: String) {
        heartbeat?.cancel(); heartbeat = nil
        receiveLoop?.cancel(); receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        let waiters = readyWaiters; readyWaiters = []
        for w in waiters { w.resume(throwing: SocketError.notConnected) }
        let calls = pending; pending = [:]
        for (_, c) in calls { c.resume(throwing: SocketError.notConnected) }
        openBatch = nil
    }

    private func setState(_ s: SocketState) {
        state = s
        onState(s)
    }

    private func markOpen() {
        guard state != .open else { return }
        setState(.open)
        let waiters = readyWaiters; readyWaiters = []
        for w in waiters { w.resume() }
        startHeartbeat()
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                do { _ = try await self.call("ping", params: [:], timeout: 20) }
                catch { await self.connectionLost(reason: "heartbeat timeout") }
            }
        }
    }

    private func connectionLost(reason: String) {
        guard task != nil else { return }
        log.warning("connection lost: \(reason, privacy: .public)")
        teardown(reason: reason)
        if wantConnected, reconnectTask == nil {
            reconnectTask = Task { await self.runConnectLoop() }
        }
    }

    // MARK: Receive

    private func receive(on t: URLSessionWebSocketTask) async {
        while !Task.isCancelled, task === t {
            do {
                let message = try await t.receive()
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    handle(InboundFrame.parse(String(line)))
                }
            } catch {
                guard task === t else { return }
                let code = t.closeCode.rawValue
                let reason = t.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                if state != .open, code == 4401 || code == 4403 {
                    // Pre-ready rejection: surface to the connect loop via waiters.
                    let waiters = readyWaiters; readyWaiters = []
                    for w in waiters { w.resume(throwing: SocketError.closed(code: code, reason: reason)) }
                    teardown(reason: "closed \(code)")
                    return
                }
                if state != .open {
                    let waiters = readyWaiters; readyWaiters = []
                    for w in waiters { w.resume(throwing: SocketError.closed(code: code, reason: reason.isEmpty ? error.localizedDescription : reason)) }
                    teardown(reason: "closed")
                    return
                }
                connectionLost(reason: "receive error: \(error.localizedDescription)")
                return
            }
        }
    }

    private func handle(_ frame: InboundFrame) {
        switch frame {
        case .event(let ev):
            if ev.type == "gateway.ready" { markOpen() }
            deliver(ev)
        case .response(let id, let result, let error):
            // Events after this reply reach the app after it (see `GatewayEventBatch`).
            openBatch = nil
            guard let n = id.intValue, let c = pending.removeValue(forKey: n) else { return }
            if let error { c.resume(throwing: error) } else { c.resume(returning: result ?? .null) }
        case .serverRequest(let req):
            openBatch = nil
            Task { await self.answer(req) }
        case .unknown:
            break
        }
    }

    /// Into the open batch while the app has not taken it; else into a new one, handed over.
    private func deliver(_ ev: GatewayEvent) {
        if let b = openBatch, b.add(ev) { return }
        let b = GatewayEventBatch()
        _ = b.add(ev)
        openBatch = b
        onEvents(b)
    }

    private func answer(_ req: ServerRequest) async {
        if let result = await onServerRequest(req) {
            await sendText(RPCFrames.response(id: req.id, result: result))
        } else {
            // The gateway settles a request on the FIRST reply from any client, so an error here
            // would withdraw the approval for every client and time the turn out. A request
            // this app cannot place (a session it has not opened, a method it does not draw) is
            // left open instead: it waits in the gateway's open_requests, replays on the next
            // resume, and another client can still answer it.
            log.warning("server request \(req.method, privacy: .public) for \(req.sessionID, privacy: .public) left unanswered")
        }
    }

    // MARK: Send

    public func call(_ method: String, params: JSONValue = .object([:]), timeout: Double = 120) async throws -> JSONValue {
        guard let task else { throw SocketError.notConnected }
        let id = nextID; nextID += 1
        let text = RPCFrames.request(id: id, method: method, params: params)
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSONValue, Error>) in
                    Task { await self.register(id: id, continuation: c, task: task, text: text) }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw SocketError.timeout(method)
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func register(id: Int, continuation: CheckedContinuation<JSONValue, Error>, task: URLSessionWebSocketTask, text: String) async {
        pending[id] = continuation
        do { try await task.send(.string(text)) }
        catch {
            // The socket may have closed while the send was in flight, and the close path has
            // then already failed every pending call, this one included: a second resume traps
            // (a crash report on 1.1 (9)). Only the one still registered is ours to fail.
            if pending.removeValue(forKey: id) != nil { continuation.resume(throwing: SocketError.notConnected) }
        }
    }

    /// Answers a server request that was surfaced outside the inline handler (e.g. replayed `open_requests`).
    public func respond(to id: String, result: JSONValue) async {
        await sendText(RPCFrames.response(id: id, result: result))
    }

    private func sendText(_ text: String) async {
        guard let task else { return }
        try? await task.send(.string(text))
    }
}
