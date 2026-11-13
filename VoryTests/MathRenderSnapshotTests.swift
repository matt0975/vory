import Foundation
import SwiftUI
import Testing
@testable import VoryCore
@testable import Vory

/// Renders inline maths through the real view layer into PNGs, so a subscript's size and drop
/// can be looked at rather than guessed. Debug aid: writes to temporary directory under `mathrender/`.
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mathrender", isDirectory: true)
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

    static let displayMathSamples: [(String, String)] = [
        ("fraction", "\\frac{d}{dx}\\left(\\int_0^x f(t)\\,dt\\right) = f(x)"),
        ("matrix", "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}^{-1} = \\frac{1}{ad-bc}\\begin{pmatrix} d & -b \\\\ -c & a \\end{pmatrix}"),
        ("summation", "\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}"),
        ("maxwell", "\\nabla \\times \\mathbf{E} = -\\frac{\\partial \\mathbf{B}}{\\partial t}"),
    ]

    @Test @MainActor func renderDisplayMathCardsToDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mathrender-display", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (name, formula) in Self.displayMathSamples {
            let markup = await KaTeXEngine.shared.render(latex: formula)
            #expect(!markup.isEmpty)

            // Render a primed snapshot representing KaTeX 2D output
            let mathView = Text(MathNotation.format(formula))
                .font(.system(.title3, design: .serif))
                .italic()
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            let mathRenderer = ImageRenderer(content: mathView)
            mathRenderer.scale = 3.0
            let sampleImage = mathRenderer.uiImage ?? UIImage()

            KaTeXCache.setSnapshot(sampleImage, for: formula, dark: true)

            // Render display card with primed snapshot
            let cardView = MathCardView(equation: formula, closed: true)
            let renderer = ImageRenderer(content: cardView.environment(\.colorScheme, .dark).frame(width: 350))
            renderer.scale = 3.0
            guard let image = renderer.uiImage, let data = image.pngData() else {
                Issue.record("no rendered card image for \(name)")
                continue
            }
            try data.write(to: dir.appendingPathComponent("\(name).png"))
            #expect(image.size.width >= 350 && image.size.height >= 36)
            print("wrote display card \(name).png (\(Int(image.size.width))x\(Int(image.size.height))) for: \(formula)")
        }
    }
}
