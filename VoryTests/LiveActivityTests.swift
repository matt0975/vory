#if os(iOS)
import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// A turn started on another device: whether its prompt is already in the snapshot's messages.
@Suite struct InflightPromptTests {
    @Test func theSameWordsSentAgainAreANewPrompt() {
        // The last user row says the same thing but is from an earlier turn.
        #expect(!ChatSession.inflightPromptIsListed(prompt: "Free up space", lastUserText: "Free up space", lastUserAt: 1000, turnStart: 2000))
        // The last user row is this turn's own: already listed.
        #expect(ChatSession.inflightPromptIsListed(prompt: "Free up space", lastUserText: "Free up space", lastUserAt: 2000.4, turnStart: 2000))
        #expect(ChatSession.inflightPromptIsListed(prompt: "Free up space", lastUserText: "Free up space", lastUserAt: 1999.5, turnStart: 2000))
    }

    @Test func differentWordsAreNeverListedAndNoStartTimeGoesByTheText() {
        #expect(!ChatSession.inflightPromptIsListed(prompt: "b", lastUserText: "a", lastUserAt: 2000, turnStart: 2000))
        #expect(!ChatSession.inflightPromptIsListed(prompt: "b", lastUserText: nil, lastUserAt: nil, turnStart: 2000))
        // An older gateway that does not say when the turn began.
        #expect(ChatSession.inflightPromptIsListed(prompt: "a", lastUserText: "a", lastUserAt: 1000, turnStart: 0))
    }
}

/// A snapshot replacing the rows on screen: rows that say the same keep their ids.
@Suite struct SnapshotRowIDTests {
    private func user(_ id: String, _ t: String) -> TranscriptItem { TranscriptItem(id: id, kind: .user(text: t, attachments: [])) }
    private func reply(_ id: String, _ t: String, streaming: Bool = false) -> TranscriptItem { TranscriptItem(id: id, kind: .assistant(text: t, reasoning: nil, streaming: streaming)) }
    private func tool(_ id: String, _ name: String) -> TranscriptItem { TranscriptItem(id: id, kind: .tool(ToolActivity(id: id, name: name, context: nil, status: .done))) }
    private func note(_ id: String) -> TranscriptItem { TranscriptItem(id: id, kind: .system(text: "Answered on another device", symbol: "checkmark.shield")) }

    @Test func aTurnWatchedLiveKeepsItsRowsWhenHistoryNumbersThem() {
        let shown = [user("h-1-0", "Check the disk"), reply("h-2-1", "It is full."),
                     user("inflight-user-170", "Free up space"), reply("stream-1", "Looking."), tool("tool-t-1", "terminal"),
                     note("local-1"), reply("stream-2", "Done.")]
        let built = [user("h-1-0", "Check the disk"), reply("h-2-1", "It is full."),
                     user("h-3-2", "Free up space"), reply("h-4-3", "Looking.\n"), tool("h-5-4", "terminal"), reply("h-6-5", "Done.")]
        let ids = ChatSession.keepingIDs(built, from: shown).map(\.id)
        #expect(ids == ["h-1-0", "h-2-1", "inflight-user-170", "stream-1", "tool-t-1", "stream-2"])
    }

    @Test func rowsThatSayOtherThingsKeepHistorysIDs() {
        let shown = [user("a", "one"), reply("b", "two")]
        let built = [user("h-1-0", "three"), reply("h-2-1", "four"), tool("h-3-2", "terminal")]
        #expect(ChatSession.keepingIDs(built, from: shown).map(\.id) == ["h-1-0", "h-2-1", "h-3-2"])
        #expect(ChatSession.keepingIDs(built, from: []).map(\.id) == ["h-1-0", "h-2-1", "h-3-2"])
    }

    @Test func theSameWordsTwicePairInOrderAndNoIDIsUsedTwice() {
        let shown = [user("u1", "ok"), reply("r1", "Sure."), user("u2", "ok"), reply("r2", "Sure.")]
        let built = [user("h-1-0", "ok"), reply("h-2-1", "Sure."), user("h-3-2", "ok"), reply("h-4-3", "Sure."), user("h-5-4", "ok")]
        let ids = ChatSession.keepingIDs(built, from: shown).map(\.id)
        #expect(ids == ["u1", "r1", "u2", "r2", "h-5-4"])
        // Rows shifted by one: a row shown under history's id for the next row must not make two rows share it.
        let shifted = ChatSession.keepingIDs([user("h-1-0", "new first"), user("h-2-1", "ok")], from: [user("h-2-1", "new first"), user("x", "ok")]).map(\.id)
        #expect(Set(shifted).count == 2)
    }

    @Test func aReplyStillStreamingIsNotPairedWithHistory() {
        let shown = [user("u1", "go"), reply("stream-9", "Half", streaming: true)]
        let built = [user("h-1-0", "go"), reply("h-2-1", "Half")]
        #expect(ChatSession.keepingIDs(built, from: shown).map(\.id) == ["u1", "h-2-1"])
    }
}

/// Where the phone's thread stops being lazy.
@Suite struct TranscriptTailTests {
    @Test func aShortThreadIsNotLazyAndALongOneKeepsAtLeastABlockAtItsEnd() {
        #expect(TranscriptRowModel.tailStart(0) == 0)
        #expect(TranscriptRowModel.tailStart(31) == 0)
        #expect(TranscriptRowModel.tailStart(32) == 16)
        #expect(TranscriptRowModel.tailStart(500) == 480)
        for n in 0...200 { #expect(n - TranscriptRowModel.tailStart(n) < 2 * TranscriptRowModel.tailBlock) }
    }

    @Test func theThreadsOwnBoundaryStandsUntilItLeavesTooMuchOrTooLittle() {
        // A thread that has not set one yet.
        #expect(TranscriptRowModel.split(count: 90, tailFrom: nil) == 64)
        // Rows arriving since the boundary was set: it stays where it is.
        #expect(TranscriptRowModel.split(count: 60, tailFrom: 16) == 16)
        // A long history arriving in a thread that had none: whole blocks, not every row at once.
        #expect(TranscriptRowModel.split(count: 500, tailFrom: 0) == 480)
        // More rows piled up than the end may hold.
        #expect(TranscriptRowModel.split(count: 16 + TranscriptRowModel.tailCap + 1, tailFrom: 16) == TranscriptRowModel.tailStart(16 + TranscriptRowModel.tailCap + 1))
        // A shorter thread than the boundary was set for.
        #expect(TranscriptRowModel.split(count: 20, tailFrom: 48) == 0)
    }
}

/// What the New Chat circle does on a tap and on a press and hold.
@Suite struct ComposeActionTests {
    @Test func nothingStoredIsTodaysBehaviour() {
        #expect(ComposeAction.tap(nil) == .quick)
        #expect(ComposeAction.hold(nil) == .sheet)
    }

    @Test func theTwoCanBeSwapped() {
        #expect(ComposeAction.tap("sheet") == .sheet)
        #expect(ComposeAction.hold("quick") == .quick)
        #expect(ComposeAction.hold("none") == .none)
    }

    @Test func aTapAlwaysDoesSomething() {
        // "none" is a choice for the hold only; an unknown value falls back too.
        #expect(ComposeAction.tap("none") == .quick)
        #expect(ComposeAction.tap("whatever") == .quick)
        #expect(ComposeAction.hold("") == .sheet)
    }
}

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
