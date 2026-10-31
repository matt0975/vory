#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Vory

/// The bot's still symbols against recorded baselines (28 and
/// 64 pt in three colours, light and dark; everything else is an assertion). Every state's
/// still is drawn from the motion model's snapped frame and compared pixel by pixel with a
/// small tolerance. Set VORY_RECORD_BASELINES=1 to write the baselines into
/// VoryTests/Baselines/Bot (committed with the change that moved them).
@MainActor @Suite(.serialized) struct BotSnapshotTests {
    static let states: [BotFace.State] = [.idle, .thinking, .searching, .usingTool, .streaming, .awaitingApproval, .error, .reconnecting, .listening]
    static let colours = ["#3B7BFF", "#FF3B5C", "#34C759"]
    static let sizes: [CGFloat] = [28, 64]

    private static var folder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Baselines/Bot", isDirectory: true)
    }
    private static var recording: Bool { ProcessInfo.processInfo.environment["VORY_RECORD_BASELINES"] == "1" }

    private func render(_ hex: String, state: BotFace.State, size: CGFloat, dark: Bool) -> UIImage? {
        let spec = BotLookSpec(shape: "blob", eyes: "classic", hex: hex)
        let m = BotMotionModel(seed: 1)
        m.snap(to: .targets(for: state), at: 0)
        let frame = m.advance(to: 0, targets: .targets(for: state))
        let view = Canvas(opaque: false, rendersAsynchronously: false) { ctx, sz in
            BotFace.drawFrame(spec, in: &ctx, size: sz, frame: frame, light: !dark)
        }
        .frame(width: size, height: size)
        .background(dark ? Color.black : Color.white)
        let r = ImageRenderer(content: view)
        r.scale = 2
        return r.uiImage
    }

    private func name(_ hex: String, _ state: BotFace.State, _ size: CGFloat, _ dark: Bool) -> String {
        "\(state)-\(Int(size))-\(hex.dropFirst())-\(dark ? "dark" : "light").png"
    }

    /// Pixels that differ by more than 8/255 in any channel, as a share of all pixels.
    private func difference(_ a: UIImage, _ b: UIImage) -> Double? {
        guard let ca = a.cgImage, let cb = b.cgImage, ca.width == cb.width, ca.height == cb.height,
              let da = ca.dataProvider?.data, let db = cb.dataProvider?.data,
              let pa = CFDataGetBytePtr(da), let pb = CFDataGetBytePtr(db) else { return nil }
        let n = ca.width * ca.height
        var off = 0
        for i in 0..<n {
            for c in 0..<3 where abs(Int(pa[i * 4 + c]) - Int(pb[i * 4 + c])) > 8 { off += 1; break }
        }
        return Double(off) / Double(n)
    }

    @Test func everyStillMatchesItsBaseline() throws {
        let folder = Self.folder
        if Self.recording { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var missing: [String] = [], differing: [String] = []
        for hex in Self.colours { for state in Self.states { for size in Self.sizes { for dark in [false, true] {
            let img = try #require(render(hex, state: state, size: size, dark: dark))
            let file = folder.appendingPathComponent(name(hex, state, size, dark))
            if Self.recording {
                try img.pngData()?.write(to: file)
                continue
            }
            guard let data = try? Data(contentsOf: file), let base = UIImage(data: data) else { missing.append(file.lastPathComponent); continue }
            guard let d = difference(img, base) else { differing.append(file.lastPathComponent + " (size)"); continue }
            if d > 0.005 { differing.append("\(file.lastPathComponent) \(String(format: "%.2f%%", d * 100))") }
        } } } }
        if Self.recording { return }
        #expect(missing.isEmpty, "no baseline for: \(missing.prefix(8)) (VORY_RECORD_BASELINES=1 records them)")
        #expect(differing.isEmpty, "stills moved from their baselines: \(differing.prefix(8))")
    }
}
#endif
