import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Holds each snapshot build of a chat until the test lets it go (builds are numbered from 0 in
/// the order they began), so what arrives while one runs is up to the test, not the clock.
actor SnapshotBuildGate {
    private var begun = 0
    private var released: Set<Int> = []
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [(count: Int, c: CheckedContinuation<Void, Never>)] = []

    /// For `ChatSession.beforeSnapshotRows`.
    nonisolated var step: @Sendable (JSONValue) async -> Void { { _ in await self.enter() } }

    private func enter() async {
        let n = begun
        begun += 1
        waiters.removeAll { w in
            guard begun >= w.count else { return false }
            w.c.resume(); return true
        }
        if released.contains(n) { return }
        await withCheckedContinuation { held[n] = $0 }
    }

    /// Returns once `count` builds are being held (or were let go).
    func begun(_ count: Int) async {
        if begun >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func release(_ n: Int) {
        released.insert(n)
        held.removeValue(forKey: n)?.resume()
    }
}

/// What reaches a chat while its snapshot's rows are being made off the main actor: the
/// events of the session it attaches to, a question the bot asks, a message sent here, and a
/// second snapshot of the same chat. Each used to be lost, wiped or doubled when the snapshot
/// was applied.
@MainActor @Suite struct SnapshotRaceTests {
    private func runtime() throws -> GatewayRuntime {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        return GatewayRuntime(connection: conn, store: ConnectionStore())
    }

    /// A chat the runtime routes events to, as `openChat` leaves it before its resume answers.
    private func openChat(_ rt: GatewayRuntime, gate: SnapshotBuildGate? = nil) -> ChatSession {
        let c = ChatSession(runtime: rt, storedID: "stored-1", title: nil)
        rt.registry.add(c)
        c.beforeSnapshotRows = gate?.step
        return c
    }

    private func event(_ type: String, _ session: String = "s1", _ payload: [String: JSONValue] = [:]) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: session, payload: .object(payload))
    }

    private let turnStart = Date().timeIntervalSince1970 - 30

    /// An exchange from before, then (`prompt`) a turn: its rows the gateway has already
    /// stored (`flushed`), and what it has in flight.
    private func snapshot(_ sid: String = "s1", running: Bool, prompt: String? = nil, flushed: [JSONValue] = [],
                          partial: String? = nil, open: [JSONValue] = []) -> JSONValue {
        var messages: [JSONValue] = [
            .object(["role": "user", "text": "Check the disk", "timestamp": .number(turnStart - 100), "row_id": 1]),
            .object(["role": "assistant", "text": "It is full.", "timestamp": .number(turnStart - 90), "row_id": 2]),
        ]
        messages += flushed
        var r: [String: JSONValue] = ["session_id": .string(sid), "stored_session_id": "stored-1", "running": .bool(running),
                                      "messages": .array(messages), "info": .object(["title": "Disk", "running": .bool(running)]),
                                      "open_requests": .array(open)]
        if let prompt {
            r["turn_started_at"] = .number(turnStart)
            r["inflight"] = .object(["user": .string(prompt), "assistant": .string(partial ?? ""), "streaming": .bool(partial != nil)])
        }
        return .object(r)
    }

    @MainActor private final class Answer { var value: JSONValue? }

    /// What the bot's request got back, or nil while it still waits (a request whose card was
    /// lost waits for good, so this does not wait on it).
    private func reply(to request: Task<JSONValue?, Never>) async -> JSONValue? {
        let got = Answer()
        Task { got.value = await request.value ?? .null }
        for _ in 0..<1000 where got.value == nil { await Task.yield() }
        return got.value
    }

    /// The streaming row is redrawn a moment after its text arrives; under a loaded test run
    /// that can take a few frames.
    private func waitForRedraw(_ c: ChatSession, last: String) async throws {
        for _ in 0..<60 where texts(c).last != last { try await Task.sleep(for: .milliseconds(50)) }
    }

    private func texts(_ c: ChatSession) -> [String] {
        c.items.map {
            switch $0.kind {
            case .user(let t, _): return "user: " + t
            case .assistant(let t, _, let streaming): return (streaming ? "streaming: " : "reply: ") + t
            case .tool(let a): return "tool: " + (a.context ?? a.name)
            case .error(let t): return "error: " + t
            case .system(let t, _): return "note: " + t
            default: return "other"
            }
        }
    }

    // MARK: Events for the session the chat attaches to

    /// A chat opened while its turn runs has no runtime id until `session.resume` answers. The
    /// turn's events are routed by that id, and they keep coming while the snapshot's rows are
    /// made: they reach the chat, wait, and the turn ends here when its reply does.
    @Test func aChatJustOpenedGetsItsTurnsEventsWhileItsSnapshotIsMade() async throws {
        let rt = try runtime()
        let gate = SnapshotBuildGate()
        let c = openChat(rt, gate: gate)
        #expect(c.runtimeID.isEmpty)
        let applying = Task { await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", partial: "Looking")) }
        await gate.begun(1)
        #expect(c.runtimeID == "s1", "the reply's id is the chat's before its rows are made")
        rt.handle(batch: [event("message.delta", "s1", ["text": " around."]),
                          event("tool.start", "s1", ["tool_id": "t1", "name": "terminal", "context": "du -sh /var"]),
                          event("tool.complete", "s1", ["tool_id": "t1", "name": "terminal", "summary": "12 GB"]),
                          event("message.delta", "s1", ["text": "Removed old logs."]),
                          event("message.complete", "s1", ["text": "Looking around.Removed old logs.", "status": "complete"])])
        #expect(!c.items.contains { $0.id == "tool-t1" }, "held until the snapshot is applied")
        await gate.release(0)
        await applying.value
        #expect(texts(c) == ["user: Check the disk", "reply: It is full.", "user: Free up space",
                             "reply: Looking around.", "tool: du -sh /var", "reply: Removed old logs."])
        guard let tool = c.items.first(where: { $0.id == "tool-t1" }), case .tool(let act) = tool.kind else {
            Issue.record("the tool call that came during the snapshot is missing"); return
        }
        #expect(act.status == .done)
        #expect(!c.isRunning, "the reply finished, so the turn is over here too")
    }

    /// A reattach whose reply names a new session id (the gateway restarted): the events
    /// stamped with it reach the chat while the rows are made.
    @Test func aNewSessionIDIsTheChatsBeforeItsRowsAreMade() async throws {
        let rt = try runtime()
        let gate = SnapshotBuildGate()
        let c = openChat(rt, gate: gate)
        await gate.release(0)
        await c.apply(snapshot: snapshot("s-old", running: false))
        #expect(c.runtimeID == "s-old")
        let applying = Task { await c.apply(snapshot: snapshot("s-new", running: true, prompt: "Free up space", partial: "")) }
        await gate.begun(2)
        #expect(c.runtimeID == "s-new")
        rt.handle(batch: [event("tool.start", "s-new", ["tool_id": "t9", "name": "terminal", "context": "df -h"])])
        await gate.release(1)
        await applying.value
        #expect(c.items.last?.id == "tool-t9")
        #expect(c.isRunning)
    }

    // MARK: Questions asked meanwhile

    /// A question the bot asks while the rows are made is newer than the snapshot's open
    /// requests: its card stays, and answering it still reaches the bot. A card only an older
    /// snapshot listed goes.
    @Test func aQuestionAskedWhileTheSnapshotIsMadeStays() async throws {
        let rt = try runtime()
        let gate = SnapshotBuildGate()
        let c = openChat(rt, gate: gate)
        let old: JSONValue = .object(["id": "req-old", "method": "clarify", "params": .object(["session_id": "s1", "question": "Which disk?"])])
        await gate.release(0)
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [old]))
        #expect(c.cards.map(\.id) == ["req-old"])
        // The reattach: the old question was answered elsewhere, so this snapshot lists none.
        let applying = Task { await c.apply(snapshot: snapshot(running: true, prompt: "Free up space")) }
        await gate.begun(2)
        let asked = ServerRequest(id: "req-new", method: "clarify", params: .object(["session_id": "s1", "question": "Delete the old logs?"]))
        let answering = Task { await c.answer(serverRequest: asked) }
        for _ in 0..<1000 where !c.cards.contains(where: { $0.id == "req-new" }) { await Task.yield() }
        try #require(c.cards.contains { $0.id == "req-new" })
        await gate.release(1)
        await applying.value
        #expect(c.cards.map(\.id) == ["req-new"])
        let card = try #require(c.cards.first)
        await c.respond(card: card, result: .object(["answer": "yes"]))
        let got = await reply(to: answering)
        #expect(got?["answer"]?.stringValue == "yes", "the bot gets the answer")
    }

    /// A request withdrawn while the rows are made (it timed out) is withdrawn after them too.
    @Test func aQuestionWithdrawnWhileTheSnapshotIsMadeGoes() async throws {
        let rt = try runtime()
        let gate = SnapshotBuildGate()
        let c = openChat(rt, gate: gate)
        let applying = Task { await c.apply(snapshot: snapshot(running: true, prompt: "Free up space")) }
        await gate.begun(1)
        let asked = ServerRequest(id: "req-1", method: "clarify", params: .object(["session_id": "s1", "question": "Delete the old logs?"]))
        let answering = Task { await c.answer(serverRequest: asked) }
        for _ in 0..<1000 where c.cards.isEmpty { await Task.yield() }
        rt.handle(batch: [event("request.cancel", "s1", ["id": "req-1", "reason": "timeout"])])
        await gate.release(0)
        await applying.value
        #expect(c.cards.isEmpty)
        #expect(await reply(to: answering) == .null, "the bot's request is let go")
    }

    // MARK: A second snapshot of the same chat

    /// Two re-reads of one chat in flight (a reconnect and the return to the app). The events
    /// between the two replies are in the second snapshot already; only those after it are
    /// handled on top of it, whichever build finishes first. Before, all of them were handled
    /// again: the tool call came twice and the reply's text doubled.
    @Test(arguments: [false, true])
    func overlappingSnapshotsShowEachEventOnce(newerFinishesFirst: Bool) async throws {
        let rt = try runtime()
        let gate = SnapshotBuildGate()
        let c = openChat(rt, gate: gate)
        let first = Task { await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", partial: "Looking")) }
        await gate.begun(1)
        // Between the two replies: the reply goes on and a tool starts.
        rt.handle(batch: [event("message.delta", "s1", ["text": " around."]),
                          event("tool.start", "s1", ["tool_id": "t1", "name": "terminal", "context": "du -sh /var"])])
        // The second reply has both: the gateway stored them.
        let flushed: [JSONValue] = [
            .object(["role": "user", "text": "Free up space", "timestamp": .number(turnStart), "row_id": 3]),
            .object(["role": "assistant", "text": "Looking around.", "timestamp": .number(turnStart + 1), "row_id": 4]),
            .object(["role": "tool", "name": "terminal", "context": "du -sh /var", "timestamp": .number(turnStart + 2), "row_id": 5]),
        ]
        let second = Task { await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", flushed: flushed)) }
        await gate.begun(2)
        // After the second reply.
        rt.handle(batch: [event("tool.start", "s1", ["tool_id": "t2", "name": "terminal", "context": "rm old logs"]),
                          event("message.delta", "s1", ["text": "Freed 12 GB."])])
        if newerFinishesFirst {
            await gate.release(1)
            await second.value
            #expect(c.isBuildingSnapshot, "the first is still being made")
            await gate.release(0)
            await first.value
        } else {
            await gate.release(0)
            await first.value
            await gate.release(1)
            await second.value
        }
        #expect(!c.isBuildingSnapshot)
        try await waitForRedraw(c, last: "streaming: Freed 12 GB.")
        #expect(texts(c) == ["user: Check the disk", "reply: It is full.", "user: Free up space", "reply: Looking around.",
                             "tool: du -sh /var", "tool: rm old logs", "streaming: Freed 12 GB."])
        #expect(!c.items.contains { $0.id == "tool-t1" }, "the tool call before the second reply is history's row, not a second one")
        #expect(Set(c.items.map(\.id)).count == c.items.count)
    }

    // MARK: A message sent meanwhile

    /// Sent while a reattach's rows are made: the snapshot was taken before it, so it stays,
    /// after the snapshot's rows, and the turn it started keeps running. The turn's first
    /// events, held meanwhile, put the reply under it.
    @Test func aMessageSentWhileTheSnapshotIsMadeStays() async throws {
        let rt = try runtime()
        let gate = SnapshotBuildGate()
        let c = openChat(rt, gate: gate)
        await gate.release(0)
        await c.apply(snapshot: snapshot(running: false))
        #expect(!c.isRunning)
        let applying = Task { await c.apply(snapshot: snapshot(running: false)) }
        await gate.begun(2)
        // The send waits on the gateway's answer, which never comes here; the row is up first.
        Task { await c.send("Free up space") }
        for _ in 0..<1000 where !texts(c).contains("user: Free up space") { await Task.yield() }
        try #require(texts(c).contains("user: Free up space"))
        #expect(c.isRunning)
        rt.handle(batch: [event("message.start", "s1"), event("message.delta", "s1", ["text": "On it."])])
        await gate.release(1)
        await applying.value
        try await waitForRedraw(c, last: "streaming: On it.")
        #expect(texts(c) == ["user: Check the disk", "reply: It is full.", "user: Free up space", "streaming: On it."])
        #expect(c.isRunning, "an older snapshot's idle does not end a turn sent since")
        #expect(Set(c.items.map(\.id)).count == c.items.count)
    }

    /// Rows the gateway put in while the rows were made (here an earlier snapshot of the same
    /// chat) are not taken for rows added here and kept twice.
    @Test func rowsAnotherSnapshotPutInAreNotKeptAsSentHere() async throws {
        let rt = try runtime()
        let gate = SnapshotBuildGate()
        let c = openChat(rt, gate: gate)
        let first = Task { await c.apply(snapshot: snapshot(running: false)) }
        await gate.begun(1)
        let second = Task { await c.apply(snapshot: snapshot(running: false)) }
        await gate.begun(2)
        await gate.release(0)
        await first.value
        #expect(texts(c) == ["user: Check the disk", "reply: It is full."])
        await gate.release(1)
        await second.value
        #expect(texts(c) == ["user: Check the disk", "reply: It is full."])
    }
}
