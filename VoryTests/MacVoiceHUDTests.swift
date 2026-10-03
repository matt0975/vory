#if os(macOS)
import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// What the Mac's voice window shows for each state of the shared loop.
@Suite struct MacVoiceHUDTests {
    private func make(_ s: HandsFreeState, spoken: String = "", live: String = "", goal: String? = nil, error: String? = nil) -> VoiceHUDPresentation {
        VoiceHUDPresentation.make(state: s, spoken: spoken, liveText: live, goal: goal, error: error)
    }

    @Test func listeningShowsThePromptThenTheWordsAsTheyAreHeard() {
        var s = HandsFreeState()
        _ = s.handle(.start)
        let p = make(s)
        #expect(p.title == "Listening…" && p.caption == VoiceHUDPresentation.prompt && p.captionIsQuote && p.showsWaveform && !p.pulses)
        _ = s.handle(.speechStarted)
        let hearing = make(s, live: "what is filling the disk")
        #expect(hearing.title == "Listening" && hearing.caption == "what is filling the disk" && !hearing.captionIsQuote && hearing.pulses)
        _ = s.handle(.speechEnded)
        _ = s.handle(.transcript("What is filling the disk?"))
        let thinking = make(s, goal: "Measuring /var/log")
        #expect(thinking.title == "Thinking…" && thinking.line == "Measuring /var/log" && thinking.caption == "“What is filling the disk?”" && thinking.mood == .thinking && thinking.faceActive)
    }

    @Test func speakingShowsTheReplyAndApprovalPointsAtTheChat() {
        var s = HandsFreeState()
        _ = s.handle(.start); _ = s.handle(.speechStarted); _ = s.handle(.speechEnded); _ = s.handle(.transcript("go")); _ = s.handle(.sent)
        _ = s.handle(.replyDelta("It is the rotated logs.")); _ = s.handle(.audioStarted)
        let speaking = make(s, spoken: "It is the rotated logs.")
        #expect(speaking.title == "Speaking" && speaking.caption == "It is the rotated logs." && speaking.mood == .speaking && speaking.pulses && !speaking.showsWaveform)
        _ = s.handle(.cardArrived(summary: "run rm on /var/log"))
        let approval = make(s)
        #expect(approval.title == "Approval needed" && approval.showsApproval && approval.line == VoiceHUDPresentation.approvalHint && approval.mood == .approval)
    }

    @Test func muteAndPauseChangeTheControlsAndNotesShowAsWarnings() {
        var s = HandsFreeState()
        _ = s.handle(.start)
        _ = s.handle(.mute)
        let muted = make(s)
        #expect(muted.title == "Muted" && muted.muteLabel == "Unmute" && muted.muteSymbol == "mic.slash.fill" && !muted.showsWaveform)
        _ = s.handle(.unmute)
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

    @Test func aLongReplyShowsItsTail() {
        let long = String(repeating: "word ", count: 80)
        let t = VoiceHUDPresentation.tail(long)
        #expect(t.hasPrefix("…") && t.count == 200)
        #expect(VoiceHUDPresentation.tail("short") == "short")
    }
}
#endif
