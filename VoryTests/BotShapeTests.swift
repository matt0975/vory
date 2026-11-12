#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Vory

/// A body shape is one outline, so no fill rule, rim or glass plate can split it (feedback on
/// 1.5 (17): the Bubble's tail drew as a second, lighter triangle with a white wedge where it
/// met the body). With VORY_SHAPE_SHOTS=<folder> the Bubble's stills are also written there, at
/// the sizes the app draws it (a row, the Bots card, the large face), painted and glass, light
/// and dark, eyes open and shut, for a look.
@MainActor @Suite struct BotShapeTests {
    @Test func bubbleIsOneOutline() {
        let path = BotFace.bodyPath("bubble", in: CGRect(x: 0, y: 0, width: 100, height: 100), time: 0, active: false)
        var outlines = 0
        path.forEach { if case .move = $0 { outlines += 1 } }
        #expect(outlines == 1)
    }

    @Test func bubbleStills() throws {
        guard let dir = ProcessInfo.processInfo.environment["VORY_SHAPE_SHOTS"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for finish in ["flat", "glass"] { for size in [CGFloat(40), 78, 132] { for dark in [false, true] { for shut in [false, true] {
            let spec = BotLookSpec(shape: "bubble", eyes: "classic", hex: "#3B7BFF", finish: finish)
            BotFace.stillBlink = shut ? 1 : 0
            let r = ImageRenderer(content: BotFaceView(spec: spec, size: size, active: false, drawn: true)
                .padding(8).background(dark ? Color.black : Color.white).environment(\.colorScheme, dark ? .dark : .light))
            r.scale = 3
            // The renderer draws when its image is read: the blink is reset after that.
            let png = try #require(r.uiImage?.pngData())
            BotFace.stillBlink = 0
            try png.write(to: folder.appendingPathComponent("bubble-\(finish)-\(Int(size))-\(dark ? "dark" : "light")\(shut ? "-shut" : "").png"))
        } } } }
    }
}
#endif
