import SwiftUI
import VoryCore

/// "@name" in a reply, a Reasoning card or the voice transcript, drawn in that bot's own
/// colour so hand-offs between bots stand out in group chats; a mention of the person reading
/// ("@you", or their name from Settings) gets a stronger mark. Never inside code spans or code
/// blocks; an unknown @name stays plain text. A bot's mention is a link that opens its card
/// (`vory://bot/<name>`, taken by the conversation's openURL) (#302).
enum Mentions {
    struct Names: Hashable, Sendable {
        /// Bot names and labels, as typed after the "@" (compared without case).
        var bots: [String] = []
        /// The person's own name from Settings; "you" always counts.
        var person: String? = nil
    }

    /// The names the thread on screen knows, set by it from the gateway's bots and Settings.
    @MainActor static var names = Names()

    /// Every name a bot answers to, for the thread's list: the folder name, the gateway's
    /// display name, and the name Vory keeps for it (#315), without repeats.
    static func botNames(for profiles: [ProfileInfo]) -> [String] {
        var out: [String] = []
        for p in profiles {
            for n in [p.name, p.displayName ?? "", p.label] {
                let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !out.contains(where: { $0.lowercased() == t.lowercased() }) { out.append(t) }
            }
        }
        return out
    }

    struct Mention: Equatable {
        var range: Range<String.Index>
        /// The bot's name as the gateway knows it (nil for the person).
        var bot: String?
        var person: Bool { bot == nil }
    }

    static let scheme = "vory"
    static func url(for bot: String) -> URL? {
        var c = URLComponents(); c.scheme = scheme; c.host = "bot"; c.path = "/" + bot
        return c.url
    }
    static func bot(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "bot" else { return nil }
        let name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
        return name.isEmpty ? nil : name
    }

    /// The person's handles: "you", and their name with its spaces closed up or just its first word.
    static func personHandles(_ person: String?) -> [String] {
        var out = ["you"]
        if let p = person?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            out.append(p.replacingOccurrences(of: " ", with: ""))
            if let first = p.split(separator: " ").first { out.append(String(first)) }
        }
        return out.map { $0.lowercased() }
    }

    /// Every mention in plain words: an "@" at a word's start, then a known name, ending at a
    /// word's end. The longest known name wins ("@ops-bot" over "@ops").
    static func find(in text: String, names: Names) -> [Mention] {
        let bots = names.bots.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let people = personHandles(names.person).sorted { $0.count > $1.count }
        var out: [Mention] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "@", i == text.startIndex || !isWord(text[text.index(before: i)]) else { i = text.index(after: i); continue }
            let after = text.index(after: i)
            // The candidate: word characters, dots and dashes after the "@".
            var j = after
            while j < text.endIndex, isWord(text[j]) || text[j] == "." || text[j] == "-" { j = text.index(after: j) }
            let word = String(text[after..<j]).lowercased()
            var matched: Mention?
            for b in bots where word == b.lowercased() || (word.hasPrefix(b.lowercased()) && boundary(word, after: b.count)) {
                matched = Mention(range: i..<text.index(after, offsetBy: b.count), bot: b); break
            }
            if matched == nil {
                for p in people where word == p || (word.hasPrefix(p) && boundary(word, after: p.count)) {
                    matched = Mention(range: i..<text.index(after, offsetBy: p.count), bot: nil); break
                }
            }
            if let m = matched { out.append(m); i = m.range.upperBound } else { i = j > after ? j : after }
        }
        return out
    }

    private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    /// A candidate longer than the name only counts when what follows is not a word's letter
    /// ("@ops." at a sentence's end, not "@opsx").
    private static func boundary(_ word: String, after n: Int) -> Bool {
        let idx = word.index(word.startIndex, offsetBy: n)
        return idx == word.endIndex || !isWord(word[idx])
    }

    /// The text with its mentions marked: a bot's in its colour, bold, as a link to its card;
    /// the person's bold on a tinted ground. Runs that are code are left alone.
    static func mark(_ a: AttributedString, names: Names) -> AttributedString {
        guard !names.bots.isEmpty || names.person != nil || true else { return a }
        var out = a
        for run in a.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) { continue }
            let piece = String(a[run.range].characters)
            guard piece.contains("@") else { continue }
            for m in find(in: piece, names: names) {
                // The run's range in the attributed string, offset by the mention's place in it.
                let lower = a.index(run.range.lowerBound, offsetByCharacters: piece.distance(from: piece.startIndex, to: m.range.lowerBound))
                let upper = a.index(run.range.lowerBound, offsetByCharacters: piece.distance(from: piece.startIndex, to: m.range.upperBound))
                if let bot = m.bot {
                    out[lower..<upper].foregroundColor = BotColors.color(for: bot)
                    out[lower..<upper].font = .body.weight(.semibold)
                    out[lower..<upper].link = url(for: bot)
                } else {
                    out[lower..<upper].foregroundColor = .accentColor
                    out[lower..<upper].font = .body.weight(.bold)
                    out[lower..<upper].backgroundColor = Color.accentColor.opacity(0.16)
                }
            }
        }
        return out
    }

    /// Plain words with their mentions marked (the voice transcript's lines).
    static func attributed(_ plain: String, names: Names) -> AttributedString {
        mark(AttributedString(plain), names: names)
    }
}

// MARK: - Chips (#321)

/// A bot's mention drawn as a chip: the text attribute `MentionChipRenderer` reads to draw the
/// pill behind the run (the bot's colour, light), with the bot's face set before the name.
struct MentionChipAttribute: TextAttribute {
    var color: Color
}

extension Mentions {
    /// The marked inline text as a `Text`, every bot mention as a chip: the bot's face (1 em),
    /// then its name, tagged for the renderer; the link to the bot's card stays on the name.
    /// Mentions of the person keep #302's stronger mark; code is never touched (it is not
    /// marked). The chip adds nothing to the line's height beyond the face's 1 em.
    @MainActor static func text(_ a: AttributedString) -> Text {
        var out = Text("")
        for run in a.runs {
            let slice = AttributedString(a[run.range])
            if run.math != nil || shouldFormatAsMath(slice) {
                out = out + math(slice)
                continue
            }
            guard let link = run.link, let bot = bot(from: link) else { out = out + Text(slice); continue }
            let color = BotColors.color(for: bot)
            var name = slice
            if name.characters.first == "@" { name = AttributedString(name[name.index(afterCharacter: name.startIndex)...]) }
            var chip = Text(name)
            if let face = face(for: bot) {
                // A narrow no-break space: the face and the name never part at a line's end.
                chip = Text(face).baselineOffset(-3) + Text("\u{202F}") + Text(name)
            }
            out = out + Text("\u{2009}") + chip.foregroundStyle(color).customAttribute(MentionChipAttribute(color: color)) + Text("\u{2009}")
        }
        return out
    }

    /// Fast check whether an un-attributed slice holds formatted math scripts or operators.
    private static func shouldFormatAsMath(_ slice: AttributedString) -> Bool {
        let s = String(slice.characters)
        return s.contains("₍") || s.contains("₎") || s.contains("^(") ||
               s.contains("∫") || s.contains("∑") || s.contains("∏") || s.contains("√")
    }

    /// An inline formula set as maths rather than as prose: serif, italic letters, and a script
    /// drawn as a script (`ℳ₍grass₎` is ℳ with "grass" below the baseline, not "ℳ(grass)").
    /// Long runs take the cheap path — one styled `Text`.
    @MainActor static func math(_ a: AttributedString) -> Text {
        let characters = a.characters
        guard characters.count <= 200 else { return Text(a).fontDesign(.serif).italic() }
        var out = Text("")
        for segment in MathNotation.segments(of: String(characters)) {
            let piece = serif(segment.text)
            switch segment.script {
            case .baseline: out = out + piece
            case .sub: out = out + piece.font(.system(.caption, design: .serif)).baselineOffset(-2.5)
            case .sup: out = out + piece.font(.system(.caption, design: .serif)).baselineOffset(4)
            }
        }
        return out
    }

    /// Serif, italic for the letters: a digit, an operator or a bracket is upright in KaTeX.
    /// The runs keep their order (`MathNotation.typeRuns`), so nothing is reordered.
    @MainActor static func serif(_ text: String) -> Text {
        var out = Text("")
        for run in MathNotation.typeRuns(text) {
            var piece = Text(AttributedString(run.text)).fontDesign(.serif)
            if run.italic { piece = piece.italic() }
            out = out + piece
        }
        return out
    }

    /// The bot's face at text size, where the app draws faces (the Mac adds its own).
    @MainActor static func face(for bot: String) -> Image? {
        // The same memoised face on both: the Mac draws it through its UIImage shims (NSImage).
        Image(uiImage: BotAvatarImage.cached(profile: bot, size: 17)).renderingMode(.original)
    }
}

/// Draws a light pill in the bot's colour behind each chip run, then the text as usual.
struct MentionChipRenderer: TextRenderer {
    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for line in layout {
            // One pill per chip: the face and the name are separate runs on the line, joined here.
            var pill: (rect: CGRect, color: Color)?
            func flush() {
                guard let p = pill else { return }
                let r = p.rect.insetBy(dx: -4, dy: -1.5)
                ctx.fill(Path(roundedRect: r, cornerRadius: r.height / 2, style: .continuous), with: .color(p.color.opacity(0.16)))
                pill = nil
            }
            for run in line {
                if let chip = run[MentionChipAttribute.self] {
                    let r = run.typographicBounds.rect
                    if let p = pill, p.color == chip.color, abs(p.rect.maxX - r.minX) < 6 { pill = (p.rect.union(r), p.color) }
                    else { flush(); pill = (r, chip.color) }
                } else { flush() }
            }
            flush()
            for run in line { ctx.draw(run) }
        }
    }
}
