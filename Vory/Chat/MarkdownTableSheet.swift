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
    /// The grid's horizontal padding, both sides, part of every column's floor: a word needs its
    /// letters' width plus this much before the column can draw it unbroken.
    static let cellPadding: CGFloat = 20
    /// A column with no words at all still needs a sliver to draw its padding and rules.
    static let minColumnFloor: CGFloat = 24
    /// The reader's choice for every table: wrap to fit the bubble, or scroll sideways. One key, so
    /// two tables on one screen never disagree, and it outlives the launch.
    static let wrapKey = "table.wrap"

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

    /// A wrapped table's widths: every column starts at its longest-word floor, then the spare in
    /// `fill` goes back to the columns that can use it — their one-line widths first, the rest in
    /// proportion. Floors that already exceed `fill` stand as they are, so the card falls back to
    /// its sideways scroll rather than breaking a word to fit.
    static func wrapWidths(natural: [CGFloat], floors: [CGFloat], hi: CGFloat, fill: CGFloat?) -> [CGFloat] {
        var widths = floors
        guard let fill, fill.isFinite, !widths.isEmpty, natural.count == widths.count else { return widths }
        var extra = fill - widths.reduce(0, +)
        guard extra > 0.5 else { return widths }
        // What each column would grow to if the bubble allowed it: its one-line width, capped at `hi`.
        let wanted = natural.indices.map { i in
            Swift.max(0, Swift.min(natural[i], Swift.max(hi, floors[i])) - floors[i])
        }
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

    /// The words a column's floor is measured from: every cell's plain text, deduped, one per line.
    /// A probe `Text` of this string reports its widest word as its natural width (measured: 39 pt
    /// for "Agentic\ncoding\nat\nscale" at footnote size, 60 pt tall for its four lines).
    static func words(_ table: MarkdownTable, column c: Int) -> String {
        var firstSeen = Set<String>(), ordered: [String] = [], word = ""
        func flush() {
            if !word.isEmpty, firstSeen.insert(word).inserted { ordered.append(word) }
            word = ""
        }
        func add(_ text: String) {
            for ch in MarkdownTable.plain(text) {
                // Only split on breakable whitespace; non-breaking spaces (\u{00A0}) must stay with their words.
                if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                    flush()
                } else {
                    word.append(ch)
                }
            }
            flush()
        }
        if table.header.indices.contains(c) { add(table.header[c]) }
        for r in table.rows.indices { add(table.cell(row: r, column: c)) }
        // First-seen order, not sorted: the string is only ever measured, so any stable order does,
        // and this one keeps the order a reader would meet the words in.
        return ordered.joined(separator: "\n")
    }

    /// The words inside a column's inline code spans, one per line, for a monospaced probe. A code
    /// span draws monospaced — measured 2.5x wider than the same letters in the table's font — so a
    /// floor taken from the plain words alone lets a token break mid-character in wrap mode.
    static func codeWords(_ table: MarkdownTable, column c: Int) -> String? {
        var firstSeen = Set<String>(), ordered: [String] = []
        func take(_ text: String) {
            let parts = text.split(separator: "`", omittingEmptySubsequences: false)
            guard parts.count > 1 else { return }
            for (i, span) in parts.enumerated() where i % 2 == 1 {
                for word in span.split(whereSeparator: { $0.isWhitespace }) {
                    let s = String(word)
                    if firstSeen.insert(s).inserted { ordered.append(s) }
                }
            }
        }
        if table.header.indices.contains(c) { take(table.header[c]) }
        for r in table.rows.indices { take(table.cell(row: r, column: c)) }
        return ordered.isEmpty ? nil : ordered.joined(separator: "\n")
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

    /// A cell's text as a grid shows it: at most `TextPieces.limit` characters, then an ellipsis. A cell with a huge
    /// unbroken value (a hash, base64) was laid out on one line to size its column, and drawn as one picture taller
    /// than the graphics card allows on the sheet, where cells are not cut to three lines (#361). The whole cell is in
    /// Copy as Markdown and on a long press on the sheet.
    static func shownCell(_ markdown: String, limit: Int = TextPieces.limit) -> String {
        guard markdown.utf8.count > limit else { return markdown }
        return String(markdown.prefix(limit)) + "…"
    }

    /// Most columns and rows a table shows in a reply; the whole table is on its sheet.
    static let bubbleColumns = 16
    static let bubbleRows = 60
}

extension MarkdownTable {
    /// The table's first `columns` columns and `rows` rows.
    func prefix(columns: Int, rows: Int) -> MarkdownTable {
        guard header.count > columns || self.rows.count > rows else { return self }
        return MarkdownTable(header: Array(header.prefix(columns)), alignments: Array(alignments.prefix(columns)),
                             rows: self.rows.prefix(rows).map { Array($0.prefix(columns)) })
    }
}

/// The wrap/scroll switch in a table card's corner. The glyph is the change it will make: a
/// scrolling table offers "wrap", a wrapped one offers "unroll". One key drives every table, so the
/// two switches on a screen never disagree.
struct TableWrapToggle: View {
    @AppStorage(MarkdownTableMetrics.wrapKey) private var wrap = true

    var body: some View {
        Button { withAnimation(.snappy) { wrap.toggle() } } label: {
            Image(systemName: wrap ? "arrow.left.and.right" : "text.alignleft")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.thinMaterial, in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(wrap ? "Unwrap wide columns" : "Wrap columns to fit")
        .help(wrap ? "Unwrap Columns" : "Wrap Columns")
    }
}

/// "Copy Cell" on a long press, on the table's sheet only (in a reply the long press keeps the reply's own menu).
private struct CopyCellMenu: ViewModifier {
    /// The table on its sheet; nil in a reply.
    var table: MarkdownTable?
    var row: Int
    var column: Int
    func body(content: Content) -> some View {
        if let table {
            content.contextMenu {
                Button { UIPasteboard.general.string = MarkdownTable.plain(table.cell(row: row, column: column)) } label: { Label("Copy Cell", systemImage: "doc.on.doc") }
            }
        } else {
            content
        }
    }
}

/// Lays a table's cells out row by row (header first, `columns` to a row) with the widths from
/// `MarkdownTableMetrics.columnWidths`; each row is as tall as its tallest cell. A Grid shared
/// the proposed width between the columns, so in a bubble every column of a wide table ended up
/// a few letters wide.
struct MarkdownTableLayout: Layout {
    var columns: Int
    /// How many of the leading subviews are cells; any after them are the per-column word probes,
    /// which are measured and never placed.
    var cellCount: Int
    var minColumn: CGFloat = MarkdownTableMetrics.minColumn
    var maxColumn: CGFloat = MarkdownTableMetrics.bubbleMaxColumn
    /// Hold the columns at their longest-word floors and let the cells wrap, instead of holding
    /// each column at its one-line width and scrolling.
    var wraps = false
    /// The width to stretch to when the columns need less. Nil uses the proposed width, which
    /// inside a sideways scroll view is none (the table keeps its own width there).
    var fillWidth: CGFloat? = nil
    /// Everything the cells' sizes come from. With it the measured sizes outlive an update that
    /// changed none of it and a row the lazy thread builds again: every cell was measured again
    /// on each pass, a cost in the thread's first scroll through a long chat (1.5 (24)).
    var sizes: SizeKey? = nil

    struct SizeKey: Hashable, Sendable {
        var table: MarkdownTable
        var font: Font
        var lineLimit: Int?
        var headerInset: CGFloat
        var typeSize: DynamicTypeSize
        var bold: Bool
        var scale: CGFloat
        /// The names an "@" in a cell can mean: a known one is drawn semibold, wider than the
        /// table's font, and the names arrive or change after the table may have been measured.
        /// Nil for a table with no "@", which they cannot change.
        var names: Mentions.Names?
        /// Whether the table's columns wrap to word floors or hold their one-line widths: each mode
        /// measures distinct column widths and row heights, and must never collide in SizeStore.
        var wraps: Bool = false

        static func names(for table: MarkdownTable, _ names: Mentions.Names) -> Mentions.Names? {
            let at = UInt8(ascii: "@")
            let any = table.header.contains { $0.utf8.contains(at) } || table.rows.contains { $0.contains { $0.utf8.contains(at) } }
            return any ? names : nil
        }
    }

    struct Cache {
        var key: SizeKey?
        var natural: [CGFloat]?
        /// Each column's word floor, padding included: what a wrapped table holds its columns at.
        var floors: [CGFloat]?
        /// Row heights by column widths: a card is measured at its ideal width and at the
        /// bubble's, and ViewThatFits tries both of its candidates.
        var rows: [[CGFloat]: [CGFloat]] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { SizeStore.shared.cache(for: sizes) }
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        guard sizes == nil || cache.key != sizes else { return }
        cache = SizeStore.shared.cache(for: sizes)
    }

    /// Each column's longest word, as SwiftUI measured it, plus the cell padding: the narrowest the
    /// column may be before a word in it would break. Measured from the probe subviews the grid
    /// appends after its cells — `sizeThatFits(.unspecified)` on a `Text` of one column's words, one
    /// per line, is the width of its widest line.
    private func floors(_ subviews: Subviews, _ cache: inout Cache) -> [CGFloat] {
        if let f = cache.floors, f.count == columns { return f }
        var f = [CGFloat](repeating: MarkdownTableMetrics.minColumnFloor, count: columns)
        if subviews.count >= cellCount + columns {
            for c in 0..<columns {
                let probe = subviews[cellCount + c].sizeThatFits(.unspecified).width
                f[c] = Swift.max(MarkdownTableMetrics.minColumnFloor, probe + MarkdownTableMetrics.cellPadding)
            }
        }
        cache.floors = f
        SizeStore.shared.keep(cache)
        return f
    }

    private func widths(_ proposal: ProposedViewSize, _ subviews: Subviews, _ cache: inout Cache) -> [CGFloat] {
        let natural: [CGFloat]
        if let n = cache.natural, n.count == columns {
            natural = n
        } else {
            var n = [CGFloat](repeating: 0, count: columns)
            for (i, s) in subviews.prefix(cellCount).enumerated() { n[i % columns] = max(n[i % columns], s.sizeThatFits(.unspecified).width) }
            cache.natural = n
            SizeStore.shared.keep(cache)
            natural = n
        }
        let fill = fillWidth ?? proposal.width
        guard wraps else {
            return MarkdownTableMetrics.columnWidths(natural: natural, fill: fill, min: minColumn, max: maxColumn)
        }
        return MarkdownTableMetrics.wrapWidths(natural: natural, floors: floors(subviews, &cache), hi: maxColumn, fill: fill)
    }

    private func heights(_ widths: [CGFloat], _ subviews: Subviews, _ cache: inout Cache) -> [CGFloat] {
        let count = (cellCount + columns - 1) / columns
        if let h = cache.rows[widths], h.count == count { return h }
        var h = [CGFloat](repeating: 0, count: count)
        for (i, s) in subviews.prefix(cellCount).enumerated() {
            h[i / columns] = max(h[i / columns], s.sizeThatFits(ProposedViewSize(width: widths[i % columns], height: nil)).height)
        }
        if cache.rows.count >= 8 { cache.rows.removeAll() }
        cache.rows[widths] = h
        SizeStore.shared.keep(cache)
        return h
    }

    /// The measured sizes of the tables drawn lately, by what they were measured from. NSCache
    /// is thread-safe and bounded; the wrapper only says so to the compiler.
    final class SizeStore: @unchecked Sendable {
        static let shared = SizeStore()
        private let store: NSCache<Key, Box> = { let c = NSCache<Key, Box>(); c.countLimit = 200; return c }()

        final class Key: NSObject {
            let key: SizeKey
            private let hashed: Int
            init(_ key: SizeKey) { self.key = key; hashed = key.hashValue }
            override var hash: Int { hashed }
            override func isEqual(_ other: Any?) -> Bool { (other as? Key)?.key == key }
        }
        final class Box { let cache: Cache; init(_ c: Cache) { cache = c } }

        func cache(for key: SizeKey?) -> Cache {
            guard let key else { return Cache() }
            return store.object(forKey: Key(key))?.cache ?? Cache(key: key)
        }
        func keep(_ cache: Cache) {
            guard let key = cache.key else { return }
            store.setObject(Box(cache), forKey: Key(key))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard columns > 0, cellCount > 0 else { return .zero }
        let w = widths(proposal, subviews, &cache)
        let h = heights(w, subviews, &cache)
        return CGSize(width: w.reduce(0, +), height: h.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard columns > 0, cellCount > 0 else { return }
        let w = widths(proposal, subviews, &cache)
        let h = heights(w, subviews, &cache)
        var xs: [CGFloat] = [0], ys: [CGFloat] = [0]
        for x in w { xs.append(xs[xs.count - 1] + x) }
        for y in h { ys.append(ys[ys.count - 1] + y) }
        // Cells only: the probes after them are placed off-screen and hidden, so they draw nothing.
        for (i, s) in subviews.prefix(cellCount).enumerated() {
            let r = i / columns, c = i % columns
            s.place(at: CGPoint(x: bounds.minX + xs[c], y: bounds.minY + ys[r]), anchor: .topLeading,
                    proposal: ProposedViewSize(width: w[c], height: h[r]))
        }
        for s in subviews.dropFirst(cellCount) {
            s.place(at: CGPoint(x: -10000, y: -10000), proposal: .zero)
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
    /// Wrap the cells inside their columns' word floors instead of holding their one-line widths.
    /// A wrapped cell is never cut short: every line of it is drawn.
    var wraps = false
    var maxColumn: CGFloat = MarkdownTableMetrics.bubbleMaxColumn
    var fillWidth: CGFloat? = nil
    /// Room kept at the end of the header row for a button over the card's corner.
    var headerInset: CGFloat = 0
    /// Whether the rows have scrolled up under the header row (it then shows a hairline).
    var pinned = false
    /// The header row stays in view as the rows scroll under it, on an opaque ground (the sheet).
    var opaqueHeader = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.legibilityWeight) private var legibility
    @Environment(\.displayScale) private var scale

    var body: some View {
        let n = table.header.count
        let sizes = MarkdownTableLayout.SizeKey(table: table, font: font, lineLimit: wraps ? nil : lineLimit, headerInset: headerInset,
                                                typeSize: typeSize, bold: legibility == .bold, scale: scale,
                                                names: MarkdownTableLayout.SizeKey.names(for: table, Mentions.names),
                                                wraps: wraps)
        MarkdownTableLayout(columns: n, cellCount: n * (1 + table.rows.count), maxColumn: maxColumn,
                            wraps: wraps, fillWidth: fillWidth, sizes: sizes) {
            ForEach(0..<n, id: \.self) { c in headerCell(c) }
            ForEach(0..<table.rows.count, id: \.self) { r in
                ForEach(0..<n, id: \.self) { c in bodyCell(row: r, column: c) }
            }
            ForEach(0..<n, id: \.self) { c in probe(c) }
        }
    }

    /// Drawn nowhere, measured always: its natural width is the column's floor, because a `Text` of
    /// the column's words one per line is as wide as its widest line. Bold, because a bold probe is
    /// never narrower than a semibold header or a bold word inside a cell; monospaced for the words
    /// inside code spans, which draw wider than the same letters in the table's font.
    private func probe(_ c: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Text(MarkdownTableMetrics.words(table, column: c))
                .font(font.weight(.bold))
            if let code = MarkdownTableMetrics.codeWords(table, column: c) {
                Text(code).font(font.weight(.bold).monospaced())
            }
        }
        .lineLimit(nil)
        .fixedSize()
        .hidden()
        .accessibilityHidden(true)
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
            .modifier(CopyCellMenu(table: opaqueHeader ? table : nil, row: r, column: c))
    }

    private func text(_ markdown: String, column c: Int, header: Bool) -> some View {
        Text(MarkdownView.inline(MarkdownTableMetrics.shownCell(markdown)))
            .font(header ? font.weight(.semibold) : font)
            .lineLimit(wraps ? nil : lineLimit)
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
        let value = Text(MarkdownView.inline(MarkdownTableMetrics.shownCell(table.cell(row: r, column: c), limit: TextPieces.Limits.largestAccessibility.chars)))
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
