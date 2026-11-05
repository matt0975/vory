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

    /// On the closed Duo the stack shared the room out evenly and the card kept only its choices. Once measured, the card
    /// takes its whole height when that fits, the conversation giving way first, and the bot goes lean when it doesn't;
    /// what's asked and the choices always stand whole there. Measured at Large on the closed Duo, near enough: what's
    /// asked 148, what each answer covers 40, the choices 100 (a 2x2 grid).
    @Test func theClosedDuosCardStandsWhole() {
        let parts = VoiceSplit.CardHeights(asked: 148, covers: 40, choices: 100)
        #expect(VoiceSplit.cardNeed(parts) == 296)
        #expect(VoiceSplit.cardWhole(parts) == 336)
        #expect(VoiceSplit.cardNeed(VoiceSplit.CardHeights()) == 0, "nothing until measured")
        #expect(VoiceSplit.cardWhole(VoiceSplit.CardHeights(asked: 148, covers: 40, choices: 0)) == 0)
        let row: CGFloat = 48, botFull: CGFloat = 264.3, lean: CGFloat = 12 + VoiceSplit.face, controls: CGFloat = 125.7
        // The full bot leaves 200 under the whole card's 336: lean. Lean, 312.3 is left, more than what must show (296).
        #expect(VoiceSplit.compactOneColumn(room: 644, row: row, botFull: botFull, controls: controls, card: 336, size: .large))
        let fit = VoiceSplit.oneColumnCard(room: 644, row: row, bot: lean, controls: controls, heights: parts, size: .large)
        #expect(fit?.height == 644 - row - lean - controls - VoiceSplit.transcriptTop)
        #expect(fit?.wordsScroll == false)
        // The open Duo upright: the whole card under the full bot, the conversation keeping the rest.
        let wide = VoiceSplit.CardHeights(asked: 114, covers: 28, choices: 55)
        #expect(!VoiceSplit.compactOneColumn(room: 835, row: row, botFull: botFull, controls: 127.3, card: VoiceSplit.cardWhole(wide), size: .large))
        #expect(VoiceSplit.oneColumnCard(room: 835, row: row, bot: botFull, controls: 127.3, heights: wide, size: .large)?.height
                == VoiceSplit.cardWhole(wide))
        // The last resort: what's asked and the choices taller than what is left. The words scroll, and the card is never
        // under its floor.
        let tall = VoiceSplit.CardHeights(asked: 260, covers: 60, choices: 180)
        let last = VoiceSplit.oneColumnCard(room: 644, row: row, bot: lean, controls: controls, heights: tall, size: .accessibility2)
        #expect(last?.wordsScroll == true)
        #expect(last.map { $0.height >= VoiceSplit.cardFloor(for: .accessibility2) } == true)
        #expect(VoiceSplit.oneColumnCard(room: 0, row: row, bot: lean, controls: controls, heights: parts, size: .large) == nil)
        // Lean, the bot gives up the split's face (24, or the ring's 28) and its state lines with the space over them. Muted,
        // its full lines hold the capsule too (26 and the 6 over it), and lean says it by a badge on the face with no height
        // of its own: the lean block is the face alone either way, so the closed Duo keeps its 312.3 muted or not.
        #expect(VoiceSplit.leanSaving(ring: false, lines: 74) == 24 + 18 + 74)
        #expect(VoiceSplit.leanSaving(ring: true, lines: 74) == 28 + 18 + 74)
        let fullFace: CGFloat = 12 + 164 + 18, unmutedLines: CGFloat = 74, mutedLines: CGFloat = 74 + 6 + 26
        let leanUnmuted = fullFace + unmutedLines - VoiceSplit.leanSaving(ring: false, lines: unmutedLines)
        let leanMuted = fullFace + mutedLines - VoiceSplit.leanSaving(ring: false, lines: mutedLines)
        #expect(leanMuted == leanUnmuted)
        #expect(leanMuted == lean)
        #expect(VoiceLook.micMuted == "Mic muted", "the lean bot's badge reads as the capsule's words")
    }

    @Test func theCompactBlockSavesItsRingOrItsFace() {
        #expect(VoiceSplit.compactSaving(ring: true) == 196 - VoiceSplit.ring)
        #expect(VoiceSplit.compactSaving(ring: false) == 164 - VoiceSplit.face)
    }
}
