import Foundation
import os

/// The demo's gateway (#392): a scripted Hermes gateway that runs inside the app, with no server and no
/// network. Vory reaches it through `GatewayTransport.demo`, so the same API client, socket and screens run as
/// for a real gateway; it answers the same wire format the mock gateway (Tools/mock-gateway) does, for what the
/// demo shows. Its words are in `DemoContent`. Everything it holds is in memory and goes with it.
public actor DemoGateway {
    /// The host only the demo's transport answers for. `.invalid` never resolves.
    public static let host = "demo.invalid"

    /// How fast a reply streams: as a real bot does, for reviewers and "Try a demo", or quicker for the tour.
    public enum Pace: Sendable { case real, quick }
    public let pace: Pace
    /// The answers the demo's one approval offers, in the order the card shows them: all four for "Try a demo", only
    /// Allow once and Deny for the onboarding tour's card (#388, Matt's pick), which passes `["once", "deny"]`.
    public static let allApprovalChoices = ["once", "session", "always", "deny"]
    public let approvalChoices: [String]
    /// When the demo started: the chats' times count back from here.
    let started: Double
    let version = "0.21.4"

    // MARK: State

    struct Stored {
        var id: String
        var title: String
        var bot: String
        var preview: String
        var source: String
        var cwd: String
        var pinned: Bool
        var startedAt: Double
        var lastActive: Double
        var archived = false
    }

    final class Live {
        let sid: String
        let stored: String
        var title: String
        var bot: String
        var history: [[String: Any]]
        var running = false
        var turnStartedAt: Double = 0
        var inflight: [String: Any]?
        var outputTokens = 0
        /// Requests to the app still open (an approval): their frames, by id, replayed on a resume.
        var openRequests: [String: [String: Any]] = [:]
        init(sid: String, stored: String, title: String, bot: String, history: [[String: Any]]) {
            self.sid = sid; self.stored = stored; self.title = title; self.bot = bot; self.history = history
        }
    }

    var stored: [Stored]
    /// Chats a socket has opened, by their runtime id.
    var live: [String: Live] = [:]
    var projects: [[String: Any]]
    var activeProject: String?
    var rooms: [[String: Any]] = []
    var roomLogs: [String: [[String: Any]]] = [:]
    var board: [[String: Any]]
    var boardCursor = 100
    /// Scheduled tasks made in the demo (`cronRoute`): none at first, gone when the demo ends.
    var cronJobs: [[String: Any]] = []
    var uploads: [String: (mime: String, data: Data)] = [:]
    /// The app's sockets: the gateway's, and the board's events.
    var sockets: [ObjectIdentifier: DemoSocketPipe] = [:]
    var boardSockets: [ObjectIdentifier: DemoSocketPipe] = [:]
    /// Answers the app owes to requests the gateway sent it (an approval's choice), by request id.
    var waiting: [String: CheckedContinuation<String?, Never>] = [:]
    var sent = 0
    var rng = DemoRandom(seed: 392)
    /// The demo asks for one approval, once (`approvalDue`).
    var approvalAsked = false
    #if DEBUG
    /// What the demo answered without having it (`trip`), in the order it was first asked for.
    private(set) var tripwire: [String] = []
    #endif
    static let log = Logger(subsystem: "Vory", category: "demo")

    public init(pace: Pace = .real, approvalChoices: [String] = DemoGateway.allApprovalChoices, now: Date = Date()) {
        self.pace = pace
        self.approvalChoices = approvalChoices
        let t = now.timeIntervalSince1970
        started = t
        stored = DemoContent.chats.map {
            Stored(id: $0.id, title: $0.title, bot: $0.bot, preview: $0.preview, source: $0.source, cwd: $0.cwd,
                   pinned: $0.pinned, startedAt: t - $0.started, lastActive: t - $0.active)
        }
        projects = DemoContent.projects.map { p in
            ["id": p.id, "slug": p.slug, "name": p.name, "description": NSNull(), "icon": p.icon ?? NSNull(), "color": p.color,
             "board_slug": NSNull(), "primary_path": p.path, "archived": false, "created_at": Int(t - p.age),
             "folders": [["path": p.path, "label": NSNull(), "is_primary": true, "added_at": Int(t - p.age)]]]
        }
        board = DemoContent.tasks.map { DemoGateway.boardTask($0, now: t) }
        let room = "room-weekend"
        rooms = [["room_id": room, "name": DemoContent.groupName,
                  "members": DemoContent.groupMembers.enumerated().map { i, bot -> [String: Any] in
                      ["member_id": "m\(i + 1)", "profile": bot, "handle": bot,
                       "display_name": DemoContent.bots.first { $0.name == bot }?.display ?? bot] },
                  "updated_at": t - (DemoContent.groupLog.last?.ago ?? 0), "disbanded_at": NSNull(),
                  "latest_seq": DemoContent.groupLog.count]]
        roomLogs[room] = DemoContent.groupLog.enumerated().map { i, line -> [String: Any] in
            let member = DemoContent.groupMembers.firstIndex(of: line.who).map { "m\($0 + 1)" }
            return ["room_id": room, "seq": i + 1, "event_id": "evt-demo\(i + 1)",
                    "kind": member == nil ? "message.user" : "message.member",
                    "actor": member.map { ["kind": "member", "id": $0] } ?? ["kind": "user", "id": "user"],
                    "payload": ["text": line.text, "thread_id": "main", "member_id": orNull(member)],
                    "created_at": t - line.ago]
        }
    }

    // MARK: Wire

    static func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
    }
    static func text(_ value: Any) -> String { String(decoding: json(value), as: UTF8.self) }

    func event(_ kind: String, _ sid: String, _ payload: [String: Any]? = nil) {
        var params: [String: Any] = ["type": kind, "session_id": sid]
        if let payload { params["payload"] = payload }
        broadcast(["jsonrpc": "2.0", "method": "event", "params": params])
    }

    func broadcast(_ frame: [String: Any]) {
        let t = Self.text(frame)
        for s in sockets.values where !s.isClosed { s.push(t) }
    }

    // MARK: Sockets

    func attach(_ pipe: DemoSocketPipe) {
        if pipe.path.hasSuffix("/kanban/events") {
            boardSockets[ObjectIdentifier(pipe)] = pipe
            return
        }
        sockets[ObjectIdentifier(pipe)] = pipe
        pipe.push(Self.text(["jsonrpc": "2.0", "method": "event", "params": [
            "type": "gateway.ready", "session_id": "",
            "payload": ["skin": ["name": "default", "description": "", "colors": [:], "light_colors": [:], "dark_colors": [:],
                                 "branding": [:], "banner_logo": "", "banner_hero": "", "tool_prefix": "", "help_header": ""],
                        "change_events": true, "replay_epoch": "demo", "heartbeat": true]]]))
    }

    func detach(_ pipe: DemoSocketPipe) {
        sockets[ObjectIdentifier(pipe)] = nil
        boardSockets[ObjectIdentifier(pipe)] = nil
    }

    func receive(_ text: String, from pipe: DemoSocketPipe) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            // An answer to a request this gateway sent (an approval).
            if let id = msg["id"] as? String, msg["result"] != nil || msg["error"] != nil {
                answered(id, msg["result"] as? [String: Any])
                continue
            }
            guard let method = msg["method"] as? String else { continue }
            let id = msg["id"] ?? NSNull()
            let params = msg["params"] as? [String: Any] ?? [:]
            let reply: [String: Any]
            switch rpc(method, params) {
            case .success(let result): reply = ["jsonrpc": "2.0", "id": id, "result": result]
            case .failure(let e): reply = ["jsonrpc": "2.0", "id": id, "error": ["code": e.code, "message": e.message]]
            }
            pipe.push(Self.text(reply))
        }
    }

    /// The app's answer to a request this gateway sent it; the turn that asked goes on.
    func answered(_ id: String, _ result: [String: Any]?) {
        for l in live.values { l.openRequests[id] = nil }
        waiting.removeValue(forKey: id)?.resume(returning: result?["choice"] as? String)
    }

    // MARK: Shapes

    func bot(_ name: String) -> DemoContent.Bot? { DemoContent.bots.first { $0.name == name } }

    func usage(_ output: Int, calls: Int = 1) -> [String: Any] {
        let used = 18_400 + output * 4
        let max = DemoContent.contextMax
        return ["model": DemoContent.model, "input": 17_900, "output": output, "reasoning": 0, "total": 17_900 + output,
                "calls": calls, "compressions": 0, "context_used": used, "context_max": max,
                "context_percent": used * 100 / max, "context_source": "models.dev", "context_estimated": false,
                "cache_hit_pct": 62, "cache_read": 11_040, "cache_write": 6_860, "avg_tps": 48.2,
                "cost_usd": 0.0231, "cost_status": "estimated"]
    }

    func info(_ title: String, running: Bool, bot: String, cwd: String) -> [String: Any] {
        ["model": DemoContent.model, "provider": DemoContent.provider, "reasoning_effort": "medium",
         "reasoning_effort_wire": "medium", "service_tier": "", "fast": false, "yolo": false, "approval_mode": "smart",
         "tools": [:], "skills": [:], "cwd": cwd, "branch": "main", "terminal_backend": "local", "personality": "",
         "running": running, "title": title, "stored_session_id": "", "version": version, "release_date": "",
         "update_command": "", "usage": usage(0, calls: 0), "profile_name": bot, "mcp_servers": [], "lazy": false]
    }

    func row(_ s: Stored) -> [String: Any] {
        ["id": s.id, "title": s.title, "preview": s.preview, "source": s.source, "model": DemoContent.model,
         "started_at": s.startedAt, "last_active": s.lastActive, "message_count": messageCount(s.id),
         "is_active": live.values.contains { $0.stored == s.id && $0.running }, "archived": s.archived, "pinned": s.pinned,
         "profile": s.bot, "cwd": s.cwd]
    }

    func messageCount(_ id: String) -> Int {
        if let l = live.values.first(where: { $0.stored == id }) { return l.history.count }
        return DemoContent.chats.first { $0.id == id }?.rows().count ?? 0
    }

    /// A chat's rows as `session.resume` lists them, its times counted back from the start of the demo.
    func history(of s: Stored) -> [[String: Any]] {
        guard let chat = DemoContent.chats.first(where: { $0.id == s.id }) else { return [] }
        let rows = chat.rows()
        let span = s.lastActive - s.startedAt
        let last = rows.last?.at ?? 0
        return rows.enumerated().map { i, r in
            // The last row lands on the chat's last activity; the rest keep their spacing.
            let at = s.startedAt + (last > 0 ? min(r.at, last) / last * span : 0)
            var m: [String: Any] = ["role": r.role, "text": r.text, "timestamp": at, "row_id": i + 1]
            if r.role == "tool" {
                m["name"] = r.name ?? "tool"
                m["context"] = r.context ?? ""
            }
            if let reasoning = r.reasoning { m["reasoning"] = reasoning }
            return m
        }
    }

    func openLive(_ id: String) -> Live? {
        if let l = live.values.first(where: { $0.stored == id || $0.sid == id }) { return l }
        guard let s = stored.first(where: { $0.id == id }) else { return nil }
        sent += 1
        let l = Live(sid: "demo\(sent)", stored: s.id, title: s.title, bot: s.bot, history: history(of: s))
        live[l.sid] = l
        return l
    }

    func now() -> Double { Date().timeIntervalSince1970 }

    struct RPCError: Error { let code: Int; let message: String }
}

/// A value for the wire, or JSON's null.
func orNull(_ value: Any?) -> Any { value ?? NSNull() }

// MARK: - JSON-RPC

extension DemoGateway {
    func rpc(_ method: String, _ p: [String: Any]) -> Result<Any, RPCError> {
        let profile = p["profile"] as? String ?? "default"
        switch method {
        case "ping":
            return .success(["pong": true])
        case "profiles.list":
            return .success(["profiles": DemoContent.bots.map { b -> [String: Any] in
                var r: [String: Any] = ["name": b.name, "is_default": b.name == "default"]
                if b.name == "gizmo" {
                    r["canonical_session"] = ["id": DemoContent.botChatID, "resolved_id": DemoContent.botChatID, "title": "Bot Chat",
                                              "message_count": messageCount(DemoContent.botChatID)]
                }
                return r
            }])
        case "session.active_list":
            return .success(["sessions": live.values.map { l in
                ["id": l.sid, "session_key": l.stored, "title": l.title, "source": "ios",
                 "status": l.running ? "streaming" : "idle", "current": false] as [String: Any] }])
        case "session.list":
            return .success(["sessions": stored.filter { !$0.archived }.map { s in
                ["id": s.id, "title": s.title, "preview": s.preview, "started_at": s.startedAt,
                 "message_count": messageCount(s.id), "source": s.source] as [String: Any] }])
        case "client.capabilities":
            return .success(["server_requests": ["approval", "clarify", "sudo", "secret"]])
        case "gateway.capabilities":
            return .success(["per_session_exclusive_submit": true])
        case "groups.capabilities":
            return .success(["protocol_version": 1, "driver": true, "methods": ["groups.list", "groups.create", "groups.send", "groups.log"]])
        case "groups.list":
            return .success(["rooms": rooms, "next_offset": NSNull()])
        case "groups.log":
            let log = roomLogs[p["room_id"] as? String ?? ""] ?? []
            let since = (p["since_seq"] as? Int) ?? Int(p["since_seq"] as? String ?? "") ?? 0
            let events = log.filter { ($0["seq"] as? Int ?? 0) > since }
            return .success(["events": events, "cursor": events.last?["seq"] ?? since, "latest_seq": log.count, "has_more": false])
        case "config.get":
            if p["key"] as? String == "profile" { return .success(["home": DemoContent.home, "display": profile]) }
            if p["key"] as? String == "project" { return .success(["cwd": p["cwd"] ?? DemoContent.home, "branch": NSNull()]) }
            return .success(["value": "", "config": config])
        case "session.create":
            sent += 1
            let sid = "demo\(sent)"
            let id = "demo_\(Int(now()))_\(sent)"
            let cwd = p["cwd"] as? String ?? DemoContent.home
            stored.insert(Stored(id: id, title: "New chat", bot: profile, preview: "", source: "ios", cwd: cwd, pinned: false,
                                 startedAt: now(), lastActive: now()), at: 0)
            let l = Live(sid: sid, stored: id, title: "New chat", bot: profile, history: [])
            live[sid] = l
            return .success(["session_id": sid, "stored_session_id": id, "message_count": 0, "messages": [],
                             "info": info("New chat", running: false, bot: profile, cwd: cwd)])
        case "session.resume", "session.activate":
            guard let l = openLive(p["session_id"] as? String ?? "") else { return .failure(RPCError(code: 4007, message: "session not found")) }
            let cwd = stored.first { $0.id == l.stored }?.cwd ?? DemoContent.home
            var result: [String: Any] = [
                "session_id": l.sid, "stored_session_id": l.stored, "message_count": l.history.count,
                "messages": p["omit_messages"] as? Bool == true ? [] : l.history,
                "info": info(l.title, running: l.running, bot: l.bot, cwd: cwd), "running": l.running,
                "open_requests": l.openRequests.values.map { ["id": $0["id"] ?? "", "method": $0["method"] ?? "", "params": $0["params"] ?? [:]] },
                "resumed": l.stored, "turn_started_at": l.running ? l.turnStartedAt : NSNull()]
            if let inflight = l.inflight { result["inflight"] = inflight }
            return .success(result)
        case "session.usage":
            return .success(usage(live[p["session_id"] as? String ?? ""]?.outputTokens ?? 0))
        case "session.context_breakdown":
            let used = usage(live[p["session_id"] as? String ?? ""]?.outputTokens ?? 0)["context_used"] as? Int ?? 0
            let max = DemoContent.contextMax
            return .success(["categories": [
                ["id": "system", "label": "System prompt", "tokens": 4_820, "color": "blue"],
                ["id": "tools", "label": "Tools", "tokens": 6_140, "color": "purple"],
                ["id": "skills", "label": "Skills", "tokens": 2_260, "color": "teal"],
                ["id": "memory", "label": "Memory", "tokens": 1_180, "color": "green"],
                ["id": "conversation", "label": "Conversation", "tokens": Swift.max(0, used - 14_400), "color": "orange"],
                ["id": "free", "label": "Free", "tokens": max - used, "color": "gray"]],
                "context_max": max, "context_percent": used * 100 / max, "context_used": used, "estimated_total": used,
                "context_estimated": false, "context_source": "models.dev", "model": DemoContent.model, "context_files": []])
        case "session.title":
            guard let l = live[p["session_id"] as? String ?? ""], let title = p["title"] as? String, !title.isEmpty else {
                return .success(["title": live[p["session_id"] as? String ?? ""]?.title ?? ""])
            }
            l.title = title
            if let i = stored.firstIndex(where: { $0.id == l.stored }) { stored[i].title = title }
            event("session.title", l.sid, ["session_id": l.stored, "title": title])
            return .success(["title": title])
        case "projects.list":
            return .success(["projects": projects, "active_id": orNull(activeProject)])
        case "projects.get":
            guard let pr = project(p["id"] as? String) else { return .failure(RPCError(code: 5062, message: "no such project")) }
            return .success(["project": pr])
        case "projects.tree":
            var nodes: [[String: Any]] = [["id": "__no_project__", "label": "Home", "isAuto": false, "isNoProject": true, "sessionCount": 0, "sessionIds": []]]
            var placed = Set<String>()
            for pr in projects where pr["archived"] as? Bool != true {
                let paths = (pr["folders"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                let ids = stored.filter { s in paths.contains { s.cwd.hasPrefix($0) } }.map(\.id)
                placed.formUnion(ids)
                nodes.append(["id": pr["id"] ?? "", "label": pr["name"] ?? "", "path": pr["primary_path"] ?? "", "color": pr["color"] ?? "",
                              "isAuto": false, "isNoProject": false, "sessionCount": ids.count, "sessionIds": ids])
            }
            let rest = stored.map(\.id).filter { !placed.contains($0) }
            nodes[0]["sessionIds"] = rest
            nodes[0]["sessionCount"] = rest.count
            return .success(["projects": nodes, "active_id": orNull(activeProject), "scoped_session_ids": []])
        case "commands.catalog":
            return .success(commandCatalog)
        case "slash.exec":
            let command = (p["command"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let name = command.split(separator: " ").first.map(String.init) ?? ""
            if name == "usage" {
                return .success(["output": "Session Token Usage\n  input   12,480\n  output   3,112\n  cache    9,004\n  context  21.3k / 200k (10.6%)"])
            }
            if DemoContent.skills.contains(where: { $0.name == name }) {
                return .failure(RPCError(code: 4018, message: "skill command: use command.dispatch for /\(name)"))
            }
            return .success(["output": "/\(command) ran on the demo gateway.", "warning": ""])
        case "command.dispatch":
            return .success(["type": "exec", "output": "/\(p["name"] as? String ?? "") ran on the demo gateway."])
        case "session.interrupt":
            return .success(["status": "interrupted", "interrupted": true])
        case "session.undo":
            // As Hermes does: the last user turn and everything after it leave the history, never while a turn runs
            // (Edit & resend, #556).
            guard let l = live[p["session_id"] as? String ?? ""] else { return .failure(RPCError(code: 4007, message: "session not found")) }
            if l.running { return .failure(RPCError(code: 4009, message: "session busy: stop the reply before undo")) }
            guard let cut = l.history.lastIndex(where: { $0["role"] as? String == "user" }) else { return .success(["removed": 0]) }
            let removed = l.history.count - cut
            l.history.removeSubrange(cut...)
            return .success(["removed": removed])
        case "config.set":
            let l = live[p["session_id"] as? String ?? ""]
            var i = info(l?.title ?? "", running: false, bot: l?.bot ?? profile, cwd: DemoContent.home)
            if p["key"] as? String == "model", let words = (p["value"] as? String)?.split(separator: " "), let first = words.first, !first.hasPrefix("--") {
                i["model"] = String(first)
            }
            return .success(["key": p["key"] ?? "", "value": "\(p["value"] ?? "")", "info": i])
        case "session.close":
            return .success(["closed": true, "deleted": p["session_id"] ?? ""])
        case "approval.pending":
            let l = live[p["session_id"] as? String ?? ""] ?? live.values.first { $0.stored == p["session_id"] as? String }
            let frames = l.map { Array($0.openRequests.values) } ?? []
            return .success(["approvals": frames.compactMap { f -> [String: Any]? in
                guard f["method"] as? String == "approval", let params = f["params"] as? [String: Any] else { return nil }
                return params }])
        case "approval.received":
            return .success(["acknowledged": true])
        default:
            if let reply = liveRPC(method, p, profile: profile) { return reply }
            trip("rpc \(method)")
            return .failure(RPCError(code: -32601, message: "unknown method: \(method)"))
        }
    }

    func project(_ id: String?) -> [String: Any]? {
        projects.first { $0["id"] as? String == id || $0["slug"] as? String == id }
    }

    var config: [String: Any] {
        ["model": DemoContent.model, "approvals": ["mode": "smart", "timeout": 300, "cron_mode": "deny"],
         "agent": ["reasoning_effort": "medium", "max_iterations": 40],
         "display": ["streaming": true, "show_reasoning": true, "timestamps": false],
         "logging": ["level": "INFO"], "terminal": ["backend": "local"]]
    }

    var commandCatalog: [String: Any] {
        var pairs: [[String]] = [["new", "Start a new chat"], ["model", "Switch the model"], ["compress", "Compress the context"],
                                 ["status", "Show session status"], ["usage", "Show token usage"], ["agents", "Show the delegation tree"]]
        pairs += DemoContent.skills.map { [$0.name, $0.description] }
        var skills: [String: Any] = [:]
        for s in DemoContent.skills { skills["/" + s.name] = ["usage": s.usage, "origin": "bundled"] }
        return ["pairs": pairs, "categories": [], "canon": ["/new": "/new", "/reset": "/new", "/compress": "/compress", "/compact": "/compress"],
                "commands": ["/usage": ["argument_mode": "text", "desktop": NSNull()], "/new": ["argument_mode": "text", "desktop": NSNull()],
                             "/model": ["argument_mode": "text", "desktop": "hidden"], "/compress": ["argument_mode": "text", "desktop": NSNull()],
                             "/status": ["argument_mode": NSNull(), "desktop": NSNull()], "/agents": ["argument_mode": NSNull(), "desktop": NSNull()]],
                "skills": skills, "skill_count": DemoContent.skills.count, "warning": ""]
    }
}

// MARK: - REST

extension DemoGateway {
    struct HTTPAnswer: Sendable {
        var status: Int
        var body: Data
        var contentType: String
        var headers: [String: String] = [:]
    }

    static let pictureTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    func rest(method: String, url: URL, body: Data, contentType: String) -> HTTPAnswer {
        let path = url.path
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        // The Files page's open, share and save (FilesView): the file's own bytes, not JSON.
        if method == "GET", path == "/api/files/download" { return download(query["path"] ?? "") }
        // What a route allows (the app asks before it offers a bot's rename): reads only. The demo's bots can't be
        // renamed, as a rename moves this device's own looks and names for the bot to the new name.
        if method == "OPTIONS" { return HTTPAnswer(status: 200, body: Data(), contentType: "text/plain", headers: ["Allow": "GET"]) }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let (status, value) = route(method: method, path: path, query: query, payload: payload, body: body, contentType: contentType)
        return HTTPAnswer(status: status, body: Self.json(value), contentType: "application/json")
    }

    func route(method: String, path: String, query: [String: String], payload: [String: Any], body: Data, contentType: String) -> (Int, Any) {
        if path.hasPrefix("/api/plugins/kanban") { return boardRoute(method: method, path: path, query: query, payload: payload) }
        if path.hasPrefix("/api/cron/"), let answer = cronRoute(method: method, path: path, query: query, payload: payload) { return answer }
        if method != "GET", let answer = liveRoute(method: method, path: path, query: query, payload: payload, body: body, contentType: contentType) {
            return answer
        }
        switch path {
        case "/api/status":
            return (200, ["version": version, "gateway": ["status": "running", "pid": 4242], "gateway_running": true,
                          "gateway_state": "running", "active_sessions": live.values.filter(\.running).count,
                          "auth_required": false, "auth_providers": [], "auth_flows": [],
                          "memory": ["pressure": "ok", "gateway_rss_mb": 312, "system_available_mb": 9200],
                          "disk": ["pressure": "ok", "free_mb": 184_320, "total_mb": 494_384, "used_percent": 41]])
        case "/api/health":
            return (200, ["ok": true, "version": version, "auth_required": false])
        case "/api/auth/providers":
            return (200, ["providers": []])
        case "/api/profiles":
            return (200, ["profiles": DemoContent.bots.map { b in
                ["name": b.name, "path": b.name == "default" ? "\(DemoContent.home)/.hermes" : "\(DemoContent.home)/.hermes-\(b.name)",
                 "is_default": b.name == "default", "description": b.title, "skill_count": b.skills, "model": DemoContent.model,
                 "provider": DemoContent.provider, "has_env": true, "display_name": b.display] as [String: Any] }])
        case "/api/profiles/active":
            return (200, ["active": "default", "current": "default"])
        case "/api/sessions":
            // Archived chats as Hermes lists them (#474): left out unless asked for, `archived=only` for them alone,
            // `archived=include` for both, marked.
            let rows: [[String: Any]]
            switch query["archived"] ?? "exclude" {
            case "only": rows = stored.filter(\.archived).map(row)
            case "include": rows = stored.map(row)
            default: rows = stored.filter { !$0.archived }.map(row)
            }
            return (200, ["sessions": rows, "total": rows.count, "limit": 100, "offset": 0])
        case "/api/sessions/search":
            let q = (query["q"] ?? "").lowercased()
            return (200, ["sessions": stored.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.preview.lowercased().contains(q) }.map(row)])
        case "/api/sessions/stats":
            var by: [String: Int] = [:]
            for s in stored { by[s.source, default: 0] += 1 }
            return (200, ["total": stored.count, "active_store": stored.count, "archived": stored.filter(\.archived).count,
                          "messages": stored.reduce(0) { $0 + messageCount($1.id) }, "by_source": by])
        case "/api/model/options":
            return (200, ["model": DemoContent.model, "provider": DemoContent.provider, "providers": [
                ["slug": DemoContent.provider, "name": "Demo", "authenticated": true, "is_current": true,
                 "featured_models": [DemoContent.model, DemoContent.fastModel], "models": [DemoContent.model, DemoContent.fastModel],
                 "capabilities": [DemoContent.model: ["fast": true, "reasoning": true, "can_disable_reasoning": true]]]]])
        case "/api/model/auxiliary":
            return (200, ["main": ["provider": DemoContent.provider, "model": DemoContent.model], "tasks": [
                ["task": "titles", "provider": "auto", "model": "", "base_url": "", "local_endpoint": false]]])
        case "/api/config":
            return (200, ["config": config])
        case "/api/config/schema":
            return (200, ["fields": [
                "model": ["type": "string", "description": "Default model", "category": "general"],
                "approvals.mode": ["type": "select", "description": "Dangerous command approval mode", "category": "security", "options": ["manual", "smart", "off"]],
                "display.show_reasoning": ["type": "boolean", "description": "Show the model's reasoning blocks", "category": "display"]],
                "category_order": ["general", "display", "security"]])
        case "/api/analytics/usage":
            return (200, analytics(days: Int(query["days"] ?? "") ?? 30))
        case "/api/skills":
            return (200, DemoContent.skills.map { ["name": $0.name, "description": $0.description, "category": $0.category, "enabled": true,
                                                   "usage": $0.usage, "provenance": "bundled"] as [String: Any] })
        case "/api/tools/toolsets":
            return (200, [
                ["name": "web", "label": "Web Search", "description": "web_search, web_extract", "platform": "cli", "enabled": true, "configured": true, "tools": ["web_extract", "web_search"]],
                ["name": "terminal", "label": "Terminal", "description": "terminal, process", "platform": "cli", "enabled": true, "configured": true, "tools": ["terminal"]],
                ["name": "files", "label": "File Operations", "description": "read, write, patch, search", "platform": "cli", "enabled": true, "configured": true, "tools": ["patch", "read_file", "search_files", "write_file"]],
            ] as [[String: Any]])
        case "/api/mcp/servers":
            return (200, ["servers": []])
        case "/api/env":
            return (200, [:] as [String: Any])
        case "/api/messaging/platforms":
            return (200, ["platforms": []])
        case "/api/logs":
            return (200, ["lines": []])
        case "/api/hermes/update/check":
            return (200, ["install_method": "git", "current_version": version, "behind": 0, "update_available": false,
                          "can_apply": false, "update_command": "", "message": NSNull(), "commits": []])
        case "/api/dashboard/plugins/hub":
            return (200, ["plugins": [["name": "kanban", "version": "0.4.2", "description": "A board of the agent's tasks.", "source": "bundled",
                                       "runtime_status": "bundled", "has_dashboard_manifest": true, "path": "/opt/hermes/plugins/kanban",
                                       "can_remove": false, "can_update_git": false, "auth_required": false, "user_hidden": false]],
                          "orphan_dashboard_plugins": [], "providers": ["memory_provider": "", "memory_options": [], "context_engine": "default", "context_options": []]])
        case "/api/media":
            guard let png = DemoImage.png(for: query["path"] ?? "") else { return (415, ["detail": "Unsupported media type"]) }
            let ext = ((query["path"] ?? "") as NSString).pathExtension.lowercased()
            guard Self.pictureTypes.contains(ext) else { return (415, ["detail": "Unsupported media type"]) }
            return (200, ["data_url": "data:image/png;base64," + png.base64EncodedString()])
        case "/api/files":
            return (200, listing(query["path"]))
        case "/api/files/read":
            return readFile(query["path"] ?? "")
        default:
            break
        }
        let parts = path.split(separator: "/").map(String.init)
        // /api/profiles/<name>/soul
        if parts.count == 4, parts[1] == "profiles", parts[3] == "soul" {
            let b = bot(parts[2])
            return (200, ["content": "# \(b?.display ?? parts[2])\n\nYou help with \(b?.title.lowercased() ?? "everyday things"). Be brief, ask before changing anything, and say what you changed.", "exists": true])
        }
        // A chat's mutation snapshot, which the app asks for before a delete, pin or archive (#467): the demo answers as a
        // Hermes from before the fence does, so the edit goes as it always went (taken by `liveRoute`) with no revision.
        if parts.count == 4, parts[1] == "sessions", parts[3] == "mutation-snapshot" { return (404, ["detail": "Not Found"]) }
        // /api/sessions/<id> and /api/sessions/<id>/messages
        if parts.count >= 3, parts[1] == "sessions", let s = stored.first(where: { $0.id == parts[2] }) {
            if parts.count == 4, parts[3] == "messages" {
                let iso = ISO8601DateFormatter()
                let rows = (live.values.first { $0.stored == s.id }?.history ?? history(of: s))
                let messages = rows.suffix(Int(query["limit"] ?? "") ?? 60).map { m -> [String: Any] in
                    var r: [String: Any] = ["id": m["row_id"] ?? 0, "role": m["role"] ?? "user", "content": m["text"] ?? "",
                                            "timestamp": iso.string(from: Date(timeIntervalSince1970: m["timestamp"] as? Double ?? started))]
                    if m["role"] as? String == "tool" { r["tool_name"] = m["name"] ?? "tool" }
                    return r
                }
                return (200, ["session_id": s.id, "profile": s.bot, "messages": Array(messages),
                              "pagination": ["limit": 60, "offset": 0, "order": "latest", "returned": messages.count]])
            }
            if parts.count == 3 {
                let asked = query["profile"] ?? "default"
                guard asked == s.bot else { return (404, ["detail": "session not found"]) }
                var r = row(s)
                r["is_default_profile"] = asked == "default"
                return (200, r)
            }
        }
        if path.hasPrefix("/api/audio/") { return (200, ["available": false, "configured": false]) }
        trip("\(method) \(path)")
        if path.hasPrefix("/api/") { return (200, [:] as [String: Any]) }
        return (404, ["detail": "Not found"])
    }

    /// A route, socket method or board route the demo doesn't have, which a page asked for: in a Debug build it is
    /// logged once ("demo tripwire", subsystem Vory, category demo) and kept in `tripwire`, so a tour of the pages lists
    /// what the demo is missing instead of a page quietly getting an empty answer. Nothing in a Release build.
    func trip(_ what: String) {
        #if DEBUG
        guard !tripwire.contains(what) else { return }
        tripwire.append(what)
        Self.log.error("demo tripwire: \(what, privacy: .public)")
        #endif
    }

    /// Home's numbers: a day's use from the demo's own chats, with a believable spread and quieter Sundays.
    func analytics(days: Int) -> [String: Any] {
        var r = DemoRandom(seed: 7)
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date(timeIntervalSince1970: started))
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        var daily: [[String: Any]] = []
        for i in stride(from: days - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
            let roll = r.unit()
            if cal.component(.weekday, from: d) == 1, roll < 0.6 { continue }
            let n = r.int(1...6)
            let input = n * r.int(9_000...40_000), output = n * r.int(1_500...6_000)
            daily.append(["day": fmt.string(from: d), "input_tokens": input, "output_tokens": output,
                          "cache_read_tokens": n * r.int(40_000...120_000), "reasoning_tokens": 0,
                          "estimated_cost": Double(n) * 0.31, "actual_cost": 0, "sessions": n, "api_calls": n * r.int(4...15)])
        }
        func total(_ k: String) -> Double { daily.reduce(0) { $0 + (($1[k] as? Int).map(Double.init) ?? ($1[k] as? Double ?? 0)) } }
        return ["daily": daily, "period_days": days,
                "by_model": [["model": DemoContent.model, "input_tokens": Int(total("input_tokens")), "output_tokens": Int(total("output_tokens")),
                              "estimated_cost": total("estimated_cost"), "sessions": Int(total("sessions")), "api_calls": Int(total("api_calls"))]],
                "totals": ["total_input": Int(total("input_tokens")), "total_output": Int(total("output_tokens")),
                           "total_cache_read": Int(total("cache_read_tokens")), "total_reasoning": 0,
                           "total_estimated_cost": total("estimated_cost"), "total_actual_cost": 0,
                           "total_sessions": Int(total("sessions")), "total_api_calls": Int(total("api_calls"))],
                "skills": [:], "tools": [:]]
    }

    func listing(_ path: String?) -> [String: Any] {
        let dir = (path?.isEmpty == false ? path! : DemoContent.home)
        let entries = (DemoContent.files.map { ($0.path, $0.directory, $0.mime, $0.text?.utf8.count, $0.age) }
                       + uploads.map { ($0.key, false, Optional($0.value.mime), Optional($0.value.data.count), 0.0) })
            .filter { ($0.0 as NSString).deletingLastPathComponent == dir }
            .map { path, directory, mime, size, age -> [String: Any] in
                var e: [String: Any] = ["name": (path as NSString).lastPathComponent, "path": path, "is_directory": directory,
                                        "modified_at": started - age]
                if !directory { e["size"] = size ?? 0; e["mime_type"] = mime ?? "application/octet-stream" }
                return e
            }
        let parent: Any = dir == DemoContent.home ? NSNull() : (dir as NSString).deletingLastPathComponent
        return ["path": dir, "parent": parent, "root": NSNull(), "locked_root": NSNull(), "entries": entries]
    }

    /// A file's bytes and media type: a picture drawn by `DemoImage` (always a PNG), a text file of the demo's, or an
    /// upload; nil for a folder or a path the demo doesn't have.
    func file(_ path: String) -> (mime: String, data: Data)? {
        if Self.pictureTypes.contains((path as NSString).pathExtension.lowercased()), let png = DemoImage.png(for: path) {
            return (mime: "image/png", data: png)
        }
        return DemoContent.files.first { $0.path == path && !$0.directory }
            .map { (mime: $0.mime ?? "text/plain", data: Data(($0.text ?? "").utf8)) } ?? uploads[path]
    }

    func readFile(_ path: String) -> (Int, Any) {
        guard let found = file(path) else { return (404, ["detail": "File not found"]) }
        return (200, ["name": (path as NSString).lastPathComponent, "path": path, "size": found.data.count, "mime_type": found.mime,
                      "data_url": "data:\(found.mime);base64," + found.data.base64EncodedString()])
    }

    /// GET /api/files/download, as the gateway's files router sends it: the raw bytes with their media type and an
    /// attachment disposition naming the file. Without it the catch-all's empty object was saved as the file ("{}").
    func download(_ path: String) -> HTTPAnswer {
        guard let found = file(path) else {
            return HTTPAnswer(status: 404, body: Self.json(["detail": "File not found"]), contentType: "application/json")
        }
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: "\"", with: "")
        return HTTPAnswer(status: 200, body: found.data, contentType: found.mime,
                          headers: ["Content-Disposition": "attachment; filename=\"\(name)\""])
    }
}
