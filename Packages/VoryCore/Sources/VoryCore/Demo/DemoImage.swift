import CoreGraphics
import Foundation
import ImageIO

/// The demo's pictures, drawn on the spot as PNGs (so there is no asset to license or ship): a bar chart of the
/// e-readers' battery life, and a line of a day's traffic for a home server's check. Any other image path gets a
/// soft gradient, as the mock's do.
enum DemoImage {
    static func png(for path: String) -> Data? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasPrefix("ereader-battery") { return draw(width: 640, height: 400) { bars($0, values: [8, 5, 6], width: 640, height: 400) } }
        if name.hasPrefix("traffic-") {
            let seed = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            return draw(width: 640, height: 320) { line($0, seed: seed, width: 640, height: 320) }
        }
        let seed = path.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return draw(width: 480, height: 300) { gradient($0, seed: seed, width: 480, height: 300) }
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> Data? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        body(ctx)
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func axis(_ ctx: CGContext, width: Int, height: Int) {
        ctx.setStrokeColor(CGColor(srgbRed: 0.8, green: 0.8, blue: 0.83, alpha: 1))
        ctx.setLineWidth(2)
        for i in 0...4 {
            let y = 40 + CGFloat(i) * CGFloat(height - 80) / 4
            ctx.move(to: CGPoint(x: 40, y: y)); ctx.addLine(to: CGPoint(x: CGFloat(width - 30), y: y))
        }
        ctx.strokePath()
    }

    private static let palette: [CGColor] = [
        CGColor(srgbRed: 0.23, green: 0.48, blue: 1.0, alpha: 1),
        CGColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1),
        CGColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1),
    ]

    private static func bars(_ ctx: CGContext, values: [Double], width: Int, height: Int) {
        axis(ctx, width: width, height: height)
        let top = values.max() ?? 1
        let slot = CGFloat(width - 100) / CGFloat(values.count)
        for (i, v) in values.enumerated() {
            let h = CGFloat(v / top) * CGFloat(height - 100)
            let rect = CGRect(x: 60 + CGFloat(i) * slot + slot * 0.15, y: 40, width: slot * 0.7, height: h)
            ctx.setFillColor(palette[i % palette.count])
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.fillPath()
        }
    }

    private static func line(_ ctx: CGContext, seed: Int, width: Int, height: Int) {
        axis(ctx, width: width, height: height)
        var rng = DemoRandom(seed: UInt64(seed))
        let points = (0..<24).map { h -> CGPoint in
            let day = 0.5 - 0.45 * cos(Double(h) / 24 * 2 * .pi)
            let v = min(1, max(0.05, day + (rng.unit() - 0.5) * 0.15))
            return CGPoint(x: 40 + CGFloat(h) * CGFloat(width - 70) / 23, y: 40 + CGFloat(v) * CGFloat(height - 80))
        }
        ctx.setStrokeColor(palette[0])
        ctx.setLineWidth(5)
        ctx.setLineJoin(.round)
        ctx.addLines(between: points)
        ctx.strokePath()
    }

    private static func gradient(_ ctx: CGContext, seed: Int, width: Int, height: Int) {
        let hue = Double(seed % 360) / 360
        let a = CGColor(srgbRed: 0.55 + 0.4 * hue, green: 0.7, blue: 0.95 - 0.4 * hue, alpha: 1)
        let b = CGColor(srgbRed: 0.95, green: 0.85 - 0.3 * hue, blue: 0.6 + 0.3 * hue, alpha: 1)
        guard let g = CGGradient(colorsSpace: nil, colors: [a, b] as CFArray, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [])
    }
}

/// A small seeded generator, so the demo's numbers and pictures are the same on every run.
struct DemoRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
}
