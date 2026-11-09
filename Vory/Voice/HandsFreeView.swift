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
    /// One column with a card waiting (#631): the room the screen gives (its height inside the safe area) and what the top
    /// row and the controls take of it (the controls at their natural height, round 3), so the card is held to what is left
    /// and the bot's block goes lean, then hides its face, when it would leave the card too little.
    @State private var roomFrame: CGRect = .zero
    private var room: CGFloat { roomFrame.height }
    @State private var rowH: CGFloat = 0
    @State private var controlsH: CGFloat = 0
    /// The widest control caption at this text size, measured off screen (#631, round 3e).
    @State private var captionW: CGFloat = 0
    /// The same under each of `VoiceSplit.captionCaps` (#631, round 3f), for the one cap both side captions take.
    @State private var captionCappedW: [CGFloat] = Array(repeating: 0, count: VoiceSplit.captionCaps.count)
    /// The waiting approval's parts as its card measures them in one column (#631), and the bot's state lines as they
    /// would stand (measured while they are hidden too), so the bot's full block is known at every level.
    @State private var cardHeights = VoiceSplit.CardHeights()
    @State private var linesH: CGFloat = 0
    /// The mic muted, said under the bot's title (#234); while the bot is lean, a badge on its face, and with its face
    /// hidden, the same badge on the top row (#631): the one state line the card doesn't say, kept with no height of its own.
    private var mutedShown: Bool { state.isMuted && state.phase != .listening }
    /// The waveform under the bot while it listens, unmuted: its 26 and the space over it.
    private var waveformShown: Bool { state.phase == .listening && !state.isMuted }
    /// The bot's block at a level, at its natural height (#631, round 3: worked out, not measured, so a level doesn't feed
    /// back into its own decision).
    private func botBlock(_ level: VoiceSplit.BotLevel) -> CGFloat {
        guard level != .hidden else { return 0 }
        return VoiceSplit.botBlock(level, ring: !BotFace.motionEngine, lines: linesH) + (waveformShown ? VoiceSplit.botLinesGap + 26 : 0)
    }
    private var botLevel: VoiceSplit.BotLevel {
        guard split == nil, chat.firstCard != nil else { return .full }
        return VoiceSplit.oneColumnBotLevel(room: room, row: rowH, full: botBlock(.full),
                                            lean: botBlock(.lean), controls: controlsH, whole: VoiceSplit.cardWhole(cardHeights),
                                            need: VoiceSplit.cardNeed(cardHeights), size: typeSize)
    }

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
        let level = botLevel
        ZStack {
            background
            // The room inside the safe area, for the one column's card (#631), read from a view of its own that holds the
            // column in its overlay (round 3b). A ZStack lays each of its views out at the stack's own final size, so a room
            // read beside the column grew with it once the column ran past the screen (the closed Duo's 644 pt read as
            // 671.7), and the card's height, worked out from that room, kept the column there. An overlay never changes the
            // size of the view it is on, so the room is always the screen's, and the column is laid out in it as it was.
            Color.clear
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { roomFrame = $0 }
                .overlay {
                    // One tree, whatever the pose: half open like a laptop only the frames change (the bot above the fold, the
                    // conversation and the controls below it), so a posture change keeps every view and its state.
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            top
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowH = $0 }
                                #if DEBUG
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probeRow = $0 }
                                #endif
                            if level != .hidden {
                                bot
                                    // One column with a card waiting (#631, round 3): the block at its own height, never squeezed
                                    // by the stack, so it is the height the card's room is worked out from.
                                    .fixedSize(horizontal: false, vertical: split == nil && chat.firstCard != nil)
                                    #if DEBUG
                                    // Measuring the worst (`-vory-voice-worst`): the block at its own height, so a line lost to a
                                    // short half shows as an overflow, not as a quietly shorter block.
                                    .fixedSize(horizontal: false, vertical: Self.worst != nil)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probeBot = $0 }
                                    .onDisappear { probeBot = .zero }
                                    #endif
                                    .padding(.top, 12)
                                    .frame(maxHeight: split == nil ? nil : .infinity)
                                    .transition(.opacity)
                            }
                        }
                        .frame(height: split?.top, alignment: .top)
                        Color.clear.frame(height: split?.gap ?? 0).accessibilityHidden(true)
                        VStack(spacing: 0) {
                            // Everything said so far, scrolling, between the state line and the controls (#235).
                            VoiceTranscriptView(lines: session.transcriptLines, prompt: prompt, quiet: VoiceLook.secondary, wholeLines: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.top, VoiceSplit.transcriptTop)
                            if let card = chat.firstCard {
                                if let split {
                                    // Below the fold the card takes what the controls leave (the conversation gives up its
                                    // lines while it waits), never across the fold. An approval's choices stand under its words,
                                    // which scroll from their start when it's taller than that: what's allowed is read first.
                                    PendingCardView(chat: chat, card: card)
                                        .environment(\.approvalChoicesPinned, true)
                                        .environment(\.cardInVoiceMode, true)
                                        .padding(.horizontal, 16)
                                        .frame(maxHeight: max(0, split.bottom - VoiceSplit.controls), alignment: .top)
                                        .layoutPriority(1)
                                        #if DEBUG
                                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probeCard = $0 }
                                        #endif
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                } else {
                                    // One column (#631): what the approval asks and its choices always stand whole, and the card
                                    // takes its whole height before the conversation gets any; when even that leaves too little,
                                    // the bot goes lean, then hides its face (`botLevel`, round 3l: at any size). Its height is set
                                    // once its parts are measured, not left to the stack's priorities, and never more than what
                                    // is left, so the column never runs past the screen: above that, its words scroll, and as the
                                    // last resort the choices with them (round 3). Until then it is held to what is left, as before.
                                    let botTaken = botBlock(level)
                                    let fit = VoiceSplit.oneColumnCard(room: room, row: rowH, bot: botTaken, controls: controlsH, heights: cardHeights)
                                    PendingCardView(chat: chat, card: card)
                                        .environment(\.approvalChoicesPinned, true)
                                        .environment(\.cardInVoiceMode, true)
                                        .environment(\.approvalInColumn, true)
                                        .environment(\.approvalWordsScroll, fit?.wordsScroll ?? false)
                                        .environment(\.approvalAllScroll, fit?.allScroll ?? false)
                                        .padding(.horizontal, 16)
                                        .frame(height: fit?.height, alignment: .top)
                                        .frame(maxHeight: fit == nil ? (VoiceSplit.oneColumnCardMax(room: room, row: rowH, bot: botTaken, controls: controlsH, size: typeSize) ?? .infinity) : nil,
                                               alignment: .top)
                                        .layoutPriority(1)
                                        #if DEBUG
                                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probeCard = $0 }
                                        #endif
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                }
                            }
                            controls
                                // Their natural height always (#631, round 3): the stack squeezed them to their minimum, the
                                // captions down to their 0.6 floor, and the card took the points back on the next pass.
                                .fixedSize(horizontal: false, vertical: true)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsH = $0 }
                                #if DEBUG
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probeControls = $0 }
                                #endif
                        }
                        .frame(height: split?.bottom)
                        // The one column's card tells its parts' heights; none with no card (or the split's), so they go with it.
                        .onPreferenceChange(ApprovalCardHeightsKey.self) { cardHeights = $0 }
                        #if DEBUG
                        // What the card's choices drew, for the readout (#631, round 3g; `-vory-voice-frames` only).
                        .onPreferenceChange(VoiceChoiceProbe.Key.self) { choiceProbe = $0 }
                        #endif
                    }
                    // The bot's state lines' height as they would stand, at every level (#631): what its full block would take.
                    .background(alignment: .top) {
                        stateLines.fixedSize(horizontal: false, vertical: true).hidden().accessibilityHidden(true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { linesH = $0 }
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
    /// What the card's choices drew (#631, round 3g).
    @State private var choiceProbe = VoiceChoiceProbe.Report()
    private var framesReadout: String {
        func r(_ f: CGRect) -> String { String(format: "%.1f %.1f %.1f %.1f", f.minX, f.minY, f.width, f.height) }
        return "row \(r(probeRow));bot \(r(probeBot));controls \(r(probeControls));card \(chat.firstCard == nil || split == nil ? "none" : r(probeCard))"
            + ";column \(r(column));fold \(foldAcross.map(r) ?? "none");split \(split == nil ? "no" : "yes")"
            // The room inside the safe area (#631): the one column must stand inside it, the closed Duo's included.
            + ";room \(r(roomFrame))"
            // The bot's level in one column (#631, round 3): full, lean or hidden, and its block as worked out for that
            // level (the 12 over it included), for a check against the block as drawn.
            + ";level \(botLevel);botblock \(String(format: "%.1f", botBlock(botLevel)))"
            // Whether the one column's card scrolls its choices with its words (#631, round 3b: the all-scroll at closed
            // AX4 and AX5), for the probe's line; none in a split or with no card.
            + ";allscroll \(split == nil && chat.firstCard != nil ? (VoiceSplit.oneColumnCard(room: room, row: rowH, bot: botBlock(botLevel), controls: controlsH, heights: cardHeights)?.allScroll == true ? "yes" : "no") : "none")"
            // The one cap both side captions take (#631, round 3f), or none.
            + ";captioncap \(captionCap.map { "\($0)" } ?? "none")"
            // The choices as drawn (#631, round 3g): the card's arrangement and measures, then each name's text size as
            // laid out, its one-line natural size and the room its cell gave it, for the rig's count of lines and its
            // check that no name is cut; none with no card.
            + ";choices \(choiceProbe.line)"
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
    /// The gradient's top: the bot's colour at 0.55, or less for a light colour, so the words over it pass 4.5:1 (#631).
    private var topOpacity: Double {
        VoiceLook.RGB(hex: BotColors.hex(for: chat.profileName)).map(VoiceLook.topOpacity(for:)) ?? VoiceLook.fullTopOpacity
    }

    private var background: some View {
        LinearGradient(colors: [tint.opacity(topOpacity), Color.black], startPoint: .top, endPoint: .bottom)
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
                // Full white (#631, round 3f): it stands on the gradient's brightest part.
                Text(session.isLive ? "Live voice · \(session.liveLabel ?? "")" : "Voice mode").font(.caption.weight(.semibold)).foregroundStyle(VoiceLook.topTitle.color)
                Text(chat.title.count > 30 ? String(chat.title.prefix(29)) + "…" : chat.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Spacer()
            // The chevron's balance on the far side; with the bot's face hidden (#631, round 3), the mic muted's badge,
            // which then has no face to sit on.
            ZStack {
                Color.clear.frame(width: 44, height: 44)
                if botLevel == .hidden, mutedShown { mutedBadge.transition(.opacity) }
            }
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
        // The split's sizes above a fold, and in one column when a waiting card needs the room (#631): lean then, its title
        // and the line under it gone too (the card's heading says the same), the mic muted a badge on the face. Hidden
        // (round 3), the block isn't drawn at all (`body`).
        let level = botLevel
        let full = split == nil && level == .full
        let lean = level == .lean
        return VStack(spacing: VoiceSplit.botLinesGap) {
            ZStack {
                // A ring breathes while the person is heard, and while the bot speaks; with the
                // motion engine the bot's own listening arcs take its place (1.5 #304).
                if !BotFace.motionEngine {
                    Circle()
                        .stroke(tint.opacity(0.5), lineWidth: 3)
                        .frame(width: full ? 196 : VoiceSplit.ring, height: full ? 196 : VoiceSplit.ring)
                        .scaleEffect(state.hearing || state.phase == .speaking ? 1.12 : 0.98)
                        .opacity(state.hearing || state.phase == .speaking ? 1 : 0.25)
                        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: state.hearing || state.phase == .speaking)
                }
                BotAvatar(profile: chat.profileName, size: full ? 164 : VoiceSplit.face, active: state.phase == .thinking || state.phase == .speaking, mood: mood)
            }
            // Lean and muted: the mic muted as a badge at the face's corner, no height of its own (#631).
            .overlay(alignment: .bottomTrailing) {
                if lean, mutedShown { mutedBadge.transition(.opacity) }
            }
            if !lean { stateLines }
            if waveformShown {
                HandsFreeWaveform(levels: session.levels, tint: tint)
                    .frame(height: 26).padding(.horizontal, 60)
                    .transition(.opacity)
            }
        }
    }

    /// Muted while the bot speaks or thinks: said plainly, not only by the button (#234).
    private var mutedLabel: some View {
        Label(VoiceLook.micMuted, systemImage: "mic.slash.fill").font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.white.opacity(0.18), in: .capsule)
            .transition(.opacity)
    }

    /// The lean bot's mic muted (#631): the capsule's symbol alone, on a dark disc at the face's corner; VoiceOver reads it
    /// as the capsule's words.
    private var mutedBadge: some View {
        Image(systemName: "mic.slash.fill").font(.caption.weight(.bold)).foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(.black.opacity(0.7), in: .circle)
            .accessibilityElement()
            .accessibilityLabel(Text(VoiceLook.micMuted))
    }

    /// The bot's state: its title, the mic muted, and the line under them.
    private var stateLines: some View {
        VStack(spacing: 6) {
            Text(state.title).font(.title2.weight(.semibold)).contentTransition(.numericText())
            if mutedShown { mutedLabel }
            // Above the fold every line stops at two (`VoiceSplit.minTop`); VoiceOver still reads it whole.
            // The quieter lines in voice mode's white at 0.85, a note or an error in orange on a dark backing of its
            // own: they pass 4.5:1 over any bot colour (#631).
            if state.phase == .thinking, let goal {
                Text(goal).font(.subheadline).foregroundStyle(VoiceLook.secondary).lineLimit(2).multilineTextAlignment(.center)
            } else if state.phase == .needsApproval {
                Text("Allow or deny it here. The bot waits for your answer.").font(.subheadline).foregroundStyle(VoiceLook.secondary).lineLimit(split == nil ? nil : 2)
            } else if state.phase == .paused {
                Text(state.note ?? "Tap Resume to keep going.").font(.subheadline).foregroundStyle(VoiceLook.secondary).multilineTextAlignment(.center).lineLimit(split == nil ? nil : 2)
            } else if let note = state.note {
                noteLine(note)
            } else if let lastError {
                noteLine(lastError)
            }
        }
        .padding(.horizontal, 24)
    }

    private func noteLine(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(VoiceLook.orange.color).multilineTextAlignment(.center).lineLimit(split == nil ? nil : 2)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(VoiceLook.noteBackingOpacity), in: .rect(cornerRadius: 12))
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
        // The four captions' widest one-line width at this text size (#631, round 3e), and under each cap (round 3f),
        // measured off screen.
        .background {
            VStack {
                VStack { ForEach(Self.captions, id: \.self) { Text($0).font(.caption).fixedSize() } }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { captionW = $0 }
                ForEach(VoiceSplit.captionCaps.indices, id: \.self) { i in
                    VStack { ForEach(Self.captions, id: \.self) { Text($0).font(.caption).fixedSize() } }
                        .fixedSize()
                        .dynamicTypeSize(...VoiceSplit.captionCaps[i])
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { captionCappedW[i] = $0 }
                }
            }
            .fixedSize().hidden().accessibilityHidden(true)
        }
    }

    /// Every caption a side control can show (#631, round 3e).
    private static let captions = ["Mute", "Unmute", "Pause", "Resume"]
    /// The side columns' width (#631, round 3e): 88 under the accessibility sizes, where every caption fits it on one
    /// line. At them, the widest caption's own one-line width (measured off screen) and 8 pt of margin, up to what the row
    /// allows (`sideRoom`), the same both sides so End stays in the middle; when even that can't hold the widest caption,
    /// both captions take the one largest size that does (`captionCap`, round 3f).
    private var controlColumn: CGFloat {
        guard typeSize.isAccessibilitySize else { return 88 }
        return max(88, min(captionW + 8, sideRoom))
    }
    /// What the row allows a side: the column less End's 72 and the two 19 pt gaps, halved.
    private var sideRoom: CGFloat { (column.width - 72 - 2 * 19) / 2 }
    /// The one cap both side captions take (#631, round 3f, `VoiceSplit.captionCap`), so they are always the same size;
    /// none under the accessibility sizes, where every caption fits.
    private var captionCap: DynamicTypeSize? {
        typeSize.isAccessibilitySize ? VoiceSplit.captionCap(room: sideRoom, current: captionW, capped: captionCappedW) : nil
    }

    /// A control's caption on one line, never shrunk (#631, round 3e).
    private func caption(_ label: String) -> some View {
        Text(label).font(.caption).foregroundStyle(VoiceLook.secondary).lineLimit(1)
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
            // Never shrunk past a whole word, never cut or wrapped (#631, round 3e), and both sides the same size (round
            // 3f): at its own size when the side holds the widest caption on one line, else both at the one largest
            // accessibility size that does (`captionCap`), a size floor as the stock controls have.
            caption(label).dynamicTypeSize(...(captionCap ?? .accessibility5))
        }
        // Both columns as wide, whatever their words ("Unmute", "Resume", large text): End stays in the middle
        // (`controlColumn`: 88 under the accessibility sizes, wider at them).
        .frame(width: controlColumn)
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
    /// The prompt's and the person's words: `.secondary` unless given (the iPhone's voice screen gives its own, #631).
    var quiet: Color? = nil
    private var quietStyle: AnyShapeStyle { quiet.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary) }
    /// The iPhone's voice screen (#631, round 3l): whole lines only, at the top edge too (`VoiceSplit.conversationShown`).
    /// The Mac's window keeps its scroll as it was.
    var wholeLines = false
    /// Following the newest words; off while the person reads back.
    @State private var following = true
    @State private var userScrolling = false
    private let bottomID = "voice.transcript.bottom"
    /// Round 3l: the room the conversation is given, one line of it, and its rows' heights (the prompt's while nothing has
    /// been said), for the whole lines.
    @State private var roomH: CGFloat = 0
    @State private var lineH: CGFloat = 0
    @State private var promptH: CGFloat = 0
    @State private var rowHeights: [UUID: CGFloat] = [:]
    /// The scroll's height on the voice screen (round 3l): cut down to whole lines, the rest blank above it. nil off the
    /// voice screen and until the room is measured.
    private var shownH: CGFloat? {
        guard wholeLines, roomH > 0 else { return nil }
        let rows = lines.isEmpty ? [promptH] : lines.reversed().map { rowHeights[$0.id] ?? 0 }
        return VoiceSplit.conversationShown(room: roomH, rows: rows, line: lineH)
    }
    /// The top fade's height (round 3l): 28, never over the newest whole line on the voice screen, so a lone line shows whole.
    private func fade(_ shown: CGFloat?) -> CGFloat {
        guard let shown, lineH > 0 else { return 28 }
        return min(28, max(0, shown - VoiceSplit.conversationBottom - lineH))
    }

    var body: some View {
        let shown = shownH
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: VoiceSplit.conversationGap) {
                    if lines.isEmpty {
                        Text(prompt).font(.body).foregroundStyle(quietStyle)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { promptH = $0 }
                    }
                    ForEach(lines) { line in
                        row(line).id(line.id)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeights[line.id] = $0 }
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 24).padding(.top, VoiceSplit.conversationTop).padding(.bottom, 6)
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
            // Round 3l: back at the newest when the whole-lines height changes (the card coming shortens it), so its lines
            // stand where they were worked out from. The scroll takes that height over its room (`WholeLinesRoom`, 3m).
            .onChange(of: shown) { _, _ in if following { proxy.scrollTo(bottomID, anchor: .bottom) } }
            .mask {
                // The top edge fades, so a line scrolling out does not cut under the state line (round 3l: never over the
                // newest whole line).
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: fade(shown))
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
        // Round 3l: on the voice screen, the room it is given (the scroll at its foot at the whole-lines height, the rest
        // blank above it) and one line, measured off screen; the Mac's window as it was.
        .modifier(WholeLinesRoom(on: wholeLines, shown: shown, room: $roomH, line: $lineH))
    }

    /// What changes as the conversation goes on: the last line's words and the count.
    private var tail: String { "\(lines.count):" + (lines.last?.text ?? "") }

    @ViewBuilder private func row(_ line: VoiceLine) -> some View {
        if line.isPerson {
            Text(Mentions.attributed(line.text, names: Mentions.names)).font(.body).foregroundStyle(quietStyle)
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

/// The voice screen's conversation in its room (#631, round 3l): the scroll at the room's foot at its whole-lines height
/// (`shown`), the rest blank above it, the room and one line of the conversation measured for its whole lines. Round 3m:
/// the room is read from a clear view that takes exactly what it is offered, and the scroll stands over it in an overlay,
/// which never changes the size of the view it is on. In 3l the room was read from a frame the scroll itself held open,
/// so once read tall it never came back down, and an approval arriving left the column past the screen. Off (the Mac's
/// voice window), the content as it is, so that window's layout doesn't change.
struct WholeLinesRoom: ViewModifier {
    let on: Bool
    let shown: CGFloat?
    @Binding var room: CGFloat
    @Binding var line: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if on {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { room = $0 }
                .background {
                    Text(verbatim: "Ag").font(.body).fixedSize().hidden().accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { line = $0 }
                }
                .overlay(alignment: .bottom) { content.frame(height: shown) }
        } else {
            content
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
