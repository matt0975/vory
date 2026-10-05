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
        var filter = Incremental()
        let pieces = filter.feed(markdown) + filter.finish()
        return pieces.joined(separator: " ").replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same filter fed a reply as it streams. Each `feed` returns the pieces that are safe
    /// to say now: finished lines, and finished sentences of a long paragraph, so the voice can
    /// start before the model has finished writing. What is still open (a line, a fence, a
    /// table) is held until more arrives or `finish()`.
    public struct Incremental: Sendable {
        /// The line being written, not yet released.
        private var held = ""
        private var inFence: String? = nil
        private var fenceLang = ""
        private var tableRows = 0
        /// A line with a pipe but no outer pipes may be a table's header (the app renders tables
        /// written that way too); the delimiter row that decides comes next, so it is held.
        private var pendingPipeLine: String?

        public init() {}

        public mutating func feed(_ delta: String) -> [String] {
            held += delta
            var out: [String] = []
            while let newline = held.firstIndex(of: "\n") {
                let line = String(held[..<newline])
                held = String(held[held.index(after: newline)...])
                out += consume(line: line)
            }
            // A long paragraph: its finished sentences go out before the line ends.
            if inFence == nil, !held.contains("|"), let cut = Self.sentenceCut(held) {
                let head = String(held[..<cut])
                held = String(held[cut...])
                out += consume(line: head)
            }
            return out
        }

        /// The last words, and the note for a fence left open.
        public mutating func finish() -> [String] {
            var out = consume(line: held)
            held = ""
            // The last line had a pipe and nothing came after it: its words, not a table.
            out += releasePending()
            if inFence != nil { out.append(Self.note(forFence: fenceLang)); inFence = nil }
            out += flushTable()
            return out
        }

        private mutating func consume(line: String) -> [String] {
            // Pictures are shown, not read: a MEDIA: reference or a bare image path says nothing
            // (the voice once read a file path out loud).
            let trimmed = MediaScan.textWithoutMedia(line).trimmingCharacters(in: .whitespaces)
            if let fence = inFence {
                if trimmed.hasPrefix(fence) { inFence = nil; return [Self.note(forFence: fenceLang)] }
                return []
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let out = releasePending() + flushTable()
                inFence = String(trimmed.prefix(3))
                fenceLang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                return out
            }
            // Tables: a row with outer pipes counts at once; a header without them counts once
            // the delimiter row under it says so, else its words are said after all.
            if pendingPipeLine != nil {
                if Self.isDelimiterRow(trimmed) { pendingPipeLine = nil; tableRows += 2; return [] }
                return releasePending() + consume(line: line)
            }
            if (trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 1) || (tableRows > 0 && trimmed.contains("|")) { tableRows += 1; return [] }
            if tableRows == 0, trimmed.contains("|") { pendingPipeLine = trimmed; return [] }
            if trimmed.isEmpty { return flushTable() }
            var out = flushTable()
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { return out }
            let words = inlineForSpeech(trimmed)
            if !words.isEmpty { out.append(words) }
            return out
        }

        private mutating func flushTable() -> [String] {
            defer { tableRows = 0 }
            return tableRows > 0 ? [tableOmitted] : []
        }

        /// The held pipe line was not a table's header after all: its words.
        private mutating func releasePending() -> [String] {
            guard let p = pendingPipeLine else { return [] }
            pendingPipeLine = nil
            let words = inlineForSpeech(p)
            return words.isEmpty ? [] : [words]
        }

        /// `---|:--:|--:` and the like: only pipes, colons, dashes and spaces, with a dash in it.
        static func isDelimiterRow(_ t: String) -> Bool {
            t.contains("-") && !t.isEmpty && t.allSatisfy { "|:- ".contains($0) }
        }

        private static func note(forFence lang: String) -> String {
            ["html", "htm"].contains(lang.lowercased()) ? cardOmitted : codeOmitted
        }

        /// Where an unfinished line can be cut after a whole sentence: the last sentence end
        /// followed by a space, with nothing left open before it (a backtick, a link, emphasis),
        /// and not so early that an abbreviation is mistaken for the end.
        static func sentenceCut(_ s: String) -> String.Index? {
            var cut: String.Index? = nil
            var backticks = 0, brackets = 0, parens = 0, stars = 0
            var i = s.startIndex
            while i < s.endIndex {
                let ch = s[i]
                switch ch {
                case "`": backticks += 1
                case "[": brackets += 1
                case "]": brackets -= 1
                case "(": parens += 1
                case ")": parens -= 1
                case "*": stars += 1
                default: break
                }
                let next = s.index(after: i)
                if ".!?…".contains(ch), next < s.endIndex, s[next] == " ",
                   backticks % 2 == 0, brackets == 0, parens == 0, stars % 2 == 0,
                   s.distance(from: s.startIndex, to: next) >= 12 {
                    cut = next
                }
                i = next
            }
            return cut
        }
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

    /// Whether `text` ends on a sentence end, so a streaming reader can say it now.
    public static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?…".contains(last)
    }
}
