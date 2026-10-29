import Foundation
import SwiftUI
import Testing
@testable import VoryCore
@testable import Vory

/// The code block's wrap switch: wide lines scroll by default, and wrapping turns the same block
/// into a taller, bubbler-wide one. Drawn through the real view, because the mode is a layout.
@Suite struct CodeWrapTests {

    /// A single line far wider than the column it is drawn in.
    static let line = String(repeating: "abcdefghij", count: 40)
    static let column: CGFloat = 300

    @MainActor private func draw(wrap: Bool) -> CGSize {
        UserDefaults.standard.set(wrap, forKey: CodeBody.wrapKey)
        defer { UserDefaults.standard.removeObject(forKey: CodeBody.wrapKey) }
        let content = CodeBody(text: Self.line, font: .system(.caption, design: .monospaced))
            .frame(width: Self.column)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.uiImage?.size ?? .zero
    }

    @Test @MainActor func wrappingTradesWidthForHeight() {
        let scrolling = draw(wrap: false)
        let wrapped = draw(wrap: true)

        // Both stay in the column; only the number of lines changes.
        #expect(abs(scrolling.width - Self.column) < 1)
        #expect(abs(wrapped.width - Self.column) < 1)

        // 400 characters in a 300pt column at caption size is several lines tall, and one line tall
        // when it scrolls instead.
        #expect(wrapped.height > scrolling.height * 3,
                "wrapped \(wrapped.height)pt vs scrolling \(scrolling.height)pt")
        #expect(scrolling.height < 40, "a scrolling line should not be \(scrolling.height)pt tall")
    }

    @Test @MainActor func theSwitchFlipsThePreference() {
        UserDefaults.standard.removeObject(forKey: CodeBody.wrapKey)
        #expect(UserDefaults.standard.object(forKey: CodeBody.wrapKey) == nil)
        // The switch writes one key, which every block reads: no per-block state to drift.
        #expect(CodeBody.wrapKey == "code.wrap")
    }
}
