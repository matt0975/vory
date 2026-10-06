import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Who a group chat shows working, read from the room's log: the gateway's own word when it
/// gives it (a turn opened for a member, a member named as typing), else its turn order (the
/// bots answer one after another, the ones a message mentions or all of them).
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
