import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Who a group chat shows working, read from the room's log: the gateway's own word when it
/// gives it (a turn opened for a member, a member named as typing), else its turn order (the
/// bots answer one after another, the ones a message mentions or all of them, then in up to two
/// more rounds the ones another bot cited, in the order the gateway turns that list to).
@Suite struct GroupActivityTests {
    private let members = [RoomMember(memberId: "m1", profile: "default", handle: "default", displayName: "Default"),
                           RoomMember(memberId: "m2", profile: "work", handle: "work", displayName: "Work"),
                           RoomMember(memberId: "m3", profile: "ops", handle: "ops", displayName: "Ops")]
    private let start = 1_800_000_000.0
    private var now: Date { Date(timeIntervalSince1970: start + 30) }

    private func log(_ entries: [(String, RoomActor, JSONValue)]) -> [RoomEvent] {
        entries.enumerated().map { i, e in
            RoomEvent(roomId: "r", seq: i + 1, eventId: "e\(i + 1)", kind: e.0, actor: e.1, payload: e.2, createdAt: start + Double(i))
        }
    }
    private let user = RoomActor(kind: "user", id: "user")
    private let gateway = RoomActor(kind: "gateway", id: "gw")
    private func member(_ id: String) -> RoomActor { RoomActor(kind: "member", id: id) }
    private func names(_ events: [RoomEvent], at: Date? = nil) -> [String] {
        GroupActivity.working(members: members, events: events, now: at ?? now).compactMap(\.displayName)
    }

    @Test func turnsTheGatewayOpensShowEveryBotAtWorkUntilEachAnswers() {
        var entries: [(String, RoomActor, JSONValue)] = [
            ("message.user", user, ["text": "@all ship it?", "thread_id": "main"]),
            ("turn.started", gateway, ["member_id": "m2"]),
            ("turn.started", gateway, ["member_id": "m1"]),
        ]
        #expect(names(log(entries)) == ["Default", "Work"], "both at once, in the room's order")
        entries.append(("message.member", member("m1"), ["member_id": "m1", "text": "Notes are done."]))
        #expect(names(log(entries)) == ["Work"], "the one who answered is done")
        entries.append(("turn.settled", gateway, ["member_id": "m2", "passed": true]))
        #expect(names(log(entries)).isEmpty, "a passed turn ends too")
    }

    @Test func aGatewayThatFilesOnlyTheEndsOfTurnsIsReadByItsTurnOrder() {
        // A hosted room: nothing says a turn started, each turn's end is filed.
        var entries: [(String, RoomActor, JSONValue)] = [("message.user", user, ["text": "plan for today?", "thread_id": "main"])]
        #expect(names(log(entries)) == ["Default"], "no mention: every bot answers, the first in the room's order first")
        entries.append(("message.member", member("m1"), ["member_id": "m1", "text": "I'll do the notes."]))
        entries.append(("turn.settled", gateway, ["member_id": "m1", "passed": false]))
        #expect(names(log(entries)) == ["Work"])
        entries.append(("turn.settled", gateway, ["member_id": "m2", "passed": true]))
        #expect(names(log(entries)) == ["Ops"], "a bot that passed is done")
        entries.append(("message.member", member("m3"), ["member_id": "m3", "text": "@work can you check the build?"]))
        #expect(names(log(entries)) == ["Work"], "a bot another bot asked is next")
        entries.append(("message.member", member("m2"), ["member_id": "m2", "text": "Build is green."]))
        #expect(names(log(entries)).isEmpty)
        entries.append(("room.activity", gateway, ["status": "settled", "discussion_event_id": "e1"]))
        #expect(names(log(entries)).isEmpty, "the room settled")
    }

    /// A bot's turn in a hosted room as the gateway files it: its message (none when it passed),
    /// then the turn's end, both with the round they belong to.
    private func turn(_ id: String, round: Int, _ text: String?, _ entries: inout [(String, RoomActor, JSONValue)]) {
        var coordinates: [String: JSONValue] = ["member_id": .string(id), "round_index": .number(Double(round)),
                                                "discussion_event_id": "e1", "thread_id": "main"]
        if let text {
            entries.append(("message.member", member(id), .object(coordinates.merging(["text": .string(text)]) { $1 })))
        }
        // How far the bot read: the thread's newest message when its turn ended.
        let seen = (entries.lastIndex { $0.0.hasPrefix("message.") } ?? 0) + 1
        coordinates["passed"] = .bool(text == nil)
        coordinates["seen_through_seq"] = .number(Double(seen))
        entries.append(("turn.settled", gateway, .object(coordinates)))
    }

    @Test func botsCitedByAnotherBotTakeTurnsInTheGatewaysTurnedOrder() {
        // Every bot answers the first round, and Ops cites Default and Work. The gateway turns
        // the cited list one place for the next round, so Work goes before Default.
        var entries: [(String, RoomActor, JSONValue)] = [("message.user", user, ["text": "plan?", "thread_id": "main"])]
        turn("m1", round: 0, "I'll do the notes.", &entries)
        turn("m2", round: 0, "I'll do the build.", &entries)
        turn("m3", round: 0, "@default @work you are both wrong", &entries)
        #expect(names(log(entries)) == ["Work"], "the cited list turned by one: Work, then Default")
        // Work cites Ops: the list is Default and Ops now, turned to put Ops first.
        turn("m2", round: 1, "@ops what would you do?", &entries)
        #expect(names(log(entries)) == ["Ops"])
        turn("m3", round: 1, "Ship the notes first.", &entries)
        #expect(names(log(entries)) == ["Default"], "the one cited bot left")
        // Default cites Work, whose turn in this round is over: it goes in the next one.
        turn("m1", round: 1, "@work agreed?", &entries)
        #expect(names(log(entries)) == ["Work"])
        turn("m2", round: 2, "Agreed.", &entries)
        #expect(names(log(entries)).isEmpty, "nobody is waiting on an answer")
    }

    @Test func aRoundInWhichNoBotSpokeEndsTheDiscussion() {
        var entries: [(String, RoomActor, JSONValue)] = [("message.user", user, ["text": "@default @ops plan?", "thread_id": "main"])]
        turn("m1", round: 0, "@work can you check the build?", &entries)
        turn("m3", round: 0, "Fine by me.", &entries)
        #expect(names(log(entries)) == ["Work"])
        turn("m2", round: 1, nil, &entries)
        #expect(names(log(entries)).isEmpty, "Work passed, so nobody spoke in the round and the gateway settles it")
    }

    @Test func aTurnOfAnEarlierMessageThatEndsLateCountsForNothing() {
        // A second message takes over from the first; the first one's turn for Default ends after it.
        let events = log([("message.user", user, ["text": "plan?", "thread_id": "main"]),
                          ("message.user", user, ["text": "actually, status?", "thread_id": "main"]),
                          ("turn.cancelled", gateway, ["member_id": "m1", "round_index": 0, "discussion_event_id": "e1",
                                                       "thread_id": "main", "seen_through_seq": 1, "reason": "superseded"])])
        #expect(names(events) == ["Default"], "Default's turn for the new message is still to come")
    }

    @Test func aBotWhoseLateReplyIsTheNewestMessageIsPassedOverInTheFirstRound() {
        // Default's reply to the first message is filed just after the second one: it has read the
        // whole thread, so the gateway passes it over for the second message and Work goes first.
        var entries: [(String, RoomActor, JSONValue)] = [
            ("message.user", user, ["text": "plan?", "thread_id": "main"]),
            ("message.user", user, ["text": "actually, status?", "thread_id": "main"]),
            ("message.member", member("m1"), ["member_id": "m1", "text": "Notes are done.", "round_index": 0,
                                              "discussion_event_id": "e1", "thread_id": "main"]),
            ("turn.settled", gateway, ["member_id": "m1", "round_index": 0, "discussion_event_id": "e1",
                                       "thread_id": "main", "seen_through_seq": 1, "passed": false]),
        ]
        #expect(names(log(entries)) == ["Work"], "Default has read the thread already")
        // Work answers: that is new to Default, which has its turn now.
        entries.append(("message.member", member("m2"), ["member_id": "m2", "text": "Build is green.", "round_index": 0,
                                                         "discussion_event_id": "e2", "thread_id": "main"]))
        entries.append(("turn.settled", gateway, ["member_id": "m2", "round_index": 0, "discussion_event_id": "e2",
                                                  "thread_id": "main", "seen_through_seq": 5, "passed": false]))
        #expect(names(log(entries)) == ["Default"])
    }

    @Test func aReadingOfTheLogStillGoesStale() {
        // A page reads the log once per change and asks the reading each time it draws.
        let reading = GroupActivity.read(members: members, events: log([("message.user", user, ["text": "@work status?", "thread_id": "main"])]))
        #expect(reading.working(at: now).compactMap(\.displayName) == ["Work"])
        #expect(reading.working(at: Date(timeIntervalSince1970: start + GroupActivity.guessWindow + 5)).isEmpty)
    }

    @Test func aMentionAsksOnlyThatBot() {
        let events = log([("message.user", user, ["text": "@ops is the disk ok?", "thread_id": "main"])])
        #expect(names(events) == ["Ops"])
        #expect(GroupActivity.mentioned(in: "@everyone hi", members: members).count == 3)
        #expect(GroupActivity.mentioned(in: "no one", members: members).isEmpty)
    }

    @Test func aRoomThatNamesWhoIsTypingIsTakenAtItsWord() {
        // The older style: an activity line naming the member, then one that clears the room.
        let hermes = [RoomMember(memberId: "m1", profile: "default", handle: "hermes", displayName: "Hermes")]
        var entries: [(String, RoomActor, JSONValue)] = [("message.user", user, ["text": "hi", "thread_id": "main"]),
                                                        ("room.activity", RoomActor(kind: "system", id: "room"), ["status": "hermes is typing…"])]
        #expect(GroupActivity.working(members: hermes, events: log(entries), now: now).map(\.handle) == ["hermes"])
        entries.append(("room.activity", RoomActor(kind: "system", id: "room"), ["status": "settled"]))
        #expect(GroupActivity.working(members: hermes, events: log(entries), now: now).isEmpty)
    }

    @Test func nobodyIsWorkingAfterAStopOrLongAfterTheMessage() {
        let asked = log([("message.user", user, ["text": "plan?", "thread_id": "main"])])
        #expect(names(asked, at: Date(timeIntervalSince1970: start + GroupActivity.guessWindow + 5)).isEmpty, "the room's driver is more likely down")
        let stopped = log([("message.user", user, ["text": "plan?", "thread_id": "main"]),
                           ("turn.started", gateway, ["member_id": "m1"]),
                           ("room.stop_requested", gateway, ["cancel_id": "c1"])])
        #expect(names(stopped).isEmpty)
        #expect(names([]).isEmpty)
    }

    @Test func namesReadAsAList() {
        #expect(GroupActivity.names(Array(members.prefix(1))) == "Default")
        #expect(GroupActivity.names(Array(members.prefix(2))) == "Default and Work")
        #expect(GroupActivity.member("@WORK", in: members)?.memberId == "m2")
    }
}
