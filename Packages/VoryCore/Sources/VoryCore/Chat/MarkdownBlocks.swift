import Foundation

/// One item of a (possibly nested) list.
public struct MarkdownListItem: Hashable, Sendable {
    public enum Marker: Hashable, Sendable {
        case bullet
        /// The ordinal to display, already resolved for its nesting level.
        case number(Int)
        case task(checked: Bool)
    }

    public var depth: Int
    public var marker: Marker
    public var text: String

    public init(depth: Int, marker: Marker, text: String) {
        self.depth = depth
        self.marker = marker
        self.text = text
    }
}

public enum MarkdownColumnAlignment: Hashable, Sendable {
    case leading, center, trailing
}

public struct MarkdownTable: Hashable, Sendable {
    public var header: [String]
    public var alignments: [MarkdownColumnAlignment]
    /// Every row has exactly `header.count` cells.
    public var rows: [[String]]

    public init(header: [String], alignments: [MarkdownColumnAlignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

// Computed only: `MarkdownBlock.id` hashes the table, so a stored property here would change
// every block's identity (and the rows would rebuild as the reply streams).
extension MarkdownTable {
    /// The cell at `row`, `column`, or "" past the end (a table built by hand can be ragged).
    public func cell(row: Int, column: Int) -> String {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return "" }
        return rows[row][column]
    }

    public func alignment(of column: Int) -> MarkdownColumnAlignment {
        alignments.indices.contains(column) ? alignments[column] : .leading
    }

    /// What VoiceOver reads for a body cell: the column's header, then the value
    /// ("Params: 744B"), with inline markdown reduced to its words so no asterisks are read out.
    public func spokenCell(row: Int, column: Int) -> String {
        let value = Self.plain(cell(row: row, column: column))
        let name = header.indices.contains(column) ? Self.plain(header[column]) : ""
        if name.isEmpty { return value }
        if value.isEmpty { return name }
        return "\(name): \(value)"
    }

    /// Inline markdown as plain words (`**a**` reads "a", a link reads its title). Cached: every
    /// cell's VoiceOver label is built from it each time the table is drawn.
    public static func plain(_ text: String) -> String {
        if let hit = plainCache.object(forKey: text as NSString) { return hit as String }
        let out = String(MarkdownParser.inline(text).characters).trimmingCharacters(in: .whitespaces)
        plainCache.setObject(out as NSString, forKey: text as NSString)
        return out
    }
    nonisolated(unsafe) private static let plainCache: NSCache<NSString, NSString> = { let c = NSCache<NSString, NSString>(); c.countLimit = 2000; return c }()

    /// The table written back out as GitHub-flavoured markdown, for Copy as Markdown. Pipes in a
    /// cell are escaped (the parser took `\|` as a literal pipe, inside code spans too), so the
    /// text parses back to the same table here and in other markdown readers.
    public var markdown: String {
        let width = header.count
        func line(_ cells: [String]) -> String {
            let padded = (0..<width).map { $0 < cells.count ? cells[$0] : "" }
            return "| " + padded.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        let delimiter = "| " + (0..<width).map { c -> String in
            switch alignment(of: c) {
            case .leading: "---"
            case .center: ":---:"
            case .trailing: "---:"
            }
        }.joined(separator: " | ") + " |"
        return ([line(header), delimiter] + rows.map(line)).joined(separator: "\n")
    }
}

/// Block-level markdown splitter for incremental rendering. Inline styling is delegated to
/// `AttributedString(markdown:)`; an unterminated code fence is still rendered as code so the
/// block stabilizes as soon as the closing fence streams in.
public enum MarkdownBlock: Hashable, Identifiable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, text: String, closed: Bool)
    /// A display math equation block ($$...$$ or \[...\]), closed when terminated.
    case math(equation: String, closed: Bool)
    /// A bullet, numbered or task list. Nesting is carried by each item's `depth`.
    case list([MarkdownListItem])
    case quote(String)
    case table(MarkdownTable)
    /// A line holding only an image, optionally wrapped in a link: `[![alt](src)](href)`.
    case image(alt: String, url: String, link: String?)
    case rule

    public var id: Int { hashValue }
}

public enum MarkdownParser {
    public static func blocks(from text: String) -> [MarkdownBlock] {
        parse(stripFrontMatter(text.replacingOccurrences(of: "\r\n", with: "\n")).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)).blocks
    }

    /// The settled part of a text that grows, and its blocks: everything through the last blank
    /// line outside a code fence that has a line after it. That blank line flushes every open
    /// block, so nothing written after it can change the blocks before it.
    public struct Settled: Sendable {
        public let text: String
        public let blocks: [MarkdownBlock]

        /// Whether `other` starts with this text, byte for byte. Compared in one call: a debug
        /// build's `utf8.starts(with:)` walked the bytes one by one and cost as much as the parse
        /// it saved.
        public func isStart(of other: String) -> Bool {
            var mine = text, other = other
            return mine.withUTF8 { p in other.withUTF8 { t in t.count >= p.count && (p.isEmpty || memcmp(t.baseAddress!, p.baseAddress!, p.count) == 0) } }
        }
    }

    /// `blocks(from:)` for a text that grows, as a streaming reply does: when `settled` is where
    /// the text starts, only what follows it is parsed. A long reply was parsed whole on every
    /// token. Returns the new settled part with the blocks, for the next call.
    public static func blocks(from text: String, after settled: Settled?) -> (blocks: [MarkdownBlock], settled: Settled?) {
        // Front matter is read off the whole text: such a text is parsed whole every time.
        guard !text.hasPrefix("---"), !text.hasPrefix("\u{FEFF}") else { return (blocks(from: text), nil) }
        let base = settled.flatMap { $0.isStart(of: text) ? $0 : nil }
        let tail = base.map { String(text[text.utf8.index(text.startIndex, offsetBy: $0.text.utf8.count)...]) } ?? text
        // Line ends written as CR LF are rewritten before the parse; nor is the parse split there.
        guard !tail.utf8.contains(13) else { return (blocks(from: text), nil) }
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parsed = parse(lines)
        let before = base?.blocks ?? []
        guard parsed.settledLines > 0 else { return (before + parsed.blocks, base) }
        let settledText = (base?.text ?? "") + lines[..<parsed.settledLines].joined(separator: "\n") + "\n"
        return (before + parsed.blocks, Settled(text: settledText, blocks: before + parsed.blocks[..<parsed.settledBlocks]))
    }

    /// The blocks of `lines`, and how many lines and blocks lie up to the last settling blank line.
    static func parse(_ lines: [String]) -> (blocks: [MarkdownBlock], settledLines: Int, settledBlocks: Int) {
        var out: [MarkdownBlock] = []
        var settledLines = 0, settledBlocks = 0
        var paragraph: [String] = []
        var list: [MarkdownListItem] = []
        var listOrdered = false
        var indentStack: [Int] = []
        var counters: [Int: Int] = [:]
        var quote: [String] = []
        var code: [String]? = nil
        var codeLang: String? = nil
        var fence = ""
        var math: [String]? = nil
        var mathFence = ""

        func flushParagraph() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushList() {
            if !list.isEmpty { out.append(.list(list)); list = [] }
            indentStack = []
            counters = [:]
        }
        func flushQuote() {
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        func flushLists() { flushList(); flushQuote() }
        func flushAll() { flushParagraph(); flushLists() }

        /// Appends a list item, resolving its depth from the indentation seen so far.
        func addItem(indent: Int, ordered: Bool, number: Int?, text itemText: String) {
            flushQuote()
            // A different kind of list starting at the top level begins a new block.
            if !list.isEmpty, listOrdered != ordered, indent <= (indentStack.first ?? 0) { flushList() }
            if list.isEmpty { listOrdered = ordered }

            while let last = indentStack.last, indent < last { indentStack.removeLast() }
            if indentStack.isEmpty || indent > (indentStack.last ?? 0) { indentStack.append(indent) }
            let depth = min(indentStack.count - 1, 6)

            for key in Array(counters.keys) where key > depth { counters[key] = nil }
            var body = itemText
            let marker: MarkdownListItem.Marker
            if ordered {
                let n = counters[depth].map { $0 + 1 } ?? (number ?? 1)
                counters[depth] = n
                marker = .number(n)
            } else {
                counters[depth] = nil
                if body == "[ ]" || body.hasPrefix("[ ] ") {
                    marker = .task(checked: false)
                    body = String(body.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                } else if body.lowercased() == "[x]" || body.lowercased().hasPrefix("[x] ") {
                    marker = .task(checked: true)
                    body = String(body.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                } else {
                    marker = .bullet
                }
            }
            list.append(MarkdownListItem(depth: depth, marker: marker, text: body))
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix(fence) {
                    out.append(.code(language: codeLang, text: code!.joined(separator: "\n"), closed: true))
                    code = nil; codeLang = nil
                } else {
                    // In place, with no second name on the array: a copy taken per line made a
                    // long block's parse grow with the square of its length, on the main
                    // thread, at every streaming redraw.
                    code!.append(line)
                }
                continue
            }
            if math != nil {
                if mathFence == "$$", let closeRange = trimmed.range(of: "$$") {
                    let before = String(trimmed[..<closeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if !before.isEmpty { math!.append(before) }
                    out.append(.math(equation: math!.joined(separator: "\n"), closed: true))
                    math = nil; mathFence = ""
                    let rem = String(trimmed[closeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !rem.isEmpty { paragraph.append(rem) }
                } else if mathFence == "\\[", let closeRange = trimmed.range(of: "\\]") {
                    let before = String(trimmed[..<closeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if !before.isEmpty { math!.append(before) }
                    out.append(.math(equation: math!.joined(separator: "\n"), closed: true))
                    math = nil; mathFence = ""
                    let rem = String(trimmed[closeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !rem.isEmpty { paragraph.append(rem) }
                } else if !mathFence.isEmpty && mathFence.hasPrefix("\\end{"), let closeRange = trimmed.range(of: mathFence) {
                    let before = String(trimmed[..<closeRange.upperBound])
                    math!.append(before)
                    out.append(.math(equation: math!.joined(separator: "\n"), closed: true))
                    math = nil; mathFence = ""
                    let rem = String(trimmed[closeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !rem.isEmpty { paragraph.append(rem) }
                } else {
                    math!.append(line)
                }
                continue
            }
            // LaTeX math environments: \begin{equation} ... \end{equation}, \begin{align} ... \end{align}, etc.
            if let envMatch = trimmed.firstMatch(of: /^\\begin\{(equation\*?|align\*?|alignat\*?|gather\*?|gathered|aligned|alignedat|matrix\*?|pmatrix\*?|bmatrix\*?|Bmatrix\*?|vmatrix\*?|Vmatrix\*?|cases|dcases|rcases|split|array)\}/) {
                let env = String(envMatch.1)
                let endTag = "\\end{\(env)}"
                flushAll()
                if let closeRange = trimmed.range(of: endTag) {
                    let eq = String(trimmed[..<closeRange.upperBound]).trimmingCharacters(in: .whitespaces)
                    out.append(.math(equation: eq, closed: true))
                    let rem = String(trimmed[closeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !rem.isEmpty { paragraph.append(rem) }
                } else {
                    mathFence = endTag
                    math = [line]
                }
                continue
            }
            if trimmed.hasPrefix("$$") {
                if let closeRange = trimmed.dropFirst(2).range(of: "$$") {
                    flushAll()
                    let eq = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<closeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    out.append(.math(equation: eq, closed: true))
                    let rem = String(trimmed[closeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !rem.isEmpty { paragraph.append(rem) }
                    continue
                }
                flushAll()
                mathFence = "$$"
                let rem = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                math = rem.isEmpty ? [] : [rem]
                continue
            }
            if trimmed.hasPrefix("\\[") {
                if let closeRange = trimmed.dropFirst(2).range(of: "\\]") {
                    flushAll()
                    let eq = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<closeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    out.append(.math(equation: eq, closed: true))
                    let rem = String(trimmed[closeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !rem.isEmpty { paragraph.append(rem) }
                    continue
                }
                flushAll()
                mathFence = "\\["
                let rem = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                math = rem.isEmpty ? [] : [rem]
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                codeLang = lang.isEmpty ? nil : lang
                code = []
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                // Settled once a line follows: the last line may still be growing.
                if i < lines.count { settledLines = i; settledBlocks = out.count }
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flushAll(); out.append(.rule); continue }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                if level <= 6, trimmed.dropFirst(level).hasPrefix(" ") {
                    flushAll(); out.append(.heading(level: level, text: trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces))); continue
                }
            }
            if let img = standaloneImage(trimmed) {
                flushAll(); out.append(.image(alt: img.alt, url: img.url, link: img.link)); continue
            }
            // A table needs its delimiter row, so a lone header line stays a paragraph until
            // the second line streams in.
            if trimmed.contains("|"), i < lines.count, let aligns = tableAlignments(lines[i]) {
                let header = tableCells(trimmed)
                if header.count == aligns.count {
                    flushAll()
                    i += 1
                    var rows: [[String]] = []
                    while i < lines.count {
                        let row = lines[i].trimmingCharacters(in: .whitespaces)
                        if row.isEmpty || !row.contains("|") { break }
                        var cells = tableCells(row)
                        if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                        if cells.count > header.count { cells = Array(cells.prefix(header.count)) }
                        rows.append(cells)
                        i += 1
                    }
                    out.append(.table(MarkdownTable(header: header, alignments: aligns, rows: rows)))
                    continue
                }
            }
            let indent = indentWidth(line)
            if let item = bulletItem(trimmed) {
                flushParagraph()
                addItem(indent: indent, ordered: false, number: nil, text: item); continue
            }
            if let numbered = numberedItem(trimmed) {
                flushParagraph()
                addItem(indent: indent, ordered: true, number: numbered.number, text: numbered.text); continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushList()
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)); continue
            }
            if !list.isEmpty, indent >= 2 { list[list.count - 1].text += " " + trimmed; continue }
            flushLists()
            paragraph.append(line)
        }
        if let mathLines = math { out.append(.math(equation: mathLines.joined(separator: "\n"), closed: false)) }
        if let codeLines = code { out.append(.code(language: codeLang, text: codeLines.joined(separator: "\n"), closed: false)) }
        flushAll()
        return (out, settledLines, settledBlocks)
    }

    /// Inline markdown → AttributedString, falling back to plain text.
    /// Preserves and formats inline LaTeX math ($...$, \(...\), and display delimiters written
    /// inside a paragraph) without markdown syntax conflicts.
    public static func inline(_ text: String) -> AttributedString {
        guard MathNotation.mayContainMath(text) else {
            return parseMarkdown(text)
        }

        let spans = MathNotation.findInlineMath(in: text)
        guard !spans.isEmpty else {
            // No delimited math: only the LaTeX loose in the prose needs reading.
            return parseMarkdown(MathNotation.formatNakedCommands(in: text))
        }

        // Each span is lifted out of the text before the markdown parse, so `_` and `*` inside a
        // formula cannot be read as emphasis, and put back afterwards from the attribute token.
        var sanitized = ""
        sanitized.reserveCapacity(text.count)
        var equations: [String: String] = [:]
        equations.reserveCapacity(spans.count)
        // One run id per call: a token only has to be unique within this string.
        let run = UUID().uuidString.prefix(8)
        var lastIndex = text.startIndex
        for (index, span) in spans.enumerated() {
            sanitized.append(contentsOf: text[lastIndex..<span.range.lowerBound])
            let token = "\u{FFFC}MATH\(run)\(index)\u{FFFC}"
            sanitized.append(token)
            equations[token] = span.equation
            lastIndex = span.range.upperBound
        }
        sanitized.append(contentsOf: text[lastIndex...])

        // Format any naked LaTeX commands outside code blocks (e.g. \LaTeX, \theta, \rightarrow, M_ (ghost))
        if MathNotation.mayContainMath(sanitized) {
            sanitized = MathNotation.formatNakedCommands(in: sanitized)
        }

        return restoreMath(in: parseMarkdown(sanitized), equations: equations)
    }

    /// Puts the formulas back where their tokens are, in one pass over the parsed string. (A
    /// `String(attr.characters)` rebuild per span made a paragraph with N formulas cost N
    /// reparses of the whole paragraph, on the main thread, at every streaming redraw.)
    private static func restoreMath(in attr: AttributedString, equations: [String: String]) -> AttributedString {
        let marker: Character = "\u{FFFC}"
        let chars = attr.characters
        guard chars.contains(marker) else { return attr }

        var out = AttributedString()
        var pieceStart = chars.startIndex
        var i = chars.startIndex
        while i < chars.endIndex {
            guard chars[i] == marker else {
                i = chars.index(after: i)
                continue
            }
            var close = chars.index(after: i)
            while close < chars.endIndex, chars[close] != marker { close = chars.index(after: close) }
            guard close < chars.endIndex else { break } // an unterminated token: keep the rest as it came
            let tokenEnd = chars.index(after: close)

            if pieceStart < i { out.append(attr[pieceStart..<i]) }
            let token = String(chars[i..<tokenEnd])
            if let equation = equations[token] {
                var mathPiece = AttributedString(MathNotation.format(equation))
                mathPiece.math = equation
                out.append(mathPiece)
            } else {
                // Not one of ours: hand the characters straight through.
                out.append(attr[i..<tokenEnd])
            }
            pieceStart = tokenEnd
            i = tokenEnd
        }
        if pieceStart < chars.endIndex { out.append(attr[pieceStart..<chars.endIndex]) }
        return out
    }

    private static func parseMarkdown(_ text: String) -> AttributedString {
        if let a = try? AttributedString(markdown: text, options: .init(allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)) {
            return a
        }
        return AttributedString(text)
    }

    // MARK: Helpers

    /// Drops a leading YAML front matter block (`---` … `---`). Only a closed block whose first
    /// line is a `key:` pair is hidden, so a reply that merely opens with a rule is untouched.
    static func stripFrontMatter(_ text: String) -> String {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        // Cheap exit for the common case: this runs on every streamed update.
        guard body.hasPrefix("---") else { return text }
        let all = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard all.count > 2, all[0].trimmingCharacters(in: .whitespaces) == "---",
              all[1].range(of: #"^[A-Za-z0-9_-]+\s*:"#, options: .regularExpression) != nil
        else { return text }
        guard let close = (2..<all.count).first(where: {
            let l = all[$0].trimmingCharacters(in: .whitespaces)
            return l == "---" || l == "..."
        }) else { return text }
        return all[(close + 1)...].joined(separator: "\n")
    }

    /// Leading whitespace width; a tab counts as four columns.
    static func indentWidth(_ line: String) -> Int {
        var w = 0
        for ch in line {
            if ch == " " { w += 1 } else if ch == "\t" { w += 4 } else { break }
        }
        return w
    }

    static func bulletItem(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func numberedItem(_ trimmed: String) -> (number: Int, text: String)? {
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (Int(digits) ?? 1, String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    private static let imagePattern = try! NSRegularExpression(
        pattern: #"^(\[)?!\[([^\]]*)\]\(\s*([^)\s]+)(?:\s+"[^"]*")?\s*\)(?:\]\(\s*([^)\s]+)\s*\))?$"#)

    /// `![alt](src "title")` or `[![alt](src)](href)` alone on a line.
    static func standaloneImage(_ trimmed: String) -> (alt: String, url: String, link: String?)? {
        guard trimmed.contains("![") else { return nil }
        let ns = trimmed as NSString
        guard let m = imagePattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let wrapped = m.range(at: 1).location != NSNotFound
        let hasLink = m.range(at: 4).location != NSNotFound
        guard wrapped == hasLink else { return nil }
        return (ns.substring(with: m.range(at: 2)),
                ns.substring(with: m.range(at: 3)),
                hasLink ? ns.substring(with: m.range(at: 4)) : nil)
    }

    /// Splits a table row into cells. `\|` and pipes inside inline code spans or inline math do not split.
    static func tableCells(_ row: String) -> [String] {
        let t = row.trimmingCharacters(in: .whitespaces)
        let mathSpans = MathNotation.findInlineMath(in: t)
        var cells: [String] = []
        var cur = ""
        var inCode = false
        var escaped = false
        var spanIndex = 0

        var i = t.startIndex
        while i < t.endIndex {
            if !inCode && spanIndex < mathSpans.count && i == mathSpans[spanIndex].range.lowerBound {
                let span = mathSpans[spanIndex]
                cur.append(contentsOf: t[span.range])
                i = span.range.upperBound
                spanIndex += 1
                continue
            }
            let ch = t[i]
            if escaped {
                if ch != "|" { cur.append("\\") }
                cur.append(ch); escaped = false
                i = t.index(after: i)
                continue
            }
            if ch == "\\" {
                escaped = true
                i = t.index(after: i)
                continue
            }
            if ch == "`" { inCode.toggle() }
            if ch == "|", !inCode {
                cells.append(cur)
                cur = ""
                i = t.index(after: i)
                continue
            }
            cur.append(ch)
            i = t.index(after: i)
        }
        if escaped { cur.append("\\") }
        cells.append(cur)
        // The last element is the trailing remainder: empty after a closing pipe.
        if t.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|"), !cells.isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The column alignments when `line` is a table delimiter row (`|:--|:-:|--:|`).
    static func tableAlignments(_ line: String) -> [MarkdownColumnAlignment]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.allSatisfy({ "|-: \t".contains($0) }) else { return nil }
        // A single column without any pipe is a rule, not a table.
        if !t.contains("|") { return nil }
        let cells = tableCells(t)
        guard !cells.isEmpty else { return nil }
        var out: [MarkdownColumnAlignment] = []
        for c in cells {
            let left = c.hasPrefix(":"), right = c.hasSuffix(":")
            let core = c.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            out.append(left && right ? .center : right ? .trailing : .leading)
        }
        return out
    }
}

/// A reply as it reads on screen, without its markdown: for Copy as Plain Text on the Mac (#402; Copy itself copies the
/// markdown, #255). Headings are their words on a line; list items keep their bullets or numbers, a nested item indented
/// by two spaces a level; code is as written; a table's rows are tab-separated; a quote is its words; a picture is its
/// alt text; a rule is left out. Inline marks go (`**a**` reads "a", a link its title). Blocks are a blank line apart.
public enum MarkdownPlainText {
    public static func from(_ markdown: String) -> String {
        var out: [String] = []
        for block in MarkdownParser.blocks(from: markdown) {
            switch block {
            case .paragraph(let t), .quote(let t):
                out.append(plainLines(t))
            case .heading(_, let t):
                out.append(MarkdownTable.plain(t))
            case .code(_, let t, _):
                out.append(t)
            case .math(let eq, _):
                out.append(MathNotation.format(eq))
            case .list(let items):
                out.append(items.map { item in
                    let marker: String
                    switch item.marker {
                    case .bullet: marker = "•"
                    case .number(let n): marker = "\(n)."
                    case .task(let checked): marker = checked ? "☑" : "☐"
                    }
                    return String(repeating: "  ", count: max(0, item.depth)) + marker + " " + plainLines(item.text)
                }.joined(separator: "\n"))
            case .table(let table):
                let rows = [table.header] + table.rows
                out.append(rows.map { $0.map(MarkdownTable.plain).joined(separator: "\t") }.joined(separator: "\n"))
            case .image(let alt, _, _):
                if !alt.isEmpty { out.append(alt) }
            case .rule:
                break
            }
        }
        return out.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Inline markdown as plain words, line by line, so a paragraph's own line breaks stay.
    private static func plainLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { MarkdownTable.plain(String($0)) }.joined(separator: "\n")
    }
}
