import CoreGraphics
import SwiftUI
import Testing
import VoryCore
@testable import Vory

/// Voice mode's colours and its one-column layout with a card waiting (#631): every word on the screen and on its card at
/// 4.5:1 or more (the title, a large one, at 3:1 or more) for every bot colour, light ones included, and the closed Duo's
/// column held on the screen.
@Suite struct VoiceLookTests {
    /// The palette, and the light colours a person can pick that the palette doesn't have.
    static let tints: [VoiceLook.RGB] = (BotPalette.hexes + ["#FFFFFF", "#FFFF00", "#00FFFF"]).compactMap { VoiceLook.RGB(hex: $0) }

    @Test func everyTintIsRead() {
        #expect(Self.tints.count == BotPalette.hexes.count + 3)
    }

    @Test func theModelMatchesTheFindingsAtTheOldTop() {
        // White over 1.5's top (the tint at 0.55 over black), as measured for #631: under 4.5:1 for the light colours.
        func old(_ hex: String) -> Double { VoiceLook.contrast(.white, VoiceLook.over(VoiceLook.RGB(hex: hex)!, 0.55, .black)) }
        #expect(abs(old("#FFD60A") - 4.47) < 0.01)
        #expect(abs(old("#00FFFF") - 4.08) < 0.01)
        #expect(abs(old("#FFFF00") - 3.57) < 0.01)
        #expect(abs(old("#FFFFFF") - 3.35) < 0.01)
    }

    @Test func darkTintsKeepTheirTopAndLightOnesGetADarkerOne() {
        #expect(VoiceLook.topOpacity(for: VoiceLook.RGB(hex: "#7C5CFF")!) == VoiceLook.fullTopOpacity)
        #expect(VoiceLook.topOpacity(for: VoiceLook.RGB(hex: "#0A84FF")!) == VoiceLook.fullTopOpacity)
        for hex in ["#FFD60A", "#FFFFFF", "#FFFF00", "#00FFFF"] {
            let t = VoiceLook.RGB(hex: hex)!
            #expect(VoiceLook.topOpacity(for: t) < VoiceLook.fullTopOpacity, "\(hex)")
            #expect(VoiceLook.luminance(VoiceLook.top(for: t)) <= VoiceLook.topLuminanceCap + 1e-9, "\(hex)")
        }
    }

    @Test func theScreensWordsPassOverTheTopForEveryTint() {
        for t in Self.tints {
            let top = VoiceLook.top(for: t)
            #expect(VoiceLook.contrast(.white, top) >= 3, "the title over \(t)")
            #expect(VoiceLook.contrast(.white, top) >= 4.5, "white over \(t)")
            let secondary = VoiceLook.over(.white, VoiceLook.secondaryOpacity, top)
            #expect(VoiceLook.contrast(secondary, top) >= 4.5, "the secondary words over \(t)")
            let backing = VoiceLook.over(.black, VoiceLook.noteBackingOpacity, top)
            #expect(VoiceLook.contrast(VoiceLook.orange, backing) >= 4.5, "a note on its capsule over \(t)")
        }
    }

    @Test func theCardsWordsPassOnItsSurfaceForEveryTint() {
        for t in Self.tints {
            let surface = VoiceLook.cardSurface(over: VoiceLook.top(for: t))
            #expect(VoiceLook.contrast(VoiceLook.orange, surface) >= 4.5, "the heading over \(t)")
            #expect(VoiceLook.contrast(.white, surface) >= 4.5, "the words and the choices over \(t)")
            #expect(VoiceLook.contrast(VoiceLook.over(.white, VoiceLook.cardSecondaryOpacity, surface), surface) >= 4.5, "the quieter lines over \(t)")
            #expect(VoiceLook.contrast(VoiceLook.deny, surface) >= 4.5, "Deny over \(t)")
        }
        #expect(VoiceLook.contrast(.white, VoiceLook.allowOnceFill) >= 4.5, "Allow once on its own fill")
    }

    /// The closed Duo's column with a card up: 382 pt wide and too short for the bot's full block over the card (50's
    /// frames: the column ran from -23 to 667), against the open Duo upright (835 tall) and on its side (635 tall, but
    /// wide enough that the card's choices stand in one row).
    @Test func theClosedDuosColumnTakesTheCompactBot() {
        // Measured on 50: the top row 48, the bot's full block 252.3 with its 12 over it, the controls 127.3 at Large.
        let row: CGFloat = 48, bot: CGFloat = 264.3, controls: CGFloat = 127.3
        #expect(VoiceSplit.compactOneColumn(room: 644, row: row, botFull: bot, controls: controls, size: .large))
        #expect(!VoiceSplit.compactOneColumn(room: 835, row: row, botFull: bot, controls: controls, size: .large))
        #expect(!VoiceSplit.compactOneColumn(room: 0, row: row, botFull: bot, controls: controls, size: .large), "no room measured yet")
        // At the accessibility sizes the card's floor rises, so a column that fits at Large may not.
        #expect(VoiceSplit.compactOneColumn(room: 700, row: row, botFull: bot, controls: controls, size: .accessibility2))
        #expect(!VoiceSplit.compactOneColumn(room: 700, row: row, botFull: bot, controls: controls, size: .large))
    }

    @Test func theCardIsHeldToWhatIsLeftNeverUnderItsFloor() {
        #expect(VoiceSplit.oneColumnCardMax(room: 0, row: 48, bot: 240, controls: 127, size: .large) == nil)
        #expect(VoiceSplit.oneColumnCardMax(room: 835, row: 48, bot: 240, controls: 127, size: .large) == 420)
        #expect(VoiceSplit.oneColumnCardMax(room: 500, row: 48, bot: 240, controls: 127, size: .large) == VoiceSplit.cardFloor(for: .large))
        #expect(VoiceSplit.cardFloor(for: .accessibility1) > VoiceSplit.cardFloor(for: .xxxLarge))
    }

    @Test func theCompactBlockSavesItsRingOrItsFace() {
        #expect(VoiceSplit.compactSaving(ring: true) == 196 - VoiceSplit.ring)
        #expect(VoiceSplit.compactSaving(ring: false) == 164 - VoiceSplit.face)
    }
}
