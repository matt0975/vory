import CoreGraphics
import Foundation
import os
import SwiftUI
import Testing
@testable import Vory

/// On the Duo the top bar's rows end where UIKit ends its own trailing navigation item (#554, #555), and the closed row
/// stands even (#558). The numbers are the probe's (2026-10-29, the Duo simulator): UIKit's trailing item ends at 531 on
/// the open Duo upright, at 439 there with another app's Live Activity, at 378 closed (the strip from 382) and at 863 on
/// its side (the strip from 867).
@Suite struct SystemBarItemsTests {
    private func clear(_ width: CGFloat, safeTrailing: CGFloat, item: CGFloat?, fallback: CGFloat = 210) -> CGFloat {
        TopBarRoom.rowTrailingClear(windowWidth: width, safeTrailing: safeTrailing, sideInset: 16, systemItemMaxX: item, fallback: fallback)
    }

    @Test func uprightTheRowEndsWhereUIKitEndsItsItem() {
        // Upright: 669 less 16 less 531, so the row's last control ends at 531, against 443 under the old reserve.
        #expect(clear(669, safeTrailing: 0, item: 531) == 122)
        // With another app's Live Activity UIKit moves its item 92 pt left, and the row ends with it.
        #expect(clear(669, safeTrailing: 0, item: 439) == 214)
        #expect(669 - 16 - clear(669, safeTrailing: 0, item: 439) == 439)
    }

    @Test func closedTheRowEndsBesideTheStrip() {
        // Closed: the bar's space ends at the strip (466 less 84); UIKit's item ends 4 pt short of it, past the bar's 16 pt
        // side inset, so the clear is negative and the row reaches 378.
        #expect(clear(466, safeTrailing: 84, item: 378) == -12)
        #expect(466 - 84 - 16 - clear(466, safeTrailing: 84, item: 378) == 378)
    }

    @Test func untilTheItemIsReadTheOldPlacesStand() {
        // Nothing read yet: up in the band, the old reserve (226 less the inset); closed, nothing.
        #expect(clear(669, safeTrailing: 0, item: nil, fallback: TopBarRoom.statusReserve - 16) == 210)
        #expect(clear(466, safeTrailing: 84, item: nil, fallback: 0) == 0)
    }

    @Test func theClosedRowIsEven() {
        // #558: 11 over the row closed, 4 everywhere else; the bar's lift into the band upright is unchanged (82 + 4 - 26).
        #expect(TopBarRoom.barPadding(closed: true) == 11)
        #expect(TopBarRoom.barPadding(closed: false) == 4)
        #expect(TopBarRoom.lift(barUp: true, safeTop: 82) == 60)
        // The pages' room beside the strip moves with it: the row's bottom (44) + 11 + the 8 pt gap.
        #expect(TopBarRoom.inset(barsVertical: true, statusInCorner: false, barOn: true, rowBottom: 44) == 63)
    }

    @Test func untilTheFoldIsReadTheBarStandsAsItLastStood() {
        // The launch probe (2026-10-31): the fold came about a second after the window, and the bar stepped up when it did.
        #expect(TopBarRoom.barUpAtLaunch(live: false, regionsRead: false, remembered: true))
        #expect(!TopBarRoom.barUpAtLaunch(live: false, regionsRead: false, remembered: false))
        // A shape never seen (a phone, an iPad, a first launch): the live verdict, as before.
        #expect(!TopBarRoom.barUpAtLaunch(live: false, regionsRead: false, remembered: nil))
    }

    @Test func theClosedStripStandsFromTheFirstFrame() {
        // The launch gate (2026-10-31): the system said its bars were vertical 0.1 s after the first layout, and that layout's
        // trailing place (12 pt short) was the one kept until the regions came. Remembered, the strip stands at once.
        #expect(TopBarRoom.stripClosedAtLaunch(live: false, regionsRead: false, remembered: true))
        #expect(!TopBarRoom.stripClosedAtLaunch(live: false, regionsRead: false, remembered: nil))
        #expect(!TopBarRoom.stripClosedAtLaunch(live: false, regionsRead: true, remembered: true))
        #expect(TopBarRoom.stripClosedAtLaunch(live: true, regionsRead: true, remembered: nil))
    }

    @Test func onceTheFoldIsReadTheLiveVerdictStands() {
        #expect(!TopBarRoom.barUpAtLaunch(live: false, regionsRead: true, remembered: true))
        #expect(TopBarRoom.barUpAtLaunch(live: true, regionsRead: true, remembered: false))
        #expect(TopBarRoom.barUpAtLaunch(live: true, regionsRead: true, remembered: nil))
    }
}

#if os(iOS)
/// UIKit's item kept per window shape and across launches (#554): a launch, or a turn into a shape seen before, draws the
/// rows where the bar last stood; only a shape never read falls back to the old places (443 up in the band).
@MainActor @Suite struct SystemBarItemsMemoryTests {
    private let upright = SystemBarItems.shapeKey(size: CGSize(width: 669, height: 951), safeTop: 82, safeTrailing: 0)
    private let closed = SystemBarItems.shapeKey(size: CGSize(width: 466, height: 678), safeTop: 0, safeTrailing: 84)
    private let side = SystemBarItems.shapeKey(size: CGSize(width: 951, height: 669), safeTop: 0, safeTrailing: 84)

    /// A store of its own, gone after the test.
    private func withStore(_ body: (UserDefaults) -> Void) {
        let name = "SystemBarItemsMemoryTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        body(d)
        d.removePersistentDomain(forName: name)
    }

    @Test func theShapeKeyTellsTheDuosPosturesApart() {
        #expect(upright == "669x951 t82 r0")
        #expect(Set([upright, closed, side]).count == 3)
    }

    @Test func aRememberedPlaceIsTakenAtTheNextLaunch() {
        withStore { d in
            SystemBarItems(defaults: d).read(CGRect(x: 487, y: 28, width: 44, height: 40), for: upright)
            let next = SystemBarItems(defaults: d)
            #expect(next.trailing(for: upright) == CGRect(x: 487, y: 28, width: 44, height: 40))
            let clear = TopBarRoom.rowTrailingClear(windowWidth: 669, safeTrailing: 0, sideInset: 16,
                                                    systemItemMaxX: next.trailing(for: upright)?.maxX, fallback: TopBarRoom.statusReserve - 16)
            #expect(669 - 16 - clear == 531)
        }
    }

    @Test func aShapeNeverReadFallsBackTo443() {
        withStore { d in
            let items = SystemBarItems(defaults: d)
            items.read(CGRect(x: 334, y: 28, width: 44, height: 40), for: closed)
            #expect(items.trailing(for: upright) == nil)
            let clear = TopBarRoom.rowTrailingClear(windowWidth: 669, safeTrailing: 0, sideInset: 16,
                                                    systemItemMaxX: items.trailing(for: upright)?.maxX, fallback: TopBarRoom.statusReserve - 16)
            #expect(669 - 16 - clear == 443)
            #expect(items.trailing(for: closed)?.maxX == 378)
        }
    }

    @Test func aLaunchStartsInTheLastSettledWindow() {
        withStore { d in
            let items = SystemBarItems(defaults: d)
            items.settled(size: CGSize(width: 466, height: 678), safeArea: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84))
            items.noteUp(true, for: upright)
            items.noteUp(false, for: closed)
            items.noteClosed(true, for: closed)
            items.noteClosed(false, for: upright)
            let next = SystemBarItems(defaults: d)
            #expect(next.closed(for: closed) == true)
            #expect(next.closed(for: upright) == false)
            #expect(next.closed(for: side) == nil)
            let g = next.launchGeometry()
            #expect(g.seeded)
            #expect(g.bounds == CGRect(x: 0, y: 0, width: 466, height: 678))
            #expect(g.safeArea == EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84))
            // Seeded, the closed window's key is there from the first frame, and with it the strip and UIKit's place.
            #expect(SystemBarItems.shapeKey(size: g.bounds.size, safeTop: g.safeArea.top, safeTrailing: g.safeArea.trailing) == closed)
            #expect(next.up(for: upright) == true)
            #expect(next.up(for: closed) == false)
            #expect(next.up(for: side) == nil)
        }
    }

    /// #617: the moment between, as the Duo opens, says nothing, so the closed shape keeps its strip for the next launch.
    @Test func theMomentBetweenTheBarsAndTheWindowSaysNothing() {
        let strip = EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84), band = EdgeInsets(top: 82, leading: 0, bottom: 34, trailing: 0)
        #expect(SystemBarItems.closedVerdict(barsVertical: true, safeArea: strip) == true)
        #expect(SystemBarItems.closedVerdict(barsVertical: false, safeArea: band) == false)
        // The look at #617 (2026-11-02), every open from closed: the closed window's strip, the bars already along the bottom.
        #expect(SystemBarItems.closedVerdict(barsVertical: false, safeArea: strip) == nil)
        #expect(SystemBarItems.closedVerdict(barsVertical: true, safeArea: band) == nil)
    }

    @Test func aMarkerIsTakenOnlyInTheStrip() {
        // Closed (466 wide, the strip the safe area's right 84, from 382): the probe's markers (399, 238 and 298) stand in it;
        // UIKit's row item (334 to 378) and the 9398bcbe row's More don't.
        #expect(StripMarkers.inStrip(CGRect(x: 399, y: 238, width: 38, height: 38), windowWidth: 466, safeLeading: 0, safeTrailing: 84))
        #expect(!StripMarkers.inStrip(CGRect(x: 334, y: 28, width: 44, height: 40), windowWidth: 466, safeLeading: 0, safeTrailing: 84))
        // On its side (951 wide, the strip from 867): 884.
        #expect(StripMarkers.inStrip(CGRect(x: 884, y: 125, width: 38, height: 38), windowWidth: 951, safeLeading: 0, safeTrailing: 84))
        // A strip on the leading side, and nothing laid out yet.
        #expect(StripMarkers.inStrip(CGRect(x: 23, y: 125, width: 38, height: 38), windowWidth: 951, safeLeading: 84, safeTrailing: 0))
        #expect(!StripMarkers.inStrip(.zero, windowWidth: 466, safeLeading: 0, safeTrailing: 84))
    }

    @Test func theMarkersAreKeptPerShapeAcrossLaunches() {
        withStore { d in
            // The probe's hidden markers closed (38 by 48, Back over More 70 pt apart), then an activity: 80 pt down.
            let markers = StripMarkers(defaults: d), key = StripMarkers.key(shape: closed, withBack: true)
            markers.settled(.back, CGRect(x: 399, y: 238, width: 38, height: 48), for: key)
            markers.settled(.more, CGRect(x: 399, y: 308, width: 38, height: 48), for: key)
            markers.settled(.more, CGRect(x: 399, y: 388, width: 38, height: 48), for: key)
            let next = StripMarkers(defaults: d)
            #expect(next.frame(.back, for: key) == CGRect(x: 399, y: 238, width: 38, height: 48))
            #expect(next.frame(.more, for: key) == CGRect(x: 399, y: 388, width: 38, height: 48))
            #expect(next.frame(.more, for: StripMarkers.key(shape: side, withBack: true)) == nil)
        }
    }

    @Test func onItsSideBesideTheListMoreIsKeptOnItsOwn() {
        withStore { d in
            // With the list beside the chat there's no Back marker and More takes its place (884, 125); with the list
            // hidden, Back stands there and More under it (195). The same window, two keys.
            let markers = StripMarkers(defaults: d)
            let solo = StripMarkers.key(shape: side, withBack: false), both = StripMarkers.key(shape: side, withBack: true)
            #expect(solo != both)
            markers.settled(.more, CGRect(x: 884, y: 125, width: 38, height: 48), for: solo)
            markers.settled(.back, CGRect(x: 884, y: 125, width: 38, height: 48), for: both)
            markers.settled(.more, CGRect(x: 884, y: 195, width: 38, height: 48), for: both)
            #expect(markers.frame(.more, for: solo)?.minY == 125)
            #expect(markers.frame(.more, for: both)?.minY == 195)
            #expect(markers.frame(.back, for: solo) == nil)
        }
    }

    /// The same objects, in the same order.
    private func same(_ a: [AnyObject], _ b: [AnyObject]) -> Bool { a.elementsEqual(b, by: ===) }

    @Test func besideTheListThePageCarriesMoreAlone() {
        // Beside the list the page's bar carries More alone (the system then stands it in Back's place, the first slot);
        // with the list hidden, Back and More. They're set again only when something replaced them.
        let i = UINavigationItem(), back = UIBarButtonItem(title: "Back", image: nil), more = UIBarButtonItem(title: "Chat options", image: nil)
        StripMarkerReader.install(on: i, back: false, backItem: back, moreItem: more)
        #expect(i.leadingItemGroups.isEmpty)
        #expect(same(i.trailingItemGroups.flatMap(\.barButtonItems), [more]))
        StripMarkerReader.install(on: i, back: true, backItem: back, moreItem: more)
        #expect(same(i.leadingItemGroups.flatMap(\.barButtonItems), [back]))
        let groups = i.leadingItemGroups + i.trailingItemGroups
        StripMarkerReader.install(on: i, back: true, backItem: back, moreItem: more)
        #expect(same(i.leadingItemGroups + i.trailingItemGroups, groups))
        // A rebuilt navigation item (a turn) has lost them: the next read sets them again.
        i.trailingItemGroups = []
        StripMarkerReader.install(on: i, back: true, backItem: back, moreItem: more)
        #expect(same(i.trailingItemGroups.flatMap(\.barButtonItems), [more]))
    }

    @Test func onlyTheMarkersOwnViewsAreFound() {
        // The strip as the system draws it: our markers' buttons at their frames, and things that share only a label or only
        // a frame with them. In a window, as the app's are: the frames are read in window space.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
        let root = UIView(frame: window.bounds), strip = UIView(frame: CGRect(x: 382, y: 0, width: 84, height: 678))
        window.addSubview(root)
        root.addSubview(strip)
        func control(_ label: String, _ frame: CGRect, in host: UIView) -> UIControl {
            let c = UIControl(frame: frame.offsetBy(dx: -host.frame.minX, dy: -host.frame.minY))
            c.accessibilityLabel = label
            host.addSubview(c)
            return c
        }
        let back = control("Back", CGRect(x: 399, y: 238, width: 38, height: 48), in: strip)
        let more = control("Chat options", CGRect(x: 399, y: 308, width: 38, height: 48), in: strip)
        _ = control("Back", CGRect(x: 16, y: 11, width: 44, height: 44), in: root)          // our own Back: elsewhere
        _ = control("Hide Sidebar", CGRect(x: 399, y: 238, width: 38, height: 48), in: root) // the frame, not the label
        let label = UILabel(frame: CGRect(x: 17, y: 238, width: 38, height: 48))            // the label, not a control
        label.accessibilityLabel = "Back"
        strip.addSubview(label)
        let targets = [("Back", CGRect(x: 399, y: 238, width: 38, height: 48)), ("Chat options", CGRect(x: 399, y: 308, width: 38, height: 48))]
        let found = StripMarkerReader.markerViews(in: root, targets: targets)
        #expect(found.count == 2)
        #expect(same(found, [back, more]))
        // A point off is still the marker; two points off isn't.
        #expect(StripMarkerReader.markerViews(in: root, targets: [("Back", CGRect(x: 400, y: 239, width: 38, height: 48))]).count == 1)
        #expect(StripMarkerReader.markerViews(in: root, targets: [("Back", CGRect(x: 401, y: 238, width: 38, height: 48))]).isEmpty)
        // Below the depth limit nothing is walked.
        #expect(StripMarkerReader.markerViews(in: root, targets: targets, depth: 0).isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test func theMarkersViewsLeaveAccessibilityAndNothingElse() {
        // The system's marker: a control with the label inside it standing as an element (the accessibility audit,
        // 2026-10-31), and beside it in the strip a view of someone else's that is one. In a window, found as the app finds
        // them.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
        let root = UIView(frame: window.bounds), strip = UIView(frame: CGRect(x: 382, y: 0, width: 84, height: 678))
        window.addSubview(root)
        root.addSubview(strip)
        let marker = UIControl(frame: CGRect(x: 17, y: 238, width: 38, height: 48))
        marker.accessibilityLabel = "Back"
        strip.addSubview(marker)
        let label = UILabel(frame: marker.bounds), glyph = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        label.text = "Back"
        label.isAccessibilityElement = true
        marker.addSubview(label)
        label.addSubview(glyph)
        let other = UILabel(frame: CGRect(x: 17, y: 400, width: 38, height: 20))
        other.isAccessibilityElement = true
        strip.addSubview(other)
        let views = StripMarkerReader.markerViews(in: root, targets: [("Back", CGRect(x: 399, y: 238, width: 38, height: 48))])
        #expect(same(views, [marker]))
        let before = [marker, label, glyph].map { ($0.isAccessibilityElement, $0.accessibilityElementsHidden) }

        let taken = StripMarkerReader.takeAccessibility(from: views)
        #expect(taken.count == 3)
        for v in [marker, label, glyph] {
            #expect(!v.isAccessibilityElement)
            #expect(v.accessibilityElementsHidden)
        }
        // Nothing above or beside them changes.
        #expect(!strip.accessibilityElementsHidden)
        #expect(!root.accessibilityElementsHidden)
        #expect(other.isAccessibilityElement && !other.accessibilityElementsHidden)

        // The system sets the label back up: the next read takes it again, and records nothing twice.
        label.isAccessibilityElement = true
        #expect(StripMarkerReader.takeAccessibility(from: views, taken: taken).isEmpty)
        #expect(!label.isAccessibilityElement)

        // Given back as they stood.
        StripMarkerReader.giveAccessibility(taken)
        let after = [marker, label, glyph].map { ($0.isAccessibilityElement, $0.accessibilityElementsHidden) }
        #expect(after.elementsEqual(before, by: ==))
        withExtendedLifetime(window) {}
    }

    @Test func beforeAnyPlaceIsReadTheMeasuredOnesStand() {
        // The system's own places at default text with no Live Activity (measured on the Duo, 2026-10-31): our 44 pt tops,
        // centred on its 48 pt items. Closed, with no room on the Chats stack (#591, 2026-11-02), at XXXL as at default; on
        // its side More alone stood where it does at default.
        #expect(StripMarkers.fallbackTops(closed: true, withBack: true, xxxl: false) == [177, 247])
        #expect(StripMarkers.fallbackTops(closed: true, withBack: true, xxxl: true) == [177, 247])
        #expect(StripMarkers.fallbackTops(closed: false, withBack: true, xxxl: false) == [127, 197])
        #expect(StripMarkers.fallbackTops(closed: false, withBack: false, xxxl: false) == [127])
        #expect(StripMarkers.fallbackTops(closed: false, withBack: false, xxxl: true) == [127])
        // On its side with Back at XXXL wasn't measured: the default.
        #expect(StripMarkers.fallbackTops(closed: false, withBack: true, xxxl: true) == [127, 197])
        withStore { d in
            let markers = StripMarkers(defaults: d), g = WindowGeometry()
            // Closed (the strip on the right, its middle 48 from the edge, where the system's 38 pt items stood at 399).
            g.bounds = CGRect(x: 0, y: 0, width: 466, height: 678)
            g.safeArea = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 84)
            #expect(markers.centre(.back, in: g, withBack: true, closed: true, xxxl: false) == CGPoint(x: 418, y: 199))
            #expect(markers.centre(.more, in: g, withBack: true, closed: true, xxxl: false) == CGPoint(x: 418, y: 269))
            #expect(markers.centre(.more, in: g, withBack: true, closed: true, xxxl: true) == CGPoint(x: 418, y: 269))
            // A settled place wins, for its own shape only.
            markers.settled(.more, CGRect(x: 399, y: 388, width: 38, height: 48), for: StripMarkers.key(shape: closed, withBack: true))
            #expect(markers.centre(.more, in: g, withBack: true, closed: true, xxxl: false) == CGPoint(x: 418, y: 412))
            // On its side: Back over More with the list hidden, More alone in Back's place beside it.
            g.bounds = CGRect(x: 0, y: 0, width: 951, height: 669)
            #expect(markers.centre(.back, in: g, withBack: true, closed: false, xxxl: false) == CGPoint(x: 903, y: 149))
            #expect(markers.centre(.more, in: g, withBack: true, closed: false, xxxl: false) == CGPoint(x: 903, y: 219))
            #expect(markers.centre(.more, in: g, withBack: false, closed: false, xxxl: false) == CGPoint(x: 903, y: 149))
            // The strip on the left: its middle 48 from the left edge.
            g.safeArea = EdgeInsets(top: 0, leading: 84, bottom: 0, trailing: 0)
            #expect(markers.centre(.more, in: g, withBack: false, closed: false, xxxl: false).x == 48)
        }
    }

    /// The settled place (`StripMarkers.Settle`): taken once it has stood 250 ms with no change.
    private let a0 = CGRect(x: 399, y: 238, width: 38, height: 48), transient = CGRect(x: 399, y: 175, width: 38, height: 48)

    @Test func closingThePassingPlaceIsNeverTaken() {
        // The probe's close (2026-10-31): nothing laid out, then a frame off the strip (nil), 175 at 0.18 s, 238 at 0.32 s.
        var s = StripMarkers.Settle()
        do { let changed = s.note(nil, at: 0); #expect(!changed) }
        do { let changed = s.note(nil, at: 0.07); #expect(!changed) }
        do { let changed = s.note(transient, at: 0.18); #expect(changed) }
        #expect(s.due(at: 0.32) == nil)
        do { let changed = s.note(a0, at: 0.32); #expect(changed) }
        // 250 ms after 175 it's long gone; 238 isn't due until 250 ms after it came.
        #expect(s.due(at: 0.43) == nil)
        #expect(s.due(at: 0.56) == nil)
        #expect(s.due(at: 0.57) == a0)
    }

    @Test func aPlaceTheSystemStopsAtIsTaken() {
        // From its side to closed the system's items stayed at 175: ours stand there too.
        var s = StripMarkers.Settle()
        do { let changed = s.note(transient, at: 10); #expect(changed) }
        #expect(s.due(at: 10.2) == nil)
        #expect(s.due(at: 10.25) == transient)
        // Read again there, nothing changes and it stays due.
        do { let changed = s.note(transient, at: 10.25); #expect(!changed) }
        #expect(s.due(at: 11) == transient)
    }

    @Test func anActivityMovesThePlaceOnce() {
        // One activity arrives: 238 to 318, taken once it has stood.
        var s = StripMarkers.Settle()
        do { let changed = s.note(a0, at: 0); #expect(changed) }
        #expect(s.due(at: 0.25) == a0)
        let p1 = a0.offsetBy(dx: 0, dy: 80)
        do { let changed = s.note(p1, at: 5); #expect(changed) }
        #expect(s.due(at: 5.1) == nil)
        #expect(s.due(at: 5.25) == p1)
        do { let changed = s.note(p1, at: 5.3); #expect(!changed) }
    }

    @Test func aReadOffTheStripStartsTheWaitAgain() {
        // Off the strip (to overflow, or not laid out) is never a place: the last kept one stands, and the wait starts over.
        var s = StripMarkers.Settle()
        do { let changed = s.note(a0, at: 0); #expect(changed) }
        do { let changed = s.note(nil, at: 0.1); #expect(changed) }
        #expect(s.due(at: 0.3) == nil)
        do { let changed = s.note(a0, at: 0.4); #expect(changed) }
        #expect(s.due(at: 0.6) == nil)
        #expect(s.due(at: 0.65) == a0)
    }

    @Test func aWindowNeverSettledOnTheDuoLaunchesEmpty() {
        withStore { d in
            let g = SystemBarItems(defaults: d).launchGeometry()
            #expect(!g.seeded)
            #expect(g.bounds == .zero)
            // An empty window is never kept.
            let items = SystemBarItems(defaults: d)
            items.settled(size: .zero, safeArea: EdgeInsets())
            #expect(SystemBarItems(defaults: d).lastWindow == nil)
        }
    }

    @Test func theMarkersAreReadOnlyInFront() {
        // Read into values first: inside #expect, `.background` alone led the macro to a call whose result it dropped
        // (the units, 2026-11-01).
        let states: [UIScene.ActivationState?] = [.foregroundActive, .foregroundInactive, .background, .unattached, nil]
        // Never on the way out (the switcher's picture), in the background, or before a scene is there.
        let reads = states.map { StripMarkers.reads($0) }
        #expect(reads == [true, false, false, false, false])
        // The tick: on its side with the chat on show, the reader on screen and the app in front; closed and upright
        // (not on its side), off screen or out of front, never.
        let ticks = states.map { StripMarkers.ticks($0, onSide: true, shown: true) }
        #expect(ticks == [true, false, false, false, false])
        let offSide = StripMarkers.ticks(.foregroundActive, onSide: false, shown: true)
        let offScreen = StripMarkers.ticks(.foregroundActive, onSide: true, shown: false)
        #expect(offSide == false)
        #expect(offScreen == false)
    }

    @Test func aTickThatFindsTheSamePlaceChangesNothing() {
        // On its side the tick reads twice a second. One that finds More where it was kept writes nothing: not the page's
        // items, not the store, not the places SwiftUI draws from (a write there would draw the bar again).
        let name = "SystemBarItemsMemoryTests-\(UUID().uuidString)"
        let d = CountingDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let markers = StripMarkers(defaults: d), key = StripMarkers.key(shape: side, withBack: false)
        let i = UINavigationItem(), back = UIBarButtonItem(title: "Back", image: nil), more = UIBarButtonItem(title: "Chat options", image: nil)
        let p = CGRect(x: 884, y: 125, width: 38, height: 48)
        var s = StripMarkers.Settle()
        StripMarkerReader.install(on: i, back: false, backItem: back, moreItem: more)
        do { let changed = s.note(p, at: 0); #expect(changed) }
        if let f = s.due(at: 0.25) { markers.settled(.more, f, for: key) }
        #expect(d.writes == 1)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = (markers.byShape, markers.side, markers.pressed) } onChange: { changes.withLock { $0 += 1 } }
        // Ten seconds of ticks with More where it was: nothing set, no change noted (so no check follows), nothing kept
        // (even a check that came anyway).
        for n in 1...20 {
            let at = 0.25 + Double(n) * StripMarkers.tickEvery
            #expect(!StripMarkerReader.install(on: i, back: false, backItem: back, moreItem: more))
            do { let changed = s.note(p, at: at); #expect(!changed) }
            #expect(s.due(at: at) == p)
            markers.settled(.more, p, for: key)
        }
        #expect(d.writes == 1)
        #expect(changes.withLock { $0 } == 0)
        // An activity moves it 92 pt: that place is kept once it has stood, and written once.
        let moved = p.offsetBy(dx: 0, dy: 92)
        do { let changed = s.note(moved, at: 11); #expect(changed) }
        #expect(s.due(at: 11.1) == nil)
        if let f = s.due(at: 11.25) { markers.settled(.more, f, for: key) }
        #expect(d.writes == 2)
        #expect(changes.withLock { $0 } == 1)
        #expect(markers.frame(.more, for: key) == moved)
    }

    @Test func noTickOutlivesItsChatOnTheSide() {
        let reader = StripMarkerReader.Reader()
        // Off screen it never starts.
        reader.onSide = true
        #expect(reader.tick == nil)
        // Running, it stops when the chat leaves the side (closed, upright, another tab)...
        reader.runTick(true)
        let first = reader.tick
        #expect(first != nil)
        reader.onSide = false
        #expect(reader.tick == nil)
        #expect(first?.isCancelled == true)
        // ...and when the page goes.
        reader.onSide = true
        reader.runTick(true)
        let second = reader.tick
        #expect(second != nil)
        reader.viewDidDisappear(false)
        #expect(reader.tick == nil)
        #expect(second?.isCancelled == true)
    }

    @Test func outOfFrontACheckKeepsWhatWasReadInFront() {
        // Closed, the system moved Back back to 238 while the app was in front, and the app left 170 ms later, inside the
        // settle (2026-11-01). Its check comes with the app inactive: the place read in front is kept, and nothing is read.
        let p = CGRect(x: 399, y: 238, width: 38, height: 48)
        var reads = 0
        var s = StripMarkers.Settle()
        do { let changed = s.note(p, at: 0); #expect(changed) }
        let inactive = StripMarkers.check(&s, state: UIScene.ActivationState.foregroundInactive, at: 0.25) { reads += 1; return nil }
        #expect(inactive == StripMarkers.Check.keep(p))
        // Not yet due, it's forgotten, so the return's read starts the wait again.
        var early = StripMarkers.Settle()
        do { let changed = early.note(p, at: 0); #expect(changed) }
        let away = StripMarkers.check(&early, state: UIScene.ActivationState.background, at: 0.1) { reads += 1; return nil }
        #expect(away == StripMarkers.Check.forget)
        #expect(early.place == nil)
        do { let changed = early.note(p, at: 5); #expect(changed) }
        // Out of front, the check never read the marker.
        #expect(reads == 0)
        // In front it reads again: the same place is kept; a new one waits again; off the strip, nothing is kept.
        var front = StripMarkers.Settle()
        do { let changed = front.note(p, at: 0); #expect(changed) }
        let same = StripMarkers.check(&front, state: UIScene.ActivationState.foregroundActive, at: 0.25) { reads += 1; return p }
        #expect(same == StripMarkers.Check.keep(p))
        let moved = StripMarkers.check(&front, state: UIScene.ActivationState.foregroundActive, at: 0.5) { reads += 1; return p.offsetBy(dx: 0, dy: 80) }
        #expect(moved == StripMarkers.Check.again)
        let off = StripMarkers.check(&front, state: UIScene.ActivationState.foregroundActive, at: 0.75) { reads += 1; return nil }
        #expect(off == StripMarkers.Check.again)
        let gone = StripMarkers.check(&front, state: UIScene.ActivationState.foregroundActive, at: 1.0) { reads += 1; return nil }
        #expect(gone == StripMarkers.Check.off)
        #expect(reads == 4)
    }
}

/// A store that counts its writes.
private final class CountingDefaults: UserDefaults {
    var writes = 0
    override func set(_ value: Any?, forKey defaultName: String) {
        writes += 1
        super.set(value, forKey: defaultName)
    }
}

/// #615: across a fold the page going and the page coming show the same chat; each takes away only its own side state.
@MainActor @Suite struct StripSideTests {
    private final class Chat {}

    /// Markers with a store of their own, gone after the test.
    private func withMarkers(_ body: (StripMarkers) -> Void) {
        let name = "StripSideTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        body(StripMarkers(defaults: d))
        d.removePersistentDomain(forName: name)
    }

    @Test func thePageGoingLeavesThePageComing() {
        let chat = Chat(), id = ObjectIdentifier(chat)
        withMarkers { m in
            // The page coming, beside the list; then the page going, full width, last; then the page going goes.
            let coming = UUID(), going = UUID()
            m.publish(.init(chat: id, withBack: false), page: coming)
            m.publish(.init(chat: id, withBack: true), page: going)
            #expect(m.side == .init(chat: id, withBack: true))
            m.publish(nil, page: going)
            #expect(m.side == .init(chat: id, withBack: false))
            m.publish(nil, page: coming)
            #expect(m.side == nil)
        }
        withMarkers { m in
            // The other order: the page going first, then the page coming; the page going's nil leaves it.
            let coming = UUID(), going = UUID()
            m.publish(.init(chat: id, withBack: true), page: going)
            m.publish(.init(chat: id, withBack: false), page: coming)
            m.publish(nil, page: going)
            #expect(m.side == .init(chat: id, withBack: false))
        }
    }

    @Test func aPressEndsWhenItsSideGoes() {
        let chat = Chat(), id = ObjectIdentifier(chat)
        withMarkers { m in
            let page = UUID()
            m.publish(.init(chat: id, withBack: false), page: page)
            m.pressed = .more
            m.publish(.init(chat: id, withBack: false), page: page)
            #expect(m.pressed == .more)
            m.publish(nil, page: page)
            #expect(m.pressed == nil && m.side == nil)
        }
    }
}
#endif
