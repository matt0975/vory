#if os(macOS)
import Foundation
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
}
#endif
