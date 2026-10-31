import Foundation
import SwiftUI
import Testing
@testable import Vory
@testable import VoryCore

// Tables: the parse of a wide table as a reply sends it, Copy as Markdown, what VoiceOver
// reads, and the column arithmetic behind the scrolling card; then the Reasoning card's
// markdown style. Nothing here is drawn, and nothing is iPhone-only: the Mac runs them too.

@Suite struct MarkdownTableTests {
    /// Six columns of emoji, bold, an em dash and star ratings: a table that used to wrap letter
    /// by letter in a phone's bubble.
    static let wide = """
    | Rank | Lab / Model | Params | License | Superpower | Rating |
    |---|---|---|---|---|---|
    | 🥇 | **Lab A — Model One** | 2.8T / 104B act | Modified MIT | Agentic coding at scale | ⭐⭐⭐⭐⭐ |
    | 🥈 | **Lab B — Model Two** | 744B / 40B act | MIT | Long-horizon tool use | ⭐⭐⭐⭐½ |
    """

    private func onlyTable(_ text: String) -> MarkdownTable? {
        let blocks = MarkdownParser.blocks(from: text)
        guard blocks.count == 1, case .table(let t) = blocks[0] else { return nil }
        return t
    }

    @Test func theWideTableParsesWithEveryCellIntact() throws {
        // One block: the alignment row is consumed, not left behind as a paragraph.
        let t = try #require(onlyTable(Self.wide))
        #expect(t.header == ["Rank", "Lab / Model", "Params", "License", "Superpower", "Rating"])
        #expect(t.alignments == Array(repeating: .leading, count: 6))
        #expect(t.rows.count == 2)
        #expect(t.rows.allSatisfy { $0.count == 6 })
        #expect(t.rows[0] == ["🥇", "**Lab A — Model One**", "2.8T / 104B act", "Modified MIT", "Agentic coding at scale", "⭐⭐⭐⭐⭐"])
        #expect(t.rows[1] == ["🥈", "**Lab B — Model Two**", "744B / 40B act", "MIT", "Long-horizon tool use", "⭐⭐⭐⭐½"])
        // Emoji are whole characters, not split or dropped.
        #expect(t.rows[0][0].count == 1)
        #expect(t.rows[0][5].count == 5)
        #expect(t.rows[1][5].count == 5)
        // The bold and the em dash survive inline parsing too.
        let name = MarkdownParser.inline(t.rows[0][1])
        #expect(String(name.characters) == "Lab A — Model One")
        #expect(name.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @Test func voiceOverReadsHeaderThenValueWithoutMarkdown() throws {
        let t = try #require(onlyTable(Self.wide))
        #expect(t.spokenCell(row: 0, column: 1) == "Lab / Model: Lab A — Model One")
        #expect(t.spokenCell(row: 1, column: 5) == "Rating: ⭐⭐⭐⭐½")
        #expect(t.spokenCell(row: 0, column: 0) == "Rank: 🥇")
        // Past the end of a ragged table: the header alone, nothing out of range.
        #expect(t.spokenCell(row: 9, column: 2) == "Params")
        #expect(t.cell(row: 0, column: 9) == "")
    }

    @Test func copyAsMarkdownParsesBackToTheSameTable() throws {
        let t = try #require(onlyTable(Self.wide))
        #expect(onlyTable(t.markdown) == t)
        #expect(t.markdown.hasPrefix("| Rank | Lab / Model | Params | License | Superpower | Rating |\n| --- | --- | --- | --- | --- | --- |\n"))
    }

    @Test func copyAsMarkdownKeepsAlignmentsAndEscapesPipes() throws {
        let source = "| a | b | c |\n|:--|:-:|--:|\n| x \\| y | `p\\|q` | |"
        let t = try #require(onlyTable(source))
        #expect(t.rows[0] == ["x | y", "`p|q`", ""])
        #expect(t.markdown == "| a | b | c |\n| --- | :---: | ---: |\n| x \\| y | `p\\|q` |  |")
        #expect(onlyTable(t.markdown) == t)
    }

    // Column widths

    @Test func columnsAreHeldBetweenTheirLimitsWhenTheTableScrolls() {
        let w = MarkdownTableMetrics.columnWidths(natural: [20, 100, 500], fill: 300, min: 64, max: 220)
        // Wider than 300 pt in all: no stretching, the card scrolls.
        #expect(w == [64, 100, 220])
        // No width to fill (inside a scroll view) or an unbounded one: the same.
        #expect(MarkdownTableMetrics.columnWidths(natural: [20, 100, 500], fill: nil, min: 64, max: 220) == [64, 100, 220])
        #expect(MarkdownTableMetrics.columnWidths(natural: [20, 100, 500], fill: .infinity, min: 64, max: 220) == [64, 100, 220])
    }

    @Test func aTableThatFitsStretchesToTheWidthUnwrappingFirst() {
        // 64 + 100 + 220 = 384 held, 116 spare in 500. The capped column gets its one-line
        // width back first (80 of the 116), then all three share the last 36 in proportion.
        let w = MarkdownTableMetrics.columnWidths(natural: [20, 100, 300], fill: 500, min: 64, max: 220)
        #expect(abs(w.reduce(0, +) - 500) < 0.001)
        #expect(w[2] >= 300)
        #expect(w[0] >= 64 && w[1] >= 100)
        #expect(w[0] < w[1] && w[1] < w[2])
        // Too little spare to unwrap fully: the wrapped columns share it and the rest stay put.
        let tight = MarkdownTableMetrics.columnWidths(natural: [20, 260, 300], fill: 520, min: 64, max: 220)
        #expect(abs(tight.reduce(0, +) - 520) < 0.001)
        #expect(tight[0] == 64)
        #expect(tight[1] > 220 && tight[2] > 220)
    }

    @Test func theScrollFadeFollowsWhereTheRestOfTheTableIs() {
        typealias M = MarkdownTableMetrics
        #expect(M.overflow(contentWidth: 600, visibleMinX: 0, visibleMaxX: 300) == .init(leading: false, trailing: true))
        #expect(M.overflow(contentWidth: 600, visibleMinX: 150, visibleMaxX: 450) == .init(leading: true, trailing: true))
        #expect(M.overflow(contentWidth: 600, visibleMinX: 300, visibleMaxX: 600) == .init(leading: true, trailing: false))
    }

    @Test func measuredSizesAreKeptByWhatTheyWereMeasuredFrom() throws {
        typealias L = MarkdownTableLayout
        let t = try #require(onlyTable(Self.wide))
        let key = L.SizeKey(table: t, font: .footnote, lineLimit: 3, headerInset: 22, typeSize: .large, bold: false, scale: 2)
        var kept = L.Cache(key: key)
        kept.natural = [70, 180, 120, 100, 160, 90]
        kept.rows[[64, 180, 120, 100, 160, 90]] = [30, 44, 44]
        L.SizeStore.shared.keep(kept)
        // A row the lazy thread builds again finds them.
        #expect(L.SizeStore.shared.cache(for: key).natural == kept.natural)
        #expect(L.SizeStore.shared.cache(for: key).rows[[64, 180, 120, 100, 160, 90]] == [30, 44, 44])
        // A cell that changed (a table still streaming), another text size or Bold Text measure afresh.
        var edited = t
        edited.rows[0][1] = "**Lab A — Model 1.1**"
        var other = key
        other.table = edited
        #expect(L.SizeStore.shared.cache(for: other).natural == nil)
        other = key
        other.typeSize = .xLarge
        #expect(L.SizeStore.shared.cache(for: other).natural == nil)
        other = key
        other.bold = true
        #expect(L.SizeStore.shared.cache(for: other).natural == nil)
        // Floors ride the same key as the widths they feed.
        kept.floors = [40, 60, 30]
        L.SizeStore.shared.keep(kept)
        #expect(L.SizeStore.shared.cache(for: key).floors == [40, 60, 30])
        #expect(L.SizeStore.shared.cache(for: other).floors == nil)
        #expect(L.SizeStore.shared.cache(for: nil).key == nil)
    }

    @Test func aTableWithAMentionIsMeasuredAgainWhenTheNamesChange() throws {
        typealias L = MarkdownTableLayout
        // The bots' names arrive after the table was first measured: "@work" is then drawn
        // semibold, wider, so the sizes measured without the names do not stand.
        let t = try #require(onlyTable("| Owner | Task |\n|---|---|\n| @work | the deploy |\n"))
        let before = Mentions.Names(), after = Mentions.Names(bots: ["work"], person: nil)
        #expect(L.SizeKey.names(for: t, before) == before)
        let key = L.SizeKey(table: t, font: .footnote, lineLimit: 3, headerInset: 22, typeSize: .large, bold: false, scale: 2,
                            names: L.SizeKey.names(for: t, before))
        var kept = L.Cache(key: key)
        kept.natural = [64, 80]
        L.SizeStore.shared.keep(kept)
        var named = key
        named.names = L.SizeKey.names(for: t, after)
        #expect(L.SizeStore.shared.cache(for: key).natural == [64, 80])
        #expect(L.SizeStore.shared.cache(for: named).natural == nil)
        // A table with no "@" keeps its sizes whatever the names: they cannot change it.
        let plain = try #require(onlyTable(Self.wide))
        #expect(L.SizeKey.names(for: plain, after) == nil)
    }

    // Words, and the widths a wrapped table takes from them

    @Test func aColumnFloorIsItsLongestWord() throws {
        let t = try #require(onlyTable(Self.wide))
        // Every word of the column, one per line: a probe Text's natural width is then its widest line.
        let words = MarkdownTableMetrics.words(t, column: 4).split(separator: "\n").map(String.init)
        #expect(Set(words) == ["Superpower", "Agentic", "coding", "at", "scale", "Long-horizon", "tool", "use"])
        #expect(words.count == Set(words).count, "words are deduped")
        // Markdown never reaches the probe: it measures words, not markers. "/" is a word of its own.
        let lab = MarkdownTableMetrics.words(t, column: 1)
        #expect(!lab.contains("*"))
        #expect(Set(lab.split(separator: "\n").map(String.init)) == ["Lab", "/", "Model", "A", "—", "One", "B", "Two"],
                "column 1's words were: \(lab)")
    }

    @Test func anEmptyColumnHasNoWords() throws {
        // The header is a word too: a column with no words at all has an empty header and empty cells.
        let t = try #require(onlyTable("| a |  |\n|---|---|\n| 1 |  |"))
        #expect(MarkdownTableMetrics.words(t, column: 1) == "", "got: \(MarkdownTableMetrics.words(t, column: 1))")
        #expect(MarkdownTableMetrics.words(t, column: 0) == "a\n1")
    }

    @Test func anEmojiRunIsOneWord() throws {
        let t = try #require(onlyTable(Self.wide))
        // ⭐⭐⭐⭐⭐ is a single word: a floor of the whole run, not one glyph.
        let rating = Set(MarkdownTableMetrics.words(t, column: 5).split(separator: "\n").map(String.init))
        #expect(rating == ["Rating", "⭐⭐⭐⭐⭐", "⭐⭐⭐⭐½"])
    }

    @Test func wrappingStartsAtTheFloorsAndSpendsTheSpare() {
        typealias M = MarkdownTableMetrics
        // Floors already past the bubble: they stand, and the card scrolls instead of breaking words.
        #expect(M.wrapWidths(natural: [200, 300, 100], floors: [180, 200, 90], hi: 220, fill: 320) == [180, 200, 90])
        // No bounded width to fill (inside a scroll view): the floors stand.
        #expect(M.wrapWidths(natural: [200, 300], floors: [60, 40], hi: 220, fill: nil) == [60, 40])
        // Room to spare: the columns grow back toward their one-line widths, to exactly the bubble.
        let roomy = M.wrapWidths(natural: [200, 100, 60], floors: [60, 40, 24], hi: 220, fill: 320)
        #expect(abs(roomy.reduce(0, +) - 320) < 0.001)
        #expect(roomy[0] > 60 && roomy[0] <= 220)
        #expect(roomy[1] >= 40 && roomy[2] >= 24)
        // A floor past `hi` is kept: never clamped down into a broken word.
        #expect(M.wrapWidths(natural: [400, 40], floors: [400, 40], hi: 220, fill: 1000)[0] >= 400)
        // The scroll-mode arithmetic is untouched: its own suite below still holds.
        #expect(M.columnWidths(natural: [20, 100, 500], fill: 300, min: 64, max: 220) == [64, 100, 220])
    }

    @Test func nonBreakingSpaceKeepsWordsBoundTogether() throws {
        let t = try #require(onlyTable("| Metric |\n|---|\n| 16\u{00A0}flaps/day |"))
        let words = MarkdownTableMetrics.words(t, column: 0).split(separator: "\n").map(String.init)
        #expect(words.contains("16\u{00A0}flaps/day"), "non-breaking spaces must not be split into separate words")
    }

    @Test func wrapWidthsGuardsMismatchedFloorCount() {
        typealias M = MarkdownTableMetrics
        // floors has fewer elements than natural: must return floors defensively without crashing
        let result = M.wrapWidths(natural: [100, 200, 300], floors: [50, 50], hi: 220, fill: 320)
        #expect(result == [50, 50])
    }
}

/// The Reasoning card's markdown style: the reply's look is untouched, html stays code.
@Suite struct ReasoningMarkdownStyleTests {
    @MainActor @Test func repliesKeepTheirHeadingsAndCardsAndReasoningDoesNot() {
        for level in 1...6 { #expect(MarkdownView.headingFont(level, style: .reply) == MarkdownView.headingFont(level)) }
        #expect(MarkdownView.headingFont(1, style: .reasoning) != MarkdownView.headingFont(1))
        #expect(MarkdownView.Style.reply.showsCards)
        #expect(!MarkdownView.Style.reasoning.showsCards)
        // The style is part of what makes two views equal (the row redraws when it changes).
        #expect(MarkdownView(text: "a") != MarkdownView(text: "a", style: .reasoning))
        #expect(MarkdownView(text: "a") == MarkdownView(text: "a"))
    }
}
