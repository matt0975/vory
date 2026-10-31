import SwiftUI
import VoryCore

#if os(iOS)
/// The hands-free screen: the bot large, what it is doing under it, the last words heard or
/// said, the approval card when one waits, and Mute / Pause / End along the bottom. A swipe
/// of the chevron puts it away while the loop goes on.
struct HandsFreeView: View {
    @Bindable var chat: ChatSession
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    private var session: HandsFreeSession { HandsFreeSession.shared }
    private var state: HandsFreeState {
        #if DEBUG
        if let worst = Self.worst { return worst.state }
        #endif
        return session.state
    }
    /// What the bot is about, under "Thinking…".
    private var goal: String? {
        #if DEBUG
        if let worst = Self.worst { return worst.goal }
        #endif
        return ChatGoals.shared.goal(for: chat.storedID) ?? chat.statusLine
    }
    private var lastError: String? {
        #if DEBUG
        if let worst = Self.worst { return worst.error }
        #endif
        return session.lastError
    }
    /// A fold across the window (the Duo half open like a laptop), in window space, and the column's own frame (inside the
    /// safe area, where the content goes): where the split falls (`VoiceSplit`, Duo stage 4).
    @State private var foldAcross: CGRect?
    @State private var column: CGRect = .zero

    /// The two halves' heights in the column (the top from the column's top to the fold, the bottom from the fold to the
    /// column's foot), or nil for one column.
    private var split: (top: CGFloat, gap: CGFloat, bottom: CGFloat)? {
        guard column.height > 0 else { return nil }
        #if DEBUG
        // `-vory-voice-worst`: the split at every size short of the accessibility sizes, to measure its worst content.
        if Self.worst != nil, let fold = foldAcross, fold.width > fold.height, !typeSize.isAccessibilitySize {
            return (fold.minY - column.minY, fold.height, column.maxY - fold.maxY)
        }
        #endif
        return VoiceSplit.halves(column: column, fold: foldAcross, size: typeSize)
    }

    var body: some View {
        let split = split
        ZStack {
            background
            // One tree, whatever the pose: half open like a laptop only the frames change (the bot above the fold, the
            // conversation and the controls below it), so a posture change keeps every view and its state.
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    top
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probeRow = $0 }
                        #endif
                    bot
                        #if DEBUG
                        // Measuring the worst (`-vory-voice-worst`): the block at its own height, so a line lost to a
                        // short half shows as an overflow, not as a quietly shorter block.
                        .fixedSize(horizontal: false, vertical: Self.worst != nil)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probeBot = $0 }
                        #endif
                        .padding(.top, 12).frame(maxHeight: split == nil ? nil : .infinity)
                }
                .frame(height: split?.top, alignment: .top)
                Color.clear.frame(height: split?.gap ?? 0).accessibilityHidden(true)
                VStack(spacing: 0) {
                    // Everything said so far, scrolling, between the state line and the controls (#235).
                    VoiceTranscriptView(lines: session.transcriptLines, prompt: prompt)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 6)
                    if let card = chat.firstCard {
                        if let split {
                            // Below the fold the card takes what the controls leave (the conversation gives up its
                            // lines while it waits), never across the fold. An approval's choices stand under its words,
                            // which scroll from their start when it's taller than that: what's allowed is read first.
                            PendingCardView(chat: chat, card: card)
                                .environment(\.approvalChoicesPinned, true)
                                .padding(.horizontal, 16)
                                .frame(maxHeight: max(0, split.bottom - VoiceSplit.controls), alignment: .top)
                                .layoutPriority(1)
                                #if DEBUG
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probeCard = $0 }
                                #endif
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            PendingCardView(chat: chat, card: card)
                                .padding(.horizontal, 16)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    controls
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probeControls = $0 }
                        #endif
                }
                .frame(height: split?.bottom)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { column = $0 }
            .background { FoldAcrossProbe(fold: $foldAcross).ignoresSafeArea() }
            #if DEBUG
            .overlay(alignment: .topLeading) {
                if Self.framesProbe {
                    Text(framesReadout).font(.system(size: 1)).opacity(0.01).frame(width: 1, height: 1)
                        .accessibilityIdentifier("voice.frames").accessibilityLabel(framesReadout)
                }
            }
            #endif
            .animation(.snappy, value: state.phase)
            .animation(.snappy, value: chat.cards.count)
        }
        .preferredColorScheme(.dark)
    }

    #if DEBUG
    /// DEBUG `-vory-voice-frames`: the top row's, the bot's, the controls' and a waiting card's frames, the column, the fold
    /// and the split (window space), read by the hinge legs as `voice.frames`' label (the bot's face is hidden from
    /// accessibility). Checked absent from Release.
    private static let framesProbe = ProcessInfo.processInfo.arguments.contains("-vory-voice-frames")
    @State private var probeRow: CGRect = .zero
    @State private var probeBot: CGRect = .zero
    @State private var probeControls: CGRect = .zero
    @State private var probeCard: CGRect = .zero
    private var framesReadout: String {
        func r(_ f: CGRect) -> String { String(format: "%.1f %.1f %.1f %.1f", f.minX, f.minY, f.width, f.height) }
        return "row \(r(probeRow));bot \(r(probeBot));controls \(r(probeControls));card \(chat.firstCard == nil || split == nil ? "none" : r(probeCard))"
            + ";column \(r(column));fold \(foldAcross.map(r) ?? "none");split \(split == nil ? "no" : "yes")"
    }

    /// DEBUG `-vory-voice-worst thinking|paused|error`: the bot's block in a state's tallest form, for measuring the top
    /// half's worst (`VoiceSplit.minTop`): thinking and muted with a long goal; paused and muted with a long note; listening with a
    /// long error under it and the waveform. The split stands at every size short of the accessibility sizes meanwhile.
    private struct Worst { var state = HandsFreeState(); var goal: String?; var error: String? }
    private static let worst: Worst? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-vory-voice-worst"), args.indices.contains(i + 1) else { return nil }
        let long = "Checking the nightly export job's logs for the failed upload, then retrying it against the backup bucket in the other region before the window closes"
        var w = Worst()
        switch args[i + 1] {
        case "thinking": w.state.phase = .thinking; w.state.isMuted = true; w.goal = long
        case "paused": w.state.phase = .paused; w.state.isMuted = true; w.state.note = long
        case "error": w.state.phase = .listening; w.error = long
        default: return nil
        }
        return w
    }()
    #endif

    private var tint: Color { BotColors.color(for: chat.profileName) }

    private var background: some View {
        LinearGradient(colors: [tint.opacity(0.55), Color.black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var top: some View {
        HStack {
            Button { session.minimized = true } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44).voryGlassEffect(.regular.interactive(), in: .circle)
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
        // Listening and transcribing are the arcs; speaking is the plain bot (the
        // words are heard, not shown), 1.5 #304.
        case .listening, .transcribing: return BotFaceView.Mood(profile: chat.profileName, state: BotFace.motionEngine ? .listening : .idle)
        case .thinking: return BotFaceView.Mood(thinking: true, profile: chat.profileName, state: .thinking)
        case .speaking: return BotFaceView.Mood(profile: chat.profileName, state: BotFace.motionEngine ? .working : .streaming)
        case .needsApproval: return BotFaceView.Mood(profile: chat.profileName, state: .awaitingApproval)
        case .paused, .ended: return BotFaceView.Mood(profile: chat.profileName, state: .idle, still: true)
        }
    }

    private var bot: some View {
        VStack(spacing: 18) {
            ZStack {
                // A ring breathes while the person is heard, and while the bot speaks; with the
                // motion engine the bot's own listening arcs take its place (1.5 #304).
                if !BotFace.motionEngine {
                    Circle()
                        .stroke(tint.opacity(0.5), lineWidth: 3)
                        .frame(width: split == nil ? 196 : VoiceSplit.ring, height: split == nil ? 196 : VoiceSplit.ring)
                        .scaleEffect(state.hearing || state.phase == .speaking ? 1.12 : 0.98)
                        .opacity(state.hearing || state.phase == .speaking ? 1 : 0.25)
                        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: state.hearing || state.phase == .speaking)
                }
                BotAvatar(profile: chat.profileName, size: split == nil ? 164 : VoiceSplit.face, active: state.phase == .thinking || state.phase == .speaking, mood: mood)
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
                // Above the fold every line stops at two (`VoiceSplit.minTop`); VoiceOver still reads it whole.
                if state.phase == .thinking, let goal {
                    Text(goal).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                } else if state.phase == .needsApproval {
                    Text("Allow or deny on screen. The loop waits.").font(.subheadline).foregroundStyle(.secondary).lineLimit(split == nil ? nil : 2)
                } else if state.phase == .paused {
                    Text(state.note ?? "Tap Resume to keep going.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(split == nil ? nil : 2)
                } else if let note = state.note {
                    Text(note).font(.subheadline).foregroundStyle(.orange).multilineTextAlignment(.center).lineLimit(split == nil ? nil : 2)
                } else if let lastError {
                    Text(lastError).font(.subheadline).foregroundStyle(.orange).multilineTextAlignment(.center).lineLimit(split == nil ? nil : 2)
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

    /// The three buttons share a line through their circles' centres; Mute's and Pause's words
    /// hang below theirs. (Centred as whole columns, words and all, the two smaller circles sat
    /// higher than End's.)
    private var controls: some View {
        HStack(alignment: .controlCircle, spacing: 19) {
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
            .alignmentGuide(.controlCircle) { $0[VerticalAlignment.center] }
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
        }
        // Both columns as wide, whatever their words ("Unmute", "Resume", large text): End stays
        // in the middle.
        .frame(width: 76)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// Where a fold runs across the window, in window space, for voice mode's split (Duo stage 4); nil with none, and before
/// iOS 27.1. Read in the cover itself rather than taken from the root, which the full-screen cover may not pass on.
private struct FoldAcrossProbe: View {
    @Binding var fold: CGRect?

    var body: some View {
        if #available(iOS 27.1, *) { Reader(fold: $fold) } else { Color.clear }
    }

    @available(iOS 27.1, *)
    private struct Reader: View {
        @Binding var fold: CGRect?
        var body: some View {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                let across = proxy.reservedRegions(kind: .division).filter(\.isActive)
                    .map { $0.frame.offsetBy(dx: frame.minX, dy: frame.minY) }.first { $0.width > $0.height }
                Color.clear
                    .onChange(of: [across ?? .null, frame], initial: true) { _, _ in fold = across }
            }
            .accessibilityHidden(true)
        }
    }
}

private extension VerticalAlignment {
    /// The middle of a voice-mode control's circle (End's, which has no words under it, is its
    /// own middle).
    enum ControlCircle: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let controlCircle = VerticalAlignment(ControlCircle.self)
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
                            .frame(width: 36, height: 36).voryGlassEffect(.regular.interactive(), in: .circle)
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
            Text(Mentions.attributed(line.text, names: Mentions.names)).font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 36)
                .accessibilityLabel("You said: \(line.text)")
        } else {
            Text(Mentions.attributed(line.text, names: Mentions.names)).font(.body).foregroundStyle(.primary)
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
            .voryGlassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice mode is on, \(session.state.title). Show it")
    }
}
#endif
