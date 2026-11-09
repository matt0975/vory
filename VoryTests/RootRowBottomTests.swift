import CoreGraphics
import Testing
@testable import Vory

/// #612: the top bar's root row bottom, from its slots' measured frames (the lead circle, the title, the trailing
/// capsule), in the bar's space. The frames are the ones read on the closed Duo.
@Suite struct RootRowBottomTests {
    private let rest = [CGRect(x: 0, y: 0, width: 44, height: 44), CGRect(x: 54, y: 3, width: 70.7, height: 38),
                        CGRect(x: 232, y: 0, width: 130, height: 44)]

    @Test func theRowAtRestIsItsTallestSlot() {
        #expect(TopBarRoom.rowBottom(of: rest) == 44)
        #expect(TopBarRoom.inset(barsVertical: true, statusInCorner: false, barOn: true, rowBottom: TopBarRoom.rowBottom(of: rest)) == 63)
    }

    /// After an accessibility audit's text sizes, the title was back but the lead's last place was still where the
    /// taller row had centred it: its bottom read 75.5, and the closed Duo's pages stood 32 pt lower (room 95).
    @Test func aSlotLeftLowAfterATextSizeChangeDoesNotDeepenTheRow() {
        let after = [CGRect(x: 0, y: 31.5, width: 44, height: 44), CGRect(x: 54, y: 3, width: 70.7, height: 38),
                     CGRect(x: 232, y: 0, width: 130, height: 44)]
        #expect(TopBarRoom.rowBottom(of: after) == 44)
        #expect(TopBarRoom.inset(barsVertical: true, statusInCorner: false, barOn: true, rowBottom: TopBarRoom.rowBottom(of: after)) == 63)
    }

    /// At a larger text size the title is the tallest slot, and the row is as tall as it.
    @Test func aTallerTitleMakesTheRowItsHeight() {
        let large = [CGRect(x: 0, y: 31.5, width: 44, height: 44), CGRect(x: 54, y: 0, width: 86, height: 107),
                     CGRect(x: 227, y: 31.5, width: 135, height: 44)]
        #expect(TopBarRoom.rowBottom(of: large) == 107)
    }

    @Test func noSlotsNoRow() {
        #expect(TopBarRoom.rowBottom(of: []) == 0)
        #expect(TopBarRoom.inset(barsVertical: true, statusInCorner: false, barOn: true, rowBottom: TopBarRoom.rowBottom(of: [])) == 0)
    }
}

#if os(iOS)
/// #612: the root row's bottom as the bar's state keeps it, written from each measurement of the row's slots: the tallest
/// slot's height, back down when the title is, and nothing written mid-scrub.
@MainActor @Suite struct MorphStateRootRowTests {
    private let lead = CGRect(x: 0, y: 0, width: 44, height: 44), trail = CGRect(x: 232, y: 0, width: 130, height: 44)

    @Test func aSlotLeftLowDoesNotDeepenTheRow() {
        let state = MorphState()
        state.noteRootRow([.lead: CGRect(x: 0, y: 31.5, width: 44, height: 44), .mid: CGRect(x: 54, y: 3, width: 70.7, height: 38), .trail: trail])
        #expect(state.rootRowBottom == 44)
    }

    /// An audit inside a chat: the list's title grew to 107 and came back to 38.
    @Test func theTitleComingBackBringsTheRowBack() {
        let state = MorphState()
        state.noteRootRow([.lead: lead, .mid: CGRect(x: 54, y: 0, width: 86, height: 107), .trail: trail])
        #expect(state.rootRowBottom == 107)
        state.noteRootRow([.lead: lead, .mid: CGRect(x: 54, y: 3, width: 70.7, height: 38), .trail: trail])
        #expect(state.rootRowBottom == 44)
    }

    @Test func nothingIsWrittenMidScrub() {
        let state = MorphState()
        state.noteRootRow([.lead: lead, .trail: trail])
        state.scrubbing = true
        state.noteRootRow([.lead: lead, .mid: CGRect(x: 54, y: 0, width: 86, height: 107), .trail: trail])
        #expect(state.rootRowBottom == 44)
    }
}
#endif
