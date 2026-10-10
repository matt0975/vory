import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Coming back to a long turn that ran on while the app was away (testers on 1.3 found the app
/// frozen and then gone): the socket's events reach the chat in batches with each run of reply
/// text made one piece, a snapshot's history is made into rows off the main actor while the
/// events that arrive meanwhile wait their turn, and the transcript cache is written off the
/// main thread.
@MainActor @Suite struct LongTurnReturnTests {
    private func chat() throws -> ChatSession {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        return ChatSession(runtime: rt, storedID: nil, title: nil)
    }

    private func event(_ type: String, _ session: String = "s1", payload: [String: JSONValue] = [:], seq: Int? = nil) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: session, payload: .object(payload), seq: seq)
    }

    private func text(_ e: GatewayEvent) -> String? { e.payload["text"]?.stringValue }

    // MARK: Coalescing

    @Test func aRunOfReplyTextBecomesOnePieceInOrder() {
        let events = [event("message.start"),
                      event("message.delta", payload: ["text": "Hel"], seq: 1),
                      event("message.delta", payload: ["text": "lo, "], seq: 2),
                      event("message.delta", payload: ["text": "world"], seq: 3),
                      event("tool.start", payload: ["tool_id": "t1", "name": "terminal"]),
                      event("message.delta", payload: ["text": "after"], seq: 5)]
        let out = GatewayEvent.coalescingText(events)
        #expect(out.map(\.type) == ["message.start", "message.delta", "tool.start", "message.delta"])
        #expect(text(out[1]) == "Hello, world")
        #expect(out[1].seq == 3)
        #expect(text(out[3]) == "after")
    }

    @Test func runsDoNotCrossSessionsOrKinds() {
        let events = [event("message.delta", "a", payload: ["text": "1"]),
                      event("message.delta", "b", payload: ["text": "2"]),
                      event("message.delta", "b", payload: ["text": "3"]),
                      event("reasoning.delta", "b", payload: ["text": "r1"]),
                      event("reasoning.delta", "b", payload: ["text": "r2"]),
                      event("message.delta", "a", payload: ["text": "4"])]
        let out = GatewayEvent.coalescingText(events)
        #expect(out.map(\.sessionID) == ["a", "b", "b", "a"])
        #expect(out.map(\.type) == ["message.delta", "message.delta", "reasoning.delta", "message.delta"])
        #expect(out.compactMap(text) == ["1", "23", "r1r2", "4"])
    }

    @Test func otherFieldsOfTheFirstPieceAreKept() {
        let out = GatewayEvent.coalescingText([event("message.delta", payload: ["text": "a", "kind": "x"]), event("message.delta", payload: ["text": "b"])])
        #expect(out.count == 1)
        #expect(out[0].payload["kind"]?.stringValue == "x")
        #expect(text(out[0]) == "ab")
    }

    @Test func oneListRefreshOfEachKindPerBatch() {
        let events = [event("sessions.changed", ""), event("message.delta", payload: ["text": "a"]), event("sessions.changed", ""),
                      event("projects.changed", ""), event("tool.start", payload: ["tool_id": "t"]), event("sessions.changed", "")]
        let out = GatewayEvent.droppingRepeatedRefreshes(events)
        #expect(out.map(\.type) == ["message.delta", "projects.changed", "tool.start", "sessions.changed"])
        let none = [event("message.delta", payload: ["text": "a"])]
        #expect(GatewayEvent.droppingRepeatedRefreshes(none) == none)
    }

    @Test func aBatchTakenIsClosed() {
        let b = GatewayEventBatch()
        #expect(b.add(event("message.delta", payload: ["text": "a"])))
        #expect(b.add(event("message.delta", payload: ["text": "b"])))
        #expect(b.take().count == 2)
        #expect(!b.add(event("message.delta", payload: ["text": "c"])), "a batch the app has taken takes no more")
        #expect(b.take().isEmpty)
    }

    /// A thousand pieces of a reply, handled as the batch they arrived in, read the same as
    /// handled one by one.
    @Test func aCoalescedBatchStreamsTheSameReply() async throws {
        let one = try chat(), batched = try chat()
        let pieces = (0..<1000).map { "word\($0) " }
        let events = [event("message.start")] + pieces.map { event("message.delta", payload: ["text": .string($0)]) }
            + [event("message.complete", payload: ["text": .string(pieces.joined())])]
        for e in events { one.handle(event: e) }
        let merged = GatewayEvent.coalescingText(events)
        #expect(merged.count == 3)
        for e in merged { batched.handle(event: e) }
        func reply(_ c: ChatSession) -> String? {
            for item in c.items.reversed() { if case .assistant(let t, _, false) = item.kind { return t } }
            return nil
        }
        #expect(reply(one) == pieces.joined())
        #expect(reply(batched) == reply(one))
    }

    /// A short reply redraws about 25 times a second; a long one less often, at most four
    /// times a second, as each redraw costs more.
    @Test func longRepliesRedrawLessOften() {
        #expect(ChatSession.streamingInterval(utf8Count: 0) == .milliseconds(40))
        #expect(ChatSession.streamingInterval(utf8Count: 4_000) == .milliseconds(40))
        #expect(ChatSession.streamingInterval(utf8Count: 16_384) == .milliseconds(128))
        #expect(ChatSession.streamingInterval(utf8Count: 60_000) == .milliseconds(250))
        #expect(ChatSession.streamingInterval(utf8Count: 5_000_000) == .milliseconds(250))
    }

    /// Away from the app the streaming row is not redrawn; the text gathers and is drawn on
    /// the way back. A tool call in the meantime still seals what was said before it.
    @Test func awayTheReplyGathersAndIsDrawnOnTheWayBack() async throws {
        let c = try chat()
        c.runtime.isAway = true
        c.handle(event: event("message.start"))
        c.handle(event: event("message.delta", payload: ["text": "First part. "]))
        c.handle(event: event("tool.start", payload: ["tool_id": "t1", "name": "terminal"]))
        c.handle(event: event("message.delta", payload: ["text": "Second "]))
        c.handle(event: event("message.delta", payload: ["text": "part."]))
        try await Task.sleep(for: .milliseconds(200))
        func texts() -> [String] { c.items.compactMap { if case .assistant(let t, _, _) = $0.kind { return t }; return nil } }
        #expect(texts() == ["First part. ", ""], "the streaming row was redrawn while away")
        c.cameBack()
        #expect(texts() == ["First part. ", "Second part."])
        c.runtime.isAway = false
        c.handle(event: event("message.delta", payload: ["text": " More."]))
        // Back in front, the coalesced redraw resumes; under a loaded test run it can take a
        // few frames, so wait for it rather than for a fixed time.
        for _ in 0..<40 where texts().last != "Second part. More." { try await Task.sleep(for: .milliseconds(50)) }
        #expect(texts().last == "Second part. More.")
    }

    // MARK: Snapshots

    /// A long chat's snapshot: `count` exchanges, each a prompt, a tool call and a reply,
    /// with a turn running whose reply has started.
    private func snapshot(exchanges count: Int, inflight: String = "Part one") -> JSONValue {
        var messages: [JSONValue] = []
        let start = Date().timeIntervalSince1970 - Double(count) * 60
        for i in 0..<count {
            let t = start + Double(i) * 60
            messages.append(.object(["role": "user", "text": .string("Question \(i)"), "timestamp": .number(t), "row_id": .number(Double(i * 3 + 1))]))
            messages.append(.object(["role": "tool", "name": "terminal", "context": .string("ls /srv/\(i)"), "timestamp": .number(t + 5)]))
            messages.append(.object(["role": "assistant", "text": .string("Answer \(i): " + String(repeating: "lorem ipsum ", count: 30)),
                                     "timestamp": .number(t + 10), "row_id": .number(Double(i * 3 + 3))]))
        }
        let now = Date().timeIntervalSince1970
        return .object(["session_id": "s1", "stored_session_id": "stored-1", "running": true, "turn_started_at": .number(now - 5),
                        "messages": .array(messages),
                        "info": .object(["title": "A long chat", "running": true]),
                        "inflight": .object(["user": "Next question", "assistant": .string(inflight), "streaming": true])])
    }

    @Test func theSnapshotsRowsAreTheHistorysRows() throws {
        let r = snapshot(exchanges: 50)
        let rows = ChatSession.snapshotRows(r, running: true, shown: [], streamingID: nil)
        #expect(rows.built.count == 150)
        #expect(rows.paired.map(\.id) == rows.built.map(\.id))
        if case .user(let t, _) = rows.built[0].kind { #expect(t == "Question 0") } else { Issue.record("first row is not the prompt") }
        // Rows already shown keep their ids when the snapshot says the same thing.
        var shown = rows.built
        shown[0].id = "shown-first"
        let again = ChatSession.snapshotRows(r, running: true, shown: shown, streamingID: nil)
        #expect(again.paired[0].id == "shown-first")
    }

    @Test func aSnapshotAppliesWithTheTurnInFlight() async throws {
        let c = try chat()
        await c.apply(snapshot: snapshot(exchanges: 20))
        #expect(c.isRunning)
        #expect(c.title == "A long chat")
        // The history, the prompt in flight, and its reply streaming at the end.
        #expect(c.items.count == 62)
        guard case .assistant(let t, _, true) = c.items.last?.kind else { Issue.record("no streaming reply at the end"); return }
        #expect(t == "Part one")
        #expect(!c.isBuildingSnapshot)
    }

    /// Events that arrive while a snapshot's rows are being made are handled after it, in
    /// order: handled before it, the snapshot would have wiped them out.
    @Test func eventsDuringASnapshotComeAfterIt() async throws {
        let c = try chat()
        let big = snapshot(exchanges: 3000)
        let applying = Task { await c.apply(snapshot: big) }
        // Into the snapshot's off-main part.
        var tries = 0
        while !c.isBuildingSnapshot, tries < 200 { await Task.yield(); tries += 1 }
        try #require(c.isBuildingSnapshot, "the snapshot was made before an event could arrive")
        c.handle(event: event("tool.start", payload: ["tool_id": "t-late", "name": "terminal", "context": "uptime"]))
        c.handle(event: event("tool.complete", payload: ["tool_id": "t-late", "name": "terminal", "summary": "up 3 days"]))
        // Held, not yet in the thread.
        #expect(!c.items.contains { $0.id == "tool-t-late" })
        await applying.value
        #expect(!c.isBuildingSnapshot)
        guard let last = c.items.last, last.id == "tool-t-late", case .tool(let act) = last.kind else {
            Issue.record("the event that came during the snapshot is not the thread's last row"); return
        }
        #expect(act.status == .done)
        #expect(act.summary == "up 3 days")
        // The reply that was streaming when the snapshot was taken sits above the tool call.
        guard case .assistant(let t, _, _) = c.items[c.items.count - 2].kind else { Issue.record("the streaming reply is gone"); return }
        #expect(t == "Part one")
    }

    // MARK: Transcript cache

    @Test func theTranscriptCacheIsWrittenOffTheMainThreadAndReadsBack() throws {
        let conn = UUID()
        let items = (0..<300).map { TranscriptItem(id: "u\($0)", kind: .user(text: "line \($0)", attachments: [])) }
        TranscriptCache.save(items, connection: conn, storedID: "s-cache")
        TranscriptCache.flush()
        let back = try #require(TranscriptCache.load(connection: conn, storedID: "s-cache"))
        // The newest 200, as before.
        #expect(back.count == 200)
        #expect(back.first?.text == "line 100")
        #expect(back.last?.text == "line 299")
        if let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "transcripts/\(conn.uuidString)") {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

#if os(iOS)
/// A long turn starts a new reply after every tool call, and each new reply asks for a Live
/// Activity when none is up. Each ask is a synchronous call into the system on the main thread;
/// with the card refused, or the app in the background (where none can start), every reply
/// asked again until one call held the main thread past the watchdog. Now one ask, then none
/// for half a minute, except straight after coming back to the front.
@Suite struct LiveActivityAskTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func theFirstAskGoesOut() {
        #expect(LiveActivityController.shouldAsk(lastAskAt: nil, lastAskAway: false, awayNow: false, now: t0))
        #expect(LiveActivityController.shouldAsk(lastAskAt: nil, lastAskAway: false, awayNow: true, now: t0))
    }

    @Test func noAskAgainForHalfAMinuteAfterOneThatGotNothing() {
        #expect(!LiveActivityController.shouldAsk(lastAskAt: t0, lastAskAway: false, awayNow: false, now: t0.addingTimeInterval(1)))
        #expect(!LiveActivityController.shouldAsk(lastAskAt: t0, lastAskAway: true, awayNow: true, now: t0.addingTimeInterval(29)))
        #expect(LiveActivityController.shouldAsk(lastAskAt: t0, lastAskAway: false, awayNow: false, now: t0.addingTimeInterval(LiveActivityController.askAgainAfter + 1)))
    }

    @Test func backInFrontAsksAtOnce() {
        // Asked while away (where the system starts no card), and the app is in front now.
        #expect(LiveActivityController.shouldAsk(lastAskAt: t0, lastAskAway: true, awayNow: false, now: t0.addingTimeInterval(2)))
    }
}
#endif
