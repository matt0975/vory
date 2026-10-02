#if os(iOS)
import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// What happens to a Live Activity still showing when the app comes to the front, the goal
/// line on its card, and a turn found stopped after the app was away.
@Suite struct LiveActivityTests {
    @Test func aFinishedOrExpiredActivityIsEnded() {
        #expect(LiveActivityController.lingering(finished: true, age: 30, openHere: false, runningHere: false) == .end)
        #expect(LiveActivityController.lingering(finished: false, age: LiveActivityController.longestTurn + 1, openHere: true, runningHere: true) == .end)
    }

    @Test func aChatThatLooksIdleHereIsAskedAboutNotEnded() {
        // The case behind "tapping the Live Activity erases it": the turn was started from
        // another device, the tap opened the app, and the app only knew the chat as idle.
        #expect(LiveActivityController.lingering(finished: false, age: 600, openHere: true, runningHere: false) == .ask)
    }

    @Test func aRunningChatAndAChatNotOpenHereAreLeftAlone() {
        #expect(LiveActivityController.lingering(finished: false, age: 600, openHere: true, runningHere: true) == .keep)
        // Not open in this app: the Companion ends it when its turn does.
        #expect(LiveActivityController.lingering(finished: false, age: 600, openHere: false, runningHere: false) == .keep)
        // Long work: four hours in is still one turn.
        #expect(LiveActivityController.lingering(finished: false, age: 4 * 3600, openHere: true, runningHere: true) == .keep)
    }

    @Test func theGoalLeadsOnlyWhileTheTurnRuns() {
        var s = HermesTurnAttributes.ContentState(phase: "tool", detail: "Running terminal", outputTokens: 0, contextPercent: nil, needsAttention: false)
        #expect(s.shownGoal == nil)
        s.goal = "  Finding why the export times out "
        #expect(s.shownGoal == "Finding why the export times out")
        s.needsAttention = true
        #expect(s.shownGoal == nil)
        s.needsAttention = false
        s.endedAtUnix = Date().timeIntervalSince1970
        #expect(s.shownGoal == nil)
        s.endedAtUnix = nil; s.goal = "   "
        #expect(s.shownGoal == nil)
    }

    @Test func aPushWithoutAGoalStillDecodes() throws {
        // What a Companion older than 1.0.36 sends.
        let old = #"{"phase":"tool","detail":"Running a tool…","outputTokens":12,"contextPercent":null,"needsAttention":false,"startedAtUnix":1790900000,"endedAtUnix":null}"#
        let s = try JSONDecoder().decode(HermesTurnAttributes.ContentState.self, from: Data(old.utf8))
        #expect(s.goal == nil && s.detail == "Running a tool…")
        let new = #"{"phase":"tool","detail":"Running a tool…","outputTokens":12,"needsAttention":false,"startedAtUnix":1790900000,"goal":"Clearing old logs"}"#
        #expect(try JSONDecoder().decode(HermesTurnAttributes.ContentState.self, from: Data(new.utf8)).shownGoal == "Clearing old logs")
    }

    @Test func aThreadEndingInTheGatewaysSentenceCountsAsInterrupted() {
        func item(_ kind: TranscriptItem.Kind) -> TranscriptItem { TranscriptItem(id: UUID().uuidString, kind: kind) }
        let prompt = item(.user(text: "Clean up the logs", attachments: []))
        let cut = item(.assistant(text: "Operation interrupted: waiting for model response (12.4s elapsed).", reasoning: nil, streaming: false))
        let reply = item(.assistant(text: "Done, 4.2 GB freed.", reasoning: nil, streaming: false))
        #expect(AwayWatch.endsInterrupted([prompt, cut]))
        // A note under it does not hide it.
        #expect(AwayWatch.endsInterrupted([prompt, cut, item(.system(text: "Interrupted", symbol: "stop.circle"))]))
        #expect(!AwayWatch.endsInterrupted([prompt, reply]))
        // An older interrupted turn above a newer prompt is not this turn's.
        #expect(!AwayWatch.endsInterrupted([prompt, cut, prompt]))
        #expect(!AwayWatch.endsInterrupted([]))
    }
}
#endif
