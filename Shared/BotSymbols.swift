import SwiftUI

/// The exact shapes a working bot becomes (1.5, #304): the orb, the lens, the toolbox, the
/// warning triangle, the exclamation, the bolt and the three bubbles, each drawn into the bot's
/// square. Outer silhouettes only; where a symbol has a lighter inside (the lens glass, the
/// warning panel) that is a second filled path on top, never a hole, so nothing needs a blend
/// mode and the glass plate keeps one solid shape. The toolbox handle is solid for the same
/// reason. Numbers from the approved preview.
public enum BotSymbols {
    /// The symbol's silhouette in `box` (a square; the drawing passes the bot's frame).
    public static func path(_ visual: BotVisual, in box: CGRect) -> Path {
        let s = min(box.width, box.height)
        let o = box.origin
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: o.x + x * s, y: o.y + y * s, width: w * s, height: h * s) }
        var p = Path()
        switch visual {
        case .rest:
            return p
        case .orb:
            p.addEllipse(in: rect(0.04, 0.04, 0.92, 0.92))
        case .lens:
            // The glass: a circle a little up and left; the handle: a rounded bar at 45 degrees
            // from the rim toward the bottom-right corner.
            p.addEllipse(in: rect(0.16, 0.16, 0.60, 0.60))
            let handle = Path(roundedRect: CGRect(x: -0.055 * s, y: 0, width: 0.11 * s, height: 0.36 * s), cornerRadius: 0.055 * s)
            let t = CGAffineTransform(translationX: pt(0.68, 0.68).x, y: pt(0.68, 0.68).y).rotated(by: -.pi / 4)
            p.addPath(handle.applying(t))
        case .toolbox:
            p.addRoundedRect(in: rect(0.10, 0.38, 0.80, 0.52), cornerSize: CGSize(width: 0.08 * s, height: 0.08 * s), style: .continuous)
            // The handle, solid (decision B): a rounded bar standing on the lid.
            p.addRoundedRect(in: rect(0.36, 0.20, 0.28, 0.24), cornerSize: CGSize(width: 0.06 * s, height: 0.06 * s), style: .continuous)
        case .warn:
            p = roundedTriangle(apex: pt(0.5, 0.08), left: pt(0.06, 0.90), right: pt(0.94, 0.90), corner: 0.10 * s)
        case .exclaim:
            p.addRoundedRect(in: rect(0.38, 0.06, 0.24, 0.56), cornerSize: CGSize(width: 0.12 * s, height: 0.12 * s), style: .continuous)
            p.addEllipse(in: rect(0.38, 0.72, 0.24, 0.24))
        case .bolt:
            let pts: [(CGFloat, CGFloat)] = [(0.06, 0.52), (0.50, 0.10), (0.43, 0.44), (0.94, 0.48), (0.50, 0.90), (0.57, 0.56)]
            p.move(to: pt(pts[0].0, pts[0].1))
            for q in pts.dropFirst() { p.addLine(to: pt(q.0, q.1)) }
            p.closeSubpath()
        case .bubbles:
            for x in [0.23, 0.50, 0.77] as [CGFloat] { p.addEllipse(in: rect(x - 0.12, 0.38, 0.24, 0.24)) }
        }
        return p
    }

    /// The lighter inside some symbols carry (decision 1): the lens glass, the warning panel.
    /// Drawn over the silhouette in a light colour so the dark marks inside read in dark mode.
    public static func inner(_ visual: BotVisual, in box: CGRect) -> Path? {
        let s = min(box.width, box.height)
        let o = box.origin
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        switch visual {
        case .lens:
            return Path(ellipseIn: CGRect(x: o.x + 0.22 * s, y: o.y + 0.22 * s, width: 0.48 * s, height: 0.48 * s))
        case .warn:
            return roundedTriangle(apex: pt(0.5, 0.26), left: pt(0.20, 0.82), right: pt(0.80, 0.82), corner: 0.06 * s)
        default:
            return nil
        }
    }

    /// The dark marks drawn in ink over a symbol: the warning's exclamation, the toolbox's lid line.
    public static func ink(_ visual: BotVisual, in box: CGRect) -> Path? {
        let s = min(box.width, box.height)
        let o = box.origin
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: o.x + x * s, y: o.y + y * s, width: w * s, height: h * s) }
        switch visual {
        case .warn:
            var p = Path()
            p.addRoundedRect(in: rect(0.455, 0.38, 0.09, 0.26), cornerSize: CGSize(width: 0.045 * s, height: 0.045 * s))
            p.addEllipse(in: rect(0.45, 0.68, 0.10, 0.10))
            return p
        case .toolbox:
            var p = Path()
            p.addRect(rect(0.14, 0.53, 0.72, 0.012))
            return p
        default:
            return nil
        }
    }

    /// Where the eyes sit inside a symbol (fraction of the square, and how far apart); nil for
    /// the symbols that take the eyes with them and for the rest body (its shape decides).
    public static func eyeAnchor(_ visual: BotVisual) -> (x: CGFloat, y: CGFloat, spread: CGFloat)? {
        switch visual {
        case .orb: return (0.5, 0.47, 0.13)
        case .lens: return (0.46, 0.44, 0.09)
        case .toolbox: return (0.5, 0.66, 0.13)
        default: return nil
        }
    }

    /// The symbol's bottom edge as a fraction of the square, for seating on a pill.
    public static func baseline(_ visual: BotVisual) -> CGFloat {
        switch visual {
        case .orb: 0.96
        case .lens: 0.95
        case .toolbox: 0.90
        case .warn: 0.90
        case .exclaim: 0.96
        case .bolt: 0.90
        case .bubbles: 0.62
        case .rest: 0.985
        }
    }

    /// The listening arcs: two short arcs standing off the body's sides, each its own subpath. Each starts with a move
    /// to its own first point: without one, the second arc began with a straight line from the first's end, a bar
    /// across the face (appending each arc as a separate Path joins them the same way).
    public static func arcs(in box: CGRect, amount: Double) -> Path {
        let s = min(box.width, box.height)
        let c = CGPoint(x: box.midX, y: box.midY)
        let r = s * (0.56 + 0.05 * amount)
        var p = Path()
        for side in [-1.0, 1.0] as [Double] {
            let mid = side > 0 ? 0.0 : Double.pi
            p.move(to: CGPoint(x: c.x + r * cos(mid - 0.38), y: c.y + r * sin(mid - 0.38)))
            p.addArc(center: c, radius: r, startAngle: .radians(mid - 0.38), endAngle: .radians(mid + 0.38), clockwise: false)
        }
        return p
    }

    static func roundedTriangle(apex: CGPoint, left: CGPoint, right: CGPoint, corner: CGFloat) -> Path {
        let pts = [apex, right, left]
        var p = Path()
        for i in 0..<3 {
            let prev = pts[(i + 2) % 3], cur = pts[i], next = pts[(i + 1) % 3]
            func towards(_ a: CGPoint, _ b: CGPoint, _ d: CGFloat) -> CGPoint {
                let dx = b.x - a.x, dy = b.y - a.y, len = max(1, (dx * dx + dy * dy).squareRoot())
                return CGPoint(x: a.x + dx / len * d, y: a.y + dy / len * d)
            }
            let inPt = towards(cur, prev, corner), outPt = towards(cur, next, corner)
            if i == 0 { p.move(to: inPt) } else { p.addLine(to: inPt) }
            p.addQuadCurve(to: outPt, control: cur)
        }
        p.closeSubpath()
        return p
    }
}
