import SwiftUI

/// The Messages typing indicator: a grey bubble with three dots that rise and fall in turn, and
/// the two small circles of a thought bubble trailing toward the speaker. `tool` turns it dark
/// with a badge: the bot is running something rather than composing.
struct TypingBubble: View {
    var tool: String? = nil
    private var dark: Bool { tool != nil }
    private var fill: Color { dark ? Color(white: 0.12) : Color(.systemGray5) }

    var body: some View {
        HStack(spacing: 10) {
            if tool != nil { ToolBadge() }
            TypingDots(color: dark ? Color.white.opacity(0.75) : Color(.systemGray))
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(fill, in: .rect(cornerRadius: 22))
        // The thought-bubble tail: a circle on the corner and a smaller one past it.
        .overlay(alignment: .bottomLeading) { Circle().fill(fill).frame(width: 12, height: 12).offset(x: -2, y: 2) }
        .overlay(alignment: .bottomLeading) { Circle().fill(fill).frame(width: 5, height: 5).offset(x: -10, y: 9) }
        .padding(.leading, 6).padding(.bottom, 6)
        .accessibilityLabel(tool.map { "Running \($0)" } ?? "Typing")
    }
}

/// Three dots, each rising and brightening in turn, then a beat of rest — Messages' rhythm.
struct TypingDots: View {
    var color: Color
    #if os(macOS)
    /// On the Mac the dots hold still where no one can see them, or under Reduce Motion (#248).
    @Environment(\.botsLive) private var botsLive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif
    var body: some View {
        #if os(macOS)
        if botsLive && !reduceMotion { moving } else { dots(at: 0.3) }
        #else
        moving
        #endif
    }

    private var moving: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            dots(at: timeline.date.timeIntervalSinceReferenceDate)
        }
    }

    private func dots(at t: Double) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                let p = (t * 1.05 - Double(i) * 0.16).truncatingRemainder(dividingBy: 1)
                let k = p < 0.55 ? sin(p / 0.55 * .pi) : 0
                Circle().fill(color)
                    .frame(width: 8, height: 8)
                    .opacity(0.45 + 0.55 * k)
                    .offset(y: -3 * k)
            }
        }
    }
}

/// The tool glyph on a dark typing bubble: a mint tile with a target in it.
struct ToolBadge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(Color(red: 0.70, green: 0.95, blue: 0.66))
            .frame(width: 34, height: 26)
            .overlay {
                Image(systemName: "circle.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 0.16, green: 0.45, blue: 0.95), Color(red: 0.30, green: 0.80, blue: 0.72))
            }
    }
}
