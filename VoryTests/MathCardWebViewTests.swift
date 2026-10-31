import Foundation
import SwiftUI
import Testing
import WebKit
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

    /// A web view that records the pages loaded into it instead of loading them, so no web content process starts.
    final class RecordingWebView: WKWebView {
        var pages: [String] = []
        override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
            pages.append(string)
            return nil
        }
    }

    /// When WebKit ends a card's web content process, the card loads its own page again, as a load of its own that
    /// the navigation rule lets through; twice at most, so a page that ends it every time doesn't loop.
    @MainActor @Test func aCardLoadsItsPageAgainWhenItsWebContentEnds() {
        let card = MathWebView(equation: "x^2", document: "<p>x</p>", height: .constant(48), contentWidth: .constant(0), loaded: .constant(false))
        let coordinator = card.makeCoordinator()
        let web = RecordingWebView(frame: .zero, configuration: WKWebViewConfiguration())
        coordinator.load(into: web)
        coordinator.load(into: web)
        #expect(web.pages == ["<p>x</p>"])
        #expect(coordinator.pendingLoads == 1)
        coordinator.webViewWebContentProcessDidTerminate(web)
        #expect(web.pages == ["<p>x</p>", "<p>x</p>"])
        #expect(coordinator.pendingLoads == 2)
        #expect(MathCard.allowsNavigation(to: URL(string: "about:blank"), isMainFrame: true, pendingLoads: coordinator.pendingLoads))
        coordinator.webViewWebContentProcessDidTerminate(web)
        #expect(web.pages.count == 3)
        coordinator.webViewWebContentProcessDidTerminate(web)
        coordinator.webViewWebContentProcessDidTerminate(web)
        #expect(web.pages.count == 3)
        #expect(coordinator.pendingLoads == 3)
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
