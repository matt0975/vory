import CoreGraphics
import Foundation
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
}
#endif
