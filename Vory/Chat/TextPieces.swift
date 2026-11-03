import SwiftUI
import VoryCore

/// A long text drawn as a stack of `Text`s of bounded size (#361, 1.5 (25)).
///
/// One `Text` is drawn as one picture. Past the graphics card's largest texture (16,384 px, about 5,400 pt at 3x)
/// that picture cannot be made: a long turn's reasoning opened, or a reply with a 2,000-line code block, showed as an
/// empty grey box, and on the phone the next change to it could end the app (1.1 (6) died the same way, then from
/// the whole thread laid out at once). Cut into pieces, each its own `Text`, every piece stays well under the limit;
/// a short text is drawn as one `Text`, as before.
///
/// A piece's size follows the text size (`Limits.for`). The bound is worked out for a column 150 pt wide, narrower
/// than any the thread has (a group chat's bubble beside its bots on a phone, an iPad in Slide Over), at 3x, with a
/// character half the font's size wide and a line 1.2 times it: at the default sizes 2,000 characters and 60 lines
/// come to about 3,800 pt (11,400 px); at the largest accessibility size 300 characters and 25 lines to about
/// 4,900 pt (14,800 px); the limit is 16,384 px.
enum TextPieces {
    /// Most characters and lines in a piece. Lines count too: many short lines make a tall piece out of few
    /// characters (a code block of braces).
    struct Limits: Hashable, Sendable {
        var chars: Int
        var lines: Int

        static let standard = Limits(chars: 2_000, lines: 60)
        /// The text sizes past the default and up to the largest that is not an accessibility size.
        static let larger = Limits(chars: 1_200, lines: 50)
        static let accessibility = Limits(chars: 500, lines: 30)
        static let largestAccessibility = Limits(chars: 300, lines: 25)

        static func `for`(_ size: DynamicTypeSize) -> Limits {
            switch size {
            case ...DynamicTypeSize.large: .standard
            case ...DynamicTypeSize.xxxLarge: .larger
            case ...DynamicTypeSize.accessibility2: .accessibility
            default: .largestAccessibility
            }
        }
    }
    /// The standard piece's characters, for what is not drawn in the thread's sizes (a table cell's cap).
    static let limit = Limits.standard.chars
    static let maxLines = Limits.standard.lines
    /// What a fold, a note or a bubble shows at most; the whole text is a Show all away.
    static let foldCap = 20_000

    /// Whether `text` is drawn in pieces. Its UTF-8 length is at least its character count, so a text under the limit
    /// in bytes is under it in characters too.
    static func isLong(_ text: some StringProtocol, _ limits: Limits = .standard) -> Bool {
        let u = text.utf8
        if u.count > limits.chars { return true }
        guard u.count > limits.lines else { return false }
        var lines = 0
        for b in u where b == 0x0A {
            lines += 1
            if lines >= limits.lines { return true }
        }
        return false
    }

    /// The pieces of `text`, as character offsets, in order. A piece ends at a line break (the break itself belongs to
    /// neither piece: the next one starts on a new line), else in its second half after a sentence's end (prose
    /// only), else after a space, else at the last whole character that fits (a URL, base64 or a run of hashes with
    /// nothing to break at: never inside a character, so never inside an emoji sequence). Every cut depends only on
    /// the text up to it, so text added at the end (a reply streaming) changes the last piece and nothing before it.
    static func ranges(_ text: String, code: Bool = false, _ limits: Limits = .standard) -> [Range<Int>] {
        let limit = limits.chars, maxLines = limits.lines
        var out: [Range<Int>] = []
        var start = text.startIndex
        var startOffset = 0
        let end = text.endIndex
        let half = limit / 2
        while start < end {
            var i = start, n = 0, lines = 0
            var lastLine: (Int, String.Index)?, lastSentence: (Int, String.Index)?, lastSpace: (Int, String.Index)?
            var previous: Character?
            var cut: (end: Int, next: Int, nextIndex: String.Index)?
            while i < end {
                if n == limit { break }
                let c = text[i]
                let after = text.index(after: i)
                if c.isNewline {
                    lines += 1
                    if lines >= maxLines { cut = (n, n + 1, after); break }
                    if n >= half { lastLine = (n, after) }
                } else if c == " " || c == "\t" {
                    if n >= half {
                        lastSpace = (n + 1, after)
                        if !code, let p = previous, p == "." || p == "!" || p == "?" || p == "…" { lastSentence = (n + 1, after) }
                    }
                }
                previous = c
                i = after
                n += 1
            }
            if cut == nil {
                if i == end { out.append(startOffset..<(startOffset + n)); break }
                if let (k, next) = lastLine { cut = (k, k + 1, next) }
                else if let (k, next) = lastSentence { cut = (k, k, next) }
                else if let (k, next) = lastSpace { cut = (k, k, next) }
                else { cut = (n, n, i) }
            }
            guard let c = cut else { break }
            out.append(startOffset..<(startOffset + c.end))
            startOffset += c.next
            start = c.nextIndex
        }
        return out
    }

    /// `ranges`, kept for the text: a row drawn again (the lazy thread, a streaming reply's other rows) does not cut
    /// it again. The key is everything the cut reads: the text, prose or code, and the limits; nothing else (no width,
    /// no font) goes into it. Bounded by the texts' length.
    static func cachedRanges(_ text: String, code: Bool = false, _ limits: Limits = .standard) -> [Range<Int>] {
        let key = Key(text, code, limits)
        if let hit = cache.object(forKey: key) { return hit.ranges }
        let r = ranges(text, code: code, limits)
        cache.setObject(Box(r), forKey: key, cost: text.utf8.count)
        return r
    }

    /// The pieces of a plain text.
    static func strings(_ text: String, code: Bool = false, _ limits: Limits = .standard) -> [String] {
        var out: [String] = []
        var i = text.startIndex, at = 0
        for r in cachedRanges(text, code: code, limits) {
            i = text.index(i, offsetBy: r.lowerBound - at)
            let j = text.index(i, offsetBy: r.count)
            out.append(String(text[i..<j]))
            i = j; at = r.upperBound
        }
        return out
    }

    /// The pieces of styled text (a paragraph's inline markdown, mentions marked), its styling kept.
    static func attributed(_ a: AttributedString, _ limits: Limits = .standard) -> [AttributedString] {
        var out: [AttributedString] = []
        var i = a.startIndex, at = 0
        for r in cachedRanges(String(a.characters), code: false, limits) {
            i = a.characters.index(i, offsetBy: r.lowerBound - at)
            let j = a.characters.index(i, offsetBy: r.count)
            out.append(AttributedString(a[i..<j]))
            i = j; at = r.upperBound
        }
        return out
    }

    /// At most `foldCap` characters of `text`, cut at a line break or a space, and how much was left out in bytes
    /// (counted without walking the rest: a reasoning of megabytes is drawn again on every update while it streams).
    /// How many lines `text` has, and its first `cap` of them, in one pass over its bytes without splitting it. A
    /// tool's output can be megabytes in tens of thousands of lines, and a code block split it into lines on every
    /// redraw: a big card took most of a second to open or close (#421).
    static func lines(_ text: String, cap: Int) -> (count: Int, head: Substring) {
        var text = text
        text.makeContiguousUTF8()
        let (count, headBytes): (Int, Int?) = text.utf8.withContiguousStorageIfAvailable { buf in
            guard let base = buf.baseAddress else { return (1, nil) }
            var count = 1, headBytes: Int?
            var p = UnsafeRawPointer(base)
            let end = p + buf.count
            while p < end, let hit = memchr(p, 0x0A, end - p) {
                let nl = UnsafeRawPointer(hit)
                // The newline after the cap-th line: the head is everything before it.
                if count == cap { headBytes = nl - UnsafeRawPointer(base) }
                count += 1
                p = nl + 1
            }
            return (count, headBytes)
        } ?? (1, nil)
        guard let headBytes else { return (count, text[...]) }
        return (count, text[..<text.utf8.index(text.utf8.startIndex, offsetBy: headBytes)])
    }

    static func capped(_ text: String) -> (text: String, more: Int) {
        guard text.utf8.count > foldCap, let end = text.index(text.startIndex, offsetBy: foldCap, limitedBy: text.endIndex), end < text.endIndex else {
            return (text, 0)
        }
        let head = text[..<end]
        let shown = String(text[..<(head.lastIndex(where: \.isNewline) ?? head.lastIndex(of: " ") ?? end)])
        return (shown, text.utf8.count - shown.utf8.count)
    }

    private final class Box { let ranges: [Range<Int>]; init(_ r: [Range<Int>]) { ranges = r } }
    private final class Key: NSObject {
        let text: String, code: Bool, limits: Limits
        private let hashed: Int
        init(_ text: String, _ code: Bool, _ limits: Limits) {
            self.text = text; self.code = code; self.limits = limits
            var h = Hasher(); h.combine(text); h.combine(code); h.combine(limits); hashed = h.finalize()
        }
        override var hash: Int { hashed }
        override func isEqual(_ other: Any?) -> Bool {
            guard let o = other as? Key else { return false }
            return o.code == code && o.limits == limits && o.text == text
        }
    }
    /// NSCache is thread-safe.
    nonisolated(unsafe) private static let cache: NSCache<Key, Box> = {
        let c = NSCache<Key, Box>(); c.countLimit = 400; c.totalCostLimit = 8_000_000; return c
    }()
}

/// A plain text that may be long: one `Text` when it is short, a stack of pieces when it is not (`TextPieces`).
/// Modifiers for text (font, colour, selection) reach the pieces through the environment; VoiceOver reads the pieces
/// as one element, as it read the single `Text`.
struct LongText: View {
    var text: String
    /// Code: cut at line breaks and spaces only, never after a sentence's end.
    var code = false
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ text: String, code: Bool = false) { self.text = text; self.code = code }

    var body: some View {
        let limits = TextPieces.Limits.for(typeSize)
        if TextPieces.isLong(text, limits) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(TextPieces.strings(text, code: code, limits).enumerated()), id: \.offset) { _, piece in
                    Text(piece).modifier(PieceProbe.Measure())
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(text).modifier(PieceProbe.Measure())
        }
    }
}

/// A paragraph's styled text (`MarkdownView.inlineText`): one `Text`, or its pieces when it is long for the text size,
/// with the mention chips drawn where there is an "@".
struct InlineText: View {
    var text: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let limits = TextPieces.Limits.for(typeSize)
        // The chip renderer only where there is a mention: on every paragraph it sized and drew
        // each line itself, a cost in every long reply's layout with nothing to show for it (1.5 (24)).
        let mention = text.utf8.contains(UInt8(ascii: "@"))
        let math = MathNotation.mayContainMath(text)
        if TextPieces.isLong(text, limits) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(TextPieces.attributed(MarkdownView.inline(text), limits).enumerated()), id: \.offset) { _, piece in
                    Group {
                        if mention { Mentions.text(piece).textRenderer(MentionChipRenderer()) }
                        else if math { Mentions.text(piece) }
                        else { Text(piece) }
                    }
                    .modifier(PieceProbe.Measure())
                }
            }
            .accessibilityElement(children: .combine)
        } else if mention {
            Mentions.text(MarkdownView.inline(text)).textRenderer(MentionChipRenderer()).modifier(PieceProbe.Measure())
        } else if math {
            Mentions.text(MarkdownView.inline(text)).modifier(PieceProbe.Measure())
        } else {
            Text(MarkdownView.inline(text)).modifier(PieceProbe.Measure())
        }
    }
}

/// Debug only, behind `-vory-piece-probe`: the tallest text the thread has drawn, in points and in pixels, for the
/// UI test that checks it against the graphics card's limit (#361). Nothing is measured without the argument.
@MainActor @Observable final class PieceProbe {
    static let shared = PieceProbe()
    #if DEBUG
    let on = ProcessInfo.processInfo.arguments.contains("-vory-piece-probe")
    #else
    let on = false
    #endif
    private(set) var tallestPoints: CGFloat = 0
    private(set) var tallestPixels: CGFloat = 0
    private(set) var texts = 0

    func report(points: CGFloat, scale: CGFloat) {
        texts += 1
        if points > tallestPoints { tallestPoints = points; tallestPixels = points * scale }
    }
    var summary: String { "tallest \(Int(tallestPoints)) pt, \(Int(tallestPixels)) px, \(texts) texts" }

    struct Measure: ViewModifier {
        @Environment(\.displayScale) private var scale
        func body(content: Content) -> some View {
            if PieceProbe.shared.on {
                content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { PieceProbe.shared.report(points: $0, scale: scale) }
            } else {
                content
            }
        }
    }
}

/// A line under a capped text: how much was left out, and "Show all" where the whole text has a place to go. It takes
/// the colour around it (white in the person's own bubble), "Show all" underlined.
struct MoreTextNote: View {
    /// What was left out, in bytes (`TextPieces.capped`).
    var more: Int
    var action: (() -> Void)? = nil
    var body: some View {
        let size = ByteCountFormatter.string(fromByteCount: Int64(more), countStyle: .file)
        let label = Text("\(size) more").font(.caption)
        if let action {
            Button(action: action) { Text("\(label) · \(Text("Show all").underline())").font(.caption) }
                .buttonStyle(.plain)
                .accessibilityLabel("\(size) more. Show all")
        } else {
            label.foregroundStyle(.secondary)
        }
    }
}
