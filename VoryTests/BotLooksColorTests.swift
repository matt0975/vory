import Foundation
import Testing
@testable import VoryCore

/// The extensions' colour for a bot (#506): the copy's own, or, for a bot missing from it, the app's default by its name,
/// never a fixed colour.
@Suite struct BotLooksColorTests {
    @Test func aBotMissingFromTheCopyGetsTheAppsDefaultByItsName() {
        let looks = BotLooks(colors: ["work": "#112233"], avatars: [:])
        #expect(looks.color(for: "work") == "#112233")
        #expect(looks.color(for: "research") == BotPalette.defaultHex(for: "research"))
        // A label as the key: the default goes by the bot's name, as the app's does.
        #expect(looks.color(for: "Sprout", profile: "default") == BotPalette.defaultHex(for: "default"))
        // An empty colour counts as none.
        #expect(BotLooks(colors: ["work": ""], avatars: [:]).color(for: "work") == BotPalette.defaultHex(for: "work"))
    }

    @Test func theDefaultIsTheSameEveryTime() {
        let looks = BotLooks()
        #expect(looks.color(for: "nightly") == looks.color(for: "nightly"))
        #expect(BotPalette.hexes.contains(looks.color(for: "nightly")))
    }
}
