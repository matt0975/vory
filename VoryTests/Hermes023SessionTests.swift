import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// #666: the session calls on a socket served by Hermes's session authority (gateway.ready says `session_authority:
/// true`; Hermes v0.23.0 on a dashboard the gateway hosts). There `session.usage`, `session.title`, `session.undo`,
/// `session.close` and `session.workspace.move` answer -32601, and their ways are `session.stats`, `session.mutate`
/// (rename, rewind, workspace: a request_id, the session's revision and, for rewind, its execution generation) and
/// `session.detach`. A steer carries the running turn's execution_generation, and a plain "rejected" may have reached the
/// bot, so it isn't sent again. Most `session.info` frames are partial there, so they're merged, not taken whole. On a
/// socket without the flag everything stays as it was.
@MainActor @Suite struct Hermes023SessionTests {
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
        func all(_ method: String) -> [[String: JSONValue]] { sent.filter { $0.method == method }.map(\.params) }
        func last(_ method: String) -> [String: JSONValue]? { all(method).last }
    }

    /// A count a stand-in keeps between calls.
    final class Box { var n: Int; init(_ n: Int) { self.n = n } }

    static let unserved: Set<String> = ["session.usage", "session.title", "session.undo", "session.close", "session.workspace.move"]

    /// The counters `session.stats` answers in these tests, and the `Usage` Hermes's own `tui_usage` makes of them
    /// (gateway/session_usage.py at v0.23.0).
    static let stats: JSONValue = [
        "input_tokens": 17_900, "output_tokens": 420, "cache_read_tokens": 11_040, "cache_write_tokens": 6_860,
        "prompt_tokens": 17_900, "completion_tokens": 420, "total_tokens": 18_320, "reasoning_tokens": 0, "api_calls": 3,
        "last_prompt_tokens": 20_080, "context_tokens": 20_080, "context_length": 200_000, "context_source": "models.dev",
        "compression_count": 1, "avg_latency_s": 1.4, "tokens_per_s": 48.24, "last_turn_tokens": 420, "active_subagents": 0,
        "model": "gpt-x", "provider": "acme"]
    static let statsAsUsage = Usage(model: "gpt-x", input: 17_900, output: 420, reasoning: 0, total: 18_320, calls: 3,
                                    compressions: 1, contextUsed: 20_080, contextMax: 200_000, contextPercent: 10,
                                    contextEstimated: true, cacheHitPct: 62, avgTps: 48.2, activeSubagents: 0)

    /// A chat attached as `rt-a`, its calls recorded. On the authority wire the five calls it doesn't serve answer
    /// -32601, as v0.23.0's do; `answer` says what every other call gets back.
    private func chat(authority: Bool, items: [TranscriptItem] = [],
                      answer: @escaping @MainActor (String, [String: JSONValue]) throws -> JSONValue = { _, _ in .object([:]) }) async throws -> (ChatSession, Calls) {
        let calls = Calls()
        let c = ChatSession(runtime: try runtime(authority: authority), storedID: nil, title: nil)
        c.gatewayStandIn = { method, params in
            calls.sent.append((method, params))
            if method == "session.create" {
                return ["session_id": "rt-a", "stored_session_id": "st-a", "execution_generation": 3, "revision": 4,
                        "subscription_id": "sub-1", "messages": [], "running": false,
                        "info": ["model": "gpt-x", "cwd": "/srv/app", "branch": "main", "title": "Logs"]]
            }
            if authority, Self.unserved.contains(method) { throw RPCError(code: RPCError.methodNotFound, message: "unknown method: \(method)") }
            if method == "session.stats" { return Self.stats }
            return try answer(method, params)
        }
        try await c.create()
        if !items.isEmpty { c.items = items }
        return (c, calls)
    }

    private func info(_ c: ChatSession, generation: Int, revision: Int, running: Bool) {
        c.handle(event: GatewayEvent(type: "session.info", sessionID: "rt-a", payload: [
            "stored_session_id": "st-a", "pending": [], "running": .bool(running), "authority_epoch": 1,
            "desktop_protocol": "hermes-gateway-v1", "execution_generation": .number(Double(generation)),
            "revision": .number(Double(revision))]))
    }

    private func line(_ c: ChatSession, _ text: String) -> Bool {
        c.items.contains { if case .system(let t, _) = $0.kind { return t == text }; return false }
    }

    private static let mutateKeys: Set<String> = ["session_id", "request_id", "expected_revision", "operation", "payload"]

    /// Two turns of the person's own, each row with the id a snapshot gives it.
    private static let twoTurns = [
        TranscriptItem(id: "u1", kind: .user(text: "Clear the old logs", attachments: []), rowID: 5),
        TranscriptItem(id: "a1", kind: .assistant(text: "Done.", reasoning: nil, streaming: false), rowID: 6),
        TranscriptItem(id: "u2", kind: .user(text: "Now the cache", attachments: []), rowID: 7),
        TranscriptItem(id: "a2", kind: .assistant(text: "Cleared.", reasoning: nil, streaming: false), rowID: 8),
    ]

    private static let stillTwoTurns: JSONValue = ["session_id": "rt-a", "stored_session_id": "st-a", "running": false,
        "execution_generation": 3, "revision": 4, "subscription_id": "sub-2", "messages": [
            ["role": "user", "text": "Clear the old logs", "row_id": 5], ["role": "assistant", "text": "Done.", "row_id": 6],
            ["role": "user", "text": "Now the cache", "row_id": 7], ["role": "assistant", "text": "Cleared.", "row_id": 8]]]

    // MARK: Steer

    @Test func aSteerSendsTheRunningTurnsGeneration() async throws {
        let (c, calls) = try await chat(authority: true) { method, params in
            method == "session.steer" ? ["status": "queued", "text": params["text"] ?? .null, "execution_generation": 7, "authority_epoch": 1] : .object([:])
        }
        info(c, generation: 7, revision: 5, running: true)
        c.queue = [QueuedMessage(text: "and the tmp folder")]
        await c.steerQueued(c.queue[0].id)
        let sent = try #require(calls.last("session.steer"))
        #expect(Set(sent.keys) == ["session_id", "execution_generation", "text"])
        #expect(sent["execution_generation"] == .number(7))
        #expect(sent["text"] == .string("and the tmp folder"))
        guard case .steer(let text, let status)? = c.items.last?.kind else { Issue.record("no steer row"); return }
        #expect(text == "and the tmp folder" && status == "queued")
    }

    @Test func aSteerTheTurnNeverSawGoesBackToTheQueue() async throws {
        let (c, calls) = try await chat(authority: true) { method, params in
            method == "session.steer" ? ["status": "rejected", "text": params["text"] ?? .null, "execution_generation": 7,
                                         "authority_epoch": 1, "delivered": false] : .object([:])
        }
        info(c, generation: 7, revision: 5, running: true)
        c.queue = [QueuedMessage(text: "a"), QueuedMessage(text: "b")]
        await c.steerQueued(c.queue[0].id)
        #expect(calls.last("session.steer")?["execution_generation"] == .number(7))
        #expect(c.queue.map(\.text) == ["a", "b"])
    }

    @Test func aSteerThatMayHaveBeenDeliveredIsNotSentAgain() async throws {
        let (c, calls) = try await chat(authority: true) { method, params in
            method == "session.steer" ? ["status": "rejected", "text": params["text"] ?? .null, "execution_generation": 7, "authority_epoch": 1] : .object([:])
        }
        info(c, generation: 7, revision: 5, running: true)
        c.queue = [QueuedMessage(text: "a"), QueuedMessage(text: "b")]
        await c.steerQueued(c.queue[0].id)
        #expect(calls.last("session.steer")?["execution_generation"] == .number(7))
        #expect(c.queue.map(\.text) == ["b"])
        #expect(line(c, "This may not have reached the bot. It was sent as the turn ended."))
    }

    @Test func aSteerAfterTheTurnEndedWaitsForTheNextTurn() async throws {
        let (c, _) = try await chat(authority: true) { method, _ in
            if method == "session.steer" { throw RPCError(code: 4001, message: "stale_generation", data: ["reason": "stale_generation"]) }
            return .object([:])
        }
        info(c, generation: 7, revision: 5, running: true)
        c.queue = [QueuedMessage(text: "a")]
        await c.steerQueued(c.queue[0].id)
        #expect(c.queue.map(\.text) == ["a"])
        #expect(c.banner == nil)
    }

    // MARK: Usage

    @Test func theUsageIsReadWithSessionStatsAndShownAsTheTickShowsIt() async throws {
        let (c, calls) = try await chat(authority: true)
        #expect(calls.last("session.stats")?["session_id"] == .string("rt-a"))
        #expect(c.usage == Self.statsAsUsage)
    }

    // MARK: Rename

    @Test func aRenameIsAMutateWithItsFences() async throws {
        let revision = Box(9)
        let (c, calls) = try await chat(authority: true) { method, params in
            guard method == "session.mutate" else { return .object([:]) }
            revision.n += 1
            return ["session_id": "rt-a", "operation": "rename", "revision": .number(Double(revision.n)),
                    "title": params["payload"]?["title"] ?? .null]
        }
        await c.rename("Disk cleanup")
        let first = try #require(calls.all("session.mutate").first)
        #expect(Set(first.keys) == Self.mutateKeys)
        #expect(first["session_id"] == .string("rt-a"))
        #expect(first["operation"] == .string("rename"))
        #expect(first["payload"] == ["title": "Disk cleanup"])
        #expect(first["expected_revision"] == .number(4))
        #expect(first["request_id"]?.stringValue?.isEmpty == false)
        #expect(c.title == "Disk cleanup")
        // The answer's revision is the one the next edit presents.
        await c.rename("Disk cleanup on the log host")
        #expect(calls.all("session.mutate").last?["expected_revision"] == .number(10))
        #expect(calls.all("session.mutate").last?["request_id"] != first["request_id"])
    }

    @Test func aRenameOnAStaleRevisionIsSentOnceMoreWithTheSameRequestID() async throws {
        let tries = Box(0)
        let (c, calls) = try await chat(authority: true) { method, params in
            guard method == "session.mutate" else { return .object([:]) }
            tries.n += 1
            if tries.n == 1 {
                throw RPCError(code: 4001, message: "revision_conflict",
                               data: ["reason": "revision_conflict", "revision": 12, "execution_generation": 3])
            }
            return ["session_id": "rt-a", "operation": "rename", "revision": 13, "title": params["payload"]?["title"] ?? .null]
        }
        await c.rename("Disk cleanup")
        let sent = calls.all("session.mutate")
        #expect(sent.count == 2)
        #expect(sent.last?["expected_revision"] == .number(12))
        #expect(sent.first?["request_id"] == sent.last?["request_id"])
        #expect(c.title == "Disk cleanup")
    }

    @Test func aRenameThatFailsSaysSo() async throws {
        let (c, calls) = try await chat(authority: true) { method, _ in
            if method == "session.mutate" { throw RPCError(code: 4001, message: "permission_denied", data: ["reason": "permission_denied"]) }
            return .object([:])
        }
        await c.rename("Disk cleanup")
        #expect(calls.all("session.mutate").count == 1)
        #expect(c.title == "Logs")
        #expect(line(c, "The chat couldn't be renamed."))
    }

    // MARK: Edit & resend

    @Test func anEditRewindsToTheMessagesRow() async throws {
        let (c, calls) = try await chat(authority: true, items: Self.twoTurns) { method, _ in
            switch method {
            case "session.mutate":
                return ["session_id": "rt-a", "operation": "rewind", "revision": 5, "rewound_count": 2,
                        "target_message": ["role": "user", "content": "Now the cache", "row_id": 7], "new_head_id": 6]
            case "session.resume":
                return ["session_id": "rt-a", "stored_session_id": "st-a", "running": false, "execution_generation": 4, "revision": 5,
                        "subscription_id": "sub-2", "messages": [["role": "user", "text": "Clear the old logs", "row_id": 5],
                                                                 ["role": "assistant", "text": "Done.", "row_id": 6]]]
            case "prompt.submit": return ["status": "streaming"]
            default: return .object([:])
            }
        }
        info(c, generation: 3, revision: 4, running: false)
        #expect(c.beginEdit("u2"))
        #expect(await c.resend("Now the cache, but keep today's") == .sent)
        let sent = try #require(calls.last("session.mutate"))
        #expect(Set(sent.keys) == Self.mutateKeys.union(["expected_generation"]))
        #expect(sent["operation"] == .string("rewind"))
        #expect(sent["payload"] == ["target_message_id": 7])
        #expect(sent["expected_revision"] == .number(4))
        #expect(sent["expected_generation"] == .number(3))
        #expect(calls.all("session.undo").isEmpty)
        #expect(calls.last("prompt.submit")?["text"] == .string("Now the cache, but keep today's"))
    }

    @Test func anEditOfAMessageWithNoRowYetReadsTheChatFirst() async throws {
        // Sent from here in this session: no row id until the chat is read again.
        let fresh = [Self.twoTurns[0], Self.twoTurns[1],
                     TranscriptItem(id: "u2", kind: .user(text: "Now the cache", attachments: [])),
                     TranscriptItem(id: "a2", kind: .assistant(text: "Cleared.", reasoning: nil, streaming: false))]
        let resumes = Box(0)
        let (c, calls) = try await chat(authority: true, items: fresh) { method, _ in
            switch method {
            case "session.resume":
                resumes.n += 1
                return resumes.n == 1 ? Self.stillTwoTurns : ["session_id": "rt-a", "stored_session_id": "st-a", "running": false,
                    "execution_generation": 4, "revision": 5, "subscription_id": "sub-3", "messages": [
                        ["role": "user", "text": "Clear the old logs", "row_id": 5], ["role": "assistant", "text": "Done.", "row_id": 6]]]
            case "session.mutate":
                return ["session_id": "rt-a", "operation": "rewind", "revision": 5, "rewound_count": 2]
            case "prompt.submit": return ["status": "streaming"]
            default: return .object([:])
            }
        }
        #expect(c.beginEdit("u2"))
        #expect(await c.resend("Now the cache, but keep today's") == .sent)
        let order = calls.sent.map(\.method).filter { ["session.resume", "session.mutate"].contains($0) }
        #expect(order.first == "session.resume")
        #expect(calls.last("session.mutate")?["payload"] == ["target_message_id": 7])
    }

    @Test func anEditOnAChatThatMovedOnIsNotLast() async throws {
        let (c, calls) = try await chat(authority: true, items: Self.twoTurns) { method, _ in
            switch method {
            case "session.mutate":
                throw RPCError(code: 4001, message: "revision_conflict",
                               data: ["reason": "revision_conflict", "revision": 6, "execution_generation": 4])
            case "session.resume":
                // Another device sent a message meanwhile: the one being edited is no longer the last.
                return ["session_id": "rt-a", "stored_session_id": "st-a", "running": false, "execution_generation": 4, "revision": 6,
                        "subscription_id": "sub-2", "messages": [
                            ["role": "user", "text": "Clear the old logs", "row_id": 5], ["role": "assistant", "text": "Done.", "row_id": 6],
                            ["role": "user", "text": "Now the cache", "row_id": 7], ["role": "assistant", "text": "Cleared.", "row_id": 8],
                            ["role": "user", "text": "And the tmp folder", "row_id": 9], ["role": "assistant", "text": "Done too.", "row_id": 10]]]
            default: return .object([:])
            }
        }
        info(c, generation: 3, revision: 4, running: false)
        #expect(c.beginEdit("u2"))
        #expect(await c.resend("Now the cache, but keep today's") == .notLast)
        #expect(calls.all("session.mutate").count == 1)
        #expect(calls.all("prompt.submit").isEmpty)
    }

    @Test func anEditWhileATurnRunsIsBusy() async throws {
        let (c, calls) = try await chat(authority: true, items: Self.twoTurns) { method, _ in
            if method == "session.mutate" { throw RPCError(code: 4001, message: "session_busy", data: ["reason": "session_busy"]) }
            return .object([:])
        }
        info(c, generation: 3, revision: 4, running: false)
        #expect(c.beginEdit("u2"))
        #expect(await c.resend("Edited") == .busy)
        #expect(calls.all("session.mutate").count == 1)
        #expect(c.editingID == "u2")
    }

    // MARK: Close

    @Test func closingDetachesWithTheSubscription() async throws {
        let (c, calls) = try await chat(authority: true) { method, params in
            method == "session.detach" ? ["session_id": params["session_id"] ?? .null, "subscription_id": params["subscription_id"] ?? .null, "detached": true] : .object([:])
        }
        c.runtime.closeChat(c)
        for _ in 0..<100 where calls.last("session.detach") == nil { try await Task.sleep(for: .milliseconds(10)) }
        let sent = try #require(calls.last("session.detach"))
        #expect(sent == ["session_id": "rt-a", "subscription_id": "sub-1", "end_reason": "tui_close"])
    }

    // MARK: session.info

    @Test func aPartialSessionInfoKeepsTheChatsModelAndFolder() async throws {
        let (c, _) = try await chat(authority: true)
        #expect(c.info?.model == "gpt-x")
        info(c, generation: 4, revision: 5, running: true)
        #expect(c.info?.model == "gpt-x")
        #expect(c.info?.cwd == "/srv/app")
        #expect(c.info?.branch == "main")
        #expect(c.info?.running == true)
        #expect(c.isRunning)
    }

    @Test func aSessionInfoMovesTheGenerationAndTheRevision() async throws {
        let (c, calls) = try await chat(authority: true) { method, params in
            switch method {
            case "session.mutate": return ["session_id": "rt-a", "operation": "rename", "revision": 10, "title": params["payload"]?["title"] ?? .null]
            case "session.steer": return ["status": "queued", "text": params["text"] ?? .null, "execution_generation": 9, "authority_epoch": 1]
            default: return .object([:])
            }
        }
        info(c, generation: 9, revision: 8, running: true)
        await c.rename("Disk cleanup")
        #expect(calls.last("session.mutate")?["expected_revision"] == .number(8))
        c.queue = [QueuedMessage(text: "a")]
        await c.steerQueued(c.queue[0].id)
        #expect(calls.last("session.steer")?["execution_generation"] == .number(9))
    }

    @Test func aResumeAfterAGatewayRestartIsBelievedWithLowerNumbers() async throws {
        let (c, calls) = try await chat(authority: true) { method, params in
            switch method {
            case "session.resume":
                // The gateway restarted: a new execution count, a new revision, a new subscription, nothing waiting.
                return ["session_id": "rt-a", "stored_session_id": "st-a", "running": true, "execution_generation": 2, "revision": 1,
                        "subscription_id": "sub-9", "messages": [], "prompts": []]
            case "session.steer":
                if params["execution_generation"] != .number(2) { throw RPCError(code: 4001, message: "stale_generation", data: ["reason": "stale_generation"]) }
                return ["status": "queued", "text": params["text"] ?? .null, "execution_generation": 2, "authority_epoch": 2]
            case "session.mutate":
                if params["expected_revision"] != .number(1) {
                    throw RPCError(code: 4001, message: "revision_conflict", data: ["reason": "revision_conflict", "revision": 1, "execution_generation": 2])
                }
                return ["session_id": "rt-a", "operation": "rename", "revision": 2, "title": params["payload"]?["title"] ?? .null]
            default: return .object([:])
            }
        }
        info(c, generation: 9, revision: 12, running: true)
        c.handle(event: GatewayEvent(type: "approval.request", sessionID: "rt-a", payload: [
            "kind": "approval", "prompt_id": "p-9", "execution_generation": 9, "command": "make deploy", "description": "",
            "choices": ["once", "deny"]]))
        #expect(c.cards.count == 1)
        try await c.resume()
        #expect(c.executionGeneration == 2)
        #expect(c.revision == 1)
        #expect(c.subscriptionID == "sub-9")
        // The card of the gone execution can't be answered any more; nothing about it was answered here.
        #expect(c.cards.isEmpty)
        c.isRunning = true
        c.queue = [QueuedMessage(text: "and the tmp folder")]
        await c.steerQueued(c.queue[0].id)
        #expect(calls.last("session.steer")?["execution_generation"] == .number(2))
        #expect(c.queue.isEmpty)
        await c.rename("Disk cleanup")
        #expect(calls.all("session.mutate").count == 1)
        #expect(calls.last("session.mutate")?["expected_revision"] == .number(1))
        #expect(c.title == "Disk cleanup")
    }

    // MARK: The legacy wire (the guards: green before and after)

    @Test func theLegacyWireSendsWhatItSentBefore() async throws {
        let (c, calls) = try await chat(authority: false, items: Self.twoTurns) { method, params in
            switch method {
            case "session.steer": return ["status": "queued", "text": params["text"] ?? .null]
            case "session.title": return ["title": params["title"] ?? .null]
            case "session.undo": return ["removed": 2]
            case "session.resume": return Self.stillTwoTurns
            case "prompt.submit": return ["status": "streaming"]
            default: return .object([:])
            }
        }
        #expect(calls.last("session.usage") == ["session_id": "rt-a"])
        #expect(calls.all("session.stats").isEmpty)
        c.isRunning = true
        c.queue = [QueuedMessage(text: "a")]
        await c.steerQueued(c.queue[0].id)
        #expect(calls.last("session.steer") == ["session_id": "rt-a", "text": "a"])
        c.isRunning = false
        await c.rename("Disk cleanup")
        #expect(calls.last("session.title") == ["session_id": "rt-a", "title": "Disk cleanup"])
        c.items = Self.twoTurns
        #expect(c.beginEdit("u2"))
        _ = await c.resend("Edited")
        #expect(calls.last("session.undo") == ["session_id": "rt-a", "intent": "retry"])
        #expect(calls.all("session.mutate").isEmpty)
    }

    // MARK: The turn's input id (#682)

    /// The keys the session authority admits on a prompt.submit (gateway/session_controls.py submission(), the same in
    /// v0.22.7 and v0.23.0), which also needs a non-empty submission_id or input_id. Anything else is 4001
    /// "invalid_params" with no fields.
    private static let submissionKeys: Set<String> = [
        "session_id", "text", "submission_id", "input_id", "queued", "attachments", "finite", "unattended", "surface",
        "voice_context", "interrupted", "voice_turn", "display_kind", "title_preview", "turn_author", "api_text",
        "model_override", "clarify_batch"]

    private static func admitted(_ params: [String: JSONValue]) -> Bool {
        guard Set(params.keys).isSubset(of: submissionKeys) else { return false }
        return [params["submission_id"], params["input_id"]].contains { !($0?.stringValue ?? "").isEmpty }
    }

    /// prompt.submit as the authority answers it, and an Edit & resend's rewind and the chat read after it.
    private static func authoritySubmits(_ method: String, _ params: [String: JSONValue]) throws -> JSONValue {
        switch method {
        case "prompt.submit":
            guard admitted(params) else { throw RPCError(code: 4001, message: "invalid_params", data: ["reason": "invalid_params"]) }
            return ["status": "streaming"]
        case "session.mutate":
            return ["session_id": "rt-a", "operation": "rewind", "revision": 5, "rewound_count": 2, "new_head_id": 6]
        case "session.resume":
            return ["session_id": "rt-a", "stored_session_id": "st-a", "running": false, "execution_generation": 4, "revision": 5,
                    "subscription_id": "sub-2", "messages": [["role": "user", "text": "Clear the old logs", "row_id": 5],
                                                             ["role": "assistant", "text": "Done.", "row_id": 6]]]
        default: return .object([:])
        }
    }

    private static func isInputID(_ v: JSONValue?) -> Bool {
        guard let s = v?.stringValue else { return false }
        return s.count == 32 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private func errorRows(_ c: ChatSession) -> Int {
        c.items.filter { if case .error = $0.kind { return true }; return false }.count
    }

    @Test func aPlainSendIsAdmittedOnTheAuthorityWire() async throws {
        let (c, calls) = try await chat(authority: true, answer: Self.authoritySubmits)
        _ = await c.send("Clean up the log host")
        #expect(calls.all("prompt.submit").count == 1)
        #expect(errorRows(c) == 0, "the send was refused")
        #expect(Self.isInputID(calls.last("prompt.submit")?["input_id"]))
    }

    @Test func eachTurnHasItsOwnInputID() async throws {
        let (c, calls) = try await chat(authority: true, answer: Self.authoritySubmits)
        _ = await c.send("First")
        c.isRunning = false
        _ = await c.send("Second")
        c.isRunning = false
        c.items = Self.twoTurns
        info(c, generation: 3, revision: 4, running: false)
        #expect(c.beginEdit("u2"))
        #expect(await c.resend("Now the cache, but keep today's") == .sent)
        let ids = calls.all("prompt.submit").map { $0["input_id"] }
        #expect(ids.count == 3)
        #expect(ids.allSatisfy { Self.isInputID($0) })
        #expect(Set(ids.compactMap { $0?.stringValue }).count == 3, "a turn reused another's input id")
    }

    @Test func aVoiceTurnCarriesAnInputIDBesideItsVoiceKeys() async throws {
        let (c, calls) = try await chat(authority: true, answer: Self.authoritySubmits)
        _ = await c.send("Yes", voice: VoiceTurn(context: "Should I clear the cache?", interrupted: true))
        let p = try #require(calls.last("prompt.submit"))
        #expect(p["surface"] == .string(VoiceTurn.surface) && p["interrupted"] == true)
        #expect(Self.isInputID(p["input_id"]))
        #expect(errorRows(c) == 0, "the spoken turn was refused")
    }

    /// The guard, green before and after: the legacy wire's prompt.submit names no turn. Hermes's legacy handler refuses
    /// a key its contract doesn't declare (tui_gateway/contracts/base.py extra="forbid"), and v0.23.0's
    /// (contracts/prompt_voice.py) declares neither id.
    @Test func onTheLegacyWireASendNamesNoTurn() async throws {
        let (c, calls) = try await chat(authority: false, answer: { method, _ in method == "prompt.submit" ? ["status": "streaming"] : .object([:]) })
        _ = await c.send("Clean up the log host")
        c.isRunning = false
        _ = await c.send("Yes", voice: VoiceTurn(context: "Should I clear the cache?", interrupted: true))
        let sent = calls.all("prompt.submit")
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0["input_id"] == nil && $0["submission_id"] == nil })
        #expect(errorRows(c) == 0)
    }

    /// The authority admits every message to its own queue and answers "queued" (with its admission_id) even when the
    /// turn starts at once: there the turn's own events say what it's doing, not "Queued on the gateway".
    @Test func anAdmittedMessageIsNotShownAsQueuedOnTheAuthorityWire() async throws {
        let (c, calls) = try await chat(authority: true, answer: { method, _ in
            method == "prompt.submit" ? ["admission_id": "adm-1", "status": "queued"] : .object([:])
        })
        _ = await c.send("Clean up the log host")
        #expect(calls.all("prompt.submit").count == 1)
        #expect(c.lastSubmitStatus == "queued")
        #expect(c.statusLine != "Queued on the gateway")
    }

    /// The guard, green before and after: on the legacy wire "queued" means the message waits behind a running turn.
    @Test func onTheLegacyWireAQueuedMessageSaysSo() async throws {
        let (c, _) = try await chat(authority: false, answer: { method, _ in method == "prompt.submit" ? ["status": "queued"] : .object([:]) })
        _ = await c.send("Clean up the log host")
        #expect(c.lastSubmitStatus == "queued")
        #expect(c.statusLine == "Queued on the gateway")
    }

    // MARK: Stop (#683)

    /// The authority's interrupt names the running turn by its execution (gateway/session_authority.py interrupt()):
    /// without it, or with an older one, it's a bare stale_generation and the turn runs on.
    @Test func aStopNamesTheRunningTurnsExecution() async throws {
        let (c, calls) = try await chat(authority: true)
        info(c, generation: 7, revision: 5, running: true)
        c.isRunning = true
        await c.stop()
        #expect(calls.last("session.interrupt") == ["session_id": "rt-a", "execution_generation": 7])
        #expect(c.banner == nil)
    }

    @Test func aStopTheAuthorityRefusesIsSaid() async throws {
        let (c, _) = try await chat(authority: true, answer: { method, _ in
            if method == "session.interrupt" { throw RPCError(code: 4001, message: "stale_generation", data: ["reason": "stale_generation"]) }
            return .object([:])
        })
        info(c, generation: 7, revision: 5, running: true)
        c.isRunning = true
        await c.stop()
        #expect(c.banner == "The reply couldn't be stopped. Try Stop again.")
        #expect(c.interruptCause == nil)
    }

    /// A refusal that is a bare code is said without it, in plain words; the code goes to the log.
    @Test func aStopRefusedWithABareCodeSaysSoInPlainWords() async throws {
        let (c, _) = try await chat(authority: true, answer: { method, _ in
            if method == "session.interrupt" { throw RPCError(code: 4001, message: "permission_denied", data: ["reason": "permission_denied"]) }
            return .object([:])
        })
        info(c, generation: 7, revision: 5, running: true)
        c.isRunning = true
        await c.stop()
        #expect(c.banner == "The reply couldn't be stopped.")
        #expect(c.interruptCause == nil)
    }

    @Test func onTheLegacyWireAStopTheGatewayRefusesIsSaid() async throws {
        let (c, _) = try await chat(authority: false, answer: { method, _ in
            if method == "session.interrupt" { throw RPCError(code: 4006, message: "unknown session") }
            return .object([:])
        })
        c.isRunning = true
        await c.stop()
        #expect(c.banner == "The reply couldn't be stopped: unknown session")
        #expect(c.interruptCause == nil)
    }

    /// The guard, green before and after: the legacy wire's Stop names no execution, and one taken says nothing.
    @Test func onTheLegacyWireAStopNamesNoExecution() async throws {
        let (c, calls) = try await chat(authority: false)
        c.isRunning = true
        await c.stop()
        #expect(calls.last("session.interrupt") == ["session_id": "rt-a"])
        #expect(c.banner == nil)
        #expect(c.interruptCause == .stopped)
    }

    /// A refused Stop's line goes once a later Stop is taken: "couldn't be stopped" stayed on screen after the reply had
    /// stopped (#684).
    @Test func aStopTakenAfterARefusedOneClearsTheRefusal() async throws {
        let refusals = Box(1)
        let (c, _) = try await chat(authority: true, answer: { method, _ in
            if method == "session.interrupt", refusals.n > 0 {
                refusals.n -= 1
                throw RPCError(code: 4001, message: "stale_generation", data: ["reason": "stale_generation"])
            }
            return .object([:])
        })
        info(c, generation: 7, revision: 5, running: true)
        c.isRunning = true
        await c.stop()
        #expect(c.banner == "The reply couldn't be stopped. Try Stop again.")
        info(c, generation: 8, revision: 6, running: true)
        await c.stop()
        #expect(c.banner == nil)
        #expect(c.interruptCause == .stopped)
    }

    /// A refused Stop's line goes when the turn ends on its own, with no Stop after it (#684).
    @Test func aRefusedStopsLineGoesWhenTheTurnEnds() async throws {
        let (c, _) = try await chat(authority: true, answer: { method, _ in
            if method == "session.interrupt" { throw RPCError(code: 4001, message: "stale_generation", data: ["reason": "stale_generation"]) }
            return .object([:])
        })
        info(c, generation: 7, revision: 5, running: true)
        c.isRunning = true
        await c.stop()
        #expect(c.banner == "The reply couldn't be stopped. Try Stop again.")
        c.isRunning = false
        #expect(c.banner == nil)
    }

    /// The guard: another banner up when the turn ends stays, a refused Stop before it or not.
    @Test func anotherBannerStaysWhenTheTurnEnds() async throws {
        let (c, _) = try await chat(authority: true, answer: { method, _ in
            if method == "session.interrupt" { throw RPCError(code: 4001, message: "stale_generation", data: ["reason": "stale_generation"]) }
            return .object([:])
        })
        info(c, generation: 7, revision: 5, running: true)
        c.isRunning = true
        await c.stop()
        c.banner = "Reconnecting…"
        c.isRunning = false
        #expect(c.banner == "Reconnecting…")
    }

    /// The guard, green before and after: a Stop taken clears only a Stop's own refusal, never another banner.
    @Test func aStopTakenLeavesAnotherBanner() async throws {
        let (c, _) = try await chat(authority: true)
        info(c, generation: 7, revision: 5, running: true)
        c.isRunning = true
        c.banner = "Reconnecting…"
        await c.stop()
        #expect(c.banner == "Reconnecting…")
    }

    // MARK: The Watch's Stop through this iPhone (#684)

    #if os(iOS)
    /// The Watch hears what the gateway said to its Stop. One refused because the reply moved on is answered with the
    /// words that ask for Stop again, where the answer was "ok" whatever happened.
    @Test func aStopFromTheWatchRefusedAsStaleIsAnsweredWithTryAgain() async throws {
        let (c, _) = try await chat(authority: true, answer: { method, _ in
            if method == "session.interrupt" { throw RPCError(code: 4001, message: "stale_generation", data: ["reason": "stale_generation"]) }
            return .object([:])
        })
        info(c, generation: 7, revision: 5, running: true)
        c.isRunning = true
        let answer = await WatchSync.stopAnswer(c)
        #expect(answer["ok"] as? Bool == false)
        #expect(answer["error"] as? String == "The reply couldn't be stopped. Try Stop again.")
    }

    @Test func aStopFromTheWatchRefusedWithABareCodeIsAnsweredInPlainWords() async throws {
        let (c, _) = try await chat(authority: true, answer: { method, _ in
            if method == "session.interrupt" { throw RPCError(code: 4001, message: "permission_denied", data: ["reason": "permission_denied"]) }
            return .object([:])
        })
        info(c, generation: 7, revision: 5, running: true)
        c.isRunning = true
        let answer = await WatchSync.stopAnswer(c)
        #expect(answer["ok"] as? Bool == false)
        #expect(answer["error"] as? String == "The reply couldn't be stopped.")
    }

    @Test func aStopFromTheWatchRefusedInWordsIsAnsweredWithThem() async throws {
        let (c, _) = try await chat(authority: false, answer: { method, _ in
            if method == "session.interrupt" { throw RPCError(code: 4006, message: "unknown session") }
            return .object([:])
        })
        c.isRunning = true
        let answer = await WatchSync.stopAnswer(c)
        #expect(answer["ok"] as? Bool == false)
        #expect(answer["error"] as? String == "The reply couldn't be stopped: unknown session")
    }

    /// The guard, green before and after: a Stop the gateway takes is answered "ok", with no error.
    @Test func aStopFromTheWatchTakenIsAnsweredOK() async throws {
        let (c, _) = try await chat(authority: true)
        info(c, generation: 7, revision: 5, running: true)
        c.isRunning = true
        let answer = await WatchSync.stopAnswer(c)
        #expect(answer["ok"] as? Bool == true)
        #expect(answer["error"] == nil)
    }
    #endif

    // MARK: The tool line

    private func toolStarts(_ c: ChatSession, _ id: String, _ name: String) {
        c.handle(event: GatewayEvent(type: "tool.start", sessionID: "rt-a", payload: ["tool_id": .string(id), "name": .string(name)]))
    }

    private func approvalAsked(_ c: ChatSession) {
        c.handle(event: GatewayEvent(type: "approval.request", sessionID: "rt-a", payload: [
            "kind": "approval", "prompt_id": "p-1", "execution_generation": 3, "command": "rm -rf /var/log/old",
            "description": "Delete the old log folder", "choices": ["once", "deny"]]))
    }

    @Test func anApprovalTakesTheOpenToolsName() async throws {
        let (c, _) = try await chat(authority: true)
        toolStarts(c, "t-1", "terminal")
        approvalAsked(c)
        let card = try #require(c.cards.first)
        #expect(card.approval?.toolName == "terminal")
    }

    @Test func anApprovalWithTwoOpenToolsHasNoToolLine() async throws {
        let (c, _) = try await chat(authority: true)
        toolStarts(c, "t-1", "terminal")
        toolStarts(c, "t-2", "execute_code")
        approvalAsked(c)
        let card = try #require(c.cards.first)
        #expect(card.approval?.toolName == nil)
    }

    @Test func aToolLeftRunningByAnEarlierTurnDoesNotCount() async throws {
        let (c, _) = try await chat(authority: true)
        c.items.append(TranscriptItem(id: "u1", kind: .user(text: "Clean the old logs", attachments: [])))
        // Its turn ended without its completion (an interrupt, a dropped socket): the row stays running.
        toolStarts(c, "t-old", "execute_code")
        c.items.append(TranscriptItem(id: "u2", kind: .user(text: "Now the cache", attachments: [])))
        toolStarts(c, "t-new", "terminal")
        approvalAsked(c)
        let card = try #require(c.cards.first)
        #expect(card.approval?.toolName == "terminal")
    }

    @Test func aLegacySessionInfoStillReplacesTheInfo() async throws {
        let (c, _) = try await chat(authority: false)
        #expect(c.info?.model == "gpt-x")
        c.handle(event: GatewayEvent(type: "session.info", sessionID: "rt-a", payload: ["running": true]))
        #expect(c.info?.model == nil)
        #expect(c.info?.running == true)
    }
}
