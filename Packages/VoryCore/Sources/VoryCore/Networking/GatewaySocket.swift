import Foundation
import OSLog

public enum SocketState: Sendable, Equatable {
    case idle
    case connecting
    case open
    case reconnecting(attempt: Int, delay: Double)
    /// Still trying, after several attempts in a row that failed the same way: what the way is (#423).
    case unreachable(ConnectProblem, attempt: Int)
    case authRejected(String)
    case failed(String)

    public var isOpen: Bool { self == .open }
    public var label: String {
        switch self {
        case .idle: return "Offline"
        case .connecting: return "Connecting…"
        case .open: return "Connected"
        case .reconnecting(let n, _): return "Reconnecting (\(n))…"
        case .unreachable(let problem, _): return problem.title
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
    /// The upgrade was answered with HTTP `status` instead of a socket (a Cloudflare error page, a redirect to a
    /// sign-in): `location`, where a redirect pointed or the address it ended at; whether Cloudflare answered; whether
    /// it was a web page.
    case refused(status: Int, location: String?, cloudflare: Bool, html: Bool)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the gateway."
        case .timeout(let m): return "Timed out waiting for \(m)."
        case .closed(let code, let reason): return "WebSocket closed (\(code))\(reason.isEmpty ? "" : ": \(reason)")"
        case .cancelled: return "Cancelled."
        case .refused(let status, _, let cloudflare, _): return "The gateway's address answered the WebSocket with HTTP \(status)\(cloudflare ? " from Cloudflare" : "")."
        }
    }
}

/// What a failed attempt says about the HTTP connection to the gateway, for the runtime to make it afresh (#423).
public enum ConnectTrouble: Sendable, Equatable {
    /// The address and ticket got no answer, twice in a row: the REST session's connection may be the one at fault.
    case addressStepNoAnswer
    /// The network path changed while the socket was waiting to try again.
    case pathChanged
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
    /// The socket's first open, which `onReconnected` is not told of: whatever gave up waiting
    /// for it (a chat opened before it, #422) can be tried again.
    private let onFirstConnected: ReconnectHook
    /// What the frames go over: a URLSession web socket, or the demo's pipe (`GatewayTransport`).
    private let makePipe: @Sendable (URLRequest) -> any GatewayFramePipe

    private var task: (any GatewayFramePipe)?
    private var receiveLoop: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    /// One per pending call: fails it with `timeout` when the reply has not come by then.
    /// A timeout used to be a sleep raced against the reply in a task group, and a task group
    /// waits for every child before it rethrows: the reply's continuation could not be
    /// cancelled, so no call ever timed out. On a socket that had died quietly under a
    /// suspended app (nothing closes it; the phone's radio just forgot it) the heartbeat's
    /// ping waited forever, the socket was never seen as lost, and every resume and send on
    /// it hung with it: testers came back to a long turn and found the app stuck (1.4 (7)
    /// and (8) crash reports with no log).
    private var callTimers: [Int: Task<Void, Never>] = [:]
    private var readyWaiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var readyTimers: [Int: Task<Void, Never>] = [:]
    private var nextWaiterID = 1
    public private(set) var state: SocketState = .idle
    private var wantConnected = false
    private var everConnected = false
    private var attempt = 0
    /// What the last failed attempts showed, and how many in a row showed it (#423).
    private var problem: ConnectProblem?
    private var problemStreak = 0
    /// A 4401 has had its one retry with a fresh ticket since the socket was last open.
    private var ticketRetried = false
    /// The address and ticket step failed without an answer on the previous attempt too.
    private var addressStepNoAnswer = false
    private var onTrouble: (@Sendable (ConnectTrouble) async -> Void)?
    /// Attempts in a row that fail the same way before the state names the problem instead of counting attempts, while
    /// the first quick retries run; past them, a problem is named at once.
    public static let problemShownAfter = 3
    /// How long an attempt waits for its address and ticket (a REST call) before giving up on it.
    public static let addressStepTimeout: Double = 25

    private var addressStepTimeoutSeconds = GatewaySocket.addressStepTimeout
    /// The tests' shorter wait for the address and ticket.
    func setAddressStepTimeout(_ seconds: Double) { addressStepTimeoutSeconds = seconds }

    /// Told when an attempt suggests the HTTP connection to the gateway should be made afresh (`ConnectTrouble`).
    public func setTroubleHandler(_ handler: (@Sendable (ConnectTrouble) async -> Void)?) { onTrouble = handler }

    /// Events in batches: the sink is called once per batch, as it opens, and whoever takes
    /// the batch later gets everything that arrived in the meantime.
    public init(urlProvider: @escaping URLProvider, onEvents: @escaping EventBatchSink, onState: @escaping StateSink,
         onServerRequest: @escaping RequestHandler, onReconnected: @escaping ReconnectHook,
         onFirstConnected: @escaping ReconnectHook = {},
         makePipe: @escaping @Sendable (URLRequest) -> any GatewayFramePipe = { GatewayTransport.network.makeFramePipe($0, nil) }) {
        self.urlProvider = urlProvider
        self.onEvents = onEvents
        self.onState = onState
        self.onServerRequest = onServerRequest
        self.onReconnected = onReconnected
        self.onFirstConnected = onFirstConnected
        self.makePipe = makePipe
    }

    /// Events one at a time, each as it arrives.
    public init(urlProvider: @escaping URLProvider, onEvent: @escaping EventSink, onState: @escaping StateSink,
         onServerRequest: @escaping RequestHandler, onReconnected: @escaping ReconnectHook,
         onFirstConnected: @escaping ReconnectHook = {},
         makePipe: @escaping @Sendable (URLRequest) -> any GatewayFramePipe = { GatewayTransport.network.makeFramePipe($0, nil) }) {
        self.init(urlProvider: urlProvider, onEvents: { batch in for e in batch.take() { onEvent(e) } },
                  onState: onState, onServerRequest: onServerRequest, onReconnected: onReconnected,
                  onFirstConnected: onFirstConnected, makePipe: makePipe)
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
        let id = nextWaiterID; nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                Task { await self.addReadyWaiter(id: id, c, timeout: timeout) }
            }
        } onCancel: {
            Task { await self.failReadyWaiter(id: id, SocketError.timeout("gateway.ready (cancelled)")) }
        }
    }

    private func addReadyWaiter(id: Int, _ c: CheckedContinuation<Void, Error>, timeout: Double) {
        if state == .open { c.resume(); return }
        readyWaiters[id] = c
        readyTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.failReadyWaiter(id: id, SocketError.timeout("gateway.ready"))
        }
    }

    /// Fails one ready waiter, if it is still waiting; the ready frame or a teardown may have
    /// resumed it first.
    private func failReadyWaiter(id: Int, _ error: Error) {
        readyTimers.removeValue(forKey: id)?.cancel()
        readyWaiters.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// Every ready waiter at once: the ready frame (`nil`), or why there will be none.
    private func settleReadyWaiters(throwing error: Error?) {
        for t in readyTimers.values { t.cancel() }
        readyTimers = [:]
        let waiters = readyWaiters; readyWaiters = [:]
        for (_, w) in waiters {
            if let error { w.resume(throwing: error) } else { w.resume() }
        }
    }

    private func runConnectLoop() async {
        defer { reconnectTask = nil }
        while wantConnected, !Task.isCancelled {
            attempt += 1
            setState(attempt == 1 && !everConnected ? .connecting : .reconnecting(attempt: attempt, delay: 0))
            var failure: Error?
            var addressStepFailed = false
            do {
                let url: URL, headers: [String: String]
                do { (url, headers) = try await addressAndTicket() }
                catch { addressStepFailed = true; throw error }
                try await open(url: url, headers: headers)
                try await waitUntilReady(timeout: 20)
                let wasReconnect = everConnected
                everConnected = true
                attempt = 0
                problem = nil; problemStreak = 0
                ticketRetried = false
                addressStepNoAnswer = false
                if wasReconnect { await onReconnected() } else { await onFirstConnected() }
                return
            } catch let e as HermesAPIError where e.isUnauthorized {
                teardown(reason: "auth")
                setState(.authRejected(e.localizedDescription))
                return
            } catch let e as SocketError {
                if case .closed(let code, let reason) = e, code == 4401 {
                    teardown(reason: "auth")
                    // A ticket can run out between its minting and its use (a slow network, an upgrade held up on
                    // the way): one more go with a fresh one before the sign-in is called refused.
                    if !ticketRetried {
                        ticketRetried = true
                        log.warning("socket refused (4401); once more with a fresh ticket")
                        continue
                    }
                    setState(.authRejected(reason.isEmpty ? "The gateway rejected the WebSocket credential (4401)." : reason))
                    return
                }
                teardown(reason: "error")
                failure = e
                log.warning("connect failed: \(e.localizedDescription, privacy: .public)")
            } catch {
                teardown(reason: "error")
                failure = error
                log.warning("connect failed: \(error.localizedDescription, privacy: .public)")
            }
            guard wantConnected else { return }
            let seen = failure.flatMap(ConnectProblem.of)
            if let seen, seen == problem { problemStreak += 1 } else { problem = seen; problemStreak = seen == nil ? 0 : 1 }
            // The ticket's REST call went unanswered twice in a row: its connection may be one a network change broke,
            // which only a new session mends (what quitting the app did, #423).
            let noAnswerNow = addressStepFailed && seen == .noAnswer
            if noAnswerNow, addressStepNoAnswer { await onTrouble?(.addressStepNoAnswer) }
            addressStepNoAnswer = noAnswerNow
            // No usable path: nothing to try against, so the next attempt waits for the path to
            // change (a route coming up on first open), not for a growing delay (#305).
            let watch = NetworkWatch.shared
            if !watch.isUsable {
                setState(.reconnecting(attempt: attempt, delay: 0))
                let mark = watch.mark
                await watch.waitForChange(since: mark, upTo: 30)
                if Task.isCancelled { return }
                if watch.mark != mark { await onTrouble?(.pathChanged) }
                continue
            }
            let delay = Self.retryDelay(attempt: attempt) * Double.random(in: 0.8...1.2)
            // Named after a few failures in a row while the first quick retries run (a blip at launch says nothing),
            // and at once after that: by then attempts are seconds apart and a new cause is news (Access after an
            // origin error waited three backed-off attempts, a minute and a half, to be named).
            if let problem, problemStreak >= Self.problemShownAfter || attempt > Self.problemShownAfter {
                setState(.unreachable(problem, attempt: attempt))
            } else {
                setState(.reconnecting(attempt: attempt, delay: delay))
            }
            // The wait is cut short by a path change: the route came up, so the attempt goes now.
            let mark = watch.mark
            let deadline = Date().addingTimeInterval(delay)
            while Date() < deadline {
                if Task.isCancelled { return }
                if watch.mark != mark { await onTrouble?(.pathChanged); break }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    /// The attempt's address and ticket, given up on after `addressStepTimeout`. The ticket is a REST call, and one
    /// on a connection the network had dropped could hold the loop for as long as it hung (#423). The call is left to
    /// finish or fail on its own: waiting for it to notice its cancellation is the wait this avoids.
    private func addressAndTicket() async throws -> (URL, [String: String]) {
        let provider = urlProvider
        let gate = OnceGate<(URL, [String: String])>()
        let timeout = addressStepTimeoutSeconds
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<(URL, [String: String]), Error>) in
                gate.arm(c)
                let work = Task {
                    do { gate.settle(.success(try await provider())) } catch { gate.settle(.failure(error)) }
                }
                let timer = Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    if !Task.isCancelled, gate.settle(.failure(SocketError.timeout("the gateway's address and ticket"))) { work.cancel() }
                }
                gate.onSettle { timer.cancel() }
            }
        } onCancel: {
            gate.settle(.failure(CancellationError()))
        }
    }

    /// How long after a failed attempt the next goes out: the first three a second apart,
    /// quiet and quick (a route still coming up on first open), then doubling to half a
    /// minute. Attempt 1 is the one that just failed.
    nonisolated static func retryDelay(attempt: Int) -> Double {
        if attempt <= 3 { return 1 }
        return min(30.0, pow(2.0, Double(min(attempt - 3, 5))))
    }

    private func open(url: URL, headers: [String: String]) async throws {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let t = makePipe(req)
        task = t
        t.resume()
        receiveLoop = Task { await self.receive(on: t) }
    }

    private func teardown(reason: String) {
        heartbeat?.cancel(); heartbeat = nil
        receiveLoop?.cancel(); receiveLoop = nil
        task?.close()
        task = nil
        settleReadyWaiters(throwing: SocketError.notConnected)
        for t in callTimers.values { t.cancel() }
        callTimers = [:]
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
        settleReadyWaiters(throwing: nil)
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

    /// Asks the gateway for a sign of life now and treats silence as the connection lost. The
    /// app coming back to a socket that died quietly while it was suspended should not wait
    /// for the next heartbeat to find out: every resume and send would queue on the dead
    /// socket until then and fail together when it was finally torn down ("Reconnected, but
    /// the chat could not be re-attached", a tester coming back after a while).
    public func checkAlive(timeout: Double = 5) async {
        guard task != nil, state == .open else { return }
        do { _ = try await call("ping", params: [:], timeout: timeout) }
        catch { connectionLost(reason: "no answer to a ping after coming back") }
    }

    private func connectionLost(reason: String) {
        guard task != nil else { return }
        log.warning("connection lost: \(reason, privacy: .public)")
        teardown(reason: reason)
        // Not open from this moment, not from the reconnect loop's first turn: a call made in
        // between saw `.open`, skipped the ready wait and failed on the torn-down socket.
        setState(wantConnected ? .reconnecting(attempt: attempt + 1, delay: 0) : .idle)
        if wantConnected, reconnectTask == nil {
            reconnectTask = Task { await self.runConnectLoop() }
        }
    }

    // MARK: Receive

    private func receive(on t: any GatewayFramePipe) async {
        while !Task.isCancelled, task === t {
            do {
                let text = try await t.receive()
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    handle(InboundFrame.parse(String(line)))
                }
            } catch {
                guard task === t else { return }
                let (code, reason) = t.closeInfo
                if state != .open, code == 4401 || code == 4403 {
                    // Pre-ready rejection: surface to the connect loop via waiters.
                    settleReadyWaiters(throwing: SocketError.closed(code: code, reason: reason))
                    teardown(reason: "closed \(code)")
                    return
                }
                if state != .open, let refused = Self.refusal(of: t.upgradeResponse) {
                    // The upgrade was answered with a page, not a socket: what it was, for the loop to tell apart.
                    settleReadyWaiters(throwing: refused)
                    teardown(reason: "refused")
                    return
                }
                if state != .open {
                    settleReadyWaiters(throwing: SocketError.closed(code: code, reason: reason.isEmpty ? error.localizedDescription : reason))
                    teardown(reason: "closed")
                    return
                }
                connectionLost(reason: "receive error: \(error.localizedDescription)")
                return
            }
        }
    }

    /// An upgrade answered with something other than a socket (101): its status, where it pointed or ended up, and
    /// whether Cloudflare sent it and it was a web page.
    nonisolated static func refusal(of response: HTTPURLResponse?) -> SocketError? {
        guard let http = response, http.statusCode != 101, http.statusCode != 0 else { return nil }
        let server = (http.value(forHTTPHeaderField: "Server") ?? "").lowercased()
        let cloudflare = server.contains("cloudflare") || http.value(forHTTPHeaderField: "CF-RAY") != nil
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let location = http.value(forHTTPHeaderField: "Location") ?? http.url?.absoluteString
        return .refused(status: http.statusCode, location: location, cloudflare: cloudflare, html: type.contains("text/html"))
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
            callTimers.removeValue(forKey: n)?.cancel()
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
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSONValue, Error>) in
                Task { await self.register(id: id, continuation: c, task: task, text: text, method: method, timeout: timeout) }
            }
        } onCancel: {
            Task { await self.fail(id: id, SocketError.timeout("\(method) (cancelled)")) }
        }
    }

    /// Fails one pending call, if it is still pending; its reply or a teardown may have
    /// settled it first, and only the one still registered is ours to fail.
    private func fail(id: Int, _ error: Error) {
        callTimers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func register(id: Int, continuation: CheckedContinuation<JSONValue, Error>, task: any GatewayFramePipe, text: String, method: String, timeout: Double) async {
        pending[id] = continuation
        callTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.fail(id: id, SocketError.timeout(method))
        }
        do { try await task.send(text) }
        catch {
            // The socket may have closed while the send was in flight, and the close path has
            // then already failed every pending call, this one included: a second resume traps
            // (a crash report on 1.1 (9)). Only the one still registered is ours to fail.
            fail(id: id, SocketError.notConnected)
        }
    }

    /// Answers a server request that was surfaced outside the inline handler (e.g. replayed `open_requests`).
    public func respond(to id: String, result: JSONValue) async {
        await sendText(RPCFrames.response(id: id, result: result))
    }

    private func sendText(_ text: String) async {
        guard let task else { return }
        try? await task.send(text)
    }
}

/// A continuation resumed once, by whichever of its racers settles first; later settles are no-ops.
final class OnceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var settled = false
    private var then: (() -> Void)?

    func arm(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let early { lock.unlock(); c.resume(with: early); return }
        continuation = c
        lock.unlock()
    }

    /// Runs `f` once the gate settles (at once if it already has).
    func onSettle(_ f: @escaping () -> Void) {
        lock.lock()
        if settled { lock.unlock(); f(); return }
        then = f
        lock.unlock()
    }

    /// True when this call was the one that settled it.
    @discardableResult
    func settle(_ r: Result<T, Error>) -> Bool {
        lock.lock()
        guard !settled else { lock.unlock(); return false }
        settled = true
        let c = continuation; continuation = nil
        if c == nil { early = r }
        let f = then; then = nil
        lock.unlock()
        c?.resume(with: r)
        f?()
        return true
    }
}

