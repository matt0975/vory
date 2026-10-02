import SwiftUI
import VoryCore

/// The sparkle beside a title the on-device model wrote: it pulses while the model is writing
/// (or waiting its turn) and is steady once the summary is there. It reads the summarizer
/// itself, so a row is not redrawn each time another chat's summary starts or ends.
struct SummarySparkle: View {
    /// The chat's stored id, or `ChatSummarizer.roomKey` for a group chat.
    var key: String
    /// A current summary is showing on the row.
    var done: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let working = ChatSummarizer.shared.isWorking(key)
        if working || done {
            Image(systemName: "sparkles").font(.caption2)
                .foregroundStyle(working ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                // Reduce Motion: a steady, dimmed sparkle in place of the pulse.
                .symbolEffect(.pulse, options: .repeating, isActive: working && !reduceMotion)
                .opacity(working && reduceMotion ? 0.55 : 1)
                .accessibilityLabel(working ? "Summarizing" : "Summarized on device")
        }
    }
}

/// Floats over the foot of the chat list while a run of summaries is being written, with how
/// far it has got, and says "up to date" for a moment when the run ends. It is the list's
/// bottom inset, not a row, so the rows stay where they are when it comes and goes. One chat
/// by itself gets no strip: its row's sparkle says enough.
struct SummaryProgressStrip: View {
    @State private var showDone = false

    var body: some View {
        let summarizer = ChatSummarizer.shared
        let p = summarizer.progress
        let working = summarizer.enabled && p.isWorking && p.total > 1
        ZStack {
            if working {
                pill {
                    Image(systemName: "sparkles").foregroundStyle(.tint)
                    Text("Summarizing \(p.current) of \(p.total)").monospacedDigit()
                    ProgressView(value: p.fraction).progressViewStyle(.linear).frame(width: 44)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Summarizing \(p.current) of \(p.total)")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if showDone {
                pill {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Summaries up to date")
                }
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
        }
        .animation(.snappy, value: working)
        .animation(.snappy, value: showDone)
        .onChange(of: summarizer.finishedAt) { _, finished in
            guard finished != nil else { return }
            showDone = true
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                // A new run may have begun and ended meanwhile; only the latest one clears it.
                if summarizer.finishedAt == finished { showDone = false }
            }
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("summaries.progress")
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 4).padding(.bottom, 10)
    }
}

/// Settings › Vory Summaries: what the model is doing now.
struct SummaryStatusRow: View {
    var body: some View {
        let summarizer = ChatSummarizer.shared
        let p = summarizer.progress
        Group {
            if let why = ChatSummarizer.unavailableReason {
                // Nothing can be written here: say why rather than "up to date".
                Label(why, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            } else if !summarizer.enabled {
                Label("Off. Switch on what the model should write below.", systemImage: "moon.zzz").foregroundStyle(.secondary)
            } else if p.isWorking {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.total == 1 ? "Summarizing a chat" : "Summarizing \(p.current) of \(p.total) chats").monospacedDigit()
                        if p.total > 1 { ProgressView(value: p.fraction).progressViewStyle(.linear) }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(p.total == 1 ? "Summarizing a chat" : "Summarizing \(p.current) of \(p.total) chats")
            } else {
                LabeledContent {
                    Text(summarizer.summaries.isEmpty ? "none yet" : "\(summarizer.summaries.count) on \(DeviceWords.this)")
                } label: {
                    Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.primary)
                }
            }
        }
        .accessibilityIdentifier("summaries.status")
    }
}
