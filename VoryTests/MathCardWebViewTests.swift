import Foundation
import Testing
@testable import Vory

/// A math card's web view loads its own document and nothing else, and that document runs no script.
@Suite struct MathCardWebViewTests {

    /// Only the card's own load gets through: about:blank in the main frame, one per load it started.
    @Test func onlyTheCardsOwnLoadIsAllowed() {
        #expect(MathCard.allowsNavigation(to: URL(string: "about:blank"), isMainFrame: true, pendingLoads: 1))
        #expect(MathCard.allowsNavigation(to: nil, isMainFrame: true, pendingLoads: 1))
        #expect(!MathCard.allowsNavigation(to: URL(string: "about:blank"), isMainFrame: true, pendingLoads: 0))
        #expect(!MathCard.allowsNavigation(to: URL(string: "about:blank"), isMainFrame: false, pendingLoads: 1))
        for link in ["https://example.com", "http://example.com", "javascript:alert(1)", "file:///etc/hosts",
                     "data:text/html,x", "mailto:a@b.c"] {
            #expect(!MathCard.allowsNavigation(to: URL(string: link), isMainFrame: true, pendingLoads: 1), "\(link)")
        }
    }

    /// The document carries no script, and KaTeX (trust off) draws a `\href` or `\url` as an
    /// unsupported command, never as a link.
    @Test func theDocumentHoldsNoScriptOrLink() async {
        let markup = await KaTeXEngine.shared.render(latex: "\\href{javascript:alert(1)}{x} + \\url{https://example.com}")
        let doc = MathCard.document(mathMarkup: markup, dark: false).lowercased()
        #expect(!doc.contains("<script"))
        #expect(!doc.contains("<a "))
        #expect(!doc.contains("href="))
    }
}
