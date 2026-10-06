import Foundation
import Testing
@testable import VoryCore

/// A bot's answer is its reply, never only a "Reasoning" card: the gateway's `reasoning.available`
/// echo (the reply's own first 500 characters) stays out of the card, an answer a model sent
/// entirely as reasoning (promoted by the gateway) shows as the reply, and real thinking before
/// an answer keeps its card.
@MainActor @Suite struct ReasoningReplyTests {
    static let table = """
    ### AI lab power rankings
    | Rank | Lab / Model | Params | License | Superpower | Rating |
    |---|---|---|---|---|---|
    | 🥇 | **Lab A — Model One** | 2.8T / 104B act | Modified MIT | Agentic coding at scale | ⭐⭐⭐⭐⭐ |
    | 🥈 | **Lab B — Model Two** | 744B / 40B act | MIT | Long-horizon tool use | ⭐⭐⭐⭐½ |
    """

    private func chat() throws -> ChatSession {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        return ChatSession(runtime: rt, storedID: nil, title: nil)
    }

    private func send(_ chat: ChatSession, _ type: String, _ payload: [String: JSONValue] = [:]) {
        chat.handle(event: GatewayEvent(type: type, sessionID: chat.runtimeID, payload: .object(payload)))
    }

    private func lastReply(_ chat: ChatSession) -> (text: String, reasoning: String?)? {
        for item in chat.items.reversed() { if case .assistant(let t, let r, _) = item.kind { return (t, r) } }
        return nil
    }

    private func chunks(_ s: String, size: Int = 17) -> [String] {
        var out: [String] = [], rest = Substring(s)
        while !rest.isEmpty { out.append(String(rest.prefix(size))); rest = rest.dropFirst(size) }
        return out
    }

    @Test func theGatewaysEchoOfTheReplyIsNotReasoning() throws {
        let c = try chat()
        send(c, "message.start")
        for part in chunks(Self.table) { send(c, "message.delta", ["text": .string(part)]) }
        send(c, "reasoning.available", ["text": .string(String(Self.table.prefix(500)))])
        send(c, "message.complete", ["text": .string(Self.table)])
        let r = try #require(lastReply(c))
        #expect(r.text == Self.table)
        #expect(r.reasoning == nil)
    }

    @Test func anAnswerSentAsReasoningIsTheReply() throws {
        // A model after a web search: no content, the whole answer as reasoning; the
        // gateway promotes it and says so by sending the same text as message.complete's reasoning.
        let c = try chat()
        send(c, "message.start")
        send(c, "thinking.delta", ["text": "(waiting for the model)"])
        for part in chunks(Self.table) { send(c, "reasoning.delta", ["text": .string(part)]) }
        send(c, "message.complete", ["text": .string(Self.table), "reasoning": .string(Self.table)])
        let r = try #require(lastReply(c))
        #expect(r.text == Self.table)
        #expect(r.reasoning == nil)
    }

    @Test func thinkingBeforeAnAnswerSentAsReasoningKeepsOnlyTheThinking() throws {
        let c = try chat()
        send(c, "message.start")
        send(c, "reasoning.delta", ["text": "Compare the labs by size and licence first.\n\n"])
        for part in chunks(Self.table) { send(c, "reasoning.delta", ["text": .string(part)]) }
        send(c, "message.complete", ["text": .string(Self.table), "reasoning": .string(Self.table)])
        let r = try #require(lastReply(c))
        #expect(r.text == Self.table)
        #expect(r.reasoning == "Compare the labs by size and licence first.")
    }

    @Test func realThinkingThenAStreamedAnswerKeepsItsCard() throws {
        let c = try chat()
        send(c, "message.start")
        send(c, "reasoning.delta", ["text": "The person wants a ranking; a table reads best."])
        send(c, "thinking.delta", ["text": "(◔_◔) pondering"])
        for part in chunks(Self.table) { send(c, "message.delta", ["text": .string(part)]) }
        send(c, "reasoning.available", ["text": .string(String(Self.table.prefix(500)))])
        send(c, "message.complete", ["text": .string(Self.table)])
        let r = try #require(lastReply(c))
        #expect(r.text == Self.table)
        // The model's own thinking, without the gateway's spinner notice or the echo.
        #expect(r.reasoning == "The person wants a ranking; a table reads best.")
    }

    @Test func aReplyAlreadyShownAsAnInterimMessageIsNotShownTwice() throws {
        // Some runtimes send every finished message as message.interim, the final one too; the
        // gateway then marks message.complete with response_previewed.
        let c = try chat()
        send(c, "message.start")
        for part in chunks(Self.table) { send(c, "message.delta", ["text": .string(part)]) }
        send(c, "message.interim", ["text": .string(Self.table), "already_streamed": true])
        send(c, "thinking.delta", ["text": ""])
        send(c, "message.complete", ["text": .string(Self.table), "response_previewed": true])
        let replies = c.items.filter { if case .assistant = $0.kind { return true }; return false }
        #expect(replies.count == 1)
        #expect(lastReply(c)?.text == Self.table)
    }

    @Test func noFinalTextNeverPromotesReasoning() throws {
        // Cut off before an answer (a stall, an interrupt): the thinking is not shown as a reply.
        let c = try chat()
        send(c, "message.start")
        send(c, "reasoning.delta", ["text": "Maybe search first"])
        send(c, "message.complete", ["text": "", "status": "interrupted"])
        #expect(lastReply(c) == nil)
    }

    // MARK: Rules

    @Test func settlingReasoning() {
        let answer = "Two meetings today."
        // Streamed text: reasoning is real thinking, kept as it came.
        #expect(StreamAssembler.settledReasoning(streamedText: answer, reasoning: answer, finalText: answer, gatewayReasoning: nil) == answer)
        // No streamed text: the same text again goes, even with different whitespace.
        #expect(StreamAssembler.settledReasoning(streamedText: "", reasoning: "Two  meetings\ntoday. ", finalText: answer, gatewayReasoning: nil) == nil)
        // Think tags around it do not matter.
        #expect(StreamAssembler.settledReasoning(streamedText: "", reasoning: "<think>Two meetings today.</think>", finalText: answer, gatewayReasoning: nil) == nil)
        // Different reasoning stays.
        #expect(StreamAssembler.settledReasoning(streamedText: "", reasoning: "Check the calendar.", finalText: answer, gatewayReasoning: nil) == "Check the calendar.")
        // The gateway's promoted mark drops reasoning that holds the answer with something after it.
        #expect(StreamAssembler.settledReasoning(streamedText: "", reasoning: "Two meetings today. </think> ok", finalText: answer, gatewayReasoning: answer) == nil)
        #expect(StreamAssembler.settledReasoning(streamedText: "", reasoning: "", finalText: answer, gatewayReasoning: answer) == nil)
        // Joined again mid-answer (a reconnect): only the end of the answer came as reasoning.
        let half = String(Self.table.suffix(Self.table.count / 2))
        #expect(StreamAssembler.settledReasoning(streamedText: "", reasoning: half, finalText: Self.table, gatewayReasoning: Self.table) == nil)
        // Without the gateway's promoted mark, part of the answer is not assumed to be the answer.
        #expect(StreamAssembler.settledReasoning(streamedText: "", reasoning: half, finalText: Self.table, gatewayReasoning: nil) != nil)
    }

    // MARK: History

    private func row(_ role: String, _ text: String? = nil, reasoning: String? = nil, api: String? = nil, finish: String? = nil, tools: Bool = false, at: Double) -> TranscriptMessage {
        TranscriptMessage(role: role, text: text, timestamp: at, reasoning: reasoning, apiContent: api, finishReason: finish, hasToolCalls: tools)
    }

    private func replies(_ items: [TranscriptItem]) -> [String] {
        items.compactMap { if case .assistant(let t, _, _) = $0.kind { return t }; return nil }
    }

    @Test func historyShowsAnAnswerStoredWithEmptyContent() {
        // The REST page: the gateway keeps the answer in api_content.
        let rest = [row("user", "rank the labs", at: 1), row("tool", "results", at: 2), row("assistant", "", reasoning: Self.table, api: Self.table, finish: "stop", at: 3)]
        let built = TranscriptItem.fromHistory(rest)
        #expect(replies(built) == [Self.table])
        if case .assistant(_, let r, _)? = built.last?.kind { #expect(r == nil) }
        // session.resume: no api_content; a clean stop followed by the person, or the end of a finished chat.
        let resume = [row("user", "rank the labs", at: 1), row("assistant", "", reasoning: Self.table, at: 3), row("user", "thanks", at: 4)]
        #expect(replies(TranscriptItem.fromHistory(resume)) == [Self.table])
        let ended = [row("user", "rank the labs", at: 1), row("assistant", "", reasoning: Self.table, at: 3)]
        #expect(replies(TranscriptItem.fromHistory(ended)) == [Self.table])
    }

    @Test func historyKeepsThinkingOutOfTheReplies() {
        // Still running: the last row may be thinking in progress.
        let running = [row("user", "rank the labs", at: 1), row("assistant", "", reasoning: "Searching first", at: 2)]
        #expect(replies(TranscriptItem.fromHistory(running, running: true)).isEmpty)
        // Before a tool call: followed by the tool, or marked as asking for one.
        let beforeTool = [row("user", "q", at: 1), row("assistant", "", reasoning: "I should search", at: 2), row("tool", "results", at: 3)]
        #expect(replies(TranscriptItem.fromHistory(beforeTool)).isEmpty)
        let asked = [row("user", "q", at: 1), row("assistant", "", reasoning: "I should search", tools: true, at: 2)]
        #expect(replies(TranscriptItem.fromHistory(asked)).isEmpty)
        // Cut off by length: not an answer.
        let cut = [row("user", "q", at: 1), row("assistant", "", reasoning: "Half a thou", finish: "length", at: 2)]
        #expect(replies(TranscriptItem.fromHistory(cut)).isEmpty)
        // A row with its own text keeps a reasoning that differs, drops one that only repeats it.
        let normal = [row("assistant", "Done.", reasoning: "Done.", at: 1), row("assistant", "Sent.", reasoning: "Write it short.", at: 2)]
        let built = TranscriptItem.fromHistory(normal)
        let reasonings = built.compactMap { item -> String? in if case .assistant(_, let r, _) = item.kind { return r ?? "-" }; return nil }
        #expect(reasonings == ["-", "Write it short."])
    }

    @Test func aStalledResponseTheGatewayContinuedIsNotAReply() {
        // The gateway nudges a stalled response on with "continue"; the stalled one keeps its
        // partial text in api_content but did not stop cleanly.
        let rows = [row("user", "read the file", at: 1),
                    row("assistant", "", reasoning: "Partial", api: "Partial", finish: "incomplete", at: 2),
                    row("user", "[System: Continue now.]", at: 3),
                    row("assistant", "", reasoning: "The file says hi.", api: "The file says hi.", finish: "stop", at: 4)]
        #expect(replies(TranscriptItem.fromHistory(rows)) == ["The file says hi."])
        #expect(TranscriptItem.withPromotedAnswers(rows)[1].text == "")
    }

    @Test func anAnswerAlreadyFinishedHereStaysWhileAnotherTurnStarts() {
        // A turn started on another device: the snapshot says running before its prompt is stored.
        let rows = [row("user", "rank the labs", at: 1), row("assistant", "", reasoning: Self.table, at: 2)]
        #expect(replies(TranscriptItem.fromHistory(rows, running: true)).isEmpty)
        #expect(replies(TranscriptItem.fromHistory(rows, running: true, settled: [StreamAssembler.normalized(Self.table)])) == [Self.table])
    }

    @Test func hiddenRowsAndBlankReasoningStayOut() throws {
        var hidden = row("assistant", "", reasoning: "[response interrupted]", at: 2)
        hidden.displayKind = "hidden"
        #expect(TranscriptItem.withPromotedAnswers([row("user", "q", at: 1), hidden])[1].text == "")
        let padded = try JSONDecoder().decode(TranscriptMessage.self, from: Data(#"{"role":"assistant","content":"Done.","reasoning_content":" "}"#.utf8))
        #expect(padded.reasoning == nil)
    }

    @Test func previewsAndSummariesSeeThePromotedAnswer() {
        let rows = [row("user", "rank the labs", at: 1), row("assistant", "", reasoning: Self.table, api: Self.table, at: 2)]
        let read = TranscriptItem.withPromotedAnswers(rows)
        #expect(read.last?.text == Self.table)
        #expect(read.first?.text == "rank the labs")
    }

    @Test func storedRowsDecodeInBothSpellingsAndSurviveTheCache() throws {
        let rest = """
        {"role":"assistant","content":"","api_content":"The answer","finish_reason":"stop","reasoning_content":"The answer","tool_calls":[]}
        """
        let snake = try JSONDecoder().decode(TranscriptMessage.self, from: Data(rest.utf8))
        #expect(snake.apiContent == "The answer")
        #expect(snake.finishReason == "stop")
        #expect(snake.reasoning == "The answer")
        #expect(snake.hasToolCalls == false)
        let viaJSONValue = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"role":"assistant","content":"","api_content":"A","tool_calls":[{"function":{"name":"web_search"}}]}
        """.utf8)).decode(TranscriptMessage.self)
        #expect(viaJSONValue.apiContent == "A")
        #expect(viaJSONValue.hasToolCalls)
        #expect(viaJSONValue.name == "web_search")
        // The transcript cache encodes and decodes with a plain coder.
        let back = try JSONDecoder().decode(TranscriptMessage.self, from: JSONEncoder().encode(viaJSONValue))
        #expect(back.apiContent == "A")
        #expect(back.hasToolCalls)
    }
}
