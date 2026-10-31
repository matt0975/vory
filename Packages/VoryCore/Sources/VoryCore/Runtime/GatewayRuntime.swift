import Foundation
import Observation
import OSLog

/// Everything live for the active gateway: REST client, WebSocket, profiles, open chats and pending attention.
@MainActor
@Observable
public final class GatewayRuntime {
    public let connection: GatewayConnection
    /// How this runtime reaches its gateway: the network, or in process for the demo.
    public let transport: GatewayTransport
    /// The demo (#392): nothing it does is saved or synced. The one check every persistence path asks: the demo
    /// connection, or any runtime on the in-process demo transport (onboarding's tour makes one of its own, #388).
    public var isEphemeral: Bool { connection.isDemo || transport.isInProcess }
    /// Where this runtime keeps files for the moment (staged attachments, downloads, fetched pictures): the system's
    /// temporary folder, or for the demo a folder of its own that `stop()` removes, so leaving the demo leaves no file.
    public let scratchDirectory: URL
    /// Pictures and files fetched for the chats: the shared cache, or for the demo one in `scratchDirectory`.
    public let media: MediaStore
    /// The address in use: the gateway's own, or for a gateway with a backup address (#283) the
    /// one that answered when the socket last connected.
    public private(set) var address: GatewayURL
    /// The address in use in words, for where the gateway is named; nil with only one address.
    public var addressLabel: String? { connection.alternate == nil ? nil : AddressChooser.label(for: address) }
    /// Tests stand in for the status probe here; nil asks the addresses themselves.
    public var addressProbe: AddressChooser.Probe?
    private let addressMemory = AddressMemory()
    /// The chosen address's index and identity, kept once the socket has opened with it.
    private var chosenAddress: AddressChooser.Choice?
    private var pathWatch: Task<Void, Never>?
    /// The status probe's session: one for the runtime's life, invalidated in `stop()`.
    private var probeSession: URLSession?
    public private(set) var secrets: GatewaySecrets
    public let api: HermesAPI
    public private(set) var socket: GatewaySocket!
    private let store: ConnectionStore
    private let log = Logger(subsystem: "Vory", category: "runtime")

    public var socketState: SocketState = .idle
    /// The app is out of sight (the phone's app in the background): streaming replies gather
    /// their text without being redrawn, and are drawn once when it comes back.
    public var isAway = false {
        didSet {
            if isAway, !oldValue { awaySince = Date() }
            guard oldValue, !isAway else { return }
            // Away long enough for the network under the REST session to have changed (#423): its connections are
            // made afresh before anything is asked of them.
            if let since = awaySince, Date().timeIntervalSince(since) >= Self.awayResetAfter {
                Task { [api] in await api.resetSession() }
            }
            awaySince = nil
            // Suspension can miss sessions.changed even without a socket-state change.
            owedListRefresh = true
            // The chats' views catch up once, when the app says (`scheduleCatchUp`); they stay
            // held until then, so a live change meanwhile does not have them catch up early.
            for chat in registry.all { chat.beginCatchUp() }
            let catchUp: @MainActor () -> Void = { [weak self] in
                guard let self, !self.isAway else { return }
                for chat in self.registry.all { chat.cameBack() }
            }
            if let scheduleCatchUp { scheduleCatchUp(catchUp) } else { catchUp() }
            // A socket that died quietly while the app was away is found out now, not at the
            // next heartbeat (see `GatewaySocket.checkAlive`).
            Task { [socket] in await socket?.checkAlive() }
            // What was owed while away, once, after the return's animation (the foreground
            // transition is where the watchdog counts the main thread's seconds).
            owedFlush?.cancel()
            owedFlush = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, !Task.isCancelled, !self.isAway else { return }
                self.payOwedRefreshes()
            }
        }
    }
    /// When the app went out of sight, and how long it must have been away for the REST session to be replaced.
    private var awaySince: Date?
    static let awayResetAfter: TimeInterval = 60

    /// When the chats' views catch up after a return: at once when not set (the Mac's wake, the
    /// tests). The phone runs it just after the return's first frame, out of the scene update,
    /// whose stretch on the main thread it lengthened by drawing the turn that ended away (#371).
    public var scheduleCatchUp: (@MainActor (@escaping @MainActor () -> Void) -> Void)?

    /// Refreshes held back while away (`publishSnapshot`, the sessions-changed notice): a long
    /// turn sends a sessions.changed with every flush, and each one fetched the list, read and
    /// wrote the widget snapshot in the Keychain, reloaded the widgets, and reloaded the chat
    /// list with its Siri and Spotlight catalogs, all on a main thread the system wants quiet
    /// in the background (#371: a quarter to half a core for as long as the turn ran).
    private(set) var owedSnapshot = false
    private(set) var owedSessionsRefresh = false
    private(set) var owedListRefresh = false
    private var owedFlush: Task<Void, Never>?

    private func payOwedRefreshes() {
        if owedListRefresh {
            owedListRefresh = false
            NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
            Task { await projects.refreshTree() }
        }
        if owedSnapshot { publishSnapshot(refreshSessions: owedSessionsRefresh) }
    }
    /// False where no socket is opened at all (a watch going through its iPhone): start,
    /// reconnect and new credentials leave it closed, and the capability probe skips it.
    public var socketEnabled = true
    /// Whether a sessions list that came back over HTTP counts as reachable for the widget
    /// snapshot (the watch, whose socket is often not allowed to open), not the socket alone.
    public var httpCountsAsOnline = false
    /// Whether this client reaches the gateway through a relay (the watch's iPhone); the
    /// complications then leave the refresh to the app, as they cannot go that way.
    public var throughRelay = false
    private var lastListAnswered = false
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
    /// Not private so a test can put a chat in it without a gateway and route events to it.
    var registry = ChatRegistry<ChatSession>()
    /// Every open chat, in the order it was opened.
    public var chats: [ChatSession] { registry.all }
    /// This gateway answered `session.undo` with "unknown method": a Hermes without it, where a sent message can't be
    /// taken back, so a bubble offers Copy to message instead of Edit & resend (#556). Learnt from that answer, never
    /// guessed from a version.
    public var undoUnsupported = false
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

    public init(connection: GatewayConnection, store: ConnectionStore, transport: GatewayTransport = .network) {
        self.connection = connection
        self.transport = transport
        self.store = store
        let ephemeral = connection.isDemo || transport.isInProcess
        if ephemeral {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vory-demo-" + UUID().uuidString, isDirectory: true)
            scratchDirectory = scratch
            media = MediaStore(directory: scratch.appendingPathComponent("media", isDirectory: true))
        } else {
            scratchDirectory = FileManager.default.temporaryDirectory
            media = .shared
        }
        let loadedSecrets = store.secrets(for: connection.id)
        self.secrets = loadedSecrets
        self.selectedProfile = connection.lastProfile
        let addresses = connection.addresses
        let first = AddressMemory().lastGood(for: connection.id).flatMap { addresses.indices.contains($0) ? addresses[$0] : nil } ?? connection.gateway
        self.address = first
        self.api = HermesAPI(gateway: first, signer: RequestSigner(authMode: connection.authMode, secrets: loadedSecrets), urlSession: transport.makeHTTPSession(), makeSession: { [transport] in transport.makeHTTPSession() },
                              downloadDirectory: ephemeral ? scratchDirectory : nil)
        self.socket = GatewaySocket(
            urlProvider: { [weak self] in
                guard let self else { throw SocketError.cancelled }
                return try await self.websocketURL()
            },
            // One trip to the main actor per batch, not per event (see `GatewayEventBatch`).
            onEvents: { [weak self] batch in Task { @MainActor in self?.handle(batch: batch.take()) } },
            onState: { [weak self] s in Task { @MainActor in
                guard let self else { return }
                let wasOpen = self.socketState.isOpen
                self.socketState = s
                if !wasOpen, s.isOpen { self.rememberAddress() }
                // The status widget shows whether the gateway is reachable: tell it on every flip.
                // Where HTTP counts too (the watch), a socket that closed asks HTTP afresh rather
                // than keep the last answer.
                if wasOpen != s.isOpen { self.publishSnapshot(refreshSessions: wasOpen && self.httpCountsAsOnline) }
            } },
            onServerRequest: { [weak self] req in
                guard let self else { return nil }
                return await self.answer(serverRequest: req)
            },
            onReconnected: { [weak self] in await self?.didReconnect() },
            onFirstConnected: { [weak self] in await self?.didConnectFirst() },
            makePipe: { [transport] in transport.makeFramePipe($0, nil) })
        // An attempt that got no answer from the ticket's REST call twice in a row, or a network change while
        // waiting: the REST session's connections are made afresh, as quitting the app did (#423).
        Task { [socket, api] in await socket?.setTroubleHandler { _ in await api.resetSession() } }
        Task { await api.setRefresher { [weak self] in
            guard let self else { throw HermesAPIError.sessionExpired }
            return try await self.refreshSigner()
        } }
    }

    // MARK: Auth plumbing

    /// Signs the gateway in again once its session has run out for good (the gateway turned the
    /// refresh token down), from a sign-in the person asked this device to remember; nil leaves
    /// it to the person, as before. Set by the app, never on the watch. Returns the new session,
    /// or nil to fall back to asking.
    public var signInAgain: (@MainActor (GatewayConnection, GatewaySecrets) async -> GatewaySecrets?)?
    /// The gateway turned the refresh token down and nothing has signed it in since: the
    /// session ended for good. A socket refused while this is false (a 4401 close, a ws-ticket
    /// refused right after a renewal that worked) is not mended by signing in again, so the app
    /// does not use a remembered sign-in for it.
    public private(set) var refreshRefused = false

    private func refreshSigner() async throws -> RequestSigner {
        guard connection.authMode.usesBearer else { throw HermesAPIError.unauthorized("") }
        var refreshed: GatewaySecrets
        var signedInAgain = false
        do {
            refreshed = try await NativeAuthClient.refresh(gateway: address, secrets: secrets)
        } catch HermesAPIError.sessionExpired {
            guard let signInAgain, let renewed = await signInAgain(connection.using(address), secrets) else {
                refreshRefused = true
                throw HermesAPIError.sessionExpired
            }
            refreshed = renewed
            refreshed.access = secrets.access
            signedInAgain = true
        }
        refreshRefused = false
        secrets = refreshed
        store.saveSecrets(refreshed, for: connection.id)
        let signer = RequestSigner(authMode: connection.authMode, secrets: refreshed)
        if signedInAgain { await reopenRefusedSocket(signer) }
        return signer
    }

    /// Signed in again by `signInAgain` while the socket stands refused (a REST call ran into the
    /// ended session first, or the socket was refused again while no prompt could show): opened
    /// again, as `replaceSecrets` does. Nothing else would. A return to the app signs in only
    /// while `refreshRefused`, which this sign-in cleared, so the socket stayed closed and the
    /// banner asked for a sign-in the person had just made.
    private func reopenRefusedSocket(_ signer: RequestSigner) async {
        guard socketEnabled else { return }
        var refused = false
        if case .authRejected = socketState { refused = true }
        // What the socket says itself, in case its last word is still on its way here.
        else if case .authRejected = await socket.state { refused = true }
        guard refused else { return }
        // Its ticket is asked for with the new session, not the one the gateway turned down.
        await api.updateSigner(signer)
        await socket.connect()
    }

    /// Renews the session the way a 401 mid-request does, for a caller that got "session
    /// expired" back from an action and wants one more go before asking the user to sign in.
    public func refreshSession() async throws {
        let s = try await refreshSigner()
        await api.updateSigner(s)
    }

    public func replaceSecrets(_ s: GatewaySecrets) async {
        refreshRefused = false
        secrets = s
        store.saveSecrets(s, for: connection.id)
        await api.updateSigner(RequestSigner(authMode: connection.authMode, secrets: s))
        if socketEnabled { await socket.connect() }
    }

    private nonisolated func websocketURL() async throws -> (URL, [String: String]) {
        let gateway = await chooseAddress()
        let (authMode, secrets) = await (connection.authMode, self.secrets)
        var ticket: String?
        if authMode.usesBearer {
            let r: [String: JSONValue] = try await api.send("POST", "/api/auth/ws-ticket", body: EmptyBody(), directOnly: true)
            ticket = r["ticket"]?.stringValue
        }
        let url = RequestSigner.websocketURL(gateway: gateway, token: secrets.sessionToken, ticket: ticket)
        return (url, secrets.access.headers)
    }

    /// A socket URL for a plugin's own endpoint (the kanban event stream), credentialled the
    /// same way as the main socket: a minted ticket for bearer gateways, `?token=` otherwise.
    nonisolated func pluginWebsocketURL(path: String, query: [URLQueryItem]) async throws -> (URL, [String: String]) {
        let (gateway, authMode, secrets) = await (address, connection.authMode, self.secrets)
        var items = query
        if authMode.usesBearer {
            let r: [String: JSONValue] = try await api.send("POST", "/api/auth/ws-ticket", body: EmptyBody(), directOnly: true)
            if let t = r["ticket"]?.stringValue, !t.isEmpty { items.append(URLQueryItem(name: "ticket", value: t)) }
        } else if let t = secrets.sessionToken, !t.isEmpty {
            items.append(URLQueryItem(name: "token", value: t))
        }
        return (gateway.websocket(path, query: items), secrets.access.headers)
    }

    // MARK: Two addresses (#283)

    /// Before each connect, a gateway with a backup address asks both addresses which is
    /// answering (`AddressChooser`: the one that worked last first, briefly, then the first good
    /// answer; no credentials sent). No good answer keeps the address in use, as one address
    /// always does.
    private func chooseAddress() async -> GatewayURL {
        let addresses = connection.addresses
        guard addresses.count > 1 else { return address }
        let probe = addressProbe ?? statusProbe()
        let choice = await AddressChooser.choose(addresses: addresses, lastGood: addressMemory.lastGood(for: connection.id),
                                                 known: addressMemory.identity(for: connection.id), probe: probe)
        chosenAddress = choice
        if let choice, addresses[choice.index] != address {
            address = addresses[choice.index]
            await api.setGateway(address)
            log.info("address: \(AddressChooser.label(for: self.address), privacy: .public)")
        }
        return address
    }

    private func statusProbe() -> AddressChooser.Probe {
        let session = probeSession ?? URLSession(configuration: AddressChooser.probeConfiguration())
        probeSession = session
        return AddressChooser.statusProbe(accessHeaders: connection.hasAccessHeaders ? secrets.access.headers : [:], session: session)
    }

    /// The socket opened, signed in, at `address`: it is this gateway. Remembered on this
    /// device as the address that works and as what the gateway says about itself. When the
    /// probe had no good answer (the gateway's sign-in changed, say), what this address says
    /// now is asked afresh and kept, so the next choice is not stuck on the old answer.
    private func rememberAddress() {
        let addresses = connection.addresses
        guard addresses.count > 1, let index = addresses.firstIndex(of: address) else { return }
        addressMemory.setLastGood(index, for: connection.id)
        if let chosen = chosenAddress, chosen.index == index {
            addressMemory.setIdentity(chosen.identity, for: connection.id)
            return
        }
        let probe = addressProbe ?? statusProbe()
        let id = connection.id, at = address
        Task { [weak self] in
            guard let identity = await probe(at), let self, self.address == at else { return }
            self.addressMemory.setIdentity(identity, for: id)
        }
    }

    /// With two addresses, a change of network while connected is checked at once: the address
    /// in use may be out of reach from the new network, and the heartbeat could take half a
    /// minute to notice. A socket that does not answer reconnects, and the reconnect chooses.
    private func watchNetwork() {
        guard connection.alternate != nil, pathWatch == nil else { return }
        pathWatch = Task { [weak self] in
            for await _ in NetworkWatch.shared.pathChanges() {
                guard let self, !Task.isCancelled else { return }
                await self.networkChanged()
            }
        }
    }

    /// The network changed: a socket that does not answer within 3 s is dropped, and its
    /// reconnect chooses the address again.
    func networkChanged() async {
        if socketState.isOpen { await socket.checkAlive(timeout: 3) }
    }

    // MARK: Lifecycle

    public func start() async {
        projects.attach(self)
        kanban.attach(self)
        voice.attach(self)
        if socketEnabled { watchNetwork(); await socket.connect() }
        // The first HTTP call waits for the socket, briefly: on first open the route may still
        // be coming up, and a profile list asked for before it failed and put up an error the
        // connect loop was about to make moot (#305). The reconnect loads what this missed.
        if socketEnabled { try? await socket.waitUntilReady(timeout: 8) }
        await loadProfiles()
        await refreshCapabilities()
        publishSnapshot(refreshSessions: true)
    }

    public func stop() async {
        pathWatch?.cancel(); pathWatch = nil
        probeSession?.invalidateAndCancel(); probeSession = nil
        globalEventTask?.cancel()
        kanban.stopEvents()
        await socket.disconnect()
        transport.stop()
        // The demo's files for the moment go with it.
        if isEphemeral { try? FileManager.default.removeItem(at: scratchDirectory) }
    }

    public func reconnectNow() async {
        // Everything made afresh, the REST session's connections too: a Reconnect is what quitting the app did (#423).
        await api.resetSession()
        await socket.disconnect()
        if socketEnabled { await socket.connect() }
    }

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
        // The bots, if the first load went out before the route was up (#305).
        if profiles.isEmpty { lastError = nil; await loadProfiles() }
        for chat in registry.all {
            if !attachIfFailed(chat) { await chat.reattachAfterReconnect() }
        }
        await probeCodeSkew()
    }

    /// The socket's first open: there is nothing to re-attach, except a chat opened before it
    /// whose attach failed waiting for it (#422: a cold launch restores the chat that was open,
    /// and a gateway unreachable then, whose refused connects fail a waiting attach at once, or
    /// slower than the attach's 20 s wait, left it showing its cached rows with no live attach,
    /// every send refused, until it was closed and opened again).
    private func didConnectFirst() async {
        for chat in registry.all { _ = attachIfFailed(chat) }
    }

    /// A connection is up: a chat whose attach failed is attached as it was opened, which clears
    /// the failure (re-attached as the others are on a reconnect, it stayed failed and every send
    /// was refused); one still attaching is left to finish, and tried again only if that fails.
    /// Whether the chat was seen to here (else it is attached, and a reconnect re-attaches it).
    private func attachIfFailed(_ chat: ChatSession) -> Bool {
        if chat.isResuming {
            Task { await chat.awaitResume(); chat.retryFailedAttach() }
            return true
        }
        return chat.retryFailedAttach()
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
        let d = defaultProfileChoice
        return d.isEmpty || !profiles.contains(where: { $0.name == d }) ? nil : d
    }
    /// The default bot as Settings shows it ("": follow the gateway). The demo's is its own, for its life only (#494):
    /// the setting is the person's, kept and synced, and a demo bot chosen there stayed after leaving the demo.
    public var defaultProfileChoice: String {
        get { isEphemeral ? ephemeralDefaultProfile : (UserDefaults.standard.string(forKey: Self.defaultProfileKey) ?? "") }
        set { if isEphemeral { ephemeralDefaultProfile = newValue } else { UserDefaults.standard.set(newValue, forKey: Self.defaultProfileKey) } }
    }
    private var ephemeralDefaultProfile = ""
    /// Back to the default bot, when one is chosen and the selection drifted (a chat opened from
    /// another bot's list, a route from a notification).
    public func returnToDefaultProfile() {
        if let d = defaultProfile, selectedProfile != d { selectedProfile = d }
    }

    /// Whether the gateway has answered for its bots yet (an empty list counts): until then
    /// `profiles` is empty because nothing is known, not because there are none.
    public private(set) var profilesLoaded = false

    public func loadProfiles() async {
        do {
            let r: ProfilesResponse = try await api.get("/api/profiles")
            profiles = r.profiles
            profilesLoaded = true
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
        guard socketEnabled else { await registerWithoutSocket(); return }
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
            // The watch's socket is often not allowed to open: register its pushes over HTTP.
            if httpCountsAsOnline { await registerWithoutSocket() }
        }
    }

    /// Push registration with no socket to ask the bot's home: the gateway's profile list
    /// carries each bot's home too, and it comes over HTTP (through the watch's iPhone when
    /// it has to). Without it the watch's complication pushes were never registered.
    private func registerWithoutSocket() async {
        if profiles.isEmpty { await loadProfiles() }
        if let home = profiles.first(where: { $0.name == selectedProfile })?.path, !home.isEmpty { profileHome = home }
        await pushRegistrar?.syncRegistration(runtime: self)
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
        if let c = registry.byStored(storedID) { return await reopen(c, waitForResume: waitForResume) }
        var owner = profile
        if owner == nil || owner!.isEmpty {
            owner = try await ownerProfile(ofStored: storedID)
            // Another open of the same chat may have finished while the gateway was asked.
            if let c = registry.byStored(storedID) { return await reopen(c, waitForResume: waitForResume) }
        }
        let session = ChatSession(runtime: self, storedID: storedID, title: title, profile: owner)
        registry.add(session)
        session.beginResume()
        // Voice mode's quick answers are put back if the app died with them on.
        Task { await session.awaitResume(); if session.resumeError == nil { await session.restoreQuickAnswersIfNeeded() } }
        if waitForResume {
            await session.awaitResume()
            if let e = session.resumeError { registry.remove(session); throw HermesAPIError.transport(e) }
        }
        return session
    }

    /// An open chat asked for again. One whose attach failed (opened while the socket was
    /// down, which the first connect does not repair) is attached again rather than handed
    /// back as it was: every send to it failed for the rest of the visit.
    private func reopen(_ c: ChatSession, waitForResume: Bool) async -> ChatSession {
        if c.resumeError != nil, !c.isResuming { c.beginResume() }
        if waitForResume { await c.awaitResume() }
        return c
    }

    /// `cwd`: a folder on the gateway the chat works in, so it belongs to that project.
    /// `profile`: the bot the chat is with when it is not the selected one (the watch's choice,
    /// without switching the phone's list under the person).
    public func newChat(cwd: String? = nil, profile: String? = nil) async throws -> ChatSession {
        let session = ChatSession(runtime: self, storedID: nil, title: nil, profile: profile)
        try await session.create(cwd: cwd)
        registry.add(session)
        return session
    }

    /// Drops a bot's open chats from the registry without closing them on the gateway: the bot
    /// was renamed (#315), so they are reopened under the new name from the reloaded list.
    public func forgetChats(of profile: String) {
        for c in registry.all where c.profileName == profile { registry.remove(c) }
    }

    public func closeChat(_ chat: ChatSession) {
        registry.remove(chat)
        Task { _ = try? await socket.call("session.close", params: Self.params(["session_id": .string(chat.runtimeID)], owner: chat.profile)) }
    }

    // MARK: Events

    /// What the socket gathered since the main actor last looked, with each run of reply text
    /// made one piece and one list refresh of each kind: after a long time away that is
    /// thousands of frames, handled in one pass.
    func handle(batch: [GatewayEvent]) {
        guard !batch.isEmpty else { return }
        let state = Self.signposter.beginInterval("events", "\(batch.count) events")
        for ev in GatewayEvent.droppingRepeatedRefreshes(GatewayEvent.coalescingText(batch)) { handle(event: ev) }
        Self.signposter.endInterval("events", state)
    }

    /// Intervals for Instruments (Points of Interest): event batches and snapshots.
    nonisolated static let signposter = OSSignposter(subsystem: "Vory", category: .pointsOfInterest)

    private func handle(event: GatewayEvent) {
        if let chat = registry.byRuntime(event.sessionID) {
            chat.handle(event: event)
            return
        }
        switch event.type {
        case "session.reclaimed":
            if let sid = event.payload["session_id"]?.stringValue, let chat = registry.byRuntime(sid) { chat.handle(event: event) }
        case "sessions.changed":
            publishSnapshot(refreshSessions: true)
            // Away, the lists are read again once on the way back (see `owedListRefresh`).
            guard !isAway else { owedListRefresh = true; break }
            NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
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

    /// Refreshes the recent-sessions list and writes the widget snapshot. Safe to call often.
    ///
    /// Away with a turn running, it is owed rather than run (see `owedSnapshot`), and runs once
    /// when the last turn ends (the state the widgets are left showing) or on the way back.
    public func publishSnapshot(refreshSessions: Bool = false) {
        if isAway, registry.all.contains(where: \.isRunning) {
            owedSnapshot = true
            owedSessionsRefresh = owedSessionsRefresh || refreshSessions
            return
        }
        let refreshSessions = refreshSessions || owedSessionsRefresh
        owedSnapshot = false
        owedSessionsRefresh = false
        Task {
            if refreshSessions || recentSessions.isEmpty {
                if let r: SessionListResponse = try? await api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "8")], profile: selectedProfile) {
                    recentSessions = r.sessions
                    lastListAnswered = true
                } else {
                    lastListAnswered = false
                }
            }
            let chats = recentSessions.map { s in
                // A chat not open here is working by the gateway's word, on the watch: without its
                // own socket it opens none, and the complications never showed one at work.
                WidgetSnapshot.Chat(id: s.id, title: s.displayTitle, profile: s.profile ?? selectedProfile ?? "default", lastActive: s.lastActive,
                                    running: chatForStored(s.id)?.isRunning ?? (httpCountsAsOnline && s.isActive == true), needsYou: needsAttention.contains(s.id))
            }
            let ctx = registry.all.first { $0.isRunning }?.usage?.computedContextPercent ?? registry.all.last?.usage?.computedContextPercent
            // The overview numbers are written by Home or the widget; a rewrite here keeps them.
            let kept = WidgetSnapshot.load()?.usage
            var snap = WidgetSnapshot(gatewayName: connection.name, connectionID: connection.id.uuidString, profile: selectedProfile ?? "default",
                                      needsAttention: needsAttention.count, chats: chats, contextPercent: ctx,
                                      connected: socketState.isOpen || (httpCountsAsOnline && lastListAnswered), usage: kept)
            snap.throughRelay = throughRelay ? true : nil
            // The demo's chats stay in the app: not in the widgets' stored data, nor on the Watch.
            guard !isEphemeral else { return }
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
    /// A bot's folder was renamed on the gateway (#315): userInfo "old" and "new". Open chats
    /// of the old name are stale; the lists reload on `hermesSessionsChanged` as usual.
    public static let hermesBotRenamed = Notification.Name("hermesBotRenamed")
    public static let hermesOpenSession = Notification.Name("hermesOpenSession")
}
