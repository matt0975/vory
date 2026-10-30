import Testing
@testable import Vory

/// Settings › Appearance › Reading › "Bot colour on replies": the wash belongs to the reply, not to the
/// bot's face. It used to be read off the field that decides whether the bot is drawn beside the bubble,
/// so with "Bot beside replies" off, the default, the toggle did nothing at all.
@Suite struct ReplyTintTests {
    @Test func theWashIsTheBotsOwnColour() {
        #expect(ChatStyle.replyTintHex(on: true, bot: "ops", scopeHex: nil) == BotColors.hex(for: "ops"))
    }

    /// The bug: the row knows whose reply it is whether or not a face is drawn, so the colour is there
    /// with "Bot beside replies" off.
    @Test func theWashIsThereWithNoBotDrawnBesideTheBubble() {
        #expect(ChatStyle.replyTintHex(on: true, bot: "ops", scopeHex: nil) == BotColors.hex(for: "ops"),
                "with bots hidden the reply still takes the bot's colour")
    }

    @Test func offKeepsTheGreyBubble() {
        #expect(ChatStyle.replyTintHex(on: false, bot: "ops", scopeHex: nil) == nil)
        #expect(ChatStyle.replyTintHex(on: false, bot: nil, scopeHex: "#123456") == nil)
    }

    /// A demo bot wears the colour its own look gives it, over whatever the stored colour is.
    @Test func aScopedLookWins() {
        #expect(ChatStyle.replyTintHex(on: true, bot: "ops", scopeHex: "#123456") == "#123456")
    }

    /// Nothing to take a colour from: the grey bubble rather than an invented accent.
    @Test func noBotAnywhereIsGrey() {
        #expect(ChatStyle.replyTintHex(on: true, bot: nil, scopeHex: nil) == nil)
    }
}
