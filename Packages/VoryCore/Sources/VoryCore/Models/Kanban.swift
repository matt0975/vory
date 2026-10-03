import Foundation

// MARK: Kanban (the gateway's bundled kanban plugin, /api/plugins/kanban/…)
//
// Hermes keeps a board of tasks for its bots: a task has a title, a body, one assignee (a bot),
// a priority and a status; the dispatcher inside the gateway promotes todo to ready when the
// parents are done, claims ready cards and spawns a worker for each. These are the shapes the
// plugin's dashboard API answers with (plugins/kanban/dashboard/plugin_api.py), as the
// gateway's decoder reads them (snake_case keys).

/// The columns, in the order the board shows them. Archived only when asked for.
public enum KanbanStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case triage, todo, scheduled, ready, running, blocked, review, done, archived

    public static let columns: [KanbanStatus] = [.triage, .todo, .scheduled, .ready, .running, .blocked, .review, .done]

    public var title: String {
        switch self {
        case .triage: return "Triage"
        case .todo: return "To do"
        case .scheduled: return "Scheduled"
        case .ready: return "Ready"
        case .running: return "Running"
        case .blocked: return "Blocked"
        case .review: return "Review"
        case .done: return "Done"
        case .archived: return "Archived"
        }
    }

    public var symbol: String {
        switch self {
        case .triage: return "tray"
        case .todo: return "circle"
        case .scheduled: return "calendar"
        case .ready: return "play.circle"
        case .running: return "bolt.circle"
        case .blocked: return "hand.raised"
        case .review: return "eye"
        case .done: return "checkmark.circle"
        case .archived: return "archivebox"
        }
    }

    /// Where a card can be moved by hand. The other three are the gateway's own doing.
    public var isMoveTarget: Bool { Self.moveTargets.contains(self) }
    public static let moveTargets: [KanbanStatus] = [.triage, .todo, .ready, .blocked, .done, .archived]

    /// Why a status is not a move target, in the server's own terms.
    public var notMovableReason: String? {
        switch self {
        case .running: return "Running is set by the dispatcher when a worker claims the task."
        case .scheduled: return "Scheduled is set when a task is given a time."
        case .review: return "Review is requested by the worker when it hands the task over."
        default: return nil
        }
    }

    /// Moving here asks for a word: the server refuses done without a result or summary
    /// unless the task comes from review.
    public var asksForSummary: Bool { self == .done }
    /// Moving here is a yes/no question first.
    public var asksToConfirm: Bool { self == .archived || self == .blocked }
}

public struct KanbanAge: Codable, Sendable, Hashable {
    public var createdAgeSeconds: Int?
    public var startedAgeSeconds: Int?
    public var timeToCompleteSeconds: Int?
    public init(createdAgeSeconds: Int? = nil, startedAgeSeconds: Int? = nil, timeToCompleteSeconds: Int? = nil) {
        self.createdAgeSeconds = createdAgeSeconds; self.startedAgeSeconds = startedAgeSeconds; self.timeToCompleteSeconds = timeToCompleteSeconds
    }
}

public struct KanbanLinkCounts: Codable, Sendable, Hashable {
    public var parents: Int
    public var children: Int
    public init(parents: Int, children: Int) { self.parents = parents; self.children = children }
}

/// Children done over total, for a parent card.
public struct KanbanProgress: Codable, Sendable, Hashable {
    public var done: Int
    public var total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
}

/// A diagnostic the server attaches to a card (a stuck worker, a breaker trip…). Its exact
/// fields vary by kind; the message is what is shown.
public struct KanbanDiagnostic: Codable, Sendable, Hashable {
    public var code: String?
    public var kind: String?
    public var severity: String?
    public var message: String?
    public var title: String?
    public var text: String { message ?? title ?? code ?? kind ?? "Needs a look" }
}

public struct KanbanTask: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var body: String?
    public var assignee: String?
    public var status: String
    public var priority: Int?
    public var createdBy: String?
    public var createdAt: Int?
    public var startedAt: Int?
    public var completedAt: Int?
    public var tenant: String?
    public var result: String?
    public var workerPid: Int?
    public var lastHeartbeatAt: Int?
    public var currentRunId: Int?
    /// The chat the task was filed from, when a bot made it (NULL from the CLI and the dashboard).
    public var sessionId: String?
    public var blockKind: String?
    public var consecutiveFailures: Int?
    public var lastFailureError: String?
    public var maxRuntimeSeconds: Int?
    public var projectId: String?
    public var workspaceKind: String?
    public var age: KanbanAge?
    /// The latest run's handoff summary (a 200-character preview on the board, whole on the detail).
    public var latestSummary: String?
    public var currentRunStartedAt: Int?
    public var linkCounts: KanbanLinkCounts?
    public var commentCount: Int?
    public var progress: KanbanProgress?
    public var diagnostics: [KanbanDiagnostic]?

    public init(id: String, title: String, status: String, body: String? = nil, assignee: String? = nil, priority: Int? = nil, createdAt: Int? = nil) {
        self.id = id; self.title = title; self.status = status; self.body = body; self.assignee = assignee; self.priority = priority; self.createdAt = createdAt
    }

    public var column: KanbanStatus? { KanbanStatus(rawValue: status) }
    /// A worker is on it right now.
    public var isWorking: Bool { status == KanbanStatus.running.rawValue && (workerPid != nil || currentRunStartedAt != nil || currentRunId != nil) }
    public var warnings: [KanbanDiagnostic] { diagnostics ?? [] }
    /// The one line under the title: the latest summary, else the body's first line.
    public var preview: String? {
        if let s = latestSummary, !s.isEmpty { return s }
        if let b = body?.split(separator: "\n").first, !b.isEmpty { return String(b) }
        return nil
    }
    public var created: Date? { createdAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

public struct KanbanColumn: Codable, Sendable, Hashable {
    public var name: String
    public var tasks: [KanbanTask]
    public init(name: String, tasks: [KanbanTask]) { self.name = name; self.tasks = tasks }
    public var status: KanbanStatus? { KanbanStatus(rawValue: name) }
}

public struct KanbanBoard: Codable, Sendable, Hashable {
    public var columns: [KanbanColumn]
    public var tenants: [String]?
    public var assignees: [String]?
    /// The newest task event's id: where the live socket starts so nothing is replayed.
    public var latestEventId: Int?
    public var now: Int?

    public init(columns: [KanbanColumn], tenants: [String]? = nil, assignees: [String]? = nil, latestEventId: Int? = nil, now: Int? = nil) {
        self.columns = columns; self.tenants = tenants; self.assignees = assignees; self.latestEventId = latestEventId; self.now = now
    }

    public func tasks(in status: KanbanStatus) -> [KanbanTask] { columns.first { $0.name == status.rawValue }?.tasks ?? [] }
    public func count(_ status: KanbanStatus) -> Int { tasks(in: status).count }
    public var allTasks: [KanbanTask] { columns.flatMap(\.tasks) }
    public func task(id: String) -> KanbanTask? { allTasks.first { $0.id == id } }
    /// Cards that need someone: blocked, or carrying a diagnostic.
    public var needsAttention: Int { allTasks.filter { $0.status == KanbanStatus.blocked.rawValue || !$0.warnings.isEmpty }.count }
}

/// One board on disk, as `/boards` lists them.
public struct KanbanBoardMeta: Codable, Sendable, Identifiable, Hashable {
    public var slug: String
    public var name: String?
    public var description: String?
    public var icon: String?
    public var color: String?
    public var isCurrent: Bool?
    public var counts: [String: Int]?
    public var total: Int?
    public var archived: Bool?
    public var projectName: String?
    public var id: String { slug }
    public var displayName: String { (name?.isEmpty == false ? name : nil) ?? slug }
    public init(slug: String, name: String? = nil, isCurrent: Bool? = nil, counts: [String: Int]? = nil, total: Int? = nil) {
        self.slug = slug; self.name = name; self.isCurrent = isCurrent; self.counts = counts; self.total = total
    }
}

public struct KanbanBoards: Codable, Sendable {
    public var boards: [KanbanBoardMeta]
    public var current: String?
    public init(boards: [KanbanBoardMeta], current: String?) { self.boards = boards; self.current = current }
}

public struct KanbanComment: Codable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var taskId: String?
    public var author: String
    public var body: String
    public var createdAt: Int
    public var created: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
}

public struct KanbanEvent: Codable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var taskId: String
    public var runId: Int?
    /// "status", "commented", "blocked", "reclaimed", "edited", "reprioritized"…
    public var kind: String
    public var payload: JSONValue?
    public var createdAt: Int
    public var created: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
    /// The event in a few words for a timeline row.
    public var line: String {
        switch kind {
        case "status":
            if let to = payload?["to"]?.stringValue ?? payload?["status"]?.stringValue { return "Moved to \(KanbanStatus(rawValue: to)?.title ?? to)" }
            return "Status changed"
        case "commented": return "Comment"
        case "blocked": return "Blocked" + (payload?["reason"]?.stringValue.map { ": \($0)" } ?? "")
        case "reclaimed": return "Worker reclaimed"
        case "edited": return "Edited"
        case "reprioritized": return "Priority changed"
        case "review_requested": return "Review requested"
        case "promoted_manual": return "Promoted by hand"
        case "scheduled": return "Scheduled"
        case "archived": return "Archived"
        case "claim_rejected": return "Claim rejected"
        case "attached": return "File attached"
        case "unlinked": return "Link removed"
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// One attempt at a task: opened when a worker claims it, closed when it completes, blocks,
/// crashes, times out or is reclaimed.
public struct KanbanRun: Codable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var taskId: String?
    public var profile: String?
    public var stepKey: String?
    public var status: String?
    public var workerPid: Int?
    public var maxRuntimeSeconds: Int?
    public var lastHeartbeatAt: Int?
    public var startedAt: Int
    public var endedAt: Int?
    public var outcome: String?
    public var summary: String?
    public var error: String?
    public var isOpen: Bool { endedAt == nil }
    public var durationSeconds: Int { (endedAt ?? Int(Date().timeIntervalSince1970)) - startedAt }
    public var started: Date { Date(timeIntervalSince1970: TimeInterval(startedAt)) }
    /// "running", else the outcome ("completed", "blocked", "crashed"…) or the status.
    public var stateText: String { isOpen ? "running" : (outcome ?? status ?? "ended") }
}

public struct KanbanLinks: Codable, Sendable, Hashable {
    public var parents: [String]
    public var children: [String]
}

public struct KanbanChildResult: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var status: String
    public var latestSummary: String?
    public var result: String?
}

public struct KanbanTaskDetail: Codable, Sendable {
    public var task: KanbanTask
    public var comments: [KanbanComment]
    public var events: [KanbanEvent]
    public var runs: [KanbanRun]
    public var links: KanbanLinks?
    public var childResults: [KanbanChildResult]?
    public init(task: KanbanTask, comments: [KanbanComment] = [], events: [KanbanEvent] = [], runs: [KanbanRun] = [], links: KanbanLinks? = nil, childResults: [KanbanChildResult]? = nil) {
        self.task = task; self.comments = comments; self.events = events; self.runs = runs; self.links = links; self.childResults = childResults
    }
    public var currentRun: KanbanRun? { runs.last { $0.isOpen } ?? task.currentRunId.flatMap { id in runs.first { $0.id == id } } }
}

public struct KanbanAssignee: Codable, Sendable, Identifiable, Hashable {
    public var name: String
    public var onDisk: Bool?
    public var counts: [String: Int]?
    public var id: String { name }
}

public struct KanbanAssignees: Codable, Sendable {
    public var assignees: [KanbanAssignee]
}

/// A running worker, as `/workers/active` lists them.
public struct KanbanWorker: Codable, Sendable, Identifiable, Hashable {
    public var runId: Int
    public var taskId: String
    public var taskTitle: String?
    public var taskStatus: String?
    public var taskAssignee: String?
    public var profile: String?
    public var workerPid: Int?
    public var startedAt: Int?
    public var lastHeartbeatAt: Int?
    public var id: Int { runId }
}

public struct KanbanWorkers: Codable, Sendable {
    public var workers: [KanbanWorker]
    public var count: Int?
    public var checkedAt: Int?
}

public struct KanbanLog: Codable, Sendable {
    public var taskId: String?
    public var exists: Bool
    public var content: String
    public var truncated: Bool?
    public var sizeBytes: Int?
}

/// What a write answers with: the task as it now is, and on a create the dispatcher warning
/// ("no gateway is running…") when nothing would pick the task up.
public struct KanbanTaskEnvelope: Codable, Sendable {
    public var task: KanbanTask?
    public var warning: String?
}

public struct KanbanStats: Codable, Sendable {
    public var byStatus: [String: Int]?
    public var byAssignee: [String: [String: Int]]?
}

/// One frame from the `/events` socket: the events since the cursor, and the new cursor.
public struct KanbanEventsFrame: Codable, Sendable, Equatable {
    public var events: [KanbanEvent]
    public var cursor: Int
    public init(events: [KanbanEvent], cursor: Int) { self.events = events; self.cursor = cursor }
}

/// A task to make.
public struct KanbanNewTask: Sendable, Equatable {
    public var title: String
    public var body: String?
    public var assignee: String?
    public var tenant: String?
    public var priority: Int
    public var parents: [String]
    /// Start in triage instead of todo.
    public var triage: Bool
    public init(title: String, body: String? = nil, assignee: String? = nil, tenant: String? = nil, priority: Int = 0, parents: [String] = [], triage: Bool = false) {
        self.title = title; self.body = body; self.assignee = assignee; self.tenant = tenant; self.priority = priority; self.parents = parents; self.triage = triage
    }
    var json: JSONValue {
        var o: [String: JSONValue] = ["title": .string(title), "priority": .number(Double(priority)), "triage": .bool(triage), "parents": .array(parents.map { .string($0) })]
        if let body, !body.isEmpty { o["body"] = .string(body) }
        if let assignee, !assignee.isEmpty { o["assignee"] = .string(assignee) }
        if let tenant, !tenant.isEmpty { o["tenant"] = .string(tenant) }
        return .object(o)
    }
}

/// A change to a task; only the fields set are sent. `status` is a move.
public struct KanbanTaskPatch: Sendable, Equatable {
    public var status: KanbanStatus?
    public var assignee: String??
    public var priority: Int?
    public var title: String?
    public var body: String?
    public var result: String?
    public var summary: String?
    public var blockReason: String?
    public init(status: KanbanStatus? = nil, assignee: String?? = nil, priority: Int? = nil, title: String? = nil, body: String? = nil, result: String? = nil, summary: String? = nil, blockReason: String? = nil) {
        self.status = status; self.assignee = assignee; self.priority = priority; self.title = title; self.body = body; self.result = result; self.summary = summary; self.blockReason = blockReason
    }
    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let status { o["status"] = .string(status.rawValue) }
        if let assignee { o["assignee"] = assignee.map { .string($0) } ?? .null }
        if let priority { o["priority"] = .number(Double(priority)) }
        if let title { o["title"] = .string(title) }
        if let body { o["body"] = .string(body) }
        if let result { o["result"] = .string(result) }
        if let summary { o["summary"] = .string(summary) }
        if let blockReason { o["block_reason"] = .string(blockReason) }
        return .object(o)
    }
}

/// The plugin's routes, every one with `?board=` when a board is chosen. Failures come back as
/// `HermesAPIError.http(status:detail:)` with the server's own words in `detail`.
public struct KanbanAPI: Sendable {
    public static let base = "/api/plugins/kanban"
    let api: HermesAPI
    public var board: String?

    public init(api: HermesAPI, board: String? = nil) { self.api = api; self.board = board }

    private func q(_ more: [URLQueryItem] = []) -> [URLQueryItem] {
        (board.map { [URLQueryItem(name: "board", value: $0)] } ?? []) + more
    }
    private func path(_ p: String) -> String { Self.base + p }

    // Reads
    public func boards(includeArchived: Bool = false) async throws -> KanbanBoards {
        try await api.get(path("/boards"), query: [URLQueryItem(name: "include_archived", value: includeArchived ? "true" : "false")])
    }
    public func board(includeArchived: Bool = false) async throws -> KanbanBoard {
        try await api.get(path("/board"), query: q([URLQueryItem(name: "include_archived", value: includeArchived ? "true" : "false")]))
    }
    public func task(_ id: String) async throws -> KanbanTaskDetail { try await api.get(path("/tasks/\(id)"), query: q()) }
    public func log(_ id: String, tail: Int = 20_000) async throws -> KanbanLog {
        try await api.get(path("/tasks/\(id)/log"), query: q([URLQueryItem(name: "tail", value: String(tail))]))
    }
    public func workers() async throws -> KanbanWorkers { try await api.get(path("/workers/active"), query: q()) }
    public func assignees() async throws -> [KanbanAssignee] { let r: KanbanAssignees = try await api.get(path("/assignees"), query: q()); return r.assignees }
    public func stats() async throws -> KanbanStats { try await api.get(path("/stats"), query: q()) }
    public func run(_ id: Int) async throws -> KanbanRun { struct R: Decodable { var run: KanbanRun }; let r: R = try await api.get(path("/runs/\(id)"), query: q()); return r.run }

    // Writes
    public func create(_ t: KanbanNewTask) async throws -> KanbanTaskEnvelope { try await api.send("POST", path("/tasks"), query: q(), json: t.json) }
    public func update(_ id: String, _ p: KanbanTaskPatch) async throws -> KanbanTaskEnvelope { try await api.send("PATCH", path("/tasks/\(id)"), query: q(), json: p.json) }
    public func delete(_ id: String) async throws {
        _ = try await api.raw("DELETE", path("/tasks/\(id)"), query: q(), profile: nil, body: nil, authenticated: true)
    }
    public func comment(_ id: String, _ body: String, author: String = "vory") async throws {
        let _: JSONValue = try await api.send("POST", path("/tasks/\(id)/comments"), query: q(), json: .object(["body": .string(body), "author": .string(author)]))
    }
    public func reassign(_ id: String, to profile: String?, reclaimFirst: Bool, reason: String? = nil) async throws {
        var o: [String: JSONValue] = ["profile": profile.map { .string($0) } ?? .null, "reclaim_first": .bool(reclaimFirst)]
        if let reason { o["reason"] = .string(reason) }
        let _: JSONValue = try await api.send("POST", path("/tasks/\(id)/reassign"), query: q(), json: .object(o))
    }
    public func terminate(run: Int, reason: String? = nil) async throws {
        let _: JSONValue = try await api.send("POST", path("/runs/\(run)/terminate"), query: q(), json: .object(reason.map { ["reason": .string($0)] } ?? [:]))
    }
    public func reclaim(_ id: String, reason: String? = nil) async throws {
        let _: JSONValue = try await api.send("POST", path("/tasks/\(id)/reclaim"), query: q(), json: .object(reason.map { ["reason": .string($0)] } ?? [:]))
    }
    /// The dispatcher nudge, so the board does not wait out its 60 s tick.
    @discardableResult public func dispatch(max: Int = 8) async throws -> JSONValue {
        try await api.send("POST", path("/dispatch"), query: q([URLQueryItem(name: "max", value: String(max))]), json: .object([:]))
    }
}

/// The live socket's cursor: the newest event id seen. The socket is opened at the board's
/// `latest_event_id` so history is not replayed, and every frame moves it on.
public struct KanbanEventCursor: Sendable, Equatable {
    public private(set) var cursor: Int?
    public init(start: Int? = nil) { cursor = start }

    /// Sets the start from a freshly read board when none is known yet.
    public mutating func start(fromBoard latest: Int?) { if cursor == nil, let latest { cursor = latest } }

    /// Takes a frame; true when it carried events, so the board is read again.
    public mutating func take(_ frame: KanbanEventsFrame) -> Bool {
        cursor = max(frame.cursor, cursor ?? 0)
        return !frame.events.isEmpty
    }

    /// `?since=` for the socket, when a cursor is known.
    public var sinceQuery: URLQueryItem? { cursor.map { URLQueryItem(name: "since", value: String($0)) } }
}
