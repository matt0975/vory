import Testing
@testable import VoryCore

/// A scheduled task whose wake-gate skipped the agent leaves an empty cron session behind; the
/// chat lists leave it out, and keep every cron run that said something.
struct SkippedCronRunTests {
    @Test func anEmptyCronSessionIsNotAChat() {
        let list = SessionListResponse(sessions: [
            StoredSession(id: "gated", source: "cron", model: "gpt-5", messageCount: 0),
            StoredSession(id: "ran", title: "Inbox", source: "cron", messageCount: 4),
            StoredSession(id: "fresh", source: "ios", messageCount: 0),
            StoredSession(id: "older", source: "cron"),
        ])
        #expect(list.sessions[0].isSkippedCronRun)
        #expect(list.chats.map(\.id) == ["ran", "fresh", "older"], "only the cron fire with no messages goes")
    }
}
