import Foundation
import Testing
@testable import VoryCore

/// The demo's seam (#392): one fixed connection that is never saved, one check that says so, and
/// a socket that runs over a pipe of its own as well as over the network.
@MainActor
@Suite struct DemoConnectionTests {
    private func defaults() -> UserDefaults {
        let name = "dev.vory.tests.demo." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private let home = GatewayConnection(name: "Home", gateway: try! GatewayURL.normalize("https://gateway.example.test"), authMode: .sessionToken)

    @Test func theDemoIsTheOneCheckAndOnlyTheDemoPassesIt() {
        #expect(GatewayConnection.demo.isDemo)
        #expect(!home.isDemo)
        // A copy with another name or address is still the demo: the id decides, nothing else.
        var renamed = GatewayConnection.demo
        renamed.name = "Something else"
        #expect(renamed.isDemo)
        #expect(GatewayRuntime(connection: .demo, store: ConnectionStore(defaults: defaults(), connections: [])).isEphemeral)
        #expect(!GatewayRuntime(connection: home, store: ConnectionStore(defaults: defaults(), connections: [home])).isEphemeral)
    }

    @Test func theDemoInUseIsNeverWritten() throws {
        let d = defaults()
        let store = ConnectionStore(defaults: d, connections: [home])
        store.activeConnectionID = home.id
        store.activeConnectionID = GatewayConnection.demoID
        #expect(store.active == .demo)
        #expect(store.activeConnectionID == GatewayConnection.demoID)
        #expect(store.connection(id: GatewayConnection.demoID) == .demo)
        // The defaults still hold the saved gateway, and the list never takes the demo.
        #expect(d.string(forKey: "activeConnectionID") == home.id.uuidString)
        try store.upsert(.demo, secrets: GatewaySecrets(sessionToken: "demo"))
        store.saveSecrets(GatewaySecrets(sessionToken: "demo"), for: GatewayConnection.demoID)
        #expect(store.connections == [home])
        #expect(store.secrets(for: GatewayConnection.demoID) == GatewaySecrets())
        var picked = GatewayConnection.demo
        picked.lastProfile = "writer"
        store.updateMetadata(picked)
        #expect(store.active?.lastProfile == "writer")
        #expect(store.connections == [home])
    }

    @Test func aRelaunchMidDemoComesBackOnTheSavedGateway() {
        let d = defaults()
        let store = ConnectionStore(defaults: d, connections: [home])
        store.activeConnectionID = home.id
        store.activeConnectionID = GatewayConnection.demoID
        // The process ends mid-demo (a crash, a force quit): the next one reads what was saved.
        let next = ConnectionStore(defaults: d, connections: [home])
        #expect(next.demo == nil)
        #expect(next.active == home)
        #expect(next.activeConnectionID == home.id)
    }

    @Test func leavingTheDemoPutsTheSavedGatewayBack() {
        let d = defaults()
        let store = ConnectionStore(defaults: d, connections: [home])
        store.activeConnectionID = home.id
        store.activeConnectionID = GatewayConnection.demoID
        store.delete(id: GatewayConnection.demoID)
        #expect(store.demo == nil)
        #expect(store.active == home)
        #expect(store.connections == [home])
        store.activeConnectionID = GatewayConnection.demoID
        store.activeConnectionID = home.id
        #expect(store.demo == nil)
        #expect(store.active == home)
        #expect(d.string(forKey: "activeConnectionID") == home.id.uuidString)
    }

    // MARK: The socket over a pipe of its own

    /// A gateway inside the test: says it is ready when the pipe opens, answers every call, and
    /// can close the pipe with a code, as a gateway on the network would close its socket.
    final class LocalPipe: GatewayFramePipe, @unchecked Sendable {
        private let lock = NSLock()
        private var inbox: [String] = []
        private var waiting: CheckedContinuation<String, Error>?
        private var closed: (code: Int, reason: String)?
        private(set) var sent: [String] = []
        let rejectWith: Int?

        init(rejectWith: Int? = nil) { self.rejectWith = rejectWith }

        func resume() {
            if let rejectWith { shut(code: rejectWith, reason: "refused"); return }
            push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","session_id":"","payload":{}}}"#)
        }

        func send(_ text: String) async throws {
            lock.withLock { sent.append(text) }
            guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? Int else { return }
            push(#"{"jsonrpc":"2.0","id":\#(id),"result":{"ok":true,"method":"\#(obj["method"] as? String ?? "")"}}"#)
        }

        func receive() async throws -> String {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if !inbox.isEmpty { let t = inbox.removeFirst(); lock.unlock(); c.resume(returning: t); return }
                if closed != nil { lock.unlock(); c.resume(throwing: URLError(.networkConnectionLost)); return }
                waiting = c
                lock.unlock()
            }
        }

        func close() { shut(code: 1001, reason: "") }

        var closeInfo: (code: Int, reason: String) { lock.withLock { closed ?? (0, "") } }

        private func push(_ text: String) {
            lock.lock()
            if let w = waiting { waiting = nil; lock.unlock(); w.resume(returning: text); return }
            inbox.append(text)
            lock.unlock()
        }

        func shut(code: Int, reason: String) {
            lock.lock()
            closed = closed ?? (code, reason)
            let w = waiting; waiting = nil
            lock.unlock()
            w?.resume(throwing: URLError(.networkConnectionLost))
        }
    }

    @Test func aSocketRunsOverAPipeOfItsOwn() async throws {
        let pipe = LocalPipe()
        let socket = GatewaySocket(urlProvider: { (URL(string: "ws://demo.invalid/api/ws")!, [:]) },
                                   onEvent: { _ in }, onState: { _ in }, onServerRequest: { _ in nil }, onReconnected: {},
                                   makePipe: { _ in pipe })
        await socket.connect()
        try await socket.waitUntilReady(timeout: 5)
        let answer = try await socket.call("session.list", timeout: 5)
        #expect(answer["ok"]?.boolValue == true)
        #expect(answer["method"]?.stringValue == "session.list")
        await socket.disconnect()
    }

    @Test func aPipeClosedWith4401BeforeReadyIsAnAuthRejection() async throws {
        let states = StateLog()
        let socket = GatewaySocket(urlProvider: { (URL(string: "ws://demo.invalid/api/ws")!, [:]) },
                                   onEvent: { _ in }, onState: { s in states.add(s) }, onServerRequest: { _ in nil }, onReconnected: {},
                                   makePipe: { _ in LocalPipe(rejectWith: 4401) })
        await socket.connect()
        for _ in 0..<50 where !states.sawAuthRejected { try await Task.sleep(for: .milliseconds(20)) }
        #expect(states.sawAuthRejected)
        await socket.disconnect()
    }

    final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [SocketState] = []
        func add(_ s: SocketState) { lock.withLock { states.append(s) } }
        var sawAuthRejected: Bool { lock.withLock { states.contains { if case .authRejected = $0 { return true }; return false } } }
    }
}
