import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// A chat created here and not prompted yet has no stored row on the gateway; resuming its key
/// after a restart writes an empty one (Hermes #96793), listed as a chat of its own. A reconnect
/// drops it instead, and the first message creates it again.
@MainActor @Suite struct UnpromptedChatTests {
    private func chat() throws -> (ChatSession, () -> [String]) {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        let c = ChatSession(runtime: rt, storedID: nil, title: nil)
        var methods: [String] = []
        var created = 0
        c.gatewayStandIn = { method, params in
            methods.append(method)
            switch method {
            case "session.create":
                created += 1
                return .object(["session_id": .string("rt\(created)"), "stored_session_id": .string("20261025_21333\(created)_abcdef")])
            case "prompt.submit":
                #expect(params["session_id"]?.stringValue == "rt\(created)")
                return .object(["status": .string("started")])
            default:
                return .object([:])
            }
        }
        return (c, { methods })
    }

    @Test func aReconnectDoesNotResumeIt() async throws {
        let (c, methods) = try chat()
        try await c.create()
        await c.reattachAfterReconnect()
        #expect(!methods().contains("session.resume"))
        #expect(!c.stale)
        #expect(c.banner == nil)
    }

    @Test func theFirstMessageCreatesItAgain() async throws {
        let (c, methods) = try chat()
        try await c.create()
        await c.reattachAfterReconnect()
        #expect(await c.send("Hello") == nil)
        #expect(methods().filter { $0 == "session.create" }.count == 2)
        #expect(methods().last == "prompt.submit")
        #expect(c.runtimeID == "rt2")
        #expect(c.storedID == "20261025_213332_abcdef")
    }

    @Test func aPromptedChatIsResumedAsBefore() async throws {
        let (c, methods) = try chat()
        try await c.create()
        #expect(await c.send("Hello") == nil)
        await c.reattachAfterReconnect()
        #expect(methods().contains("session.resume"))
        #expect(methods().filter { $0 == "session.create" }.count == 1)
    }
}
