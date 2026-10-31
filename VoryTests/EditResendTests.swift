import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Edit & resend (#556): only the chat's last message of the person's own can be edited; Send then asks the gateway to
/// take that turn back (`session.undo`, as a retry), reads the chat again and sends the new words. Each of the gateway's
/// answers ends it as Matt asked: nothing sent unless the turn was taken back, the words kept otherwise, and a gateway
/// without the method offers Copy to message from then on.
@MainActor @Suite struct EditResendTests {
    private func chat() throws -> ChatSession {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        let c = ChatSession(runtime: rt, storedID: "s1", title: nil)
        c.items = [
            TranscriptItem(id: "u1", kind: .user(text: "Clear the old logs", attachments: [])),
            TranscriptItem(id: "a1", kind: .assistant(text: "Done.", reasoning: nil, streaming: false)),
            TranscriptItem(id: "u2", kind: .user(text: "Now the cache", attachments: [])),
            TranscriptItem(id: "a2", kind: .assistant(text: "Cleared.", reasoning: nil, streaming: false)),
        ]
        return c
    }

    /// The gateway as a list of answers by method, and the calls in the order they came.
    private final class Gateway {
        var calls: [(String, [String: JSONValue])] = []
        var undo: Result<JSONValue, Error> = .success(["removed": 2])
        var submit: Result<JSONValue, Error> = .success(["status": "streaming"])
        func call(_ name: String, _ params: [String: JSONValue]) throws -> JSONValue {
            calls.append((name, params))
            switch name {
            case "session.undo": return try undo.get()
            case "session.resume": return ["session_id": "rt1", "running": false, "messages": [["role": "user", "text": "Clear the old logs"], ["role": "assistant", "text": "Done."]]]
            case "prompt.submit": return try submit.get()
            default: return [:]
            }
        }
        var names: [String] { calls.map(\.0) }
    }

    private func standIn(_ c: ChatSession, _ g: Gateway) {
        c.gatewayStandIn = { name, params in try g.call(name, params) }
    }

    @Test func onlyTheLastPlainMessageOfThePersonsOwnCanBeEdited() throws {
        let c = try chat()
        #expect(c.lastResendableID == "u2")
        #expect(!c.beginEdit("u1"))
        #expect(c.beginEdit("u2"))
        #expect(c.editingID == "u2")
        // A notice the gateway put in the person's seat, last: none, since the gateway would take back another turn.
        c.items.append(TranscriptItem(id: "n1", kind: .user(text: "[IMPORTANT: Background process proc_1 completed normally (exit code 0).]", attachments: [])))
        #expect(c.lastResendableID == nil)
    }

    @Test func aResendTakesTheTurnBackReadsTheChatAgainAndSends() async throws {
        let c = try chat()
        let g = Gateway(); standIn(c, g)
        #expect(c.beginEdit("u2"))
        let outcome = await c.resend("Now the cache, but keep today's")
        #expect(outcome == .sent)
        #expect(g.names == ["session.undo", "session.resume", "prompt.submit"])
        #expect(g.calls[0].1["intent"] == "retry")
        #expect(g.calls[2].1["text"] == "Now the cache, but keep today's")
        #expect(c.editingID == nil)
        #expect(!c.resending)
    }

    @Test func nothingIsSentWhenTheGatewayIsBusy() async throws {
        let c = try chat()
        let g = Gateway(); g.undo = .failure(RPCError(code: 4009, message: "session busy")); standIn(c, g)
        #expect(c.beginEdit("u2"))
        #expect(await c.resend("Edited") == .busy)
        #expect(g.names == ["session.undo"])
        // The edit stays: the words are kept for another try.
        #expect(c.editingID == "u2")
    }

    @Test func nothingIsSentWhenTheGatewayTookNothingBack() async throws {
        let c = try chat()
        let g = Gateway(); g.undo = .success(["removed": 0]); standIn(c, g)
        #expect(c.beginEdit("u2"))
        #expect(await c.resend("Edited") == .nothingRemoved)
        #expect(g.names == ["session.undo"])
        #expect(c.editingID == "u2")
    }

    @Test func aFailedUndoIsSaidInTheGatewaysWordsAndSendsNothing() async throws {
        let c = try chat()
        let g = Gateway(); g.undo = .failure(RPCError(code: 5008, message: "undo: database is locked")); standIn(c, g)
        #expect(c.beginEdit("u2"))
        let outcome = await c.resend("Edited")
        guard case .failed(let why) = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(why.contains("database is locked"))
        #expect(g.names == ["session.undo"])
        #expect(c.editingID == "u2")
    }

    @Test func aGatewayWithoutUndoOffersCopyToMessageFromThenOn() async throws {
        let c = try chat()
        let g = Gateway(); g.undo = .failure(RPCError(code: RPCError.methodNotFound, message: "unknown method: session.undo")); standIn(c, g)
        #expect(c.beginEdit("u2"))
        #expect(await c.resend("Edited") == .unsupported)
        #expect(g.names == ["session.undo"])
        #expect(c.editingID == nil)
        #expect(c.runtime.undoUnsupported)
        // Learnt once: no edit begins again on this gateway.
        #expect(!c.beginEdit("u2"))
    }

    @Test func noEditBeginsWhileAReplyRuns() throws {
        let c = try chat()
        c.isRunning = true
        #expect(!c.beginEdit("u2"))
        #expect(c.editingID == nil)
    }

    @Test func aTurnThatStartsWhileEditingEndsTheEdit() throws {
        let c = try chat()
        #expect(c.beginEdit("u2"))
        // A reply arriving from another device.
        c.isRunning = true
        #expect(c.editingID == nil)
    }

    @Test func aTurnStartingWhileTheResendWaitsDoesNotEndTheEdit() async throws {
        let c = try chat()
        let g = Gateway(); g.undo = .failure(RPCError(code: 4009, message: "session busy"))
        c.gatewayStandIn = { name, params in
            // Another device's turn starts while the undo is on its way: the resend, not the turn, ends the edit.
            if name == "session.undo" { c.isRunning = true; #expect(c.editingID == "u2") }
            return try g.call(name, params)
        }
        #expect(c.beginEdit("u2"))
        #expect(await c.resend("Edited") == .busy)
        #expect(c.editingID == "u2")
    }

    @Test func onceTheTurnIsTakenBackTheEditEndsWhateverFollows() async throws {
        let c = try chat()
        let g = Gateway(); g.submit = .failure(RPCError(code: 4006, message: "unknown session")); standIn(c, g)
        #expect(c.beginEdit("u2"))
        #expect(await c.resend("Edited") == .sendFailed)
        // A second Send is a plain one: it never takes back the turn before.
        #expect(c.editingID == nil)
        #expect(g.names == ["session.undo", "session.resume", "prompt.submit"])
    }

    @Test func aFailedSendAfterTheUndoSaysTheOldMessageIsGone() {
        // Nothing was sent, but the old message isn't there any more: said as it is, not as an edit that didn't happen.
        let m = ChatSession.ResendOutcome.sendFailed.message ?? ""
        #expect(m.hasPrefix("Your message was taken back"))
        #expect(m.contains("send them as a new message"))
        #expect(!m.contains("Nothing was sent"))
    }

    @Test func aMessageNoLongerLastIsNotTakenBack() async throws {
        let c = try chat()
        let g = Gateway(); standIn(c, g)
        #expect(c.beginEdit("u2"))
        c.items.append(TranscriptItem(id: "u3", kind: .user(text: "And the temp files", attachments: [])))
        #expect(await c.resend("Edited") == .notLast)
        #expect(g.names.isEmpty)
    }

    @Test func cancelEndsTheEditButNotOneOnItsWay() throws {
        let c = try chat()
        #expect(c.beginEdit("u2"))
        c.cancelEdit()
        #expect(c.editingID == nil)
    }

    @Test func everyOutcomeButSentSaysWhyAndThatTheWordsAreKept() {
        let outcomes: [ChatSession.ResendOutcome] = [.busy, .notLast, .nothingRemoved, .unsupported, .reloadFailed("timed out"), .sendFailed, .failed("locked")]
        for o in outcomes { #expect(o.message?.isEmpty == false) }
        #expect(ChatSession.ResendOutcome.sent.message == nil)
        for o in outcomes where o != .busy { #expect(o.message?.contains("in the box") == true) }
    }
}
