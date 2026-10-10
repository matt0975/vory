import Foundation
import SwiftUI
import Testing
@testable import Vory

/// "@name" mentions (#302): which words count, where, and that code is left alone.
@Suite struct MentionsTests {
    private let names = Mentions.Names(bots: ["ops", "ops-bot", "Writer"], person: "Sam Lee")

    private func found(_ text: String) -> [(String, String?)] {
        Mentions.find(in: text, names: names).map { (String(text[$0.range]), $0.bot) }
    }

    @Test func knownBotsAndThePersonAreFoundAndUnknownNamesStayPlain() {
        #expect(found("Handing this to @ops now").map(\.0) == ["@ops"])
        #expect(found("Handing this to @ops now").first?.1 == "ops")
        // Case does not matter; the longest name wins; a trailing dot is not part of it.
        #expect(found("@Writer and @ops-bot, then @OPS.").map(\.0) == ["@Writer", "@ops-bot", "@OPS"])
        #expect(found("@Writer and @ops-bot, then @OPS.").map(\.1) == ["Writer", "ops-bot", "ops"])
        // The person: "@you", the name without spaces, or its first word.
        #expect(found("over to @you and @SamLee and @sam").map(\.1) == [nil, nil, nil])
        // Unknown, or not at a word's start, or part of a longer word: plain.
        #expect(found("ask @nobody, mail me@ops.example, and @opsx").isEmpty)
        #expect(found("no mentions here").isEmpty)
    }

    @Test func codeIsLeftAloneAndOtherTextIsMarked() throws {
        let a = try AttributedString(markdown: "Ping @ops, not `@ops` in code", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let marked = Mentions.mark(a, names: names)
        let links = marked.runs.compactMap { $0.link }
        #expect(links.count == 1)
        #expect(links.first.flatMap(Mentions.bot(from:)) == "ops")
        // The code span kept no link and no colour.
        let codeRuns = marked.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        #expect(!codeRuns.isEmpty)
        #expect(codeRuns.allSatisfy { $0.link == nil && $0.foregroundColor == nil })
    }

    @Test func thePersonGetsTheStrongerMark() {
        let marked = Mentions.attributed("That one is for @you.", names: names)
        let run = marked.runs.first { $0.backgroundColor != nil }
        #expect(run != nil)
        #expect(run?.link == nil)
    }

    @Test func aBotLinkRoundTrips() throws {
        let url = try #require(Mentions.url(for: "ops-bot"))
        #expect(Mentions.bot(from: url) == "ops-bot")
        #expect(Mentions.bot(from: URL(string: "https://example.com/bot/ops")!) == nil)
    }
}
