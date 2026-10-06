import Foundation
import UIKit
import VoryCore
import WatchConnectivity

/// Sends every saved gateway (and its secrets) to the paired watch as the application context —
/// latest wins, delivered when the watch is reachable, end-to-end encrypted by the system.
/// WCSession calls its delegate on a background queue; those entry points are nonisolated and
/// hop back to the main actor, where the store lives.
@MainActor
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()
    private var pending: ConnectionStore?
    private weak var lastStore: ConnectionStore?
    private var refreshTask: Task<Void, Never>?
    /// Settings › Vory Summaries › Send to Apple Watch.
    static let summariesToWatchKey = "chats.aiSummaries.watch"
    static var summariesToWatch: Bool { UserDefaults.standard.bool(forKey: summariesToWatchKey) }

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func push(store: ConnectionStore) {
        lastStore = store
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { pending = store; return }
        let secrets = Self.contextSecrets(store)
        guard let cdata = try? JSONEncoder().encode(store.connections), let sdata = try? JSONEncoder().encode(secrets) else { return }
        var ctx: [String: Any] = ["connections": cdata, "secrets": sdata, "sent": Date().timeIntervalSince1970]
        if let a = store.activeConnectionID { ctx["active"] = a.uuidString }
        // The bots as this phone draws them (shape, eyes, colour, photo thumbnail): the watch
        // draws the same faces from this, static.
        if let looks = try? JSONEncoder().encode(BotLooks.load()) { ctx["looks"] = looks }
        // Vory Summaries, made here by Apple Intelligence, so the watch shows them without
        // running a model of its own.
        if Self.summariesToWatch, let s = try? JSONEncoder().encode(ChatSummarizer.shared.summaries) { ctx["summaries"] = s }
        do { try session.updateApplicationContext(ctx) } catch {
            // Too big (photo looks and summaries add up): the gateways and looks still go, the
            // summaries wait for a smaller day. Silently dropping the whole context left the
            // watch without its gateways.
            ctx["summaries"] = nil
            do { try session.updateApplicationContext(ctx) } catch {
                ctx["looks"] = nil
                try? session.updateApplicationContext(ctx)
            }
        }
    }

    /// The secrets the watch gets: what signs a call, never the refresh token. With both devices
    /// rotating one session, the next context overwrote the watch's newer secrets with the
    /// phone's older ones.
    static func contextSecrets(_ store: ConnectionStore) -> [String: GatewaySecrets] {
        var secrets: [String: GatewaySecrets] = [:]
        for c in store.connections {
            var s = store.secrets(for: c.id)
            s.refreshToken = nil
            secrets[c.id.uuidString] = s
        }
        return secrets
    }

    /// Re-send the context after looks or summaries changed, coalesced: summaries arrive one
    /// chat at a time and each would otherwise be a full context update.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let store = lastStore else { return }
            push(store: store)
        }
    }

    private func flushPending() {
        if let s = pending { pending = nil; push(store: s) }
    }

    /// The watch cannot open WebSockets over the phone's Bluetooth link, so it asks the phone to
    /// submit prompts and answer approvals, and makes its HTTP calls through it when its own
    /// route does not reach the gateway. `sendMessage` wakes this app in the background; the
    /// background task keeps it awake until the answer is sent.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = UncheckedBox(replyHandler)
        let incoming = UncheckedBox(message)
        Task { @MainActor in
            let hold = WatchRequestHold(reply: reply.value)
            hold.finish(await WatchSync.handle(incoming.value))
        }
    }

    @MainActor
    static func handle(_ m: [String: Any]) async -> [String: Any] {
        guard let model = AppDelegate.model, let op = m["op"] as? String else { return ["ok": false, "error": "app not ready"] }
        switch op {
        case RelayWire.op: return await relay(m, model: model)
        case RelayWire.putOp: return RelayParts.put(m)
        case RelayWire.partOp: return RelayParts.part(m)
        default: break
        }
        if model.runtime == nil, let c = model.store.active { await model.activate(c) }
        guard let rt = model.runtime else { return ["ok": false, "error": "no gateway"] }
        // The phone acts on its own active gateway only: a chat on another one is refused, not
        // looked up (or created) on the wrong gateway.
        if let g = (m["gateway"] as? String).flatMap(UUID.init(uuidString:)), g != rt.connection.id {
            return ["ok": false, "error": "Your iPhone is using another gateway. Switch the iPhone to this one, or pick the iPhone's gateway on the watch."]
        }
        // The watch's bot goes with each call; the phone's own selection stays where the person
        // left it (switching it here changed the phone's list under them).
        let profile = (m["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if op == "new" {
            // The watch cannot open a socket over the phone link, so the phone creates the session.
            guard let chat = try? await rt.newChat(profile: profile) else { return ["ok": false, "error": "could not create a chat"] }
            return ["ok": true, "session": chat.storedID, "title": chat.title]
        }
        guard let sid = m["session"] as? String, let chat = try? await rt.openChat(storedID: sid, title: nil, profile: m["profile"] as? String, waitForResume: true) else { return ["ok": false, "error": "could not open the chat"] }
        if let e = chat.resumeError { return ["ok": false, "error": "The iPhone could not open the chat: \(e)"] }
        switch op {
        case "prompt":
            guard let text = m["text"] as? String, !text.isEmpty else { return ["ok": false, "error": "empty"] }
            // A failure is the watch's to show: "ok" while nothing was sent left it on "Working…".
            // Talk on the watch marks a spoken turn: short, plain answers, as on the phone.
            let voice: VoiceTurn? = m["voice"] as? Bool == true ? VoiceTurn() : nil
            if let problem = await chat.send(text, voice: voice), chat.resumeError != nil { return ["ok": false, "error": problem] }
            if !chat.isRunning, chat.queue.isEmpty, case .error(let why)? = chat.items.last?.kind { return ["ok": false, "error": why] }
            return ["ok": true, "running": chat.isRunning]
        case "approval":
            guard let rid = m["card"] as? String, let choice = m["choice"] as? String, let card = chat.cards.first(where: { $0.id == rid }) else { return ["ok": false, "error": "no such card"] }
            await chat.respond(card: card, result: ["choice": .string(choice)])
            return ["ok": true]
        case "answer":
            guard let rid = m["card"] as? String, let card = chat.cards.first(where: { $0.id == rid }) else { return ["ok": false, "error": "no such card"] }
            let key = card.method == "clarify" ? "answer" : "value"
            await chat.respond(card: card, result: .object([key: .string(m["text"] as? String ?? "")]))
            return ["ok": true]
        case "cards":
            let cards: [[String: Any]] = chat.cards.map { c in
                ["id": c.id, "method": c.method,
                 "text": c.approval?.description ?? c.approval?.command ?? c.clarify?.question ?? c.clarify?.questions?.first?.question ?? c.valuePrompt?.prompt ?? ""]
            }
            // The watch shows what the bot is working on when this iPhone has written it (the
            // watch runs no model), else the step it is on.
            return ["ok": true, "running": chat.isRunning, "status": ChatGoals.shared.goal(for: chat.storedID) ?? chat.statusLine ?? "", "cards": cards]
        case "stop":
            await chat.stop(); return ["ok": true]
        default:
            return ["ok": false, "error": "unknown op"]
        }
    }

    /// An HTTP call the watch makes through this phone: signed with this phone's credentials
    /// for the watch's gateway, the answer compressed and, when big, in parts.
    @MainActor
    private static func relay(_ m: [String: Any], model: AppModel) async -> [String: Any] {
        // Failures before the gateway was asked are "unavailable": the watch tries its own route.
        var assembled: Data?
        if let ref = m["bodyRef"] as? String {
            guard let d = RelayParts.assemble(ref, parts: m["parts"] as? Int ?? 0) else { return RelayWire.unavailable("Part of the request was lost on the way from the watch.") }
            assembled = d
        }
        guard let request = RelayWire.request(from: m, assembled: assembled) else { return RelayWire.unavailable("The iPhone could not read the request.") }
        guard let api = api(for: m["gateway"] as? String, model: model) else { return RelayWire.unavailable("This gateway is not on the iPhone any more.") }
        do {
            let answer = try await api.forward(request)
            return RelayParts.reply(answer)
        } catch {
            return RelayWire.failure(error)
        }
    }

    /// The client for the watch's gateway: the running one when it is the phone's active
    /// gateway, else one made from the saved credentials, renewing its sign-in as the app does.
    @MainActor
    private static func api(for gateway: String?, model: AppModel) -> HermesAPI? {
        let wanted = gateway.flatMap(UUID.init(uuidString:)) ?? model.store.activeConnectionID
        if let rt = model.runtime, rt.connection.id == wanted { return rt.api }
        guard let id = wanted, let c = model.store.connection(id: id) else { return nil }
        let store = model.store
        let secrets = store.secrets(for: id)
        // Kept while the credentials are the same: a sign-in on the phone makes a new one.
        if let cached = spareAPIs[id], cached.secrets == secrets, cached.gateway == c.gateway { return cached.api }
        let api = HermesAPI(gateway: c.gateway, signer: RequestSigner(authMode: c.authMode, secrets: secrets))
        Task { await api.setRefresher { @MainActor in
            let renewed = try await NativeAuthClient.refresh(gateway: c.gateway, secrets: store.secrets(for: id))
            store.saveSecrets(renewed, for: id)
            return RequestSigner(authMode: c.authMode, secrets: renewed)
        } }
        spareAPIs[id] = (secrets, c.gateway, api)
        return api
    }
    @MainActor private static var spareAPIs: [UUID: (secrets: GatewaySecrets, gateway: GatewayURL, api: HermesAPI)] = [:]

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.flushPending() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.flushPending() }
    }
}

/// Bodies too big for one message, by id: a request's parts as they arrive from the watch, and
/// an answer's parts until the watch has fetched them. Anything a minute old is dropped.
@MainActor
enum RelayParts {
    private static var uploads: [String: (at: Date, parts: [Int: Data])] = [:]
    private static var answers: [String: (at: Date, parts: [Data])] = [:]

    private static func prune() {
        let cutoff = Date().addingTimeInterval(-60)
        uploads = uploads.filter { $0.value.at > cutoff }
        answers = answers.filter { $0.value.at > cutoff }
    }

    static func put(_ m: [String: Any]) -> [String: Any] {
        prune()
        guard let id = m["id"] as? String, let i = m["index"] as? Int, let d = m["part"] as? Data else { return ["ok": false, "error": "bad part"] }
        var entry = uploads[id] ?? (Date(), [:])
        entry.parts[i] = d
        uploads[id] = entry
        return ["ok": true]
    }

    static func assemble(_ id: String, parts: Int) -> Data? {
        guard let entry = uploads.removeValue(forKey: id), parts > 0, entry.parts.count == parts else { return nil }
        var out = Data()
        for i in 0..<parts { guard let d = entry.parts[i] else { return nil }; out.append(d) }
        return out
    }

    static func reply(_ answer: RelayedResponse) -> [String: Any] {
        prune()
        let parts = RelayWire.split(RelayWire.compress(answer.body))
        var more: String?
        if parts.count > 1 {
            let id = UUID().uuidString
            answers[id] = (Date(), parts)
            more = id
        }
        return RelayWire.reply(answer, firstPart: parts[0], more: more, parts: parts.count)
    }

    static func part(_ m: [String: Any]) -> [String: Any] {
        guard let id = m["id"] as? String, let i = m["index"] as? Int, let entry = answers[id], i > 0, i < entry.parts.count else {
            return ["ok": false, "error": "That answer is gone; ask again."]
        }
        if i == entry.parts.count - 1 { answers[id] = nil }
        return ["ok": true, "part": entry.parts[i]]
    }
}

/// A watch request in flight: keeps the phone awake until the answer is sent, and answers
/// with an error if the system ends the background time first (the app was killed for a task
/// left running). The watch gets exactly one answer.
@MainActor
final class WatchRequestHold {
    private let reply: ([String: Any]) -> Void
    private var task = UIBackgroundTaskIdentifier.invalid
    private var answered = false

    init(reply: @escaping ([String: Any]) -> Void) {
        self.reply = reply
        task = UIApplication.shared.beginBackgroundTask(withName: "watch-request") { [weak self] in
            MainActor.assumeIsolated { self?.finish(RelayWire.unavailable("The iPhone ran out of background time.")) }
        }
    }

    func finish(_ result: [String: Any]) {
        if !answered { answered = true; reply(result) }
        if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
    }
}

/// WCSession's reply handler is not Sendable; it is invoked exactly once from the main actor.
final class UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
