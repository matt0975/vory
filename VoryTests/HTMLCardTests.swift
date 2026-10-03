import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// A fenced html block in a reply becomes a card; the parser's part of that.
@Suite struct HTMLCardFenceTests {
    @Test func anHTMLFenceInsideOtherContentIsItsOwnClosedBlock() {
        let text = "Here it is:\n\n```html\n<b>hi</b>\n<table></table>\n```\n\nSay the word."
        let blocks = MarkdownParser.blocks(from: text)
        #expect(blocks.count == 3)
        #expect(blocks[0] == .paragraph("Here it is:"))
        #expect(blocks[1] == .code(language: "html", text: "<b>hi</b>\n<table></table>", closed: true))
        #expect(blocks[2] == .paragraph("Say the word."))
        #expect(HTMLCard.isCard(language: "html") && HTMLCard.isCard(language: "HTML ") && HTMLCard.isCard(language: "htm"))
        #expect(!HTMLCard.isCard(language: "bash") && !HTMLCard.isCard(language: nil) && !HTMLCard.isCard(language: ""))
    }

    @Test func anUnclosedFenceIsStillCodeAndNotYetACard() {
        let blocks = MarkdownParser.blocks(from: "Drawing:\n\n```html\n<p>half")
        #expect(blocks.count == 2)
        #expect(blocks[1] == .code(language: "html", text: "<p>half", closed: false))
    }

    @Test func severalCardsInOneMessageStaySeparate() {
        let text = "```html\n<p>one</p>\n```\ntext between\n```html\n<p>two</p>\n```\n```js\nconsole.log(1)\n```"
        let blocks = MarkdownParser.blocks(from: text)
        let cards = blocks.compactMap { b -> String? in if case .code(let l, let t, true) = b, HTMLCard.isCard(language: l) { return t }; return nil }
        #expect(cards == ["<p>one</p>", "<p>two</p>"])
        #expect(blocks.contains(.code(language: "js", text: "console.log(1)", closed: true)))
    }
}

/// What the card loads and where it may go.
@Suite struct HTMLCardPolicyTests {
    @Test func aFragmentIsWrappedAndADocumentKeepsItsHead() {
        let wrapped = HTMLCard.document("<p>hi</p>", dark: true)
        #expect(wrapped.hasPrefix("<!doctype html><html><head>"))
        #expect(wrapped.contains("color-scheme: dark") && wrapped.contains("<body><p>hi</p></body>"))
        let doc = HTMLCard.document("<html><head><title>T</title><style>p{color:red}</style></head><body><p>x</p></body></html>", dark: false)
        #expect(doc.contains("<head><meta charset=\"utf-8\">"))
        #expect(doc.contains("<title>T</title>") && doc.contains("p{color:red}") && doc.contains("color-scheme: light"))
        #expect(doc.components(separatedBy: "<head").count == 2)
    }

    @Test func onlyTheFirstLoadStaysInsideAndLinksGoOutside() {
        #expect(HTMLCard.navigation(to: URL(string: "about:blank"), isMainFrame: true, initialLoad: true) == .allow)
        #expect(HTMLCard.navigation(to: nil, isMainFrame: true, initialLoad: true) == .allow)
        #expect(HTMLCard.navigation(to: URL(string: "https://example.com/logs"), isMainFrame: true, initialLoad: false) == .openOutside)
        #expect(HTMLCard.navigation(to: URL(string: "https://example.com/"), isMainFrame: true, initialLoad: true) == .openOutside)
        #expect(HTMLCard.navigation(to: URL(string: "mailto:a@b.c"), isMainFrame: true, initialLoad: false) == .openOutside)
        #expect(HTMLCard.navigation(to: URL(string: "javascript:alert(1)"), isMainFrame: true, initialLoad: false) == .block)
        #expect(HTMLCard.navigation(to: URL(string: "file:///etc/passwd"), isMainFrame: true, initialLoad: false) == .block)
        #expect(HTMLCard.navigation(to: URL(string: "https://example.com/frame"), isMainFrame: false, initialLoad: false) == .block)
    }

    @Test func theRuleListIsValidAndBlocksEverythingButHTTPS() throws {
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(HTMLCard.ruleListJSON.utf8)) as? [[String: Any]])
        let filters = rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        #expect(filters.contains("^http://") && filters.contains("^file://") && filters.contains("^ws://"))
        #expect(!filters.contains("^https://"))
        #expect(rules.allSatisfy { (($0["action"] as? [String: Any])?["type"] as? String) == "block" })
    }
}
