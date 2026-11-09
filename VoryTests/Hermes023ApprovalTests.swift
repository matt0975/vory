import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// #665, part A: on a socket served by Hermes's session authority (gateway.ready says `session_authority: true`;
/// Hermes v0.23.0 on a dashboard the gateway hosts), an approval or a single question comes as an `approval.request`
/// or `clarify.request` event, with its prompt_id and the turn's execution_generation, and is answered with
/// `approval.respond` or `clarify.respond` and exactly {session_id, execution_generation, prompt_id, choice|answer}.
/// The resume snapshot lists the open ones as `prompts`, and `approval.settled` / `clarify.settled` end them. On a
/// socket without the flag everything stays as it was.
@MainActor @Suite struct Hermes023ApprovalTests {
    private func runtime(authority: Bool) throws -> GatewayRuntime {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        var payload: [String: JSONValue] = ["change_events": true, "heartbeat": true]
        if authority { payload["session_authority"] = true }
        rt.handle(batch: [GatewayEvent(type: "gateway.ready", sessionID: "", payload: .object(payload))])
        return rt
    }

    /// The calls a chat made, by method, with their params.
    final class Calls {
        var sent: [(method: String, params: [String: JSONValue])] = []
        func last(_ method: String) -> [String: JSONValue]? { sent.last { $0.method == method }?.params }
    }

    /// A chat attached as `rt-a`, its calls recorded; `answer` says what each call gets back.
    private func chat(authority: Bool, answer: @escaping @MainActor (String, [String: JSONValue]) throws -> JSONValue = { _, _ in .object([:]) }) async throws -> (ChatSession, Calls) {
        let calls = Calls()
        let c = ChatSession(runtime: try runtime(authority: authority), storedID: nil, title: nil)
        c.gatewayStandIn = { method, params in
            calls.sent.append((method, params))
            if method == "session.create" { return .object(["session_id": "rt-a", "stored_session_id": "st-a", "execution_generation": 3]) }
            return try answer(method, params)
        }
        try await c.create()
        return (c, calls)
    }

    private func approvalEvent(_ id: String = "p-1", generation: Int = 3, choices: [String] = ["once", "session", "always", "deny"],
                               edit: Bool = false) -> GatewayEvent {
        var p: [String: JSONValue] = ["kind": "approval", "prompt_id": .string(id), "execution_generation": .number(Double(generation)),
                                      "command": "rm -rf /var/log/old", "description": "Delete the old log folder",
                                      "choices": .array(choices.map { .string($0) })]
        if edit { p["edit"] = .object(["path": "notes.md"]) }
        return GatewayEvent(type: "approval.request", sessionID: "rt-a", payload: .object(p))
    }

    private func line(_ chat: ChatSession, _ text: String) -> Bool {
        chat.items.contains { if case .system(let t, _) = $0.kind { return t == text }; return false }
    }

    @Test func anApprovalEventShowsItsCard() async throws {
        let (c, _) = try await chat(authority: true)
        c.handle(event: approvalEvent())
        let card = try #require(c.cards.first)
        #expect(c.cards.count == 1)
        #expect(card.method == "approval")
        #expect(card.approval?.requestId == "p-1")
        #expect(card.approval?.command == "rm -rf /var/log/old")
        #expect(card.isNamed(by: "p-1"))
    }

    @Test func anApprovalIsAnsweredWithItsFourKeys() async throws {
        let (c, calls) = try await chat(authority: true) { method, params in
            method == "approval.respond" ? .object(["status": "resolved", "prompt_id": params["prompt_id"] ?? .null]) : .object([:])
        }
        c.handle(event: approvalEvent())
        let card = try #require(c.cards.first)
        await c.respond(card: card, result: ["choice": "once"])
        let sent = try #require(calls.last("approval.respond"))
        #expect(Set(sent.keys) == ["session_id", "execution_generation", "prompt_id", "choice"])
        #expect(sent["session_id"] == .string("rt-a"))
        #expect(sent["execution_generation"] == .number(3))
        #expect(sent["prompt_id"] == .string("p-1"))
        #expect(sent["choice"] == .string("once"))
        #expect(c.cards.isEmpty)
    }

    @Test func anEditApprovalOffersOnlyOnceAndDeny() async throws {
        let (c, _) = try await chat(authority: true)
        c.handle(event: approvalEvent(choices: ["once", "deny"], edit: true))
        let card = try #require(c.cards.first)
        #expect(card.approval?.offeredChoices == ["once", "deny"])
    }

    @Test func aSettledApprovalTakesItsCardDown() async throws {
        let (c, _) = try await chat(authority: true)
        c.handle(event: approvalEvent())
        #expect(c.cards.count == 1)
        c.handle(event: GatewayEvent(type: "approval.settled", sessionID: "rt-a", payload: ["prompt_id": "p-1", "execution_generation": 3]))
        #expect(c.cards.isEmpty)
        #expect(line(c, "Answered on another device"))
    }

    @Test func aClarifyEventIsAnsweredWithClarifyRespond() async throws {
        let (c, calls) = try await chat(authority: true) { method, params in
            method == "clarify.respond" ? .object(["status": "resolved", "prompt_id": params["prompt_id"] ?? .null]) : .object([:])
        }
        c.handle(event: GatewayEvent(type: "clarify.request", sessionID: "rt-a", payload: [
            "kind": "clarify", "prompt_id": "q-1", "execution_generation": 3, "question": "Which day?",
            "choices": ["Thursday", "Friday"], "multi_select": false]))
        let card = try #require(c.cards.first)
        #expect(card.method == "clarify")
        #expect(card.clarify?.question == "Which day?")
        await c.respond(card: card, result: ["answer": "Thursday"])
        let sent = try #require(calls.last("clarify.respond"))
        #expect(Set(sent.keys) == ["session_id", "execution_generation", "prompt_id", "answer"])
        #expect(sent["prompt_id"] == .string("q-1"))
        #expect(sent["answer"] == .string("Thursday"))
    }

    @Test func theSnapshotsPromptsBringTheCardsBack() async throws {
        let (c, _) = try await chat(authority: true)
        await c.apply(snapshot: [
            "session_id": "rt-a", "stored_session_id": "st-a", "messages": [], "running": true, "execution_generation": 4,
            "prompts": [
                ["kind": "approval", "prompt_id": "p-9", "execution_generation": 4, "command": "make deploy", "description": "",
                 "choices": ["once", "deny"]],
                ["kind": "clarify", "prompt_id": "q-9", "execution_generation": 4, "question": "Which region?",
                 "choices": [], "multi_select": false],
            ]])
        #expect(Set(c.cards.map(\.id)) == ["p-9", "q-9"])
        #expect(c.cards.first { $0.id == "p-9" }?.approval?.requestId == "p-9")
    }

    @Test func aStaleGenerationLeavesTheCardDownWithALine() async throws {
        let (c, _) = try await chat(authority: true) { method, _ in
            if method == "approval.respond" { throw RPCError(code: 4001, message: "stale_generation", data: ["reason": "stale_generation"]) }
            return .object([:])
        }
        c.handle(event: approvalEvent())
        let card = try #require(c.cards.first)
        await c.respond(card: card, result: ["choice": "once"])
        #expect(c.cards.isEmpty)
        #expect(line(c, "This approval is no longer waiting"))
    }

    @Test func aReadyWithoutTheFlagGoesBackToTheLegacyWire() async throws {
        let (c, _) = try await chat(authority: true)
        c.handle(event: approvalEvent("p-1"))
        #expect(c.cards.count == 1)
        // The same runtime reconnected to a gateway without the session authority.
        c.runtime.handle(batch: [GatewayEvent(type: "gateway.ready", sessionID: "", payload: ["change_events": true])])
        c.handle(event: approvalEvent("p-2"))
        #expect(c.cards.map(\.id) == ["p-1"])
    }

    /// The guard: with no `session_authority`, an event is not a card, and a queue card from `approval.pending` is
    /// answered with {session_id, request_id, choice} as on 51. Green before and after the fix.
    @Test func aLegacySocketAnswersAsBefore() async throws {
        let (c, calls) = try await chat(authority: false) { method, _ in
            if method == "approval.pending" {
                return ["approvals": [["request_id": "r-1", "command": "ls -la", "description": "List", "choices": ["once", "deny"]]]]
            }
            return .object([:])
        }
        c.handle(event: approvalEvent("p-1"))
        #expect(c.cards.isEmpty)
        await c.pollPendingApprovals()
        let card = try #require(c.cards.first)
        #expect(card.viaApprovalRPC)
        await c.respond(card: card, result: ["choice": "once"])
        let sent = try #require(calls.last("approval.respond"))
        #expect(Set(sent.keys) == ["session_id", "request_id", "choice"])
        #expect(sent["request_id"] == .string("r-1"))
    }
}
