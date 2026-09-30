import SwiftUI

/// The Vory cloud as an outline with its two eyes, tilted a little: the Bots tab's icon.
struct VoryOutlineIcon: View {
    var body: some View {
        Canvas { ctx, size in
            // The cloud is several overlapping pieces, so stroking it scribbles; instead fill it,
            // then punch out a slightly smaller cloud, which leaves a clean outline.
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            ctx.drawLayer { layer in
                layer.fill(BotFace.bodyPath("cloud", in: box, time: 0, active: false), with: .foreground)
                layer.blendMode = .destinationOut
                let inner = CGRect(x: box.midX - box.width * 0.42, y: box.midY - box.height * 0.42, width: box.width * 0.84, height: box.height * 0.84)
                layer.fill(BotFace.bodyPath("cloud", in: inner, time: 0, active: false), with: .color(.black))
            }
            let s = min(size.width, size.height)
            let cy = size.height * 0.60, dx = s * 0.13
            for x in [size.width / 2 - dx, size.width / 2 + dx] {
                ctx.fill(Path(roundedRect: CGRect(x: x - s * 0.05, y: cy - s * 0.11, width: s * 0.10, height: s * 0.22), cornerRadius: s * 0.05), with: .foreground)
            }
        }
        .rotationEffect(.degrees(-10))
        .accessibilityHidden(true)
    }
}
