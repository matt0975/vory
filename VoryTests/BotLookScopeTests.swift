#if os(iOS)
import Testing
@testable import Vory
@testable import VoryCore

/// The tour's own looks for the demo's bots (#490): each its own body, eyes and colour, as the demo has them, and none
/// for a bot that isn't the demo's, so a real bot's face never takes a demo look.
@Suite struct BotLookScopeTests {
    @Test func everyDemoBotHasItsOwnLookAndNoOtherBotHasOne() {
        let scope = BotLookScope.demo
        for bot in DemoBots.all {
            #expect(scope.avatar(for: bot.name) == BotAvatarChoice.studio(shape: bot.shape, eyes: bot.eyes).raw, "\(bot.name)'s body and eyes")
            #expect(scope.color(for: bot.name) == bot.hex, "\(bot.name)'s colour")
        }
        #expect(Set(DemoBots.all.map { scope.avatar(for: $0.name) ?? "" }).count == DemoBots.all.count, "two demo bots share a look")
        #expect(Set(DemoBots.all.map { scope.color(for: $0.name) ?? "" }).count == DemoBots.all.count, "two demo bots share a colour")
        #expect(scope.avatar(for: "my-own-bot") == nil && scope.color(for: "my-own-bot") == nil)
    }
}
#endif
