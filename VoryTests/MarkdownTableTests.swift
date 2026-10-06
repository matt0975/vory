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
