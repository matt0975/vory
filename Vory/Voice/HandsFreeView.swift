import SwiftUI
import VoryCore

#if os(iOS)
/// The hands-free screen: the bot large, what it is doing under it, the last words heard or
/// said, the approval card when one waits, and Mute / Pause / End along the bottom. A swipe
/// of the chevron puts it away while the loop goes on.
struct HandsFreeView: View {
    @Bindable var chat: ChatSession
    @Environment(\.colorScheme) private var scheme
    private var session: HandsFreeSession { HandsFreeSession.shared }
    private var state: HandsFreeState { session.state }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                top
                bot.padding(.top, 12)
                // Everything said so far, scrolling, between the state line and the controls (#235).
                VoiceTranscriptView(lines: session.transcriptLines, prompt: prompt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 6)
                if let card = chat.firstCard {
                    PendingCardView(chat: chat, card: card)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                controls
            }
            .animation(.snappy, value: state.phase)
            .animation(.snappy, value: chat.cards.count)
        }
        .preferredColorScheme(.dark)
    }

    private var tint: Color { BotColors.color(for: chat.profileName) }

    private var background: some View {
        LinearGradient(colors: [tint.opacity(0.55), Color.black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var top: some View {
        HStack {
            Button { session.minimized = true } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide voice mode")
            Spacer()
            VStack(spacing: 2) {
                // Live is named when it is in use: the person's own provider, billed to them.
                Text(session.isLive ? "Live voice · \(session.liveLabel ?? "")" : "Voice mode").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(chat.title.count > 30 ? String(chat.title.prefix(29)) + "…" : chat.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16).padding(.top, 4)
    }

    private var mood: BotFaceView.Mood {
        switch state.phase {
        case .listening, .transcribing: return BotFaceView.Mood(profile: chat.profileName, state: .idle)
        case .thinking: return BotFaceView.Mood(thinking: true, profile: chat.profileName, state: .thinking)
        case .speaking: return BotFaceView.Mood(profile: chat.profileName, state: .streaming)
        case .needsApproval: return BotFaceView.Mood(profile: chat.profileName, state: .awaitingApproval)
        case .paused, .ended: return BotFaceView.Mood(profile: chat.profileName, state: .idle, still: true)
        }
    }

    private var bot: some View {
        VStack(spacing: 18) {
            ZStack {
                // A ring breathes while the person is heard, and while the bot speaks.
                Circle()
                    .stroke(tint.opacity(0.5), lineWidth: 3)
                    .frame(width: 196, height: 196)
                    .scaleEffect(state.hearing || state.phase == .speaking ? 1.12 : 0.98)
                    .opacity(state.hearing || state.phase == .speaking ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: state.hearing || state.phase == .speaking)
                BotAvatar(profile: chat.profileName, size: 164, active: state.phase == .thinking || state.phase == .speaking, mood: mood)
            }
            VStack(spacing: 6) {
                Text(state.title).font(.title2.weight(.semibold)).contentTransition(.numericText())
                // Muted while the bot speaks or thinks: said plainly, not only by the button (#234).
                if state.isMuted, state.phase != .listening {
                    Label("Mic muted", systemImage: "mic.slash.fill").font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.white.opacity(0.18), in: .capsule)
                        .transition(.opacity)
                }
                if state.phase == .thinking, let goal = ChatGoals.shared.goal(for: chat.storedID) ?? chat.statusLine {
                    Text(goal).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                } else if state.phase == .needsApproval {
                    Text("Approve on screen. The loop waits.").font(.subheadline).foregroundStyle(.secondary)
                } else if state.phase == .paused {
                    Text(state.note ?? "Tap Resume to keep going.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else if let note = state.note {
                    Text(note).font(.subheadline).foregroundStyle(.orange).multilineTextAlignment(.center)
                } else if let err = session.lastError {
                    Text(err).font(.subheadline).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            if state.phase == .listening, !state.isMuted {
                HandsFreeWaveform(levels: session.levels, tint: tint)
                    .frame(height: 26).padding(.horizontal, 60)
                    .transition(.opacity)
            }
        }
    }

    /// What the empty transcript says.
    private var prompt: String { session.isLive ? "Say something." : "Say something. I'll answer when you pause." }

    private var controls: some View {
        HStack(spacing: 28) {
            control(state.isMuted ? "mic.slash.fill" : "mic.fill", label: state.isMuted ? "Unmute" : "Mute", on: state.isMuted) { session.toggleMute() }
                .disabled(state.phase == .paused)
            Button { session.end() } label: {
                Image(systemName: "xmark").font(.title2.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 72, height: 72).background(.red, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End voice mode")
            control(state.phase == .paused ? "play.fill" : "pause.fill", label: state.phase == .paused ? "Resume" : "Pause", on: state.phase == .paused) { session.togglePause() }
        }
        .padding(.top, 18).padding(.bottom, 24)
    }

    private func control(_ symbol: String, label: String, on: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: symbol).font(.title3.weight(.semibold))
                    .foregroundStyle(on ? Color.black : Color.white)
                    .frame(width: 58, height: 58)
                    .background(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(.white.opacity(0.18)), in: .circle)
            }
            .buttonStyle(.plain)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

#endif

/// The conversation so far in voice mode, scrolling: the person's words set apart from the
/// bot's, the whole of each reply (never a tail of it), the newest at the bottom and followed
/// as it grows. Scrolling up stops the following, as a chat's thread does (#218), until the
/// person is back at the bottom or taps the arrow. Shared with the Mac's voice window.
struct VoiceTranscriptView: View {
    var lines: [VoiceLine]
    /// Shown while nothing has been said.
    var prompt: String
    /// Following the newest words; off while the person reads back.
    @State private var following = true
    @State private var userScrolling = false
    private let bottomID = "voice.transcript.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if lines.isEmpty {
                        Text(prompt).font(.body).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    }
                    ForEach(lines) { line in row(line).id(line.id) }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { g in
                max(0, g.contentSize.height + g.contentInsets.bottom - g.visibleRect.maxY)
            } action: { _, distance in
                // A real pull up stops the following; back at the bottom (by hand or by the
                // arrow) it resumes. Not while the finger is still down at the bottom.
                if userScrolling, distance > 24 { following = false }
                else if distance < 4, !userScrolling { following = true }
            }
            .onScrollPhaseChange { _, phase in userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating }
            // Each new word: to the bottom, unanimated (the words stream several times a second).
            .onChange(of: tail) { _, _ in if following { proxy.scrollTo(bottomID, anchor: .bottom) } }
            .mask {
                // The top edge fades, so a line scrolling out does not cut under the state line.
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 28)
                    Color.black
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !following, !lines.isEmpty {
                    Button {
                        following = true
                        withAnimation(.snappy) { proxy.scrollTo(bottomID, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down").font(.subheadline.weight(.bold))
                            .frame(width: 36, height: 36).glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20).padding(.bottom, 8)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                    .accessibilityLabel("Jump to the latest words")
                }
            }
            .animation(.snappy(duration: 0.2), value: following)
        }
    }

    /// What changes as the conversation goes on: the last line's words and the count.
    private var tail: String { "\(lines.count):" + (lines.last?.text ?? "") }

    @ViewBuilder private func row(_ line: VoiceLine) -> some View {
        if line.isPerson {
            Text(line.text).font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 36)
                .accessibilityLabel("You said: \(line.text)")
        } else {
            Text(line.text).font(.body).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 16)
                .accessibilityLabel("Bot said: \(line.text)")
        }
    }
}

/// The listener's loudness as bars, newest at the right.
struct HandsFreeWaveform: View {
    var levels: [Float]
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let count = UtteranceListener.waveformSamples
            let step = geo.size.width / CGFloat(count)
            HStack(alignment: .center, spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    let idx = i - (count - levels.count)
                    let level = idx >= 0 && idx < levels.count ? CGFloat(levels[idx]) : 0
                    Capsule().fill(tint)
                        .frame(width: max(1.5, step * 0.45), height: max(3, 3 + level * (geo.size.height - 4)))
                        .frame(width: step)
                }
            }
            .frame(height: geo.size.height)
        }
        .animation(.linear(duration: 0.05), value: levels.count)
        .accessibilityHidden(true)
    }
}

#if os(iOS)
/// The pill in a chat while voice mode runs out of sight: tap to bring the screen back.
struct HandsFreePill: View {
    @Bindable var chat: ChatSession
    private var session: HandsFreeSession { HandsFreeSession.shared }

    var body: some View {
        Button { session.minimized = false } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.mic").font(.subheadline.weight(.semibold)).symbolEffect(.variableColor.iterative, isActive: session.state.phase == .listening)
                Text("Voice mode · \(session.state.title)").font(.subheadline.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.up").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice mode is on, \(session.state.title). Show it")
    }
}
#endif
