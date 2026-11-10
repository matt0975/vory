import Foundation
import Testing
import VoryCore
@testable import Vory

/// #673: on a gateway whose scheduled tasks run every few minutes, every run writes a chat, most with no messages and no
/// title, so Chats filled with "New chat" rows and the person's own chats fell off its page of 100. Scheduled chats are
/// asked for apart (Hermes's `exclude_sources` and `source`, `min_messages`), kept in a section of their own, never listed
/// when empty, and one with a reply reads as its own words.
struct ScheduledChatsTests {
    private struct Refused: Error {}

    private func row(_ id: String, source: String?, count: Int?, title: String? = nil, preview: String? = nil,
                     pinned: Bool = false) -> StoredSession {
        StoredSession(id: id, title: title, preview: preview, source: source, messageCount: count, pinned: pinned)
    }

    @Test func aScheduledChatIsOneTheGatewayMarksCron() {
        #expect(ScheduledChats.isScheduled(row("a", source: "cron", count: 2)))
        #expect(!ScheduledChats.isScheduled(row("b", source: "ios", count: 2)))
        #expect(!ScheduledChats.isScheduled(row("c", source: nil, count: 2)))
        #expect(!ScheduledChats.isScheduled(row("cron_digest_1", source: "tui", count: 2)), "the source decides, not the id")
    }

    @Test func anEmptyScheduledChatIsNeverListed() {
        #expect(!ScheduledChats.isListed(row("a", source: "cron", count: 0)))
        #expect(ScheduledChats.isListed(row("b", source: "cron", count: 3)))
        #expect(ScheduledChats.isListed(row("c", source: "cron", count: nil)), "a gateway that doesn't count: not known to be empty")
        #expect(ScheduledChats.isListed(row("d", source: "ios", count: 0)), "the person's own chat, just started, is listed")
    }

    @Test func theRowsSplitIntoChatsAndScheduledInTheirOrder() {
        let rows = [row("p", source: "ios", count: 4, pinned: true), row("c1", source: "cron", count: 0),
                    row("c2", source: "cron", count: 2, pinned: true), row("t", source: "tui", count: 6),
                    row("c3", source: "cron", count: 1), row("c4", source: "cron", count: 0), row("n", source: "ios", count: 0)]
        let (chats, scheduled) = ScheduledChats.split(rows)
        #expect(chats.map(\.id) == ["p", "t", "n"])
        #expect(scheduled.map(\.id) == ["c2", "c3"])
    }

    @Test func aScheduledChatReadsAsItsOwnWordsNeverNewChat() {
        #expect(row("a", source: "cron", count: 2, title: "Morning digest", preview: "Sum up the night").displayTitle == "Morning digest")
        #expect(row("b", source: "cron", count: 2, preview: "Check the backup log").displayTitle == "Check the backup log")
        #expect(row("c", source: "cron", count: 1).displayTitle == "Scheduled task")
        #expect(row("d", source: "cron", count: 1, title: "  ", preview: "").displayTitle == "Scheduled task")
        #expect(row("e", source: "ios", count: 0).displayTitle == "New chat", "the person's own chat, just started, keeps its words")
    }

    @Test func theChatsAreAskedForWithoutTheScheduledOnes() {
        for archived in [true, false] {
            let q = ChatListView.listQuery(limit: 100, showArchived: archived)
            #expect(q.first { $0.name == "exclude_sources" }?.value == "cron")
            #expect(!q.contains { $0.name == "source" || $0.name == "min_messages" })
        }
    }

    @Test func theScheduledAreAskedForApartAndOnlyWithAReply() {
        let q = ScheduledChats.query(limit: ScheduledChats.limit, showArchived: false)
        func value(_ name: String) -> String? { q.first { $0.name == name }?.value }
        #expect(value("source") == "cron")
        #expect(value("min_messages") == "1")
        #expect(value("order") == "recent")
        #expect(value("limit") == "50")
        #expect(value("archived") == "exclude")
        #expect(value("exclude_sources") == nil)
        #expect(ScheduledChats.query(limit: 50, showArchived: true).first { $0.name == "archived" }?.value == "include")
    }

    @Test func theTwoAnswersMakeOneListWithEachChatOnce() {
        let chat = row("a", source: "ios", count: 2), run = row("c", source: "cron", count: 1)
        #expect(ScheduledChats.merged(chats: [chat], scheduled: [run]).map(\.id) == ["a", "c"])
        // A gateway older than the filters answers both requests with every row.
        #expect(ScheduledChats.merged(chats: [chat, run], scheduled: [chat, run]).map(\.id) == ["a", "c"])
    }

    @Test func oneBotsRowsAreItsChatsAndItsScheduledChats() async throws {
        let chat = row("a", source: "ios", count: 2), run = row("c", source: "cron", count: 1)
        let rows = try await ScheduledChats.fetch(chats: { [chat] }, scheduled: { [run] })
        #expect(rows.map(\.id) == ["a", "c"])
    }

    @Test func aFailedScheduledRequestLeavesTheChats() async throws {
        let chat = row("a", source: "ios", count: 2)
        let rows = try await ScheduledChats.fetch(chats: { [chat] }, scheduled: { throw Refused() })
        #expect(rows.map(\.id) == ["a"])
    }

    @Test func aFailedChatsRequestIsTheLists() async {
        let run = row("c", source: "cron", count: 1)
        await #expect(throws: Refused.self) {
            _ = try await ScheduledChats.fetch(chats: { throw Refused() }, scheduled: { [run] })
        }
    }
}
