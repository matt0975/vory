import Testing
@testable import Vory

/// A cold launch with All bots on: the list is not asked for before the gateway has answered for
/// its bots, so an answer made of no bots cannot wipe it (feedback on 1.5 (20): no chats until
/// another page was picked).
struct ChatListLoadTests {
    @Test func allBotsWaitsForTheGatewaysAnswerAboutItsBots() {
        #expect(!ChatListView.canList(allBots: true, botsLoaded: false), "not answered yet: nothing to ask for, the cached list stays")
        #expect(ChatListView.canList(allBots: true, botsLoaded: true), "answered (with bots, or with none): ask")
        #expect(ChatListView.canList(allBots: false, botsLoaded: false), "one bot's list does not wait for the others")
        #expect(ChatListView.canList(allBots: false, botsLoaded: true))
    }
}
