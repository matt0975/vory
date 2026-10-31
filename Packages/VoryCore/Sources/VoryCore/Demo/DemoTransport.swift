import Foundation

extension GatewayTransport {
    /// The demo (#392): every request and every socket frame answered in process by `gateway`,
    /// with nothing sent anywhere. Its sessions name the gateway in a header, so each runtime's
    /// requests reach its own demo, and the binding goes when the runtime stops.
    public static func demo(_ gateway: DemoGateway) -> GatewayTransport {
        let id = DemoURLProtocol.bind(gateway)
        return GatewayTransport(
            makeHTTPSession: {
                let cfg = URLSessionConfiguration.ephemeral
                cfg.protocolClasses = [DemoURLProtocol.self]
                cfg.httpAdditionalHeaders = [DemoURLProtocol.gatewayHeader: id]
                cfg.httpCookieAcceptPolicy = .never
                cfg.httpShouldSetCookies = false
                cfg.waitsForConnectivity = false
                cfg.urlCache = nil
                return URLSession(configuration: cfg)
            },
            makeFramePipe: { request, _ in DemoSocketPipe(gateway: gateway, path: request.url?.path ?? "/api/ws", query: request.url?.query) },
            stop: { DemoURLProtocol.unbind(id) }, isInProcess: true)
    }
}

/// Answers the REST calls of the sessions the demo transport makes, in process, from the gateway
/// their header names (`bind`). It takes every request those sessions make, whatever its host: one
/// for anywhere but the demo, or for a demo whose runtime has stopped, fails as if the device were
/// offline and is counted (`refused`), and nothing goes out to the network.
final class DemoURLProtocol: URLProtocol, @unchecked Sendable {
    static let gatewayHeader = "X-Vory-Demo"

    private struct Bound { weak var gateway: DemoGateway? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bound: [String: Bound] = [:]
    nonisolated(unsafe) private static var refusedCount = 0

    /// Requests the demo's sessions refused. None is ever expected: each one is a page asking the network for something.
    static var refused: Int { lock.withLock { refusedCount } }

    /// The id a demo session's requests carry to reach `gateway`; held weakly, so a demo nothing runs any more is gone.
    static func bind(_ gateway: DemoGateway) -> String {
        let id = UUID().uuidString
        lock.withLock {
            bound = bound.filter { $0.value.gateway != nil }
            bound[id] = Bound(gateway: gateway)
        }
        return id
    }

    static func unbind(_ id: String) { _ = lock.withLock { bound.removeValue(forKey: id) } }

    static func gateway(for request: URLRequest) -> DemoGateway? {
        guard request.url?.host == DemoGateway.host, let id = request.value(forHTTPHeaderField: gatewayHeader) else { return nil }
        return lock.withLock { bound[id]?.gateway }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var work: Task<Void, Never>?

    override func startLoading() {
        guard let url = request.url, let gateway = Self.gateway(for: request) else {
            Self.lock.withLock { Self.refusedCount += 1 }
            DemoGateway.log.error("demo refused a request for \(self.request.url?.host ?? "no host", privacy: .public)")
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        // URLProtocol hands its client over to whichever thread finishes the load; this one is not touched elsewhere.
        nonisolated(unsafe) let me = self
        work = Task {
            let answer = await gateway.rest(method: method, url: url, body: body, contentType: contentType)
            guard !Task.isCancelled else { return }
            var fields = ["Content-Type": answer.contentType, "Content-Length": String(answer.body.count)]
            fields.merge(answer.headers) { _, extra in extra }
            let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: fields)!
            me.client?.urlProtocol(me, didReceive: response, cacheStoragePolicy: .notAllowed)
            me.client?.urlProtocol(me, didLoad: answer.body)
            me.client?.urlProtocolDidFinishLoading(me)
        }
    }

    override func stopLoading() { work?.cancel() }

    private static func read(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// The demo's socket: text frames in and out of `DemoGateway` with no connection under them.
/// The gateway's socket (`/api/ws`) or the board's events (`/api/plugins/kanban/events`).
final class DemoSocketPipe: GatewayFramePipe, @unchecked Sendable {
    private let gateway: DemoGateway
    let path: String
    let query: String?
    private let lock = NSLock()
    private var inbox: [String] = []
    private var waiting: CheckedContinuation<String, Error>?
    private var closed = false

    init(gateway: DemoGateway, path: String, query: String?) {
        self.gateway = gateway
        self.path = path
        self.query = query
    }

    func resume() { Task { await gateway.attach(self) } }

    func send(_ text: String) async throws {
        if lock.withLock({ closed }) { throw URLError(.networkConnectionLost) }
        await gateway.receive(text, from: self)
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if !inbox.isEmpty { let t = inbox.removeFirst(); lock.unlock(); c.resume(returning: t); return }
            if closed { lock.unlock(); c.resume(throwing: URLError(.networkConnectionLost)); return }
            waiting = c
            lock.unlock()
        }
    }

    func close() {
        lock.lock()
        let wasOpen = !closed
        closed = true
        let w = waiting; waiting = nil
        lock.unlock()
        w?.resume(throwing: URLError(.networkConnectionLost))
        if wasOpen { Task { await gateway.detach(self) } }
    }

    /// Nothing closes a demo socket but the app itself, as the client going away.
    var closeInfo: (code: Int, reason: String) { (1001, "") }

    /// A frame from the gateway; dropped once the pipe has closed.
    func push(_ text: String) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if let w = waiting { waiting = nil; lock.unlock(); w.resume(returning: text); return }
        inbox.append(text)
        lock.unlock()
    }

    var isClosed: Bool { lock.withLock { closed } }
}
