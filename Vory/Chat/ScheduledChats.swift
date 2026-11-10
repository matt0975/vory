import SwiftUI
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
    /// The Scheduled section's row in the list, for a scroll to the top.
    static let rowID = "chats.scheduled"

    /// A chat a scheduled task wrote. Its source alone says so; its id isn't read.
    static func isScheduled(_ s: StoredSession) -> Bool { s.source == source }

    /// Whether the chat is listed at all: a scheduled chat with no messages isn't. One from a gateway that doesn't count
    /// messages isn't known to be empty, so it is.
    static func isListed(_ s: StoredSession) -> Bool { !(isScheduled(s) && s.messageCount == 0) }

    /// The person's chats and the scheduled ones, each in the order given, with the empty scheduled ones in neither.
    static func split(_ rows: [StoredSession]) -> (chats: [StoredSession], scheduled: [StoredSession]) {
        var chats: [StoredSession] = [], scheduled: [StoredSession] = []
        for s in rows where isListed(s) {
            if isScheduled(s) { scheduled.append(s) } else { chats.append(s) }
        }
        return (chats, scheduled)
    }

    /// One bot's two answers as one list, each chat once: the chats, then the scheduled ones they didn't already hold
    /// (a gateway older than the filters answers both requests with every row).
    static func merged(chats: [StoredSession], scheduled: [StoredSession]) -> [StoredSession] {
        var seen = Set(chats.map(\.id))
        return chats + scheduled.filter { seen.insert($0.id).inserted }
    }

    /// The Scheduled request: the newest scheduled chats with at least one message, a page of `limit`, with archived ones
    /// asked for as the list's own request asks for them.
    nonisolated static func query(limit: Int, showArchived: Bool) -> [URLQueryItem] {
        [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: String(limit)),
         URLQueryItem(name: "archived", value: showArchived ? "include" : "exclude"),
         URLQueryItem(name: "source", value: source), URLQueryItem(name: "min_messages", value: "1")]
    }

    /// One bot's rows: its chats and its scheduled chats, asked for together. A failed chats request is the list's to
    /// report; a failed Scheduled request leaves the chats as they came.
    static func fetch(chats: @escaping @Sendable () async throws -> [StoredSession],
                      scheduled: @escaping @Sendable () async throws -> [StoredSession]) async throws -> [StoredSession] {
        async let runs: [StoredSession]? = try? await scheduled()
        let own = try await chats()
        return merged(chats: own, scheduled: await runs ?? [])
    }
}

/// The Scheduled section's first row in Chats (#673), which opens and closes it: the timer Settings gives scheduled
/// tasks, how many chats it holds, and, as a project's header does, whether one of them is working or waiting, so a chat
/// that needs you shows while the section is closed. A row, not the section's header: the whole row takes the tap, and
/// a tap on the selected Chats tab can scroll the list up to it.
struct ScheduledSectionRow: View {
    var count: Int
    var open: Bool
    var working: Int
    var waiting: Int
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Image(systemName: "timer").foregroundStyle(.secondary).frame(width: 22)
                Text("Scheduled").font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if waiting > 0 {
                    Text(waiting == 1 ? "Needs you" : "\(waiting) need you").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.red.opacity(0.15), in: .capsule).foregroundStyle(.red)
                } else if working > 0 {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scheduled, \(count) \(count == 1 ? "chat" : "chats")\(working > 0 ? ", working" : "")\(waiting > 0 ? ", needs you" : "")")
        .accessibilityHint(open ? "Hides its chats" : "Shows its chats")
        .accessibilityIdentifier("chats.scheduled")
    }
}
