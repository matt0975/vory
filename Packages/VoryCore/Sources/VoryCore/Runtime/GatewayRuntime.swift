import Foundation
import Observation
import OSLog

/// Everything live for the active gateway: REST client, WebSocket, profiles, open chats and pending attention.
@MainActor
@Observable
public final class GatewayRuntime {
    public let connection: GatewayConnection
    public private(set) var secrets: GatewaySecrets
    public let api: HermesAPI
    public private(set) var socket: GatewaySocket!
    private let store: ConnectionStore
    private let log = Logger(subsystem: "Vory", category: "runtime")

    public var socketState: SocketState = .idle
    public var profiles: [ProfileInfo] = []
    public var selectedProfile: String? {
        didSet {
            var c = connection; c.lastProfile = selectedProfile; store.updateMetadata(c)
            if oldValue != selectedProfile { Task { await refreshCapabilities() } }
        }
    }
    public var hasBotMode = false
    public var profileHome: String?
    public var lastError: String?
    /// Stored session ids that have a card waiting for the user.
    public var needsAttention: Set<String> = []
    private var registry = ChatRegistry<ChatSession>()
    /// Every open chat, in the order it was opened.
    public var chats: [ChatSession] { registry.all }
    private var globalEventTask: Task<Void, Never>?
    /// Platform hooks, set by the app that owns this runtime.
    public var pushRegistrar: (any PushRegistrationSyncing)?
    public var cardNotifier: (any CardNotifying)?
    public var activityReporterFactory: @MainActor () -> any TurnActivityReporting = { NoTurnActivity() }
    /// Restart / update runs for this gateway; shared by the System screen and the "restart required" callout.
    public let maintenance = MaintenanceModel()
    /// The dashboard's "Restart required" message when it is serving stale code, else nil. Hermes only
    /// reports this from /api/model/options, so it is probed on connect, profile change and reconnect
    /// rather than discovered by surprise when the model picker opens.
    public var restartRequired: String?

    /// The gateway's projects for the selected bot, and which chat is in which.
    public let projects = ProjectsStore()
    /// The gateway's kanban board (its bundled plugin), when it has one.
    public let kanban = KanbanStore()
    /// Speech in and out, by the Speech setting: the gateway's providers or this device's engines.
    public let voice = VoiceEngine()

    public init(connection: GatewayConnection, store: ConnectionStore) {
        self.connection = connection
        self.store = store
        let loadedSecrets = store.secrets(for: connection.id)
        self.secrets = loadedSecrets
        self.selectedProfile = connection.lastProfile
        self.api = HermesAPI(gateway: connection.gateway, signer: RequestSigner(authMode: connection.authMode, secrets: loadedSecrets))
        self.socket = GatewaySocket(
            urlProvider: { [weak self] in
                guard let self else { throw SocketError.cancelled }
                return try await self.websocketURL()
            },
            onEvent: { [weak self] ev in Task { @MainActor in self?.handle(event: ev) } },
            onState: { [weak self] s in Task { @MainActor in
                guard let self else { return }
                let wasOpen = self.socketState.isOpen
                self.socketState = s
                // The status widget shows whether the gateway is reachable: tell it on every flip.
                if wasOpen != s.isOpen { self.publishSnapshot() }
            } },
            onServerRequest: { [weak self] req in
                guard let self else { return nil }
                return await self.answer(serverRequest: req)
            },
            onReconnected: { [weak self] in await self?.didReconnect() })
        Task { await api.setRefresher { [weak self] in
            guard let self else { throw HermesAPIError.sessionExpired }
            return try await self.refreshSigner()
        } }
    }

    // MARK: Auth plumbing

    private func refreshSigner() async throws -> RequestSigner {
        guard connection.authMode.usesBearer else { throw HermesAPIError.unauthorized("") }
        let refreshed = try await NativeAuthClient.refresh(gateway: connection.gateway, secrets: secrets)
        secrets = refreshed
        store.saveSecrets(refreshed, for: connection.id)
        return RequestSigner(authMode: connection.authMode, secrets: refreshed)
    }

    /// Renews the session the way a 401 mid-request does, for a caller that got "session
    /// expired" back from an action and wants one more go before asking the user to sign in.
    public func refreshSession() async throws {
        let s = try await refreshSigner()
        await api.updateSigner(s)
    }

    public func replaceSecrets(_ s: GatewaySecrets) async {
        secrets = s
        store.saveSecrets(s, for: connection.id)
        await api.updateSigner(RequestSigner(authMode: connection.authMode, secrets: s))
        await socket.connect()
    }

    private nonisolated func websocketURL() async throws -> (URL, [String: String]) {
        let (gateway, authMode, secrets) = await (connection.gateway, connection.authMode, self.secrets)
        var ticket: String?
        if authMode.usesBearer {
            let r: [String: JSONValue] = try await api.send("POST", "/api/auth/ws-ticket", body: EmptyBody())
            ticket = r["ticket"]?.stringValue
        }
        let url = RequestSigner.websocketURL(gateway: gateway, token: secrets.sessionToken, ticket: ticket)
        return (url, secrets.access.headers)
    }

    /// A socket URL for a plugin's own endpoint (the kanban event stream), credentialled the
    /// same way as the main socket: a minted ticket for bearer gateways, `?token=` otherwise.
    nonisolated func pluginWebsocketURL(path: String, query: [URLQueryItem]) async throws -> (URL, [String: String]) {
        let (gateway, authMode, secrets) = await (connection.gateway, connection.authMode, self.secrets)
        var items = query
        if authMode.usesBearer {
            let r: [String: JSONValue] = try await api.send("POST", "/api/auth/ws-ticket", body: EmptyBody())
            if let t = r["ticket"]?.stringValue, !t.isEmpty { items.append(URLQueryItem(name: "ticket", value: t)) }
        } else if let t = secrets.sessionToken, !t.isEmpty {
            items.append(URLQueryItem(name: "token", value: t))
        }
        return (gateway.websocket(path, query: items), secrets.access.headers)
    }

    // MARK: Lifecycle

    public func start() async {
        projects.attach(self)
        kanban.attach(self)
        voice.attach(self)
        await socket.connect()
        await loadProfiles()
        await refreshCapabilities()
        publishSnapshot(refreshSessions: true)
    }

    public func stop() async {
        globalEventTask?.cancel()
        await socket.disconnect()
    }

    public func reconnectNow() async { await socket.disconnect(); await socket.connect() }

    /// Tells the gateway this socket answers server → client requests (approval, clarify…).
    /// Without it the gateway never writes the approval frame and the agent waits with no card.
    /// The result names what it will send; anything missing "approval" is retried once.
    public private(set) var serverRequestsAdvertised: [String] = []
    public func advertiseCapabilities() async {
        for attempt in 0..<2 {
            if let r = try? await socket.call("client.capabilities", params: ["server_requests": true], timeout: 15) {
                serverRequestsAdvertised = r["server_requests"]?.arrayValue?.compactMap(\.stringValue) ?? []
                log.info("client.capabilities → \(self.serverRequestsAdvertised.joined(separator: ","), privacy: .public)")
                if serverRequestsAdvertised.contains("approval") || attempt == 1 { return }
            } else {
                log.warning("client.capabilities: no answer (attempt \(attempt + 1))")
            }
        }
    }

    private func didReconnect() async {
        await advertiseCapabilities()
        for chat in registry.all { await chat.reattachAfterReconnect() }
        await probeCodeSkew()
    }

    /// One cheap GET; only the 503 skew refusal sets the flag, every other outcome clears it.
    public func probeCodeSkew() async {
        do {
            let _: JSONValue = try await api.get("/api/model/options", profile: selectedProfile)
            restartRequired = nil
        } catch let e as HermesAPIError {
            if case .http(let status, let detail) = e, status == 503, MaintenanceModel.isRestartRequired(detail) { restartRequired = detail }
            else { restartRequired = nil }
        } catch { restartRequired = nil }
    }

    /// Settings › Bots › Default bot: the bot the app comes back to on launch and after a chat
    /// with another one; empty follows the gateway's own active profile.
    public static let defaultProfileKey = "bots.defaultProfile"
    public var defaultProfile: String? {
        let d = UserDefaults.standard.string(forKey: Self.defaultProfileKey) ?? ""
        return d.isEmpty || !profiles.contains(where: { $0.name == d }) ? nil : d
    }
    /// Back to the default bot, when one is chosen and the selection drifted (a chat opened from
    /// another bot's list, a route from a notification).
    public func returnToDefaultProfile() {
        if let d = defaultProfile, selectedProfile != d { selectedProfile = d }
    }

    public func loadProfiles() async {
        do {
            let r: ProfilesResponse = try await api.get("/api/profiles")
            profiles = r.profiles
            if let d = defaultProfile, selectedProfile != d { selectedProfile = d }
            else if selectedProfile == nil || !profiles.contains(where: { $0.name == selectedProfile }) {
                let active: ActiveProfileResponse? = try? await api.get("/api/profiles/active")
                selectedProfile = active?.current ?? profiles.first(where: { $0.isDefault == true })?.name ?? profiles.first?.name
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func refreshCapabilities() async {
        do {
            try await socket.waitUntilReady()
            await advertiseCapabilities()
            if let caps: GroupsCapabilities = try? (await socket.call("groups.capabilities", params: profileParams())).decode() {
                hasBotMode = caps.driver ?? false || !(caps.methods ?? []).isEmpty
            } else {
                hasBotMode = false
            }
            if let cfg = try? await socket.call("config.get", params: profileParams(["key": "profile"])) {
                profileHome = cfg["home"]?.stringValue
            }
            await projects.refresh()
            await kanban.probe()
            await pushRegistrar?.syncRegistration(runtime: self)
            await probeCodeSkew()
        } catch {
            log.warning("capabilities: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adds `profile` to RPC params when a non-default profile is selected.
    public func profileParams(_ base: [String: JSONValue] = [:], profile: String? = nil) -> JSONValue {
        var p = base
        if let sp = profile ?? selectedProfile, !sp.isEmpty { p["profile"] = .string(sp) }
        return .object(p.compactingNulls)
    }

    /// A chat's own call: the bot that owns the chat and no other. No fallback to the selected
    /// bot, which may have changed since the chat was opened.
    public nonisolated static func params(_ base: [String: JSONValue], owner: String?) -> JSONValue {
        var p = base
        if let owner, !owner.isEmpty { p["profile"] = .string(owner) }
        return .object(p.compactingNulls)
    }

    public func rpc(_ method: String, _ params: [String: JSONValue] = [:], owner: String?, timeout: Double = 120) async throws -> JSONValue {
        try await socket.waitUntilReady()
        return try await socket.call(method, params: Self.params(params, owner: owner), timeout: timeout)
    }

    /// Which bot's store holds a chat, for an open that was not told (a notification without
    /// its bot, a card for a chat started elsewhere). One small request per bot, the selected
    /// one first. Returns nil when no store has it yet (a chat seconds old), and throws when
    /// the gateway could not be asked: guessing is what moves chats.
    public func ownerProfile(ofStored id: String) async throws -> String? {
        if profiles.isEmpty { await loadProfiles() }
        let names = Self.lookupOrder(profiles: profiles.map(\.name), selected: selectedProfile)
        var found: [(name: String, archived: Bool)] = []
        var failure: Error?
        for name in names {
            do {
                let row: JSONValue = try await api.get("/api/sessions/\(id)", profile: name)
                let archived = row["archived"]?.boolValue ?? ((row["archived"]?.doubleValue ?? 0) != 0)
                found.append((name, archived))
                if !archived { break }
            } catch HermesAPIError.http(let status, _) where status == 404 {
                continue
            } catch {
                failure = error
            }
        }
        if let owner = Self.owner(among: found) { return owner }
        if let failure { throw failure }
        return selectedProfile
    }

    /// The selected bot first (the usual answer), then the rest in the gateway's order.
    public nonisolated static func lookupOrder(profiles: [String], selected: String?) -> [String] {
        guard let selected, profiles.contains(selected) else { return profiles }
        return [selected] + profiles.filter { $0 != selected }
    }

    /// A live copy over an archived one: after the gateway has moved a chat, the store it
    /// left keeps the id as an archived row.
    public nonisolated static func owner(among found: [(name: String, archived: Bool)]) -> String? {
        found.first { !$0.archived }?.name ?? found.first?.name
    }

    /// `profile`: this call's bot instead of the selected one (a read-only look at another
    /// bot's chat keeps the selection where it was).
    public func rpc(_ method: String, _ params: [String: JSONValue] = [:], profile: String? = nil, timeout: Double = 120) async throws -> JSONValue {
        try await socket.waitUntilReady()
        return try await socket.call(method, params: profileParams(params, profile: profile), timeout: timeout)
    }

    // MARK: Chats

    public func chat(runtimeID: String) -> ChatSession? { registry.byRuntime(runtimeID) }
    public func chatForStored(_ storedID: String) -> ChatSession? { registry.byStored(storedID) }

    /// Opens (or returns) the live chat for a stored session id.
    /// Returns immediately with the cached transcript; the live attach runs behind it
    /// (`ChatSession.isResuming` / `resumeError`). Pass `waitForResume` to keep the old blocking contract.
    /// `profile`: the bot whose store holds the chat. When the caller does not know it, the
    /// gateway is asked before anything is resumed: a `session.resume` sent under another bot
    /// does not fail, it makes the gateway move the chat into that bot's store.
    public func openChat(storedID: String, title: String?, profile: String? = nil, waitForResume: Bool = false) async throws -> ChatSession {
        if let c = registry.byStored(storedID) { if waitForResume { await c.awaitResume() }; return c }
        var owner = profile
        if owner == nil || owner!.isEmpty {
            owner = try await ownerProfile(ofStored: storedID)
            // Another open of the same chat may have finished while the gateway was asked.
            if let c = registry.byStored(storedID) { if waitForResume { await c.awaitResume() }; return c }
        }
        let session = ChatSession(runtime: self, storedID: storedID, title: title, profile: owner)
        registry.add(session)
        session.beginResume()
        if waitForResume {
            await session.awaitResume()
            if let e = session.resumeError { registry.remove(session); throw HermesAPIError.transport(e) }
        }
        return session
    }

    /// `cwd`: a folder on the gateway the chat works in, so it belongs to that project.
    public func newChat(cwd: String? = nil) async throws -> ChatSession {
        let session = ChatSession(runtime: self, storedID: nil, title: nil)
        try await session.create(cwd: cwd)
        registry.add(session)
        return session
    }

    public func closeChat(_ chat: ChatSession) {
        registry.remove(chat)
        Task { _ = try? await socket.call("session.close", params: Self.params(["session_id": .string(chat.runtimeID)], owner: chat.profile)) }
    }

    // MARK: Events

    private func handle(event: GatewayEvent) {
        if let chat = registry.byRuntime(event.sessionID) {
            chat.handle(event: event)
            return
        }
        switch event.type {
        case "session.reclaimed":
            if let sid = event.payload["session_id"]?.stringValue, let chat = registry.byRuntime(sid) { chat.handle(event: event) }
        case "sessions.changed":
            NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
            publishSnapshot(refreshSessions: true)
            Task { await projects.refreshTree() }
        case "projects.changed":
            Task { await projects.refresh() }
        case "cron.changed":
            NotificationCenter.default.post(name: .hermesCronChanged, object: nil)
        default:
            break
        }
    }

    /// How many server→client requests (approval, clarify…) this socket has received since it
    /// connected, and the last one: the diagnostics page shows them, so "I cannot see approvals"
    /// can be told apart as "none arrive" versus "they arrive and are not drawn".
    public private(set) var serverRequestsReceived = 0
    public private(set) var lastServerRequest: String?

    private func answer(serverRequest req: ServerRequest) async -> JSONValue? {
        serverRequestsReceived += 1
        lastServerRequest = "\(req.method) · \(Date().formatted(date: .omitted, time: .shortened))"
        if let chat = registry.byRuntime(req.sessionID) ?? registry.byStored(req.sessionID) {
            return await chat.answer(serverRequest: req)
        }
        // An approval for a session this app has not opened (a cron run, a chat started
        // elsewhere): refusing it withdraws the prompt, so open the session and show the card.
        let stored = req.params["stored_session_id"]?.stringValue ?? req.sessionID
        log.warning("server request \(req.method, privacy: .public) for unopened session \(stored, privacy: .public); opening it")
        if let chat = try? await openChat(storedID: stored, title: nil, profile: req.params["profile"]?.stringValue, waitForResume: true) {
            return await chat.answer(serverRequest: req)
        }
        return nil
    }

    public func setAttention(storedID: String, needed: Bool) {
        if needed { needsAttention.insert(storedID) } else { needsAttention.remove(storedID) }
        publishSnapshot()
    }

    /// Called by whoever wants widgets refreshed (`WidgetCenter.reloadAllTimelines` lives in the app).
    public var onSnapshotPublished: (@MainActor (WidgetSnapshot) -> Void)?
    private var recentSessions: [StoredSession] = []

    /// Refreshes the recent-sessions list and writes the widget snapshot. Cheap; safe to call often.
    public func publishSnapshot(refreshSessions: Bool = false) {
        Task {
            if refreshSessions || recentSessions.isEmpty {
                if let r: SessionListResponse = try? await api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "8")], profile: selectedProfile) {
                    recentSessions = r.sessions
                }
            }
            let chats = recentSessions.map { s in
                WidgetSnapshot.Chat(id: s.id, title: s.displayTitle, profile: s.profile ?? selectedProfile ?? "default", lastActive: s.lastActive,
                                    running: chatForStored(s.id)?.isRunning ?? false, needsYou: needsAttention.contains(s.id))
            }
            let ctx = registry.all.first { $0.isRunning }?.usage?.computedContextPercent ?? registry.all.last?.usage?.computedContextPercent
            // The overview numbers are written by Home or the widget; a rewrite here keeps them.
            let kept = WidgetSnapshot.load()?.usage
            let snap = WidgetSnapshot(gatewayName: connection.name, connectionID: connection.id.uuidString, profile: selectedProfile ?? "default",
                                      needsAttention: needsAttention.count, chats: chats, contextPercent: ctx, connected: socketState.isOpen, usage: kept)
            snap.save()
            onSnapshotPublished?(snap)
        }
    }
}

public extension Notification.Name {
    public static let hermesSessionsChanged = Notification.Name("hermesSessionsChanged")
    /// `/new` in a chat: the app opens a fresh chat with the same bot (userInfo "profile").
    public static let hermesNewChatRequested = Notification.Name("hermesNewChatRequested")
    /// A piece of reply text arrived for a chat (`storedID`, `count` characters).
    public static let hermesStreamDelta = Notification.Name("hermesStreamDelta")
    /// A reply finished (`storedID`, `text`: the whole assistant turn), for reading it aloud.
    public static let hermesReplyCompleted = Notification.Name("hermesReplyCompleted")
    public static let hermesCronChanged = Notification.Name("hermesCronChanged")
    public static let hermesOpenSession = Notification.Name("hermesOpenSession")
}
