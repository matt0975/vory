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

    @Test @MainActor func colorSchemeSwitchingDifferentiatesSnapshots() {
        let equation = "\\int_a^b f(x) dx"
        #if os(iOS)
        let lightImg = UIImage()
        let darkImg = UIImage()
        #else
        let lightImg = NSImage()
        let darkImg = NSImage()
        #endif

        KaTeXCache.setSnapshot(lightImg, for: equation, dark: false)
        KaTeXCache.setSnapshot(darkImg, for: equation, dark: true)

        let lightView = MathCardView(equation: equation, closed: true).environment(\.colorScheme, .light)
        let darkView = MathCardView(equation: equation, closed: true).environment(\.colorScheme, .dark)

        #expect(KaTeXCache.snapshot(for: equation, dark: false) === lightImg)
        #expect(KaTeXCache.snapshot(for: equation, dark: true) === darkImg)
    }
}
