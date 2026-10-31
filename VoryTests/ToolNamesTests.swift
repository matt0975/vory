import Foundation
import Testing
@testable import VoryCore

/// Tool steps are named (#387): the stored rows the watch and the fast open read carry a tool's
/// name only on the asking row's calls, and a row that asked for several tools named only its
/// first, so the other steps read "tool". Every call is read, and each result is matched to its
/// call; the gateway's own history (already named) is unchanged.
@Suite struct ToolNamesTests {
    /// The stored rows of one turn with three calls, as GET /api/sessions/{id}/messages returns them.
    static let stored = #"""
    [
      {"id": 1, "role": "user", "content": "Check the log host", "timestamp": "2026-10-14T08:00:00Z"},
      {"id": 2, "role": "assistant", "content": "", "finish_reason": "tool_calls", "timestamp": "2026-10-14T08:00:02Z",
       "tool_calls": [
         {"id": "call_a", "type": "function", "function": {"name": "terminal", "arguments": "{\"command\": \"df -h\"}"}},
         {"id": "call_b", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\": \"/etc/logrotate.d/nginx\"}"}},
         {"id": "call_c", "type": "function", "function": {"name": "web_search", "arguments": "{\"query\": \"logrotate size\"}"}}]},
      {"id": 3, "role": "tool", "content": "/var/log 41G", "tool_call_id": "call_a", "tool_name": null, "timestamp": "2026-10-14T08:00:03Z"},
      {"id": 4, "role": "tool", "content": "rotate 52", "tool_call_id": "call_b", "timestamp": "2026-10-14T08:00:04Z"},
      {"id": 5, "role": "tool", "content": "3 results", "tool_call_id": "call_c", "timestamp": "2026-10-14T08:00:05Z"},
      {"id": 6, "role": "assistant", "content": "Done: 4.2 GB freed.", "finish_reason": "stop", "timestamp": "2026-10-14T08:00:09Z"}
    ]
    """#

    static func decode(_ json: String) throws -> [TranscriptMessage] {
        try JSONDecoder().decode([TranscriptMessage].self, from: Data(json.utf8))
    }

    static func toolNames(_ items: [TranscriptItem]) -> [String] {
        items.compactMap { if case .tool(let a) = $0.kind { return a.name }; return nil }
    }

    @Test func everyCallIsReadAndEachResultTakesItsCallsName() throws {
        let rows = try Self.decode(Self.stored)
        #expect(rows[1].toolCalls.map(\.name) == ["terminal", "read_file", "web_search"])
        #expect(rows[1].toolCalls.map(\.id) == ["call_a", "call_b", "call_c"])
        #expect(rows[2].toolCallID == "call_a")
        let items = TranscriptItem.fromHistory(rows)
        #expect(Self.toolNames(items) == ["terminal", "read_file", "web_search"])
        // The results stay with their calls, and the reply follows.
        let results = items.compactMap { if case .tool(let a) = $0.kind { return a.resultText }; return nil }
        #expect(results == ["/var/log 41G", "rotate 52", "3 results"])
        if case .assistant(let t, _, _) = items.last?.kind { #expect(t == "Done: 4.2 GB freed.") } else { Issue.record("no reply") }
    }

    @Test func resultsOutOfOrderStillMatchTheirCalls() throws {
        var rows = try Self.decode(Self.stored)
        rows.swapAt(2, 4)
        #expect(Self.toolNames(TranscriptItem.fromHistory(rows)) == ["web_search", "read_file", "terminal"])
    }

    @Test func aResultWithoutItsCallIDTakesTheStoredNameElseTheNextCall() throws {
        let rows = try Self.decode(#"""
        [
          {"id": 1, "role": "assistant", "content": "", "tool_calls": [
            {"id": "x1", "function": {"name": "terminal", "arguments": "{}"}},
            {"id": "x2", "function": {"name": "patch", "arguments": "{}"}}]},
          {"id": 2, "role": "tool", "content": "ok", "tool_name": "search_files"},
          {"id": 3, "role": "tool", "content": "ok"},
          {"id": 4, "role": "tool", "content": "ok"}
        ]
        """#)
        // The stored name first; then the turn's calls in order.
        #expect(Self.toolNames(TranscriptItem.fromHistory(rows)) == ["search_files", "terminal", "patch"])
    }

    @Test func aResultMatchedByItsStoredNameAnswersThatCall() throws {
        // The first result names itself after the turn's first call; the next unnamed one is the second call.
        let rows = try Self.decode(#"""
        [
          {"id": 1, "role": "assistant", "content": "", "tool_calls": [
            {"id": "x1", "function": {"name": "terminal", "arguments": "{}"}},
            {"id": "x2", "function": {"name": "patch", "arguments": "{}"}}]},
          {"id": 2, "role": "tool", "content": "ok", "tool_name": "terminal"},
          {"id": 3, "role": "tool", "content": "ok"}
        ]
        """#)
        #expect(Self.toolNames(TranscriptItem.fromHistory(rows)) == ["terminal", "patch"])
    }

    @Test func aPageThatStartsMidTurnKeepsTheStoredNames() throws {
        // The asking row is on the page before; Hermes stores each result with its tool's name.
        let rows = try Self.decode(#"""
        [
          {"id": 9, "role": "tool", "content": "ok", "tool_call_id": "gone", "tool_name": "terminal"},
          {"id": 10, "role": "assistant", "content": "Done.", "finish_reason": "stop"}
        ]
        """#)
        #expect(Self.toolNames(TranscriptItem.fromHistory(rows)) == ["terminal"])
    }

    @Test func theGatewaysOwnHistoryIsUnchanged() throws {
        // session.resume's rows are already named and previewed, and carry no calls.
        let rows = try Self.decode(#"""
        [
          {"role": "user", "text": "Check it", "row_id": 1, "timestamp": 1760428800},
          {"role": "tool", "name": "terminal", "context": "df -h", "tool_call_id": "call_a"},
          {"role": "tool", "name": "read_file", "context": "/etc/logrotate.d/nginx"},
          {"role": "assistant", "text": "Done.", "row_id": 4, "timestamp": 1760428809}
        ]
        """#)
        let items = TranscriptItem.fromHistory(rows)
        #expect(Self.toolNames(items) == ["terminal", "read_file"])
        let contexts = items.compactMap { if case .tool(let a) = $0.kind { return a.context }; return nil }
        #expect(contexts == ["df -h", "/etc/logrotate.d/nginx"])
    }

    @Test func theCallsSurviveTheCachesRoundTrip() throws {
        let rows = try Self.decode(Self.stored)
        let back = try JSONDecoder().decode([TranscriptMessage].self, from: JSONEncoder().encode(rows))
        #expect(back[1].toolCalls == rows[1].toolCalls)
        #expect(back[2].toolCallID == "call_a")
        #expect(Self.toolNames(TranscriptItem.fromHistory(back)) == ["terminal", "read_file", "web_search"])
    }

    @Test func throughJSONValueAsTheWatchDecodesIt() throws {
        // The watch's relayed pages go through JSONValue, which turns snake_case into camelCase.
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(Self.stored.utf8))
        let rows = try value.decode([TranscriptMessage].self)
        #expect(Self.toolNames(TranscriptItem.fromHistory(rows)) == ["terminal", "read_file", "web_search"])
    }
}
