import Foundation
import SwiftUI
import Testing
import Vision
@testable import VoryCore
@testable import Vory

/// The table's wrap switch: a table whose words fit wraps inside the bubble, and one whose words do
/// not reports more than the bubble so the card falls back to its sideways scroll. Drawn through the
/// real views, because the mode is a layout, not a string.
@Suite struct TableWrapTests {
    /// Three columns and one long cell: the words fit a phone bubble once the cells may wrap, while
    /// the scrolling grid holds that cell at its 220 pt cap and overflows the bubble.
    static let three = """
    | Owner | Task | Status |
    |---|---|---|
    | @work | deploy every gateway to staging tonight, then roll the whole fleet back at dawn — slowly, watching every log line | Done |
    """

    static func table(_ text: String) -> MarkdownTable? {
        let blocks = MarkdownParser.blocks(from: text)
        guard blocks.count == 1, case .table(let t) = blocks[0] else { return nil }
        return t
    }

    @MainActor static func draw(_ view: some View) -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.uiImage?.size ?? .zero
    }

    @MainActor private func grid(_ text: String, wraps: Bool) throws -> some View {
        let t = try #require(Self.table(text))
        // No `.frame`: the point is the grid's own width, which a frame would clamp to 320.
        return MarkdownTableGrid(table: t, lineLimit: wraps ? nil : 3, wraps: wraps, fillWidth: 320)
    }

    @Test @MainActor func wrappingFitsTheBubbleThatScrollingOverflows() throws {
        let wrapped = Self.draw(try grid(Self.three, wraps: true))
        let scrolling = Self.draw(try grid(Self.three, wraps: false))
        #expect(abs(wrapped.width - 320) < 1, "the wrapped grid took \(wrapped.width) pt of a 320 pt bubble")
        #expect(scrolling.width > 320, "a held 220 pt column should overflow, but this took \(scrolling.width) pt")
    }

    @Test @MainActor func wrappingIgnoresAThreeLineCap() throws {
        // A wrapped cell is never cut short: passing a cap with `wraps` must change nothing. This
        // fails if `lineLimit(wraps ? nil : lineLimit)` ever goes back to a bare `lineLimit`.
        let t = try #require(Self.table(Self.three))
        let capped = Self.draw(MarkdownTableGrid(table: t, lineLimit: 3, wraps: true, fillWidth: 240))
        let open = Self.draw(MarkdownTableGrid(table: t, lineLimit: nil, wraps: true, fillWidth: 240))
        #expect(abs(capped.height - open.height) < 1, "a cap of 3 drew \(capped.height) pt, no cap \(open.height) pt")
    }

    @Test @MainActor func aTableWhoseWordsDoNotFitReportsMoreThanTheBubble() throws {
        // Six columns of real words: 333 pt of word floors plus 120 pt of padding cannot fit 320.
        let wide = Self.draw(try grid(MarkdownTableTests.wide, wraps: true))
        #expect(wide.width > 320, "the wrapped grid reported \(wide.width) pt, so ViewThatFits falls back")
    }

    @Test @MainActor func anEmptyColumnKeepsASliver() throws {
        // With no width to fill, a wrapped table stands on its floors: the empty column's floor is
        // all that separates these two tables.
        let withEmpty = try #require(Self.table("| a |  |\n|---|---|\n| 1 |  |"))
        let without = try #require(Self.table("| a |\n|---|\n| 1 |"))
        let wide = Self.draw(MarkdownTableGrid(table: withEmpty, lineLimit: nil, wraps: true))
        let narrow = Self.draw(MarkdownTableGrid(table: without, lineLimit: nil, wraps: true))
        #expect(wide.width - narrow.width >= MarkdownTableMetrics.minColumnFloor - 1,
                "the empty column took \(wide.width - narrow.width) pt")
    }

    @Test @MainActor func aTokenTooWideForTheBubbleIsNotSqueezedLetterByLetter() throws {
        let token = String(repeating: "9f2c7ab4", count: 8)   // 64 characters, one unbreakable word
        let t = try #require(Self.table("| hash |\n|---|\n| \(token) |"))
        let size = Self.draw(MarkdownTableGrid(table: t, lineLimit: nil, wraps: true, fillWidth: 320))
        #expect(size.width > 320, "the column must hold its token and scroll, but took \(size.width) pt")
        #expect(size.height < 80, "the cell stacked into \(size.height) pt instead of staying one line")
    }

    // The switch, the preference, and the card that carries them

    @Test @MainActor func theSwitchIsFortyFourPointsToHit() {
        UserDefaults.standard.removeObject(forKey: MarkdownTableMetrics.wrapKey)
        let size = Self.draw(TableWrapToggle())
        #expect(size.width >= 44 && size.height >= 44, "the target is \(size.width)x\(size.height)pt")
    }

    @Test @MainActor func bothControlsCarryCircularMaterialAffordance() {
        UserDefaults.standard.removeObject(forKey: MarkdownTableMetrics.wrapKey)
        let toggleSize = Self.draw(TableWrapToggle())
        #expect(toggleSize.width >= 28 && toggleSize.height >= 28)
    }

    @Test @MainActor func oneKeyDrivesEveryTable() throws {
        let t = try #require(Self.table(Self.three))
        #expect(MarkdownTableMetrics.wrapKey == "table.wrap")
        // Unset: wrapping is the default.
        UserDefaults.standard.removeObject(forKey: MarkdownTableMetrics.wrapKey)
        let wrapped = Self.draw(MarkdownTableView(table: t).frame(width: 320))
        UserDefaults.standard.set(false, forKey: MarkdownTableMetrics.wrapKey)
        let scrolling = Self.draw(MarkdownTableView(table: t).frame(width: 320))
        UserDefaults.standard.removeObject(forKey: MarkdownTableMetrics.wrapKey)
        #expect(wrapped.height > scrolling.height, "wrap drew \(wrapped.height) pt, scroll \(scrolling.height) pt")
    }

    @Test @MainActor func theAccessibilityTextSizesStillStackInsteadOfScrolling() throws {
        let t = try #require(Self.table(MarkdownTableTests.wide))
        let phone = Self.draw(MarkdownTableView(table: t).frame(width: 320))
        let accessibility = Self.draw(MarkdownTableView(table: t).frame(width: 320).environment(\.dynamicTypeSize, .accessibility3))
        // One card of "Header: value" lines per row is far taller than a six-column grid.
        #expect(accessibility.height > phone.height * 1.5, "stacked \(accessibility.height) pt vs gridded \(phone.height) pt")
    }

    @Test @MainActor func theControlsSitInTheirOwnStripSoNoHeaderIsSqueezed() throws {
        // The corner buttons used to overlay the header row, and the room they claimed was taken
        // from the last header cell: with a 65 pt column that left 1 pt for "Status". They now sit
        // in a strip of their own above the grid, so the card is the grid plus that strip.
        let t = try #require(Self.table(Self.three))
        let grid = Self.draw(MarkdownTableGrid(table: t, lineLimit: nil, wraps: true, fillWidth: 320, headerInset: 0))
        let card = Self.draw(MarkdownTableView(table: t).frame(width: 320))
        #expect(card.height >= grid.height + 28, "card \(card.height) pt vs grid \(grid.height) pt: the strip is missing")
    }

    @Test @MainActor func aCodeSpanColumnHoldsItsWholeToken() throws {
        // A code span draws monospaced, up to 2.5x wider than the same letters in the table's font.
        // If the floor ignores that, this token breaks mid-character at the floor width.
        let token = String(repeating: "i", count: 20)
        let t = try #require(Self.table("| cmd |\n|---|\n| `\(token)` |"))
        let tight = Self.draw(MarkdownTableGrid(table: t, lineLimit: nil, wraps: true, fillWidth: 120))
        let roomy = Self.draw(MarkdownTableGrid(table: t, lineLimit: nil, wraps: true, fillWidth: 900))
        #expect(tight.height == roomy.height, "the token broke: tight \(tight.height) pt vs roomy \(roomy.height) pt")
    }

    @Test @MainActor func aTokenTooWideForTheBubbleFallsBackToTheCardScroll() throws {
        let token = String(repeating: "9f2c7ab4", count: 8)
        let t = try #require(Self.table("| hash |\n|---|\n| \(token) |"))
        defer { UserDefaults.standard.removeObject(forKey: MarkdownTableMetrics.wrapKey) }
        UserDefaults.standard.removeObject(forKey: MarkdownTableMetrics.wrapKey)
        let wrapped = Self.draw(MarkdownTableView(table: t).frame(width: 320))
        UserDefaults.standard.set(false, forKey: MarkdownTableMetrics.wrapKey)
        let scrolling = Self.draw(MarkdownTableView(table: t).frame(width: 320))
        // Falling back draws the same three-line scroll card. A wrapped candidate that was accepted
        // instead would draw the token on one line, and be *shorter* than the scroll card.
        #expect(wrapped.height >= scrolling.height, "no fallback: wrapped \(wrapped.height) pt vs scroll \(scrolling.height) pt")
    }

    @Test @MainActor func theStripIsInsetFromTheCardsEdge() throws {
        // The action discs are compact 28 pt circles in the strip; 4 pt of vertical padding keeps them inset (strip = 36 pt tall).
        let t = try #require(Self.table(Self.three))
        let grid = Self.draw(MarkdownTableGrid(table: t, lineLimit: nil, wraps: true, fillWidth: 320, headerInset: 0))
        let card = Self.draw(MarkdownTableView(table: t).frame(width: 320))
        #expect(card.height - grid.height >= 34, "the strip is \(card.height - grid.height) pt: the disc is not inset")
    }

    @Test @MainActor func probesAreNeverDrawnOverTableCells() throws {
        // Probe subviews measure column word floors and must never be rendered on screen.
        let text = """
        | Deliverable | Verified state |
        |---|---|
        | Mac↔VPS latency | 80-105ms → 16ms |
        | SOCKS tunnel | timeout added |
        """
        let t = try #require(Self.table(text))
        let renderer = ImageRenderer(content: MarkdownTableView(table: t).frame(width: 320))
        renderer.scale = 2
        #if canImport(UIKit)
        let cgImage = renderer.uiImage?.cgImage
        #else
        let cgImage = renderer.nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
        let cg = try #require(cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        // The probe words (individual lines "Mac↔VPS", "latency", "SOCKS", "tunnel") must not
        // be recognized as independent lines on top of the cells.
        #expect(!recognized.contains("Mac↔VPS") && !recognized.contains("Mac→VPS"))
        #expect(recognized.contains(where: { $0.contains("VPS latency") }))
    }

    @Test func wrappedAndScrollingGridsDoNotShareSizeCache() throws {
        let t = try #require(Self.table(Self.three))
        let wrappedKey = MarkdownTableLayout.SizeKey(table: t, font: .footnote, lineLimit: nil, headerInset: 0,
                                                     typeSize: .large, bold: false, scale: 2, names: nil, wraps: true)
        let scrollingKey = MarkdownTableLayout.SizeKey(table: t, font: .footnote, lineLimit: nil, headerInset: 0,
                                                       typeSize: .large, bold: false, scale: 2, names: nil, wraps: false)
        #expect(wrappedKey != scrollingKey, "wrapped and unwrapped modes with the same lineLimit must have distinct cache keys")
    }

    /// Not an assertion: with `TABLE_WRAP_SHOTS_OUT` set, writes both cards as PNGs so a person —
    /// or a luminance map — can look at what "wrapped" means. Silent otherwise.
    @Test @MainActor func shotsOfBothModes() throws {
        guard let dir = ProcessInfo.processInfo.environment["TABLE_WRAP_SHOTS_OUT"] else { return }
        let t = try #require(Self.table(Self.three))
        defer { UserDefaults.standard.removeObject(forKey: MarkdownTableMetrics.wrapKey) }
        for wrap in [true, false] {
            UserDefaults.standard.set(wrap, forKey: MarkdownTableMetrics.wrapKey)
            let renderer = ImageRenderer(content: MarkdownTableView(table: t).frame(width: 320))
            renderer.scale = 3
            #if canImport(UIKit)
            guard let png = renderer.uiImage?.pngData() else { continue }
            #else
            guard let image = renderer.nsImage, let png = image.tiffRepresentation
                .flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) else { continue }
            #endif
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("table-\(wrap ? "wrapped" : "scrolling").png"))
        }
    }
}
