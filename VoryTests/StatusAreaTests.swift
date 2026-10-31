import CoreGraphics
import Testing
@testable import Vory

/// The status area as the layout reads it (#516): the open Duo upright's corner, or why none was found, on made-up
/// regions; `statusInCorner` says the same as the reading, so Screen layout shows what the layout decided.
@Suite struct StatusAreaTests {
    private let width: CGFloat = 669
    private func read(_ occlusions: [CGRect]) -> ReservedRegions.StatusArea {
        ReservedRegions(occlusions: occlusions).statusArea(width: width)
    }

    @Test func theSimulatorsCornerIsFound() {
        let corner = CGRect(x: 535, y: 0, width: 134, height: 82)
        #expect(read([corner]) == .corner(corner))
        #expect(ReservedRegions(occlusions: [corner]).statusInCorner(width: width))
    }

    @Test func eachOtherShapeSaysWhy() {
        #expect(read([]) == .notFound("No area reported"))
        #expect(read([CGRect(x: 535, y: 10, width: 134, height: 82)]) == .notFound("None at the top edge"))
        #expect(read([CGRect(x: 0, y: 0, width: 669, height: 47)]) == .notFound("Half the window's width or wider"), "a band")
        #expect(read([CGRect(x: 535, y: 0, width: 134, height: 160)]) == .notFound("Not wider than tall"))
        #expect(read([CGRect(x: 400, y: 0, width: 134, height: 82)]) == .notFound("Not against the right edge"))
        for o in [[], [CGRect(x: 0, y: 0, width: 669, height: 47)], [CGRect(x: 535, y: 0, width: 134, height: 160)]] {
            #expect(!ReservedRegions(occlusions: o).statusInCorner(width: width))
        }
    }

    @Test func twoAreasAtTheTop() {
        let corner = CGRect(x: 535, y: 0, width: 134, height: 82)
        #expect(read([CGRect(x: 0, y: 0, width: 669, height: 20), corner]) == .corner(corner), "a corner beside a band")
        #expect(read([CGRect(x: 535, y: 0, width: 134, height: 160), CGRect(x: 535, y: 0, width: 60, height: 90)])
                == .notFound("Not wider than tall (the first of 2 at the top edge)"))
    }

    #if os(iOS)
    /// On the main actor: ScreenLayoutView is a View, so its statics are the main actor's (their closures check it).
    @Test @MainActor func screenLayoutsPoints() {
        #expect(ScreenLayoutView.points(669) == "669 pt")
        #expect(ScreenLayoutView.points(455.5) == "455.5 pt")
        #expect(ScreenLayoutView.points(0.04) == "0 pt")
        #expect(ScreenLayoutView.size(CGSize(width: 669, height: 951)) == "669 × 951 pt")
        // The front tab's room, and a root that differs named after it.
        #expect(ScreenLayoutView.room(front: .settings, rooms: [:]) == "Not applied yet")
        #expect(ScreenLayoutView.room(front: .settings, rooms: [.settings: 1, .chats: 1]) == "1 pt")
        #expect(ScreenLayoutView.room(front: .settings, rooms: [.settings: 1, .chats: 0]) == "1 pt (Chats 0 pt)")
    }
    #endif
}
