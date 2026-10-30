import Foundation
import SwiftUI
import Testing
@testable import VoryCore
@testable import Vory

/// Renders inline maths through the real view layer into PNGs, so a subscript's size and drop
/// can be looked at rather than guessed. Debug aid: writes to ~/.hermes/cache/scratch/mathrender.
@Suite struct MathRenderSnapshotTests {

    static let samples: [(String, String)] = [
        ("manifold", "$(\\mathcal{M}_{\\text{grass}}, g_{\\mu\\nu})$"),
        ("pdf", "density $\\mathcal{N}_{\\mu,\\sigma^2}(\\cdot)$ here"),
        ("constants", "$e^{i\\pi}$, $i$, $\\pi$, $1$, $0$"),
        ("tuple", "$(e^{i\\pi}, \\, i, \\, \\pi, 1, 0)$"),
        ("norm", "$\\nabla_\\theta \\mathcal{L}$ and $\\|x\\|_2$"),
        ("power", "$\\mathbb{R}^{n \\times m}$ and $e^{-x^2}$"),
        ("plain", "The energy is $E = mc^2$ and $n\\log n$ is fine."),
        // Diagnostics for the missing items after a thin space.
        ("diag-no-thin", "$(e^{i\\pi}, i, \\pi, 1, 0)$"),
        ("diag-thin", "$(e^{i\\pi}, \\, i, \\, \\pi, 1, 0)$"),
        ("diag-space", "$(e^{i\\pi}, \\ i, \\ \\pi, 1, 0)$"),
        ("diag-prose-thin", "a\u{2009}i b\u{2009}\u{03C0} c"),
        ("diag-sup-only", "$e^{i\\pi}$ alone"),
    ]

    @Test @MainActor func renderSamplesToDisk() throws {
        let dir = URL(fileURLWithPath: "/Users/andrew/.hermes/cache/scratch/mathrender", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (name, source) in Self.samples {
            let attr = MarkdownParser.inline(source)
            let content = Mentions.text(attr)
                .font(.body)
                .foregroundStyle(.white)
                .padding(8)
                .background(Color(white: 0.12))

            let renderer = ImageRenderer(content: content)
            renderer.scale = 3
            guard let image = renderer.uiImage, let data = image.pngData() else {
                Issue.record("no image for \(name)")
                continue
            }
            try data.write(to: dir.appendingPathComponent("\(name).png"))
            print("wrote \(name).png  (\(Int(image.size.width))x\(Int(image.size.height)))  from: \(source)")
        }
    }
}
