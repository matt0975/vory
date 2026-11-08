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
        let fit = VoiceSplit.oneColumnCard(room: 644, row: row, bot: lean, controls: controls, heights: parts)
        #expect(fit?.height == 644 - row - lean - controls - VoiceSplit.transcriptTop)
        #expect(fit?.wordsScroll == false)
        #expect(fit?.allScroll == false)
        // The open Duo upright: the whole card under the full bot, the conversation keeping the rest.
        let wide = VoiceSplit.CardHeights(asked: 114, covers: 28, choices: 55)
        #expect(!VoiceSplit.compactOneColumn(room: 835, row: row, botFull: botFull, controls: 127.3, card: VoiceSplit.cardWhole(wide), size: .large))
        #expect(VoiceSplit.oneColumnCard(room: 835, row: row, bot: botFull, controls: 127.3, heights: wide)?.height
                == VoiceSplit.cardWhole(wide))
        // The last resort: what's asked and the choices taller than what is left. The card is exactly what is left (round
        // 3: no floor once measured, so the column never runs past the screen), its words scroll, the choices still fit.
        let tall = VoiceSplit.CardHeights(asked: 260, covers: 60, choices: 180)
        let last = VoiceSplit.oneColumnCard(room: 644, row: row, bot: lean, controls: controls, heights: tall)
        #expect(last?.height == 644 - row - lean - controls - VoiceSplit.transcriptTop)
        #expect(last?.wordsScroll == true)
        #expect(last?.allScroll == false)
        // The closed Duo at AX5 as measured, the longer text, the face hidden: the choices alone (457, with the card's padding and a
        // gap) are taller than what is left, so everything scrolls, and the card is still only what is left.
        let huge = VoiceSplit.CardHeights(asked: 774, covers: 576, choices: 457.3)
        let worst = VoiceSplit.oneColumnCard(room: 644, row: 116, bot: 0, controls: 164.3, heights: huge)
        #expect(worst?.allScroll == true)
        #expect(worst?.height == 644 - 116 - 164.3 - VoiceSplit.transcriptTop)
        #expect(VoiceSplit.oneColumnCard(room: 0, row: row, bot: lean, controls: controls, heights: parts) == nil)
        // The bot's block at each level (round 3: worked out, not measured): full is the face, the space and its state
        // lines; lean the split's face alone (24 less, or the ring's 28), the same muted or not, since the mic muted is a
        // badge on the face then; hidden nothing. CGFloat on the right: a sum of bare literals there is read as Int.
        #expect(VoiceSplit.botBlock(.full, ring: false, lines: 74) == CGFloat(12 + 164 + 18 + 74))
        #expect(VoiceSplit.botBlock(.lean, ring: false, lines: 74) == lean)
        #expect(VoiceSplit.botBlock(.lean, ring: false, lines: 74 + 6 + 26) == lean, "the lean block, muted or not")
        #expect(VoiceSplit.botBlock(.lean, ring: true, lines: 74) == 12 + VoiceSplit.ring)
        #expect(VoiceSplit.botBlock(.hidden, ring: false, lines: 74) == 0)
        #expect(VoiceLook.micMuted == "Mic muted", "the lean bot's badge reads as the capsule's words")
    }

    /// Round 3: past lean, the bot's face hides too when what must show doesn't fit beside the lean face. Round 3l: at any
    /// size (it was XXXL and larger only: the closed Duo at XXL cut the command under the words' fade), within the margin
    /// (`faceMargin`). The closed Duo at XXXL as measured, the longer text: the row 53, the controls at their natural 134.5,
    /// what must show 482.3 (asked 243.7, the choices 190.7), the whole card 590.7.
    @Test func theBotHidesItsFaceWhenWhatIsAskedWouldNotStandWhole() {
        let full = VoiceSplit.botBlock(.full, ring: false, lines: 120), lean = VoiceSplit.botBlock(.lean, ring: false, lines: 120)
        // At XXXL, 298.5 is left beside the lean face; what must show is 482.3: hidden.
        #expect(VoiceSplit.oneColumnBotLevel(room: 644, row: 53, full: full, lean: lean, controls: 134.5, whole: 590.7, need: 482.3,
                                             size: .xxxLarge) == .hidden)
        // The same numbers at Large: hidden too (round 3l: at any size).
        #expect(VoiceSplit.oneColumnBotLevel(room: 644, row: 53, full: full, lean: lean, controls: 134.5, whole: 590.7, need: 482.3,
                                             size: .large) == .hidden)
        // The closed Duo at XXL as measured on round 3k: 305.4 left beside the lean face, what must show 366.7: hidden.
        #expect(VoiceSplit.oneColumnBotLevel(room: 644, row: 48.3, full: full, lean: lean, controls: 132.3, whole: 444.7, need: 366.7,
                                             size: .xxLarge) == .hidden)
        // XL on the closed Duo as measured on round 3k: what must show 296.3 beside 308, past the margin: lean.
        #expect(VoiceSplit.oneColumnBotLevel(room: 644, row: 48, full: full, lean: lean, controls: 130, whole: 366, need: 296.3,
                                             size: .xLarge) == .lean)
        // Large on the closed Duo, the longer text, as measured: what must show 299 fits beside the lean face (310.7), past
        // the margin: lean.
        #expect(VoiceSplit.oneColumnBotLevel(room: 644, row: 48, full: full, lean: lean, controls: 127.3, whole: 338.3, need: 299,
                                             size: .large) == .lean)
        // Within the margin of the same 310.7: hidden, so a measure a point short never cuts what's asked.
        #expect(VoiceSplit.oneColumnBotLevel(room: 644, row: 48, full: full, lean: lean, controls: 127.3, whole: 338.3,
                                             need: 310.7 - VoiceSplit.faceMargin + 1, size: .large) == .hidden)
        // At XXXL when what must show fits beside the lean face: lean.
        #expect(VoiceSplit.oneColumnBotLevel(room: 644, row: 53, full: full, lean: lean, controls: 134.5, whole: 400, need: 290,
                                             size: .xxxLarge) == .lean)
        // Upright, the whole card fits beside the full bot: full.
        #expect(VoiceSplit.oneColumnBotLevel(room: 835, row: 48, full: VoiceSplit.botBlock(.full, ring: false, lines: 74), lean: lean,
                                             controls: 127.3, whole: 245, need: 217, size: .large) == .full)
        // Not measured yet: the floor decides lean, and the face never hides unmeasured.
        #expect(VoiceSplit.oneColumnBotLevel(room: 644, row: 53, full: full, lean: lean, controls: 134.5, whole: 0, need: 0,
                                             size: .xxxLarge) == .lean)
    }

    /// Round 3: the choices' solid fills in voice mode. White names on Allow once's blue and on the grey, and Deny's red on
    /// the grey, each at 4.5:1 or more whatever stands behind the card, since the fills are solid.
    @Test func theChoicesNamesPassOnTheirOwnFills() {
        #expect(VoiceLook.contrast(.white, VoiceLook.allowOnceFill) >= 4.5, "Allow once")
        #expect(VoiceLook.contrast(.white, VoiceLook.choiceFill) >= 4.5, "Allow for this chat and Always allow…")
        #expect(VoiceLook.contrast(VoiceLook.deny, VoiceLook.choiceFill) >= 4.5, "Deny")
    }

    @Test func theCompactBlockSavesItsRingOrItsFace() {
        #expect(VoiceSplit.compactSaving(ring: true) == 196 - VoiceSplit.ring)
        #expect(VoiceSplit.compactSaving(ring: false) == 164 - VoiceSplit.face)
    }

    /// Round 3k: what each answer covers shows whole lines only. On the closed Duo at Large the card was short of its whole
    /// height and its small print's third line was cut through at its scroll's edge (the audit's element-less "Text
    /// clipped"). Its share is now cut down to whole lines, the card that much shorter; nothing changes when the whole
    /// card fits, when the words scroll, or before a line is measured.
    @Test func theSmallPrintShowsWholeLinesOnly() {
        let row: CGFloat = 48, lean = 12 + VoiceSplit.face, controls: CGFloat = 125.7
        let left = 644 - row - lean - controls - VoiceSplit.transcriptTop
        // What must show leaves 30 for the small print, whose lines are 13 and which runs to four of them: two show, 26.
        let parts = VoiceSplit.CardHeights(asked: left - 30 - 76.6 - 2 * VoiceSplit.cardGap - 2 * VoiceSplit.cardPadding,
                                           covers: 52, choices: 76.6, coversLine: 13)
        let fit = VoiceSplit.oneColumnCard(room: 644, row: row, bot: lean, controls: controls, heights: parts)
        #expect(fit?.height == VoiceSplit.cardNeed(parts) + 26, "two whole lines")
        #expect(fit?.wordsScroll == false)
        #expect(fit?.allScroll == false)
        // Before a line is measured: what is left, as before.
        var unmeasured = parts; unmeasured.coversLine = 0
        #expect(VoiceSplit.oneColumnCard(room: 644, row: row, bot: lean, controls: controls, heights: unmeasured)?.height == left)
        // Exactly three lines' room: all three show.
        var three = parts; three.asked += 30 - 39
        #expect(VoiceSplit.oneColumnCard(room: 644, row: row, bot: lean, controls: controls, heights: three)?.height
                == VoiceSplit.cardNeed(three) + 39, "three whole lines")
        // The whole card fits: as it is.
        let small = VoiceSplit.CardHeights(asked: 100, covers: 26, choices: 76.6, coversLine: 13)
        #expect(VoiceSplit.oneColumnCard(room: 644, row: row, bot: lean, controls: controls, heights: small)?.height == VoiceSplit.cardWhole(small))
        // The words scroll (what must show doesn't fit): what is left, as before.
        let tall = VoiceSplit.CardHeights(asked: left, covers: 52, choices: 76.6, coversLine: 13)
        let words = VoiceSplit.oneColumnCard(room: 644, row: row, bot: lean, controls: controls, heights: tall)
        #expect(words?.height == left)
        #expect(words?.wordsScroll == true)
    }

    /// Round 3l: the voice screen's conversation shows whole lines only, at its top edge too. On the closed Duo at Large
    /// the card left it a sliver, and a line of it showed cut through above the card. Its rows walked from the newest up
    /// (the screen follows them), its height is cut down to where a line starts; the rest stays blank.
    @Test func theConversationShowsWholeLinesOnly() {
        let line: CGFloat = 22, bottom = VoiceSplit.conversationBottom, gap = VoiceSplit.conversationGap
        // The newest row three lines (66), the one before it two (44).
        let rows: [CGFloat] = [66, 44]
        // A sliver, under the space below the newest row: no line there, the room as it is (blank).
        #expect(VoiceSplit.conversationShown(room: 13, rows: rows, line: line) == 13)
        // The edge a line and a bit up the newest row: one whole line.
        #expect(VoiceSplit.conversationShown(room: bottom + 66 - 30, rows: rows, line: line) == bottom + 22)
        // Exactly two lines' room: both.
        #expect(VoiceSplit.conversationShown(room: bottom + 44, rows: rows, line: line) == bottom + 44)
        // The edge between the two rows: no line cut, the room as it is.
        #expect(VoiceSplit.conversationShown(room: bottom + 66 + gap / 2, rows: rows, line: line) == bottom + 66 + gap / 2)
        // The edge inside the older row: its whole lines under the edge.
        #expect(VoiceSplit.conversationShown(room: bottom + 66 + gap + 30, rows: rows, line: line) == bottom + 66 + gap + 22)
        // Everything fits: the room as it is.
        #expect(VoiceSplit.conversationShown(room: 400, rows: rows, line: line) == 400)
        // Until one line and every row are measured: the room as it is.
        #expect(VoiceSplit.conversationShown(room: bottom + 36, rows: rows, line: 0) == bottom + 36)
        #expect(VoiceSplit.conversationShown(room: bottom + 36, rows: [66, 0], line: line) == bottom + 36)
    }

    /// Round 3m: the conversation's room on the voice screen is what it is offered, never what its scroll was last set to.
    /// In 3l the room was read from a frame the scroll itself held open, so once read tall it never came back down, and an
    /// approval arriving left the closed Duo's column 247 pt past its screen. With the scroll set to 600 over it, the room
    /// still takes the 120 or the 800 offered.
    @Test @MainActor func theConversationsRoomIsWhatItIsOfferedNeverItsScroll() {
        let room = Color.red.modifier(WholeLinesRoom(on: true, shown: 600, room: .constant(0), line: .constant(0)))
        #if canImport(UIKit)
        let host = UIHostingController(rootView: room)
        #else
        let host = NSHostingController(rootView: room)
        #endif
        #expect(abs(host.sizeThatFits(in: CGSize(width: 382, height: 120)).height - 120) <= 0.5, "a short room stays short")
        #expect(abs(host.sizeThatFits(in: CGSize(width: 382, height: 800)).height - 800) <= 0.5, "a tall room stays tall")
    }

    /// Round 3f: the top row's title in full white, 6:1 or more over every tint's top (white at 0.85 had under 5:1 over
    /// the light ones).
    @Test func theTitlePassesOverTheTopForEveryTintWithRoomToSpare() {
        for t in Self.tints {
            #expect(VoiceLook.contrast(VoiceLook.topTitle, VoiceLook.top(for: t)) >= 6, "the title over \(t)")
        }
    }

    /// Round 3f: the four choices the same size. The widest name, "Allow for this chat", 135.7 at Large and about 151.7,
    /// 167.6 and 183.6 at XL, XXL and XXXL; the capsule's insets taken as 32; the card's inside 322 on the closed Duo, 609
    /// upright, 807 on its side and as a book.
    @Test func theChoicesTakeOneLineAtTheBoundElseWrapOnWords() {
        typealias A = VoiceSplit.ChoiceArrangement
        // The width at the fit scale taken as the name's times 0.8 here, as these cases always had it (the app measures it;
        // the measured cases are in noFrameEverBreaksAWord).
        func a(_ width: CGFloat, _ name: CGFloat, _ word: CGFloat, ax: Bool = false, count: Int = 4) -> A {
            VoiceSplit.choiceArrangement(width: width, widestName: name, widestAtFit: name * VoiceSplit.choiceMinScale, longestWord: word,
                                         insets: 32, count: count, accessibility: ax)
        }
        let line = A(columns: 2, oneLine: true, minScale: VoiceSplit.choiceMinScale)
        let wrap = A(columns: 2, oneLine: false, minScale: 1)
        // Closed: two by two on one line at Large (it needs 0.92) and XL (0.82); wrapping at XXL and XXXL (0.75, 0.68).
        #expect(a(322, 135.7, 50) == line)
        #expect(a(322, 151.7, 56) == line)
        #expect(a(322, 167.6, 62) == wrap)
        #expect(a(322, 183.6, 68) == wrap)
        // At the accessibility sizes nothing shrinks: two by two while a half cell (125) holds the longest word, wrapping;
        // past it, one to a row.
        #expect(a(322, 301.2, 120, ax: true) == wrap)
        #expect(a(322, 400, 130, ax: true) == A(columns: 1, oneLine: false, minScale: 1))
        // Upright: a row at Large (0.84), two by two from XL, one line at full size through XXXL.
        #expect(a(609, 135.7, 50) == A(columns: 4, oneLine: true, minScale: VoiceSplit.choiceMinScale))
        #expect(a(609, 151.7, 56) == line)
        #expect(a(609, 183.6, 68) == line)
        // On its side and as a book: a row through XXXL (0.89).
        #expect(a(807, 183.6, 68) == A(columns: 4, oneLine: true, minScale: VoiceSplit.choiceMinScale))
        // One line at an accessibility size only at its own size.
        #expect(a(807, 190, 80, ax: true) == A(columns: 2, oneLine: true, minScale: 1))
        // Before the measures: two by two, wrapping. Fewer choices: as many to a row as fit; one alone takes the row.
        #expect(a(0, 135.7, 50) == .unmeasured)
        #expect(VoiceSplit.choiceArrangement(width: 322, widestName: 135.7, widestAtFit: 108.6, longestWord: 50, insets: 0, count: 4,
                                             accessibility: false) == .unmeasured)
        #expect(a(322, 82.6, 50, count: 2) == line)
        #expect(a(322, 135.7, 50, count: 3) == line)
        #expect(a(322, 82.6, 50, count: 1).columns == 1)
    }

    /// Round 3i: no frame should ever break a word, nor cut a name. Before the measures are in, the accessibility sizes
    /// start in one column (the closed Duo's first frame at AX5 was two by two, its half cell 113 pt against a 118.3 pt
    /// "Deny"); under them, two by two, where the closed card's half cell, less generous insets, holds XXXL's longest word
    /// (70.7, as measured on the closed Duo). Once measured: wherever the names wrap two to a row, a half cell holds the
    /// longest word; wherever they stand on one line, the widest name measured at the fit scale fits its cell. As measured
    /// on round 3i at 0.8: upright at XL 122.3 against a quarter cell's 122.25 (a row was cut; now two by two at its own
    /// size), and the closed Duo at XXL 129.7 against a half cell's 133 (drawn at its floor, it was cut). Round 3j measures
    /// at 0.85: about 130.0 and 137.8, and both leave one line in those cells.
    @Test func noFrameEverBreaksAWord() {
        typealias A = VoiceSplit.ChoiceArrangement
        #expect(VoiceSplit.choiceArrangement(width: 0, widestName: 0, widestAtFit: 0, longestWord: 0, insets: 0, count: 4, accessibility: true)
                == .unmeasuredAccessible)
        #expect(VoiceSplit.choiceArrangement(width: 322, widestName: 0, widestAtFit: 0, longestWord: 0, insets: 0, count: 4,
                                             accessibility: true).columns == 1)
        #expect(VoiceSplit.choiceArrangement(width: 322, widestName: 0, widestAtFit: 0, longestWord: 0, insets: 0, count: 4,
                                             accessibility: false) == .unmeasured)
        let longestUnderAccessibility: CGFloat = 70.7
        #expect(longestUnderAccessibility <= (322 - VoiceSplit.choiceGap) / 2 - 40, "the unmeasured two by two under the accessibility sizes")
        let line2 = A(columns: 2, oneLine: true, minScale: VoiceSplit.choiceMinScale), wrap2 = A(columns: 2, oneLine: false, minScale: 1)
        #expect(VoiceSplit.choiceArrangement(width: 609, widestName: 150.7, widestAtFit: 130.0, longestWord: 59, insets: 24, count: 4,
                                             accessibility: false) == line2, "upright at XL")
        #expect(VoiceSplit.choiceArrangement(width: 609, widestName: 150.7, widestAtFit: 122.0, longestWord: 59, insets: 24, count: 4,
                                             accessibility: false) == A(columns: 4, oneLine: true, minScale: VoiceSplit.choiceMinScale), "a row where it fits")
        #expect(VoiceSplit.choiceArrangement(width: 322, widestName: 162.3, widestAtFit: 137.8, longestWord: 64.7, insets: 24, count: 4,
                                             accessibility: false) == wrap2, "the closed Duo at XXL")
        #expect(VoiceSplit.choiceArrangement(width: 322, widestName: 162.3, widestAtFit: 133.0, longestWord: 64.7, insets: 24, count: 4,
                                             accessibility: false) == line2, "one line at the half cell's room")
        #expect(VoiceSplit.choiceArrangement(width: 322, widestName: 162.3, widestAtFit: 133.1, longestWord: 64.7, insets: 24, count: 4,
                                             accessibility: false) == wrap2, "wrapping just past it")
        func room(_ width: CGFloat, _ columns: Int, _ insets: CGFloat) -> CGFloat {
            (width - CGFloat(columns - 1) * VoiceSplit.choiceGap) / CGFloat(columns) - insets
        }
        for width: CGFloat in [322, 609, 807] {
            for word: CGFloat in stride(from: 40, through: 200, by: 5) {
                for widest in [word * 1.5, word * 2.5, word * 4] {
                    for grow: CGFloat in [1, 1.02, 1.05] {
                        let atFit = widest * VoiceSplit.choiceFitScale * grow
                        for insets: CGFloat in [24, 32, 44] {
                            for accessibility in [false, true] {
                                let a = VoiceSplit.choiceArrangement(width: width, widestName: widest, widestAtFit: atFit, longestWord: word,
                                                                     insets: insets, count: 4, accessibility: accessibility)
                                if a.oneLine {
                                    #expect((accessibility ? widest : atFit) <= room(width, a.columns, insets), "width \(width), widest \(widest)")
                                } else if a.columns == 2 {
                                    #expect(word <= room(width, 2, insets), "width \(width), word \(word), insets \(insets)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Round 3f: one cap for both side captions, the largest at which the widest of them fits its side (the widths here
    /// are the test's own).
    @Test func bothSideCaptionsTakeOneCap() {
        let capped: [CGFloat] = [131, 120, 100, 80]
        #expect(VoiceSplit.captionCap(room: 136, current: 120, capped: capped) == nil, "fits at its own size")
        #expect(VoiceSplit.captionCap(room: 136, current: 149.2, capped: capped) == .accessibility3)
        #expect(VoiceSplit.captionCap(room: 60, current: 149.2, capped: capped) == .accessibility1, "none fits: the smallest")
        #expect(VoiceSplit.captionCap(room: 0, current: 149.2, capped: capped) == nil, "not measured yet")
        #expect(VoiceSplit.captionCap(room: 136, current: 0, capped: capped) == nil, "not measured yet")
        #expect(VoiceSplit.captionCap(room: 60, current: 149.2, capped: [131, 120, 0, 80]) == nil, "not all measured")
        #expect(VoiceSplit.captionCap(room: 136, current: 149.2, capped: [0, 120, 100, 80]) == nil, "not all measured, though AX3 fits")
    }
}
