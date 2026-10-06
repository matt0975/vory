import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// What "Speak Last Reply" reads: the newest finished reply, never a streaming or empty one.
@Suite struct SpeakLastReplyTests {
    private func reply(_ id: String, _ t: String, streaming: Bool = false) -> TranscriptItem { TranscriptItem(id: id, kind: .assistant(text: t, reasoning: nil, streaming: streaming)) }
    private func user(_ id: String, _ t: String) -> TranscriptItem { TranscriptItem(id: id, kind: .user(text: t, attachments: [])) }

    @Test func theNewestFinishedReplyIsRead() {
        let items = [user("u1", "hi"), reply("a1", "First."), user("u2", "more"), reply("a2", "Second."), reply("a3", "", streaming: true)]
        #expect(VoiceCoordinator.lastReply(in: items) == "Second.")
        #expect(VoiceCoordinator.lastReply(in: [user("u1", "hi")]) == nil)
        #expect(VoiceCoordinator.lastReply(in: [reply("a1", "  \n")]) == nil)
        #expect(VoiceCoordinator.lastReply(in: []) == nil)
    }
}
