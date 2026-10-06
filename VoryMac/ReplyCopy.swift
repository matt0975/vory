import SwiftUI
import VoryCore

extension TranscriptMedia {
    /// What Copy puts on the pasteboard for a reply (#255): the markdown its bubble shows, with
    /// the pictures' MEDIA: lines and gateway paths left out as the bubble leaves them out, trimmed.
    static func copyText(_ text: String) -> String {
        images(in: text).isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : MediaScan.textWithoutMedia(text)
    }
}

/// The Mac's Copy on a reply (#255): a button just past the bubble's trailing edge, by its last
/// line, while the pointer is on the bubble or on the strip beside it. A click copies the reply's
/// markdown and the button shows a checkmark for a moment, even if the pointer has moved on.
/// The hover flags live here, so a crossing re-evaluates this modifier only, never the bubble;
/// no timers run until a click. Hidden from VoiceOver: Chat › Copy Last Reply (⇧⌘C) is the
/// keyboard and VoiceOver way, and the bubble's own accessibility is left alone.
struct ReplyCopyHover: ViewModifier {
    var text: String
    var enabled: Bool
    @State private var overBubble = false
    @State private var overStrip = false
    @State private var copiedAt: Date?

    func body(content: Content) -> some View {
        let copied = copiedAt != nil
        let shown = enabled && (overBubble || overStrip || copied)
        content
            .onHover { overBubble = $0 }
            .overlay(alignment: .trailing) {
                // A clear strip as tall as the bubble beside its trailing edge: the pointer can go
                // from any line to the button without the button going away on the way.
                Color.clear
                    .frame(width: 28)
                    .contentShape(.rect)
                    .onHover { overStrip = $0 }
                    .overlay(alignment: .bottom) {
                        if shown {
                            Button(action: copy) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(copied ? Color.green : Color.secondary)
                                    .frame(width: 24, height: 20)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help(copied ? "Copied" : "Copy reply")
                            .transition(.opacity)
                        }
                    }
                    // The strip's leading edge on the bubble's trailing edge: never over a word.
                    .alignmentGuide(.trailing) { d in d[.leading] }
                    .accessibilityHidden(true)
            }
            .animation(.easeOut(duration: 0.12), value: shown)
    }

    private func copy() {
        UIPasteboard.general.string = TranscriptMedia.copyText(text)
        let at = Date()
        withAnimation(.snappy) { copiedAt = at }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedAt == at { withAnimation(.snappy) { copiedAt = nil } }
        }
    }
}
