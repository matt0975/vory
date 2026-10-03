import Foundation
import Testing
@testable import VoryCore

/// A helper the bot spun up: one row that follows every `subagent.*` event, whichever comes first.
@Suite struct SubagentRowTests {
    @Test func theFirstEventMakesTheRowAndTheRestKeepItUpToDate() {
        let spawn: JSONValue = ["subagent_id": .string("sa-1"), "goal": .string("Audit nginx"), "task_index": .number(0), "task_count": .number(2)]
        var a = SubagentActivity.applying("subagent.spawn_requested", spawn, to: nil)
        #expect(a.id == "sa-1" && a.goal == "Audit nginx" && a.isRunning)
        #expect(a.detailLine == "1 of 2 · Working…")
        a = SubagentActivity.applying("subagent.start", ["subagent_id": .string("sa-1"), "goal": .string("Audit nginx"), "model": .string("anthropic/claude-sonnet-4.6")], to: a)
        #expect(a.model == "anthropic/claude-sonnet-4.6" && a.taskCount == 2)
        a = SubagentActivity.applying("subagent.tool", ["subagent_id": .string("sa-1"), "tool_name": .string("terminal"), "tool_preview": .string("ls /etc/nginx\n"), "tool_count": .number(1)], to: a)
        #expect(a.step == "terminal: ls /etc/nginx" && a.toolCount == 1)
        a = SubagentActivity.applying("subagent.progress", ["subagent_id": .string("sa-1"), "text": .string("3 blocks found")], to: a)
        #expect(a.detailLine == "1 of 2 · 3 blocks found")
        a = SubagentActivity.applying("subagent.complete", ["subagent_id": .string("sa-1"), "status": .string("completed"), "summary": .string("One stale block."),
                                                            "duration_seconds": .number(4.6), "tool_count": .number(2)], to: a)
        #expect(!a.isRunning && !a.failed && a.summary == "One stale block." && a.step == nil)
        #expect(a.detailLine == "1 of 2 · Done in 5s · 2 tool calls")
    }

    @Test func aToolEventBeforeAnyStartStillMakesARow() {
        let a = SubagentActivity.applying("subagent.tool", ["subagent_id": .string("sa-9"), "tool_name": .string("read_file")], to: nil)
        #expect(a.id == "sa-9" && a.goal == "Subagent" && a.step == "read_file" && a.detailLine == "read_file")
        #expect(SubagentActivity.rowID(for: ["subagent_id": .string("sa-9")]) == "sub-sa-9")
        #expect(SubagentActivity.rowID(for: ["child_session_id": .string("child-3")]) == "sub-child-3")
        #expect(SubagentActivity.rowID(for: ["goal": .string("no id")]) == nil)
    }

    @Test func aFailedHelperSaysSoAndLongRunsAreInMinutes() {
        let a = SubagentActivity.applying("subagent.complete", ["subagent_id": .string("sa-2"), "status": .string("failed"), "duration_seconds": .number(75)],
                                          to: SubagentActivity(id: "sa-2", goal: "List logs"))
        #expect(a.failed && a.detailLine == "Failed in 1m")
    }
}

/// The report a helper's work comes back as, filed by the gateway in the user's seat.
@Suite struct DelegationReportTests {
    @Test func reportsFoldIntoNotesInsteadOfUserBubbles() {
        let batch = InjectedNote.parse("[ASYNC DELEGATION BATCH COMPLETE — dlg-1]\n\nTask 1 of 2: completed in 4.6s.")
        #expect(batch?.title == "Subagents reported back")
        #expect(batch?.body.hasPrefix("[ASYNC DELEGATION BATCH COMPLETE") == true)
        #expect(InjectedNote.parse("[ASYNC DELEGATION COMPLETE — sa-1]\nDone.")?.title == "Subagent reported back")
        #expect(InjectedNote.parse("[ASYNC DELEGATION TASK FAILED — sa-2]\nTimed out.")?.title == "Subagent failed")
        #expect(InjectedNote.parse("[async delegation batch complete — x] a failed test is mentioned here")?.title == "Subagents reported back")
    }

    @Test func ordinaryWordsAboutDelegationStayTheUsersOwn() {
        #expect(InjectedNote.parse("Can you check the async delegation docs?") == nil)
        #expect(InjectedNote.parse("[ASYNC] not a delegation") == nil)
    }
}
