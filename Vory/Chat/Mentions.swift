import SwiftUI
import VoryCore

/// "@name" in a reply, a Reasoning card or the voice transcript, drawn in that bot's own
/// colour so hand-offs between bots stand out in group chats; a mention of the person reading
/// ("@you", or their name from Settings) gets a stronger mark. Never inside code spans or code
/// blocks; an unknown @name stays plain text. A bot's mention is a link that opens its card
/// (`vory://bot/<name>`, taken by the conversation's openURL) (#302).
enum Mentions {
    struct Names: Equatable, Sendable {
        /// Bot names and labels, as typed after the "@" (compared without case).
        var bots: [String] = []
        /// The person's own name from Settings; "you" always counts.
        var person: String? = nil
    }

    /// The names the thread on screen knows, set by it from the gateway's bots and Settings.
    @MainActor static var names = Names()

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
