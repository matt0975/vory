import Foundation
import Testing
@testable import VoryCore

/// #592: a socket lost while the app re-attached its chats left the app on "Reconnecting (1)…" for good. The re-attach
/// (the socket's `onReconnected` hook) runs inside the connect loop, so the loss found the loop still there and started
/// no other, and the loop then ended as if its attempt had held. A chat re-attach that fails on the lost socket waits
/// for the next reconnect (`ReattachTests`), so nothing tried again.
///
/// The socket runs over the demo's pipe (`DemoConnectionTests.LocalPipe`): it says it is ready as it opens, and the test
/// drops it as a network drops a socket.
@Suite struct ReconnectDuringReattachTests {
    /// Every pipe the socket opened, in order: one per attempt.
    final class Pipes: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [DemoConnectionTests.LocalPipe] = []
        func make() -> DemoConnectionTests.LocalPipe {
            let p = DemoConnectionTests.LocalPipe()
            lock.withLock { made.append(p) }
            return p
        }
        var count: Int { lock.withLock { made.count } }
        var last: DemoConnectionTests.LocalPipe? { lock.withLock { made.last } }
    }

    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.withLock { n += 1; return n } }
        var count: Int { lock.withLock { n } }
    }

    /// How many states the socket has said it is reconnecting in.
    final class Reconnecting: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add(_ s: SocketState) { if case .reconnecting = s { lock.withLock { n += 1 } } }
        var count: Int { lock.withLock { n } }
    }

    @Test func aSocketLostWhileTheChatsReattachTriesAgain() async throws {
        let pipes = Pipes(), reconnecting = Reconnecting(), reattaches = Tally(), firstOpens = Tally()
        let socket = GatewaySocket(
            urlProvider: { (URL(string: "ws://demo.invalid/api/ws")!, [:]) },
            onEvent: { _ in }, onState: { reconnecting.add($0) }, onServerRequest: { _ in nil },
            onReconnected: {
                // The first re-attach: the socket drops under it, and it returns once the socket has seen the loss, as
                // a re-attach whose calls fail on the torn-down socket does.
                guard reattaches.next() == 1 else { return }
                let before = reconnecting.count
                pipes.last?.shut(code: 1006, reason: "dropped during the re-attach")
                for _ in 0..<100 where reconnecting.count == before { try? await Task.sleep(for: .milliseconds(20)) }
            },
            onFirstConnected: { _ = firstOpens.next() },
            makePipe: { _ in pipes.make() })
        await socket.connect()
        try await socket.waitUntilReady(timeout: 5)
        for _ in 0..<100 where firstOpens.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        // Let the first connect's loop end, so the drop below is one with nothing re-attaching: the socket comes back on
        // a second pipe and re-attaches, and the drop above happens there.
        try await Task.sleep(for: .milliseconds(100))
        pipes.last?.shut(code: 1006, reason: "dropped")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(pipes.count >= 3 && reattaches.count >= 2) { try await Task.sleep(for: .milliseconds(20)) }
        let state = await socket.state
        #expect(pipes.count == 3, "the socket opened \(pipes.count) pipes; a third should follow the drop during the re-attach")
        #expect(state == .open, "the socket is on \"\(state.label)\"")
        #expect(reattaches.count == 2, "the chats were re-attached \(reattaches.count) times")
        await socket.disconnect()
    }

    /// The socket, for a hook that waits on it.
    final class SocketBox: @unchecked Sendable {
        private let lock = NSLock()
        private var s: GatewaySocket?
        var socket: GatewaySocket? {
            get { lock.withLock { s } }
            set { lock.withLock { s = newValue } }
        }
    }

    /// What the hook's wait for the socket came to: "ready", or the error's words.
    final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var v: String?
        func set(_ s: String) { lock.withLock { v = s } }
        var value: String? { lock.withLock { v } }
    }

    /// #641: a socket lost while the chats re-attach is opened again before they finish. The re-attach hook ran inside
    /// the connect loop, so the loss started no other loop, and each chat after it waited 20 s on a gateway.ready that
    /// only the held loop could bring: "Timed out waiting for gateway.ready." (Matt's banner). Here the hook drops its
    /// pipe and then waits on the socket as a chat's re-attach does, for up to 3 s.
    @Test func aSocketLostWhileTheChatsReattachReconnectsBeforeTheyFinish() async throws {
        let pipes = Pipes(), reattaches = Tally(), firstOpens = Tally(), box = SocketBox(), waited = Outcome()
        let socket = GatewaySocket(
            urlProvider: { (URL(string: "ws://demo.invalid/api/ws")!, [:]) },
            onEvent: { _ in }, onState: { _ in }, onServerRequest: { _ in nil },
            onReconnected: {
                guard reattaches.next() == 1 else { return }
                pipes.last?.shut(code: 1006, reason: "dropped during the re-attach")
                // Once the socket has seen the loss (its ready from before no longer counts), as a chat's calls do.
                for _ in 0..<100 { if let s = box.socket, await s.state != .open { break }; try? await Task.sleep(for: .milliseconds(20)) }
                do {
                    try await box.socket?.waitUntilReady(timeout: 3)
                    waited.set("ready")
                } catch {
                    waited.set(error.localizedDescription)
                }
            },
            onFirstConnected: { _ = firstOpens.next() },
            makePipe: { _ in pipes.make() })
        box.socket = socket
        await socket.connect()
        try await socket.waitUntilReady(timeout: 5)
        for _ in 0..<100 where firstOpens.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        // A drop with nothing re-attaching: the socket comes back on a second pipe and re-attaches, and the hook drops that.
        pipes.last?.shut(code: 1006, reason: "dropped")
        for _ in 0..<400 where waited.value == nil { try await Task.sleep(for: .milliseconds(20)) }
        let opened = pipes.count
        #expect(waited.value == "ready", "the re-attach's wait for the socket came to \"\(waited.value ?? "nothing in 8 s")\" with \(opened) pipes opened")
        await socket.disconnect()
    }
}
