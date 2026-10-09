import Foundation
import Network
import Testing
@testable import VoryCore

/// A gateway socket that stops answering without closing: what a suspended app's socket looks
/// like when the phone's radio has forgotten it. The socket's timeouts have to fire on it, or
/// the heartbeat never sees the connection as lost and every resume and send waits for good
/// (testers came back to a long turn and found the app stuck, 1.4 (7) and (8)).
///
/// A WebSocket server of our own on the loopback: it completes the handshake, sends what the
/// test tells it to, and otherwise says nothing.
@Suite struct SocketTimeoutTests {
    /// Accepts one WebSocket connection and sends `greeting` on it; never answers anything.
    final class SilentServer: @unchecked Sendable {
        let listener: NWListener
        private(set) var port: UInt16 = 0
        private var connections: [NWConnection] = []
        private let queue = DispatchQueue(label: "dev.vory.tests.silent-server")

        init(greeting: String?) throws {
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
                queue.async { self.connections.append(c) }
                c.stateUpdateHandler = { state in
                    guard case .ready = state, let greeting else { return }
                    let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                    let ctx = NWConnection.ContentContext(identifier: "greeting", metadata: [meta])
                    c.send(content: Data(greeting.utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
                }
                // Read and drop everything the client sends, so the stream keeps flowing.
                func drain() {
                    c.receiveMessage { _, _, _, error in if error == nil { drain() } }
                }
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

    private func socket(port: UInt16) -> GatewaySocket {
        GatewaySocket(urlProvider: { (URL(string: "ws://127.0.0.1:\(port)/api/ws")!, [:]) },
                      onEvent: { _ in }, onState: { _ in }, onServerRequest: { _ in nil }, onReconnected: {})
    }

    static let ready = #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","session_id":"","payload":{}}}"#

    @Test func aCallOnASocketThatStoppedAnsweringTimesOut() async throws {
        let server = try SilentServer(greeting: Self.ready)
        defer { server.stop() }
        #expect(server.port != 0)
        let s = socket(port: server.port)
        await s.connect()
        try await s.waitUntilReady(timeout: 10)
        let began = Date()
        await #expect(throws: SocketError.self) {
            _ = try await s.call("ping", params: [:], timeout: 1)
        }
        let took = Date().timeIntervalSince(began)
        #expect(took < 5, "the call took \(took) s to time out")
        await s.disconnect()
    }

    @Test func waitingForReadyOnAServerThatNeverSaysSoTimesOut() async throws {
        let server = try SilentServer(greeting: nil)
        defer { server.stop() }
        let s = socket(port: server.port)
        await s.connect()
        let began = Date()
        await #expect(throws: SocketError.self) {
            try await s.waitUntilReady(timeout: 1)
        }
        let took = Date().timeIntervalSince(began)
        #expect(took < 5, "the wait took \(took) s to time out")
        await s.disconnect()
    }

    @Test func comingBackToASocketThatStoppedAnsweringTearsItDown() async throws {
        let server = try SilentServer(greeting: Self.ready)
        defer { server.stop() }
        let s = socket(port: server.port)
        await s.connect()
        try await s.waitUntilReady(timeout: 10)
        #expect(await s.state == .open)
        let began = Date()
        await s.checkAlive(timeout: 1)
        #expect(await s.state != .open, "a socket that answers no ping is still open")
        #expect(Date().timeIntervalSince(began) < 5)
        await s.disconnect()
    }

    @Test func aCallThatIsCancelledReturnsAtOnce() async throws {
        let server = try SilentServer(greeting: Self.ready)
        defer { server.stop() }
        let s = socket(port: server.port)
        await s.connect()
        try await s.waitUntilReady(timeout: 10)
        let began = Date()
        let t = Task { try await s.call("session.resume", params: [:], timeout: 120) }
        try await Task.sleep(for: .milliseconds(200))
        t.cancel()
        await #expect(throws: Error.self) { _ = try await t.value }
        #expect(Date().timeIntervalSince(began) < 5)
        await s.disconnect()
    }
}
