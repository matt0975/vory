#if os(macOS)
import Foundation
import Testing
@testable import Vory

/// The Mac paints the card's own colour into the page (a Mac web view always draws a
/// background, and the private way of turning that off is gone): one colour per scheme, as
/// CSS, and the document carries it.
@Suite struct MacCardBackgroundTests {
    @MainActor @Test func thePageGetsTheCardsColourInEachScheme() throws {
        let light = HTMLCard.pageBackground(dark: false)
        let dark = HTMLCard.pageBackground(dark: true)
        let hex = try! NSRegularExpression(pattern: "^#[0-9A-F]{6}$")
        for h in [light, dark] {
            let s = try #require(h)
            #expect(hex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil)
        }
        #expect(light != dark)
        let doc = HTMLCard.document("<p>hi</p>", dark: false, background: light)
        #expect(doc.contains("background: \(light!)") && !doc.contains("background: transparent"))
        // Nothing asked for: the page stays see-through (the phone's way).
        #expect(HTMLCard.document("<p>hi</p>", dark: false).contains("background: transparent"))
    }
}
#endif
