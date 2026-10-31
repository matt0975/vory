import CoreGraphics
import SwiftUI
import Testing
import VoryCore
@testable import Vory

/// The fold of a half-open iPhone Duo (Duo stage 2): how far the composer's lists may grow under
/// a fold across the window, when the dock lifts over it, where the list column ends at a fold
/// up the window, how a floating piece steps off the fold, and Home's tiles on a window that folds.
/// Window space throughout: the open Duo's 669 x 951 window upright (the laptop pose folds it
/// across) and 951 x 669 on its side (the book pose folds it up the middle).
/// Expected values are CGFloat (`m` makes each sum one): an untyped sum on the right of `#expect`'s
/// `==` is an Int there, and 206.0 against 206 compared false.
@Suite struct FoldLayoutTests {
    /// The fold across the window as the Duo reports it in the laptop pose (the probe, 2026-10-20): a 40 pt band at y 456
    /// to 496, the hinge line at 476 with Apple's 20 pt margin either side already in the frame.
    let laptop = ReservedRegions(divisions: [CGRect(x: 0, y: 456, width: 669, height: 40)])
    /// The fold up the window in the book pose: x 456 to 496.
    let book = ReservedRegions(divisions: [CGRect(x: 456, y: 0, width: 40, height: 669)])
    let none = ReservedRegions()
    /// Our own margin beyond the frame (0 since the probe: the frame carries Apple's).
    let m = ReservedRegions.margin

    // MARK: The room under a fold

    @Test func underAFoldAcrossTheWindowAListMayGrowUpToTheFoldLessTheMargin() {
        #expect(laptop.room(under: 700) == 700 - 496 - m)
    }

    @Test func noFloorCrossesTheFold() {
        // The 10-12 round: the + panel took its 180 pt floor with about 60 pt of room and opened
        // across the fold. Room under the fold is what is there, down to none at all.
        #expect(laptop.room(under: 556 + m) == 60)
        #expect(laptop.room(under: 490) == 0)
    }

    @Test func noRoomLimitAboveTheFoldOrWithoutOne() {
        #expect(laptop.room(under: 300) == nil)
        #expect(book.room(under: 700) == nil)
        #expect(none.room(under: 700) == nil)
    }

    // MARK: The dock's lift

    /// A 70 pt dock with its bottom edge at `bottom`.
    func dock(bottom: CGFloat) -> CGRect { CGRect(x: 0, y: bottom - 70, width: 669, height: 70) }

    @Test func aDockOnTheFoldLiftsToTheMarginAboveIt() {
        // The keyboard has pushed the dock onto the fold: its bottom ends the margin above the fold's frame.
        let lift = laptop.dockLift(dock: dock(bottom: 520))
        #expect(lift == 520 - 456 + m)
        #expect(dock(bottom: 520).maxY - lift == 456 - m)
    }

    @Test func aDockJustAboveTheFoldMovesUpToTheMargin() {
        #expect(laptop.dockLift(dock: dock(bottom: 460)) == 4 + m)
        #expect(laptop.dockLift(dock: dock(bottom: 456 - m)) == 0)
    }

    @Test func aDockUnderTheFoldStaysWithNoListOpen() {
        #expect(laptop.dockLift(dock: dock(bottom: 917)) == 0)
    }

    @Test func aListThatFitsUnderTheFoldLeavesTheDockWhereItIs() {
        // The "/" list's top at 600: well under the fold's 496 plus the margin.
        #expect(laptop.dockLift(dock: dock(bottom: 917), listTop: 600) == 0)
    }

    @Test func aListThatWouldCrossTheFoldLiftsTheDockOverIt() {
        // The + panel at full size would reach up to y 400, across the fold: the dock goes over
        // the fold (its bottom the margin above it) while the panel is open.
        let lift = laptop.dockLift(dock: dock(bottom: 917), listTop: 400)
        #expect(lift == 917 - 456 + m)
        // Its top reaching to the margin under the fold is already too far.
        #expect(laptop.dockLift(dock: dock(bottom: 917), listTop: 495 + m) > 0)
        #expect(laptop.dockLift(dock: dock(bottom: 917), listTop: 496 + m) == 0)
    }

    @Test func aLiftForAnOpenListHoldsUntilTheListCloses() {
        // Lifted, the list gets the whole room above and reports a different reach: held, the
        // dock stays up rather than dropping back under it.
        #expect(laptop.dockLift(dock: dock(bottom: 917), listTop: 600, held: true) == 917 - 456 + m)
        // Closed (no list), the hold no longer counts.
        #expect(laptop.dockLift(dock: dock(bottom: 917), listTop: nil, held: true) == 0)
    }

    @Test func aDockAboveTheFoldNeverMovesForAList() {
        #expect(laptop.dockLift(dock: dock(bottom: 400), listTop: 100) == 0)
        #expect(laptop.dockLift(dock: dock(bottom: 400), listTop: 100, held: true) == 0)
    }

    @Test func noFoldAcrossTheWindowNoLift() {
        #expect(book.dockLift(dock: dock(bottom: 520), listTop: 100) == 0)
        #expect(none.dockLift(dock: dock(bottom: 520), listTop: 100) == 0)
        #expect(laptop.dockLift(dock: .zero) == 0)
    }

    // MARK: The list column at a fold up the window

    @Test func theListColumnEndsAtTheFoldsMiddle() {
        #expect(book.listWidth(leading: 0, range: 280...480) == 476)
        // A bar down the leading side moves the split view in: the column is narrower.
        #expect(book.listWidth(leading: 84, range: 280...480) == 392)
    }

    @Test func aFoldOutsideTheColumnsRangeLeavesTheUsualWidth() {
        let early = ReservedRegions(divisions: [CGRect(x: 200, y: 0, width: 20, height: 669)])
        #expect(early.listWidth(leading: 0, range: 280...480) == nil)
        let late = ReservedRegions(divisions: [CGRect(x: 600, y: 0, width: 20, height: 669)])
        #expect(late.listWidth(leading: 0, range: 280...480) == nil)
    }

    @Test func noFoldUpTheWindowNoListWidth() {
        #expect(laptop.listWidth(leading: 0, range: 280...480) == nil)
        #expect(none.listWidth(leading: 0, range: 280...480) == nil)
    }

    // MARK: Stepping off the fold

    @Test func aPieceClearOfTheFoldStaysPut() {
        let fold = CGRect(x: 466, y: 0, width: 20, height: 669)
        #expect(FoldAvoidance.offset(for: CGRect(x: 100, y: 10, width: 200, height: 40), fold: fold, in: 951) == 0)
        #expect(FoldAvoidance.offset(for: CGRect(x: 380, y: 10, width: 200, height: 40), fold: nil, in: 951) == 0)
    }

    @Test func aPieceOnTheFoldStepsToTheRoomierSide() {
        // More room to the right of the fold: the piece's leading edge goes to the fold's far edge.
        let right = CGRect(x: 400, y: 0, width: 20, height: 669)
        #expect(FoldAvoidance.offset(for: CGRect(x: 380, y: 10, width: 200, height: 40), fold: right, in: 951) == CGFloat(420 - 380))
        // More room to the left: the piece's trailing edge goes to the fold's near edge.
        let left = CGRect(x: 600, y: 0, width: 20, height: 669)
        #expect(FoldAvoidance.offset(for: CGRect(x: 500, y: 10, width: 200, height: 40), fold: left, in: 951) == CGFloat(600 - 700))
    }

    // MARK: Home's tiles

    @Test func homesTilesGoTwoToARowOnAWindowThatFoldsUpItsMiddle() {
        // The open Duo on its side, flat (an inactive division up the window) or half open like a book: two to a row.
        // The Mac (this suite runs there too) keeps three whatever it is handed.
        #if os(macOS)
        let folding = 3
        #else
        let folding = 2
        #endif
        let side = CGSize(width: 951, height: 669)
        let flatOnItsSide = ReservedRegions(upFold: ReservedRegions.upFold([CGRect(x: 456, y: 0, width: 40, height: 669)], in: side))
        #expect(HomeTiles.columns(regions: flatOnItsSide) == folding)
        var bookOpen = book; bookOpen.upFold = book.divisions.first
        #expect(HomeTiles.columns(regions: bookOpen) == folding)
        // An active fold up the window counts on its own too (a flat Duo that reports no division).
        #expect(HomeTiles.columns(regions: book) == folding)
    }

    @Test func homesTilesStayThreeWhereTheFoldRunsAcross() {
        // The open Duo upright, flat (an inactive division across) or half open like a laptop: the fold runs between rows.
        let upright = CGSize(width: 669, height: 951)
        let across = [CGRect(x: 0, y: 456, width: 669, height: 40)]
        #expect(ReservedRegions.upFold(across, in: upright) == nil)
        #expect(HomeTiles.columns(regions: ReservedRegions(upFold: ReservedRegions.upFold(across, in: upright))) == 3)
        var laptopOpen = laptop; laptopOpen.upFold = ReservedRegions.upFold(laptop.divisions, in: upright)
        #expect(HomeTiles.columns(regions: laptopOpen) == 3)
    }

    @Test func aDivisionOutsideTheWindowDoesNotCount() {
        // The closed Duo, should it report the inner display's fold: outside its 466 x 678 window.
        #expect(ReservedRegions.upFold([CGRect(x: 700, y: 0, width: 20, height: 951)], in: CGSize(width: 466, height: 678)) == nil)
    }

    @Test func homesTwoColumnsStandEitherSideOfTheFold() {
        // The book pose's Home: the grid at x 129 to 737 (centred in the safe area, off the window's middle); the
        // fold at 456 to 496 is the gap: the leading column ends at 456, the trailing one starts at 496.
        let grid = CGRect(x: 129, y: 200, width: 608, height: 300)
        let s = HomeTiles.split(frame: grid, fold: CGRect(x: 456, y: 0, width: 40, height: 669), minimum: 100)
        #expect(s?.leading == 327)
        #expect(s?.gap == 40)
        #expect(s?.trailing == 241)
        #expect(grid.minX + (s?.leading ?? 0) == 456)
        #expect(grid.minX + (s?.leading ?? 0) + (s?.gap ?? 0) == 496)
    }

    @Test func noFoldThroughTheGridKeepsEvenColumns() {
        let grid = CGRect(x: 129, y: 200, width: 608, height: 300)
        #expect(HomeTiles.split(frame: grid, fold: nil, minimum: 100) == nil)
        // A fold outside the grid, or one that would leave a column under the minimum.
        #expect(HomeTiles.split(frame: grid, fold: CGRect(x: 800, y: 0, width: 40, height: 669), minimum: 100) == nil)
        #expect(HomeTiles.split(frame: grid, fold: CGRect(x: 180, y: 0, width: 40, height: 669), minimum: 100) == nil)
        // Not laid out yet.
        #expect(HomeTiles.split(frame: .zero, fold: CGRect(x: 456, y: 0, width: 40, height: 669), minimum: 100) == nil)
    }

    @Test func homesTilesStayThreeToARowOnAnIPad() {
        // A wide window with no fold (an iPad) and a phone: unchanged.
        #expect(HomeTiles.columns(regions: none) == 3)
    }

    // MARK: Voice mode on a column folded across (Duo stage 4)

    /// The open Duo upright, 669 x 951, half open like a laptop: the voice screen's column inside the safe area (82 at the
    /// top for the status corner, 34 at the foot), the fold at 455.5 to 495.5 (the legs' readout).
    private let voiceColumn = CGRect(x: 0, y: 82, width: 669, height: 835)
    private let voiceFold = CGRect(x: 0, y: 455.5, width: 669, height: 40)
    private let voiceSizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]

    @Test func voiceModeSplitsAtAFoldAcrossTheColumn() {
        let s = VoiceSplit.halves(column: voiceColumn, fold: voiceFold, size: .large)
        #expect(s?.top == 373.5)
        #expect(s?.gap == 40)
        #expect(s?.bottom == 421.5)
    }

    @Test func voiceModeJudgesTheHalvesOnTheColumnNotTheWindow() {
        // A fold a point short of the top half's minimum in the column: the window, 82 taller above, would split.
        let window = CGRect(x: 0, y: 0, width: 669, height: 951)
        let fold = CGRect(x: 0, y: voiceColumn.minY + VoiceSplit.minTop(for: .large) - 1, width: 669, height: 40)
        #expect(VoiceSplit.halves(column: window, fold: fold, size: .large) != nil)
        #expect(VoiceSplit.halves(column: voiceColumn, fold: fold, size: .large) == nil)
    }

    @Test func voiceModeStaysOneColumnWithoutAFoldAcross() {
        // No fold (a phone, an iPad, the Duo flat or closed), a fold up the window (the book pose), a fold outside the
        // column, and the accessibility text sizes.
        #expect(VoiceSplit.halves(column: voiceColumn, fold: nil, size: .large) == nil)
        #expect(VoiceSplit.halves(column: CGRect(x: 0, y: 0, width: 867, height: 635), fold: CGRect(x: 456, y: 0, width: 40, height: 669), size: .large) == nil)
        #expect(VoiceSplit.halves(column: voiceColumn, fold: CGRect(x: 0, y: 1000, width: 669, height: 40), size: .large) == nil)
        for size in [DynamicTypeSize.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5] {
            #expect(VoiceSplit.halves(column: voiceColumn, fold: voiceFold, size: size) == nil)
        }
    }

    @Test func voiceModesTopMinimumGrowsWithTheTextAndSmallerSizesTakeLarges() {
        let mins = voiceSizes.map { VoiceSplit.minTop(for: $0) }
        #expect(mins == mins.sorted())
        for size in [DynamicTypeSize.xSmall, .small, .medium] { #expect(VoiceSplit.minTop(for: size) == VoiceSplit.minTop(for: .large)) }
        #expect(VoiceSplit.minBottom == VoiceSplit.controls + VoiceSplit.transcriptFloor)
    }

    @Test func voiceModeSplitsOnlyWithBothHalvesAtTheirMinimum() {
        let gap: CGFloat = 40
        for size in voiceSizes {
            // The top half at its minimum for the size splits; a hair under doesn't.
            let atTop = CGRect(x: 0, y: voiceColumn.minY + VoiceSplit.minTop(for: size), width: 669, height: gap)
            if voiceColumn.maxY - atTop.maxY >= VoiceSplit.minBottom {
                #expect(VoiceSplit.halves(column: voiceColumn, fold: atTop, size: size)?.top == VoiceSplit.minTop(for: size))
                #expect(VoiceSplit.halves(column: voiceColumn, fold: atTop.offsetBy(dx: 0, dy: -0.1), size: size) == nil)
            }
        }
        // The bottom half at its minimum splits; a hair under doesn't.
        let atBottom = CGRect(x: 0, y: voiceColumn.maxY - VoiceSplit.minBottom - gap, width: 669, height: gap)
        #expect(VoiceSplit.halves(column: voiceColumn, fold: atBottom, size: .large)?.bottom == VoiceSplit.minBottom)
        #expect(VoiceSplit.halves(column: voiceColumn, fold: atBottom.offsetBy(dx: 0, dy: 0.1), size: .large) == nil)
    }

    // MARK: The Board's column chips (Duo stage 4)

    /// The widths of fixed columns and the spacing after each; nil for a column that isn't fixed.
    private func fixed(_ items: [GridItem]) -> [(width: CGFloat, spacing: CGFloat)]? {
        let out = items.compactMap { item -> (width: CGFloat, spacing: CGFloat)? in
            if case .fixed(let w) = item.size { return (w, item.spacing ?? 0) }
            return nil
        }
        return out.count == items.count ? out : nil
    }
    private func allFlexible(_ items: [GridItem]) -> Bool {
        items.allSatisfy { if case .flexible = $0.size { return true }; return false }
    }

    @Test func theBoardsChipsStandTwoEachSideOfTheFold() {
        // The book pose's Board: the chips at x 12 to 855 (the safe area beside the 84 pt strip, less the 12 pt
        // margins); the fold at 456 to 496 is the gap between the second chip and the third.
        var bookOpen = book; bookOpen.upFold = book.divisions.first
        let chips = CGRect(x: 12, y: 0, width: 843, height: 0)
        let items = KanbanChips.items(regions: bookOpen, frame: chips, count: 4, spacing: 6)
        #if os(macOS)
        #expect(allFlexible(items))
        #else
        let cols = fixed(items)
        #expect(cols?.count == 4)
        guard let cols, cols.count == 4 else { return }
        // Each half's chips share its width evenly, 6 pt apart.
        #expect(cols[0].width == CGFloat(444 - 6) / 2)
        #expect(cols[1].width == cols[0].width)
        #expect(cols[2].width == CGFloat(359 - 6) / 2)
        #expect(cols[3].width == cols[2].width)
        // The second chip ends at the fold's leading edge, the third starts at its far edge.
        #expect(chips.minX + cols[0].width + cols[0].spacing + cols[1].width == 456)
        #expect(cols[1].spacing == 40)
        #expect(chips.minX + cols[0].width + cols[0].spacing + cols[1].width + cols[1].spacing == 496)
        #endif
    }

    @Test func atTheAccessibilitySizesOneChipStandsEachSideOfTheFold() {
        var bookOpen = book; bookOpen.upFold = book.divisions.first
        let items = KanbanChips.items(regions: bookOpen, frame: CGRect(x: 12, y: 0, width: 843, height: 0), count: 2, spacing: 6)
        #if os(macOS)
        #expect(allFlexible(items))
        #else
        let cols = fixed(items)
        #expect(cols?.map(\.width) == [444, 359])
        #expect(cols?.first?.spacing == 40)
        #endif
    }

    @Test func theBoardsChipsStayEvenWithoutAFoldThroughThem() {
        let chips = CGRect(x: 12, y: 0, width: 843, height: 0)
        // A phone, an iPad, the closed Duo: no fold.
        #expect(allFlexible(KanbanChips.items(regions: none, frame: CGRect(x: 12, y: 0, width: 378, height: 0), count: 4, spacing: 6)))
        // The open Duo upright or as a laptop: the fold runs across, between rows.
        #expect(allFlexible(KanbanChips.items(regions: laptop, frame: CGRect(x: 12, y: 0, width: 645, height: 0), count: 4, spacing: 6)))
        // A fold that misses the chips, or that would leave a chip under the minimum (two chips need 146 pt a side).
        let outside = ReservedRegions(upFold: CGRect(x: 900, y: 0, width: 40, height: 669))
        #expect(allFlexible(KanbanChips.items(regions: outside, frame: chips, count: 4, spacing: 6)))
        let nearTheEdge = ReservedRegions(upFold: CGRect(x: 140, y: 0, width: 40, height: 669))
        #expect(allFlexible(KanbanChips.items(regions: nearTheEdge, frame: chips, count: 4, spacing: 6)))
        // Not laid out yet.
        var bookOpen = book; bookOpen.upFold = book.divisions.first
        #expect(allFlexible(KanbanChips.items(regions: bookOpen, frame: .zero, count: 4, spacing: 6)))
        // Even columns as before: four flexible, 6 pt apart.
        #expect(KanbanChips.items(regions: none, frame: chips, count: 4, spacing: 6).count == 4)
    }

    // MARK: Home's desk on a window folded across (Duo stage 4)

    /// The open Duo half open like a laptop: Home's page from under our top bar's row (141) to our tab bar's top (874),
    /// the fold at 456 to 496 (the code's numbers; the legs read the real ones).
    private let deskPage = CGRect(x: 0, y: 141, width: 669, height: 733)
    private let deskFold = CGRect(x: 0, y: 456, width: 669, height: 40)

    @Test func homeIsADeskAtAFoldAcrossThePage() {
        let s = DeskSplit.halves(page: deskPage, fold: deskFold, accessibilityText: false, editing: false)
        #expect(s?.top == 315)
        #expect(s?.gap == 40)
        #expect(s?.bottom == 378)
    }

    @Test func homeStaysOneListWithoutAFoldAcrossOrWhileEdited() {
        // No fold (a phone, an iPad, the Duo flat or closed), a fold up the window (the book pose), a fold outside the
        // page, the accessibility text sizes, Home being edited, and a page not laid out yet.
        #expect(DeskSplit.halves(page: deskPage, fold: nil, accessibilityText: false, editing: false) == nil)
        #expect(DeskSplit.halves(page: CGRect(x: 0, y: 141, width: 867, height: 494), fold: CGRect(x: 456, y: 0, width: 40, height: 669), accessibilityText: false, editing: false) == nil)
        #expect(DeskSplit.halves(page: deskPage, fold: CGRect(x: 0, y: 900, width: 669, height: 40), accessibilityText: false, editing: false) == nil)
        #expect(DeskSplit.halves(page: deskPage, fold: deskFold, accessibilityText: true, editing: false) == nil)
        #expect(DeskSplit.halves(page: deskPage, fold: deskFold, accessibilityText: false, editing: true) == nil)
        #expect(DeskSplit.halves(page: .zero, fold: deskFold, accessibilityText: false, editing: false) == nil)
    }

    @Test func homeIsADeskOnlyWithBothHalvesAtTheirMinimum() {
        let gap: CGFloat = 40
        // The top half at its minimum (290) splits; a hair under doesn't.
        let atTop = CGRect(x: 0, y: deskPage.minY + DeskSplit.minTop, width: 669, height: gap)
        #expect(DeskSplit.halves(page: deskPage, fold: atTop, accessibilityText: false, editing: false)?.top == DeskSplit.minTop)
        #expect(DeskSplit.halves(page: deskPage, fold: atTop.offsetBy(dx: 0, dy: -0.1), accessibilityText: false, editing: false) == nil)
        // The bottom half at its minimum (365) splits; a hair under doesn't.
        let atBottom = CGRect(x: 0, y: deskPage.maxY - DeskSplit.minBottom - gap, width: 669, height: gap)
        #expect(DeskSplit.halves(page: deskPage, fold: atBottom, accessibilityText: false, editing: false)?.bottom == DeskSplit.minBottom)
        #expect(DeskSplit.halves(page: deskPage, fold: atBottom.offsetBy(dx: 0, dy: 0.1), accessibilityText: false, editing: false) == nil)
    }

    @Test func theDeskAnswersApprovalsInPlaceAndSendsTheRestToTheirChat() {
        let approval = PendingCard(id: "a", method: "approval", params: ["request_id": "r1", "session_id": "s1", "command": "ls"])
        let question = PendingCard(id: "q", method: "clarify", params: ["question": "Which branch?"])
        let secret = PendingCard(id: "v", method: "sudo", params: .object([:]))
        // An approval the app can't read shows as unsupported, so it opens its chat too.
        let unreadable = PendingCard(id: "b", method: "approval", params: .object([:]))
        #expect(DeskCards.answersInPlace(approval))
        #expect(!DeskCards.answersInPlace(question))
        #expect(!DeskCards.answersInPlace(secret))
        #expect(!DeskCards.answersInPlace(unreadable))
        #expect(DeskCards.note(for: approval) == nil)
        #expect(DeskCards.note(for: question) == "Answer in the chat")
        #expect(DeskCards.note(for: nil) == "Needs you")
    }

    @Test func theDesksWaitingChatsFollowHomesChatList() {
        // Home's list order (the latest first), then the chats it doesn't list, by id.
        #expect(DeskCards.waiting(ids: ["c", "a", "z", "y"], order: ["a", "b", "c"]) == ["a", "c", "y", "z"])
        #expect(DeskCards.waiting(ids: [], order: ["a"]).isEmpty)
    }
}
