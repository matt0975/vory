import Foundation
import Observation
import OSLog
import UniformTypeIdentifiers

public struct QueuedMessage: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var text: String
    /// Set when the message was spoken (hands-free): it goes out with the voice params.
    public var voice: VoiceTurn? = nil

    public init(text: String, voice: VoiceTurn? = nil) {
        self.text = text
        self.voice = voice
    }
}

/// What a spoken turn carries beyond its words (tui_gateway/methods_prompt.py, prompt.submit):
/// `surface: "voice-live"` has the gateway prepend its spoken-conversation note to the MODEL
/// INPUT only (a transcript in, short plain sentences out; the stored user row stays the words
/// said), `voice_context` the recent spoken exchange so "yes" and "Thursday, not Friday" make
/// sense, `interrupted` that the bot's last reply was cut off by the person.
public struct VoiceTurn: Hashable, Sendable {
    public static let surface = "voice-live"
    /// The gateway keeps at most this much of the context.
    public static let contextLimit = 6000
    public var context: String
    public var interrupted: Bool

    public init(context: String = "", interrupted: Bool = false) {
        self.context = context
        self.interrupted = interrupted
    }

    func apply(to params: inout [String: JSONValue]) {
        params["surface"] = .string(Self.surface)
        if !context.isEmpty { params["voice_context"] = .string(String(context.suffix(Self.contextLimit))) }
        if interrupted { params["interrupted"] = true }
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
    /// True from this device's own submit until its turn ends.
    private var startedHere = false
    /// A turn's first event arrived for a prompt this device did not send: its snapshot is
    /// being fetched (once).
    private var adoptingTurn = false
    /// The events that open a turn. One of these on an idle chat means the prompt was sent
    /// from another device that has the same chat open.
    private static let turnOpeners: Set<String> = ["message.start", "reasoning.delta", "thinking.delta", "tool.start"]
    /// Events that mean the bot is doing something again.
    private static let turnMovers: Set<String> = ["message.delta", "reasoning.delta", "thinking.delta", "tool.start", "tool.complete"]

    /// The gateway sends a chat's events to every device that has it open, but the events
    /// carry the reply, not the prompt. When a turn starts that this device did not ask for,
    /// the session's snapshot is fetched once: it has the prompt in flight, so the other
    /// device's message appears here with the reply streaming under it.
    private func adoptTurnStartedElsewhere() {
        adoptingTurn = true
        Task { [weak self] in
            guard let self else { return }
            if let r = try? await rpc("session.resume", ["session_id": .string(storedID), "cols": 80]) { apply(snapshot: r) }
            adoptingTurn = false
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
    /// Why the latest turn was cut short, when this device can tell: Stop pressed here, or the
    /// app away from the gateway while the turn ran. Cleared by the next message.
    public var interruptCause: InterruptedTurn.Cause?
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
            items = TranscriptItem.fromHistory(cached)
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
        items = TranscriptItem.fromHistory(msgs)
    }

    private func saveTranscriptCache() {
        TranscriptCache.save(items, connection: runtime.connection.id, storedID: storedID)
    }

    /// Whether a snapshot's in-flight prompt is already the last user row of its messages. With
    /// the turn's start time known, that row must be from this turn; without it the text decides.
    public nonisolated static func inflightPromptIsListed(prompt: String, lastUserText: String?, lastUserAt: Double?, turnStart: Double) -> Bool {
        guard let lastUserText, lastUserText == prompt else { return false }
        guard turnStart > 0, let lastUserAt else { return true }
        return lastUserAt >= turnStart - 1
    }

    /// A snapshot's rows under the ids of the rows already shown that say the same thing. The
    /// gateway numbers a turn's rows once it has stored them, so a turn that was watched as it
    /// streamed (its rows named on the way in) came back under new ids in the next snapshot, and
    /// the thread took out every one of those rows and put it back. Rows are paired in order,
    /// looking a few rows ahead for the notes only this device shows.
    public nonisolated static func keepingIDs(_ built: [TranscriptItem], from shown: [TranscriptItem]) -> [TranscriptItem] {
        func said(_ item: TranscriptItem) -> String? {
            switch item.kind {
            case .user(let t, _): return "u" + t.trimmingCharacters(in: .whitespacesAndNewlines)
            case .assistant(let t, _, let streaming): return streaming ? nil : "a" + t.trimmingCharacters(in: .whitespacesAndNewlines)
            case .tool(let act): return "t" + act.name
            default: return nil
            }
        }
        var out = built
        var next = 0
        var taken = Set<String>()
        for i in out.indices {
            if let words = said(out[i]),
               let j = shown[next...].prefix(6).firstIndex(where: { said($0) == words }), !taken.contains(shown[j].id) {
                out[i].id = shown[j].id
                next = j + 1
            } else if taken.contains(out[i].id) {
                // Its own id went to an earlier row (rows shifted under it): never two rows with one id.
                out[i].id += "-\(i)"
            }
            taken.insert(out[i].id)
        }
        return out
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
        let running = r["running"]?.boolValue ?? info?.running ?? false
        // Replies already finished on screen stay replies while another turn starts.
        let settled = Set(items.compactMap { item -> String? in
            if case .assistant(let t, _, false) = item.kind, !t.isEmpty { return StreamAssembler.normalized(t) }
            return nil
        })
        let built = TranscriptItem.fromHistory(history, running: running, settled: settled).map { item -> TranscriptItem in
            var item = item
            if case .user(let t, let a) = item.kind, a.isEmpty, let k = keptAttachments[t] { item.kind = .user(text: t, attachments: k) }
            return item
        }
        // The reply streaming now is put back under its own id below; it is not history's.
        items = Self.keepingIDs(built, from: items.filter { $0.id != streamingItemID })
        toolIndex = [:]
        cards = []
        cardShownAt = [:]
        isRunning = r["running"]?.boolValue ?? info?.running ?? false
        if let inflight = r["inflight"], !inflight.isNull {
            let user = inflight["user"]?.stringValue ?? ""
            let lastUser = items.last(where: { if case .user = $0.kind { return true }; return false })
            let lastUserText: String? = lastUser.flatMap { if case .user(let t, _) = $0.kind { return t }; return nil }
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
            // The prompt is already among the messages only when the last user row is this
            // turn's own. The same words sent twice in a row are two prompts: going by the text
            // alone, the second never appeared on a device that was watching.
            let alreadyListed = Self.inflightPromptIsListed(prompt: user, lastUserText: lastUserText,
                                                            lastUserAt: lastUser?.timestamp.timeIntervalSince1970, turnStart: turnStart)
            if !user.isEmpty, !alreadyListed {
                // One id per turn: an earlier turn's prompt may still be shown under its own.
                var promptID = "inflight-user-\(Int(turnStart))"
                if items.contains(where: { $0.id == promptID }) { promptID += "-\(items.count)" }
                var prompt = TranscriptItem(id: promptID, kind: .user(text: user, attachments: keptAttachments[user] ?? []))
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
                // A reply already streaming here (a turn adopted from another device: its first
                // event made the row, then this snapshot arrived) keeps its row: under a new id
                // the thread's last row would be taken out and put back while it is pinned to it.
                let id = streamingItemID ?? "stream-\(UUID().uuidString)"
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
        let asked = Date()
        lastApprovalCheck = asked
        guard let r = try? await rpc("approval.pending", ["session_id": .string(runtimeID)], timeout: 10) else { return }
        // The gateway's own list of what still waits, when it sent one (an older gateway
        // answers with a single approval, which says nothing about the others).
        let waiting = r["approvals"]?.arrayValue ?? r["pending"]?.arrayValue
        if let waiting {
            // An approval this device still shows that the gateway no longer lists was answered
            // somewhere else (another device with the chat open, the dashboard, a terminal):
            // nothing tells the other clients, so the card stayed up here for good. A card
            // younger than the question is left alone: it may have arrived after the gateway
            // made its list.
            let open = Set(waiting.compactMap { $0["request_id"]?.stringValue })
            let held = cards.filter { $0.method == "approval" }.compactMap { $0.approval?.requestId }
            log.notice("approval.pending: gateway lists \(open.sorted().joined(separator: ","), privacy: .public); held \(held.joined(separator: ","), privacy: .public)")
            for card in cards where card.method == "approval" {
                guard let rid = card.approval?.requestId, !open.contains(rid),
                      let shown = cardShownAt[card.id], shown.addingTimeInterval(Self.cardGrace) < asked else { continue }
                settleElsewhere(card)
            }
        }
        let list = waiting ?? (r["request_id"] != nil ? [r] : [])
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
    /// Sends a message (queued behind a running turn). `voice` marks a spoken turn: the gateway
    /// then answers in short plain sentences, with the recent spoken exchange in mind.
    public func send(_ rawText: String, voice: VoiceTurn? = nil) async -> String? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !staged.isEmpty else { return nil }
        await awaitResume()
        if let e = resumeError { return "This chat could not be opened on the gateway: \(e)" }
        if !text.isEmpty { composerHistory.append(text) }
        if text.hasPrefix("/"), staged.isEmpty { return await dispatchSlash(text) }
        if isRunning {
            queue.append(QueuedMessage(text: text, voice: voice))
            return nil
        }
        await submit(text: text, queued: false, voice: voice)
        return nil
    }

    private func submit(text: String, queued: Bool, voice: VoiceTurn? = nil) async {
        interruptCause = nil
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
        startedHere = true
        isRunning = true
        statusLine = "Sending…"
        do {
            var params: [String: JSONValue] = ["session_id": .string(runtimeID), "text": .string(outgoing)]
            if queued { params["queued"] = true }
            voice?.apply(to: &params)
            let r = try await rpc("prompt.submit", params)
            lastSubmitStatus = r["status"]?.stringValue
            if lastSubmitStatus == "queued" { statusLine = "Queued on the gateway" }
            activity.start(for: self)
            runtime.pushRegistrar?.noteSend(session: storedID, runtime: runtime)
        } catch {
            startedHere = false
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
        interruptCause = .stopped
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

    /// Voice mode is on for this chat with this state line (nil: it ended); the platform's turn
    /// surface shows it.
    public func noteVoiceMode(_ line: String?) { activity.voiceMode(for: self, line: line) }

    private func drainQueue() {
        guard !isRunning, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        Task { await submit(text: next.text, queued: true, voice: next.voice) }
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

    // MARK: Quick answers (voice)

    /// Voice mode is running with this chat's reasoning turned down and fast replies on.
    public private(set) var quickAnswersOn = false
    /// What voice mode puts back, kept on disk per session so an app killed mid-voice can
    /// restore it on the next open (`restoreQuickAnswersIfNeeded`).
    private static func quickRestoreKey(_ storedID: String) -> String { "voice.quick.restore." + storedID }
    /// The effort voice mode runs with; the gateway's levels go none … ultra.
    public static let quickEffort = "low"

    /// Voice mode begins: low reasoning and fast replies for this chat only, with what it had
    /// remembered so typed turns after are unaffected. Nothing when the setting is off.
    public func beginQuickAnswers() async {
        guard VoiceSettings.quickAnswers, !quickAnswersOn else { return }
        let before = ["reasoning": info?.reasoningEffort ?? "", "fast": (info?.fast ?? false) ? "on" : "off"]
        if !storedID.isEmpty { UserDefaults.standard.set(before, forKey: Self.quickRestoreKey(storedID)) }
        quickAnswersOn = true
        try? await setReasoning(Self.quickEffort)
        try? await setFast(true)
    }

    /// Voice mode ended: the chat's own reasoning and fast come back.
    public func endQuickAnswers() async {
        guard quickAnswersOn else { return }
        quickAnswersOn = false
        await restoreQuickAnswers(storedID.isEmpty ? nil : UserDefaults.standard.dictionary(forKey: Self.quickRestoreKey(storedID)) as? [String: String])
    }

    /// A chat opened after the app was killed mid-voice: what voice mode changed is put back.
    public func restoreQuickAnswersIfNeeded() async {
        guard !storedID.isEmpty, let before = UserDefaults.standard.dictionary(forKey: Self.quickRestoreKey(storedID)) as? [String: String] else { return }
        await restoreQuickAnswers(before)
    }

    private func restoreQuickAnswers(_ before: [String: String]?) async {
        if !storedID.isEmpty { UserDefaults.standard.removeObject(forKey: Self.quickRestoreKey(storedID)) }
        // Only what was recorded goes back; a chat that reported no effort of its own is left
        // to the gateway's own default rather than guessed at.
        if let effort = before?["reasoning"], !effort.isEmpty { try? await setReasoning(effort) }
        if let fast = before?["fast"] { try? await setFast(fast == "on") }
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

    /// When each card appeared here.
    private var cardShownAt: [String: Date] = [:]
    private var lastApprovalCheck = Date.distantPast
    /// A card this fresh is never taken for answered elsewhere.
    static let cardGrace: TimeInterval = 2

    /// A card this device shows was answered on another one (or its turn ended without it):
    /// it goes, whoever waits on it here is released, and the chat stops asking for attention.
    private func settleElsewhere(_ card: PendingCard) {
        guard cards.contains(where: { $0.id == card.id }) else { return }
        cards.removeAll { $0.id == card.id }
        cardShownAt[card.id] = nil
        // The gateway's reply slot stays open: answering it with nothing here read as a deny
        // when the gateway's list had simply missed the card (a tester's Once came back as
        // "Answered on another device" and a refusal). If the gateway really has its answer
        // it ignores a late one; the turn's end releases whatever still waits.
        if cards.isEmpty { runtime.setAttention(storedID: storedID, needed: false); activity.update(for: self, attention: false) }
        runtime.cardNotifier?.cardSettled(card, chat: self)
        items.append(TranscriptItem(id: UUID().uuidString, kind: .system(text: card.method == "approval" ? "Answered on another device" : "No longer waiting for an answer", symbol: "checkmark.shield")))
    }

    /// The turn is moving again while an approval card is showing: the bot was waiting on it,
    /// so it has probably been answered elsewhere. Asked at once rather than at the next poll.
    private func checkApprovalsIfTurnMovedOn() {
        guard cards.contains(where: { $0.method == "approval" }), Date().timeIntervalSince(lastApprovalCheck) > 1.5 else { return }
        lastApprovalCheck = Date()
        Task { await pollPendingApprovals() }
    }

    private func addCard(_ card: PendingCard) {
        guard !cards.contains(where: { $0.id == card.id }) else { return }
        cardShownAt[card.id] = Date()
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
        cardShownAt[card.id] = nil
        if cards.isEmpty { runtime.setAttention(storedID: storedID, needed: false); activity.update(for: self, attention: false) }
        if card.method == "approval" {
            runtime.pushRegistrar?.noteAnswer(requestID: card.approval?.requestId ?? card.id, session: storedID, runtime: runtime)
        }
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
        cardShownAt[id] = nil
        if cards.isEmpty { runtime.setAttention(storedID: storedID, needed: false) }
        if let c = inlineAnswers.removeValue(forKey: id) { c.resume(returning: .null) }
        items.append(TranscriptItem(id: UUID().uuidString, kind: .system(text: "Request withdrawn (\(reason)).", symbol: "xmark.circle")))
    }

    // MARK: Events

    public func handle(event ev: GatewayEvent) {
        let p = ev.payload
        if !startedHere, !isRunning, !adoptingTurn, !isResuming, Self.turnOpeners.contains(ev.type) { adoptTurnStartedElsewhere() }
        if ev.type == "message.complete" || ev.type == "error" { startedHere = false }
        if Self.turnMovers.contains(ev.type) { checkApprovalsIfTurnMovedOn() }
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
            if !delta.isEmpty { NotificationCenter.default.post(name: .hermesStreamDelta, object: nil, userInfo: ["storedID": storedID, "count": delta.count, "text": delta]) }
        case "reasoning.delta":
            if streamingItemID == nil { beginStreaming() }
            if statusLine != "Thinking…" { statusLine = "Thinking…" }
            assembler.appendReasoning(p["text"]?.stringValue ?? "")
            scheduleStreamingUpdate()
        case "thinking.delta":
            // The gateway's wait and spinner notices, not the model's reasoning: the status line
            // says so, the card stays the model's own thinking.
            if streamingItemID == nil { beginStreaming() }
            if statusLine != "Thinking…" { statusLine = "Thinking…" }
        case "reasoning.available":
            // Despite its name this is the reply's own text again (its first 500 characters),
            // sent after each model response: it put the opening of the answer, a table cut off
            // halfway, in the Reasoning card. The reply streams and completes on its own events.
            break
        case "message.interim":
            let text = p["text"]?.stringValue ?? ""
            if p["already_streamed"]?.boolValue == true { finishStreaming(finalText: text.isEmpty ? nil : text) }
            else if !text.isEmpty {
                finishStreaming(finalText: nil)
                items.append(TranscriptItem(id: UUID().uuidString, kind: .assistant(text: text, reasoning: nil, streaming: false)))
            }
        case "message.complete":
            let text = p["text"]?.stringValue
            let lastAssistantIndex = finishStreaming(finalText: text, gatewayReasoning: p["reasoning"]?.stringValue,
                                                     previewed: p["response_previewed"]?.boolValue == true)
            if let spoken = text, !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, p["status"]?.stringValue != "interrupted" {
                NotificationCenter.default.post(name: .hermesReplyCompleted, object: nil, userInfo: ["storedID": storedID, "text": spoken])
            }
            if let u = try? p["usage"]?.decode(Usage.self) { usage = u }
            if let idx = lastAssistantIndex, let started = turnStartedAt {
                items[idx].stats = TurnStats.make(outputBefore: outputTokensAtTurnStart, outputAfter: usage?.output,
                                                  streamedCharacters: streamedCharactersThisTurn + (text?.count ?? 0),
                                                  seconds: Date().timeIntervalSince(started))
            }
            turnStartedAt = nil
            let status = p["status"]?.stringValue
            if let err = p["error"]?.stringValue, !err.isEmpty { appendError(err) }
            // The gateway's own "Operation interrupted." message is shown as a card that says as much.
            else if status == "interrupted", InterruptedTurn.parse(text ?? "") == nil { items.append(TranscriptItem(id: UUID().uuidString, kind: .system(text: "Interrupted", symbol: "stop.circle"))) }
            if let w = p["warning"]?.stringValue, !w.isEmpty { banner = w }
            // A finished turn waits for nothing: a card still showing was answered elsewhere.
            for card in cards { settleElsewhere(card) }
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
        case let t where t.hasPrefix("subagent."):
            updateSubagent(t, p)
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

    /// One row per helper, made on whichever `subagent.*` event comes first and kept up to date
    /// by the rest (the official TUI does the same). The row used to be made on `start` and
    /// touched again only on `complete`, so a helper's tools and progress went nowhere.
    private func updateSubagent(_ type: String, _ p: JSONValue) {
        let rowID = SubagentActivity.rowID(for: p) ?? "sub-" + UUID().uuidString
        let idx = items.firstIndex { $0.id == rowID }
        let current: SubagentActivity? = idx.flatMap { if case .subagent(let a) = items[$0].kind { return a }; return nil }
        let act = SubagentActivity.applying(type, p, to: current)
        if let idx { items[idx].kind = .subagent(act) } else {
            // As with a tool call: what the bot says after its helpers goes in a new bubble below them.
            sealStreamingForTool()
            items.append(TranscriptItem(id: rowID, kind: .subagent(act)))
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
    private func finishStreaming(finalText: String?, gatewayReasoning: String? = nil, previewed: Bool = false) -> Int? {
        // The final reply already went out as an interim message (some runtimes send every
        // finished message that way) and nothing streamed since: the gateway says so with
        // `response_previewed`, and the bubble on screen is the reply. Appending it again showed
        // the answer twice.
        if previewed, let finalText, assembler.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let idx = items.lastIndex(where: { if case .assistant(let t, _, false) = $0.kind { return !t.isEmpty }; return false }),
           case .assistant(let shown, _, _) = items[idx].kind,
           shown.trimmingCharacters(in: .whitespacesAndNewlines) == finalText.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let id = streamingItemID { items.removeAll { $0.id == id } }
            streamingItemID = nil
            sealedTurnText = ""
            assembler.reset()
            return items.lastIndex { if case .assistant(let t, _, false) = $0.kind { return !t.isEmpty }; return false }
        }
        // `finalText` is the whole assistant turn. When tool calls split the stream, the leading
        // part is already on screen in earlier bubbles, so only the remainder belongs in the
        // trailing one — otherwise the entire reply is rendered twice.
        let tail = finalText.map { StreamAssembler.tail(ofFinalText: $0, alreadySealed: sealedTurnText) }
        var result: Int?
        if let id = streamingItemID, let idx = items.firstIndex(where: { $0.id == id }) {
            let streamed = assembler.text
            let text = assembler.complete(finalText: tail)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.remove(at: idx) }
            else {
                // An answer that came as reasoning (the gateway promoted it) is the reply, not a card.
                let reasoning = StreamAssembler.settledReasoning(streamedText: streamed, reasoning: assembler.reasoning, finalText: text, gatewayReasoning: gatewayReasoning)
                items[idx].kind = .assistant(text: text, reasoning: reasoning, streaming: false); result = idx
            }
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
