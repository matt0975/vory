#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Vory
@testable import VoryCore

/// What the Mac's voice window shows for each state of the shared loop: the title, the line
/// under it, the badges and the controls. The words themselves are the shared transcript's.
@Suite struct MacVoiceHUDTests {
    private func make(_ s: HandsFreeState, goal: String? = nil, error: String? = nil) -> VoiceHUDPresentation {
        VoiceHUDPresentation.make(state: s, spoken: "", liveText: "", goal: goal, error: error)
    }

    @Test func listeningThenThinkingShowTheStateAndTheGoal() {
        var s = HandsFreeState()
        _ = s.handle(.start)
        let p = make(s)
        #expect(p.title == "Listening…" && p.line == nil && p.showsWaveform && !p.pulses && !p.showsMutedBadge)
        _ = s.handle(.speechStarted)
        let hearing = make(s)
        #expect(hearing.title == "Listening" && hearing.pulses)
        _ = s.handle(.speechEnded)
        _ = s.handle(.transcript("What is filling the disk?"))
        let thinking = make(s, goal: "Measuring /var/log")
        #expect(thinking.title == "Thinking…" && thinking.line == "Measuring /var/log" && thinking.mood == .thinking && thinking.faceActive && !thinking.showsWaveform)
    }

    @Test func theEngineShowsTheArcsWhileListeningAndThePlainBotWhileSpeaking() {
        let kept = BotFace.motionEngine
        defer { BotFace.motionEngine = kept }
        var s = HandsFreeState()
        _ = s.handle(.start)
        BotFace.motionEngine = true
        #expect(make(s).mood == .listening)
        BotFace.motionEngine = false
        #expect(make(s).mood == .idle)
        _ = s.handle(.speechStarted); _ = s.handle(.speechEnded); _ = s.handle(.transcript("go")); _ = s.handle(.sent)
        _ = s.handle(.replyDelta("It is the logs.")); _ = s.handle(.audioStarted)
        BotFace.motionEngine = true
        // The presentation still says speaking; the face it maps to is the plain working bot.
        #expect(make(s).mood == .speaking)
    }

    @Test func speakingAndApprovalPointAtTheChat() {
        var s = HandsFreeState()
        _ = s.handle(.start); _ = s.handle(.speechStarted); _ = s.handle(.speechEnded); _ = s.handle(.transcript("go")); _ = s.handle(.sent)
        _ = s.handle(.replyDelta("It is the rotated logs.")); _ = s.handle(.audioStarted)
        let speaking = make(s)
        #expect(speaking.title == "Speaking" && speaking.mood == .speaking && speaking.pulses && !speaking.showsWaveform)
        _ = s.handle(.cardArrived(summary: "run rm on /var/log"))
        let approval = make(s)
        #expect(approval.title == "Approval needed" && approval.showsApproval && approval.line == VoiceHUDPresentation.approvalHint && approval.mood == .approval)
    }

    @Test func muteShowsInTheTitleWhileListeningAndAsABadgeOtherwise() {
        var s = HandsFreeState()
        _ = s.handle(.start)
        _ = s.handle(.mute)
        let muted = make(s)
        #expect(muted.title == "Muted" && muted.muteLabel == "Unmute" && muted.muteSymbol == "mic.slash.fill" && !muted.showsWaveform && !muted.showsMutedBadge)
        // Muted while the bot thinks or speaks: the title is the bot's state, the badge says the mic is off.
        _ = s.handle(.unmute); _ = s.handle(.speechStarted); _ = s.handle(.speechEnded); _ = s.handle(.transcript("go")); _ = s.handle(.sent)
        _ = s.handle(.mute)
        let thinkingMuted = make(s)
        #expect(thinkingMuted.title == "Thinking…" && thinkingMuted.showsMutedBadge && thinkingMuted.muteLabel == "Unmute")
        _ = s.handle(.replyDelta("Done.")); _ = s.handle(.audioStarted)
        #expect(make(s).showsMutedBadge && make(s).title == "Speaking")
        _ = s.handle(.unmute)
        #expect(!make(s).showsMutedBadge)
    }

    @Test func pauseAndNotesShowAsLinesAndWarnings() {
        var s = HandsFreeState()
        _ = s.handle(.start)
        _ = s.handle(.pause)
        let paused = make(s)
        #expect(paused.title == "Paused" && paused.pauseLabel == "Resume" && !paused.muteEnabled && paused.line == VoiceHUDPresentation.pausedHint && paused.mood == .still)
        _ = s.handle(.resume)
        _ = s.handle(.speechStarted); _ = s.handle(.speechEnded)
        _ = s.handle(.transcriptFailed("No STT provider"))
        let failed = make(s)
        #expect(failed.line == "No STT provider" && failed.lineIsWarning && failed.title == "Listening…")
        #expect(make(HandsFreeState(), error: "Microphone access denied.").line == "Microphone access denied.")
    }

    @Test func theEmptyTranscriptSaysHowEachEngineAnswers() {
        #expect(VoiceHUDPresentation.prompt(live: false) == VoiceHUDPresentation.prompt)
        #expect(VoiceHUDPresentation.prompt(live: true) == VoiceHUDPresentation.livePrompt)
        #expect(VoiceHUDPresentation.prompt.contains("pause") && !VoiceHUDPresentation.livePrompt.contains("pause"))
    }

    /// The text sizes the window is measured at (#627), the default first: macOS's SwiftUI may draw some of them alike.
    private static let sizes: [DynamicTypeSize] = [.large, .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility3]

    /// A view's own width, as laid out with nothing pressing on it, at one text size.
    @MainActor private static func idealWidth(_ v: some View, _ size: DynamicTypeSize) -> CGFloat {
        NSHostingView(rootView: v.environment(\.dynamicTypeSize, size)).fittingSize.width
    }

    /// The approval's Show Chat at the window's default width (#627): in the control row it was cut to "Show…". Under
    /// the approval's line it has the text column (210 pt at 340), and its whole label fits there at every text size.
    @MainActor @Test func theApprovalsShowChatFitsItsColumnAtTheDefaultWidthAtEveryTextSize() {
        #expect(MacVoiceHUD.textColumnWidth == 210)
        let widths = Self.sizes.map { Self.idealWidth(VoiceShowChatButton {}, $0) }
        print("VOICE-627 Show Chat: \(zip(Self.sizes, widths).map { "\($0.0) \(Int($0.1.rounded()))" }.joined(separator: ", ")); column \(MacVoiceHUD.textColumnWidth)")
        for (size, w) in zip(Self.sizes, widths) {
            #expect(w > 0 && w <= MacVoiceHUD.textColumnWidth, "Show Chat needs \(w) pt at \(size); the column has \(MacVoiceHUD.textColumnWidth)")
        }
    }

    /// The control row at the window's default width (#627), with its longest labels (Unmute, Resume) and End: it fits its
    /// room (312 pt at 340) at every text size, with nothing cut.
    @MainActor @Test func theControlRowFitsTheDefaultWidthAtEveryTextSize() {
        #expect(MacVoiceHUD.controlRowWidth == 312)
        var p = VoiceHUDPresentation(title: "Paused")
        p.muteLabel = "Unmute"; p.muteSymbol = "mic.slash.fill"; p.pauseLabel = "Resume"; p.pauseSymbol = "play.fill"
        let row = VoiceControlRow(p: p, muted: true, paused: true, mute: {}, pause: {}, end: {})
        let widths = Self.sizes.map { Self.idealWidth(row, $0) }
        print("VOICE-627 control row: \(zip(Self.sizes, widths).map { "\($0.0) \(Int($0.1.rounded()))" }.joined(separator: ", ")); room \(MacVoiceHUD.controlRowWidth)")
        for (size, w) in zip(Self.sizes, widths) {
            #expect(w > 0 && w <= MacVoiceHUD.controlRowWidth, "the control row needs \(w) pt at \(size); it has \(MacVoiceHUD.controlRowWidth)")
        }
    }
}
#endif
