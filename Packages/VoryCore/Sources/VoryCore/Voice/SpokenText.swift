import Foundation

/// What of a reply is read aloud: the bot's prose, as speech. Markdown is taken out, code
/// blocks become "Code omitted, it's in the app.", tables "There's a table in the app." and
/// HTML cards "There's a card in the app."; links read as their words. Tool calls, tool output,
/// thinking and helper rows never reach this: callers pass the assistant text only.
public enum SpokenText {
    public static let codeOmitted = "Code omitted, it's in the app."
    public static let tableOmitted = "There's a table in the app."
    public static let cardOmitted = "There's a card in the app."

    public static func forSpeech(_ markdown: String) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        var inFence: String? = nil
        var fenceLang = ""
        var tableRows = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { out.append(joined) }
            paragraph = []
        }
        func flushTable() {
            if tableRows > 0 { out.append(tableOmitted) }
            tableRows = 0
        }

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = inFence {
                if trimmed.hasPrefix(fence) {
                    inFence = nil
                    out.append(["html", "htm"].contains(fenceLang.lowercased()) ? cardOmitted : codeOmitted)
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph(); flushTable()
                inFence = String(trimmed.prefix(3))
                fenceLang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                flushParagraph()
                tableRows += 1
                continue
            }
            if trimmed.isEmpty { flushParagraph(); flushTable(); continue }
            flushTable()
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flushParagraph(); continue }
            paragraph.append(inlineForSpeech(trimmed))
        }
        if inFence != nil { out.append(["html", "htm"].contains(fenceLang.lowercased()) ? cardOmitted : codeOmitted) }
        flushParagraph(); flushTable()
        return out.joined(separator: " ").replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line of markdown as words: headings, bullets and numbering gone, emphasis marks gone,
    /// links as their text, inline code as its text, a sentence end added where a heading or a
    /// bullet had none so the voice pauses there.
    static func inlineForSpeech(_ line: String) -> String {
        var s = line
        var wasHeadingOrBullet = false
        if let m = s.firstMatch(of: /^#{1,6}\s+/) { s.removeSubrange(m.range); wasHeadingOrBullet = true }
        if let m = s.firstMatch(of: /^(?:[-*+]|\d+[.)])\s+/) { s.removeSubrange(m.range); wasHeadingOrBullet = true }
        if let m = s.firstMatch(of: /^>\s?/) { s.removeSubrange(m.range) }
        s = s.replacing(/!\[([^\]]*)\]\([^)]*\)/) { m in String(m.1).isEmpty ? "an image" : String(m.1) }
        s = s.replacing(/\[([^\]]+)\]\([^)]*\)/) { m in String(m.1) }
        s = s.replacing(/`([^`]*)`/) { m in String(m.1) }
        s = s.replacing(/\*\*([^*]+)\*\*/) { m in String(m.1) }
        s = s.replacing(/__([^_]+)__/) { m in String(m.1) }
        // No lookbehind in Swift's regex engine: the character before the mark is kept by hand.
        s = s.replacing(/(^|[^\w*])\*([^*]+)\*(?!\w)/) { m in String(m.1) + String(m.2) }
        s = s.replacing(/(^|[^\w_])_([^_]+)_(?!\w)/) { m in String(m.1) + String(m.2) }
        s = s.replacing(/~~([^~]+)~~/) { m in String(m.1) }
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.trimmingCharacters(in: .whitespaces)
        if wasHeadingOrBullet, let last = s.last, !".!?:;…".contains(last) { s += "." }
        return s
    }

    /// Sentences for one-at-a-time synthesis, so speech can start before a long reply is
    /// finished: split on sentence ends, short runs joined so a voice is not asked for "Yes."
    public static func sentences(_ text: String, minLength: Int = 24) -> [String] {
        var pieces: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?…".contains(ch) { pieces.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        var out: [String] = []
        for p in pieces where !p.isEmpty {
            if let last = out.last, last.count < minLength { out[out.count - 1] = last + " " + p } else { out.append(p) }
        }
        return out
    }
}
