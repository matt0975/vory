import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Vory
@testable import VoryCore

/// A real WKWebView with the card's coordinator: the navigation delegate is wired the way
/// WebKit looks it up, and a navigation the page starts on its own goes nowhere. (The closure
/// form of the delegate method only "nearly matched" the requirement once, so WebKit never saw
/// it and a tapped link loaded its page inside the card.)
@Suite struct HTMLCardWebViewTests {
    private final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }

    @MainActor @Test func theDelegateIsSeenByWebKitAndAScriptedNavigationStaysOnTheCard() async throws {
        let height = Box<CGFloat>(0)
        let loaded = Box(false)
        let html = "<p id=\"p\">hi</p><a href=\"https://example.com/x\">go</a>"
        let view = HTMLWebView(document: HTMLCard.document(html, dark: false), scrolls: false,
                               height: Binding(get: { height.v }, set: { height.v = $0 }),
                               loaded: Binding(get: { loaded.v }, set: { loaded.v = $0 }))
        let coordinator = view.makeCoordinator()
        let web = view.makeWebView(coordinator)
        // WebKit calls the policy method only when it is exposed under its selector.
        let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        #expect(web.navigationDelegate != nil && (web.navigationDelegate as AnyObject).responds(to: selector))
        // The card's own document loads.
        for _ in 0..<200 where !loaded.v { try await Task.sleep(for: .milliseconds(50)) }
        #expect(loaded.v)
        let text = try await web.evaluateJavaScript("document.getElementById('p').textContent") as? String
        #expect(text == "hi")
        // The page sends itself elsewhere: refused, the card stays on its document.
        _ = try? await web.evaluateJavaScript("location.href = 'https://example.com/x'; 0")
        try await Task.sleep(for: .milliseconds(800))
        #expect(web.url == nil || web.url?.absoluteString == "about:blank")
        let still = try await web.evaluateJavaScript("document.getElementById('p') ? document.getElementById('p').textContent : ''") as? String
        #expect(still == "hi")
    }
}
