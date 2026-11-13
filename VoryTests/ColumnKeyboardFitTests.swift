import CoreGraphics
import Testing
@testable import Vory

/// #637: the closed Duo's column with the keyboard up, by fit alone. Back and More stay two wherever the pair fits as it
/// stands, nothing of it lower than 8 pt above the keyboard's top; where it does not they are one More, on Back's marker
/// where that fits and else with its bottom on that line. Nothing rises. The numbers are the closed Duo simulator's
/// (2026-11-11): the keyboard's top 374, so the line is 366; the circles 48 high, More's middle 60 under Back's, so
/// More's bottom is Back's marker's middle plus 84.
@Suite struct ColumnKeyboardFitTests {
    private func fit(_ back: CGFloat, top: CGFloat? = 374) -> TopBarRoom.ColumnFit { TopBarRoom.columnFit(back: back, keyboardTop: top) }

    @Test func withTheKeyboardDownThePairStandsWhereverItIs() {
        #expect(fit(199, top: nil) == .pair(back: 199, more: 259))
        #expect(fit(359, top: nil) == .pair(back: 359, more: 419))
    }

    @Test func thePairStaysWhereItFits() {
        // No Live Activity (the simulator's own place), one as measured on Oct 31, and the last place that fits: More's
        // bottom 283, 363 and 366, the last on the line, which counts as fitting.
        #expect(fit(199) == .pair(back: 199, more: 259))
        #expect(fit(279) == .pair(back: 279, more: 339))
        #expect(fit(282) == .pair(back: 282, more: 342))
    }

    @Test func theTwoBecomeOneFromTheFirstPlaceThatDoesNotFit() {
        // 283: More's bottom would be 367. The one More stands on Back's marker while its own bottom is on or over the line.
        #expect(fit(283) == .merged(more: 283))
        #expect(fit(293) == .merged(more: 293))
        #expect(fit(342) == .merged(more: 342))
    }

    @Test func theOneStandsOnTheLineWhereItsMarkerWouldNot() {
        // 343: on its marker its bottom would be 367. Its middle is the line less half a circle, 342, from there on.
        #expect(fit(343) == .merged(more: 342))
        #expect(fit(359) == .merged(more: 342))
    }

    @Test func theLineFollowsTheKeyboard() {
        // A keyboard 26 pt lower: the line at 392, so the pair fits to 308 and not from 309.
        #expect(fit(308, top: 400) == .pair(back: 308, more: 368))
        #expect(fit(309, top: 400) == .merged(more: 309))
    }

    @Test func backStandsWithThePairOnly() {
        // What the bar reads to put Back's control up or leave it out of the view: there with the pair, not there merged.
        #expect(fit(199, top: nil).hasBack)
        #expect(fit(282).hasBack)
        #expect(!fit(283).hasBack)
        #expect(!fit(359).hasBack)
    }

    @Test func aPairMergedUnderATallerKeyboardStaysOneUntilTheKeyboardGoes() {
        // The closed Duo's window (678 high, 34 at the bottom) and a marker at 279, which fits over a keyboard covering
        // 270 (its top 374) and not over one covering 300 (344). The column is fitted against the most the keyboard has
        // covered since it came up (`WindowGeometry.highOverlap`): up, taller, as it was, gone, up again.
        var held: CGFloat = 0
        let fits = [270, 300, 270, 0, 270].map { (now: CGFloat) -> TopBarRoom.ColumnFit in
            held = WindowGeometry.highOverlap(now: now, held: held)
            return fit(279, top: held > 0 ? 678 - 34 - held : nil)
        }
        #expect(fits == [.pair(back: 279, more: 339), .merged(more: 279), .merged(more: 279), .pair(back: 279, more: 339), .pair(back: 279, more: 339)])
        // And the case that started it: a menu asked for reads the keyboard 39 pt shorter while it stays. At 293 the
        // column is one More before, during and after.
        held = 0
        let underAMenu = [270, 231, 270].map { (now: CGFloat) -> TopBarRoom.ColumnFit in
            held = WindowGeometry.highOverlap(now: now, held: held)
            return fit(293, top: 678 - 34 - held)
        }
        #expect(underAMenu == [.merged(more: 293), .merged(more: 293), .merged(more: 293)])
    }

    @Test func backIsInTheMenuExactlyWhereItIsNotInTheColumn() {
        // What More's menu reads to put Back first: never both places, never neither.
        #expect(!fit(199, top: nil).backInMenu)
        #expect(!fit(282).backInMenu)
        #expect(fit(283).backInMenu)
        #expect(fit(342).backInMenu)
        #expect(fit(359).backInMenu)
    }

    @Test func theNumbersTheRuleStandsOn() {
        #expect(TopBarRoom.keyboardClear == 8)
        #expect(TopBarRoom.stripPitch == 60)
        #expect(TopBarRoom.columnSide == 48)
    }
}
