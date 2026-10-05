import Foundation
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
    /// submit prompts and answer approvals. `sendMessage` wakes this app in the background.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = UncheckedBox(replyHandler)
        let incoming = UncheckedBox(message)
        Task { @MainActor in
            let result = await WatchSync.handle(incoming.value)
            reply.value(result)
        }
    }

    @MainActor
    static func handle(_ m: [String: Any]) async -> [String: Any] {
        guard let model = AppDelegate.model, let op = m["op"] as? String else { return ["ok": false, "error": "app not ready"] }
        if model.runtime == nil, let c = model.store.active { await model.activate(c) }
        guard let rt = model.runtime else { return ["ok": false, "error": "no gateway"] }
        // The watch's bot goes with each call; the phone's own selection stays where the person
        // left it (switching it here changed the phone's list under them).
        let profile = (m["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if op == "new" {
            // The watch cannot open a socket over the phone link, so the phone creates the session.
            guard let chat = try? await rt.newChat(profile: profile) else { return ["ok": false, "error": "could not create a chat"] }
            return ["ok": true, "session": chat.storedID, "title": chat.title]
        }
        guard let sid = m["session"] as? String, let chat = try? await rt.openChat(storedID: sid, title: nil, profile: m["profile"] as? String, waitForResume: true) else { return ["ok": false, "error": "could not open the chat"] }
        switch op {
        case "prompt":
            guard let text = m["text"] as? String, !text.isEmpty else { return ["ok": false, "error": "empty"] }
            await chat.send(text)
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

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.flushPending() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.flushPending() }
    }
}

/// WCSession's reply handler is not Sendable; it is invoked exactly once from the main actor.
final class UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
