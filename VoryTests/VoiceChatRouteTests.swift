import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// The Voice Chat button's path: a request names a bot or not, and the chat it opens starts
/// voice mode on that bot, or on the one the list shows.
@Suite struct VoiceChatRouteTests {
    @Test func aRequestForABotOpensAFreshVoiceChatWithIt() {
        let route = ChatListView.voiceRoute(AppModel.VoiceChatRequest(profile: "work"), selectedProfile: "default", cwd: nil)
        #expect(route.storedID == nil && route.profile == "work" && route.startVoice && route.initialText == nil && !route.readOnly)
    }

    @Test func aRequestWithNoBotTakesTheOneTheListShowsAndTheProject() {
        let route = ChatListView.voiceRoute(AppModel.VoiceChatRequest(profile: nil), selectedProfile: "default", cwd: "/srv/app")
        #expect(route.profile == "default" && route.cwd == "/srv/app" && route.startVoice)
        // With no bot selected either, the gateway's default bot takes it (profile nil).
        #expect(ChatListView.voiceRoute(AppModel.VoiceChatRequest(profile: nil), selectedProfile: nil, cwd: nil).profile == nil)
    }

    @Test func everyRequestIsItsOwnSoTwoInARowBothOpen() {
        let a = AppModel.VoiceChatRequest(profile: nil), b = AppModel.VoiceChatRequest(profile: nil)
        #expect(a.id != b.id)
        // Two voice routes for the same bot are the same destination; the request ids keep them apart.
        #expect(ChatListView.voiceRoute(a, selectedProfile: "x", cwd: nil) == ChatListView.voiceRoute(b, selectedProfile: "x", cwd: nil))
    }
}
