import Testing
import SwiftUI
@testable import VoryCore
@testable import Vory
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@Suite struct MathCardViewRenderTests {

    @Test @MainActor func primedSnapshotRendersDirectlyWithoutWebView() {
        let equation = "\\sqrt{a^2 + b^2}"
        #if os(iOS)
        let sampleImage = UIImage(systemName: "function") ?? UIImage()
        #else
        let sampleImage = NSImage()
        #endif

        KaTeXCache.setSnapshot(sampleImage, for: equation, dark: false)
        KaTeXCache.setSnapshot(sampleImage, for: equation, dark: true)

        let view = MathCardView(equation: equation, closed: true)

        #if os(iOS)
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2.0
        let renderedImage = renderer.uiImage
        #expect(renderedImage != nil)
        #endif

        #expect(KaTeXCache.snapshot(for: equation, dark: true) === sampleImage)
        #expect(KaTeXCache.snapshot(for: equation, dark: false) === sampleImage)
    }

    @Test @MainActor func uncachedEquationRendersThroughKaTeXEngine() async {
        let equation = "E = mc^2"
        let markup = await KaTeXEngine.shared.render(latex: equation)
        #expect(!markup.isEmpty)
        #expect(KaTeXCache.markup(for: equation) != nil)
    }
}
