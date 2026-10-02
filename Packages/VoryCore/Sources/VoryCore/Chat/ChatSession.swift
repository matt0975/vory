import Foundation
import Observation
import OSLog
import UniformTypeIdentifiers

public struct QueuedMessage: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// A gateway → client question waiting for the user (approval, clarify, sudo, secret, vault.*).
public struct PendingCard: Identifiable, Hashable, Sendable {
    public var id: String
    public var method: String
    public var params: JSONValue
    /// True when the card came from `pending_approval` and must be answered with `approval.respond`.
    public var viaApprovalRPC = false

    public init(id: String, method: String, params: JSONValue, viaApprovalRPC: Bool = false) {
        self.id = id; self.method = method; self.params = params; self.viaApprovalRPC = viaApprovalRPC
    }
    public var approval: ApprovalRequest? { method == "approval" ? try? params.decode(ApprovalRequest.self) : nil }
    public var clarify: ClarifyRequest? { method == "clarify" ? try? params.decode(ClarifyRequest.self) : nil }
    public var valuePrompt: ValuePromptRequest? { ["sudo", "secret", "vault.unlock_prompt", "vault.save_login", "vault.code"].contains(method) ? try? params.decode(ValuePromptRequest.self) : nil }
    public var isSecret: Bool { method != "approval" && method != "clarify" }

    public init(id: String, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// One live conversation. Owns the transcript, streaming assembly, pending cards, the local send queue and staged attachments.
@MainActor
@Observable
public final class ChatSession: @MainActor Identifiable, ChatIdentity {
    /// Strong on purpose: a chat kept by a screen must outlive a gateway switch (an unowned
    /// reference trapped when the old runtime went away under an open conversation).
    public let runtime: GatewayRuntime
    private let log = Logger(subsystem: "Vory", category: "chat")

    public private(set) var runtimeID = ""
    public private(set) var storedID: String
    public var title: String
    public var info: SessionLiveInfo?
    public var items: [TranscriptItem] = []
    public var usage: Usage?
    public var isRunning = false {
        didSet {
            guard isRunning != oldValue else { return }
            runtime.publishSnapshot()
            if isRunning {
                activityEndTask?.cancel(); activityEndTask = nil
                // A missed approval frame (a proxy that drops it, another client that answered
                // first, a capability the gateway never recorded): while the turn runs the
                // gateway's pending queue is asked every few seconds, so the card still appears.
                approvalPollTask?.cancel()
                approvalPollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(6))
                        guard let self, self.isRunning, !Task.isCancelled else { return }
                        await self.pollPendingApprovals()
                    }
                }
            } else {
                approvalPollTask?.cancel(); approvalPollTask = nil
                // Every way a turn can stop (reclaim, a resume snapshot that says idle, a stray
                // session.info) funnels through here, so the Live Activity cannot outlive the turn —
                // but a moment later, so the brief idle blip between submit and the first token does
                // not end the activity that was just started. Completion and errors end it at once.
                let phase = endPhase; endPhase = "done"
                activityEndTask?.cancel()
                activityEndTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self, !self.isRunning else { return }
                    self.activity.end(for: self, phase: phase)
                }
            }
        }
    }
    /// Phase the next `isRunning = false` reports to the activity surface.
    private var endPhase = "done"
    private var activityEndTask: Task<Void, Never>?
    private var approvalPollTask: Task<Void, Never>?
    public var statusLine: String? {
        didSet { if isRunning, statusLine != oldValue, cards.isEmpty { activity.update(for: self, attention: false) } }
    }
    public var banner: String?
    public var cards: [PendingCard] = []
    public var queue: [QueuedMessage] = []
    public var staged: [AttachmentPreview] = []
    public var composerHistory: [String] = []
    public var lastSubmitStatus: String?
    public var stale = false
    /// True from open until `session.resume` has answered; the transcript shown meanwhile is the
    /// cached copy (or a REST page), so the chat appears instantly and syncs behind it.
    public private(set) var isResuming = false
    public var resumeError: String?
    private var resumeTask: Task<Void, Never>?
    private var bannerIsReconnect = false
    private var lastActivityUpdate = Date.distantPast
    public var id: String { storedID }

    private var assembler = StreamAssembler()
    private var streamingItemID: String?
    /// Tokens arrive faster than the screen can usefully show them; each one used to replace the
    /// streaming row and re-lay out the thread. They are gathered and shown about 25 times a
    /// second instead, which reads the same and leaves the main thread free to scroll.
    private var streamFlush: Task<Void, Never>?
    private var lastStatsUpdate = Date.distantPast
    /// Assistant text already sealed into earlier bubbles of the current turn, because tool calls
    /// split the stream. `message.complete` carries the WHOLE turn, so it must be reconciled
    /// against this instead of being appended again.
    private var sealedTurnText = ""
    /// Turn timing for the tokens-per-second footer.
    private var turnStartedAt: Date?
    private var outputTokensAtTurnStart: Int?
    private var streamedCharactersThisTurn = 0
    private var toolIndex: [String: String] = [:]
    private var inlineAnswers: [String: CheckedContinuation<JSONValue?, Never>] = [:]
    private let activity: any TurnActivityReporting

    /// The bot this chat belongs to, fixed when the chat is opened or created: every call
    /// carries it and the header names it. Never the bot selected at the time of a call. A
    /// reconnect that resumed the chat under whichever bot was selected by then made the
    /// gateway move the chat into that bot's store.
    public let profile: String?

    public init(runtime: GatewayRuntime, storedID: String?, title: String?, profile: String? = nil) {
        self.runtime = runtime
        self.activity = runtime.activityReporterFactory()
        self.storedID = storedID ?? ""
        self.profile = (profile?.isEmpty == false ? profile : nil) ?? runtime.selectedProfile
        self.title = title ?? "New chat"
    }

    public var profileName: String { profile ?? info?.profileName ?? runtime.selectedProfile ?? "default" }

    /// The runtime's call with this chat's bot attached.
    private func rpc(_ method: String, _ params: [String: JSONValue] = [:], timeout: Double = 120) async throws -> JSONValue {
        try await runtime.rpc(method, params, owner: profile, timeout: timeout)
    }
    public var modelName: String { info?.model ?? "" }
    public var subtitle: String {
        let m = modelName.isEmpty ? "no model" : (modelName.split(separator: "/").last.map(String.init) ?? modelName)
        // Model and context first: on a phone the subtitle truncates at the end, and the profile
        // name is the part the user can most afford to lose.
        if let u = usage, let pct = u.computedContextPercent { return "\(m) · \(pct)% · \(profileName)" }
        return "\(m) · \(profileName)"
    }
    public var firstCard: PendingCard? { cards.first }
    public var needsAttention: Bool { !cards.isEmpty }

    // MARK: Lifecycle

    public func create(cwd: String? = nil) async throws {
        var params: [String: JSONValue] = ["cols": 80]
        if let cwd, !cwd.isEmpty { params["cwd"] = .string(cwd); params["cwd_explicit"] = .bool(true) }
        let r = try await rpc("session.create", params)
        runtimeID = r["session_id"]?.stringValue ?? ""
        storedID = r["stored_session_id"]?.stringValue ?? runtimeID
        info = try? r["info"]?.decode(SessionLiveInfo.self)
        title = info?.title?.isEmpty == false ? info!.title! : "New chat"
        items = []
        await loadUsage()
    }

    public func resume() async throws {
        let r = try await rpc("session.resume", ["session_id": .string(storedID), "cols": 80])
        apply(snapshot: r)
        await loadUsage()
    }

    public func reattachAfterReconnect() async {
        do {
            let r = try await rpc("session.resume", ["session_id": .string(storedID), "cols": 80])
            apply(snapshot: r)
            stale = false
            if bannerIsReconnect { banner = nil; bannerIsReconnect = false }
        } catch is CancellationError {
            // A newer reconnect superseded this one; it will re-attach the chat itself.
            stale = true
        } catch {
            stale = true
            if !(error is CancellationError), !error.localizedDescription.contains("CancellationError") {
                let why = error.localizedDescription
                if why.localizedCaseInsensitiveContains("not found") {
                    // A one-off run (a scheduled task, say) the gateway never kept, or one it
                    // dropped on restart: say so instead of quoting the error.
                    banner = "The gateway no longer has this chat. It may have been a one-off run, or the gateway restarted without it. Start a new chat to carry on."
                } else {
                    banner = "Reconnected, but the chat could not be re-attached: \(why)"
                }
                bannerIsReconnect = true
            }
        }
    }

    // MARK: Instant open

    /// Shows the last transcript this device saw for the session while `resume()` runs, or a REST
    /// page of it when nothing is cached; `resume()` then replaces both with the live snapshot.
    public func beginResume() {
        if items.isEmpty, let cached = TranscriptCache.load(connection: runtime.connection.id, storedID: storedID), !cached.isEmpty {
            items = cached.enumerated().compactMap { TranscriptItem.fromHistory($1, index: $0) }
        }
        isResuming = true
        resumeError = nil
        let needsPrefetch = items.isEmpty
        resumeTask = Task { [weak self] in
            guard let self else { return }
            if needsPrefetch { Task { [weak self] in await self?.prefetchFromREST() } }
            do { try await resume(); resumeError = nil }
            catch { resumeError = error.localizedDescription }
            isResuming = false
        }
    }

    /// Waits for the live attach before anything that needs the runtime session id.
    public func awaitResume() async { await resumeTask?.value }

    private func prefetchFromREST() async {
        guard let r: JSONValue = try? await runtime.api.get("/api/sessions/\(storedID)/messages",
                                                            query: [URLQueryItem(name: "order", value: "latest"), URLQueryItem(name: "limit", value: "60")],
                                                            profile: profile) else { return }
        guard isResuming, items.isEmpty else { return }
        let msgs = (r["messages"]?.arrayValue ?? []).compactMap { try? $0.decode(TranscriptMessage.self) }
        items = msgs.enumerated().compactMap { TranscriptItem.fromHistory($1, index: $0) }
    }

    private func saveTranscriptCache() {
        TranscriptCache.save(items, connection: runtime.connection.id, storedID: storedID)
    }

    private func apply(snapshot r: JSONValue) {
        runtimeID = r["session_id"]?.stringValue ?? runtimeID
        if let sid = r["stored_session_id"]?.stringValue, !sid.isEmpty { storedID = sid }
        info = try? r["info"]?.decode(SessionLiveInfo.self)
        if let t = info?.title, !t.isEmpty { title = t }
        let history = (try? r["messages"]?.decode([TranscriptMessage].self)) ?? []
        // The gateway's transcript has no attachments; keep the ones this app sent (a photo in
        // the bubble vanished when the snapshot replaced the items).
        var keptAttachments: [String: [AttachmentPreview]] = [:]
        for it in items { if case .user(let t, let a) = it.kind, !a.isEmpty { keptAttachments[t] = a } }
        var built: [TranscriptItem] = []
        for (i, m) in history.enumerated() {
            if var item = TranscriptItem.fromHistory(m, index: i) {
                if case .user(let t, let a) = item.kind, a.isEmpty, let k = keptAttachments[t] { item.kind = .user(text: t, attachments: k) }
                built.append(item)
            }
        }
        items = built
        toolIndex = [:]
        cards = []
        isRunning = r["running"]?.boolValue ?? info?.running ?? false
        if let inflight = r["inflight"], !inflight.isNull {
            let user = inflight["user"]?.stringValue ?? ""
            let lastUserText: String? = items.last(where: { if case .user = $0.kind { return true }; return false })
                .flatMap { if case .user(let t, _) = $0.kind { return t }; return nil }
            // Where this turn begins in `messages`: mid-turn the gateway has already flushed the
            // turn's tool and assistant rows while the prompt is still "inflight", so the prompt
            // goes in front of the first row stamped after the turn started (else after the last
            // reply), and the turn's rows sit under it instead of above it.
            let turnStart = r["turn_started_at"]?.doubleValue ?? 0
            let turnAt: Int = {
                if turnStart > 0, let i = items.firstIndex(where: { $0.timestamp.timeIntervalSince1970 >= turnStart - 1 }) { return i }
                if let la = items.lastIndex(where: { if case .assistant = $0.kind { return true }; return false }) { return la + 1 }
                return items.count
            }()
            if !user.isEmpty, lastUserText != user {
                var prompt = TranscriptItem(id: "inflight-user", kind: .user(text: user, attachments: keptAttachments[user] ?? []))
                if turnStart > 0 { prompt.timestamp = Date(timeIntervalSince1970: turnStart) }
                items.insert(prompt, at: turnAt)
            }
            let partial = inflight["assistant"]?.stringValue ?? ""
            let streaming = inflight["streaming"]?.boolValue ?? false
            if let err = inflight["error"]?.stringValue, !err.isEmpty {
                items.append(TranscriptItem(id: "inflight-error", kind: .error(text: err)))
            } else if streaming || !partial.isEmpty {
                // The partial may already be in `messages` as the last assistant row (a flushed
                // prefix): the streaming bubble takes that row's place instead of repeating it.
                if let idx = items.indices.last(where: { if case .assistant = items[$0].kind { return true }; return false }),
                   idx > turnAt, case .assistant(let t, _, _) = items[idx].kind, !t.isEmpty, partial.hasPrefix(t) || t.hasPrefix(partial) {
                    items.remove(at: idx)
                }
                assembler.start()
                assembler.appendDelta(partial)
                let id = "stream-\(UUID().uuidString)"
                streamingItemID = id
                items.append(TranscriptItem(id: id, kind: .assistant(text: partial, reasoning: nil, streaming: streaming)))
                if !streaming { finishStreaming(finalText: nil) }
            }
        }
        if let q = r["queued"]?["user"]?.stringValue, !q.isEmpty { queue = [QueuedMessage(text: q)] }
        if let open = r["open_requests"]?.arrayValue {
            for o in open {
                guard let id = o["id"]?.stringValue, let method = o["method"]?.stringValue else { continue }
                addCard(PendingCard(id: id, method: method, params: o["params"] ?? .object([:])))
            }
        }
        if let pa = r["pending_approval"], !pa.isNull, let rid = pa["request_id"]?.stringValue, !cards.contains(where: { $0.approval?.requestId == rid }) {
            var params = pa.objectValue ?? [:]
            params["session_id"] = .string(runtimeID)
            addCard(PendingCard(id: "queue-\(rid)", method: "approval", params: .object(params), viaApprovalRPC: true))
        }
        if isRunning { activity.start(for: self) }
        saveTranscriptCache()
        Task { await pollPendingApprovals() }
    }

    /// The fallback the gateway offers for a missed approval frame: anything still waiting on
    /// this session becomes a card answered through `approval.respond`.
    public func pollPendingApprovals() async {
        guard let r = try? await rpc("approval.pending", ["session_id": .string(runtimeID)], timeout: 10) else { return }
        let list = r["pending"]?.arrayValue ?? r["approvals"]?.arrayValue ?? (r["request_id"] != nil ? [r] : [])
        for pa in list {
            guard let rid = pa["request_id"]?.stringValue, !cards.contains(where: { $0.approval?.requestId == rid }) else { continue }
            var params = pa.objectValue ?? [:]
            params["session_id"] = .string(runtimeID)
            addCard(PendingCard(id: "queue-\(rid)", method: "approval", params: .object(params), viaApprovalRPC: true))
        }
    }

    public func loadUsage() async {
        if let u: Usage = try? (await rpc("session.usage", ["session_id": .string(runtimeID)])).decode() { usage = u }
    }

    public func contextBreakdown() async throws -> ContextBreakdown {
        try await rpc("session.context_breakdown", ["session_id": .string(runtimeID)]).decode()
    }

    // MARK: Sending

    /// Sends text (with staged attachments). Returns prefill text when a slash command asks the composer to prefill.
    @discardableResult
    public func send(_ rawText: String) async -> String? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !staged.isEmpty else { return nil }
        await awaitResume()
        if let e = resumeError { return "This chat could not be opened on the gateway: \(e)" }
        if !text.isEmpty { composerHistory.append(text) }
        if text.hasPrefix("/"), staged.isEmpty { return await dispatchSlash(text) }
        if isRunning {
            queue.append(QueuedMessage(text: text))
            return nil
        }
        await submit(text: text, queued: false)
        return nil
    }

    private func submit(text: String, queued: Bool) async {
        var outgoing = text
        var previews: [AttachmentPreview] = []
        for a in staged {
            do {
                if let ref = try await upload(a) { outgoing += (outgoing.isEmpty ? "" : "\n") + ref }
                previews.append(a)
            } catch {
                items.append(TranscriptItem(id: UUID().uuidString, kind: .error(text: "Attachment \(a.name) failed: \(error.localizedDescription)")))
            }
        }
        staged = []
        items.append(TranscriptItem(id: UUID().uuidString, kind: .user(text: text, attachments: previews)))
        isRunning = true
        statusLine = "Sending…"
        do {
            var params: [String: JSONValue] = ["session_id": .string(runtimeID), "text": .string(outgoing)]
            if queued { params["queued"] = true }
            let r = try await rpc("prompt.submit", params)
            lastSubmitStatus = r["status"]?.stringValue
            if lastSubmitStatus == "queued" { statusLine = "Queued on the gateway" }
            activity.start(for: self)
        } catch {
            isRunning = false
            statusLine = nil
            items.append(TranscriptItem(id: UUID().uuidString, kind: .error(text: error.localizedDescription)))
        }
    }

    /// Uploads one staged attachment through the gateway and returns the text reference to append (for files).
    private func upload(_ a: AttachmentPreview) async throws -> String? {
        guard let url = a.localURL, let data = try? Data(contentsOf: url) else { return nil }
        let b64 = data.base64EncodedString()
        switch a.kind {
        case .image:
            _ = try await rpc("image.attach_bytes", ["session_id": .string(runtimeID), "content_base64": .string(b64), "filename": .string(a.name)])
            return nil
        case .pdf:
            _ = try await rpc("pdf.attach", ["session_id": .string(runtimeID), "content_base64": .string(b64), "filename": .string(a.name)])
            return nil
        case .audio, .video, .file:
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let r = try await rpc("file.attach", ["session_id": .string(runtimeID), "data_url": .string("data:\(mime);base64,\(b64)"), "name": .string(a.name)])
            return r["ref_text"]?.stringValue
        }
    }

    /// Set by the app: turns an image the gateway cannot take (HEIC from the photo library, say)
    /// into one it can, returning the new bytes and file name. Nil leaves the image as it is.
    nonisolated(unsafe) public static var imageTranscoder: (@Sendable (Data, String) -> (Data, String)?)?

    public func stageAttachment(data: Data, name: String, kind: AttachmentPreview.Kind) {
        var data = data, name = name
        if kind == .image, let t = Self.imageTranscoder?(data, name) { data = t.0; name = t.1 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("staged-\(runtimeID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + "-" + name)
        do {
            try data.write(to: url)
            staged.append(AttachmentPreview(id: url.lastPathComponent, name: name, serverPath: nil, kind: kind, localURL: url, byteCount: data.count))
        } catch {
            banner = "Could not stage \(name): \(error.localizedDescription)"
        }
    }

    public func removeStaged(_ id: String) {
        if let a = staged.first(where: { $0.id == id }), let u = a.localURL { try? FileManager.default.removeItem(at: u) }
        staged.removeAll { $0.id == id }
    }

    public func stop() async {
        _ = try? await rpc("session.interrupt", ["session_id": .string(runtimeID)])
    }

    public func steer(_ text: String) async {
        do {
            let r = try await rpc("session.steer", ["session_id": .string(runtimeID), "text": .string(text)])
            items.append(TranscriptItem(id: UUID().uuidString, kind: .steer(text: text, status: r["status"]?.stringValue ?? "queued")))
        } catch {
            banner = error.localizedDescription
        }
    }

    public func removeQueued(_ id: UUID) { queue.removeAll { $0.id == id } }
    public func updateQueued(_ id: UUID, text: String) { if let i = queue.firstIndex(where: { $0.id == id }) { queue[i].text = text } }

    private func drainQueue() {
        guard !isRunning, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        Task { await submit(text: next.text, queued: true) }
    }

    // MARK: Slash commands

    /// The last catalog fetched for this chat (the composer asks for it); tells which commands a
    /// phone may run.
    public private(set) var catalogCache: CommandsCatalog?

    public func commandsCatalog() async -> CommandsCatalog? {
        let c: CommandsCatalog? = try? (await rpc("commands.catalog", ["session_id": .string(runtimeID)])).decode()
        if let c { catalogCache = c }
        return c
    }

    private func systemLine(_ text: String, symbol: String = "terminal") {
        items.append(TranscriptItem(id: UUID().uuidString, kind: .system(text: text, symbol: symbol)))
    }

    /// Slash commands, the way the terminal and the desktop run them: a few are the app's own
    /// (approve, stop, title, model…), the rest go to `slash.exec`, the gateway's general
    /// runner for built-ins, plugins and quick commands. `command.dispatch` only knows quick,
    /// plugin, bundle and skill commands, so it is the fallback the gateway asks for (skills)
    /// and the whole path on a gateway too old to have `slash.exec`.
    private func dispatchSlash(_ text: String, depth: Int = 0) async -> String? {
        let body = String(text.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1)
        let name = parts.first.map { String($0).lowercased() } ?? ""
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
        switch name {
        case "approve":
            if let card = cards.first(where: { $0.method == "approval" }) { await respond(card: card, result: ["choice": "once"]) }
            else { banner = "No approval is waiting." }
            return nil
        case "deny":
            if let card = cards.first(where: { $0.method == "approval" }) { await respond(card: card, result: ["choice": "deny"]) }
            return nil
        case "stop":
            await stop(); return nil
        case "title", "rename":
            if let arg, !arg.isEmpty { await rename(arg); systemLine("Renamed to \(arg)", symbol: "pencil"); return nil }
        case "model":
            if let arg, !arg.isEmpty {
                do { try await setModel(provider: nil, model: arg); systemLine("Model set to \(arg)", symbol: "cpu") }
                catch { items.append(TranscriptItem(id: UUID().uuidString, kind: .error(text: "/model: \(error.localizedDescription)"))) }
                return nil
            }
        case "reasoning", "effort":
            if let arg, !arg.isEmpty {
                do { try await setReasoning(arg); systemLine("Reasoning set to \(arg)", symbol: "brain") }
                catch { items.append(TranscriptItem(id: UUID().uuidString, kind: .error(text: "/\(name): \(error.localizedDescription)"))) }
                return nil
            }
        case "new", "reset", "clear":
            // A fresh chat with this bot opens on top; this one stays as it is.
            NotificationCenter.default.post(name: .hermesNewChatRequested, object: nil, userInfo: ["profile": profileName])
            return nil
        case "help", "commands":
            var cat = catalogCache
            if cat == nil { cat = await commandsCatalog() }
            if let c = cat {
                let lines = (c.categories ?? []).map { cat in "\(cat.name ?? "Commands")\n" + (cat.pairs ?? []).map { "  " + $0.joined(separator: "  ") }.joined(separator: "\n") }
                systemLine(lines.isEmpty ? c.allPairs.map { "/\($0.name)  \($0.description)" }.joined(separator: "\n") : lines.joined(separator: "\n\n"), symbol: "questionmark.circle")
            }
            return nil
        default: break
        }
        // Commands the gateway marks as terminal-only (or Settings-only) are said so, not run.
        if let meta = catalogCache?.commands?["/" + name], let why = meta.desktop, why != "hidden" {
            let reason: String
            switch why {
            case "terminal": reason = "it needs the terminal"
            case "settings": reason = "use Settings instead"
            case "composer-voice": reason = "use the mic button instead"
            case "messaging": reason = "it belongs to the messaging setup"
            default: reason = "it is not available in the app"
            }
            systemLine("/\(name): \(reason).", symbol: "info.circle")
            return nil
        }
        do {
            let r = try await rpc("slash.exec", ["session_id": .string(runtimeID), "command": .string(body)], timeout: 120)
            if r["type"]?.stringValue != nil, let d = try? r.decode(CommandDispatchResult.self) {
                return await apply(d, name: name, arg: arg, depth: depth)
            }
            var out = r["output"]?.stringValue ?? ""
            if let w = r["warning"]?.stringValue, !w.isEmpty { out = out.isEmpty ? w : w + "\n\n" + out }
            systemLine(out.isEmpty ? "/\(name) done" : out)
            return nil
        } catch let e as RPCError where e.code == 4018 && (e.message.hasPrefix("skill command: use command.dispatch") || e.message.contains("use command.dispatch for /snapshot restore")) {
            return await dispatchViaCommand(name: name, arg: arg, depth: depth)
        } catch let e as RPCError where e.code == RPCError.methodNotFound {
            return await dispatchViaCommand(name: name, arg: arg, depth: depth)
        } catch {
            items.append(TranscriptItem(id: UUID().uuidString, kind: .error(text: "/\(name): \(error.localizedDescription)")))
            return nil
        }
    }

    private func dispatchViaCommand(name: String, arg: String?, depth: Int) async -> String? {
        do {
            var params: [String: JSONValue] = ["name": .string(name), "session_id": .string(runtimeID)]
            if let arg { params["arg"] = .string(arg) }
            let r: CommandDispatchResult = try await rpc("command.dispatch", params).decode()
            return await apply(r, name: name, arg: arg, depth: depth)
        } catch {
            items.append(TranscriptItem(id: UUID().uuidString, kind: .error(text: "/\(name): \(error.localizedDescription)")))
        }
        return nil
    }

    /// A typed dispatch result (from either runner) applied to the chat.
    private func apply(_ r: CommandDispatchResult, name: String, arg: String?, depth: Int) async -> String? {
        do {
            switch r.type {
            case "exec", "plugin":
                items.append(TranscriptItem(id: UUID().uuidString, kind: .system(text: r.display ?? r.output ?? r.notice ?? "/\(name) done", symbol: "terminal")))
            case "send", "skill":
                if let m = r.message { await submit(text: m, queued: false) }
            case "prefill":
                return r.message
            case "alias":
                // An alias that points at itself, or a ring of them, must not recurse without
                // end (a stack overflow on the phone the moment the command was sent).
                if let t = r.target, t != name, depth < 4 {
                    return await dispatchSlash("/" + t + (arg.map { " " + $0 } ?? ""), depth: depth + 1)
                }
                banner = "/\(name) points at /\(r.target ?? name), which leads back to itself."
                return nil
            default:
                if let n = r.notice ?? r.display { items.append(TranscriptItem(id: UUID().uuidString, kind: .system(text: n, symbol: "info.circle"))) }
            }
            if let notice = r.notice, r.type != "exec" { banner = notice }
        }
        return nil
    }

    // MARK: Model / effort / fast / yolo (session-scoped)

    public func setModel(provider: String?, model: String) async throws {
        var value = model
        if let provider, !provider.isEmpty { value += " --provider \(provider)" }
        value += " --session"
        let r = try await rpc("config.set", ["key": "model", "value": .string(value), "session_id": .string(runtimeID)])
        if r["confirm_required"]?.boolValue == true {
            _ = try await rpc("config.set", ["key": "model", "value": .string(value), "session_id": .string(runtimeID), "confirm_expensive_model": true])
        }
        if let i = try? r["info"]?.decode(SessionLiveInfo.self) { info = i }
        if let w = r["warning"]?.stringValue, !w.trimmingCharacters(in: .whitespaces).isEmpty { banner = w }
        if r["deferred"]?.boolValue == true { banner = "Model change applies at the next turn." }
        await loadUsage()
    }

    public func setReasoning(_ effort: String) async throws {
        _ = try await rpc("config.set", ["key": "reasoning", "value": .string(effort), "session_id": .string(runtimeID), "scope": "session"])
    }

    public func setFast(_ on: Bool) async throws {
        _ = try await rpc("config.set", ["key": "fast", "value": .string(on ? "on" : "off"), "session_id": .string(runtimeID)])
    }

    public func setYolo(_ on: Bool) async throws {
        _ = try await rpc("config.set", ["key": "yolo", "value": .string(on ? "on" : "off"), "session_id": .string(runtimeID), "scope": "session"])
    }

    public func rename(_ newTitle: String) async {
        if let r = try? await rpc("session.title", ["session_id": .string(runtimeID), "title": .string(newTitle)]), let t = r["title"]?.stringValue { title = t }
    }

    // MARK: Server → client requests

    public func answer(serverRequest req: ServerRequest) async -> JSONValue? {
        guard ["approval", "clarify", "sudo", "secret", "vault.unlock_prompt", "vault.save_login", "vault.code"].contains(req.method) else { return nil }
        let card = PendingCard(id: req.id, method: req.method, params: req.params)
        addCard(card)
        // The same request id asked twice (a gateway retry): the first waiter is answered
        // empty rather than left hanging under the new one.
        inlineAnswers.removeValue(forKey: req.id)?.resume(returning: nil)
        return await withCheckedContinuation { (c: CheckedContinuation<JSONValue?, Never>) in
            inlineAnswers[req.id] = c
        }
    }

    private func addCard(_ card: PendingCard) {
        guard !cards.contains(where: { $0.id == card.id }) else { return }
        cards.append(card)
        runtime.setAttention(storedID: storedID, needed: true)
        activity.update(for: self, attention: true)
        if card.method == "approval", let rid = card.approval?.requestId, !card.viaApprovalRPC {
            Task { _ = try? await rpc("approval.received", ["session_id": .string(runtimeID), "request_id": .string(rid)]) }
        }
        runtime.cardNotifier?.cardArrived(card, chat: self)
    }

    public func respond(card: PendingCard, result: JSONValue) async {
        cards.removeAll { $0.id == card.id }
        if cards.isEmpty { runtime.setAttention(storedID: storedID, needed: false); activity.update(for: self, attention: false) }
        if card.viaApprovalRPC, let rid = card.approval?.requestId {
            var params: [String: JSONValue] = ["session_id": .string(runtimeID), "request_id": .string(rid)]
            params["choice"] = result["choice"] ?? "deny"
            _ = try? await rpc("approval.respond", params)
            return
        }
        if let c = inlineAnswers.removeValue(forKey: card.id) { c.resume(returning: result) }
        else { await runtime.socket.respond(to: card.id, result: result) }
        if card.method == "approval" {
            items.append(TranscriptItem(id: UUID().uuidString, kind: .system(text: "Approval: \(result["choice"]?.stringValue ?? "?")", symbol: "checkmark.shield")))
        }
    }

    private func cancelCard(id: String, reason: String) {
        guard cards.contains(where: { $0.id == id }) else { return }
        cards.removeAll { $0.id == id }
        if cards.isEmpty { runtime.setAttention(storedID: storedID, needed: false) }
        if let c = inlineAnswers.removeValue(forKey: id) { c.resume(returning: .null) }
        items.append(TranscriptItem(id: UUID().uuidString, kind: .system(text: "Request withdrawn (\(reason)).", symbol: "xmark.circle")))
    }

    // MARK: Events

    public func handle(event ev: GatewayEvent) {
        let p = ev.payload
        switch ev.type {
        case "message.start":
            beginStreaming()
        case "message.delta":
            if streamingItemID == nil { beginStreaming() }
            if statusLine != "Writing…" { statusLine = "Writing…" }   // the Live Activity follows this
            let delta = p["text"]?.stringValue ?? ""
            streamedCharactersThisTurn += delta.count
            assembler.appendDelta(delta)
            scheduleStreamingUpdate()
            if !delta.isEmpty { NotificationCenter.default.post(name: .hermesStreamDelta, object: nil, userInfo: ["storedID": storedID, "count": delta.count]) }
        case "reasoning.delta", "thinking.delta":
            if streamingItemID == nil { beginStreaming() }
            if statusLine != "Thinking…" { statusLine = "Thinking…" }
            assembler.appendReasoning(p["text"]?.stringValue ?? "")
            scheduleStreamingUpdate()
        case "reasoning.available":
            if streamingItemID == nil { beginStreaming() }
            assembler.appendReasoning(p["text"]?.stringValue ?? "")
            updateStreamingItem()
        case "message.interim":
            let text = p["text"]?.stringValue ?? ""
            if p["already_streamed"]?.boolValue == true { finishStreaming(finalText: text.isEmpty ? nil : text) }
            else if !text.isEmpty {
                finishStreaming(finalText: nil)
                items.append(TranscriptItem(id: UUID().uuidString, kind: .assistant(text: text, reasoning: nil, streaming: false)))
            }
        case "message.complete":
            let text = p["text"]?.stringValue
            let lastAssistantIndex = finishStreaming(finalText: text)
            if let u = try? p["usage"]?.decode(Usage.self) { usage = u }
            if let idx = lastAssistantIndex, let started = turnStartedAt {
                items[idx].stats = TurnStats.make(outputBefore: outputTokensAtTurnStart, outputAfter: usage?.output,
                                                  streamedCharacters: streamedCharactersThisTurn + (text?.count ?? 0),
                                                  seconds: Date().timeIntervalSince(started))
            }
            turnStartedAt = nil
            let status = p["status"]?.stringValue
            if let err = p["error"]?.stringValue, !err.isEmpty { appendError(err) }
            else if status == "interrupted" { items.append(TranscriptItem(id: UUID().uuidString, kind: .system(text: "Interrupted", symbol: "stop.circle"))) }
            if let w = p["warning"]?.stringValue, !w.isEmpty { banner = w }
            endPhase = (status == "error" || p["error"]?.stringValue?.isEmpty == false) ? "error" : "done"
            let finalPhase = endPhase
            isRunning = false
            statusLine = nil
            activityEndTask?.cancel(); activityEndTask = nil
            activity.end(for: self, phase: finalPhase)
            runtime.cardNotifier?.turnFinished(chat: self, error: p["error"]?.stringValue)
            saveTranscriptCache()
            drainQueue()
        case "session.usage":
            if let u = try? p["usage"]?.decode(Usage.self) { usage = u; activity.update(for: self, attention: !cards.isEmpty) }
        case "session.info":
            if let i = try? p.decode(SessionLiveInfo.self) { info = i; if let t = i.title, !t.isEmpty { title = t }; if let r = i.running { isRunning = r } }
        case "session.title":
            if let t = p["title"]?.stringValue { title = t }
        case "status.update":
            let kind = p["kind"]?.stringValue ?? ""
            let text = p["text"]?.stringValue ?? ""
            if kind == "compacting" { items.append(TranscriptItem(id: UUID().uuidString, kind: .system(text: text.isEmpty ? "Compressing context…" : text, symbol: "arrow.down.right.and.arrow.up.left"))) }
            else { statusLine = text.isEmpty ? nil : text }
        case "tool.start":
            let id = p["tool_id"]?.stringValue ?? UUID().uuidString
            let act = ToolActivity(id: id, name: p["name"]?.stringValue ?? "tool", context: p["context"]?.stringValue ?? p["preview"]?.stringValue, argsText: p["args_text"]?.stringValue ?? p["args"]?.prettyPrinted)
            let itemID = "tool-\(id)"
            toolIndex[id] = itemID
            sealStreamingForTool()
            items.append(TranscriptItem(id: itemID, kind: .tool(act)))
            statusLine = "Running \(act.displayName)…"
            activity.update(for: self, attention: false, detail: "Running \(act.displayName)")
        case "tool.generating":
            statusLine = "Preparing \(p["name"]?.stringValue ?? "tool")…"
        case "tool.complete":
            let id = p["tool_id"]?.stringValue ?? ""
            if let itemID = toolIndex[id], let idx = items.firstIndex(where: { $0.id == itemID }), case .tool(var act) = items[idx].kind {
                act.status = .done
                act.summary = p["summary"]?.stringValue
                act.resultText = p["result_text"]?.stringValue ?? p["result"]?.stringValue ?? p["result"].map { $0.isNull ? "" : $0.prettyPrinted }
                act.durationSeconds = p["duration_s"]?.doubleValue
                items[idx].kind = .tool(act)
            }
            statusLine = "Thinking…"
        case "tool.output_risk":
            let id = p["tool_id"]?.stringValue ?? ""
            if let itemID = toolIndex[id], let idx = items.firstIndex(where: { $0.id == itemID }), case .tool(var act) = items[idx].kind {
                act.risk = p["risk"]?.stringValue
                items[idx].kind = .tool(act)
            }
        case "subagent.start", "subagent.spawn_requested":
            items.append(TranscriptItem(id: "sub-\(p["subagent_id"]?.stringValue ?? UUID().uuidString)", kind: .subagent(goal: p["goal"]?.stringValue ?? "Subagent", status: "running")))
        case "subagent.complete":
            let sid = "sub-\(p["subagent_id"]?.stringValue ?? "")"
            if let idx = items.firstIndex(where: { $0.id == sid }) { items[idx].kind = .subagent(goal: p["goal"]?.stringValue ?? "Subagent", status: p["status"]?.stringValue ?? "completed") }
        case "error":
            appendError(p["message"]?.stringValue ?? "Unknown error")
            endPhase = "error"
            isRunning = false
            activityEndTask?.cancel(); activityEndTask = nil
            activity.end(for: self, phase: "error")
        case "notice":
            items.append(TranscriptItem(id: UUID().uuidString, kind: .system(text: p["message"]?.stringValue ?? "", symbol: "info.circle")))
        case "notification.show":
            if let t = p["text"]?.stringValue, !t.trimmingCharacters(in: .whitespaces).isEmpty { banner = t; bannerIsReconnect = false }
        case "notification.clear":
            banner = nil
        case "request.cancel":
            cancelCard(id: p["id"]?.stringValue ?? "", reason: p["reason"]?.stringValue ?? "cancelled")
        case "session.reclaimed":
            stale = true
            isRunning = false
            banner = "The gateway reclaimed this session (\(p["reason"]?.stringValue ?? "idle")). It will resume on your next message."
        case "session.resume_progress":
            statusLine = p["message"]?.stringValue
        case "review.summary", "todo.updated", "voice.status", "voice.transcript", "reaction", "message.reaction", "skin.changed":
            break
        default:
            log.debug("unhandled event \(ev.type, privacy: .public)")
        }
    }

    /// The gateway repeats the same failure on agent init, on the turn and on completion; keep one row.
    private func appendError(_ text: String) {
        if let last = items.last, case .error(let t) = last.kind, t == text { return }
        items.append(TranscriptItem(id: UUID().uuidString, kind: .error(text: text)))
    }

    private func beginStreaming() {
        if streamingItemID == nil && !isRunning { sealedTurnText = "" }
        if turnStartedAt == nil {
            turnStartedAt = Date()
            outputTokensAtTurnStart = usage?.output
            streamedCharactersThisTurn = 0
        }
        assembler.start()
        isRunning = true
        let id = "stream-\(UUID().uuidString)"
        streamingItemID = id
        items.append(TranscriptItem(id: id, kind: .assistant(text: "", reasoning: nil, streaming: true)))
        statusLine = "Thinking…"
        activity.start(for: self)
    }

    private func scheduleStreamingUpdate() {
        guard streamFlush == nil else { return }
        streamFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard let self, !Task.isCancelled else { return }
            self.streamFlush = nil
            self.updateStreamingItem()
        }
    }

    private func updateStreamingItem() {
        streamFlush?.cancel(); streamFlush = nil
        guard let id = streamingItemID, let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].kind = .assistant(text: assembler.text, reasoning: assembler.reasoning.isEmpty ? nil : assembler.reasoning, streaming: true)
        if let started = turnStartedAt, Date().timeIntervalSince(lastStatsUpdate) > 0.5 {
            lastStatsUpdate = Date()
            items[idx].stats = TurnStats.make(outputBefore: nil, outputAfter: nil, streamedCharacters: streamedCharactersThisTurn, seconds: Date().timeIntervalSince(started))
        }
        // Keep the Live Activity's token count and elapsed state fresh: about once a second while streaming.
        if Date().timeIntervalSince(lastActivityUpdate) > 1 { lastActivityUpdate = Date(); activity.update(for: self, attention: false) }
    }

    private func sealStreamingForTool() {
        guard let id = streamingItemID, let idx = items.firstIndex(where: { $0.id == id }) else { return }
        sealedTurnText += assembler.text
        if assembler.text.isEmpty { items.remove(at: idx) } else {
            items[idx].kind = .assistant(text: assembler.text, reasoning: assembler.reasoning.isEmpty ? nil : assembler.reasoning, streaming: false)
        }
        streamingItemID = nil
        assembler.reset()
    }

    /// Returns the index of the turn's final assistant bubble, if one is on screen.
    @discardableResult
    private func finishStreaming(finalText: String?) -> Int? {
        // `finalText` is the whole assistant turn. When tool calls split the stream, the leading
        // part is already on screen in earlier bubbles, so only the remainder belongs in the
        // trailing one — otherwise the entire reply is rendered twice.
        let tail = finalText.map { StreamAssembler.tail(ofFinalText: $0, alreadySealed: sealedTurnText) }
        var result: Int?
        if let id = streamingItemID, let idx = items.firstIndex(where: { $0.id == id }) {
            let text = assembler.complete(finalText: tail)
            if text.isEmpty { items.remove(at: idx) }
            else { items[idx].kind = .assistant(text: text, reasoning: assembler.reasoning.isEmpty ? nil : assembler.reasoning, streaming: false); result = idx }
        } else if let tail, !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(TranscriptItem(id: UUID().uuidString, kind: .assistant(text: tail, reasoning: nil, streaming: false)))
            result = items.count - 1
        }
        if result == nil { result = items.lastIndex { if case .assistant = $0.kind { return true }; return false } }
        streamingItemID = nil
        sealedTurnText = ""
        assembler.reset()
        return result
    }
}
