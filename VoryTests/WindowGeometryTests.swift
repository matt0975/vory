import CoreGraphics
import SwiftUI
import Testing
@testable import Vory

/// The window's geometry replaces every read of the main screen and the key window (1.5, iPad
/// and the Duo): the rules that decide what counts as a keyboard, how far the dock moves, how
/// much the tab bar reserves, and how a grid splits on a wide layout.
@Suite struct WindowGeometryTests {
    let window = CGRect(x: 0, y: 0, width: 393, height: 852)

    @Test func aKeyboardOnTheBottomEdgeCounts() {
        let kb = CGRect(x: 0, y: 852 - 336, width: 393, height: 336)
        #expect(WindowGeometry.keyboardRect(window: window, end: kb) == kb)
        #expect(abs(WindowGeometry.keyboardOverlap(window: window, keyboard: kb, safeBottom: 34) - 302) < 0.001)
    }

    @Test func aHiddenKeyboardIsBelowTheWindowAndDoesNotCount() {
        let kb = CGRect(x: 0, y: 852, width: 393, height: 336)
        #expect(WindowGeometry.keyboardRect(window: window, end: kb).isNull)
        #expect(WindowGeometry.keyboardOverlap(window: window, keyboard: .null, safeBottom: 34) == 0)
    }

    @Test func aFloatingKeyboardAwayFromTheBottomEdgeDoesNotCount() {
        let kb = CGRect(x: 40, y: 300, width: 320, height: 260)
        #expect(WindowGeometry.keyboardRect(window: window, end: kb).isNull)
    }

    @Test func aWholeWindowRectIsNotAKeyboard() {
        #expect(WindowGeometry.keyboardRect(window: window, end: window).isNull)
    }

    @Test func theOverlapNeverExceedsMostOfTheWindow() {
        let kb = CGRect(x: 0, y: 852 - 560, width: 393, height: 560)
        #expect(abs(WindowGeometry.keyboardOverlap(window: window, keyboard: kb, safeBottom: 0) - 852 * 0.6) < 0.001)
    }

    @Test func aSplitWindowMeasuresItsOwnBottomEdge() {
        // Half of a 951 x 669 inner display: the window's own bounds, not the screen's.
        let half = CGRect(x: 0, y: 0, width: 475, height: 669)
        let kb = CGRect(x: 0, y: 669 - 300, width: 475, height: 300)
        #expect(abs(WindowGeometry.keyboardOverlap(window: half, keyboard: kb, safeBottom: 20) - 280) < 0.001)
    }

    #if os(iOS)
    @Test func theTabBarReservesLessOnAHomeButtonPhone() {
        // With a home indicator the capsule hangs 13 pt into its area; without one it cannot hang,
        // so the bar keeps those 13 pt as a gap above the window's edge instead.
        #expect(abs(VoryTabBar.reservedHeight(safeBottom: 34) - 43) < 0.001)
        #expect(abs(VoryTabBar.reservedHeight(safeBottom: 0) - 69) < 0.001)
        #expect(VoryTabBar.overhang(safeBottom: 8) == 8)
    }
    #endif

    @Test func wideGridsGetAnEvenColumnCount() {
        #expect(EvenColumns.count(width: 720, minimum: 150, spacing: 18) == 4)
        #expect(EvenColumns.count(width: 520, minimum: 150, spacing: 18) == 2)   // three fit; two keeps it even
        #expect(EvenColumns.count(width: 951, minimum: 150, spacing: 18) == 4)   // five fit
        #expect(EvenColumns.count(width: 0, minimum: 150, spacing: 18) == 2)
    }

    /// A keyboard frame is forgotten when the window changes size (a turn), kept while it stays:
    /// the open Duo's bar stayed hidden behind a keyboard the turn had taken away.
    @Test func aKeyboardFrameDoesNotOutliveTheWindowsSize() {
        #expect(WindowGeometry.keyboardCarriesOver(from: .zero, to: CGSize(width: 669, height: 951)))
        #expect(WindowGeometry.keyboardCarriesOver(from: CGSize(width: 669, height: 951), to: CGSize(width: 669, height: 951)))
        #expect(!WindowGeometry.keyboardCarriesOver(from: CGSize(width: 669, height: 951), to: CGSize(width: 951, height: 669)))
    }

    #if os(iOS)
    /// #537: in the background the system lays the window out again for its snapshot (the open Duo on its side: compact,
    /// 466 × 678). The window's measure is held there and only there; the first one always goes through.
    @Test func theWindowIsHeldOnlyInTheBackground() {
        #expect(WindowGeometry.publishes(.foregroundActive, measured: true))
        #expect(WindowGeometry.publishes(UIScene.ActivationState.background, measured: true) == false)
        #expect(WindowGeometry.publishes(.background, measured: false))   // the first measure, whatever the scene
        // Inactive is still read: the switcher, or an unfocused window still on screen, which can be resized.
        #expect(WindowGeometry.publishes(.foregroundInactive, measured: true))
        #expect(WindowGeometry.publishes(nil, measured: true))   // a window not in a scene yet
    }

    /// #537: `wide`, the reserved regions and the bars' edge keep the last value read outside the background while the
    /// scene is there, and follow the live one again once it leaves; before any, the live one.
    @Test func aValueFromTheWindowHoldsInTheBackground() {
        // On its side, wide; the background's snapshot pass reads compact: still wide until the scene leaves it.
        #expect(WindowGeometry.held(live: false, holding: true, last: true))
        #expect(!WindowGeometry.held(live: false, holding: false, last: true))
        #expect(!WindowGeometry.held(live: false, holding: true, last: nil))
        #expect(WindowGeometry.held(live: true, holding: false, last: nil))
        // A wide window turned upright while the app was away reads one column the moment it leaves the background.
        #expect(!WindowGeometry.held(live: RootView.isWide(regular: true, size: CGSize(width: 669, height: 951)), holding: false, last: true))
        // The bars' edge is itself optional: a held edge stays while the pass reads none, and a held "no edge" stays none.
        let trailing: HorizontalEdge?? = .some(.trailing), noEdge: HorizontalEdge?? = .some(nil)
        #expect(WindowGeometry.held(live: HorizontalEdge?.none, holding: true, last: trailing) == .trailing)
        #expect(WindowGeometry.held(live: Optional(HorizontalEdge.trailing), holding: true, last: noEdge) == nil)
        #expect(WindowGeometry.held(live: Optional(HorizontalEdge.trailing), holding: true, last: nil) == .trailing)   // before any
    }
    #endif

    /// #340: the floating top bar's row gets stage 1's room (the row's bottom, in the bar's space, plus the bar's top
    /// padding and a gap) where the bars stand vertical (the closed Duo) or the status stands in a top corner (the open
    /// Duo upright), with the bar up; nowhere else.
    @Test func theTopBarsRowGetsRoomBesideAStripOrUnderACornerStatus() {
        #expect(TopBarRoom.inset(barsVertical: true, statusInCorner: true, barOn: true, rowBottom: 44) == 56)
        #expect(TopBarRoom.inset(barsVertical: false, statusInCorner: true, barOn: true, rowBottom: 44) == TopBarRoom.cornerRoom)
        #expect(TopBarRoom.cornerRoom == 1)
        #expect(TopBarRoom.inset(barsVertical: true, statusInCorner: false, barOn: true, rowBottom: 41.3) == 53)
        // A phone and an iPad: neither, so nothing, unchanged.
        #expect(TopBarRoom.inset(barsVertical: false, statusInCorner: false, barOn: true, rowBottom: 44) == 0)
        // No bar (a wide window: the iPad, the open Duo on its side), or the row not measured yet.
        #expect(TopBarRoom.inset(barsVertical: false, statusInCorner: true, barOn: false, rowBottom: 44) == 0)
        #expect(TopBarRoom.inset(barsVertical: true, statusInCorner: true, barOn: true, rowBottom: 0) == 0)
    }

    /// The poses the stage 2 probe read, end to end (the rule and the regions together): the closed Duo, the open Duo
    /// upright and like a laptop get the room; on its side (flat or like a book) the window is wide and the bar is off; a
    /// phone with an Island in the middle and an iPad with nothing at the top get none.
    @Test func theRoomInEachPoseTheProbeRead() {
        func room(_ occlusions: [CGRect], width: CGFloat, vertical: Bool, barOn: Bool) -> CGFloat {
            TopBarRoom.inset(barsVertical: vertical, statusInCorner: ReservedRegions(occlusions: occlusions).statusInCorner(width: width), barOn: barOn, rowBottom: 44)
        }
        let closed = [CGRect(x: 400, y: 29, width: 37, height: 37), CGRect(x: 382, y: 0, width: 84, height: 170)]
        let upright = [CGRect(x: 611, y: 677, width: 37, height: 58), CGRect(x: 535, y: 0, width: 134, height: 82)]
        let side = [CGRect(x: 216, y: 611, width: 58, height: 37), CGRect(x: 867, y: 0, width: 84, height: 120)]
        #expect(room(closed, width: 466, vertical: true, barOn: true) == 56)
        #expect(room(upright, width: 669, vertical: false, barOn: true) == 1)   // flat upright, and the laptop pose
        #expect(room(side, width: 951, vertical: true, barOn: false) == 0)      // flat on its side, and the book pose
        #expect(room([CGRect(x: 138, y: 11, width: 126, height: 37)], width: 402, vertical: false, barOn: true) == 0)
        #expect(room([], width: 820, vertical: false, barOn: true) == 0)
    }

    /// #516: a search keeps the navigation bar while it's presented under a status in a top corner only (the open Duo
    /// upright), so the field stays under the row with the corner room; everywhere else the system's own behaviour.
    @Test func aSearchKeepsTheBarOnlyUnderACornerStatus() {
        #expect(TopBarRoom.keepsBarWhileSearching(statusInCorner: true))
        #expect(!TopBarRoom.keepsBarWhileSearching(statusInCorner: false))
        let upright = ReservedRegions(occlusions: [CGRect(x: 611, y: 677, width: 37, height: 58), CGRect(x: 535, y: 0, width: 134, height: 82)])
        #expect(TopBarRoom.keepsBarWhileSearching(statusInCorner: upright.statusInCorner(width: 669)))
        let phone = ReservedRegions(occlusions: [CGRect(x: 0, y: 0, width: 402, height: 54)])
        #expect(!TopBarRoom.keepsBarWhileSearching(statusInCorner: phone.statusInCorner(width: 402)))
        let closed = ReservedRegions(occlusions: [CGRect(x: 382, y: 0, width: 84, height: 170)])
        #expect(!TopBarRoom.keepsBarWhileSearching(statusInCorner: closed.statusInCorner(width: 466)))
    }

    /// The occlusions the stage 2 probe read, in window space: a corner status counts, a camera under the top edge and a
    /// Dynamic Island in the middle don't.
    @Test func aStatusInATopCornerIsSeenFromTheRegions() {
        // The open Duo upright (669 wide): the status corner, and the camera lower down.
        let upright = ReservedRegions(occlusions: [CGRect(x: 535, y: 0, width: 134, height: 82), CGRect(x: 611, y: 677, width: 37, height: 58)])
        #expect(upright.statusInCorner(width: 669))
        // The closed Duo (466 wide): its strip's top is taller than wide, a strip down the side, not a corner (the closed Duo
        // gets its room from its vertical bars); its camera at y 29 doesn't count either.
        #expect(!ReservedRegions(occlusions: [CGRect(x: 382, y: 0, width: 84, height: 170)]).statusInCorner(width: 466))
        #expect(!ReservedRegions(occlusions: [CGRect(x: 400, y: 29, width: 37, height: 37)]).statusInCorner(width: 466))
        // A phone's Dynamic Island: in the middle of the top, against neither side.
        #expect(!ReservedRegions(occlusions: [CGRect(x: 138, y: 11, width: 126, height: 37)]).statusInCorner(width: 402))
        #expect(!ReservedRegions(occlusions: [CGRect(x: 138, y: 0, width: 126, height: 37)]).statusInCorner(width: 402))
        // Nothing reported (anything before iOS 27.1).
        #expect(!ReservedRegions().statusInCorner(width: 1024))
        // An iPad window's own controls stand in its top leading corner (iPadOS 26 on): were a system to report them as an
        // occlusion, they'd be wider than tall at the top edge, against a side, under half the width, and must not count:
        // only the trailing corner does (the open Duo's status at 535 of 669).
        #expect(!ReservedRegions(occlusions: [CGRect(x: 0, y: 0, width: 74, height: 34)]).statusInCorner(width: 744))
        #expect(!ReservedRegions(occlusions: [CGRect(x: 8, y: 0, width: 80, height: 30)]).statusInCorner(width: 1024))
        #expect(ReservedRegions(occlusions: [CGRect(x: 535, y: 0, width: 134, height: 82)]).statusInCorner(width: 669))
        // What iOS 27.2 reports at the top of a phone and an iPad (the readouts, 2026-10-20): one band the window's full
        // width, never a corner, and so no room: the iPhone 17 Pro, the iPhone SE at the largest text, the iPad Air.
        #expect(!ReservedRegions(occlusions: [CGRect(x: 0, y: 0, width: 402, height: 54)]).statusInCorner(width: 402))
        #expect(!ReservedRegions(occlusions: [CGRect(x: 0, y: 0, width: 375, height: 20)]).statusInCorner(width: 375))
        #expect(!ReservedRegions(occlusions: [CGRect(x: 0, y: 0, width: 820, height: 32)]).statusInCorner(width: 820))
        // A narrow window (Split View, Stage Manager): the band spans whatever window it is in, so never under half.
        #expect(!ReservedRegions(occlusions: [CGRect(x: 0, y: 0, width: 320, height: 32)]).statusInCorner(width: 320))
        // The iPad turned to landscape: 27.2 reports its status as a strip 32 wide down a side, the window's full height.
        #expect(!ReservedRegions(occlusions: [CGRect(x: 0, y: 0, width: 32, height: 820)]).statusInCorner(width: 1180))
        #expect(!ReservedRegions(occlusions: [CGRect(x: 1148, y: 0, width: 32, height: 820)]).statusInCorner(width: 1180))
        // Such a strip in a narrow window with the bar up gives no room either.
        #expect(!ReservedRegions(occlusions: [CGRect(x: 0, y: 0, width: 32, height: 820)]).statusInCorner(width: 320))
    }

    #if os(iOS)
    /// #537, #547, #548: only the window a turn of the open Duo passes through is held back (the probe's readings,
    /// 2026-10-28): wide already, with the upright's insets carried over from the measure published before it.
    @Test func onlyATurnsPassingWindowIsHeldBack() {
        let inset = { (t: CGFloat, l: CGFloat, b: CGFloat, r: CGFloat) in EdgeInsets(top: t, leading: l, bottom: b, trailing: r) }
        let upright = CGSize(width: 669, height: 951), side = CGSize(width: 951, height: 669)
        // The open Duo turned on its side right after an upright publish: the passing window is held, the corrected one
        // isn't.
        #expect(WindowGeometry.passing(size: side, safeArea: inset(82, 0, 34, 0), published: upright, publishedSafeArea: inset(82, 0, 34, 0)))
        #expect(!WindowGeometry.passing(size: side, safeArea: inset(0, 0, 34, 84), published: upright, publishedSafeArea: inset(82, 0, 34, 0)))
        // Once a wide measure is published (the corrected one, or the passing one at the hold's limit), no hold.
        #expect(!WindowGeometry.passing(size: side, safeArea: inset(82, 0, 34, 0), published: side, publishedSafeArea: inset(82, 0, 34, 0)))
        // A window already wide, top 60 and no sides (an iPad window with a title bar): settled.
        #expect(!WindowGeometry.passing(size: CGSize(width: 1180, height: 800), safeArea: inset(60, 0, 20, 0),
                                        published: CGSize(width: 1180, height: 800), publishedSafeArea: inset(60, 0, 20, 0)))
        // An iPad turned to landscape, its 24 pt status band both ways: settled.
        #expect(!WindowGeometry.passing(size: CGSize(width: 1180, height: 820), safeArea: inset(24, 0, 20, 0),
                                        published: CGSize(width: 820, height: 1180), publishedSafeArea: inset(24, 0, 20, 0)))
        // Turned back upright, closed, a phone on its side, and the first measure (nothing published yet): settled.
        #expect(!WindowGeometry.passing(size: upright, safeArea: inset(82, 0, 34, 0), published: side, publishedSafeArea: inset(0, 0, 34, 84)))
        #expect(!WindowGeometry.passing(size: CGSize(width: 466, height: 678), safeArea: inset(0, 0, 34, 84), published: side, publishedSafeArea: inset(0, 0, 34, 84)))
        #expect(!WindowGeometry.passing(size: CGSize(width: 874, height: 402), safeArea: inset(0, 62, 21, 62),
                                        published: CGSize(width: 402, height: 874), publishedSafeArea: inset(62, 0, 34, 0)))
        #expect(!WindowGeometry.passing(size: side, safeArea: inset(82, 0, 34, 0), published: .zero, publishedSafeArea: inset(0, 0, 0, 0)))
    }
    #endif
}
