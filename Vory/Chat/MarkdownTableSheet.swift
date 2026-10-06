import SwiftUI
import VoryCore

// A markdown table's pieces, shared by the card in a reply (MarkdownTableView, in
// TranscriptView.swift) and the full-screen sheet below: the column arithmetic, the grid that
// lays the cells out, and the stacked rows used at the accessibility text sizes.

/// The arithmetic behind a table's columns and its scroll fades, kept free of views so it can
/// be tested on its own.
enum MarkdownTableMetrics {
    /// Narrow enough for a rank or an emoji column, wide enough for a short word and its padding.
    static let minColumn: CGFloat = 64
    /// In a bubble: past this a cell wraps (up to three lines) rather than widening its column.
    static let bubbleMaxColumn: CGFloat = 220
    /// On the sheet, where there is room to read a long cell on fewer lines.
    static let sheetMaxColumn: CGFloat = 320

    /// Each column's width: its widest cell on one line (`natural`), held between `lo` and `hi`.
    /// When the total leaves room in `fill`, the columns that had to wrap get their one-line
    /// width back first, then every column grows in proportion, so a narrow table spans the
    /// width it was given. With no room (a wide table, which scrolls) the held widths stand.
    static func columnWidths(natural: [CGFloat], fill: CGFloat?, min lo: CGFloat, max hi: CGFloat) -> [CGFloat] {
        var widths = natural.map { Swift.min(Swift.max($0, lo), hi) }
        // An unbounded proposal (a parent asking for the largest size) is not a width to fill.
        guard let fill, fill.isFinite, !widths.isEmpty else { return widths }
        var extra = fill - widths.reduce(0, +)
        guard extra > 0.5 else { return widths }
        let wanted = natural.indices.map { Swift.max(0, natural[$0] - widths[$0]) }
        let totalWanted = wanted.reduce(0, +)
        if totalWanted > 0 {
            let share = Swift.min(1, extra / totalWanted)
            for i in widths.indices { widths[i] += wanted[i] * share }
            extra -= totalWanted * share
        }
        guard extra > 0.5 else { return widths }
        let total = widths.reduce(0, +)
        return widths.map { $0 + extra * $0 / total }
    }

    /// Which edges of a sideways-scrolling table have more of it past them.
    struct Overflow: Equatable {
        var leading = false
        /// A table only scrolls when it is wider than its card, and it starts at its first
        /// column: more is to the right until the scroll view says otherwise.
        var trailing = true
    }

    static func overflow(contentWidth: CGFloat, visibleMinX: CGFloat, visibleMaxX: CGFloat) -> Overflow {
        Overflow(leading: visibleMinX > 1, trailing: visibleMaxX < contentWidth - 1)
    }
}

/// Lays a table's cells out row by row (header first, `columns` to a row) with the widths from
/// `MarkdownTableMetrics.columnWidths`; each row is as tall as its tallest cell. A Grid shared
/// the proposed width between the columns, so in a bubble every column of a wide table ended up
/// a few letters wide.
struct MarkdownTableLayout: Layout {
    var columns: Int
    var minColumn: CGFloat = MarkdownTableMetrics.minColumn
    var maxColumn: CGFloat = MarkdownTableMetrics.bubbleMaxColumn
    /// The width to stretch to when the columns need less. Nil uses the proposed width, which
    /// inside a sideways scroll view is none (the table keeps its own width there).
    var fillWidth: CGFloat? = nil

    struct Cache {
        var natural: [CGFloat]?
        var rows: (widths: [CGFloat], heights: [CGFloat])?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func widths(_ proposal: ProposedViewSize, _ subviews: Subviews, _ cache: inout Cache) -> [CGFloat] {
        let natural: [CGFloat]
        if let n = cache.natural {
            natural = n
        } else {
            var n = [CGFloat](repeating: 0, count: columns)
            for (i, s) in subviews.enumerated() { n[i % columns] = max(n[i % columns], s.sizeThatFits(.unspecified).width) }
            cache.natural = n
            natural = n
        }
        return MarkdownTableMetrics.columnWidths(natural: natural, fill: fillWidth ?? proposal.width, min: minColumn, max: maxColumn)
    }

    private func heights(_ widths: [CGFloat], _ subviews: Subviews, _ cache: inout Cache) -> [CGFloat] {
        if let r = cache.rows, r.widths == widths { return r.heights }
        var h = [CGFloat](repeating: 0, count: (subviews.count + columns - 1) / columns)
        for (i, s) in subviews.enumerated() {
            h[i / columns] = max(h[i / columns], s.sizeThatFits(ProposedViewSize(width: widths[i % columns], height: nil)).height)
        }
        cache.rows = (widths, h)
        return h
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard columns > 0, !subviews.isEmpty else { return .zero }
        let w = widths(proposal, subviews, &cache)
        let h = heights(w, subviews, &cache)
        return CGSize(width: w.reduce(0, +), height: h.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard columns > 0, !subviews.isEmpty else { return }
        let w = widths(proposal, subviews, &cache)
        let h = heights(w, subviews, &cache)
        var xs: [CGFloat] = [0], ys: [CGFloat] = [0]
        for x in w { xs.append(xs[xs.count - 1] + x) }
        for y in h { ys.append(ys[ys.count - 1] + y) }
        for (i, s) in subviews.enumerated() {
            let r = i / columns, c = i % columns
            s.place(at: CGPoint(x: bounds.minX + xs[c], y: bounds.minY + ys[r]), anchor: .topLeading,
                    proposal: ProposedViewSize(width: w[c], height: h[r]))
        }
    }
}

/// The table's cells: a semibold header row on a tertiary fill, hairlines between rows, inline
/// markdown (bold, links, code, emoji) in every cell. VoiceOver reads a body cell as
/// "header: value" (#42).
struct MarkdownTableGrid: View {
    var table: MarkdownTable
    var font: Font = .footnote
    /// Lines a cell may take before it is cut short; nil for all of them.
    var lineLimit: Int? = 3
    var maxColumn: CGFloat = MarkdownTableMetrics.bubbleMaxColumn
    var fillWidth: CGFloat? = nil
    /// Room kept at the end of the header row for a button over the card's corner.
    var headerInset: CGFloat = 0
    /// Whether the rows have scrolled up under the header row (it then shows a hairline).
    var pinned = false
    /// The header row stays in view as the rows scroll under it, on an opaque ground (the sheet).
    var opaqueHeader = false

    var body: some View {
        let n = table.header.count
        MarkdownTableLayout(columns: n, maxColumn: maxColumn, fillWidth: fillWidth) {
            ForEach(0..<n, id: \.self) { c in headerCell(c) }
            ForEach(0..<table.rows.count, id: \.self) { r in
                ForEach(0..<n, id: \.self) { c in bodyCell(row: r, column: c) }
            }
        }
    }

    private func headerCell(_ c: Int) -> some View {
        text(table.header[c], column: c, header: true)
            .accessibilityLabel(MarkdownTable.plain(table.header[c]))
            .accessibilityAddTraits(.isHeader)
            .padding(.leading, 10)
            .padding(.trailing, 10 + (c == table.header.count - 1 ? headerInset : 0))
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(c))
            .background {
                ZStack {
                    if opaqueHeader { Color(.systemBackground) }
                    Color(.tertiarySystemFill)
                }
            }
            .overlay(alignment: .bottom) { if opaqueHeader && pinned { hairline } }
            // Pinned by the render pass, from its own place in the scroll view: a scroll offset
            // kept in state re-laid out every cell and re-read every cell's markdown each frame.
            .visualEffect { [opaqueHeader] content, proxy in
                content.offset(y: opaqueHeader ? max(0, -proxy.frame(in: .scrollView).minY) : 0)
            }
            .zIndex(1)
    }

    private func bodyCell(row r: Int, column c: Int) -> some View {
        text(table.cell(row: r, column: c), column: c, header: false)
            // VoiceOver hears which column a cell is in, not a bare value.
            .accessibilityLabel(table.spokenCell(row: r, column: c))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(c))
            .overlay(alignment: .top) { hairline }
    }

    private func text(_ markdown: String, column c: Int, header: Bool) -> some View {
        Text(MarkdownView.inline(markdown))
            .font(header ? font.weight(.semibold) : font)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .multilineTextAlignment(textAlignment(c))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var hairline: some View { Rectangle().fill(Color(.separator)).frame(height: 0.5) }

    private func alignment(_ c: Int) -> Alignment {
        switch table.alignment(of: c) {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }

    private func textAlignment(_ c: Int) -> TextAlignment {
        switch table.alignment(of: c) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// A table for the accessibility text sizes: each row a card of "Header: value" lines, which
/// wraps at any size and never needs a sideways scroll.
struct MarkdownTableStack: View {
    var table: MarkdownTable
    var font: Font = .footnote

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if table.rows.isEmpty {
                // Only a header: its names, one per line.
                card {
                    ForEach(table.header.indices, id: \.self) { c in
                        Text(MarkdownView.inline(table.header[c])).font(font.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(table.rows.indices, id: \.self) { r in
                card {
                    ForEach(table.header.indices, id: \.self) { c in line(row: r, column: c) }
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4, content: content)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground).opacity(0.5), in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color(.separator), lineWidth: 0.5) }
            .accessibilityElement(children: .contain)
    }

    private func line(row r: Int, column c: Int) -> some View {
        let name = table.header[c]
        let value = Text(MarkdownView.inline(table.cell(row: r, column: c)))
        let shown = name.isEmpty ? value : Text("\(Text(MarkdownView.inline(name)).fontWeight(.semibold)): \(value)")
        return shown.font(font)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(table.spokenCell(row: r, column: c))
    }
}

/// The whole table on its own: every line of every cell, columns up to about 320 pt, scrolling
/// both ways with the header row held at the top. It fills a wide sheet (an iPad on its side, a
/// Mac window) rather than sitting in a phone-width column.
struct MarkdownTableSheet: View {
    var table: MarkdownTable
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The visible width, for a table narrower than the sheet to stretch across it.
    @State private var width: CGFloat = 0
    /// Whether the rows have scrolled up under the header row.
    @State private var pinned = false
    private static let margin: CGFloat = 16

    /// Changes only on a rotation or when the header starts or stops being pinned, so scrolling
    /// does not rebuild the table.
    private struct Scroll: Equatable {
        var width: CGFloat
        var pinned: Bool
    }

    var body: some View {
        NavigationStack {
            Group {
                if typeSize.isAccessibilitySize {
                    ScrollView { MarkdownTableStack(table: table, font: .body).padding(Self.margin) }
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        MarkdownTableGrid(table: table, font: .subheadline, lineLimit: nil, maxColumn: MarkdownTableMetrics.sheetMaxColumn,
                                          fillWidth: max(0, width - 2 * Self.margin), pinned: pinned, opaqueHeader: true)
                            .padding(Self.margin)
                    }
                    .onScrollGeometryChange(for: Scroll.self) { g in
                        Scroll(width: g.containerSize.width - g.contentInsets.leading - g.contentInsets.trailing,
                               pinned: g.contentOffset.y + g.contentInsets.top > Self.margin)
                    } action: { _, now in
                        if width != now.width { width = now.width }
                        if pinned != now.pinned { pinned = now.pinned }
                    }
                }
            }
            .textSelection(.enabled)
            .navigationTitle("Table")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { UIPasteboard.general.string = table.markdown } label: { Label("Copy as Markdown", systemImage: "doc.on.doc") }
                }
            }
        }
        #if os(iOS)
        .presentationSizing(.page)
        #endif
    }
}
