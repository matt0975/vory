import Testing
import Foundation
@testable import VoryCore
@testable import Vory
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@Suite struct MathCardSnapshotCacheTests {
    @Test func cacheSnapshotStorageAndRetrieval() {
        let latex = "\\frac{a}{b}"
        #if os(iOS)
        let sampleImageDark = UIImage()
        let sampleImageLight = UIImage()
        #else
        let sampleImageDark = NSImage()
        let sampleImageLight = NSImage()
        #endif

        KaTeXCache.setSnapshot(sampleImageDark, for: latex, dark: true)
        KaTeXCache.setSnapshot(sampleImageLight, for: latex, dark: false)

        let hitDark = KaTeXCache.snapshot(for: latex, dark: true)
        let hitLight = KaTeXCache.snapshot(for: latex, dark: false)
        let missUnknown = KaTeXCache.snapshot(for: "\\sum_{i=0}^n x_i", dark: true)

        #expect(hitDark === sampleImageDark)
        #expect(hitLight === sampleImageLight)
        #expect(missUnknown == nil)
    }

    @Test func cacheDifferentiatesEquations() {
        let eq1 = "E = mc^2"
        let eq2 = "e^{i\\pi} + 1 = 0"
        #if os(iOS)
        let img1 = UIImage()
        let img2 = UIImage()
        #else
        let img1 = NSImage()
        let img2 = NSImage()
        #endif

        KaTeXCache.setSnapshot(img1, for: eq1, dark: true)
        KaTeXCache.setSnapshot(img2, for: eq2, dark: true)

        #expect(KaTeXCache.snapshot(for: eq1, dark: true) === img1)
        #expect(KaTeXCache.snapshot(for: eq2, dark: true) === img2)
    }
}
