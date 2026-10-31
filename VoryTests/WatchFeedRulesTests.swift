import Foundation
import Observation
import Testing
@testable import VoryCore

/// #387: the Watch chat's rules. Which rows the Watch shows, when it reads a chat (never at rest), which arrivals it
/// announces (nothing on a first read, a wrist-raise read of rows already seen, or a switch of path), how long the iPhone
/// follows a chat for it, which turn calls the iPhone passes on, and the cards on the phone path.
@Suite struct WatchFeedRulesTests {
    private func user(_ id: String, _ t: String = "hi") -> TranscriptItem { TranscriptItem(id: id, kind: .user(text: t, attachments: [])) }
    private func reply(_ id: String, _ t: String = "done", streaming: Bool = false) -> TranscriptItem {
        TranscriptItem(id: id, kind: .assistant(text: t, reasoning: nil, streaming: streaming))
    }
    private func tool(_ id: String, _ name: String, _ status: ToolActivity.Status = .done) -> TranscriptItem {
        TranscriptItem(id: id, kind: .tool(ToolActivity(id: id, name: name, status: status)))
    }

    // MARK: Rows

    @Test func aReplyStillBeingWrittenAndAThinkingOnlyStepAreNotShown() {
        let thinking = TranscriptItem(id: "t", kind: .assistant(text: "", reasoning: "weighing it", streaming: false))
        let rows = [user("u"), thinking, tool("a", "terminal"), reply("r1"), reply("r2", streaming: true)]
        #expect(WatchFeedRules.settled(rows).map(\.id) == ["u", "a", "r1"])
    }

    @Test func thisTurnsStepsAreTheToolsAfterTheLastMessageOfYours() {
        let rows = [user("u1"), tool("a", "read_file"), reply("r1"), user("u2"), tool("b", "terminal"), tool("c", "web_search", .running)]
        #expect(WatchFeedRules.turnTools(rows).map(\.name) == ["terminal", "web_search"])
        #expect(WatchFeedRules.turnTools([tool("x", "terminal")]).map(\.name) == ["terminal"])
    }

    // MARK: When the Watch reads a chat

    @Test func onlyThePhonePathPollsAndOnlyWhileATurnRuns() {
        #expect(WatchFeedRules.pollInterval(route: .throughPhone, working: true) == 2)
        #expect(WatchFeedRules.pollInterval(route: .throughPhone, working: false) == nil)
        #expect(WatchFeedRules.pollInterval(route: .live, working: true) == nil)
        #expect(WatchFeedRules.pollInterval(route: .live, working: false) == nil)
        #expect(WatchFeedRules.pollInterval(route: .offline, working: true) == nil)
    }

    @Test func comingForwardAndThePhoneComingBackReadAChatOnThePhonePath() {
        #expect(WatchFeedRules.refreshes(.sceneActive, route: .throughPhone))
        #expect(WatchFeedRules.refreshes(.phoneReachable, route: .throughPhone))
        #expect(WatchFeedRules.refreshes(.chatChanged, route: .throughPhone))
        #expect(WatchFeedRules.refreshes(.sceneActive, route: .offline))
        #expect(WatchFeedRules.refreshes(.phoneReachable, route: .offline))
    }

    @Test func theLivePathIgnoresWhatOnlyThePhonePathNeeds() {
        #expect(WatchFeedRules.refreshes(.sceneActive, route: .live))
        #expect(WatchFeedRules.refreshes(.liveChanged, route: .live))
        #expect(!WatchFeedRules.refreshes(.chatChanged, route: .live))
        #expect(!WatchFeedRules.refreshes(.poll, route: .live))
        #expect(!WatchFeedRules.refreshes(.phoneReachable, route: .live))
        #expect(!WatchFeedRules.refreshes(.poll, route: .offline))
    }

    // MARK: Arrivals

    /// A live attach that failed waits 30 s before the live path is tried again, and on the phone path at rest nothing
    /// else wakes the chat (no poll, the socket already open): it stayed there, every read waking the iPhone. The retry
    /// gets its own wake, only in that state.
    @Test func aFailedLiveAttachIsTriedAgainOnlyOnThePhonePathWithTheSocketUp() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let later = now.addingTimeInterval(30)
        #expect(WatchFeedRules.liveRetryWake(route: .throughPhone, socketUsable: true, retryAt: later, now: now) == 30)
        // The socket down: its coming back wakes the chat.
        #expect(WatchFeedRules.liveRetryWake(route: .throughPhone, socketUsable: false, retryAt: later, now: now) == nil)
        // On the live path, or offline: nothing to retry.
        #expect(WatchFeedRules.liveRetryWake(route: .live, socketUsable: true, retryAt: later, now: now) == nil)
        #expect(WatchFeedRules.liveRetryWake(route: .offline, socketUsable: true, retryAt: later, now: now) == nil)
    }

    /// On the phone path with the socket up and no retry pending, the live path is tried at once. The socket had opened
    /// while the phone path's read was out: its change went by unseen, and the Watch stayed on the phone path with the
    /// socket up for as long as the chat was open (a test that broke the socket and let it come back, 2026-10-20).
    @Test func thePhonePathWithTheSocketUpAndNoRetryPendingTriesTheLivePathAtOnce() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(WatchFeedRules.liveRetryWake(route: .throughPhone, socketUsable: true, retryAt: .distantPast, now: now) == 0)
        #expect(WatchFeedRules.liveRetryWake(route: .throughPhone, socketUsable: true, retryAt: now, now: now) == 0)
        // A retry pending still waits for it.
        #expect(WatchFeedRules.liveRetryWake(route: .throughPhone, socketUsable: true, retryAt: now.addingTimeInterval(12), now: now) == 12)
        // The socket down: no wake, its coming back wakes the chat.
        #expect(WatchFeedRules.liveRetryWake(route: .throughPhone, socketUsable: false, retryAt: .distantPast, now: now) == nil)
    }

    /// The try at once can't become a loop: one that fails waits its 30 seconds, one that works leaves the phone path.
    @Test func aTryAtOnceThatFailsWaitsItsThirtySecondsAndOneThatWorksNeedsNoWake() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let retryAt = WatchFeedRules.retryAfterFailedAttach(now: now)
        #expect(WatchFeedRules.liveRetryWake(route: .throughPhone, socketUsable: true, retryAt: retryAt, now: now) == 30)
        #expect(WatchFeedRules.liveRetryWake(route: .throughPhone, socketUsable: true, retryAt: retryAt, now: now.addingTimeInterval(0.5)) == 29.5)
        #expect(WatchFeedRules.liveRetryWake(route: .live, socketUsable: true, retryAt: .distantPast, now: now) == nil)
    }

    /// Over a run of reads a second apart, every try at once failing: one wake at once when the socket comes up, then
    /// the 30-second waits; the socket going down and up again within a wait brings no second one.
    @Test func aSocketComingUpGivesAtMostOneWakeAtOnce() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var retryAt = Date.distantPast, atOnce: [Int] = []
        for (second, up) in [false, false, true, true, true, false, true, true].enumerated() {
            let now = start.addingTimeInterval(TimeInterval(second))
            guard let wait = WatchFeedRules.liveRetryWake(route: .throughPhone, socketUsable: up, retryAt: retryAt, now: now) else { continue }
            if wait == 0 { atOnce.append(second); retryAt = WatchFeedRules.retryAfterFailedAttach(now: now) }
        }
        #expect(atOnce == [2])
    }

    /// The socket coming up while the phone path's read is out wakes the chat, once (`WatchFeedSocketWatch`): watched
    /// only after the read, as it was, that change went by unseen and the chat stayed on the phone path.
    @MainActor @Test func aSocketThatComesUpWhileThePhoneReadIsOutStillWakesTheChatOnce() async {
        let socket = FakeSocket(), wakes = Count()
        await WatchFeedSocketWatch.across({ socket.up }, read: {
            await Task.yield()
            socket.up = true
            await Task.yield()
            socket.up = false
            socket.up = true
        }, changed: { wakes.add() })
        #expect(wakes.value == 1)
        // Nothing changed during the read: no wake.
        let still = Count()
        await WatchFeedSocketWatch.across({ socket.up }, read: { await Task.yield() }, changed: { still.add() })
        #expect(still.value == 0)
    }

    @Test func aFirstReadAnnouncesNothing() {
        var gate = WatchFeedEventGate()
        #expect(gate.arrivals(items: [user("u"), reply("r")], cardIDs: ["c1"]).isEmpty)
    }

    @Test func aNewReplyIsAnnouncedOnceAndAReadOfRowsAlreadySeenIsQuiet() {
        var gate = WatchFeedEventGate()
        _ = gate.arrivals(items: [user("u")], cardIDs: [])
        #expect(gate.arrivals(items: [user("u"), reply("r")], cardIDs: []) == [.replyArrived(itemID: "r")])
        // A wrist raise reads the chat again: the same rows say nothing.
        #expect(gate.arrivals(items: [user("u"), reply("r")], cardIDs: []).isEmpty)
    }

    @Test func aReplyIsAnnouncedWhenItIsDoneNotWhileItIsWritten() {
        var gate = WatchFeedEventGate()
        _ = gate.arrivals(items: WatchFeedRules.settled([user("u")]), cardIDs: [])
        #expect(gate.arrivals(items: WatchFeedRules.settled([user("u"), reply("r", streaming: true)]), cardIDs: []).isEmpty)
        #expect(gate.arrivals(items: WatchFeedRules.settled([user("u"), reply("r")]), cardIDs: []) == [.replyArrived(itemID: "r")])
    }

    @Test func aSwitchOfPathOnlyLearnsWhatIsThere() {
        var gate = WatchFeedEventGate()
        _ = gate.arrivals(items: [user("live-u"), reply("live-r")], cardIDs: [])
        // The phone path's rows carry other ids for the same messages.
        gate.reseed()
        #expect(gate.arrivals(items: [user("hist-u"), reply("hist-r")], cardIDs: ["c1"]).isEmpty)
        #expect(gate.arrivals(items: [user("hist-u"), reply("hist-r"), reply("hist-r2")], cardIDs: ["c1"]) == [.replyArrived(itemID: "hist-r2")])
    }

    /// A live chat shows its cached transcript while it resumes, and the resume's history brought a row the cache didn't
    /// have, announced as an arrival: a buzz on opening, 2 of 6 opens in range B's gates (history row h-5-4, the read
    /// right after the first load). What is there when the load completes is learned, whichever read gets there first.
    @Test func aReadRightAfterTheFirstLoadAnnouncesNothing() {
        var gate = WatchFeedEventGate()
        // The open's read: the cached transcript, the chat still resuming.
        #expect(gate.arrivals(items: [user("u"), reply("h-5-3")], cardIDs: [], loaded: false).isEmpty)
        // A liveChanged read as the resume lands: the history, with a row the cache didn't have and a card waiting.
        #expect(gate.arrivals(items: [user("u"), reply("h-5-3"), reply("h-5-4")], cardIDs: ["c1"], loaded: true).isEmpty)
        // Read again straight after: quiet.
        #expect(gate.arrivals(items: [user("u"), reply("h-5-3"), reply("h-5-4")], cardIDs: ["c1"]).isEmpty)
        // A reply that comes after the load is announced.
        #expect(gate.arrivals(items: [user("u"), reply("h-5-3"), reply("h-5-4"), reply("r")], cardIDs: ["c1"]) == [.replyArrived(itemID: "r")])
    }

    @Test func aCardAndAFailedTurnAreAnnounced() {
        var gate = WatchFeedEventGate()
        _ = gate.arrivals(items: [user("u")], cardIDs: [])
        #expect(gate.arrivals(items: [user("u")], cardIDs: ["c1"]) == [.cardArrived(cardID: "c1")])
        let failed = TranscriptItem(id: "e", kind: .error(text: "Your request was not processed"))
        #expect(gate.arrivals(items: [user("u"), failed], cardIDs: ["c1"]) == [.turnFailed(itemID: "e")])
        let interrupted = reply("i", "Operation interrupted.")
        #expect(gate.arrivals(items: [user("u"), failed, interrupted], cardIDs: ["c1"]) == [.turnFailed(itemID: "i")])
    }

    @Test func oneReadWithSeveralArrivalsAnnouncesTheCardFirstThenAFailureThenTheNewestReply() {
        #expect(WatchFeedEventGate.strongest([.replyArrived(itemID: "a"), .cardArrived(cardID: "c"), .turnFailed(itemID: "e")]) == .cardArrived(cardID: "c"))
        #expect(WatchFeedEventGate.strongest([.replyArrived(itemID: "a"), .turnFailed(itemID: "e")]) == .turnFailed(itemID: "e"))
        #expect(WatchFeedEventGate.strongest([.replyArrived(itemID: "a"), .replyArrived(itemID: "b")]) == .replyArrived(itemID: "b"))
        #expect(WatchFeedEventGate.strongest([]) == nil)
    }

    // MARK: The iPhone's follow

    @Test func theFollowLastsTenMinutesFromTheLastRequestAndEndsWhenTheWatchLeaves() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var follow = WatchFollow()
        #expect(!follow.isActive(now: t0))
        follow.renew(now: t0)
        #expect(follow.isActive(now: t0.addingTimeInterval(599)))
        #expect(!follow.isActive(now: t0.addingTimeInterval(600)))
        // Each request renews it.
        follow.renew(now: t0.addingTimeInterval(500))
        #expect(follow.isActive(now: t0.addingTimeInterval(1_000)))
        follow.end()
        #expect(!follow.isActive(now: t0.addingTimeInterval(501)))
    }

    @Test func theIPhonePassesOnATurnStartingOrEndingAndItsCardsNotEveryUpdate() {
        #expect(WatchFeedRules.tellsWatch(.start))
        #expect(WatchFeedRules.tellsWatch(.end))
        #expect(WatchFeedRules.tellsWatch(.showCards))
        #expect(!WatchFeedRules.tellsWatch(.update))
        #expect(!WatchFeedRules.tellsWatch(.voiceMode))
    }

    // MARK: Problems and cards

    @Test func aFailureReadsAsItsKind() {
        #expect(WatchFeedProblem.from("Your request was not processed.").kind == .notProcessed)
        #expect(WatchFeedProblem.from("Your iPhone is not reachable.", phoneAway: true).kind == .phoneAway)
        #expect(WatchFeedProblem.from("could not open the chat").kind == .sendFailed)
    }

    @Test func anApprovalCrossesToTheWatchWhole() throws {
        let params: JSONValue = ["request_id": "req-1", "session_id": "s1", "command": "rm -rf build", "description": "Delete the build folder",
                                 "choices": ["once", "deny"], "pattern_key": "rm -rf", "tool_name": "terminal"]
        let card = PendingCard(id: "card-1", method: "approval", params: params)
        let message = WatchFeedRules.cardMessage(card)
        #expect(message["text"] as? String == "Delete the build folder")
        #expect(message["request"] as? String == "req-1")
        #expect(message["choices"] as? [String] == ["once", "deny"])
        #expect(message["scope"] as? String == "commands matching “rm -rf”")
        let back = try #require(WatchFeedRules.cards(from: [message]).first)
        #expect(back.id == "card-1")
        #expect(back.approval == card.approval)
        #expect(back.isNamed(by: "req-1"))
    }

    @Test func anOlderPhonesCardIsRebuiltFromItsWords() throws {
        let approval = try #require(WatchFeedRules.cards(from: [["id": "c", "method": "approval", "text": "Run tests", "request": "r9", "choices": ["once", "deny"]]]).first)
        #expect(approval.approval?.requestId == "r9")
        #expect(approval.approval?.description == "Run tests")
        #expect(approval.approval?.offeredChoices == ["once", "deny"])
        let question = try #require(WatchFeedRules.cards(from: [["id": "q", "method": "clarify", "text": "Which branch?"]]).first)
        #expect(question.clarify?.question == "Which branch?")
        #expect(WatchFeedRules.cards(from: [["method": "approval"]]).isEmpty)
    }
}

/// The Watch's socket, for `WatchFeedSocketWatch`.
@MainActor @Observable private final class FakeSocket { var up = false }

/// A wake count the watch's `changed` can add to from anywhere.
private final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
