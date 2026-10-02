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

/// Block-level markdown splitter for incremental rendering. Inline styling is delegated to
/// `AttributedString(markdown:)`; an unterminated code fence is still rendered as code so the
/// block stabilizes as soon as the closing fence streams in.
public enum MarkdownBlock: Hashable, Identifiable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, text: String, closed: Bool)
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
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: [MarkdownListItem] = []
        var listOrdered = false
        var indentStack: [Int] = []
        var counters: [Int: Int] = [:]
        var quote: [String] = []
        var code: [String]? = nil
        var codeLang: String? = nil
        var fence = ""

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

        let lines = stripFrontMatter(text.replacingOccurrences(of: "\r\n", with: "\n")).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var codeLines = code {
                if trimmed.hasPrefix(fence) {
                    out.append(.code(language: codeLang, text: codeLines.joined(separator: "\n"), closed: true))
                    code = nil; codeLang = nil
                } else {
                    codeLines.append(line); code = codeLines
                }
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
            if trimmed.isEmpty { flushAll(); continue }
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
        if let codeLines = code { out.append(.code(language: codeLang, text: codeLines.joined(separator: "\n"), closed: false)) }
        flushAll()
        return out
    }

    /// Inline markdown → AttributedString, falling back to plain text.
    public static func inline(_ text: String) -> AttributedString {
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

    /// Splits a table row into cells. `\|` and pipes inside inline code spans do not split.
    static func tableCells(_ row: String) -> [String] {
        let t = row.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var cur = ""
        var inCode = false
        var escaped = false
        for ch in t {
            if escaped {
                // The escape is consumed only for the pipe; any other escape is kept for inline parsing.
                if ch != "|" { cur.append("\\") }
                cur.append(ch); escaped = false; continue
            }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|", !inCode { cells.append(cur); cur = ""; continue }
            cur.append(ch)
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
