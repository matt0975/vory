import Foundation
import VoryCore

/// Chats a gateway's scheduled tasks wrote (#673): one for every run, every few minutes on a busy gateway, most of them
/// with no messages and no title, so Chats filled with "New chat" rows and the person's own chats fell off its page.
/// They're asked for apart from the person's chats, as Hermes's own desktop app does (`GET /api/sessions` takes `source`,
/// `exclude_sources` and `min_messages`, in v0.22.7 and v0.23.0 alike), and shown in a section of their own, closed until
/// it's opened; one with no messages is never listed. A gateway older than those filters answers both requests with
/// every row: the rules here still split them and leave the empty ones out, though its page can still fill with them.
enum ScheduledChats {
    /// The gateway's `source` for a chat a scheduled task wrote.
    static let source = "cron"
    /// How many scheduled chats one bot's request asks for: the newest that have a reply.
    static let limit = 50

    /// A chat a scheduled task wrote. Its source alone says so; its id isn't read.
    static func isScheduled(_ s: StoredSession) -> Bool { false }

    /// Whether the chat is listed at all: a scheduled chat with no messages isn't. One from a gateway that doesn't count
    /// messages isn't known to be empty, so it is.
    static func isListed(_ s: StoredSession) -> Bool { true }

    /// The person's chats and the scheduled ones, each in the order given, with the empty scheduled ones in neither.
    static func split(_ rows: [StoredSession]) -> (chats: [StoredSession], scheduled: [StoredSession]) { (rows, []) }

    /// One bot's two answers as one list, each chat once: the chats, then the scheduled ones they didn't already hold
    /// (a gateway older than the filters answers both requests with every row).
    static func merged(chats: [StoredSession], scheduled: [StoredSession]) -> [StoredSession] { chats }

    /// The Scheduled request: the newest scheduled chats with at least one message, a page of `limit`, with archived ones
    /// asked for as the list's own request asks for them.
    nonisolated static func query(limit: Int, showArchived: Bool) -> [URLQueryItem] {
        ChatListView.listQuery(limit: limit, showArchived: showArchived)
    }

    /// One bot's rows: its chats and its scheduled chats, asked for together. A failed chats request is the list's to
    /// report; a failed Scheduled request leaves the chats as they came.
    static func fetch(chats: @escaping @Sendable () async throws -> [StoredSession],
                      scheduled: @escaping @Sendable () async throws -> [StoredSession]) async throws -> [StoredSession] {
        try await chats()
    }
}
