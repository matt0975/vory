import CoreGraphics
import Testing
@testable import Vory

/// The open Duo upright's top bar up in the status band (#516): keyed on the window (a fold reported across it, active or
/// not; taller than wide; a top safe area deep enough for the row), never on a status region. The fixtures are Matt's 38
/// readouts of his Duo (iOS 27.2), the simulator's, and an iPhone 18 Pro, which must leave the bar where it is.
@Suite struct BarUpTests {
    private typealias Reported = ReservedRegions.Reported
    /// Every pose of the device reports this, inactive (the readouts' "Covered area").
    private let covered = Reported(kind: .occlusion, frame: CGRect(x: 22.4, y: 230.4, width: 39.5, height: 62), active: false)
    private let upright = CGSize(width: 669, height: 951)
    private let onItsSide = CGSize(width: 951, height: 669)

    private func barUp(_ reported: [Reported], _ size: CGSize, safeTop: CGFloat, occlusions: [CGRect] = []) -> Bool {
        TopBarRoom.barUp(regions: ReservedRegions(occlusions: occlusions, reported: reported), size: size, safeTop: safeTop)
    }

    @Test func theDuoUprightOnTheDevice() {
        // Open flat: the fold across the window, inactive; half open like a laptop: the same fold, active.
        let flat = Reported(kind: .fold, frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), active: false)
        let laptop = Reported(kind: .fold, frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), active: true)
        #expect(barUp([flat, covered], upright, safeTop: 82))
        #expect(barUp([laptop, covered], upright, safeTop: 82))
        // The row: 26 to 70, inside the 82 pt band; the bar 60 pt higher than its place under the safe area (82 + 4).
        #expect(TopBarRoom.bandRowTop + TopBarRoom.bandRowHeight <= 82)
        #expect(TopBarRoom.lift(barUp: true, safeTop: 82) == 60)
        // Its trailing edge at 443 or before, at least 8 pt clear of the status's left edge in each readout (476, 553).
        let trailing = upright.width - TopBarRoom.statusReserve
        #expect(trailing <= 443)
        for statusLeft: CGFloat in [476, 553] { #expect(statusLeft - trailing >= 8) }
        // A search keeps the bar there, so the field doesn't ride up into the band under the row.
        #expect(TopBarRoom.keepsBarWhileSearching(statusInCorner: false, barUp: true))
    }

    @Test func theSimulatorUpright() {
        // The simulator also reports the status in the top trailing corner: the bar goes up the same, on the window alone.
        let fold = Reported(kind: .fold, frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), active: false)
        let corner = CGRect(x: 535, y: 0, width: 134, height: 82)
        #expect(barUp([fold, Reported(kind: .occlusion, frame: corner, active: true)], upright, safeTop: 82, occlusions: [corner]))
        #expect(corner.minX >= upright.width - TopBarRoom.statusReserve + 8, "the row clears the simulator's corner too")
        // The corner's room only where the bar isn't up and the window is taller than wide (#548): the upright's corner
        // still reported once the window is on its side gives none.
        let regions = ReservedRegions(occlusions: [corner])
        #expect(TopBarRoom.statusCorner(barUp: false, regions: regions, size: upright))
        #expect(!TopBarRoom.statusCorner(barUp: true, regions: regions, size: upright))
        #expect(!TopBarRoom.statusCorner(barUp: false, regions: ReservedRegions(occlusions: [CGRect(x: 817, y: 0, width: 134, height: 82)]), size: onItsSide))
    }

    @Test func everythingElseLeavesTheBarWhereItIs() {
        // Matt's iPhone 18 Pro: no regions, safe top 62. The bar stays put and nothing moves.
        #expect(!barUp([], CGSize(width: 402, height: 874), safeTop: 62))
        #expect(TopBarRoom.lift(barUp: false, safeTop: 62) == 0)
        #expect(!TopBarRoom.keepsBarWhileSearching(statusInCorner: false, barUp: false), "a phone's search keeps the system's own way")
        // The Duo on its side, open flat or half open like a book: the fold runs up the window.
        let upFold = Reported(kind: .fold, frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), active: false)
        #expect(!barUp([upFold, covered], onItsSide, safeTop: 0))
        #expect(!barUp([Reported(kind: .fold, frame: upFold.frame, active: true), covered], onItsSide, safeTop: 0))
        // The Duo closed: no fold, its status in the side strip.
        #expect(!barUp([covered], CGSize(width: 466, height: 678), safeTop: 0))
        // An iPad Air: no fold.
        #expect(!barUp([], CGSize(width: 820, height: 1180), safeTop: 24))
        // A fold across a window whose top safe area can't hold the row, or one wider than tall: no.
        let across = Reported(kind: .fold, frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), active: false)
        #expect(!barUp([across], upright, safeTop: 62))
        #expect(!barUp([across], CGSize(width: 951, height: 669), safeTop: 82))
        // A status region alone never puts the bar up (the trigger is the fold).
        #expect(!barUp([Reported(kind: .occlusion, frame: CGRect(x: 535, y: 0, width: 134, height: 82), active: true)], upright, safeTop: 82))
    }
}
