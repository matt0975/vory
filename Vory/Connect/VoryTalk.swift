import SwiftUI
import VoryCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Vory's speech bubble, typed out a few characters at a time whenever `text` changes (by
/// `key`). Wraps, and keeps the full text's height so the layout does not grow line by line.
struct VoryTypedBubble: View {
    var text: String
    var key: AnyHashable
    var reduceMotion = false
    var tint: Color = .primary
    var fill: Color = Color(.secondarySystemFill)
    @State private var shown = ""

    var body: some View {
        ZStack {
            Text(text).hidden()
            Text(shown)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(tint)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .padding(.top, 8)
        .background(fill, in: SpeechBubbleShape(tailOnTop: true))
        .frame(maxWidth: 340)
        .task(id: key) {
            if reduceMotion { shown = text; return }
            shown = ""
            for ch in text {
                guard !Task.isCancelled else { return }
                shown.append(ch)
                try? await Task.sleep(for: .milliseconds(ch == " " ? 12 : 22))
            }
        }
    }
}

extension Color {
    /// Green that reads on both backgrounds: the system green is too pale on white.
    #if canImport(UIKit)
    static let readableGreen = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0.10, green: 0.50, blue: 0.22, alpha: 1) })
    #else
    static let readableGreen = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemGreen : NSColor(red: 0.10, green: 0.50, blue: 0.22, alpha: 1)
    })
    #endif
}

/// Vory at the top of a guided screen: the glass cloud, a full turn whenever `turnKey` changes
/// (a new page or a finished step), a squint while `thinking` (never the thinking hold: the
/// mascot keeps its shape), and the typed bubble under it.
struct VoryGuide: View {
    var says: String
    var key: AnyHashable
    var turnKey: AnyHashable
    var thinking = false
    var done = false
    var reduceMotion = false
    var size: CGFloat = 96

    var body: some View {
        VStack(spacing: 6) {
            BotFaceView(spec: BotLookSpec.vory, size: size, active: true,
                        mood: BotFaceView.Mood(profile: "vory-guide", state: .guide, squint: thinking))
            VoryTypedBubble(text: says, key: key, reduceMotion: reduceMotion,
                            tint: done ? Color.readableGreen : .primary,
                            fill: done ? Color.green.mix(with: Color(.secondarySystemFill), by: 0.75) : Color(.secondarySystemFill))
                .padding(.horizontal, 24)
        }
        .onChange(of: turnKey) { _, _ in BotAmbient.shared.turnFinished(profile: "vory-guide") }
    }
}
