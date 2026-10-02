import Foundation
import Observation
import UserNotifications
import VoryCore
import WatchConnectivity
import WatchKit
import WidgetKit

/// The watch's app state: gateways (synced from the iPhone over WatchConnectivity, or typed in),
/// the live runtime from VoryCore, push registration for complications, and routing.
@MainActor
@Observable
final class WatchModel {
    let store = ConnectionStore()
    let push = WatchPushRegistrar()
    private(set) var runtime: GatewayRuntime?
    var sessions: [StoredSession] = []
    var loadError: String?
    var pendingChat: String?
    /// A complication tapped: open the Activity page (working chats, approvals waiting).
    var pendingActivity = false
    var syncStatus = "Waiting for iPhone…"
    /// nil = the selected profile; "*" = every profile merged.
    var listProfile: String?
    let connectivity = WatchConnectivityBridge()
    /// The bots as the iPhone draws them, sent over with the gateways; the watch draws the
    /// same faces, still.
    var looks = BotLooks.load()
    /// Vory Summaries made on the iPhone (Settings › Vory Summaries › Send to Apple Watch),
    /// keyed by session id; the watch never runs a model of its own.
    var summaries: [String: WatchSummary] = WatchSummary.loadCache()
    struct WatchSummary: Codable { var title: String; var summary: String; var stamp: Double
        static let cacheKey = "watch.summaries"
        static func loadCache() -> [String: WatchSummary] {
            guard let d = UserDefaults.standard.data(forKey: cacheKey) else { return [:] }
            return (try? JSONDecoder().decode([String: WatchSummary].self, from: d)) ?? [:]
        }
    }
    /// The summary for a chat when the phone made one for its current state.
    func summary(for s: StoredSession) -> WatchSummary? {
        guard let m = summaries[s.id] else { return nil }
        if let last = s.lastActive, abs(m.stamp - last) > 1 { return nil }
        return m
    }

    var hasConnections: Bool { !store.connections.isEmpty }

    func start() async {
        connectivity.onContext = { [weak self] ctx in Task { @MainActor in self?.receive(context: ctx) } }
        connectivity.activate()
        #if DEBUG
        // Simulator/e2e only: seed a gateway from the environment instead of typing it on a watch.
        let env = ProcessInfo.processInfo.environment
        if store.connections.isEmpty, let u = env["VORY_E2E_URL"], let t = env["VORY_E2E_TOKEN"], let g = try? GatewayURL.normalize(u, pathPrefix: nil) {
            let conn = GatewayConnection(name: "Workshop", gateway: g, authMode: .sessionToken)
            try? store.upsert(conn, secrets: GatewaySecrets(sessionToken: t))
        }
        #endif
        if let c = store.active { await activate(c) }
    }

    func activate(_ connection: GatewayConnection) async {
        if let rt = runtime {
            if rt.connection.id == connection.id { return }
            await rt.stop()
        }
        store.activeConnectionID = connection.id
        let rt = GatewayRuntime(connection: connection, store: store)
        rt.pushRegistrar = push
        rt.cardNotifier = WatchCardNotifier()
        rt.onSnapshotPublished = { _ in WidgetCenter.shared.reloadAllTimelines() }
        runtime = rt
        await rt.start()
        await loadSessions()
    }

    /// How many chats the list holds; "Show more" at the end raises it.
    var listLimit = 8
    var loadingMore = false
    var hasMore = true
    private var cacheKey: String { "watch.sessions." + (runtime?.connection.id.uuidString ?? "-") + "." + (listProfile ?? runtime?.selectedProfile ?? "-") }

    /// The list, in three steps so the wrist never waits on the slowest one: the last list this
    /// watch saw (at once), a short page from the gateway, then the rest in the background.
    func loadSessions() async {
        guard let rt = runtime else { return }
        if sessions.isEmpty, let d = UserDefaults.standard.data(forKey: cacheKey), let cached = try? JSONDecoder().decode([StoredSession].self, from: d) {
            sessions = cached
        }
        await fetchSessions(limit: listLimit)
    }

    /// The next page: more rows from the same query.
    func loadMore() async {
        guard hasMore, !loadingMore else { return }
        loadingMore = true; defer { loadingMore = false }
        listLimit += 12
        await fetchSessions(limit: listLimit)
    }

    private func fetchSessions(limit: Int) async {
        guard let rt = runtime else { return }
        do {
            var out: [StoredSession] = []
            if listProfile == "*" {
                // Every bot at once, not one after another: the slow path over Bluetooth.
                try await withThrowingTaskGroup(of: [StoredSession].self) { group in
                    for p in rt.profiles.map(\.name) {
                        group.addTask {
                            guard let r: SessionListResponse = try? await rt.api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: String(max(6, limit / 2)))], profile: p) else { return [] }
                            return r.sessions.map { var s = $0; if s.profile == nil || s.profile!.isEmpty { s.profile = p }; return s }
                        }
                    }
                    for try await part in group { out += part }
                }
                out.sort { ($0.lastActive ?? 0) > ($1.lastActive ?? 0) }
            } else {
                let r: SessionListResponse = try await rt.api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: String(limit))], profile: listProfile ?? rt.selectedProfile)
                out = r.sessions
            }
            hasMore = out.count >= limit
            sessions = out
            if let d = try? JSONEncoder().encode(Array(out.prefix(30))) { UserDefaults.standard.set(d, forKey: cacheKey) }
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }

    /// Whether the live socket is usable; false over the phone's Bluetooth link, where only HTTP works.
    var socketUsable: Bool { if case .open? = runtime?.socketState { return true }; return false }

    /// Background refresh for a complication push.
    func refreshForWidgets() async {
        if runtime == nil, let c = store.active { await activate(c) }
        runtime?.publishSnapshot(refreshSessions: true)
        try? await Task.sleep(for: .seconds(2))
    }

    func syncPush() async { if let rt = runtime { await push.syncRegistration(runtime: rt) } }

    // MARK: iPhone → watch credential sync

    /// The phone sends every saved gateway plus its secrets as one application context.
    private func receive(context: [String: Any]) {
        if let ldata = context["looks"] as? Data, let l = try? JSONDecoder().decode(BotLooks.self, from: ldata) {
            l.save(); looks = l
        }
        if let sdata = context["summaries"] as? Data, let m = try? JSONDecoder().decode([String: WatchSummary].self, from: sdata) {
            summaries = m; UserDefaults.standard.set(sdata, forKey: WatchSummary.cacheKey)
        } else if context["summaries"] == nil, !summaries.isEmpty {
            // The switch on the phone went off: the list goes back to the gateway's text.
            summaries = [:]; UserDefaults.standard.removeObject(forKey: WatchSummary.cacheKey)
        }
        guard let cdata = context["connections"] as? Data, let sdata = context["secrets"] as? Data,
              let connections = try? JSONDecoder().decode([GatewayConnection].self, from: cdata),
              let secrets = try? JSONDecoder().decode([String: GatewaySecrets].self, from: sdata) else { return }
        for c in connections {
            if let s = secrets[c.id.uuidString] { try? store.upsert(c, secrets: s) }
        }
        syncStatus = "Synced \(connections.count) gateway\(connections.count == 1 ? "" : "s") from iPhone"
        let activeID = (context["active"] as? String).flatMap(UUID.init(uuidString:))
        if let target = activeID.flatMap({ store.connection(id: $0) }) ?? store.active ?? connections.first {
            Task { await activate(target) }
        }
    }

    // MARK: Routing

    func open(_ url: URL) {
        guard url.scheme == "vory" else { return }
        if url.host == "chat", let id = url.pathComponents.dropFirst().first { pendingChat = id }
        else if url.host == "activity" || url.host == "chats" { pendingActivity = true }
    }

    func route(from userInfo: [AnyHashable: Any], action: String?, replyText: String?) {
        guard let hermes = userInfo["hermes"] as? [String: Any], let sid = hermes["session_id"] as? String else { return }
        pendingChat = sid
        guard let rt = runtime, let action else { return }
        Task {
            guard let chat = try? await rt.openChat(storedID: sid, title: nil, profile: hermes["profile"] as? String) else { return }
            if action == WatchNotifier.replyAction, let text = replyText, !text.isEmpty { await chat.send(text); return }
            let choice = action == WatchNotifier.approveOnceAction ? "once" : "deny"
            let deadline = Date().addingTimeInterval(8)
            while chat.cards.isEmpty, Date() < deadline { try? await Task.sleep(for: .milliseconds(250)) }
            if let card = chat.cards.first(where: { $0.method == "approval" }) { await chat.respond(card: card, result: ["choice": .string(choice)]) }
        }
    }
}

/// WCSession plumbing; callbacks arrive off the main thread and are hopped by the model.
final class WatchConnectivityBridge: NSObject, WCSessionDelegate {
    nonisolated(unsafe) var onContext: (([String: Any]) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let ctx = session.receivedApplicationContext
        if !ctx.isEmpty { onContext?(ctx) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        onContext?(applicationContext)
    }

    /// Ask the phone to do something the watch cannot (submit a prompt, answer a card) and wait.
    func request(_ message: [String: Any]) async throws -> [String: Any] {
        let s = WCSession.default
        guard s.activationState == .activated, s.isReachable else { throw WatchProxyError.phoneUnreachable }
        let boxed: SendableDict = try await withCheckedThrowingContinuation { (c: CheckedContinuation<SendableDict, Error>) in
            let box = ReplyBox(c)
            s.sendMessage(message, replyHandler: { r in box.resume(with: .success(SendableDict(r))) }, errorHandler: { e in box.resume(with: .failure(e)) })
        }
        return boxed.value
    }
}

/// `[String: Any]` from WCSession, carried across the continuation boundary.
struct SendableDict: @unchecked Sendable { let value: [String: Any]; init(_ v: [String: Any]) { value = v } }

/// A continuation that may be resumed from either WCSession callback, but only once.
private final class ReplyBox: @unchecked Sendable {
    private var c: CheckedContinuation<SendableDict, Error>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<SendableDict, Error>) { self.c = c }
    func resume(with r: Result<SendableDict, Error>) { lock.lock(); let cc = c; c = nil; lock.unlock(); cc?.resume(with: r) }
}

enum WatchProxyError: LocalizedError {
    case phoneUnreachable
    var errorDescription: String? { "Your iPhone is not reachable. Sending from the watch needs the phone nearby (or the watch on Wi-Fi)." }
}

/// Registers the watch for `complication` pushes: `platform: watchos`, its own bundle id.
@MainActor
@Observable
final class WatchPushRegistrar: PushRegistrationSyncing {
    var deviceToken: String?
    var lastError: String?
    var registeredAt: Date?
    let installID: String

    init() {
        if let s = UserDefaults.standard.string(forKey: "pushInstallID") { installID = s }
        else { let s = UUID().uuidString.lowercased(); UserDefaults.standard.set(s, forKey: "pushInstallID"); installID = s }
    }

    func syncRegistration(runtime: GatewayRuntime) async {
        guard let token = deviceToken, let home = runtime.profileHome else { return }
        let path = "\(home)/push/devices/\(installID)-watch.json"
        #if DEBUG
        let env = "development"
        #else
        let env = "production"
        #endif
        if PushRelay.isConfigured {
            try? await PushRelay.register(deviceToken: token, platform: "watchos", bundleID: Bundle.main.bundleIdentifier ?? "", environment: env)
        }
        var payload: [String: JSONValue] = [
            "schema": 1, "device_id": .string(installID + "-watch"), "platform": "watchos", "app": "Vory",
            "bundle_id": .string(Bundle.main.bundleIdentifier ?? ""), "apns_token": .string(token), "apns_environment": .string(env),
            "gateway": .string(runtime.connection.gateway.description), "connection_name": .string(runtime.connection.name),
            "device_name": .string(WKInterfaceDevice.current().name),
            "registered_at": .string(ISO8601DateFormatter().string(from: Date())),
        ]
        payload.merge(PushRelay.deviceFileFields()) { $1 }
        do {
            let data = try JSONEncoder().encode(JSONValue.object(payload))
            let body: JSONValue = ["path": .string(path), "data_url": .string("data:application/json;base64," + data.base64EncodedString()), "overwrite": true]
            let _: ManagedUploadResult = try await runtime.api.send("POST", "/api/files/upload", json: body)
            registeredAt = Date(); lastError = nil
        } catch { lastError = error.localizedDescription }
    }
}

/// Local notifications while the watch app is in the background; mirrors the phone's categories
/// so mirrored iPhone notifications show the same actions here.
@MainActor
final class WatchCardNotifier: CardNotifying {
    func cardArrived(_ card: PendingCard, chat: ChatSession) {
        guard WKApplication.shared().applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(chat.profileName) · \(card.method == "approval" ? "approval needed" : "question")"
        content.subtitle = chat.title
        content.body = card.approval?.description ?? card.approval?.command ?? card.clarify?.question ?? "Needs your answer"
        content.categoryIdentifier = card.method == "approval" ? WatchNotifier.approvalCategory : WatchNotifier.clarifyCategory
        content.userInfo = ["hermes": ["session_id": chat.storedID, "kind": card.method]]
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "card-\(card.id)", content: content, trigger: nil))
    }

    func turnFinished(chat: ChatSession, error: String?) {
        guard WKApplication.shared().applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = chat.profileName
        content.subtitle = chat.title
        if let error, !error.isEmpty { content.body = error } else if case .assistant(let text, _, _)? = chat.items.last(where: { if case .assistant = $0.kind { return true }; return false })?.kind { content.body = String(text.prefix(160)) } else { content.body = "Turn finished" }
        content.categoryIdentifier = WatchNotifier.turnCategory
        content.userInfo = ["hermes": ["session_id": chat.storedID, "kind": "turn"]]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "turn-\(chat.storedID)-\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil))
    }
}

enum WatchNotifier {
    static let approvalCategory = "HERMES_APPROVAL"
    static let clarifyCategory = "HERMES_CLARIFY"
    static let turnCategory = "HERMES_TURN"
    static let approveOnceAction = "HERMES_APPROVE_ONCE"
    static let denyAction = "HERMES_DENY"
    static let replyAction = "HERMES_REPLY"

    static func registerCategories() {
        let approve = UNNotificationAction(identifier: approveOnceAction, title: "Approve once", options: [])
        let deny = UNNotificationAction(identifier: denyAction, title: "Deny", options: [.destructive])
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: approvalCategory, actions: [approve, deny], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: clarifyCategory, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: turnCategory, actions: [reply], intentIdentifiers: [], options: []),
        ])
    }
}
