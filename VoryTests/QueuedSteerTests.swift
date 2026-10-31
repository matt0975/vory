import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// A queued message steered into the running turn (#546): it leaves the queue before the steer goes out, so the turn's
/// end can't send it too; a failed steer, or one the gateway doesn't take ("rejected"), puts it back where it was; and
/// when the turn ends while the steer is out, the message is sent once, whichever way the gateway answers.
@MainActor @Suite struct QueuedSteerTests {
    private func chat() throws -> ChatSession {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        return ChatSession(runtime: rt, storedID: "s1", title: nil)
    }

    private func turnEnds(_ c: ChatSession) {
        c.handle(event: GatewayEvent(type: "message.complete", sessionID: c.runtimeID, payload: .object(["status": .string("complete")])))
    }

    /// The queue's own send (a task) has its moment.
    private func settle() async { for _ in 0..<50 { await Task.yield() } }

    private func submitted(_ calls: [(String, [String: JSONValue])]) -> [String] {
        calls.filter { $0.0 == "prompt.submit" }.compactMap { $0.1["text"]?.stringValue }
    }

    @Test func aSteerTakesItOffTheQueueAndSendsItIntoTheTurn() async throws {
        let c = try chat()
        c.isRunning = true
        c.queue = [QueuedMessage(text: "first"), QueuedMessage(text: "second")]
        var calls: [(String, [String: JSONValue])] = []
        c.gatewayStandIn = { m, p in calls.append((m, p)); return .object(["status": .string("delivered")]) }
        await c.steerQueued(c.queue[0].id)
        #expect(calls.map(\.0) == ["session.steer"])
        #expect(calls.first?.1["text"]?.stringValue == "first")
        #expect(c.queue.map(\.text) == ["second"])
        guard case .steer(let text, let status)? = c.items.last?.kind else { Issue.record("no steer row"); return }
        #expect(text == "first" && status == "delivered")
    }

    @Test func aFailedSteerPutsItBackWhereItWasAndSaysSo() async throws {
        let c = try chat()
        c.isRunning = true
        c.queue = [QueuedMessage(text: "a"), QueuedMessage(text: "b"), QueuedMessage(text: "c")]
        c.gatewayStandIn = { _, _ in throw SocketError.timeout("session.steer") }
        await c.steerQueued(c.queue[1].id)
        #expect(c.queue.map(\.text) == ["a", "b", "c"])
        #expect(c.banner != nil)
    }

    @Test func noSteerWithoutATurn() async throws {
        let c = try chat()
        c.queue = [QueuedMessage(text: "a")]
        var calls = 0
        c.gatewayStandIn = { _, _ in calls += 1; return .object([:]) }
        await c.steerQueued(c.queue[0].id)
        #expect(calls == 0)
        #expect(c.queue.map(\.text) == ["a"])
    }

    /// The race: the turn ends (its queue drained, without this message) while the steer is out, and the gateway refuses
    /// the steer. The message goes back and out as the next message, once.
    @Test func theTurnEndsWhileTheSteerIsOutAndItIsRefused() async throws {
        let c = try chat()
        c.isRunning = true
        c.queue = [QueuedMessage(text: "late")]
        var calls: [(String, [String: JSONValue])] = []
        c.gatewayStandIn = { m, p in
            calls.append((m, p))
            if m == "session.steer" { turnEnds(c); throw SocketError.timeout("session.steer") }
            return .object(["status": .string("started")])
        }
        await c.steerQueued(c.queue[0].id)
        await settle()
        #expect(submitted(calls) == ["late"])
        #expect(calls.filter { $0.0 == "session.steer" }.count == 1)
        #expect(c.queue.isEmpty)
        #expect(c.banner == nil)
    }

    /// The race as the gateway answers it once its turn has ended: "rejected" (a reply, not an error), for the client to
    /// send it as its next prompt (tui_gateway's session.steer). It goes back and out once, with no steer row.
    @Test func theTurnEndsWhileTheSteerIsOutAndTheGatewayRejectsIt() async throws {
        let c = try chat()
        c.isRunning = true
        c.queue = [QueuedMessage(text: "late")]
        var calls: [(String, [String: JSONValue])] = []
        c.gatewayStandIn = { m, p in
            calls.append((m, p))
            if m == "session.steer" { turnEnds(c); return .object(["status": .string("rejected"), "text": .string("late")]) }
            return .object(["status": .string("started")])
        }
        await c.steerQueued(c.queue[0].id)
        await settle()
        #expect(submitted(calls) == ["late"])
        #expect(c.queue.isEmpty)
        #expect(!c.items.contains { if case .steer = $0.kind { true } else { false } })
    }

    /// "rejected" while the turn still runs here (its end not yet arrived): back where it was, sent at the turn's end.
    @Test func aRejectedSteerWhileTheTurnRunsStaysQueued() async throws {
        let c = try chat()
        c.isRunning = true
        c.queue = [QueuedMessage(text: "a"), QueuedMessage(text: "b")]
        var calls: [(String, [String: JSONValue])] = []
        c.gatewayStandIn = { m, p in calls.append((m, p)); return .object(["status": .string("rejected")]) }
        await c.steerQueued(c.queue[1].id)
        await settle()
        #expect(c.queue.map(\.text) == ["a", "b"])
        #expect(submitted(calls).isEmpty)
        #expect(c.banner == nil)
        #expect(!c.items.contains { if case .steer = $0.kind { true } else { false } })
    }

    /// The same race with the steer taken ("queued": the gateway queues it itself while it compresses, as it does): it
    /// went once, as a steer, and the turn's end didn't send it again.
    @Test func theTurnEndsWhileTheSteerIsOutAndItIsTaken() async throws {
        let c = try chat()
        c.isRunning = true
        c.queue = [QueuedMessage(text: "late")]
        var calls: [(String, [String: JSONValue])] = []
        c.gatewayStandIn = { m, p in
            calls.append((m, p))
            if m == "session.steer" { turnEnds(c); return .object(["status": .string("queued")]) }
            return .object(["status": .string("started")])
        }
        await c.steerQueued(c.queue[0].id)
        await settle()
        #expect(submitted(calls).isEmpty)
        #expect(calls.map(\.0) == ["session.steer"])
        #expect(c.queue.isEmpty)
    }
}
