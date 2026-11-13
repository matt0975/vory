import SwiftUI

/// A message bubble with the Messages tail: the edge on the speaker's side flows down into a
/// small point at the bottom corner, then curls back under. `tailed` false gives the plain
/// rounded bubble used for every message but the last of a run.
struct MessageBubbleShape: Shape {
    enum Side { case leading, trailing }
    var side: Side
    var tailed = true
    var radius: CGFloat = 18
    /// Room kept for the tail inside the rect, on the speaker's side: the bubble is drawn that
    /// much in from the edge, so the tail stays inside the view's bounds (`bubble(_:side:)`).
    var tailRoom: CGFloat = 0
    /// How far the tail reaches past the bubble's edge.
    static let tail: CGFloat = 6

    func path(in full: CGRect) -> Path {
        var rect = full
        rect.size.width -= tailRoom
        if side == .leading { rect.origin.x += tailRoom }
        let r = min(radius, rect.height / 2, rect.width / 2)
        guard tailed else { return Path(roundedRect: rect, cornerRadius: r, style: .continuous) }
        // Drawn for a trailing tail; mirrored for a leading one.
        let x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
        let tail = Self.tail
        var p = Path()
        p.move(to: CGPoint(x: x0 + r, y: y0))
        p.addLine(to: CGPoint(x: x1 - r, y: y0))
        p.addArc(center: CGPoint(x: x1 - r, y: y0 + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: x1, y: y1 - r))
        // The tail: the edge keeps going down and flares out to a point at the bottom…
        p.addCurve(to: CGPoint(x: x1 + tail, y: y1),
                   control1: CGPoint(x: x1, y: y1 - r * 0.45),
                   control2: CGPoint(x: x1 + tail * 0.9, y: y1 - r * 0.18))
        // …then sweeps back in under itself to the flat bottom edge.
        p.addCurve(to: CGPoint(x: x1 - r * 0.6, y: y1),
                   control1: CGPoint(x: x1 + tail * 0.25, y: y1),
                   control2: CGPoint(x: x1 - r * 0.12, y: y1 - r * 0.04))
        p.addLine(to: CGPoint(x: x0 + r, y: y1))
        p.addArc(center: CGPoint(x: x0 + r, y: y1 - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: x0, y: y0 + r))
        p.addArc(center: CGPoint(x: x0 + r, y: y0 + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        if side == .leading {
            p = p.applying(CGAffineTransform(translationX: rect.midX, y: 0).scaledBy(x: -1, y: 1).translatedBy(x: -rect.midX, y: 0))
        }
        return p
    }
}

extension View {
    /// A message bubble: its fill in the bubble's shape, and its press-and-hold menu. On the phone
    /// the view takes in the tail (it reaches past the bubble's edge), so the menu's lift keeps the
    /// tail and lifts the bubble's own outline, and the bubble comes back whole after it: the lift
    /// cut the tail off, and it grew back a few frames after the menu closed (feedback on 1.5 (21)).
    /// The layout is as before. `wholeOnMac`: the Mac's right-click takes the whole bubble, its
    /// padding too (#255). The Mac's right-click has no lift.
    @ViewBuilder func bubble<S: ShapeStyle, M: View>(_ fill: S, side: MessageBubbleShape.Side, tailed: Bool = true, wholeOnMac: Bool = false, @ViewBuilder menu: () -> M) -> some View {
        #if os(iOS)
        let edge: Edge.Set = side == .trailing ? .trailing : .leading
        let shape = MessageBubbleShape(side: side, tailed: tailed, tailRoom: MessageBubbleShape.tail)
        padding(edge, MessageBubbleShape.tail)
            .background(fill, in: shape)
            .contentShape(.contextMenuPreview, shape)
            .contextMenu { menu() }
            .padding(edge, -MessageBubbleShape.tail)
        #else
        if wholeOnMac {
            background(fill, in: MessageBubbleShape(side: side, tailed: tailed)).contentShape(.rect).contextMenu { menu() }
        } else {
            background(fill, in: MessageBubbleShape(side: side, tailed: tailed)).contextMenu { menu() }
        }
        #endif
    }
}
