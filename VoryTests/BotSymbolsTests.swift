import SwiftUI
import Testing
@testable import Vory

/// The symbols' geometry (1.5, #304): every one fits its square, the lighter insides sit within
/// their silhouettes, and the eyes' seats are inside the symbols that keep eyes.
@Suite struct BotSymbolsTests {
    let box = CGRect(x: 10, y: 20, width: 100, height: 100)

    @Test func everySymbolFitsItsSquare() {
        for v in BotVisual.allCases where v != .rest {
            let p = BotSymbols.path(v, in: box)
            #expect(!p.isEmpty, "\(v) draws nothing")
            let b = p.boundingRect
            #expect(box.insetBy(dx: -1, dy: -1).contains(b), "\(v) leaves the square: \(b)")
            #expect(b.width > 20 && b.height > 20, "\(v) is tiny: \(b)")
        }
        #expect(BotSymbols.path(.rest, in: box).isEmpty)
    }

    @Test func theLighterInsidesSitWithinTheirSilhouettes() {
        for v in [BotVisual.lens, .warn] {
            let outer = BotSymbols.path(v, in: box), inner = BotSymbols.inner(v, in: box)
            #expect(inner != nil, "\(v) has no inner panel")
            guard let inner else { continue }
            let ib = inner.boundingRect
            // The inner panel's middle, its top and bottom midpoints, and two points a quarter
            // of the way out from the middle (a triangle's bounds are wider than its waist).
            for c in [CGPoint(x: ib.midX, y: ib.minY + 1), CGPoint(x: ib.midX - ib.width / 4, y: ib.midY), CGPoint(x: ib.midX + ib.width / 4, y: ib.midY), CGPoint(x: ib.midX, y: ib.maxY - 1), CGPoint(x: ib.midX, y: ib.midY)] {
                #expect(outer.contains(c), "\(v): inner point \(c) is outside the silhouette")
            }
        }
        #expect(BotSymbols.inner(.toolbox, in: box) == nil, "the toolbox has no hole or panel (decision B)")
    }

    @Test func theInkMarksSitInsideTheirSymbols() {
        for v in [BotVisual.warn, .toolbox] {
            let outer = BotSymbols.path(v, in: box)
            guard let ink = BotSymbols.ink(v, in: box) else { Issue.record("\(v) has no mark"); continue }
            let b = ink.boundingRect
            #expect(outer.contains(CGPoint(x: b.midX, y: b.midY)), "\(v): the mark is off the symbol")
        }
    }

    @Test func theEyesSeatInsideTheSymbolsThatKeepThem() {
        for v in [BotVisual.orb, .lens, .toolbox] {
            guard let a = BotSymbols.eyeAnchor(v) else { Issue.record("\(v) has no eye seat"); continue }
            let outer = BotSymbols.path(v, in: box)
            let left = CGPoint(x: box.minX + (a.x - a.spread) * 100, y: box.minY + a.y * 100)
            let right = CGPoint(x: box.minX + (a.x + a.spread) * 100, y: box.minY + a.y * 100)
            #expect(outer.contains(left) && outer.contains(right), "\(v): an eye sits outside the symbol")
        }
        for v in [BotVisual.bolt, .bubbles, .warn, .exclaim] { #expect(BotSymbols.eyeAnchor(v) == nil && v.hidesEyes) }
    }

    @Test func theArcsStandOffTheBody() {
        let p = BotSymbols.arcs(in: box, amount: 1)
        let b = p.boundingRect
        #expect(b.width > box.width, "the arcs should reach past the square's sides: \(b)")
    }

    @Test func theArcsAreTwoStrokesWithNothingAcrossTheFace() throws {
        // Stroked as the face strokes them (s × 0.05 wide, round caps) into a bitmap 0.3 s wider than the square on
        // every side, since the arcs stand past it. In one subpath the second arc began with a straight line from the
        // first's end: a bar across the face at mid − r·sin 0.38 (#516).
        let p = BotSymbols.arcs(in: box, amount: 1)
        let s = min(box.width, box.height), r = s * 0.61, c = CGPoint(x: box.midX, y: box.midY)
        let canvas = box.insetBy(dx: -0.3 * s, dy: -0.3 * s)
        let w = Int(canvas.width), h = Int(canvas.height)
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Rows counted from the top, as the path's y runs.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -canvas.minX, y: -canvas.minY)
        ctx.addPath(p.cgPath)
        ctx.setLineWidth(s * 0.05)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.strokePath()
        let pixels = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        func alpha(_ pt: CGPoint) -> UInt8 { pixels[Int(pt.y - canvas.minY) * w * 4 + Int(pt.x - canvas.minX) * 4 + 3] }
        let across = CGPoint(x: box.midX, y: c.y - r * sin(0.38))
        #expect(alpha(across) == 0, "a stroke runs across the face between the arcs, at \(across)")
        for angle: CGFloat in [0, .pi] {
            let onArc = CGPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
            #expect(alpha(onArc) > 0, "the arc at angle \(angle) isn't drawn, at \(onArc)")
        }
    }
}
