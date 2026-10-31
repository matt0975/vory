import Foundation

/// What changes the demo's state: a message sent gets a scripted turn from `DemoContent` (`everyday`, or once per
/// demo `cleanup` with the approval the app answers), streamed at a believable pace; a group message gets its members'
/// replies; the board's writes are applied and its event socket told; files the app sends are kept for the demo's life.
extension DemoGateway {
    /// Seconds between streamed pieces, and for a tool step.
    var pieceDelay: Double { pace == .real ? 0.035 : 0.008 }
    var stepDelay: Double { pace == .real ? 1.2 : 0.25 }

    func liveRPC(_ method: String, _ p: [String: Any], profile: String) -> Result<Any, RPCError>? {
        switch method {
        case "prompt.submit":
            guard let l = live[p["session_id"] as? String ?? ""] else { return .failure(RPCError(code: 4006, message: "unknown session")) }
            if l.running { return .failure(RPCError(code: 4009, message: "a turn is already running in this session")) }
            let text = p["text"] as? String ?? ""
            l.running = true
            l.turnStartedAt = now()
            l.inflight = ["user": text, "assistant": "", "streaming": true]
            Task { await self.runTurn(l, prompt: text) }
            return .success(["status": "streaming"])
        case "approval.respond":
            for l in live.values {
                for (id, f) in l.openRequests where f["method"] as? String == "approval" {
                    if (f["params"] as? [String: Any])?["request_id"] as? String == p["request_id"] as? String {
                        answered(id, ["choice": p["choice"] ?? "deny"])
                        return .success(["resolved": 1])
                    }
                }
            }
            return .success(["resolved": 0])
        case "session.delete":
            let id = p["session_id"] as? String ?? ""
            stored.removeAll { $0.id == id }
            live = live.filter { $0.value.stored != id && $0.key != id }
            return .success(["closed": true, "deleted": id])
        case "session.workspace.move":
            guard let key = p["session_key"] as? String, let i = stored.firstIndex(where: { $0.id == key }) else {
                return .failure(RPCError(code: 4007, message: "session not found"))
            }
            guard let cwd = p["cwd"] as? String, !cwd.isEmpty else { return .failure(RPCError(code: 4016, message: "cwd required")) }
            stored[i].cwd = cwd
            return .success(["cwd": cwd, "branch": NSNull(), "git_repo_root": NSNull()])
        case "projects.create":
            let name = (p["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let folders = p["folders"] as? [String] ?? []
            guard !name.isEmpty, let first = folders.first else { return .failure(RPCError(code: 5063, message: "name and at least one folder are required")) }
            sent += 1
            let t = Int(now())
            let pr: [String: Any] = ["id": "p_demo\(sent)", "slug": name.lowercased().replacingOccurrences(of: " ", with: "-"), "name": name,
                                     "description": p["description"] ?? NSNull(), "icon": p["icon"] ?? NSNull(), "color": p["color"] ?? NSNull(),
                                     "board_slug": NSNull(), "primary_path": first, "archived": false, "created_at": t,
                                     "folders": folders.enumerated().map { i, f in ["path": f, "label": NSNull(), "is_primary": i == 0, "added_at": t] }]
            projects.append(pr)
            if p["use"] as? Bool == true { activeProject = pr["id"] as? String }
            return .success(["project": pr])
        case "projects.update", "projects.archive", "projects.delete", "projects.set_active":
            let i = projects.firstIndex { $0["id"] as? String == p["id"] as? String || $0["slug"] as? String == p["id"] as? String }
            if method == "projects.set_active" {
                activeProject = i.flatMap { projects[$0]["id"] as? String }
                return .success(["active_id": orNull(activeProject)])
            }
            guard let i else { return .failure(RPCError(code: 5062, message: "no such project")) }
            switch method {
            case "projects.update":
                for k in ["name", "description", "icon", "color", "board_slug"] where p[k] != nil { projects[i][k] = p[k] }
                return .success(["project": projects[i]])
            case "projects.archive":
                projects[i]["archived"] = !(p["restore"] as? Bool ?? false)
            default:
                if activeProject == projects[i]["id"] as? String { activeProject = nil }
                projects.remove(at: i)
            }
            return .success(["projects": projects, "active_id": orNull(activeProject)])
        case "groups.create":
            sent += 1
            let members = (p["members"] as? [[String: Any]] ?? []).enumerated().map { i, m -> [String: Any] in
                let bot = m["profile"] as? String ?? "default"
                return ["member_id": "m\(i + 1)", "profile": bot, "handle": m["handle"] ?? bot,
                        "display_name": DemoContent.bots.first { $0.name == bot }?.display ?? bot]
            }
            let room: [String: Any] = ["room_id": p["room_id"] as? String ?? "room-demo\(sent)", "name": p["name"] ?? "Group",
                                       "members": members, "updated_at": now(), "disbanded_at": NSNull(), "latest_seq": 0]
            rooms.append(room)
            return .success(["room": room])
        case "groups.send":
            let payload = p["payload"] as? [String: Any] ?? [:]
            guard Set(payload.keys) == ["text", "thread_id"] else {
                return .failure(RPCError(code: -32602, message: payload["thread_id"] == nil ? "user payload is missing fields: thread_id" : "unexpected payload fields"))
            }
            let roomID = p["room_id"] as? String ?? ""
            let said = logRoom(roomID, kind: "message.user", actor: ["kind": "user", "id": "user"], payload: ["text": payload["text"] ?? "", "thread_id": "main"])
            Task { await self.groupReplies(roomID, to: payload["text"] as? String ?? "") }
            return .success(["event_id": said["event_id"] ?? "", "seq": said["seq"] ?? 0])
        case "image.attach_bytes", "pdf.attach":
            let name = p["filename"] as? String ?? "upload.png"
            let ext = (name as NSString).pathExtension.isEmpty ? "png" : (name as NSString).pathExtension
            return .success(["attached": true, "filename": name, "path": "\(DemoContent.home)/.hermes/images/upload_\(Int(now()))_1.\(ext)", "count": 1])
        case "file.attach":
            return .success(["ref_text": "[file: \(p["name"] as? String ?? "file")]"])
        default:
            return nil
        }
    }

    func liveRoute(method: String, path: String, query: [String: String], payload: [String: Any], body: Data, contentType: String) -> (Int, Any)? {
        switch path {
        case "/api/files/upload", "/api/files/upload-stream":
            let (name, data) = Self.uploaded(body: body, contentType: contentType, payload: payload)
            let dir = query["path"] ?? (payload["path"] as? String).map { ($0 as NSString).deletingLastPathComponent } ?? DemoContent.home
            let target = name.hasPrefix("/") ? name : (dir as NSString).appendingPathComponent(name)
            uploads[target] = (Self.mime(for: target), data)
            return (200, ["ok": true, "path": target, "size": data.count])
        default:
            if let answer = chatEdit(method: method, path: path, payload: payload) { return answer }
            // Bots, settings and the rest the demo does not keep: taken, and nothing changes (the tripwire lists them).
            if path.hasPrefix("/api/") { trip("\(method) \(path) (taken)"); return (200, ["ok": true]) }
            return nil
        }
    }

    /// A chat deleted, pinned, archived or renamed from the list, as a Hermes from before #467's fence takes it (the
    /// demo has no snapshot route, so the app sends these plainly): kept for the demo's life, so the list the app
    /// reloads agrees with what was done and a pin moves the chat (an archived one is listed when asked for, #474). Taken and dropped instead, the app's own reload
    /// brought a deleted chat back and put a pin back, which is #467's fault shown in the demo. A fresh demo starts
    /// from the seed again.
    func chatEdit(method: String, path: String, payload: [String: Any]) -> (Int, Any)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "api", parts[1] == "sessions", method == "DELETE" || method == "PATCH" else { return nil }
        let id = parts[2]
        guard let i = stored.firstIndex(where: { $0.id == id }) else { return (404, ["detail": "Session not found"]) }
        if method == "DELETE" {
            stored.remove(at: i)
            live = live.filter { $0.value.stored != id && $0.key != id }
            return (200, ["ok": true, "session_id": id, "operation": "delete", "deleted_ids": [id]])
        }
        if let v = payload["pinned"] as? Bool { stored[i].pinned = v }
        if let v = payload["archived"] as? Bool { stored[i].archived = v }
        if let t = (payload["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { stored[i].title = t }
        return (200, ["ok": true, "title": stored[i].title])
    }

    // MARK: A turn

    func runTurn(_ l: Live, prompt: String) async {
        let userAt = now()
        let turn = approvalDue(l, prompt: prompt) ? DemoContent.cleanup : DemoContent.everyday
        event("message.start", l.sid)
        // The reply's paragraphs as they stream (`paragraph`); an empty one (a turn that opens with its tool step) adds nothing.
        var reply = ""
        await stream(l, turn.reasoning, kind: "reasoning.delta")
        if let piece = Self.paragraph(turn.opening, after: reply) { await stream(l, piece); reply += piece }
        var tools: [[String: Any]] = []
        for step in turn.steps { tools.append(await runStep(step, in: l)) }
        event("session.usage", l.sid, ["usage": usage(l.outputTokens)])
        var closing = turn.closing
        if let a = turn.approval {
            approvalAsked = true
            // The command is on the card the app shows, not repeated in the reply.
            if let piece = Self.paragraph(a.ask, after: reply) { await stream(l, piece); reply += piece }
            let answer = await ask(l, "approval", ["request_id": "req-demo\(sent)", "command": a.command,
                                                   "description": a.description, "tool_name": a.ran.name,
                                                   "choices": approvalChoices, "allow_session": approvalChoices.contains("session"),
                                                   "allow_permanent": approvalChoices.contains("always")])
            if (answer ?? "deny") == "deny" {
                closing = a.denied
            } else {
                tools.append(await runStep(a.ran, in: l))
                closing = a.done
            }
        }
        if let piece = Self.paragraph(closing, after: reply) { await stream(l, piece); reply += piece }
        // The chat's history as the gateway files it: the prompt, the tool rows, the reply.
        var rows: [[String: Any]] = [["role": "user", "text": prompt, "timestamp": userAt]]
        rows += tools
        rows.append(["role": "assistant", "text": reply, "timestamp": now()])
        for var r in rows { r["row_id"] = l.history.count + 1; l.history.append(r) }
        if let i = stored.firstIndex(where: { $0.id == l.stored }) {
            stored[i].preview = closing.components(separatedBy: "\n").first ?? ""
            stored[i].lastActive = now()
            if stored[i].title == "New chat" {
                let title = Self.title(for: prompt)
                stored[i].title = title
                l.title = title
                event("session.title", l.sid, ["session_id": l.stored, "title": title])
            }
        }
        l.running = false
        l.inflight = nil
        event("message.complete", l.sid, ["text": reply, "status": "complete", "usage": usage(l.outputTokens, calls: 2)])
    }

    /// A paragraph of a reply as it streams: on its own after a blank line, or nil when it has no words.
    static func paragraph(_ text: String, after reply: String) -> String? {
        text.isEmpty ? nil : (reply.isEmpty ? text : "\n\n" + text)
    }

    /// A tool step of a turn: started, a moment, completed; its row as the chat's history files it.
    func runStep(_ step: DemoContent.Turn.Step, in l: Live) async -> [String: Any] {
        let id = "t-demo\(sent)"
        sent += 1
        event("tool.start", l.sid, ["tool_id": id, "name": step.name, "context": step.context, "args": ["command": step.context]])
        try? await Task.sleep(for: .seconds(stepDelay))
        event("tool.complete", l.sid, ["tool_id": id, "name": step.name, "duration_s": step.seconds ?? stepDelay, "summary": step.summary, "result_text": step.output])
        return ["role": "tool", "name": step.name, "context": step.context, "text": step.summary, "timestamp": now()]
    }

    /// Once per demo: the message that asks what's taking the space or for a cleanup (onboarding's ready-made
    /// message among them), or the second message in a chat.
    func approvalDue(_ l: Live, prompt: String) -> Bool {
        guard !approvalAsked else { return false }
        let p = prompt.lowercased()
        if ["space", "disk", "clean", "delete", "remove", "tidy", "free up"].contains(where: p.contains) { return true }
        return l.history.filter { $0["role"] as? String == "user" }.count == 1 && l.stored.hasPrefix("demo_")
    }

    func stream(_ l: Live, _ text: String, kind: String = "message.delta") async {
        var i = text.startIndex
        while i < text.endIndex {
            let n = rng.int(3...14)
            let j = text.index(i, offsetBy: n, limitedBy: text.endIndex) ?? text.endIndex
            let piece = String(text[i..<j])
            i = j
            event(kind, l.sid, ["text": piece])
            if kind == "message.delta", var inflight = l.inflight {
                inflight["assistant"] = (inflight["assistant"] as? String ?? "") + piece
                l.inflight = inflight
            }
            l.outputTokens += max(1, piece.count / 4)
            try? await Task.sleep(for: .seconds(pieceDelay))
        }
    }

    /// A request to the app (an approval): sent to every socket, and kept open until one answers.
    func ask(_ l: Live, _ method: String, _ params: [String: Any]) async -> String? {
        sent += 1
        let id = "srq-demo\(sent)"
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": ["session_id": l.sid].merging(params) { a, _ in a }]
        l.openRequests[id] = frame
        broadcast(frame)
        return await withCheckedContinuation { c in waiting[id] = c }
    }

    /// A new chat's title from its first message: whole words up to about 40 characters, capitalised.
    static func title(for prompt: String) -> String {
        var words: [Substring] = []
        for w in prompt.split(whereSeparator: \.isWhitespace) {
            if !words.isEmpty, (words + [w]).joined(separator: " ").count > 40 { break }
            words.append(w)
        }
        let t = words.joined(separator: " ")
        guard let first = t.first else { return "New chat" }
        return first.uppercased() + t.dropFirst()
    }

    // MARK: Groups

    @discardableResult
    func logRoom(_ roomID: String, kind: String, actor: [String: Any], payload: [String: Any]) -> [String: Any] {
        var log = roomLogs[roomID] ?? []
        let e: [String: Any] = ["room_id": roomID, "seq": log.count + 1, "event_id": "evt-demo-\(roomID)-\(log.count + 1)", "kind": kind,
                                "actor": actor, "payload": payload, "created_at": now()]
        log.append(e)
        roomLogs[roomID] = log
        if let i = rooms.firstIndex(where: { $0["room_id"] as? String == roomID }) {
            rooms[i]["latest_seq"] = log.count
            rooms[i]["updated_at"] = now()
        }
        return e
    }

    func groupReplies(_ roomID: String, to text: String) async {
        guard let room = rooms.first(where: { $0["room_id"] as? String == roomID }) else { return }
        let members = room["members"] as? [[String: Any]] ?? []
        let lines = ["I'll take the first part of that.", "And I'll pick up the rest and write it up.", "I'll keep an eye on it while you two work."]
        logRoom(roomID, kind: "room.activity", actor: ["kind": "system", "id": "room"], payload: ["status": "typing"])
        for (i, m) in members.prefix(3).enumerated() {
            try? await Task.sleep(for: .seconds(pace == .real ? 3 : 0.5))
            logRoom(roomID, kind: "message.member", actor: ["kind": "member", "id": m["member_id"] ?? "m\(i + 1)"],
                    payload: ["text": lines[i % lines.count], "member_id": m["member_id"] ?? "m\(i + 1)", "thread_id": "main"])
        }
        logRoom(roomID, kind: "room.activity", actor: ["kind": "system", "id": "room"], payload: ["status": "settled"])
    }

    // MARK: Board writes

    func boardWrite(method: String, sub: String, payload: [String: Any]) -> (Int, Any)? {
        let parts = sub.split(separator: "/").map(String.init)
        if sub == "/tasks", method == "POST" {
            sent += 1
            let id = "t-\(200 + sent)"
            let assignee = payload["assignee"] as? String
            let status = payload["triage"] as? Bool == true ? "triage" : (assignee != nil ? "ready" : "todo")
            var t = Self.boardTask(DemoContent.BoardTask(id: id, title: payload["title"] as? String ?? "Untitled", status: status, assignee: assignee,
                                                         body: payload["body"] as? String, summary: nil, age: 0, priority: payload["priority"] as? Int ?? 0), now: now())
            t["created_at"] = Int(now())
            board.insert(t, at: 0)
            bumpBoard(id, "status", ["from": NSNull(), "to": status])
            return (200, ["task": t])
        }
        guard parts.count >= 2, parts[0] == "tasks", let i = board.firstIndex(where: { $0["id"] as? String == parts[1] }) else { return nil }
        let id = parts[1]
        let tail = parts.count > 2 ? parts[2] : ""
        switch (method, tail) {
        case ("DELETE", ""):
            board.remove(at: i)
            bumpBoard(id, "archived", nil)
            return (200, ["deleted": true, "task_id": id])
        case ("PATCH", ""):
            if let to = payload["status"] as? String, !to.isEmpty {
                if to == "running" { return (409, ["detail": "status 'running' is set by the dispatcher when a worker claims the task"]) }
                let from = board[i]["status"] as? String ?? ""
                board[i]["status"] = to
                if to == "done" {
                    board[i]["completed_at"] = Int(now())
                    if let result = payload["result"] { board[i]["result"] = result }
                    else if let summary = payload["summary"] { board[i]["result"] = summary }
                }
                if to != "running" { board[i]["worker_pid"] = NSNull(); board[i]["current_run_id"] = NSNull(); board[i]["claim_lock"] = NSNull() }
                bumpBoard(id, "status", ["from": from, "to": to])
            }
            for k in ["assignee", "title", "body", "priority"] where payload[k] != nil { board[i][k] = payload[k] }
            if let s = payload["summary"] { board[i]["latest_summary"] = s }
            bumpBoard(id, "edited", nil)
            return (200, ["task": board[i]])
        case ("POST", "comments"):
            board[i]["comment_count"] = (board[i]["comment_count"] as? Int ?? 0) + 1
            bumpBoard(id, "commented", ["author": "vory"])
            return (200, ["ok": true])
        case ("POST", "reassign"):
            board[i]["assignee"] = payload["profile"] ?? NSNull()
            bumpBoard(id, "edited", ["assignee": payload["profile"] ?? NSNull()])
            return (200, ["ok": true, "task_id": id, "assignee": payload["profile"] ?? NSNull()])
        case ("POST", "reclaim"):
            guard board[i]["status"] as? String == "running" else { return (409, ["detail": "cannot reclaim \(id): not running"]) }
            board[i]["status"] = "ready"; board[i]["worker_pid"] = NSNull(); board[i]["current_run_id"] = NSNull()
            bumpBoard(id, "reclaimed", ["reason": "reclaimed from Vory"])
            return (200, ["ok": true, "task_id": id])
        default:
            return nil
        }
    }

    /// A board change, told to the board's event sockets as the plugin's stream does.
    func bumpBoard(_ id: String, _ kind: String, _ payload: [String: Any]?) {
        boardCursor += 1
        let frame: [String: Any] = ["events": [["id": boardCursor, "task_id": id, "run_id": NSNull(), "kind": kind,
                                                "payload": payload ?? NSNull(), "created_at": Int(now())]], "cursor": boardCursor]
        let t = Self.text(frame)
        for s in boardSockets.values where !s.isClosed { s.push(t) }
    }

    // MARK: Uploads

    static func uploaded(body: Data, contentType: String, payload: [String: Any]) -> (String, Data) {
        if let name = payload["path"] as? String ?? payload["name"] as? String, let b64 = payload["content"] as? String ?? payload["data"] as? String,
           let data = Data(base64Encoded: b64) {
            return (name, data)
        }
        // multipart/form-data: the file part's name and bytes.
        guard let boundary = contentType.components(separatedBy: "boundary=").last, contentType.contains("multipart") else { return ("upload.bin", body) }
        let marker = Data(("--" + boundary).utf8)
        var name = "upload.bin", file = Data()
        var rest = body[...]
        while let r = rest.range(of: marker) {
            let part = rest[rest.startIndex..<r.lowerBound]
            rest = rest[r.upperBound...]
            guard let split = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: part[part.startIndex..<split.lowerBound], as: UTF8.self)
            guard head.contains("filename=") else { continue }
            if let f = head.components(separatedBy: "filename=\"").last?.components(separatedBy: "\"").first { name = f }
            file = Data(part[split.upperBound...].dropLast(2))
        }
        return (name, file)
    }

    static func mime(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "pdf": return "application/pdf"
        case "md": return "text/markdown"
        case "csv": return "text/csv"
        case "txt", "log": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}
