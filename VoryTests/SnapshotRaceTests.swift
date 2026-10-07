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
                          partial: String? = nil, open: [JSONValue] = [], pending: JSONValue? = nil) -> JSONValue {
        var messages: [JSONValue] = [
            .object(["role": "user", "text": "Check the disk", "timestamp": .number(turnStart - 100), "row_id": 1]),
            .object(["role": "assistant", "text": "It is full.", "timestamp": .number(turnStart - 90), "row_id": 2]),
        ]
        messages += flushed
        var r: [String: JSONValue] = ["session_id": .string(sid), "stored_session_id": "stored-1", "running": .bool(running),
                                      "messages": .array(messages), "info": .object(["title": "Disk", "running": .bool(running)]),
                                      "open_requests": .array(open)]
        if let pending { r["pending_approval"] = pending }
        if let prompt {
            r["turn_started_at"] = .number(turnStart)
            r["inflight"] = .object(["user": .string(prompt), "assistant": .string(partial ?? ""), "streaming": .bool(partial != nil)])
        }
        return .object(r)
    }

    /// The bot's question as a snapshot lists it (`open`), and for an approval as the gateway's
    /// approval queue has it too (`queued`).
    private func question(_ method: String) -> (open: JSONValue, queued: JSONValue?) {
        let approval = method == "approval"
        let params: JSONValue = approval
            ? .object(["session_id": "s1", "request_id": "ap-1", "command": "rm -rf /var/log/old", "description": "Delete the old logs"])
            : .object(["session_id": "s1", "question": "Delete the old logs?"])
        let queued: JSONValue? = approval ? .object(["request_id": "ap-1", "command": "rm -rf /var/log/old", "description": "Delete the old logs"]) : nil
        return (.object(["id": "req-1", "method": .string(method), "params": params]), queued)
    }

    @MainActor private final class Answer { var value: JSONValue? }

    /// What the chat told the platform: the cards that arrived and went, the turns that finished.
    @MainActor private final class Notes: CardNotifying {
        var arrived: [String] = []
        var settled: [String] = []
        var finished = 0
        func cardArrived(_ card: PendingCard, chat: ChatSession) { arrived.append(card.id) }
        func cardSettled(_ card: PendingCard, chat: ChatSession) { settled.append(card.id) }
        func turnFinished(chat: ChatSession, error: String?) { finished += 1 }
    }

    /// The chat's turn surface (the Live Activity) as the platform's acts: an update before it
    /// was started reaches nothing, and one just started says "Thinking…". `showing`: the card
    /// its words and its Approve are for. `asks`: the updates that asked for the person, each
    /// of which may alert away from the app (the Island expanding, the buzz); `showCards` never.
    @MainActor private final class Surface: TurnActivityReporting {
        private(set) var started = false
        private(set) var attention = false
        private(set) var showing: String?
        private(set) var asks = 0
        func start(for chat: ChatSession) { guard !started else { return }; started = true; attention = false; showing = nil }
        func update(for chat: ChatSession, attention: Bool, detail: String?) {
            guard started else { return }
            self.attention = attention
            showing = attention ? chat.firstCard?.id : nil
            if attention { asks += 1 }
        }
        func showCards(for chat: ChatSession) {
            guard started else { return }
            attention = !chat.cards.isEmpty
            showing = chat.firstCard?.id
        }
        func end(for chat: ChatSession, phase: String) { started = false; attention = false; showing = nil }
    }

    /// A runtime whose chats report to `surface`.
    private func runtime(surface: Surface) throws -> GatewayRuntime {
        let rt = try runtime()
        rt.activityReporterFactory = { surface }
        return rt
    }

    /// The gateway's side of a chat's calls (`ChatSession.gatewayStandIn`): each call is noted,
    /// one the test holds waits until the test answers it, and the rest fail as with no gateway.
    @MainActor private final class Calls {
        private let holding: Set<String>
        private var held: [String: [CheckedContinuation<JSONValue, Never>]] = [:]
        private(set) var made: [String] = []
        private(set) var answered: [String: Int] = [:]

        init(holding: Set<String> = []) { self.holding = holding }

        func call(_ method: String) async throws -> JSONValue {
            made.append(method)
            guard holding.contains(method) else { throw URLError(.cannotConnectToHost) }
            let value = await withCheckedContinuation { held[method, default: []].append($0) }
            answered[method, default: 0] += 1
            return value
        }

        func waiting(_ method: String) -> Int { held[method]?.count ?? 0 }
        func count(_ method: String) -> Int { made.filter { $0 == method }.count }

        /// The oldest call of `method` still waiting gets `value`.
        func answer(_ method: String, with value: JSONValue) {
            guard held[method]?.isEmpty == false else { return }
            held[method]?.removeFirst().resume(returning: value)
        }
    }

    /// Lets the chat's own tasks run until `done` holds (or a while has passed).
    private func until(_ done: () -> Bool) async {
        for _ in 0..<1000 where !done() { await Task.yield() }
    }

    /// How often the chat said a reply was finished (what voice, Siri and the watch wait for),
    /// counting only this reply: other tests post theirs meanwhile.
    @MainActor private final class Heard {
        var count = 0
        private var observer: NSObjectProtocol?
        init(_ reply: String) {
            observer = NotificationCenter.default.addObserver(forName: .hermesReplyCompleted, object: nil, queue: nil) { [weak self] n in
                guard n.userInfo?["storedID"] as? String == "stored-1", n.userInfo?["text"] as? String == reply else { return }
                MainActor.assumeIsolated { self?.count += 1 }
            }
        }
        func stop() { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    /// What the bot's request got back, or nil while it still waits (a request whose card was
    /// lost waits for good, so this does not wait on it).
    private func reply(to request: Task<JSONValue?, Never>) async -> JSONValue? {
        let got = Answer()
        Task { got.value = await request.value ?? .null }
        for _ in 0..<1000 where got.value == nil { await Task.yield() }
        return got.value
    }

    /// What the bot's request came to here: it still waits, it was let go with nothing sent to
    /// the gateway (the question stays open there), or it was answered. An answer of `.null`
    /// the gateway takes as answered: a clarify as cancelled, a password as skipped.
    private enum Outcome: Equatable { case waiting, letGo, answered(JSONValue) }
    @MainActor private final class Came { var outcome = Outcome.waiting }

    private func outcome(of request: Task<JSONValue?, Never>) async -> Outcome {
        let came = Came()
        Task { came.outcome = await request.value.map(Outcome.answered) ?? .letGo }
        for _ in 0..<1000 where came.outcome == .waiting { await Task.yield() }
        return came.outcome
    }

    /// The bot's question (`question`) as it comes on its own, a request to this device.
    private func request(_ method: String) -> ServerRequest {
        ServerRequest(id: "req-1", method: method, params: question(method).open["params"] ?? .object([:]))
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

    /// A card answered here while the rows are made stays answered. The snapshot was read
    /// before the answer, so it still lists the question (an approval in the approval queue
    /// too): put back, the chat asked for attention again and a second tap answered a request
    /// the bot had already closed.
    @Test(arguments: ["approval", "clarify"])
    func aCardAnsweredWhileTheSnapshotIsMadeStaysAnswered(method: String) async throws {
        let rt = try runtime()
        let notes = Notes()
        rt.cardNotifier = notes
        let gate = SnapshotBuildGate()
        let c = openChat(rt, gate: gate)
        let approval = method == "approval"
        let (open, queued) = question(method)
        // On screen from before the socket dropped.
        await gate.release(0)
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [open], pending: queued))
        #expect(c.cards.map(\.id) == ["req-1"])
        #expect(rt.needsAttention.contains("stored-1"))
        let card = try #require(c.cards.first)
        // The reattach's rows are being made, and the person answers meanwhile.
        let applying = Task { await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [open], pending: queued)) }
        await gate.begun(2)
        await c.respond(card: card, result: approval ? .object(["choice": "once"]) : .object(["answer": "yes"]))
        #expect(c.cards.isEmpty)
        await gate.release(1)
        await applying.value
        #expect(c.cards.isEmpty, "the answered card does not come back")
        #expect(!rt.needsAttention.contains("stored-1"), "and the chat does not ask for attention again")
        #expect(notes.arrived == ["req-1"], "nor is the card announced again")
        #expect(texts(c).filter { $0.hasPrefix("note: Approval") } == (approval ? ["note: Approval: once"] : []))
    }

    /// A card answered after the snapshot was asked for, before its reply came, stays answered.
    /// The gateway reads its open questions just before it answers, and the answer may reach
    /// it after that: taken as read when the reply came, the list put the card back.
    @Test(arguments: ["approval", "clarify"])
    func aCardAnsweredWhileTheSnapshotIsAskedForStaysAnswered(method: String) async throws {
        let rt = try runtime()
        let notes = Notes()
        rt.cardNotifier = notes
        let c = openChat(rt)
        let calls = Calls(holding: ["session.resume"])
        c.gatewayStandIn = { name, _ in try await calls.call(name) }
        let (open, queued) = question(method)
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [open], pending: queued))
        let card = try #require(c.cards.first)
        // The reattach goes out, and the person answers before its reply comes.
        let resuming = Task { try await c.resume() }
        await until { calls.waiting("session.resume") == 1 }
        try #require(calls.waiting("session.resume") == 1)
        await c.respond(card: card, result: method == "approval" ? .object(["choice": "once"]) : .object(["answer": "yes"]))
        calls.answer("session.resume", with: snapshot(running: true, prompt: "Free up space", open: [open], pending: queued))
        try await resuming.value
        #expect(c.cards.isEmpty, "the answered card does not come back")
        #expect(!rt.needsAttention.contains("stored-1"), "and the chat does not ask for attention again")
        #expect(notes.arrived == ["req-1"], "nor is the card announced again")
    }

    // MARK: Cards a newer snapshot lists again, or no longer

    /// A card the newer snapshot no longer lists (answered on another device, or its turn
    /// over) goes with the chat's call for attention and with what was posted for it, and a
    /// question's waiter here is let go with nothing sent. Before, the card went and the chat
    /// still said it needed you, and the notification still offered Approve.
    @Test(arguments: ["approval", "clarify"])
    func aCardTheNewerSnapshotNoLongerListsIsSettled(method: String) async throws {
        let rt = try runtime()
        let notes = Notes()
        rt.cardNotifier = notes
        let c = openChat(rt)
        var answering: Task<JSONValue?, Never>?
        if method == "approval" {
            let (open, queued) = question(method)
            await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [open], pending: queued))
        } else {
            let asked = ServerRequest(id: "req-1", method: "clarify", params: .object(["session_id": "s1", "question": "Delete the old logs?"]))
            answering = Task { await c.answer(serverRequest: asked) }
            await until { !c.cards.isEmpty }
        }
        try #require(c.cards.map(\.id) == ["req-1"])
        #expect(rt.needsAttention.contains("stored-1"))
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space"))
        #expect(c.cards.isEmpty)
        #expect(!rt.needsAttention.contains("stored-1"), "the chat no longer asks for attention")
        #expect(notes.settled == ["req-1"], "what was posted for the card comes down")
        if let answering { #expect(await outcome(of: answering) == .letGo, "the bot's request is let go, not answered") }
    }

    /// A question withdrawn (it timed out, the turn moved on) takes down what was posted for
    /// it, as one answered elsewhere does. Before, the card went and a withdrawn approval's
    /// notification still offered Approve, and the Live Activity still said it needed approval.
    @Test(arguments: ["approval", "clarify"])
    func aWithdrawnQuestionTakesDownWhatWasPostedForIt(method: String) async throws {
        let surface = Surface()
        let rt = try runtime(surface: surface)
        let notes = Notes()
        rt.cardNotifier = notes
        let c = openChat(rt)
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space"))
        let asking = Task { await c.answer(serverRequest: request(method)) }
        await until { !c.cards.isEmpty }
        try #require(surface.started && surface.attention)
        rt.handle(batch: [event("request.cancel", "s1", ["id": "req-1", "reason": "timeout"])])
        #expect(c.cards.isEmpty)
        #expect(notes.settled == ["req-1"], "what was posted for the card comes down")
        #expect(!surface.attention, "the activity no longer says it needs you")
        #expect(!rt.needsAttention.contains("stored-1"))
        #expect(await outcome(of: asking) == .answered(.null), "and the bot's request is let go")
    }

    /// Two cards up, and the one the Live Activity shows goes (answered here, withdrawn, or no
    /// longer on the gateway's list): the activity shows the other, its words and the request
    /// its Approve answers, with no alert. Before, it kept the card that went until the last
    /// one did: its Approve named a request no longer waiting, and a question was offered
    /// Approve or Deny.
    @Test(arguments: ["answered", "withdrawn", "noLongerListed"])
    func theActivityShowsTheCardNowFirstWhenTheOneItShowedGoes(how: String) async throws {
        let surface = Surface()
        let rt = try runtime(surface: surface)
        let c = openChat(rt)
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space"))
        let approving = Task { await c.answer(serverRequest: request("approval")) }
        await until { !c.cards.isEmpty }
        let clarify = ServerRequest(id: "req-2", method: "clarify", params: .object(["session_id": "s1", "question": "Keep the newest log?"]))
        let asking = Task { await c.answer(serverRequest: clarify) }
        await until { c.cards.count == 2 }
        try #require(surface.attention && surface.showing == "req-1")
        let asks = surface.asks
        switch how {
        case "answered":
            await c.respond(card: try #require(c.cards.first), result: .object(["choice": "once"]))
            #expect(await outcome(of: approving) == .answered(.object(["choice": "once"])))
        case "withdrawn":
            rt.handle(batch: [event("request.cancel", "s1", ["id": "req-1", "reason": "timeout"])])
            #expect(await outcome(of: approving) == .answered(.null))
        default:
            // A list read after both were asked has the question alone: the approval was
            // answered on another device. (Nothing running, so the snapshot itself does not
            // show the activity its cards.)
            let more: JSONValue = .object(["id": "req-2", "method": "clarify", "params": clarify.params])
            await c.apply(snapshot: snapshot(running: false, open: [more]))
            #expect(await outcome(of: approving) == .letGo)
        }
        #expect(c.cards.map(\.id) == ["req-2"])
        #expect(surface.attention && surface.showing == "req-2", "the activity shows the question now first")
        #expect(surface.asks == asks, "with no alert: it was announced when it came")
        rt.handle(batch: [event("request.cancel", "s1", ["id": "req-2", "reason": "timeout"])])
        #expect(!surface.attention && surface.showing == nil)
        #expect(await outcome(of: asking) == .answered(.null))
    }

    /// A chat re-read (`resume`) while its turn runs, and the bot asks `method` while the reply
    /// is on its way. The gateway read its open questions before the question was asked, so
    /// the reply does not list it.
    private func questionAskedWhileResuming(_ method: String, notes: Notes) async throws -> (chat: ChatSession, calls: Calls, asking: Task<JSONValue?, Never>) {
        let rt = try runtime()
        rt.cardNotifier = notes
        let c = openChat(rt)
        let calls = Calls(holding: ["session.resume"])
        c.gatewayStandIn = { name, _ in try await calls.call(name) }
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space"))
        let resuming = Task { try await c.resume() }
        await until { calls.waiting("session.resume") == 1 }
        try #require(calls.waiting("session.resume") == 1)
        let asking = Task { await c.answer(serverRequest: request(method)) }
        await until { !c.cards.isEmpty }
        try #require(c.cards.map(\.id) == ["req-1"])
        calls.answer("session.resume", with: snapshot(running: true, prompt: "Free up space"))
        try await resuming.value
        return (c, calls, asking)
    }

    /// A question asked after the snapshot was asked for, and not on its list, stays, and the
    /// bot still waits for its answer: the question may be newer than the list. Before, its
    /// card went and its waiter was answered with nothing, which the gateway took as answered:
    /// a clarify as cancelled, a password as skipped, and the person never saw the question.
    @Test(arguments: ["approval", "clarify", "sudo"])
    func aQuestionAskedAfterTheSnapshotWasAskedForStays(method: String) async throws {
        let notes = Notes()
        let (c, _, asking) = try await questionAskedWhileResuming(method, notes: notes)
        #expect(c.cards.map(\.id) == ["req-1"], "the question stays")
        #expect(c.runtime.needsAttention.contains("stored-1"))
        #expect(notes.arrived == ["req-1"] && notes.settled.isEmpty, "announced once, and nothing taken down")
        #expect(await outcome(of: asking) == .waiting, "the bot still waits for its answer")
        // And the answer reaches the bot.
        let answer: JSONValue = method == "approval" ? .object(["choice": "once"]) : .object(["answer": "yes"])
        await c.respond(card: try #require(c.cards.first), result: answer)
        #expect(await outcome(of: asking) == .answered(answer))
    }

    /// That question goes on a later list asked for after it came, which no longer has it
    /// (answered on another device). Its waiter here is let go with nothing sent: should the
    /// gateway still have the question after all, it stays open there.
    @Test(arguments: ["approval", "clarify"])
    func aQuestionAskedWhileResumingGoesOnALaterList(method: String) async throws {
        let notes = Notes()
        let (c, calls, asking) = try await questionAskedWhileResuming(method, notes: notes)
        try #require(c.cards.map(\.id) == ["req-1"])
        let again = Task { try await c.resume() }
        await until { calls.waiting("session.resume") == 1 }
        calls.answer("session.resume", with: snapshot(running: true, prompt: "Free up space"))
        try await again.value
        #expect(c.cards.isEmpty)
        #expect(!c.runtime.needsAttention.contains("stored-1"))
        #expect(notes.settled == ["req-1"], "what was posted for the card comes down")
        #expect(await outcome(of: asking) == .letGo, "let go, not answered")
    }

    /// Two re-reads overlap, and the one asked for before the question came is applied last,
    /// after the one that lists it: the question stays, and the bot still waits for its answer.
    @Test func aQuestionStaysWhenTheOlderSnapshotIsAppliedLast() async throws {
        let c = openChat(try runtime())
        let olderAskedFor = Date()
        let asking = Task { await c.answer(serverRequest: request("clarify")) }
        await until { !c.cards.isEmpty }
        let (open, _) = question("clarify")
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [open]), listedAt: Date())
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space"), listedAt: olderAskedFor)
        #expect(c.cards.map(\.id) == ["req-1"])
        #expect(await outcome(of: asking) == .waiting)
    }

    /// A card a newer snapshot lists again stays the card it was, announced once. Before, each
    /// snapshot put it back as new: another buzz or notification, and the gateway was told
    /// again that the approval arrived. A question new to the list is announced.
    @Test func aCardListedAgainIsAnnouncedOnce() async throws {
        let rt = try runtime()
        let notes = Notes()
        rt.cardNotifier = notes
        let c = openChat(rt)
        let calls = Calls()
        c.gatewayStandIn = { name, _ in try await calls.call(name) }
        let (open, _) = question("approval")
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [open]))
        await until { calls.count("approval.received") == 1 }
        // A reattach, then the return to the app: the approval still waits, and a question joins it.
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [open]))
        let more: JSONValue = .object(["id": "req-2", "method": "clarify", "params": .object(["session_id": "s1", "question": "Keep the newest log?"])])
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [open, more]))
        for _ in 0..<100 { await Task.yield() }
        #expect(c.cards.map(\.id) == ["req-1", "req-2"])
        #expect(notes.arrived == ["req-1", "req-2"])
        #expect(calls.count("approval.received") == 1, "the gateway hears once that the approval arrived")
        #expect(notes.settled.isEmpty)
        #expect(rt.needsAttention.contains("stored-1"))
    }

    /// A Live Activity the snapshot starts shows the card its turn waits on, whether the card
    /// came with the snapshot or was asked before the turn was known here, and with no alert:
    /// the card was announced when it came. Before, the card was announced while there was no
    /// activity yet, and the one started after it said "Thinking…" while the bot waited for an
    /// answer; and one taken over after a relaunch buzzed again for an approval it had shown.
    @Test(arguments: [false, true])
    func anActivityASnapshotStartsShowsTheCardItWaitsOn(askedBefore: Bool) async throws {
        let surface = Surface()
        let rt = try runtime(surface: surface)
        let c = openChat(rt)
        var asking: Task<JSONValue?, Never>?
        if askedBefore {
            await c.apply(snapshot: snapshot(running: false))
            asking = Task { await c.answer(serverRequest: request("approval")) }
            await until { !c.cards.isEmpty }
            try #require(!surface.started)
        }
        let (open, queued) = question("approval")
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [open], pending: queued))
        #expect(c.cards.map(\.id) == ["req-1"])
        #expect(surface.started)
        #expect(surface.attention && surface.showing == "req-1", "the activity says the turn waits on you")
        #expect(surface.asks == 0, "with no alert")
        // The return to the app re-reads the chat: the activity is shown the card again, still
        // with no alert.
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [open], pending: queued))
        #expect(surface.attention && surface.showing == "req-1")
        #expect(surface.asks == 0)
        if let asking {
            rt.handle(batch: [event("request.cancel", "s1", ["id": "req-1", "reason": "timeout"])])
            #expect(await outcome(of: asking) == .answered(.null))
        }
    }

    // MARK: Looks at the pending approvals

    /// Looks at the pending approvals overlap. One that went out before a card was answered
    /// here, and comes back after a newer look went out and a snapshot was applied, still has
    /// the card: it stays answered. Before, only the newest look was minded and the older one
    /// put the card back.
    @Test func anOlderLookAtThePendingApprovalsDoesNotBringBackAnAnsweredCard() async throws {
        let rt = try runtime()
        let notes = Notes()
        rt.cardNotifier = notes
        let c = openChat(rt)
        let calls = Calls(holding: ["approval.pending"])
        c.gatewayStandIn = { name, _ in try await calls.call(name) }
        let pending = try #require(question("approval").queued)
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", pending: pending))
        #expect(c.cards.map(\.id) == ["queue-ap-1"])
        // The look that follows the snapshot goes out, and the person answers while it is out.
        await until { calls.waiting("approval.pending") == 1 }
        try #require(calls.waiting("approval.pending") == 1)
        let card = try #require(c.cards.first)
        await c.respond(card: card, result: .object(["choice": "once"]))
        // A newer look goes out after the answer, and a snapshot read after it is applied.
        let newer = Task { await c.pollPendingApprovals() }
        await until { calls.waiting("approval.pending") == 2 }
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space"))
        await until { calls.waiting("approval.pending") == 3 }
        // The first look comes back last, read before the answer reached the gateway.
        calls.answer("approval.pending", with: .object(["approvals": .array([pending])]))
        await until { calls.answered["approval.pending"] == 1 }
        #expect(c.cards.isEmpty, "the answered card does not come back")
        #expect(!rt.needsAttention.contains("stored-1"))
        #expect(notes.arrived == ["queue-ap-1"])
        calls.answer("approval.pending", with: .object(["approvals": .array([])]))
        calls.answer("approval.pending", with: .object(["approvals": .array([])]))
        await newer.value
    }

    // MARK: One approval under two ids

    /// The gateway queues an approval a moment before it asks: a list read in between (here a
    /// snapshot's pending approval) puts the queue's card up, then the request itself comes. It
    /// takes the queue card's place, where that was and without being announced again, and an
    /// answer reaches the bot's request. Before, both stayed: two cards for one approval, and a
    /// tap on one left the other asking.
    @Test func theRequestTakesItsQueueCardsPlace() async throws {
        let rt = try runtime()
        let notes = Notes()
        rt.cardNotifier = notes
        let c = openChat(rt)
        let calls = Calls()
        c.gatewayStandIn = { name, _ in try await calls.call(name) }
        let (open, queued) = question("approval")
        let pending = try #require(queued)
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", pending: pending))
        let clarify = ServerRequest(id: "req-2", method: "clarify", params: .object(["session_id": "s1", "question": "Keep the newest log?"]))
        let other = Task { await c.answer(serverRequest: clarify) }
        await until { c.cards.count == 2 }
        try #require(c.cards.map(\.id) == ["queue-ap-1", "req-2"])
        let asking = Task { await c.answer(serverRequest: request("approval")) }
        await until { c.cards.first?.id == "req-1" }
        #expect(c.cards.map(\.id) == ["req-1", "req-2"], "one card for the approval, where the queue's was")
        #expect(notes.arrived == ["queue-ap-1", "req-2"], "not announced again")
        await until { calls.count("approval.received") == 1 }
        #expect(calls.count("approval.received") == 1, "the gateway hears that its request arrived")
        // A later list with the approval under both ids keeps the one card.
        let more: JSONValue = .object(["id": "req-2", "method": "clarify", "params": clarify.params])
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [open, more], pending: pending))
        #expect(c.cards.map(\.id) == ["req-1", "req-2"])
        #expect(notes.arrived == ["queue-ap-1", "req-2"] && notes.settled.isEmpty)
        await c.respond(card: try #require(c.cards.first), result: .object(["choice": "once"]))
        #expect(await outcome(of: asking) == .answered(.object(["choice": "once"])), "the bot's request has the answer")
        #expect(calls.count("approval.respond") == 0, "answered as the request, not again through the queue")
        #expect(c.cards.map(\.id) == ["req-2"])
        rt.handle(batch: [event("request.cancel", "s1", ["id": "req-2", "reason": "timeout"])])
        #expect(await outcome(of: other) == .answered(.null))
    }

    /// The other way round: the request's card is up, and a list read after it (the pending
    /// approvals, a snapshot's pending approval) adds no queue card for the same approval.
    @Test func noQueueCardJoinsTheRequestsOwn() async throws {
        let rt = try runtime()
        let notes = Notes()
        rt.cardNotifier = notes
        let c = openChat(rt)
        let calls = Calls(holding: ["approval.pending"])
        c.gatewayStandIn = { name, _ in try await calls.call(name) }
        let pending = try #require(question("approval").queued)
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space"))
        await until { calls.waiting("approval.pending") == 1 }
        try #require(calls.waiting("approval.pending") == 1)
        let asking = Task { await c.answer(serverRequest: request("approval")) }
        await until { !c.cards.isEmpty }
        calls.answer("approval.pending", with: .object(["approvals": .array([pending])]))
        await until { calls.answered["approval.pending"] == 1 }
        #expect(c.cards.map(\.id) == ["req-1"])
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", pending: pending))
        #expect(c.cards.map(\.id) == ["req-1"])
        #expect(notes.arrived == ["req-1"])
        await until { calls.waiting("approval.pending") == 1 }
        calls.answer("approval.pending", with: .object(["approvals": .array([pending])]))
        await until { calls.answered["approval.pending"] == 2 }
        #expect(c.cards.map(\.id) == ["req-1"])
        rt.handle(batch: [event("request.cancel", "s1", ["id": "req-1", "reason": "timeout"])])
        #expect(await outcome(of: asking) == .answered(.null))
    }

    /// The queue's card was taken before the request's own took its place (the watch was shown
    /// it, a confirmation was asked on it): the approval is still found by that id, and an
    /// answer given as the queue's card reaches the bot's request. Before, the watch got "no
    /// such card", and the answer took nothing down and went through the approval queue while
    /// the bot's request waited.
    @Test func anApprovalTakenAsTheQueuesCardIsAnsweredAsTheRequest() async throws {
        let rt = try runtime()
        let c = openChat(rt)
        let calls = Calls()
        c.gatewayStandIn = { name, _ in try await calls.call(name) }
        let pending = try #require(question("approval").queued)
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", pending: pending))
        let taken = try #require(c.cards.first)
        try #require(taken.id == "queue-ap-1")
        let asking = Task { await c.answer(serverRequest: request("approval")) }
        await until { c.cards.first?.id == "req-1" }
        try #require(c.cards.map(\.id) == ["req-1"])
        #expect(c.approvalCard(named: [taken.id])?.id == "req-1", "found by the id the watch was given")
        await c.respond(card: taken, result: .object(["choice": "once"]))
        #expect(await outcome(of: asking) == .answered(.object(["choice": "once"])), "the bot's request has the answer")
        #expect(calls.count("approval.respond") == 0, "not sent again through the queue")
        #expect(c.cards.isEmpty)
        #expect(!rt.needsAttention.contains("stored-1"))
    }

    // MARK: Approve or Deny from outside the chat

    /// Two approvals wait, the newer from the approval queue. Approve from the notification of
    /// either, this app's own (it names its card and its request) or the Companion's (its
    /// request alone), answers that one.
    @Test func approveFromANotificationIsForTheApprovalItWasPostedFor() async throws {
        let c = openChat(try runtime())
        let asking = Task { await c.answer(serverRequest: request("approval")) }
        await until { !c.cards.isEmpty }
        let (open, _) = question("approval")
        let newer: JSONValue = .object(["request_id": "ap-2", "command": "rm -rf /tmp/cache", "description": "Clear the cache"])
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [open], pending: newer))
        try #require(c.cards.map(\.id) == ["req-1", "queue-ap-2"])
        for card in c.cards {
            let tapped = try #require(PendingRoute(notification: LocalNotifier.userInfo(chat: c, kind: card.method, card: card)))
            #expect(await AppModel.approvalCard(for: tapped, in: c, wait: 0)?.id == card.id)
        }
        for (named, card) in [("ap-2", "queue-ap-2"), ("ap-1", "req-1"), ("queue-ap-1", "req-1")] {
            let pushed = try #require(PendingRoute(notification: ["hermes": ["session_id": "stored-1", "kind": "approval", "request_id": named]]))
            #expect(await AppModel.approvalCard(for: pushed, in: c, wait: 0)?.id == card)
        }
        c.runtime.handle(batch: [event("request.cancel", "s1", ["id": "req-1", "reason": "timeout"])])
        #expect(await outcome(of: asking) == .answered(.null))
    }

    /// Approve from a notification left from an approval that is gone (withdrawn, answered on
    /// another device) answers nothing, though a newer approval waits. Before, it answered the
    /// first approval shown, one nobody had read.
    @Test func approveFromANotificationOfAnApprovalThatIsGoneAnswersNothing() async throws {
        let c = openChat(try runtime())
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space"))
        let asking = Task { await c.answer(serverRequest: request("approval")) }
        await until { !c.cards.isEmpty }
        let answered = try #require(c.cards.first)
        let stale = LocalNotifier.userInfo(chat: c, kind: "approval", card: answered)
        c.runtime.handle(batch: [event("request.cancel", "s1", ["id": "req-1", "reason": "timeout"])])
        #expect(await outcome(of: asking) == .answered(.null))
        let newer = ServerRequest(id: "req-3", method: "approval",
                                  params: .object(["session_id": "s1", "request_id": "ap-3", "command": "rm -rf /tmp/cache", "description": "Clear the cache"]))
        let waiting = Task { await c.answer(serverRequest: newer) }
        await until { !c.cards.isEmpty }
        try #require(c.cards.map(\.id) == ["req-3"])
        let tapped = try #require(PendingRoute(notification: stale))
        #expect(await AppModel.approvalCard(for: tapped, in: c, wait: 0.3) == nil, "the approval it was for is gone")
        let pushed = try #require(PendingRoute(notification: ["hermes": ["session_id": "stored-1", "kind": "approval", "request_id": "ap-1"]]))
        #expect(await AppModel.approvalCard(for: pushed, in: c, wait: 0) == nil)
        #expect(await outcome(of: waiting) == .waiting, "the newer approval still waits for its own answer")
        c.runtime.handle(batch: [event("request.cancel", "s1", ["id": "req-3", "reason": "timeout"])])
        #expect(await outcome(of: waiting) == .answered(.null))
    }

    /// Approve tapped while the chat is still opening: the approval it names is looked for
    /// until it shows.
    @Test func approveFromANotificationWaitsForItsApprovalToShow() async throws {
        let c = openChat(try runtime())
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space"))
        let pushed = try #require(PendingRoute(notification: ["hermes": ["session_id": "stored-1", "kind": "approval", "request_id": "ap-1"]]))
        let finding = Task { await AppModel.approvalCard(for: pushed, in: c, wait: 5) }
        let asking = Task { await c.answer(serverRequest: request("approval")) }
        #expect(await finding.value?.id == "req-1")
        c.runtime.handle(batch: [event("request.cancel", "s1", ["id": "req-1", "reason": "timeout"])])
        #expect(await outcome(of: asking) == .answered(.null))
    }

    /// Approve from a notification that names no approval (one from an older build, a push
    /// without a usable id) answers the chat's approval when it has just one, as it did before
    /// approvals were named, and waits for it while the chat opens. With none or several it
    /// answers nothing, and the chat opens on its cards. One that names an approval is still
    /// for that one alone.
    @Test func approveThatNamesNoApprovalAnswersTheChatsOnlyOne() async throws {
        let c = openChat(try runtime())
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space"))
        let unnamed = try #require(PendingRoute(notification: ["hermes": ["session_id": "stored-1", "kind": "approval"]]))
        let blank = try #require(PendingRoute(notification: ["hermes": ["session_id": "stored-1", "kind": "approval", "request_id": ""]]))
        let clarify = ServerRequest(id: "req-2", method: "clarify", params: .object(["session_id": "s1", "question": "Keep the newest log?"]))
        let other = Task { await c.answer(serverRequest: clarify) }
        await until { !c.cards.isEmpty }
        #expect(await AppModel.approvalCard(for: unnamed, in: c, wait: 0) == nil, "a question is no approval")
        let finding = Task { await AppModel.approvalCard(for: unnamed, in: c, wait: 5) }
        let asking = Task { await c.answer(serverRequest: request("approval")) }
        #expect(await finding.value?.id == "req-1", "the one approval, once it shows")
        #expect(await AppModel.approvalCard(for: blank, in: c, wait: 0)?.id == "req-1")
        let gone = try #require(PendingRoute(notification: ["hermes": ["session_id": "stored-1", "kind": "approval", "request_id": "ap-0"]]))
        #expect(await AppModel.approvalCard(for: gone, in: c, wait: 0) == nil, "one named that is gone answers nothing, though one waits")
        // A second approval: which one was meant is unknown.
        let (open, _) = question("approval")
        let more: JSONValue = .object(["id": "req-2", "method": "clarify", "params": clarify.params])
        let newer: JSONValue = .object(["request_id": "ap-2", "command": "rm -rf /tmp/cache", "description": "Clear the cache"])
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [open, more], pending: newer))
        try #require(c.cards.map(\.id) == ["req-2", "req-1", "queue-ap-2"])
        #expect(await AppModel.approvalCard(for: unnamed, in: c, wait: 0) == nil, "two wait: nothing is answered")
        let named = try #require(PendingRoute(notification: ["hermes": ["session_id": "stored-1", "kind": "approval", "request_id": "ap-2"]]))
        #expect(await AppModel.approvalCard(for: named, in: c, wait: 0)?.id == "queue-ap-2")
        #expect(await outcome(of: asking) == .waiting)
        c.runtime.handle(batch: [event("request.cancel", "s1", ["id": "req-1", "reason": "timeout"]),
                                 event("request.cancel", "s1", ["id": "req-2", "reason": "timeout"])])
        #expect(await outcome(of: asking) == .answered(.null))
        #expect(await outcome(of: other) == .answered(.null))
    }

    #if os(iOS)
    /// The Live Activity's Approve names the approval it shows, and is for that one alone. One
    /// whose activity names none (the Companion updated it last) answers the chat's approval
    /// when it has just one, and nothing when it has several. Before, it answered nothing at
    /// all, and Approve on the Companion's activity only opened the app.
    @Test func theLiveActivitysApproveIsForTheApprovalItShows() async throws {
        let c = openChat(try runtime())
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space"))
        let asking = Task { await c.answer(serverRequest: request("approval")) }
        await until { !c.cards.isEmpty }
        let attributes = HermesTurnAttributes(sessionTitle: "Disk", storedSessionID: "stored-1", connectionID: "", profile: "default")
        var state = HermesTurnAttributes.ContentState(phase: "waiting", detail: "Delete the old logs", outputTokens: 0, contextPercent: nil, needsAttention: true)
        state.attentionRequest = "ap-1"
        let deny = try #require(PendingRoute(approvalURL: attributes.approvalURL(choice: "deny", state: state)))
        #expect(deny.action == LocalNotifier.denyAction && deny.storedSessionID == "stored-1")
        #expect(await AppModel.approvalCard(for: deny, in: c, wait: 0)?.id == "req-1")
        state.attentionRequest = "ap-0"
        #expect(await AppModel.approvalCard(for: try #require(PendingRoute(approvalURL: attributes.approvalURL(choice: "once", state: state))), in: c, wait: 0) == nil)
        state.attentionRequest = nil
        let unnamed = try #require(PendingRoute(approvalURL: attributes.approvalURL(choice: "once", state: state)))
        #expect(unnamed.action == LocalNotifier.approveOnceAction && unnamed.cardKeys.isEmpty)
        #expect(await AppModel.approvalCard(for: unnamed, in: c, wait: 0)?.id == "req-1", "the chat's one approval")
        let (open, _) = question("approval")
        let newer: JSONValue = .object(["request_id": "ap-2", "command": "rm -rf /tmp/cache", "description": "Clear the cache"])
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", open: [open], pending: newer))
        try #require(c.cards.map(\.id) == ["req-1", "queue-ap-2"])
        #expect(await AppModel.approvalCard(for: unnamed, in: c, wait: 0) == nil, "two wait: which one was meant is unknown")
        #expect(await AppModel.approvalCard(for: deny, in: c, wait: 0)?.id == "req-1", "one named is still answered")
        c.runtime.handle(batch: [event("request.cancel", "s1", ["id": "req-1", "reason": "timeout"])])
        #expect(await outcome(of: asking) == .answered(.null))
    }
    #endif

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

    /// The turn ends between the two replies. The newer snapshot shows its reply, and its end
    /// still does what a snapshot cannot: voice, Siri and the watch hear the reply, and the
    /// message queued behind the turn goes out. Before, both were lost with the reply's rows.
    @Test(arguments: [false, true])
    func aTurnThatEndedBeforeTheNewerSnapshotStillEndsHere(newerFinishesFirst: Bool) async throws {
        let rt = try runtime()
        let notes = Notes()
        rt.cardNotifier = notes
        let gate = SnapshotBuildGate()
        let c = openChat(rt, gate: gate)
        await gate.release(0)
        await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", partial: "Looking"))
        #expect(c.isRunning)
        // Typed while the turn runs: it waits for the turn to end.
        _ = await c.send("Then empty the trash")
        #expect(c.queue.map(\.text) == ["Then empty the trash"])
        let reply = "Looking around. Emptied the cache."
        let heard = Heard(reply)
        defer { heard.stop() }
        let first = Task { await c.apply(snapshot: snapshot(running: true, prompt: "Free up space", partial: "Looking around.")) }
        await gate.begun(2)
        rt.handle(batch: [event("message.complete", "s1", ["text": .string(reply), "status": "complete"])])
        // The second reply has the finished turn.
        let flushed: [JSONValue] = [
            .object(["role": "user", "text": "Free up space", "timestamp": .number(turnStart), "row_id": 3]),
            .object(["role": "assistant", "text": .string(reply), "timestamp": .number(turnStart + 5), "row_id": 4]),
        ]
        let second = Task { await c.apply(snapshot: snapshot(running: false, flushed: flushed)) }
        await gate.begun(3)
        if newerFinishesFirst {
            await gate.release(2)
            await second.value
            await gate.release(1)
            await first.value
        } else {
            await gate.release(1)
            await first.value
            await gate.release(2)
            await second.value
        }
        #expect(heard.count == 1, "the reply is heard once")
        #expect(notes.finished == 1)
        for _ in 0..<1000 where !texts(c).contains("user: Then empty the trash") { await Task.yield() }
        #expect(c.queue.isEmpty)
        #expect(texts(c) == ["user: Check the disk", "reply: It is full.", "user: Free up space", "reply: \(reply)",
                             "user: Then empty the trash"])
        #expect(c.isRunning, "the queued message is the next turn")
    }

    /// A question asked and withdrawn between the two replies: the newer snapshot no longer
    /// lists it, and the bot's request here is let go all the same (it waited for good).
    @Test func aQuestionWithdrawnBeforeTheNewerSnapshotLetsItsWaiterGo() async throws {
        let rt = try runtime()
        let gate = SnapshotBuildGate()
        let c = openChat(rt, gate: gate)
        let first = Task { await c.apply(snapshot: snapshot(running: true, prompt: "Free up space")) }
        await gate.begun(1)
        let asked = ServerRequest(id: "req-1", method: "clarify", params: .object(["session_id": "s1", "question": "Delete the old logs?"]))
        let answering = Task { await c.answer(serverRequest: asked) }
        for _ in 0..<1000 where c.cards.isEmpty { await Task.yield() }
        try #require(c.cards.map(\.id) == ["req-1"])
        rt.handle(batch: [event("request.cancel", "s1", ["id": "req-1", "reason": "timeout"])])
        let second = Task { await c.apply(snapshot: snapshot(running: true, prompt: "Free up space")) }
        await gate.begun(2)
        await gate.release(1)
        await second.value
        await gate.release(0)
        await first.value
        #expect(c.cards.isEmpty)
        #expect(await reply(to: answering) == .null, "the bot's request is let go")
    }

    /// A question asked after a re-read was asked for, and withdrawn before its reply while
    /// another re-read's rows are made. The reply leaves the card up (the question may be newer
    /// than its list), and the withdrawal, held meanwhile, takes it down. Before, a withdrawal
    /// that came before the reply was taken as shown by the snapshot: the card stayed and the
    /// bot's request waited here for good.
    @Test func aQuestionWithdrawnBeforeTheReplyOfASnapshotThatLeftItUpGoes() async throws {
        let rt = try runtime()
        let gate = SnapshotBuildGate()
        let c = openChat(rt, gate: gate)
        let calls = Calls(holding: ["session.resume"])
        c.gatewayStandIn = { name, _ in try await calls.call(name) }
        let first = Task { await c.apply(snapshot: snapshot(running: true, prompt: "Free up space")) }
        await gate.begun(1)
        let resuming = Task { try await c.resume() }
        await until { calls.waiting("session.resume") == 1 }
        try #require(calls.waiting("session.resume") == 1)
        let asking = Task { await c.answer(serverRequest: request("clarify")) }
        await until { !c.cards.isEmpty }
        rt.handle(batch: [event("request.cancel", "s1", ["id": "req-1", "reason": "timeout"])])
        #expect(c.cards.map(\.id) == ["req-1"], "held while the first rows are made")
        calls.answer("session.resume", with: snapshot(running: true, prompt: "Free up space"))
        await gate.begun(2)
        await gate.release(1)
        try await resuming.value
        #expect(c.cards.map(\.id) == ["req-1"], "the reply leaves it up")
        await gate.release(0)
        await first.value
        #expect(c.cards.isEmpty, "the withdrawal takes it down")
        #expect(!rt.needsAttention.contains("stored-1"))
        #expect(texts(c).last == "note: Request withdrawn (timeout).")
        #expect(await outcome(of: asking) != .waiting, "and the bot's request is let go")
    }

    /// Likewise a turn that ended (or failed) before that reply, which says nothing runs: the
    /// card the reply left up waited on that turn, and goes with it. Before, the turn's end,
    /// taken as shown by the snapshot, left the card up, and the chat said it needed you after
    /// the turn was over.
    @Test(arguments: ["message.complete", "error"])
    func aCardLeftUpByASnapshotGoesWithATurnThatEndedBeforeItsReply(end: String) async throws {
        let rt = try runtime()
        let notes = Notes()
        rt.cardNotifier = notes
        let gate = SnapshotBuildGate()
        let c = openChat(rt, gate: gate)
        let calls = Calls(holding: ["session.resume"])
        c.gatewayStandIn = { name, _ in try await calls.call(name) }
        let first = Task { await c.apply(snapshot: snapshot(running: true, prompt: "Free up space")) }
        await gate.begun(1)
        let resuming = Task { try await c.resume() }
        await until { calls.waiting("session.resume") == 1 }
        try #require(calls.waiting("session.resume") == 1)
        let asking = Task { await c.answer(serverRequest: request("approval")) }
        await until { !c.cards.isEmpty }
        let payload: [String: JSONValue] = end == "error" ? ["message": "The model is unavailable"] : ["text": "Stopped there.", "status": "complete"]
        rt.handle(batch: [event(end, "s1", payload)])
        calls.answer("session.resume", with: snapshot(running: false))
        await gate.begun(2)
        await gate.release(1)
        try await resuming.value
        #expect(c.cards.map(\.id) == ["req-1"], "the reply leaves it up; the turn's end is still held")
        await gate.release(0)
        await first.value
        #expect(c.cards.isEmpty, "the turn's end takes it down")
        #expect(!rt.needsAttention.contains("stored-1"))
        #expect(notes.settled == ["req-1"], "with what was posted for it")
        // The gateway's own word on the request lets its waiter here go.
        rt.handle(batch: [event("request.cancel", "s1", ["id": "req-1", "reason": "turn ended"])])
        #expect(await outcome(of: asking) == .answered(.null))
    }

    /// The turn ended before that reply, and the next turn asked a question after the end came,
    /// before the reply (the gateway read the snapshot between the two turns). The card up
    /// before the end goes with it; the new question stays, and its bot still waits for the
    /// answer. Before, the end took every card the reply left up, the next turn's with them.
    @Test func aQuestionAskedAfterTheTurnEndedStaysWhenASnapshotLeftItUp() async throws {
        let rt = try runtime()
        let notes = Notes()
        rt.cardNotifier = notes
        let gate = SnapshotBuildGate()
        let c = openChat(rt, gate: gate)
        let calls = Calls(holding: ["session.resume"])
        c.gatewayStandIn = { name, _ in try await calls.call(name) }
        let first = Task { await c.apply(snapshot: snapshot(running: true, prompt: "Free up space")) }
        await gate.begun(1)
        let resuming = Task { try await c.resume() }
        await until { calls.waiting("session.resume") == 1 }
        try #require(calls.waiting("session.resume") == 1)
        let approving = Task { await c.answer(serverRequest: request("approval")) }
        await until { !c.cards.isEmpty }
        rt.handle(batch: [event("message.complete", "s1", ["text": "Stopped there.", "status": "complete"])])
        // The next turn asks; a request to this device is never held.
        let clarify = ServerRequest(id: "req-2", method: "clarify", params: .object(["session_id": "s1", "question": "Keep the newest log?"]))
        let asking = Task { await c.answer(serverRequest: clarify) }
        await until { c.cards.count == 2 }
        calls.answer("session.resume", with: snapshot(running: false))
        await gate.begun(2)
        await gate.release(1)
        try await resuming.value
        #expect(c.cards.map(\.id) == ["req-1", "req-2"], "the reply leaves both up; the turn's end is still held")
        await gate.release(0)
        await first.value
        #expect(c.cards.map(\.id) == ["req-2"], "the end takes down the card up before it, and only that one")
        #expect(rt.needsAttention.contains("stored-1"))
        #expect(notes.settled == ["req-1"])
        #expect(await outcome(of: asking) == .waiting, "the bot still waits for the new question's answer")
        rt.handle(batch: [event("request.cancel", "s1", ["id": "req-1", "reason": "turn ended"]),
                          event("request.cancel", "s1", ["id": "req-2", "reason": "timeout"])])
        #expect(await outcome(of: approving) == .answered(.null))
        #expect(await outcome(of: asking) == .answered(.null))
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
