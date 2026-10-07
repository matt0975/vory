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
    /// The Overview or blocks complication tapped: open the Overview page.
    var pendingOverview = false
    /// The month in numbers, as the complications draw it; refreshed when the Overview page opens.
    var usage: WidgetSnapshot.Usage? = WidgetSnapshot.load()?.usage
    /// Gateways that came from the iPhone (by id), so one the phone drops is dropped here too
    /// while one typed on the watch stays.
    static let syncedGatewaysKey = "watch.syncedGateways"
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

    /// The phone link from the first moment, background launches included: a notification's
    /// Reply or a complication push that launched the app found it not yet activated.
    init() {
        connectivity.onContext = { [weak self] ctx in Task { @MainActor in self?.receive(context: ctx) } }
        connectivity.activate()
    }

    /// Settings › Connect through: the watch's own connection with the iPhone taking over when
    /// the gateway does not answer there (Automatic), or always the iPhone (no socket at all).
    static let routeKey = "watch.route"
    private(set) var route: GatewayRoute = GatewayRoute(rawValue: UserDefaults.standard.string(forKey: WatchModel.routeKey) ?? "") ?? .automatic
    /// Whether the last call that reached the gateway went through the iPhone.
    private(set) var throughPhone = false
    /// The phone's active gateway at the last sync: a sync moves the watch only when it changed.
    static let lastPhoneActiveKey = "watch.lastPhoneActive"

    func setRoute(_ r: GatewayRoute) async {
        guard r != route else { return }
        route = r
        UserDefaults.standard.set(r.rawValue, forKey: Self.routeKey)
        // The stored copy: it has the bot picked since the runtime started.
        if let id = runtime?.connection.id, let c = store.connection(id: id) { await activate(c, force: true) }
    }

    /// The latest activation: an older one that finishes after it gives way.
    private var activation = UUID()

    func start() async {
        #if DEBUG
        // Simulator/e2e only: seed a gateway from the environment instead of typing it on a watch.
        let env = ProcessInfo.processInfo.environment
        if store.connections.isEmpty, let u = env["VORY_E2E_URL"], let t = env["VORY_E2E_TOKEN"], let g = try? GatewayURL.normalize(u, pathPrefix: nil) {
            let conn = GatewayConnection(name: "Workshop", gateway: g, authMode: .sessionToken)
            try? store.upsert(conn, secrets: GatewaySecrets(sessionToken: t))
        }
        #endif
        if let c = store.active { await activate(c) }
        #if DEBUG
        // Simulator only: land on a page for a screenshot ("home", "activity", "chat/<id>").
        if let page = env["VORY_E2E_OPEN"], let url = URL(string: "vory://" + page) { open(url) }
        #endif
    }

    /// `force`: start the same gateway again (the route changed, or its address).
    func activate(_ connection: GatewayConnection, force: Bool = false) async {
        let token = UUID()
        activation = token
        if let rt = runtime {
            if rt.connection.id == connection.id, !force { return }
            await rt.stop()
            if rt.connection.id != connection.id {
                // Another gateway: its own list, from its own cache.
                sessions = []
                listLimit = 8
                hasMore = true
            }
        }
        store.activeConnectionID = connection.id
        let rt = GatewayRuntime(connection: connection, store: store)
        rt.pushRegistrar = push
        rt.cardNotifier = WatchCardNotifier()
        rt.onSnapshotPublished = { _ in WidgetCenter.shared.reloadAllTimelines() }
        // iPhone only opens no socket; the watch's HTTP goes by the route, the iPhone carrying
        // what its own connection cannot.
        rt.socketEnabled = route != .relayOnly
        rt.httpCountsAsOnline = true
        rt.throughRelay = route == .relayOnly
        throughPhone = route == .relayOnly
        let bridge = connectivity, gateway = connection.id.uuidString
        await rt.api.setRelay({ request in try await bridge.relay(request, gateway: gateway) }, route: route,
                              reachable: { WatchConnectivityBridge.phoneReachable }) { [weak self, weak rt] relayed in
            Task { @MainActor in if let rt { self?.noteRoute(relayed: relayed, runtime: rt) } }
        }
        // Another activation started while this one waited: it wins.
        guard activation == token else { await rt.stop(); return }
        runtime = rt
        await rt.start()
        await loadSessions()
    }

    private func noteRoute(relayed: Bool, runtime rt: GatewayRuntime) {
        guard runtime === rt else { return }
        throughPhone = relayed || route == .relayOnly
        // The complications read the flag from the snapshot: write it as soon as it changes.
        if rt.throughRelay != throughPhone { rt.throughRelay = throughPhone; rt.publishSnapshot() }
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
        // The bots, if the first try found neither route (the phone not yet within reach).
        if rt.profiles.isEmpty { await rt.loadProfiles() }
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
            // Pinned chats first, as on the phone; the gateway's order within each group.
            sessions = out.filter { $0.pinned == true } + out.filter { $0.pinned != true }
            if let d = try? JSONEncoder().encode(Array(out.prefix(30))) { UserDefaults.standard.set(d, forKey: cacheKey) }
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }

    /// A chat op the phone carries out for the watch, for this watch's gateway: the phone
    /// refuses one for a gateway other than its own active one instead of acting there.
    func askPhone(_ m: [String: Any]) async throws -> [String: Any] {
        var m = m
        if let id = runtime?.connection.id { m["gateway"] = id.uuidString }
        return try await connectivity.request(m)
    }

    /// Whether the watch's own live socket is open. watchOS lets a watch app open one only in
    /// narrow cases, and iPhone only never opens it; without it sending goes through the phone.
    var socketUsable: Bool { if case .open? = runtime?.socketState { return true }; return false }

    /// Background refresh for a complication push.
    func refreshForWidgets() async {
        if runtime == nil, let c = store.active { await activate(c) }
        runtime?.publishSnapshot(refreshSessions: true)
        // The complications cannot go through the iPhone: their numbers are refreshed here.
        if runtime?.throughRelay == true { await loadUsage() }
        try? await Task.sleep(for: .seconds(2))
    }

    func syncPush() async { if let rt = runtime { await push.syncRegistration(runtime: rt) } }

    /// The Overview page's numbers. What the snapshot holds shows at once; the gateway is asked
    /// only when that is older than half an hour, and the answer goes back into the snapshot so
    /// the complications draw the same thing.
    func loadUsage() async {
        if let u = WidgetSnapshot.load()?.usage {
            usage = u
            if Date().timeIntervalSince(u.updatedAt) < 1800 { return }
        }
        guard let rt = runtime else { return }
        let profile = listProfile == "*" ? rt.selectedProfile : (listProfile ?? rt.selectedProfile)
        guard let a: UsageAnalytics = try? await rt.api.get("/api/analytics/usage", query: [URLQueryItem(name: "days", value: "91")], profile: profile) else { return }
        // The watch holds a short list of chats: the message count and peak hour stay as the phone last worked them out.
        let u = WidgetSnapshot.Usage.make(analytics: a, sessions: nil, previous: usage)
        usage = u
        if var snap = WidgetSnapshot.load() {
            snap.usage = u
            snap.save()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

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
        // The running gateway takes what changed on the phone: a new address starts it again,
        // new credentials go to its client (they used to wait for the next launch).
        if let rt = runtime, let c = connections.first(where: { $0.id == rt.connection.id }) {
            if c.gateway != rt.connection.gateway || c.authMode != rt.connection.authMode {
                Task { await activate(c, force: true) }
            } else if let s = secrets[c.id.uuidString], s != rt.secrets {
                Task { await rt.replaceSecrets(s) }
            }
        }
        // A gateway the phone no longer has (removed there, or the phone was reset) goes here too.
        let incoming = Set(connections.map(\.id.uuidString))
        let previous = Set(UserDefaults.standard.stringArray(forKey: Self.syncedGatewaysKey) ?? [])
        for id in previous.subtracting(incoming) {
            guard let uuid = UUID(uuidString: id) else { continue }
            if let rt = runtime, rt.connection.id == uuid {
                Task { await rt.stop() }
                runtime = nil
                sessions = []
            }
            store.delete(id: uuid)
        }
        UserDefaults.standard.set(Array(incoming).sorted(), forKey: Self.syncedGatewaysKey)
        guard !store.connections.isEmpty else { syncStatus = "No gateway on the iPhone yet"; return }
        syncStatus = "Synced \(connections.count) gateway\(connections.count == 1 ? "" : "s") from iPhone"
        let activeID = (context["active"] as? String).flatMap(UUID.init(uuidString:))
        // Only when the phone's choice changed since the last sync: every context (a looks or
        // summary resend) moved the watch back to it over a gateway picked on the watch.
        let phoneMoved = activeID?.uuidString != UserDefaults.standard.string(forKey: Self.lastPhoneActiveKey)
        UserDefaults.standard.set(activeID?.uuidString, forKey: Self.lastPhoneActiveKey)
        if let target = activeID.flatMap({ store.connection(id: $0) }) ?? store.active ?? connections.first {
            if runtime == nil || (phoneMoved && runtime?.connection.id != target.id) { Task { await activate(target) } }
        }
    }

    // MARK: Routing

    func open(_ url: URL) {
        guard url.scheme == "vory" else { return }
        if url.host == "chat", let id = url.pathComponents.dropFirst().first { pendingChat = id }
        else if url.host == "activity" || url.host == "chats" { pendingActivity = true }
        else if url.host == "home" { pendingOverview = true }
    }

    func route(from userInfo: [AnyHashable: Any], action: String?, replyText: String?) {
        guard let hermes = userInfo["hermes"] as? [String: Any], let sid = hermes["session_id"] as? String else { return }
        pendingChat = sid
        guard let action else { return }
        // What Approve or Deny may answer: the approval the notification was for, by its card or
        // its request (`PendingCard.isNamed(by:)`). Gone, nothing is answered and the chat opens:
        // the first approval shown was answered once, a newer one nobody had read. One that names
        // none (posted by an older build) answers the chat's approval when it has just one.
        let names = ["card_id", "request_id"].compactMap { hermes[$0] as? String }.filter { !$0.isEmpty }
        guard let rt = runtime, socketUsable else {
            // No socket of its own (launched in the background by the action, or a watch that
            // goes through its iPhone): the phone answers for it over the watch link. With a
            // runtime but no socket, the answer used to wait on a socket that never came.
            Task {
                var base: [String: Any] = ["session": sid]
                if let p = hermes["profile"] as? String, !p.isEmpty { base["profile"] = p }
                // The gateway the notification is for, when it says: the phone refuses another.
                if let g = hermes["connection_id"] as? String, !g.isEmpty { base["gateway"] = g }
                do {
                    if action == WatchNotifier.replyAction, let text = replyText, !text.isEmpty {
                        let r = try await connectivity.request(base.merging(["op": "prompt", "text": text]) { $1 })
                        if r["ok"] as? Bool != true { WatchNotifier.notSent(r["error"] as? String) }
                        return
                    }
                    let choice = action == WatchNotifier.approveOnceAction ? "once" : "deny"
                    let r = try await connectivity.request(base.merging(["op": "cards"]) { $1 })
                    guard r["ok"] as? Bool == true else { WatchNotifier.notSent(r["error"] as? String); return }
                    let approvals = (r["cards"] as? [[String: Any]] ?? []).filter { ($0["method"] as? String) == "approval" }
                    let named = names.isEmpty ? (approvals.count == 1 ? approvals.first : nil) : approvals.first { c in
                        names.contains { PendingCard.isNamed(id: c["id"] as? String ?? "", requestID: c["request"] as? String, by: $0) }
                    }
                    guard let card = named, let id = card["id"] as? String else {
                        WatchNotifier.notSent(names.isEmpty && approvals.count > 1 ? "Several approvals are waiting. Open the chat to answer the one you mean."
                                              : "The approval was not found. It may have been answered already.")
                        return
                    }
                    let a = try await connectivity.request(base.merging(["op": "approval", "card": id, "choice": choice]) { $1 })
                    if a["ok"] as? Bool != true { WatchNotifier.notSent(a["error"] as? String) }
                } catch { WatchNotifier.notSent(error.localizedDescription) }
            }
            return
        }
        Task {
            guard let chat = try? await rt.openChat(storedID: sid, title: nil, profile: hermes["profile"] as? String) else { return }
            if action == WatchNotifier.replyAction, let text = replyText, !text.isEmpty { await chat.send(text); return }
            let choice = action == WatchNotifier.approveOnceAction ? "once" : "deny"
            if let card = await chat.approvalToAnswer(named: names, waitingUpTo: 8) { await chat.respond(card: card, result: ["choice": .string(choice)]) }
        }
    }
}

/// WCSession plumbing; callbacks arrive off the main thread and are hopped by the model.
final class WatchConnectivityBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
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

    /// Whether the phone could take a message now.
    static var phoneReachable: Bool { WCSession.default.activationState == .activated && WCSession.default.isReachable }

    /// Ask the phone to do something the watch cannot (submit a prompt, answer a card) and wait.
    /// Right after launch the session may still be activating: up to 3 s are given to it.
    func request(_ message: [String: Any]) async throws -> [String: Any] {
        let s = WCSession.default
        for _ in 0..<15 where s.activationState != .activated { try? await Task.sleep(for: .milliseconds(200)) }
        guard s.activationState == .activated, s.isReachable else { throw WatchProxyError.phoneUnreachable }
        let boxed: SendableDict = try await withCheckedThrowingContinuation { (c: CheckedContinuation<SendableDict, Error>) in
            let box = ReplyBox(c)
            s.sendMessage(message, replyHandler: { r in box.resume(with: .success(SendableDict(r))) }, errorHandler: { e in box.resume(with: .failure(e)) })
        }
        return boxed.value
    }

    /// An HTTP call made by the phone for the watch (`RelayWire`): a big body goes ahead in
    /// parts, a big answer's parts are fetched after. Throws `RelayUnavailable` when the phone
    /// cannot be asked at all, so the watch's own route is tried instead.
    func relay(_ r: RelayedRequest, gateway: String) async throws -> RelayedResponse {
        let packed = r.body.map(RelayWire.compress)
        let message: [String: Any]
        if let packed, packed.count > RelayWire.partSize {
            let id = UUID().uuidString
            let parts = RelayWire.split(packed)
            for (i, p) in parts.enumerated() {
                let ok = try await relaySend(["op": RelayWire.putOp, "id": id, "index": i, "part": p])
                // Nothing reached the gateway yet: the watch's own route can still be tried.
                guard ok["ok"] as? Bool == true else { throw RelayUnavailable("The iPhone did not take the request.") }
            }
            message = RelayWire.message(r, gateway: gateway, bodyRef: id, parts: parts.count)
        } else {
            message = RelayWire.message(r, gateway: gateway, inlineBody: packed)
        }
        let first = try await relaySend(message)
        if RelayWire.isUnavailable(first) { throw RelayUnavailable(first["error"] as? String ?? WatchProxyError.phoneUnreachable.localizedDescription) }
        guard first["ok"] as? Bool == true else { throw RelayWire.error(from: first) }
        guard let status = first["status"] as? Int, var body = first["body"] as? Data else { throw HermesAPIError.transport("The iPhone's answer could not be read.") }
        let parts = first["parts"] as? Int ?? 1
        if parts > 1, let more = first["more"] as? String {
            for i in 1..<parts {
                let p = try await relaySend(["op": RelayWire.partOp, "id": more, "index": i])
                guard p["ok"] as? Bool == true, let d = p["part"] as? Data else { throw RelayWire.error(from: p) }
                body.append(d)
            }
        }
        guard let plain = RelayWire.decompress(body) else { throw HermesAPIError.transport("The iPhone's answer could not be read.") }
        return RelayedResponse(status: status, contentType: first["type"] as? String, body: plain)
    }

    /// `request`, with "the phone is not there" told apart from "the phone failed it".
    private func relaySend(_ m: [String: Any]) async throws -> [String: Any] {
        do { return try await request(m) }
        catch WatchProxyError.phoneUnreachable { throw RelayUnavailable(WatchProxyError.phoneUnreachable.localizedDescription) }
        catch let e as WCError where Self.phoneAway.contains(e.code) { throw RelayUnavailable(WatchProxyError.phoneUnreachable.localizedDescription) }
    }

    private static let phoneAway: Set<WCError.Code> = [.notReachable, .deviceNotPaired, .companionAppNotInstalled, .sessionNotActivated, .sessionInactive]
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
    var errorDescription: String? { "Your iPhone is not reachable. Keep it nearby with Vory installed." }
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
        // On screen already: a tap on the wrist, no banner over the card itself.
        guard WKApplication.shared().applicationState != .active else { WKInterfaceDevice.current().play(.notification); return }
        let content = UNMutableNotificationContent()
        content.title = "\(chat.profileName) · \(card.method == "approval" ? "approval needed" : "question")"
        content.subtitle = chat.title
        content.body = card.approval?.description ?? card.approval?.command ?? card.clarify?.question ?? "Needs your answer"
        content.categoryIdentifier = card.method == "approval" ? WatchNotifier.approvalCategory : WatchNotifier.clarifyCategory
        // The card and its request, so Approve here answers this one (`WatchModel.route`).
        content.userInfo = ["hermes": ["session_id": chat.storedID, "kind": card.method, "card_id": card.id,
                                       "request_id": card.approval?.requestId ?? card.id]]
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "card-\(card.id)", content: content, trigger: nil))
    }

    /// Answered on another device: the banner that offered Approve here is out of date, whether
    /// it was posted for this card or for the approval queue's card it took the place of.
    func cardSettled(_ card: PendingCard, chat: ChatSession) {
        let center = UNUserNotificationCenter.current()
        let ids = [card.id, card.approval.map { "queue-" + $0.requestId }].compactMap { $0 }.map { "card-" + $0 }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func turnFinished(chat: ChatSession, error: String?) {
        guard WKApplication.shared().applicationState != .active else {
            WKInterfaceDevice.current().play(error?.isEmpty == false ? .failure : .success)
            return
        }
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

    /// A reply or an answer from a notification that did not get through: said, not dropped.
    static func notSent(_ why: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Not sent"
        content.body = why?.isEmpty == false ? why! : "The iPhone could not send it."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "not-sent-\(UUID().uuidString)", content: content, trigger: nil))
    }

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
