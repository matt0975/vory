import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// A bot's own Bot Chat (#653): one lookup for the "Messaged X" notice and the bot's page.
@MainActor
@Suite(.serialized) struct BotChatTests {
    private func runtime() async -> GatewayRuntime {
        let name = "dev.vory.tests.botchat." + UUID().uuidString
        let store = ConnectionStore(defaults: UserDefaults(suiteName: name)!, connections: [])
        let rt = GatewayRuntime(connection: .demo, store: store, transport: .demo(DemoGateway(pace: .quick)))
        await rt.start()
        return rt
    }

    /// The gateway's own answer wins: the canonical session's resolved id (the live tip), else its id.
    @Test func canonicalSessionNamesIt() {
        let reply: JSONValue = .object(["profiles": .array([
            .object(["name": .string("default"), "canonical_session": .null]),
            .object(["name": .string("work"), "canonical_session": .object(["id": .string("old"), "resolved_id": .string("tip"), "title": .string("Bot Chat")])]),
            .object(["name": .string("ops"), "canonical_session": .object(["id": .string("only")])]),
        ])])
        #expect(BotChat.canonicalID(in: reply, profile: "work") == "tip")
        #expect(BotChat.canonicalID(in: reply, profile: "ops") == "only")
        #expect(BotChat.canonicalID(in: reply, profile: "default") == nil, "a null canonical session is no Bot Chat")
        #expect(BotChat.canonicalID(in: reply, profile: "nobody") == nil)
    }

    /// A gateway without the field: the bot's own chat titled Bot Chat, else one with it in its title.
    @Test func titleIsTheFallback() {
        let list = [StoredSession(id: "a", title: "Notes"), StoredSession(id: "b", title: "Bot Chat", profile: "ops"),
                    StoredSession(id: "c", title: "Re: bot chat"), StoredSession(id: "d", title: "Bot Chat")]
        #expect(BotChat.titledID(in: list, profile: "work") == "d", "another bot's Bot Chat was taken")
        #expect(BotChat.titledID(in: Array(list.prefix(3)), profile: "work") == "c")
        #expect(BotChat.titledID(in: [StoredSession(id: "a", title: "Notes")], profile: "work") == nil)
    }

    /// Through the real client on the demo gateway, whose profiles.list names gizmo's Bot Chat.
    @Test func demoBotsBotChat() async throws {
        let rt = await runtime()
        #expect(try await BotChat.storedID(of: "gizmo", on: rt) == DemoContent.botChatID)
    }
}
