import Foundation
import Network
import Testing
@testable import VoryCore

/// #423: a gateway behind a Cloudflare Tunnel stayed on "Reconnecting" until the app was quit. Cloudflare answered
/// every attempt with a page (a redirect to Access's sign-in, its "origin unreachable" error) and the loop counted
/// attempts without saying so; and the REST session that mints the socket's ticket lasted as long as the app, so a
/// connection a network change had broken kept failing until the app was quit. Now the socket tells the causes apart
/// after a few attempts that fail the same way, gives a ticket that ran out one more go, gives up on an address step
/// that hangs, and has the runtime make its REST connections afresh.
@Suite struct ReconnectProblemTests {
    /// Answers every connection with one canned HTTP response and closes it, as Cloudflare's edge answers an upgrade
    /// it cannot pass on.
    final class CannedHTTPServer: @unchecked Sendable {
        let listener: NWListener
        private(set) var port: UInt16 = 0
        private let queue = DispatchQueue(label: "dev.vory.tests.canned-http")
        private let lock = NSLock()
        private var _requests = 0
        var requests: Int { lock.lock(); defer { lock.unlock() }; return _requests }

        init(response: String) throws {
            listener = try NWListener(using: .tcp, on: .any)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
                if case .failed = state { ready.signal() }
            }
            let bytes = Data(response.utf8)
            listener.newConnectionHandler = { [self] c in
                c.start(queue: queue)
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                    self.lock.lock(); self._requests += 1; self.lock.unlock()
                    c.send(content: bytes, completion: .contentProcessed { _ in c.cancel() })
                }
            }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 5)
            port = listener.port?.rawValue ?? 0
        }

        func stop() { listener.cancel() }
    }

    /// A WebSocket server that closes the first `refusals` connections with 4401 and greets the rest as ready.
    final class TicketServer: @unchecked Sendable {
        let listener: NWListener
        private(set) var port: UInt16 = 0
        private let queue = DispatchQueue(label: "dev.vory.tests.ticket-server")
        private var connections: [NWConnection] = []
        private var refusalsLeft: Int

        init(refusals: Int) throws {
            refusalsLeft = refusals
            let params = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            listener = try NWListener(using: params, on: .any)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
                if case .failed = state { ready.signal() }
            }
            listener.newConnectionHandler = { [self] c in
                connections.append(c)
                let refuse = refusalsLeft > 0
                if refuse { refusalsLeft -= 1 }
                c.stateUpdateHandler = { state in
                    guard case .ready = state else { return }
                    if refuse {
                        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
                        meta.closeCode = .privateCode(4401)
                        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
                        c.send(content: Data("ticket expired".utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
                    } else {
                        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                        let ctx = NWConnection.ContentContext(identifier: "ready", metadata: [meta])
                        c.send(content: Data(SocketTimeoutTests.ready.utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
                    }
                }
                func drain() { c.receiveMessage { _, _, _, error in if error == nil { drain() } } }
                c.start(queue: queue)
                drain()
            }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 5)
            port = listener.port?.rawValue ?? 0
        }

        func stop() {
            listener.cancel()
            queue.sync { for c in connections { c.cancel() } }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        private var troubles: [ConnectTrouble] = []
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func note(_ t: ConnectTrouble) { lock.lock(); troubles.append(t); lock.unlock() }
        var noted: [ConnectTrouble] { lock.lock(); defer { lock.unlock() }; return troubles }
    }

    private func socket(port: UInt16, calls: Counter? = nil) -> GatewaySocket {
        GatewaySocket(urlProvider: { _ = calls?.bump(); return (URL(string: "ws://127.0.0.1:\(port)/api/ws")!, [:]) },
                      onEvent: { _ in }, onState: { _ in }, onServerRequest: { _ in nil }, onReconnected: {})
    }

    /// Polls the socket's state until `match` says yes or `seconds` pass.
    private func waitFor(_ s: GatewaySocket, seconds: Double, _ match: @escaping (SocketState) -> Bool) async -> SocketState {
        let deadline = Date().addingTimeInterval(seconds)
        var last = await s.state
        while Date() < deadline {
            last = await s.state
            if match(last) { return last }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return last
    }

    private static func unreachable(_ s: SocketState) -> ConnectProblem? {
        if case .unreachable(let p, _) = s { return p }
        return nil
    }

    // MARK: Cloudflare's pages, told apart

    @Test func aRedirectToCloudflareAccessIsToldAsASignInVoryCannotDo() async throws {
        let server = try CannedHTTPServer(response: "HTTP/1.1 302 Found\r\nLocation: https://team.cloudflareaccess.com/cdn-cgi/access/login/gw.example.com?kid=k\r\nServer: cloudflare\r\nCF-RAY: test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { server.stop() }
        let s = socket(port: server.port)
        await s.connect()
        let state = await waitFor(s, seconds: 10) { Self.unreachable($0) != nil }
        #expect(Self.unreachable(state) == .cloudflareSignIn, "state \(state)")
        #expect(state.label == "Cloudflare wants a sign-in")
        await s.disconnect()
    }

    @Test func cloudflaresOriginErrorIsToldAsTheGatewayUnreachableBehindIt() async throws {
        let page = "<!DOCTYPE html><html><body>Error 523 Origin is unreachable</body></html>"
        let server = try CannedHTTPServer(response: "HTTP/1.1 523 Origin Error\r\nContent-Type: text/html\r\nServer: cloudflare\r\nCF-RAY: test\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)")
        defer { server.stop() }
        let s = socket(port: server.port)
        await s.connect()
        let state = await waitFor(s, seconds: 10) { Self.unreachable($0) != nil }
        #expect(Self.unreachable(state) == .cloudflareOrigin(status: 523), "state \(state)")
        #expect(server.requests >= GatewaySocket.problemShownAfter)
        await s.disconnect()
    }

    @Test func theFirstFailuresStillCountAttemptsBeforeNamingTheProblem() async throws {
        let server = try CannedHTTPServer(response: "HTTP/1.1 523 Origin Error\r\nServer: cloudflare\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { server.stop() }
        var states: [SocketState] = []
        let box = StateLog()
        let s = GatewaySocket(urlProvider: { (URL(string: "ws://127.0.0.1:\(server.port)/api/ws")!, [:]) },
                              onEvent: { _ in }, onState: { box.add($0) }, onServerRequest: { _ in nil }, onReconnected: {})
        await s.connect()
        _ = await waitFor(s, seconds: 10) { Self.unreachable($0) != nil }
        await s.disconnect()
        states = box.all
        let firstNamed = states.firstIndex { Self.unreachable($0) != nil }
        let reconnectingBefore = states.prefix(firstNamed ?? 0).filter { if case .reconnecting = $0 { return true }; return false }
        #expect(firstNamed != nil)
        #expect(!reconnectingBefore.isEmpty, "the problem was named on the first failure: \(states)")
    }

    // MARK: Tickets

    @Test func aTicketRefusedOnceGetsOneMoreGoWithAFreshOne() async throws {
        let server = try TicketServer(refusals: 1)
        defer { server.stop() }
        let calls = Counter()
        let s = socket(port: server.port, calls: calls)
        await s.connect()
        // The state, not a ready wait: a wait made during the refused attempt ends with that attempt, as before.
        let state = await waitFor(s, seconds: 10) { $0 == .open }
        #expect(state == .open, "state \(state)")
        #expect(calls.count == 2, "address and ticket asked for \(calls.count) times")
        await s.disconnect()
    }

    @Test func aTicketRefusedTwiceIsASignInRefused() async throws {
        let server = try TicketServer(refusals: 10)
        defer { server.stop() }
        let calls = Counter()
        let s = socket(port: server.port, calls: calls)
        await s.connect()
        let state = await waitFor(s, seconds: 10) { if case .authRejected = $0 { return true }; return false }
        if case .authRejected = state {} else { Issue.record("not refused: \(state)") }
        #expect(calls.count == 2)
        await s.disconnect()
    }

    // MARK: The address step and the REST session

    @Test func anAddressStepThatHangsIsGivenUpOnAndTriedAgain() async throws {
        let calls = Counter()
        let s = GatewaySocket(urlProvider: {
            _ = calls.bump()
            // Hangs and ignores its cancellation: the wait the loop must not share.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return (URL(string: "ws://127.0.0.1:9/api/ws")!, [:])
        }, onEvent: { _ in }, onState: { _ in }, onServerRequest: { _ in nil }, onReconnected: {})
        await s.setAddressStepTimeout(0.5)
        await s.connect()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, calls.count < 3 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(calls.count >= 3, "the loop stayed on a hung address step (\(calls.count) tries)")
        await s.disconnect()
    }

    @Test func twoUnansweredTicketsInARowAskForAFreshRESTSession() async throws {
        let troubles = Counter()
        let s = GatewaySocket(urlProvider: { throw HermesAPIError.transport("The request timed out.") },
                              onEvent: { _ in }, onState: { _ in }, onServerRequest: { _ in nil }, onReconnected: {})
        await s.setTroubleHandler { troubles.note($0) }
        await s.connect()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !troubles.noted.contains(.addressStepNoAnswer) { try await Task.sleep(for: .milliseconds(100)) }
        await s.disconnect()
        #expect(troubles.noted.contains(.addressStepNoAnswer), "troubles: \(troubles.noted)")
    }

    @Test func aTicketAnsweredWithAPageDoesNotThrowAwayTheRESTSession() async throws {
        let troubles = Counter()
        let s = GatewaySocket(urlProvider: { throw HermesAPIError.htmlResponse(status: 523) },
                              onEvent: { _ in }, onState: { _ in }, onServerRequest: { _ in nil }, onReconnected: {})
        await s.setTroubleHandler { troubles.note($0) }
        await s.connect()
        let state = await waitFor(s, seconds: 10) { Self.unreachable($0) != nil }
        await s.disconnect()
        #expect(Self.unreachable(state) == .cloudflareOrigin(status: 523))
        #expect(!troubles.noted.contains(.addressStepNoAnswer), "an answer is not a broken connection: \(troubles.noted)")
    }

    // MARK: Classification

    @Test func errorsAreToldApart() {
        #expect(ConnectProblem.of(SocketError.refused(status: 302, location: "https://t.cloudflareaccess.com/cdn-cgi/access/login/x", cloudflare: true, html: false)) == .cloudflareSignIn)
        #expect(ConnectProblem.of(SocketError.refused(status: 302, location: "https://gw.example.com/cdn-cgi/access/login/gw", cloudflare: false, html: false)) == .cloudflareSignIn)
        #expect(ConnectProblem.of(SocketError.refused(status: 403, location: nil, cloudflare: true, html: true)) == .cloudflareSignIn)
        #expect(ConnectProblem.of(SocketError.refused(status: 523, location: nil, cloudflare: true, html: true)) == .cloudflareOrigin(status: 523))
        #expect(ConnectProblem.of(SocketError.refused(status: 523, location: nil, cloudflare: false, html: false)) == .http(status: 523))
        #expect(ConnectProblem.of(SocketError.refused(status: 200, location: nil, cloudflare: false, html: true)) == .webPage(status: 200))
        #expect(ConnectProblem.of(SocketError.refused(status: 404, location: nil, cloudflare: false, html: false)) == .http(status: 404))
        #expect(ConnectProblem.of(SocketError.timeout("x")) == .noAnswer)
        #expect(ConnectProblem.of(SocketError.closed(code: 1006, reason: "")) == .noAnswer)
        #expect(ConnectProblem.of(SocketError.closed(code: 4401, reason: "")) == nil)
        #expect(ConnectProblem.of(SocketError.cancelled) == nil)
        #expect(ConnectProblem.of(HermesAPIError.cloudflareAccess(status: 200)) == .cloudflareSignIn)
        #expect(ConnectProblem.of(HermesAPIError.htmlResponse(status: 522)) == .cloudflareOrigin(status: 522))
        #expect(ConnectProblem.of(HermesAPIError.htmlResponse(status: 200)) == .webPage(status: 200))
        #expect(ConnectProblem.of(HermesAPIError.http(status: 502, detail: "")) == .http(status: 502))
        #expect(ConnectProblem.of(HermesAPIError.transport("timed out")) == .noAnswer)
        #expect(ConnectProblem.of(HermesAPIError.unauthorized("")) == nil)
        #expect(ConnectProblem.of(HermesAPIError.sessionExpired) == nil)
        #expect(ConnectProblem.of(URLError(.networkConnectionLost)) == .noAnswer)
        #expect(ConnectProblem.of(URLError(.notConnectedToInternet)) == nil)
    }

    @Test func anAccessSignInPageOverRESTIsItsOwnError() throws {
        let access = HTTPURLResponse(url: URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/login/gw.example.com?kid=k")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
        if case .cloudflareAccess = HermesAPI.error(for: access, data: Data("<html>".utf8)) {} else { Issue.record("not told as Access") }
        if case .cloudflareAccess = HermesAPI.htmlError(access) {} else { Issue.record("not told as Access") }
        let portal = HTTPURLResponse(url: URL(string: "http://captive.example/login")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
        if case .htmlResponse(200) = HermesAPI.htmlError(portal) {} else { Issue.record("a captive portal told as Access") }
    }
}

/// The REST session made afresh (#423): the new one takes calls at once, a call still on the old one fails into its
/// caller's usual handling, and the new one keeps the transport's protocol classes (no real network where there was
/// none).
@Suite(.serialized) struct RESTSessionResetTests {
    /// Answers every request with a small JSON body, counting them.
    final class AnswerProtocol: URLProtocol {
        nonisolated(unsafe) static var answered = 0
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.answered += 1
            let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// Never answers: a connection a network change has broken.
    final class StallProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}
    }

    private func api(_ protocols: [AnyClass], makeSession: (@Sendable () -> URLSession)? = nil) throws -> HermesAPI {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = protocols
        let g = try GatewayURL.normalize("https://gw.example.com")
        return HermesAPI(gateway: g, signer: RequestSigner(authMode: .sessionToken, sessionToken: "tok", bearer: nil, access: CloudflareAccess(clientId: "", clientSecret: "")),
                         urlSession: URLSession(configuration: cfg), makeSession: makeSession)
    }

    @Test func aWriteOnTheOldSessionFailsAtOnceAndIsNotSentAgain() async throws {
        AnswerProtocol.answered = 0
        let a = try api([StallProtocol.self], makeSession: {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [AnswerProtocol.self]
            return URLSession(configuration: cfg)
        })
        let began = Date()
        let call = Task { () -> Bool in
            do { let _: JSONValue = try await a.send("POST", "/api/sessions/x/title", body: EmptyBody()); return true } catch { return false }
        }
        try await Task.sleep(for: .milliseconds(300))
        await a.resetSession()
        let answered = await call.value
        #expect(!answered)
        #expect(AnswerProtocol.answered == 0, "the write was sent again on the new session")
        #expect(Date().timeIntervalSince(began) < 5, "the stalled call waited for its own timeout")
        #expect(await a.sessionResets == 1)
    }

    @Test func aReadCutOffByAResetGoesAgainOnTheNewSession() async throws {
        AnswerProtocol.answered = 0
        let a = try api([StallProtocol.self], makeSession: {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [AnswerProtocol.self]
            return URLSession(configuration: cfg)
        })
        let call = Task { () -> Bool in
            do { let _: JSONValue = try await a.get("/api/sessions"); return true } catch { return false }
        }
        try await Task.sleep(for: .milliseconds(300))
        await a.resetSession()
        #expect(await call.value, "a load cut off by the reset was dropped")
        #expect(AnswerProtocol.answered == 1)
    }

    @Test func theNewSessionKeepsTheTransportsProtocolClassesAndAnswers() async throws {
        AnswerProtocol.answered = 0
        let a = try api([AnswerProtocol.self])
        await a.resetSession()
        let classes = await a.sessionConfiguration.protocolClasses ?? []
        #expect(classes.contains { $0 == AnswerProtocol.self }, "the replacement lost the transport's protocol: \(classes)")
        let _: JSONValue = try await a.get("/api/status")
        #expect(AnswerProtocol.answered == 1)
    }

    @Test func aGivenFactoryMakesTheReplacement() async throws {
        let made = ReconnectProblemTests.Counter()
        let a = try api([StallProtocol.self], makeSession: {
            _ = made.bump()
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [AnswerProtocol.self]
            return URLSession(configuration: cfg)
        })
        await a.resetSession()
        #expect(made.count == 1)
        let _: JSONValue = try await a.get("/api/status")
    }
}

/// Every state a socket reported, in order.
final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [SocketState] = []
    func add(_ s: SocketState) { lock.lock(); states.append(s); lock.unlock() }
    var all: [SocketState] { lock.lock(); defer { lock.unlock() }; return states }
}

/// The runtime makes its REST session afresh through its own transport (#423), never as a plain network session: a demo
/// runtime (the demo's in-process transport, #392) must never be handed a real network session by a reset.
@Suite(.serialized) struct TransportSessionResetTests {
    /// Answers in process, as the demo's transport does.
    final class InProcessProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @MainActor @Test func aDemoRuntimesResetSessionComesFromItsTransportAndStaysInProcess() async throws {
        let made = ReconnectProblemTests.Counter()
        let transport = GatewayTransport(makeHTTPSession: {
            _ = made.bump()
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [InProcessProtocol.self]
            return URLSession(configuration: cfg)
        }, makeFramePipe: { request, session in GatewayTransport.network.makeFramePipe(request, session) })
        let rt = GatewayRuntime(connection: .demo, store: ConnectionStore(), transport: transport)
        let before = made.count
        await rt.api.resetSession()
        #expect(made.count == before + 1, "the reset did not ask the runtime's transport for its session")
        let classes = await rt.api.sessionConfiguration.protocolClasses ?? []
        #expect(classes.count == 1 && classes.first == InProcessProtocol.self, "the reset session is not the transport's alone: \(classes)")
        let answer: JSONValue = try await rt.api.get("/api/status")
        #expect(answer["ok"]?.boolValue == true)
    }
}
