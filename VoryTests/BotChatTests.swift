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

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    /// The bot's page: a Bot Chat row under Profile, above its Chats, shown only when the bot has one, that opens it as
    /// an ordinary chat (no `readOnly`). They are a view's rows, so the check reads the source, as DemoEntryPointsTests does.
    @Test func botPageOpensItsBotChatToTypeIn() throws {
        let file = try Self.source("Vory/Bots/BotsView.swift")
        let page = try #require(file.range(of: "struct BotDetailView").map { String(file[$0.lowerBound...]) })
        let body = String(page[..<(page.range(of: "private func load()")?.lowerBound ?? page.endIndex)])
        let profile = try #require(body.range(of: "Text(\"Profile\")"), "the page has no Profile row")
        let chats = try #require(body.range(of: "Text(\"Chats\")"), "the page has no Chats header")
        let row = try #require(body.range(of: "BotChat.route("), "the page has no Bot Chat row")
        #expect(profile.upperBound <= row.lowerBound && row.upperBound <= chats.lowerBound, "the Bot Chat row isn't between Profile and Chats")
        #expect(body.contains("if let botChatID"), "the Bot Chat row is shown when the bot has none")
        #expect(page.contains("BotChat.storedID(of: profile.name"), "the page doesn't find the Bot Chat the notice's way")
    }

    /// The route the page opens is the chat itself, to type in, titled Bot Chat; the notice's stays read-only.
    @Test func pageRouteIsWritableAndTheNoticesIsNot() throws {
        let app = try Self.source("Vory/App/AppModel.swift")
        let notice = try #require(app.range(of: "func openBotChat(").map { String(app[$0.lowerBound...].prefix(1200)) })
        #expect(notice.contains("BotChat.storedID(of: profile.name, on: rt)"))
        #expect(notice.contains("route.kind = \"readonly\""), "the notice's Bot Chat is no longer read-only")
        let bots = try Self.source("Vory/Bots/BotChat.swift")
        #expect(bots.contains("static func route("), "BotChat has no route for the bot's page")
    }
}
