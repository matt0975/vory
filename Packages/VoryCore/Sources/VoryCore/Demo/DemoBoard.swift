import Foundation

/// The demo's board: the gateway's bundled kanban plugin (`/api/plugins/kanban/…`), in the shapes the mock
/// gateway answers with. One board of the demo's tasks (`DemoContent.tasks`).
extension DemoGateway {
    static let boardColumns = ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"]

    static func boardTask(_ t: DemoContent.BoardTask, now: Double) -> [String: Any] {
        let created = Int(now - t.age)
        let running = t.status == "running"
        let startedAgo: Double? = ["running", "blocked", "review", "done"].contains(t.status) ? t.age * 0.8 : nil
        let completedAgo: Double? = t.status == "done" ? t.age * 0.6 : nil
        let started = startedAgo.map { Int(now - $0) }
        let completed = completedAgo.map { Int(now - $0) }
        return ["id": t.id, "title": t.title, "body": t.body ?? NSNull(), "assignee": t.assignee ?? NSNull(), "status": t.status,
                "priority": t.priority, "created_by": "dashboard", "created_at": created, "started_at": started ?? NSNull(),
                "completed_at": completed ?? NSNull(), "workspace_kind": "scratch", "workspace_path": NSNull(),
                "claim_lock": running ? "w-\(t.id)" : NSNull(), "claim_expires": running ? Int(now) + 3600 : NSNull(),
                "tenant": NSNull(), "branch_name": NSNull(), "project_id": NSNull(),
                "result": t.status == "done" ? (t.summary ?? NSNull()) as Any : NSNull(), "idempotency_key": NSNull(),
                "consecutive_failures": 0, "worker_pid": running ? 4243 : NSNull(), "last_failure_error": NSNull(),
                "max_runtime_seconds": 3600, "last_heartbeat_at": running ? Int(now) - 12 : NSNull(),
                "current_run_id": running ? 8 : NSNull(), "workflow_template_id": NSNull(), "current_step_key": NSNull(),
                "skills": NSNull(), "model_override": NSNull(), "provider_override": NSNull(), "reasoning_effort": NSNull(),
                "max_retries": NSNull(), "goal_mode": false, "goal_max_turns": NSNull(), "session_id": NSNull(),
                "block_kind": NSNull(), "block_recurrences": 0, "completion_contract": NSNull(),
                "age": ["created_age_seconds": Int(t.age), "started_age_seconds": startedAgo.map { Int($0) } ?? NSNull(),
                        "time_to_complete_seconds": completed.map { $0 - (started ?? created) } ?? NSNull()],
                "latest_summary": t.summary ?? NSNull(), "current_run_started_at": running ? (started ?? created) : NSNull(),
                "link_counts": ["parents": 0, "children": 0], "comment_count": 0, "progress": NSNull()]
    }

    func boardRoute(method: String, path: String, query: [String: String], payload: [String: Any]) -> (Int, Any) {
        if let board = query["board"], board != "default" { return (404, ["detail": "board '\(board)' not found"]) }
        let sub = String(path.dropFirst("/api/plugins/kanban".count))
        if method != "GET", let answer = boardWrite(method: method, sub: sub, payload: payload) { return answer }
        switch sub {
        case "/boards":
            var counts: [String: Int] = [:]
            for t in board { counts[t["status"] as? String ?? "", default: 0] += 1 }
            return (200, ["boards": [["slug": "default", "name": "Default", "description": "", "icon": "", "color": "", "default_workdir": NSNull(),
                                      "project_id": NSNull(), "created_at": NSNull(), "archived": false, "default_workspace_kind": "scratch",
                                      "project_name": NSNull(), "is_current": true, "counts": counts, "total": board.count]],
                          "current": "default"])
        case "/board":
            return (200, ["columns": Self.boardColumns.map { c in ["name": c, "tasks": board.filter { $0["status"] as? String == c }] as [String: Any] },
                          "tenants": [], "assignees": Array(Set(board.compactMap { $0["assignee"] as? String })).sorted(),
                          "latest_event_id": boardCursor, "now": Int(now())])
        case "/assignees":
            return (200, ["assignees": DemoContent.bots.map { ["name": $0.name, "on_disk": true, "counts": [:]] as [String: Any] }])
        case "/stats":
            var by: [String: Int] = [:]
            for t in board { by[t["status"] as? String ?? "", default: 0] += 1 }
            return (200, ["by_status": by, "by_assignee": [:], "oldest_ready_age_seconds": 20_000])
        case "/workers/active":
            let workers = board.filter { $0["status"] as? String == "running" }.map { t -> [String: Any] in
                ["run_id": t["current_run_id"] ?? NSNull(), "task_id": t["id"] ?? "", "task_title": t["title"] ?? "", "task_status": "running",
                 "task_assignee": t["assignee"] ?? NSNull(), "profile": t["assignee"] ?? NSNull(), "worker_pid": t["worker_pid"] ?? NSNull(),
                 "started_at": t["started_at"] ?? NSNull(), "claim_lock": t["claim_lock"] ?? NSNull(), "claim_expires": t["claim_expires"] ?? NSNull(),
                 "last_heartbeat_at": t["last_heartbeat_at"] ?? NSNull(), "max_runtime_seconds": 3600]
            }
            return (200, ["workers": workers, "count": workers.count, "checked_at": Int(now())])
        case "/dispatch":
            return (200, ["spawned": 0, "promoted": 0, "dry_run": query["dry_run"] == "true", "reasons": []])
        default:
            break
        }
        let parts = sub.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "tasks", let t = board.first(where: { $0["id"] as? String == parts[1] }) {
            if parts.count == 2 {
                return (200, ["task": t, "comments": [], "events": [], "attachments": [], "links": ["parents": [], "children": []],
                              "link_tasks": [:], "child_results": [], "runs": []])
            }
            if parts.count == 3, parts[2] == "log" {
                let content = t["status"] as? String == "running" ? "[10:01:03] claimed \(parts[1]) (run 8)\n[10:01:04] working on it\n" : ""
                return (200, ["task_id": parts[1], "path": "\(DemoContent.home)/.hermes/kanban/logs/\(parts[1]).log", "exists": !content.isEmpty,
                              "size_bytes": content.utf8.count, "content": content, "truncated": false])
            }
        }
        if parts.count == 2, parts[0] == "runs" { return (404, ["detail": "run \(parts[1]) not found"]) }
        trip("board \(method) \(sub)")
        return (404, ["detail": "Not found"])
    }
}
