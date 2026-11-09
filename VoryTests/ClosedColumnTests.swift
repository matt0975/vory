#if os(iOS)
import CoreGraphics
import Testing
@testable import Vory

/// #618: the closed Duo's column. Back stands on its marker and More `stripPitch` under it, on its own marker's line:
/// closer than the system stands our two markers (two groups, 70 apart), never so close the 44 pt circles meet.
@MainActor @Suite struct ClosedColumnTests {
    /// The markers' middles closed with no Live Activity, as the system stood them when measured (`StripMarkers`).
    private let back = CGPoint(x: 418, y: 199), more = CGPoint(x: 418, y: 269)

    @Test func backStaysOnItsMarkerAndMoreStandsThePitchUnderIt() {
        #expect(MorphTopBar.columnCentre(.columnBack, back: back, more: more) == back)
        #expect(MorphTopBar.columnCentre(.columnMore, back: back, more: more) == CGPoint(x: 418, y: 199 + TopBarRoom.stripPitch))
    }

    @Test func thePitchIsCloserThanTheTwoGroupsAndKeepsTheCirclesApart() {
        #expect(TopBarRoom.stripPitch >= 44)
        #expect(TopBarRoom.stripPitch < 70)
    }

    /// #671: Back and More stand 60 apart, middle to middle, as circles of 48: 12 pt between them, more than the bar's
    /// glass spacing (10), so the two stand apart instead of running together.
    @Test func theCirclesAre48And60ApartWithRoomBetween() {
        #expect(TopBarRoom.stripPitch == 60)
        #expect(TopBarRoom.columnSide == 48)
        #expect(TopBarRoom.stripPitch - TopBarRoom.columnSide > 10)
    }

    /// A Live Activity moves the status down the strip, and Back's marker with it (80 pt closed): More follows Back.
    @Test func moreFollowsBackDownTheStrip() {
        let down = CGPoint(x: 418, y: 279)
        #expect(MorphTopBar.columnCentre(.columnMore, back: down, more: CGPoint(x: 418, y: 349)) == CGPoint(x: 418, y: 279 + TopBarRoom.stripPitch))
    }
}
#endif
