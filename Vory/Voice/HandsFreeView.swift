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
                Spacer(minLength: 12)
                bot
                Spacer(minLength: 12)
                words
                Spacer(minLength: 12)
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

    /// What was heard, or what is being said.
    private var words: some View {
        Group {
            if state.phase == .speaking || (state.phase == .thinking && !session.spoken.isEmpty) {
                Text(Self.tail(session.spoken))
                    .font(.body).foregroundStyle(.primary)
            } else if state.hearing, !session.liveText.isEmpty {
                Text(Self.tail(session.liveText))
                    .font(.body).foregroundStyle(.primary)
            } else if let heard = state.caption {
                Text("“\(heard)”")
                    .font(.body).foregroundStyle(.secondary)
            } else {
                Text("Say something. I'll answer when you pause.")
                    .font(.body).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(5)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .frame(minHeight: 90, alignment: .top)
    }

    static func tail(_ s: String, max: Int = 220) -> String {
        guard s.count > max else { return s }
        return "…" + String(s.suffix(max - 1))
    }

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
