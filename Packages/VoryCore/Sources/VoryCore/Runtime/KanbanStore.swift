import Foundation

/// The gateway's kanban board for the Board page: whether the plugin is there at all, the
/// boards, the one in front, its columns, the workers on it, and the live socket that says
/// when to read it again. Writes go through here too, so every change is followed by a fresh
/// read and a dispatcher nudge, as the desktop client does.
@MainActor
@Observable
public final class KanbanStore {
    /// Whether the plugin answers. Unknown until the probe ran; then what it said. The last
    /// answer is kept per gateway so the page does not flicker in and out at launch.
    public enum Availability: String, Sendable { case unknown, present, absent }

    public private(set) var availability: Availability = .unknown
    public private(set) var boards: [KanbanBoardMeta] = []
    /// The board in front: chosen here (kept per gateway), else the gateway's current one.
    public private(set) var selectedBoard: String?
    public private(set) var board: KanbanBoard?
    public private(set) var workers: [KanbanWorker] = []
    public private(set) var assignees: [KanbanAssignee] = []
    /// The server's words on the last failure, for the page to show as they are.
    public var lastError: String?
    public private(set) var loading = false
    public private(set) var liveConnected = false
    public private(set) var lastRead: Date?

    private weak var runtime: GatewayRuntime?
    private var cached: Availability?
    private var cursor = KanbanEventCursor()
    private var eventsTask: Task<Void, Never>?
    private var refetch: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private static let socketSession = HermesAPI.makeSession()

    public init() {}

    func attach(_ runtime: GatewayRuntime) {
        self.runtime = runtime
        if let raw = UserDefaults.standard.string(forKey: cacheKey), let a = Availability(rawValue: raw) { cached = a }
        selectedBoard = UserDefaults.standard.string(forKey: boardKey)
    }

    private var gatewayKey: String { runtime?.connection.id.uuidString ?? "" }
    private var cacheKey: String { "kanban.available." + gatewayKey }
    private var boardKey: String { "kanban.board." + gatewayKey }

    /// What the pages go by: the probe's answer, else the last one for this gateway.
    public var effective: Availability { availability != .unknown ? availability : (cached ?? .unknown) }
    public var isPresent: Bool { effective == .present }

    public var api: KanbanAPI? { runtime.map { KanbanAPI(api: $0.api, board: selectedBoard) } }
    public var selectedBoardMeta: KanbanBoardMeta? { boards.first { $0.slug == selectedBoard } }
    /// A running worker's run id for a task, from the workers list (the board's card does not carry it on its own).
    public func worker(for task: KanbanTask) -> KanbanWorker? { workers.first { $0.taskId == task.id } }

    // MARK: Availability

    /// Asks the plugin for its boards: present when it answers, absent on a 404 (a disabled
    /// plugin says "Plugin not found"; an unmounted one gives the server's own Not Found).
    public func probe() async {
        guard let api else { return }
        do {
            let b = try await api.boards()
            boards = b.boards
            if selectedBoard == nil || !boards.contains(where: { $0.slug == selectedBoard }) { selectedBoard = b.current ?? boards.first?.slug }
            set(.present)
        } catch let e as HermesAPIError {
            if case .http(let status, _) = e, status == 404 { set(.absent) } else { lastError = e.localizedDescription }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func set(_ a: Availability) {
        availability = a; cached = a
        UserDefaults.standard.set(a.rawValue, forKey: cacheKey)
    }

    // MARK: Reads

    /// Reads the board and the workers. The read runs in its own task, so a page whose task is
    /// restarted mid-read (a tab change, a re-appear) does not cancel the request under it;
    /// callers that arrive while one is in flight wait for that one.
    public func refresh() async {
        guard let api, isPresent else { return }
        if let t = refreshTask { await t.value; return }
        let t = Task { @MainActor [weak self] in if let self { await self.read(api) } }
        refreshTask = t
        await t.value
        refreshTask = nil
    }

    private func read(_ api: KanbanAPI) async {
        loading = board == nil
        defer { loading = false }
        do {
            async let b = api.board()
            async let w = api.workers()
            let (bb, ww) = try await (b, w)
            board = bb
            workers = ww.workers
            cursor.start(fromBoard: bb.latestEventId)
            lastRead = Date()
            lastError = nil
        } catch {
            lastError = Self.message(error)
        }
    }

    public func refreshBoards() async {
        guard let api else { return }
        if let b = try? await api.boards() { boards = b.boards }
    }

    public func loadAssignees() async {
        guard let api else { return }
        if let a = try? await api.assignees() { assignees = a }
    }

    public func detail(_ id: String) async throws -> KanbanTaskDetail {
        guard let api else { throw HermesAPIError.transport("No gateway") }
        return try await api.task(id)
    }

    public func log(_ id: String, tail: Int = 20_000) async throws -> KanbanLog {
        guard let api else { throw HermesAPIError.transport("No gateway") }
        return try await api.log(id, tail: tail)
    }

    /// Puts another board in front: its own read and its own socket.
    public func select(board slug: String) {
        guard slug != selectedBoard else { return }
        selectedBoard = slug
        UserDefaults.standard.set(slug, forKey: boardKey)
        board = nil; workers = []
        cursor = KanbanEventCursor()
        Task { await refresh(); startEvents() }
    }

    // MARK: Live

    /// Opens the plugin's own socket (not the gateway's main one) and reads the board again
    /// whenever a frame carries events. Reconnects with backoff; stops with `stopEvents()`.
    public func startEvents() {
        eventsTask?.cancel()
        guard isPresent else { return }
        eventsTask = Task { [weak self] in await self?.eventLoop() }
    }

    public func stopEvents() {
        eventsTask?.cancel(); eventsTask = nil
        // `receive()` does not notice a cancelled task: the socket is closed under it, so the
        // loop ends now and not at the next frame.
        eventSocket?.cancel(with: .goingAway, reason: nil); eventSocket = nil
        liveConnected = false
    }
    private var eventSocket: URLSessionWebSocketTask?

    private func eventLoop() async {
        var backoff: Double = 2
        while !Task.isCancelled {
            guard let runtime else { return }
            do {
                var query: [URLQueryItem] = []
                if let b = selectedBoard { query.append(URLQueryItem(name: "board", value: b)) }
                if let s = cursor.sinceQuery { query.append(s) }
                let (url, headers) = try await runtime.pluginWebsocketURL(path: KanbanAPI.base + "/events", query: query)
                var request = URLRequest(url: url)
                for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
                let socket = Self.socketSession.webSocketTask(with: request)
                eventSocket = socket
                socket.resume()
                liveConnected = true
                backoff = 2
                defer { socket.cancel(with: .goingAway, reason: nil); if eventSocket === socket { eventSocket = nil } }
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data?
                    switch message {
                    case .data(let d): data = d
                    case .string(let s): data = Data(s.utf8)
                    @unknown default: data = nil
                    }
                    if let data, let frame = try? JSONCoding.decoder.decode(KanbanEventsFrame.self, from: data), cursor.take(frame) {
                        scheduleRefetch()
                    }
                }
            } catch {
                // A loop that was stopped says nothing: a newer one may already be live.
                if Task.isCancelled { return }
                liveConnected = false
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(30, backoff * 2)
        }
    }

    /// Several events land together after a change; one read for all of them.
    private func scheduleRefetch() {
        refetch?.cancel()
        refetch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Writes

    /// Runs a change, keeps the server's words if it refuses, then reads the board again and
    /// nudges the dispatcher the way the desktop client does after every change.
    @discardableResult
    private func change(_ work: (KanbanAPI) async throws -> Void) async -> Bool {
        guard let api else { return false }
        var refusal: String?
        do { try await work(api); lastError = nil; lastRefusal = nil }
        catch { refusal = Self.message(error) }
        await refresh()
        if let refusal {
            // The read that follows must not wipe the refusal before the view shows it (it did,
            // and a refused move looked like nothing at all).
            lastError = refusal
            lastRefusal = refusal
            return false
        }
        try? await api.dispatch()
        return true
    }

    /// The server's words for the last change it refused; a later read does not clear it.
    public private(set) var lastRefusal: String?

    public func move(_ task: KanbanTask, to status: KanbanStatus, summary: String? = nil, blockReason: String? = nil) async -> Bool {
        var patch = KanbanTaskPatch(status: status)
        if status == .done, let summary, !summary.isEmpty { patch.result = summary; patch.summary = summary }
        if status == .blocked, let blockReason, !blockReason.isEmpty { patch.blockReason = blockReason }
        return await change { try await $0.update(task.id, patch) }
    }

    public func setPriority(_ task: KanbanTask, _ priority: Int) async -> Bool {
        await change { try await $0.update(task.id, KanbanTaskPatch(priority: priority)) }
    }

    public func edit(_ task: KanbanTask, title: String?, body: String?) async -> Bool {
        await change { try await $0.update(task.id, KanbanTaskPatch(title: title, body: body)) }
    }

    /// Hands the task to another bot; a running one has its worker reclaimed first.
    public func reassign(_ task: KanbanTask, to profile: String?) async -> Bool {
        await change { try await $0.reassign(task.id, to: profile, reclaimFirst: task.status == KanbanStatus.running.rawValue) }
    }

    public func comment(_ task: KanbanTask, _ text: String) async -> Bool {
        await change { try await $0.comment(task.id, text) }
    }

    public func delete(_ task: KanbanTask) async -> Bool {
        await change { try await $0.delete(task.id) }
    }

    /// Makes a task; the envelope carries the dispatcher warning when nothing would pick it up.
    public func create(_ new: KanbanNewTask) async -> KanbanTaskEnvelope? {
        guard let api else { return nil }
        var made: KanbanTaskEnvelope?
        await change { made = try await $0.create(new) }
        _ = api
        return made
    }

    /// Stops the worker on a task: the run is terminated, with reclaim as the fallback. A 409
    /// means it had already ended, which only calls for a fresh read.
    public func stop(_ task: KanbanTask, reason: String? = nil) async -> Bool {
        guard let api else { return false }
        let runID = task.currentRunId ?? worker(for: task)?.runId
        do {
            if let runID { try await api.terminate(run: runID, reason: reason) } else { try await api.reclaim(task.id, reason: reason) }
            lastError = nil
        } catch let e as HermesAPIError {
            if case .http(let status, _) = e, status == 409 {
                // Already ended: nothing to stop, the board just needs reading.
            } else if runID != nil, (try? await api.reclaim(task.id, reason: reason)) != nil {
                lastError = nil
            } else {
                await refusal(Self.message(e))
                return false
            }
        } catch {
            await refusal(Self.message(error))
            return false
        }
        await refresh()
        return true
    }

    public func nudge() async {
        guard let api else { return }
        do { try await api.dispatch(); lastError = nil; lastRefusal = nil } catch { await refusal(Self.message(error)); return }
        await refresh()
    }

    /// A refused write: the board is read again, and the server's words stay for the view.
    private func refusal(_ words: String) async {
        await refresh()
        lastError = words
        lastRefusal = words
    }

    /// The server's `detail` when it refused, else the error as it describes itself.
    public nonisolated static func message(_ error: Error) -> String {
        if let e = error as? HermesAPIError, case .http(_, let detail) = e, !detail.isEmpty { return detail }
        return error.localizedDescription
    }
}
