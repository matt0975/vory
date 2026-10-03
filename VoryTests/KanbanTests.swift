import Foundation
import Testing
@testable import VoryCore

/// The kanban plugin's payloads, in the shapes its dashboard API answers with.
@Suite struct KanbanDecodingTests {
    static let boardJSON = """
    {"columns": [
      {"name": "triage", "tasks": []},
      {"name": "todo", "tasks": [{"id": "t-002", "title": "Add a logrotate rule", "body": "rotate 8", "assignee": "default", "status": "todo", "priority": 1,
        "created_by": "dashboard", "created_at": 1759500000, "started_at": null, "completed_at": null, "workspace_kind": "scratch", "workspace_path": null,
        "claim_lock": null, "claim_expires": null, "tenant": null, "age": {"created_age_seconds": 3600, "started_age_seconds": null, "time_to_complete_seconds": null},
        "latest_summary": null, "current_run_started_at": null, "link_counts": {"parents": 1, "children": 0}, "comment_count": 2, "progress": null}]},
      {"name": "running", "tasks": [{"id": "t-001", "title": "Clear old logs", "body": null, "assignee": "work", "status": "running", "priority": 0,
        "created_by": "agent", "created_at": 1759490000, "started_at": 1759503000, "completed_at": null, "workspace_kind": "scratch", "workspace_path": null,
        "claim_lock": "w1", "claim_expires": 1759600000, "tenant": "acme", "worker_pid": 4242, "last_heartbeat_at": 1759503300, "current_run_id": 7,
        "session_id": "20260921_154212_a1b2c3", "age": {"created_age_seconds": 13600, "started_age_seconds": 600, "time_to_complete_seconds": null},
        "latest_summary": "Found 34 files", "current_run_started_at": 1759503000, "link_counts": {"parents": 0, "children": 2}, "comment_count": 0,
        "progress": {"done": 1, "total": 2}, "diagnostics": [{"code": "stale_heartbeat", "severity": "warning", "message": "No heartbeat for 5 minutes"}]}]},
      {"name": "done", "tasks": []}],
     "tenants": ["acme"], "assignees": ["default", "work"], "latest_event_id": 41, "now": 1759503600}
    """

    @Test func aBoardDecodesWithItsCardsFacts() throws {
        let board = try JSONCoding.decoder.decode(KanbanBoard.self, from: Data(Self.boardJSON.utf8))
        #expect(board.columns.count == 4 && board.latestEventId == 41)
        #expect(board.count(.todo) == 1 && board.count(.running) == 1 && board.count(.done) == 0)
        let running = try #require(board.task(id: "t-001"))
        #expect(running.column == .running && running.isWorking && running.workerPid == 4242 && running.currentRunId == 7)
        #expect(running.sessionId == "20260921_154212_a1b2c3" && running.progress == KanbanProgress(done: 1, total: 2))
        #expect(running.warnings.first?.text == "No heartbeat for 5 minutes")
        #expect(running.preview == "Found 34 files")
        let todo = try #require(board.task(id: "t-002"))
        #expect(todo.priority == 1 && todo.commentCount == 2 && todo.linkCounts?.parents == 1 && todo.preview == "rotate 8")
        #expect(!todo.isWorking && todo.age?.createdAgeSeconds == 3600)
        #expect(board.needsAttention == 1)
    }

    @Test func aTaskDetailDecodesItsCommentsRunsAndEvents() throws {
        let json = """
        {"task": {"id": "t-001", "title": "Clear old logs", "body": "Under /var/log", "assignee": "work", "status": "review", "priority": 0, "created_by": "agent",
                  "created_at": 1759490000, "started_at": 1759503000, "completed_at": null, "workspace_kind": "scratch", "workspace_path": null, "claim_lock": null,
                  "claim_expires": null, "tenant": null, "current_run_id": 8, "latest_summary": "34 files removed, 4.2 GB freed", "current_run_started_at": null},
         "comments": [{"id": 1, "task_id": "t-001", "author": "matt", "body": "Keep today's log", "created_at": 1759491000}],
         "events": [{"id": 40, "task_id": "t-001", "run_id": 7, "kind": "status", "payload": {"from": "ready", "to": "running"}, "created_at": 1759503000},
                    {"id": 41, "task_id": "t-001", "run_id": 8, "kind": "review_requested", "payload": null, "created_at": 1759503500}],
         "attachments": [], "links": {"parents": [], "children": ["t-003"]}, "link_tasks": {}, "child_results": [{"id": "t-003", "title": "Child", "status": "done", "latest_summary": null, "result": "ok"}],
         "runs": [{"id": 7, "task_id": "t-001", "profile": "work", "step_key": null, "status": "ended", "claim_lock": null, "claim_expires": null, "worker_pid": 4242,
                   "max_runtime_seconds": 3600, "last_heartbeat_at": 1759503200, "started_at": 1759503000, "ended_at": 1759503250, "outcome": "crashed", "summary": null,
                   "metadata": null, "error": "worker exited 1"},
                  {"id": 8, "task_id": "t-001", "profile": "work", "step_key": null, "status": "running", "claim_lock": "w2", "claim_expires": 1759600000, "worker_pid": 4243,
                   "max_runtime_seconds": 3600, "last_heartbeat_at": 1759503500, "started_at": 1759503300, "ended_at": null, "outcome": null, "summary": null, "metadata": {"k": 1}, "error": null}]}
        """
        let d = try JSONCoding.decoder.decode(KanbanTaskDetail.self, from: Data(json.utf8))
        #expect(d.task.column == .review && d.comments.count == 1 && d.comments[0].author == "matt")
        #expect(d.runs.count == 2 && d.runs[0].stateText == "crashed" && d.runs[0].durationSeconds == 250 && d.runs[1].isOpen)
        #expect(d.currentRun?.id == 8)
        #expect(d.events.map(\.line) == ["Moved to Running", "Review requested"])
        #expect(d.links?.children == ["t-003"] && d.childResults?.first?.result == "ok")
    }

    @Test func boardsWorkersLogsAndEnvelopesDecode() throws {
        let boards = try JSONCoding.decoder.decode(KanbanBoards.self, from: Data("""
        {"boards": [{"slug": "default", "name": "Default", "description": "", "icon": "", "color": "", "default_workdir": null, "project_id": null, "created_at": null,
                     "archived": false, "is_current": true, "counts": {"todo": 2, "running": 1, "archived": 4}, "total": 3, "default_workspace_kind": "scratch", "project_name": null},
                    {"slug": "homelab", "name": "", "is_current": false, "counts": {}, "total": 0, "archived": false}], "current": "default"}
        """.utf8))
        #expect(boards.current == "default" && boards.boards.count == 2 && boards.boards[1].displayName == "homelab" && boards.boards[0].total == 3)
        let workers = try JSONCoding.decoder.decode(KanbanWorkers.self, from: Data("""
        {"workers": [{"run_id": 8, "task_id": "t-001", "task_title": "Clear old logs", "task_status": "running", "task_assignee": "work", "profile": "work",
                      "worker_pid": 4243, "started_at": 1759503300, "claim_lock": "w2", "claim_expires": 1759600000, "last_heartbeat_at": 1759503500, "max_runtime_seconds": 3600}],
         "count": 1, "checked_at": 1759503600}
        """.utf8))
        #expect(workers.workers.first?.id == 8 && workers.workers.first?.taskId == "t-001")
        let log = try JSONCoding.decoder.decode(KanbanLog.self, from: Data(#"{"task_id": "t-001", "path": "/x", "exists": true, "size_bytes": 12, "content": "hello\nworld", "truncated": false}"#.utf8))
        #expect(log.exists && log.content.hasSuffix("world"))
        let made = try JSONCoding.decoder.decode(KanbanTaskEnvelope.self, from: Data(#"{"task": {"id": "t-009", "title": "New", "status": "ready", "assignee": "default", "created_at": 1}, "warning": "No gateway is running for this profile; the task will sit in 'ready'."}"#.utf8))
        #expect(made.task?.id == "t-009" && made.warning?.hasPrefix("No gateway") == true)
        let frame = try JSONCoding.decoder.decode(KanbanEventsFrame.self, from: Data(#"{"events": [{"id": 42, "task_id": "t-001", "run_id": null, "kind": "commented", "payload": {"author": "matt"}, "created_at": 1759503700}], "cursor": 42}"#.utf8))
        #expect(frame.cursor == 42 && frame.events[0].line == "Comment")
    }
}

/// What the app may do to a card, and the words it sends.
@Suite struct KanbanRulesTests {
    @Test func onlyTheHandMovableColumnsAreTargets() {
        #expect(KanbanStatus.moveTargets == [.triage, .todo, .ready, .blocked, .done, .archived])
        #expect(!KanbanStatus.running.isMoveTarget && !KanbanStatus.scheduled.isMoveTarget && !KanbanStatus.review.isMoveTarget)
        #expect(KanbanStatus.running.notMovableReason?.contains("dispatcher") == true)
        #expect(KanbanStatus.done.asksForSummary && KanbanStatus.archived.asksToConfirm && KanbanStatus.blocked.asksToConfirm && !KanbanStatus.todo.asksToConfirm)
        #expect(KanbanStatus.columns.map(\.rawValue) == ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"])
    }

    @Test func patchesAndNewTasksSendTheServersFieldNames() {
        let p = KanbanTaskPatch(status: .done, assignee: .some(nil), priority: 2, result: "Freed 4.2 GB", summary: "Freed 4.2 GB", blockReason: "waiting on a key")
        guard case .object(let o) = p.json else { Issue.record("not an object"); return }
        #expect(o["status"] == .string("done") && o["assignee"] == .null && o["priority"] == .number(2))
        #expect(o["result"] == .string("Freed 4.2 GB") && o["block_reason"] == .string("waiting on a key") && o["title"] == nil)
        let t = KanbanNewTask(title: "Rotate logs", body: "", assignee: "work", priority: 1, triage: true)
        guard case .object(let n) = t.json else { Issue.record("not an object"); return }
        #expect(n["title"] == .string("Rotate logs") && n["body"] == nil && n["assignee"] == .string("work") && n["triage"] == .bool(true) && n["parents"] == .array([]))
    }

    @Test func theEventCursorStartsAtTheBoardsTailAndMovesWithFrames() {
        var c = KanbanEventCursor()
        #expect(c.sinceQuery == nil)
        c.start(fromBoard: 41)
        #expect(c.cursor == 41 && c.sinceQuery?.value == "41")
        c.start(fromBoard: 10)   // a later board read does not move it back
        #expect(c.cursor == 41)
        let event = KanbanEvent(id: 42, taskId: "t-001", runId: nil, kind: "commented", payload: nil, createdAt: 1)
        #expect(c.take(KanbanEventsFrame(events: [event], cursor: 42)) == true)
        #expect(c.cursor == 42)
        #expect(c.take(KanbanEventsFrame(events: [], cursor: 42)) == false)
        #expect(c.take(KanbanEventsFrame(events: [event], cursor: 40)) == true && c.cursor == 42)
    }
}
