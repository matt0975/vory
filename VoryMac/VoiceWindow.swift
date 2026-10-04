import AppKit
import SwiftUI
import VoryCore

/// Voice mode on the Mac: a small window that floats above the others while the conversation
/// runs (the main window may be behind or minimised), with the bot's face in its mood, what
/// the loop is doing, the words heard or being said, and Mute, Pause and End. The loop itself
/// is the shared one (`HandsFreeSession` on `HandsFreeState`); this is its window. Approvals
/// are never taken here: the window says one waits and points at the chat.
struct MacVoiceHUD: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var session = HandsFreeSession.shared

    static let size = CGSize(width: 340, height: 220)

    var body: some View {
        Group {
            if let chat = session.chat, session.isActive { content(chat) } else { ended }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // The loop ended (End here, or from the chat, or the gateway went): the window goes.
        .onChange(of: session.isActive) { _, on in if !on { dismissWindow(id: MacWindow.voice) } }
        // The window closed by its own button: the loop ends with it.
        .onDisappear { session.end() }
    }

    private var ended: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.mic").font(.title).foregroundStyle(.secondary)
            Text("Voice mode is off").font(.headline)
            Text("Open a chat and choose Voice Mode (⇧⌘V).").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private func content(_ chat: ChatSession) -> some View {
        // `levels` and `liveText` are the session's, whichever engine is on (Standard's listener or Live).
        let p = VoiceHUDPresentation.make(state: session.state, spoken: session.spoken, liveText: session.liveText,
                                          goal: ChatGoals.shared.goal(for: chat.storedID) ?? chat.statusLine, error: session.lastError)
        let tint = BotColors.color(for: chat.profileName)
        return ZStack {
            LinearGradient(colors: [tint.opacity(0.45), Color.black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        Circle()
                            .stroke(tint.opacity(0.6), lineWidth: 2.5)
                            .frame(width: 78, height: 78)
                            .scaleEffect(p.pulses ? 1.1 : 0.98)
                            .opacity(p.pulses ? 1 : 0.25)
                            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: p.pulses)
                        BotAvatar(profile: chat.profileName, size: 64, active: p.faceActive, mood: mood(p.mood, chat))
                    }
                    .frame(width: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(p.title).font(.headline).contentTransition(.numericText())
                            if session.isLive, let label = session.liveLabel {
                                // A Live conversation (the person's own key, billed per minute): which model.
                                Text("Live · \(label)").font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.white.opacity(0.14), in: .capsule)
                                    .help("A Live conversation with \(label), on your own key")
                            }
                            Spacer(minLength: 0)
                            Text(chat.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).frame(maxWidth: 120, alignment: .trailing)
                        }
                        if let line = p.line {
                            Text(line).font(.caption).foregroundStyle(p.lineIsWarning ? Color.orange : Color.secondary).lineLimit(2)
                        }
                        Text(p.caption).font(.callout).foregroundStyle(p.captionIsQuote ? Color.secondary : Color.primary)
                            .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                            .animation(.default, value: p.caption)
                        if p.showsWaveform {
                            HandsFreeWaveform(levels: session.levels, tint: tint).frame(height: 18).transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 14)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    control(p.muteSymbol, label: p.muteLabel, on: session.state.isMuted) { session.toggleMute() }
                        .disabled(!p.muteEnabled)
                        .accessibilityIdentifier("voice.mute")
                    control(p.pauseSymbol, label: p.pauseLabel, on: session.state.phase == .paused) { session.togglePause() }
                        .accessibilityIdentifier("voice.pause")
                    if p.showsApproval {
                        Button { showChat() } label: { Label("Show Chat", systemImage: "checkmark.shield") }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .help("The approval waits in the chat")
                            .accessibilityIdentifier("voice.showChat")
                    }
                    Spacer(minLength: 0)
                    Button { session.end() } label: { Label("End", systemImage: "xmark") }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                        .keyboardShortcut(.escape, modifiers: [])
                        .accessibilityIdentifier("voice.end")
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .animation(.snappy, value: session.state.phase)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice mode, \(p.title)")
    }

    private func control(_ symbol: String, label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(label, systemImage: symbol) }
            .buttonStyle(.bordered).controlSize(.small)
            .tint(on ? .accentColor : nil)
            .help(label)
    }

    private func mood(_ m: VoiceHUDPresentation.Mood, _ chat: ChatSession) -> BotFaceView.Mood {
        switch m {
        case .idle: return BotFaceView.Mood(profile: chat.profileName, state: .idle)
        case .thinking: return BotFaceView.Mood(thinking: true, profile: chat.profileName, state: .thinking)
        case .speaking: return BotFaceView.Mood(profile: chat.profileName, state: .streaming)
        case .approval: return BotFaceView.Mood(profile: chat.profileName, state: .awaitingApproval)
        case .still: return BotFaceView.Mood(profile: chat.profileName, state: .idle, still: true)
        }
    }

    /// The main window in front, on the chat the loop is in, where the card is.
    private func showChat() {
        openWindow(id: MacWindow.main)
        NSApp.activate()
        if let chat = session.chat {
            model.pendingRoute = PendingRoute(connectionID: model.runtime?.connection.id, storedSessionID: chat.storedID, profile: chat.profileName)
            model.selectedTab = .chats
        }
    }
}

/// What the window shows for a loop state: worked out apart from the view so it can be tested.
struct VoiceHUDPresentation: Equatable {
    enum Mood: Equatable { case idle, thinking, speaking, approval, still }
    var title: String
    /// The line under the title: the bot's goal while it thinks, a note, the approval hint,
    /// the paused hint; nil when there is nothing to say.
    var line: String?
    var lineIsWarning = false
    /// The words: the reply being said, the words being heard, the last words heard (as a
    /// quote), or the prompt to speak.
    var caption: String
    var captionIsQuote = false
    var showsWaveform = false
    var showsApproval = false
    var pulses = false
    var faceActive = false
    var mood: Mood = .idle
    var muteEnabled = true
    var muteLabel = "Mute"
    var muteSymbol = "mic.fill"
    var pauseLabel = "Pause"
    var pauseSymbol = "pause.fill"

    static let prompt = "Say something. I'll answer when you pause."
    static let approvalHint = "Approve on screen. The loop waits."
    static let pausedHint = "Resume to keep going."

    static func make(state: HandsFreeState, spoken: String, liveText: String, goal: String?, error: String?) -> VoiceHUDPresentation {
        var p = VoiceHUDPresentation(title: state.title, caption: prompt)
        // The line.
        switch state.phase {
        case .thinking:
            if let goal, !goal.isEmpty { p.line = goal }
        case .needsApproval:
            p.line = approvalHint
        case .paused:
            p.line = state.note ?? pausedHint
        default:
            if let note = state.note { p.line = note; p.lineIsWarning = true }
            else if let error { p.line = error; p.lineIsWarning = true }
        }
        // The words.
        if state.phase == .speaking || (state.phase == .thinking && !spoken.isEmpty) {
            p.caption = tail(spoken)
        } else if state.hearing, !liveText.isEmpty {
            p.caption = tail(liveText)
        } else if let heard = state.caption {
            p.caption = "“\(heard)”"; p.captionIsQuote = true
        } else {
            p.caption = prompt; p.captionIsQuote = true
        }
        p.showsWaveform = state.phase == .listening && !state.isMuted
        p.showsApproval = state.phase == .needsApproval
        p.pulses = state.hearing || state.phase == .speaking
        p.faceActive = state.phase == .thinking || state.phase == .speaking
        switch state.phase {
        case .listening, .transcribing: p.mood = .idle
        case .thinking: p.mood = .thinking
        case .speaking: p.mood = .speaking
        case .needsApproval: p.mood = .approval
        case .paused, .ended: p.mood = .still
        }
        p.muteEnabled = state.phase != .paused
        p.muteLabel = state.isMuted ? "Unmute" : "Mute"
        p.muteSymbol = state.isMuted ? "mic.slash.fill" : "mic.fill"
        p.pauseLabel = state.phase == .paused ? "Resume" : "Pause"
        p.pauseSymbol = state.phase == .paused ? "play.fill" : "pause.fill"
        return p
    }

    static func tail(_ s: String, max: Int = 200) -> String {
        guard s.count > max else { return s }
        return "…" + String(s.suffix(max - 1))
    }
}
