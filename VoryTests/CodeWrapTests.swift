import Foundation
import SwiftUI
import Testing
@testable import VoryCore
@testable import Vory

/// The code block's wrap switch: wrapping by default, unwrapping into a sideways scroll, and a
/// target big enough to hit. Drawn through the real view, because the mode is a layout.
@Suite struct CodeWrapTests {

    /// A single line far wider than the column it is drawn in.
    static let line = String(repeating: "abcdefghij", count: 40)
    static let column: CGFloat = 300

    @MainActor private func draw(_ view: some View) -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.uiImage?.size ?? .zero
    }

    @MainActor private func drawBlock() -> CGSize {
        draw(CodeBody(text: Self.line, font: .system(.caption, design: .monospaced)).frame(width: Self.column))
    }

    @Test @MainActor func wrappingIsTheDefault() {
        UserDefaults.standard.removeObject(forKey: CodeBody.wrapKey)
        let size = drawBlock()
        #expect(abs(size.width - Self.column) < 1)
        // 400 characters in a 300 pt column at caption size: several lines, not one.
        #expect(size.height > 40, "the default should wrap, and this block is \(size.height)pt tall")
    }

    @Test @MainActor func unwrappingTradesHeightForAWidthThatScrolls() {
        UserDefaults.standard.set(true, forKey: CodeBody.wrapKey)
        let wrapped = drawBlock()
        UserDefaults.standard.set(false, forKey: CodeBody.wrapKey)
        let scrolling = drawBlock()
        UserDefaults.standard.removeObject(forKey: CodeBody.wrapKey)

        // Both stay in the column; only the number of lines changes.
        #expect(abs(scrolling.width - Self.column) < 1)
        #expect(abs(wrapped.width - Self.column) < 1)
        #expect(wrapped.height > scrolling.height * 3,
                "wrapped \(wrapped.height)pt vs scrolling \(scrolling.height)pt")
        #expect(scrolling.height < 40, "a scrolling line should not be \(scrolling.height)pt tall")
    }

    @Test @MainActor func theSwitchIsFortyFourPointsToHit() {
        UserDefaults.standard.removeObject(forKey: CodeBody.wrapKey)
        let size = draw(CodeWrapToggle())
        #expect(size.width >= 44 && size.height >= 44,
                "the target is \(Int(size.width))x\(Int(size.height))pt")
    }

    @Test func oneKeyDrivesEveryBlock() {
        // The switch and the body read the same key: no per-block state to drift, and the choice
        // outlives the launch.
        #expect(CodeBody.wrapKey == "code.wrap")
    }
}
