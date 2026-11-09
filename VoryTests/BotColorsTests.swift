import Foundation
import Testing
import SwiftUI
@testable import Vory

@MainActor
struct BotColorsTests {
    @Test func whiteColorConvertsToWhiteHex() {
        let white = Color(red: 1.0, green: 1.0, blue: 1.0)
        #expect(white.hexString.uppercased() == "#FFFFFF")
    }

    @Test func grayColorConvertsToGrayHex() {
        let gray = Color(red: 0.5, green: 0.5, blue: 0.5)
        #expect(gray.hexString.uppercased() == "#808080")
    }

    #if canImport(UIKit)
    @Test func monochromeWhiteAndGrayscaleConvertsCorrectly() {
        let monoWhite = Color(uiColor: UIColor(white: 1.0, alpha: 1.0))
        #expect(monoWhite.hexString.uppercased() == "#FFFFFF")
        let monoDark = Color(uiColor: UIColor(white: 0.2, alpha: 1.0))
        #expect(monoDark.hexString.uppercased() == "#333333")
    }
    #endif

    @Test func customRGBColorConvertsToHex() {
        let orange = Color(red: 1.0, green: 0.5, blue: 0.0)
        #expect(orange.hexString.uppercased() == "#FF8000")
    }

    @Test func hexParsingSucceedsForValidStrings() {
        let color = Color(hex: "#007AFF")
        #expect(color != nil)
        let noHash = Color(hex: "007AFF")
        #expect(noHash != nil)
    }

    @Test func hexParsingFailsForInvalidStrings() {
        #expect(Color(hex: "invalid") == nil)
        #expect(Color(hex: "#123") == nil)
        #expect(Color(hex: "") == nil)
    }
}
