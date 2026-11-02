import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// #439: an old chat of a few thousand rows spent most of its main thread building the thread's rows, at every pass of
/// the thread's view (the thread scrolling, the status line, a card toggled), though its items had not changed. The
/// rows are kept by the chat's `itemsRevision`, the settings that pick them and the day; these tests hold the count to
/// every write to the items, which is what makes a kept row current.
@MainActor @Suite struct RowCacheTests {
    private func chat() throws -> ChatSession {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        let c = ChatSession(runtime: rt, storedID: nil, title: nil)
        rt.registry.add(c)
        return c
    }

    private func event(_ type: String, _ payload: [String: JSONValue] = [:]) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "s1", payload: .object(payload), seq: nil)
    }

    /// A turn as the gateway sends it: reasoning, two tool steps, a streamed reply, the end.
    private var turn: [GatewayEvent] {
        [event("message.start"),
         event("reasoning.delta", ["text": "Checking the disk first."]),
         event("tool.start", ["tool_id": "t1", "name": "terminal", "context": "df -h"]),
         event("tool.generating", ["tool_id": "t1", "name": "terminal"]),
         event("tool.complete", ["tool_id": "t1", "name": "terminal", "summary": "41% used", "result_text": "/dev/sda1 41%"]),
         event("tool.start", ["tool_id": "t2", "name": "terminal", "context": "du -sh /var"]),
         event("tool.complete", ["tool_id": "t2", "name": "terminal", "summary": "2.1G", "result_text": "2.1G /var"]),
         event("message.delta", ["text": "All "]),
         event("message.delta", ["text": "good."]),
         event("message.complete", ["text": "All good.", "status": "complete"])]
    }

    /// Plays `events` and checks that whenever the items came out different, the count did too.
    private func expectEveryChangeCounted(_ c: ChatSession, _ events: [GatewayEvent], _ note: String) {
        var changes = 0
        for e in events {
            let (items, count) = (c.items, c.itemsRevision)
            c.handle(event: e)
            guard c.items != items else { continue }
            changes += 1
            #expect(c.itemsRevision != count, "\(note): \(e.type) changed the items and not the count")
        }
        #expect(changes >= 5, "\(note): the turn changed the items only \(changes) times")
    }

    @Test func everyChangeToTheItemsChangesTheCount() throws {
        let c = try chat()
        expectEveryChangeCounted(c, turn, "in front")

        // Each way of writing them: a new array, an append, an item changed in place, a removal.
        var count = c.itemsRevision
        func changed(_ what: String) {
            #expect(c.itemsRevision != count, "\(what) left the count as it was")
            count = c.itemsRevision
        }
        c.items = c.items + [TranscriptItem(id: "n1", kind: .system(text: "Compacted", symbol: "archivebox"))]
        changed("a new array")
        c.items.append(TranscriptItem(id: "u2", kind: .user(text: "And memory?", attachments: [])))
        changed("an append")
        c.items[c.items.count - 1].kind = .user(text: "And the memory?", attachments: [])
        changed("an item changed in place")
        c.items.removeLast()
        changed("a removal")
        // An equal array tells nobody and keeps the rows.
        c.items = Array(c.items)
        #expect(c.itemsRevision == count, "an equal array moved the count")
    }

    /// Away the views are told nothing until the return (#371); the count still changes at once, so a pass of the
    /// thread meanwhile, or the one on the way back, never keeps rows from before.
    @Test func awayTheCountStillChangesWithEveryWrite() throws {
        let c = try chat()
        c.runtime.isAway = true
        expectEveryChangeCounted(c, turn, "away")
        c.runtime.isAway = false
    }

    /// Two chats in one thread view (it is handed another chat) never hold the same count after a write.
    @Test func noTwoChatsHoldTheSameCount() throws {
        let a = try chat(), b = try chat()
        var heldA = Set<Int>(), heldB = Set<Int>()
        for e in turn {
            a.handle(event: e); heldA.insert(a.itemsRevision)
            b.handle(event: e); heldB.insert(b.itemsRevision)
        }
        #expect(heldA.intersection(heldB).subtracting([0]).isEmpty, "the chats shared \(heldA.intersection(heldB).sorted())")
        #expect(a.itemsRevision > 0 && b.itemsRevision > 0)
    }

    @Test func theCacheBuildsAgainOnlyWhenItsKeyChanges() {
        let cache = RowCache()
        let day = Calendar.current.startOfDay(for: Date())
        let key = RowCache.Key(chat: ObjectIdentifier(cache), items: 7, showToolCalls: true, currentStepOnly: false,
                               showSystemNotes: true, showReasoning: true, day: day)
        let rows = TranscriptRowModel.build([TranscriptItem(id: "r1", kind: .assistant(text: "Hi.", reasoning: nil, streaming: false))], now: day)
        #expect(cache.rows(for: key) { rows } == rows)
        #expect(cache.rows(for: key) { [] } == rows, "a pass with nothing changed built the rows again")
        #expect(cache.builds == 1)

        var changes: [(String, RowCache.Key)] = []
        var k = key; k.items = 8; changes.append(("the items", k))
        k = key; k.chat = ObjectIdentifier(RowCache()); changes.append(("the chat", k))
        k = key; k.showToolCalls = false; changes.append(("tool calls shown", k))
        k = key; k.currentStepOnly = true; changes.append(("the current step only", k))
        k = key; k.showSystemNotes = false; changes.append(("notes shown", k))
        k = key; k.showReasoning = false; changes.append(("reasoning shown", k))
        k = key; k.day = Calendar.current.date(byAdding: .day, value: 1, to: day)!; changes.append(("the day", k))
        for (what, changed) in changes {
            let before = cache.builds
            _ = cache.rows(for: changed) { [] }
            #expect(cache.builds == before + 1, "a change of \(what) kept the rows")
        }
    }

    /// The older rows are the same array from pass to pass while the rows and the split hold, so `OlderRows`' `==`
    /// is Array's check of its own storage; a new split or new rows give a new array with the right rows.
    @Test func theOlderRowsAreOneArrayWhileNothingChanges() {
        let cache = RowCache()
        let day = Calendar.current.startOfDay(for: Date())
        let key = RowCache.Key(chat: ObjectIdentifier(cache), items: 1, showToolCalls: true, currentStepOnly: false,
                               showSystemNotes: true, showReasoning: true, day: day)
        let items = (0..<40).map { TranscriptItem(id: "r\($0)", kind: .assistant(text: "Reply \($0)", reasoning: nil, streaming: false)) }
        let rows = TranscriptRowModel.build(items, now: day)
        func storage(_ a: [TranscriptRowModel]) -> UnsafeRawPointer? { a.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) } }

        _ = cache.rows(for: key) { rows }
        let first = cache.older(than: 32)
        _ = cache.rows(for: key) { [] }
        let again = cache.older(than: 32)
        #expect(first == Array(rows[..<32]))
        #expect(storage(first) == storage(again), "a pass with nothing changed made a new array of the older rows")

        let moved = cache.older(than: 16)
        #expect(moved == Array(rows[..<16]))
        #expect(storage(moved) != storage(first))

        var next = key; next.items = 2
        let more = rows + [TranscriptRowModel(item: TranscriptItem(id: "u1", kind: .user(text: "Thanks", attachments: [])))]
        _ = cache.rows(for: next) { more }
        let rebuilt = cache.older(than: 16)
        #expect(rebuilt == Array(more[..<16]))
        #expect(storage(rebuilt) == storage(moved), "appending rows at the tail should preserve the older rows' array storage buffer pointer")

        // Modifying only the tail preserves the older array buffer pointer
        var nextModTail = next; nextModTail.items = 3
        var moreModTail = more
        moreModTail[moreModTail.count - 1].item.kind = .user(text: "Thanks!", attachments: [])
        _ = cache.rows(for: nextModTail) { moreModTail }
        let tailMod = cache.older(than: 16)
        #expect(storage(tailMod) == storage(moved), "modifying only tail rows preserves the older rows' storage buffer pointer")

        // Modifying an older row (within the split) invalidates the older array and allocates anew
        var nextModOlder = nextModTail; nextModOlder.items = 4
        var moreModOlder = moreModTail
        moreModOlder[0].item.kind = .assistant(text: "Edited prefix", reasoning: nil, streaming: false)
        _ = cache.rows(for: nextModOlder) { moreModOlder }
        let olderMod = cache.older(than: 16)
        #expect(storage(olderMod) != storage(moved), "modifying rows within the older split must allocate a new array")

        // Moving the split allocates a new array
        let wider = cache.older(than: 24)
        #expect(storage(wider) != storage(olderMod), "moving the split allocates a new array")

        // Switching chats invalidates older rows
        var otherChatKey = nextModOlder; otherChatKey.chat = ObjectIdentifier(RowCache())
        _ = cache.rows(for: otherChatKey) { moreModOlder }
        let otherChat = cache.older(than: 16)
        #expect(storage(otherChat) != storage(olderMod), "switching chats must invalidate the older rows' array")
    }
}
