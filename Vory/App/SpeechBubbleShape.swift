import SwiftUI

/// A speech bubble as one continuous outline: the rounded body and a small tail at the bottom
/// centre drawn in the same stroke, so there is no seam where they meet. The bottom 8 points of
/// the frame belong to the tail.
struct SpeechBubbleShape: Shape {
    /// The tail points up (the speaker is above the bubble) instead of down.
    var tailOnTop = false
    func path(in r: CGRect) -> Path {
        let tailH: CGFloat = 8, tailW: CGFloat = 16
        if tailOnTop {
            // Same outline, mirrored: the tail rises from the top edge.
            let body = CGRect(x: r.minX, y: r.minY + tailH, width: r.width, height: r.height - tailH)
            let radius = min(16, body.height / 2)
            let cx = r.midX
            var p = Path()
            p.move(to: CGPoint(x: body.minX + radius, y: body.minY))
            p.addLine(to: CGPoint(x: cx - tailW / 2, y: body.minY))
            p.addQuadCurve(to: CGPoint(x: cx, y: r.minY), control: CGPoint(x: cx - tailW * 0.22, y: body.minY - tailH * 0.55))
            p.addQuadCurve(to: CGPoint(x: cx + tailW / 2, y: body.minY), control: CGPoint(x: cx + tailW * 0.22, y: body.minY - tailH * 0.55))
            p.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
            p.addArc(center: CGPoint(x: body.maxX - radius, y: body.minY + radius), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
            p.addArc(center: CGPoint(x: body.maxX - radius, y: body.maxY - radius), radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
            p.addArc(center: CGPoint(x: body.minX + radius, y: body.maxY - radius), radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
            p.addArc(center: CGPoint(x: body.minX + radius, y: body.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.closeSubpath()
            return p
        }
        let body = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - tailH)
        let radius = min(16, body.height / 2)
        let cx = r.midX
        var p = Path()
        p.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        p.addArc(center: CGPoint(x: body.maxX - radius, y: body.minY + radius), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        p.addArc(center: CGPoint(x: body.maxX - radius, y: body.maxY - radius), radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        // Along the bottom edge to the tail, down its right side, up its left, and on.
        p.addLine(to: CGPoint(x: cx + tailW / 2, y: body.maxY))
        p.addQuadCurve(to: CGPoint(x: cx, y: r.maxY), control: CGPoint(x: cx + tailW * 0.22, y: body.maxY + tailH * 0.55))
        p.addQuadCurve(to: CGPoint(x: cx - tailW / 2, y: body.maxY), control: CGPoint(x: cx - tailW * 0.22, y: body.maxY + tailH * 0.55))
        p.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        p.addArc(center: CGPoint(x: body.minX + radius, y: body.maxY - radius), radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        p.addArc(center: CGPoint(x: body.minX + radius, y: body.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
