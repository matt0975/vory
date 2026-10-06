import Foundation
import Testing
@testable import VoryCore

/// Talk on the watch through its iPhone reads the reply from the chat's history: the bot's
/// words after what the person said.
@Suite struct WatchTalkReplyTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func theReplyIsWhatFollowsTheSpokenMessage() {
        let items = [
            TranscriptItem(id: "1", kind: .user(text: "earlier question", attachments: []), timestamp: at(-60)),
            TranscriptItem(id: "2", kind: .assistant(text: "earlier answer", reasoning: nil, streaming: false), timestamp: at(-50)),
            TranscriptItem(id: "3", kind: .user(text: "what's on today", attachments: []), timestamp: at(1)),
            TranscriptItem(id: "4", kind: .tool(ToolActivity(id: "t", name: "calendar", context: nil, status: .done)), timestamp: at(2)),
            TranscriptItem(id: "5", kind: .assistant(text: "Two meetings.", reasoning: nil, streaming: false), timestamp: at(3)),
            TranscriptItem(id: "6", kind: .assistant(text: "The first is at ten.", reasoning: nil, streaming: false), timestamp: at(4)),
        ]
        #expect(TranscriptItem.reply(in: items, to: " what's on today ", sentAt: at(0)) == "Two meetings.\n\nThe first is at ten.")
    }

    @Test func withoutTheSameTextTheReplyIsFoundByTime() {
        // The gateway may store the spoken words a little differently.
        let items = [
            TranscriptItem(id: "1", kind: .assistant(text: "old", reasoning: nil, streaming: false), timestamp: at(-120)),
            TranscriptItem(id: "2", kind: .user(text: "What's on today?", attachments: []), timestamp: at(1)),
            TranscriptItem(id: "3", kind: .assistant(text: "Two meetings.", reasoning: nil, streaming: false), timestamp: at(3)),
        ]
        #expect(TranscriptItem.reply(in: items, to: "whats on today", sentAt: at(0)) == "Two meetings.")
    }

    @Test func noReplyYetIsNil() {
        let items = [TranscriptItem(id: "1", kind: .user(text: "hello", attachments: []), timestamp: at(1))]
        #expect(TranscriptItem.reply(in: items, to: "hello", sentAt: at(0)) == nil)
        #expect(TranscriptItem.reply(in: [], to: "hello", sentAt: at(0)) == nil)
    }
}
