import Foundation
import Testing
@testable import VoryCore
@testable import Vory

/// Demo mode leaves no trace on the device and sends nothing anywhere (#392). A demo used end to end through the real
/// client (every chat opened, a turn sent and its approval answered, a chat renamed, the board read, a picture fetched,
/// a file downloaded, an attachment staged) and then left has written none of the core's stores: no defaults of its
/// own, no transcript cache, no shared media cache, no widget snapshot, nothing left in its scratch folder, no saved
/// connection. And nothing it did asked the network: no request through the shared session (the push relay's and the
/// sign-in's) and none its own sessions had to refuse.
@MainActor
@Suite(.serialized) struct DemoNoTraceTests {
    /// Every request the shared session is asked for while the demo runs, recorded ("<method> <URL>") and failed.
    final class SharedSessionWatch: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var urls: [String] = []
        static var seen: [String] { lock.withLock { urls } }
        static func reset() { lock.withLock { urls = [] } }
        override class func canInit(with request: URLRequest) -> Bool {
            lock.withLock { urls.append("\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "no URL")") }
            return true
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }

    private func waitUntil(_ seconds: Double = 15, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private static var sharedMedia: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("vory-media", isDirectory: true)
    }

    private static var botPhotos: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appending(path: "BotAvatars", directoryHint: .isDirectory)
    }

    private static func files(in dir: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    /// The Keychain as the test host has it. The unsigned Mac test host (CODE_SIGNING_ALLOWED=NO) has no Keychain
    /// entitlement, and every call fails with errSecMissingEntitlement (-34018): there the checks run on the Keychain's
    /// in-memory store (`Keychain.memoryOnly`), which the app's own reads and writes go through too, so a test reads what
    /// it wrote. A signed host (the iOS simulator) keeps the real one. Returns the setting to put back.
    private static func useWorkingKeychain() -> Bool {
        let was = Keychain.memoryOnly
        let probe = "dev.vory.tests.demotrace.probe"
        if (try? Keychain.set(Data([1]), account: probe)) == nil { Keychain.memoryOnly = true } else { Keychain.delete(account: probe) }
        return was
    }

    /// Every key of the defaults that names the demo's gateway or one of its chats.
    private static func demoKeys(_ ids: [String]) -> [String] {
        let ids = ids.filter { !$0.isEmpty }.map { $0.uppercased() }
        return UserDefaults.standard.dictionaryRepresentation().keys.filter { k in ids.contains { k.uppercased().contains($0) } }.sorted()
    }

    /// The app's own folders under Caches and Application Support (the transcripts, the media and the pictures), walked
    /// through: whatever in them is named after the demo's gateway.
    private static func demoFiles() -> [String] {
        let id = GatewayConnection.demoID.uuidString
        let fm = FileManager.default
        var roots: [URL] = []
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots += ["transcripts", "vory-media", "vory-web-images", "vory-voice-previews"].map { caches.appending(path: $0, directoryHint: .isDirectory) }
        }
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(support.appending(path: "BotAvatars", directoryHint: .isDirectory))
        }
        var out: [String] = []
        for root in roots {
            guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in walk where u.lastPathComponent.uppercased().contains(id) { out.append(u.path) }
        }
        return out
    }

    /// Each demo chat's transcript cache file, by path, with when it was last written (none: absent). A copy an older
    /// build left there (one without the guard) is not this run's: what counts is that nothing writes it now.
    private static func cacheStamps() -> [String: Date] {
        var out: [String: Date] = [:]
        for c in DemoContent.chats {
            guard let u = TranscriptCache.url(connection: GatewayConnection.demoID, storedID: c.id),
                  let d = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date else { continue }
            out[u.path] = d
        }
        return out
    }

    /// A runtime on the demo's transport keeps nothing whatever its connection: onboarding's tour (#388) makes one of its
    /// own for a moment, not on the demo connection, and every store's check (`isEphemeral`) covers it as it covers the
    /// demo. The same connection over the network is an ordinary gateway.
    @Test func aRuntimeOnTheDemoTransportIsEphemeralWhateverItsConnection() async throws {
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "dev.vory.tests.demotrace." + UUID().uuidString)!, connections: [])
        let own = GatewayConnection(name: "tour", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        #expect(!own.isDemo)
        let tour = GatewayRuntime(connection: own, store: store, transport: .demo(DemoGateway(pace: .quick)))
        #expect(tour.isEphemeral)
        #expect(tour.scratchDirectory.path != FileManager.default.temporaryDirectory.path, "the tour's files would go to the shared folder")
        await tour.stop()
        let net = GatewayRuntime(connection: own, store: store)
        #expect(!net.isEphemeral)
        #expect(net.scratchDirectory.path == FileManager.default.temporaryDirectory.path)
    }

    @Test func aDemoUsedAndLeftLeavesNoTraceAndSendsNothingAnywhere() async throws {
        // Nothing else writes the stores read here: the test host connects no gateway of its own (#494; a used
        // simulator's saved gateway did, and rewrote the widgets' snapshot mid-test).
        #expect(AppModel.isUnitTestHost && AppModel.shared.runtime == nil, "the test host runs \(AppModel.shared.runtime?.connection.name ?? "a gateway"), which writes the stores this test reads")
        let keychainWas = Self.useWorkingKeychain()
        defer { Keychain.memoryOnly = keychainWas }
        // A clean start, as on a new device: what an earlier run (or an older build) left for the demo would hide a
        // write of this one's, its key already there with the same ids (#493: how the cache of the demo's chat list
        // got past this test).
        let chatIDs = DemoContent.chats.map(\.id)
        DemoTraces.sweep()
        for key in Self.demoKeys(chatIDs) { UserDefaults.standard.removeObject(forKey: key) }
        #expect(Self.demoKeys([GatewayConnection.demoID.uuidString] + chatIDs).isEmpty)
        #expect(Self.demoFiles().isEmpty)
        let cacheBefore = Self.cacheStamps()
        // The person's own settings and looks the app's screens could write from the demo (#494), as they were.
        let ownKeys = [GatewayRuntime.defaultProfileKey, "chats.filter.project", "chats.byProject.collapsed", "chats.archivedRooms",
                       "companionPromptShown", "notificationsSetupCardDone"]
        let ownBefore = ownKeys.map { UserDefaults.standard.object(forKey: $0).map { "\($0)" } }
        let looksBefore = Keychain.get(account: BotLooks.account)
        let photosBefore = Self.files(in: Self.botPhotos)
        let defaultsBefore = UserDefaults.standard.dictionaryRepresentation()
        let renamedBefore = UserDefaults.standard.stringArray(forKey: ChatSession.renamedByPersonKey) ?? []
        let snapshotBefore = WidgetSnapshot.load()
        let mediaBefore = Self.files(in: Self.sharedMedia)
        let refusedBefore = DemoURLProtocol.refused
        SharedSessionWatch.reset()
        URLProtocol.registerClass(SharedSessionWatch.self)
        // A relay set, so a registration with it during the demo would be seen (Debug builds have none, #501).
        PushRelay.testURL = URL(string: "https://relay.test.invalid")
        defer { URLProtocol.unregisterClass(SharedSessionWatch.self); PushRelay.testURL = nil }
        try #require(PushRelay.isConfigured, "no relay: a request to it could not be seen")

        let suite = "dev.vory.tests.demotrace." + UUID().uuidString
        let store = ConnectionStore(defaults: UserDefaults(suiteName: suite)!, connections: [])
        store.activeConnectionID = GatewayConnection.demoID
        let rt = GatewayRuntime(connection: .demo, store: store, transport: .demo(DemoGateway(pace: .quick)))
        await rt.start()
        let scratch = rt.scratchDirectory
        #expect(scratch.path != FileManager.default.temporaryDirectory.path)

        // Every chat opened and read (each would have been cached on a real gateway).
        for c in DemoContent.chats {
            let chat = try await rt.openChat(storedID: c.id, title: c.title, profile: c.bot, waitForResume: true)
            #expect(!chat.items.isEmpty, "\(c.title) opened empty")
        }
        // A turn with its approval, then a rename.
        let chat = try await rt.newChat(profile: "default")
        _ = await chat.send("What's taking up the most space on my server?")
        await waitUntil { chat.cards.contains { $0.method == "approval" } }
        let card = try #require(chat.cards.first { $0.method == "approval" })
        await chat.respond(card: card, result: .object(["choice": .string("once")]))
        let done = try #require(DemoContent.cleanup.approval).done
        await waitUntil { !chat.isRunning && chat.items.contains { if case .assistant(let t, _, _) = $0.kind { return t.contains(done) }; return false } }
        await chat.rename("Server space")
        // The board (read, and a board chosen), a picture, a download, an attachment staged.
        await rt.kanban.refresh()
        rt.kanban.select(board: "default")
        let picture = try await rt.media.localURL(for: MediaRef(path: "/home/demo/images/ereader-battery.png"),
                                                  gateway: rt.connection.id.uuidString, api: GatewayMediaAPI(api: rt.api))
        #expect(picture.path.hasPrefix(scratch.path), "the picture went to \(picture.path)")
        let download = try await rt.api.download("/api/files/download", query: [URLQueryItem(name: "path", value: "/home/demo/trip/packing.md")])
        #expect(download.path.hasPrefix(scratch.path), "the download went to \(download.path)")
        chat.stageAttachment(data: Data("hello".utf8), name: "note.txt", kind: .file)
        #expect(chat.staged.first?.localURL?.path.hasPrefix(scratch.path) == true)
        // What the app's own screens write, done as they do it in the demo (#494): Home's month for the widgets, a default
        // bot chosen, the chat list's project filter, folded projects and archived rooms, and the looks' copy.
        let month: UsageAnalytics = try await rt.api.get("/api/analytics/usage", query: [URLQueryItem(name: "days", value: "30")])
        DashboardView.keepForWidgets(month, sessions: nil, runtime: rt)
        rt.defaultProfileChoice = DemoContent.bots.last?.name ?? "default"
        let prefs = ChatListPrefs.shared
        prefs.inDemo = true
        prefs.projectFilter = "demo-project"; prefs.collapsedRaw = "demo-project"; prefs.archivedRoomsRaw = "room-weekend"
        prefs.inDemo = false
        DemoLooks.set(on: true)
        BotLooksMirror.mirror()
        DemoLooks.set(on: false)
        await rt.stop()

        // No trace. The defaults: no key of the core's for the demo, and nothing that names its gateway or a chat of it.
        let demoIDs = [GatewayConnection.demoID.uuidString, chat.storedID] + DemoContent.chats.map(\.id)
        let added = UserDefaults.standard.dictionaryRepresentation().filter { defaultsBefore[$0.key] == nil }.map(\.key)
        let ours = added.filter { key in demoIDs.contains { key.contains($0) } || ["kanban.", "gateway.", "chat.", "chats.", "transcript"].contains { key.hasPrefix($0) } }
        #expect(ours.isEmpty, "the demo wrote defaults: \(ours.sorted())")
        // From the clean start: no key names the demo or a chat of it, and no file is named after it, at all.
        #expect(Self.demoKeys(demoIDs).isEmpty, "keys that name the demo: \(Self.demoKeys(demoIDs))")
        #expect(Self.demoFiles().isEmpty, "files named after the demo: \(Self.demoFiles())")
        let renamed = UserDefaults.standard.stringArray(forKey: ChatSession.renamedByPersonKey) ?? []
        #expect(renamed == renamedBefore, "the demo's rename was recorded")
        #expect(Self.cacheStamps() == cacheBefore, "a demo chat was written to the transcript cache")
        #expect(TranscriptCache.load(connection: GatewayConnection.demoID, storedID: chat.storedID) == nil, "the new chat was cached")
        #expect(Self.files(in: Self.sharedMedia) == mediaBefore, "the shared media cache changed")
        let snapshotAfter = WidgetSnapshot.load()
        #expect(snapshotAfter == snapshotBefore, "the widgets' snapshot changed: \(snapshotBefore.map { "\($0.gatewayName) \($0.connectionID) at \($0.updatedAt.timeIntervalSince1970)" } ?? "none") -> \(snapshotAfter.map { "\($0.gatewayName) \($0.connectionID) at \($0.updatedAt.timeIntervalSince1970)" } ?? "none")")
        let ownAfter = ownKeys.map { UserDefaults.standard.object(forKey: $0).map { "\($0)" } }
        #expect(ownAfter == ownBefore, "the demo changed the person's own settings: \(zip(ownKeys, zip(ownBefore, ownAfter)).filter { $0.1.0 != $0.1.1 }.map(\.0))")
        #expect(Keychain.get(account: BotLooks.account) == looksBefore, "the looks' copy for the extensions and the Watch changed")
        #expect(Self.files(in: Self.botPhotos) == photosBefore, "the bots' photos changed")
        #expect(!FileManager.default.fileExists(atPath: scratch.path), "the demo's scratch folder is still there")
        #expect(store.connections.isEmpty && UserDefaults(suiteName: suite)?.string(forKey: "activeConnectionID") == nil)
        // Nothing sent anywhere.
        #expect(SharedSessionWatch.seen.isEmpty, "the shared session was asked for \(SharedSessionWatch.seen)")
        #expect(DemoURLProtocol.refused == refusedBefore, "a demo session asked for another host")
    }

    /// Home's "since you were here" mark is kept from the person's own visits only: a visit in the demo writes none, so
    /// after leaving it Home measures from their own last visit (the demo legs found the demo's Home visit kept).
    /// The chat list's cache never keeps the demo's list, and never reads back one an older build kept (#493): read back,
    /// the list kept its chats' first times (a chat keeps its time until it has new messages), so the demo's chats aged
    /// a day at a time. The sweep at launch and on leaving the demo takes such a list away; a gateway's own list is kept.
    @Test func theChatListsCacheNeverKeepsTheDemos() throws {
        let demo = GatewayConnection.demoID
        let key = SessionCache.key(connection: demo, profile: "default")
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let list = [StoredSession(id: DemoContent.botChatID, title: "Bot Chat", lastActive: 1, messageCount: 4)]
        SessionCache.save(list, connection: demo, profile: "default")
        #expect(UserDefaults.standard.object(forKey: key) == nil, "the demo's list was saved")
        UserDefaults.standard.set(try JSONEncoder().encode(list), forKey: key)
        #expect(SessionCache.load(connection: demo, profile: "default").isEmpty, "an older build's list was read back")
        #expect(SessionCache.loadAny(connection: demo).isEmpty, "an older build's list was read back")
        DemoTraces.sweep()
        #expect(UserDefaults.standard.object(forKey: key) == nil, "the sweep left an older build's list")

        let own = UUID()
        defer { UserDefaults.standard.removeObject(forKey: SessionCache.key(connection: own, profile: "default")) }
        SessionCache.save(list, connection: own, profile: "default")
        #expect(SessionCache.load(connection: own, profile: "default").map(\.id) == [DemoContent.botChatID])
        DemoTraces.sweep()
        #expect(SessionCache.load(connection: own, profile: "default").map(\.id) == [DemoContent.botChatID], "the sweep took a gateway's own list")
    }

    /// The sweep at launch leaves a demo that is already running alone (a test build started in it, `-vory-demo`), and
    /// takes the demo's keys when it isn't; leaving the demo sweeps either way. It takes the demo's gateway id only.
    @Test func theLaunchSweepSkipsADemoThatRuns() throws {
        let suite = "dev.vory.tests.demotrace." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let caches = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: caches) }
        let demoKey = "sessions.cache." + GatewayConnection.demoID.uuidString + ".default"
        let chatKey = "voice.quick.restore." + DemoContent.botChatID
        let folder = caches.appending(path: "transcripts/" + GatewayConnection.demoID.uuidString, directoryHint: .isDirectory)
        func plant() throws {
            defaults.set(Data("[]".utf8), forKey: demoKey)
            defaults.set(["a": 1], forKey: chatKey)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let running = ConnectionStore(defaults: defaults, connections: [])
        running.activeConnectionID = GatewayConnection.demoID
        try plant()
        DemoTraces.sweepAtLaunch(store: running, defaults: defaults, caches: caches)
        #expect(defaults.object(forKey: demoKey) != nil, "the launch sweep took state from under a running demo")
        #expect(FileManager.default.fileExists(atPath: folder.path))

        let saved = ConnectionStore(defaults: defaults, connections: [])
        DemoTraces.sweepAtLaunch(store: saved, defaults: defaults, caches: caches)
        #expect(defaults.object(forKey: demoKey) == nil, "the launch sweep left the demo's key")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "the launch sweep left the demo's transcripts")
        #expect(defaults.object(forKey: chatKey) != nil, "the sweep took a key by a chat id, which a real chat can have")

        try plant()
        DemoTraces.sweep(defaults: defaults, caches: caches)
        #expect(defaults.object(forKey: demoKey) == nil && !FileManager.default.fileExists(atPath: folder.path))
    }

    /// What an older build kept for the demo inside the app's values and in the Keychain goes too (#494): its favourite
    /// models (iCloud would get them), the pin and scheduled-task refusals by its id, its secrets, its Companion's and a
    /// sign-in remembered for it. A gateway's own entries stay.
    @Test func theSweepTakesTheDemosEntriesInsideValuesAndTheKeychain() throws {
        let keychainWas = Self.useWorkingKeychain()
        defer { Keychain.memoryOnly = keychainWas }
        let suite = "dev.vory.tests.demotrace." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let demo = GatewayConnection.demoID.uuidString, own = UUID().uuidString
        defaults.set(#"{"\#(demo)":[{"p":"default","m":"demo/assistant"}],"\#(own)":[{"p":"work","m":"lab/large"}]}"#, forKey: "models.favourites")
        defaults.set([demo, own], forKey: "vory.pins.refused")
        defaults.set([demo: "0.9", own: ""], forKey: "vory.cron.createRefused")
        DemoTraces.sweep(defaults: defaults, caches: nil)
        let favourites = try #require(defaults.string(forKey: "models.favourites"))
        #expect(!favourites.contains(demo) && favourites.contains(own), "favourites: \(favourites)")
        #expect(defaults.stringArray(forKey: "vory.pins.refused") == [own])
        #expect(defaults.dictionary(forKey: "vory.cron.createRefused") as? [String: String] == [own: ""])

        let store = ConnectionStore(defaults: defaults, connections: [])
        store.remembered = RememberedSignInVault(backend: MemoryRememberedSignInBackend())
        try store.remembered.remember(RememberedSignIn(provider: "basic", username: "u", password: "p", gateway: try GatewayURL.normalize("https://127.0.0.1:1")), for: GatewayConnection.demoID)
        try Keychain.set(Data("x".utf8), account: "secrets." + demo)
        try Keychain.set(Data("x".utf8), account: "companion-secrets." + demo)
        DemoTraces.sweepKeychain(store: store)
        #expect(!store.remembered.contains(GatewayConnection.demoID), "a sign-in remembered for the demo stayed")
        #expect(Keychain.get(account: "secrets." + demo) == nil && Keychain.get(account: "companion-secrets." + demo) == nil)
    }

    /// A demo's scratch folder left by an app that ended in the demo is taken away at the next launch (#494), unless a
    /// demo runs, and not one written in the last hour (a test build's temporary folder can be another copy's).
    @Test func theLaunchSweepTakesAStaleDemoFolder() throws {
        let suite = "dev.vory.tests.demotrace." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let temporary = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stale = temporary.appending(path: "vory-demo-stale", directoryHint: .isDirectory)
        let fresh = temporary.appending(path: "vory-demo-fresh", directoryHint: .isDirectory)
        let other = temporary.appending(path: "vory-voice", directoryHint: .isDirectory)
        for f in [stale, fresh, other] { try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: other.path)

        let running = ConnectionStore(defaults: defaults, connections: [])
        running.activeConnectionID = GatewayConnection.demoID
        DemoTraces.sweepAtLaunch(store: running, defaults: defaults, caches: nil, temporary: temporary)
        #expect(FileManager.default.fileExists(atPath: stale.path), "the sweep took a folder while a demo ran")

        DemoTraces.sweepAtLaunch(store: ConnectionStore(defaults: defaults, connections: []), defaults: defaults, caches: nil, temporary: temporary)
        #expect(!FileManager.default.fileExists(atPath: stale.path), "a stale demo folder stayed")
        #expect(FileManager.default.fileExists(atPath: fresh.path), "a demo folder written in the last hour was taken")
        #expect(FileManager.default.fileExists(atPath: other.path), "a folder not the demo's was taken")
    }

    /// Home's month reaches the widgets' snapshot from a gateway only, never from the demo (#493): the demo's numbers
    /// stayed on the saved gateway's widget after leaving it.
    @Test func homesNumbersReachTheWidgetsFromAGatewayOnly() async throws {
        let keychainWas = Self.useWorkingKeychain()
        defer { Keychain.memoryOnly = keychainWas }
        let before = WidgetSnapshot.load()
        defer { if let before { before.save() } else { Keychain.delete(account: WidgetSnapshot.account) } }
        WidgetSnapshot(gatewayName: "Home", connectionID: UUID().uuidString, profile: "default", needsAttention: 0, chats: [], contextPercent: nil).save()
        let planted = WidgetSnapshot.load()
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "dev.vory.tests.demotrace." + UUID().uuidString)!, connections: [])
        let demo = GatewayRuntime(connection: .demo, store: store, transport: .demo(DemoGateway(pace: .quick)))
        await demo.start()
        let month: UsageAnalytics = try await demo.api.get("/api/analytics/usage", query: [URLQueryItem(name: "days", value: "30")])
        DashboardView.keepForWidgets(month, sessions: nil, runtime: demo)
        await demo.stop()
        #expect(WidgetSnapshot.load() == planted, "the demo's numbers went to the widgets")
        let own = GatewayRuntime(connection: GatewayConnection(name: "own", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken), store: store)
        DashboardView.keepForWidgets(month, sessions: nil, runtime: own)
        #expect(WidgetSnapshot.load()?.usage != nil, "a gateway's numbers did not reach the widgets")
    }

    /// The looks the extensions and the Watch read are never copied while the demo runs (#494): its colours come first
    /// then, and its bots' names went along.
    @Test func theLooksMirrorWaitsOutTheDemo() throws {
        let keychainWas = Self.useWorkingKeychain()
        defer { Keychain.memoryOnly = keychainWas }
        func now() throws -> Data {
            let e = JSONEncoder(); e.outputFormatting = .sortedKeys
            return try e.encode(BotLooks.load())
        }
        let before = Keychain.get(account: BotLooks.account)
        defer { if let before { try? Keychain.set(before, account: BotLooks.account) } else { Keychain.delete(account: BotLooks.account) } }
        BotLooks(colors: ["default": "#112233"], avatars: ["default": "initial"]).save()
        let planted = try now()
        DemoLooks.set(on: true)
        defer { DemoLooks.set(on: false) }
        BotLooksMirror.mirror()
        #expect(try now() == planted, "the looks were copied while the demo ran")
        // The copy held back is made when the demo ends (a change of the person's own looks meanwhile, CloudSync's).
        DemoLooks.set(on: false)
        BotLooksMirror.mirrorIfOwed()
        #expect(try now() != planted, "the copy held back during the demo was not made when it ended")
    }

    /// A demo that changed none of the person's looks writes nothing to the extensions' copy as it ends (#494): written on
    /// every leave, it was a first write of their default looks, which #487's replay check saw as the demo's doing. The
    /// copy stays byte for byte as it was, an absent one absent.
    @Test func leavingADemoThatChangedNoLookWritesNoCopy() throws {
        let keychainWas = Self.useWorkingKeychain()
        defer { Keychain.memoryOnly = keychainWas }
        let before = Keychain.get(account: BotLooks.account)
        defer { if let before { try? Keychain.set(before, account: BotLooks.account) } else { Keychain.delete(account: BotLooks.account) } }
        // Nothing owed from an earlier test, then an absent copy.
        BotLooksMirror.mirrorIfOwed()
        Keychain.delete(account: BotLooks.account)
        DemoLooks.set(on: true)
        DemoLooks.set(on: false)
        BotLooksMirror.mirrorIfOwed()
        #expect(Keychain.get(account: BotLooks.account) == nil, "leaving the demo wrote the looks' copy where there was none")
        // And a copy that was there stays as it was.
        BotLooks(colors: ["default": "#445566"], avatars: [:]).save()
        let kept = Keychain.get(account: BotLooks.account)
        DemoLooks.set(on: true)
        DemoLooks.set(on: false)
        BotLooksMirror.mirrorIfOwed()
        #expect(Keychain.get(account: BotLooks.account) == kept, "leaving the demo rewrote the looks' copy")
    }

    /// A default bot chosen in the demo is the demo's, for its life (#494): the setting is the person's own, kept and
    /// synced, and a demo bot chosen there stayed after leaving. A gateway's choice is kept as before.
    @Test func theDemosDefaultBotIsItsOwn() async throws {
        let key = GatewayRuntime.defaultProfileKey
        let before = UserDefaults.standard.string(forKey: key)
        defer { if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set("mine", forKey: key)
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "dev.vory.tests.demotrace." + UUID().uuidString)!, connections: [])
        let demo = GatewayRuntime(connection: .demo, store: store, transport: .demo(DemoGateway(pace: .quick)))
        await demo.start()
        await demo.loadProfiles()
        #expect(demo.defaultProfileChoice == "", "the demo took the person's default")
        let bot = try #require(DemoContent.bots.last?.name)
        demo.defaultProfileChoice = bot
        demo.returnToDefaultProfile()
        #expect(demo.defaultProfile == bot && demo.selectedProfile == bot)
        await demo.stop()
        #expect(UserDefaults.standard.string(forKey: key) == "mine", "the demo's default bot was kept")

        let own = GatewayRuntime(connection: GatewayConnection(name: "own", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken), store: store)
        #expect(own.defaultProfileChoice == "mine")
        own.defaultProfileChoice = "work"
        #expect(UserDefaults.standard.string(forKey: key) == "work")
    }

    /// The chat list's filter by project, folded projects and archived rooms are the demo's while it runs (#494): kept,
    /// they left the person's list filtered to a project they don't have. Leaving it brings the person's own back.
    @Test func theChatListsProjectFilterIsTheDemosForItsLife() {
        let prefs = ChatListPrefs.shared
        let keys = ["chats.filter.project", "chats.byProject.collapsed", "chats.archivedRooms"]
        let before = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            prefs.inDemo = false
            for (k, v) in zip(keys, before) { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        }
        prefs.inDemo = false
        prefs.projectFilter = "mine"; prefs.collapsedRaw = "a"; prefs.archivedRoomsRaw = "r1"
        prefs.inDemo = true
        #expect(prefs.projectFilter == "" && prefs.collapsedRaw == "" && prefs.archivedRoomsRaw == "", "the demo's list took the person's filter")
        prefs.projectFilter = "proj-lake"; prefs.collapsedRaw = "proj-lab"; prefs.archivedRoomsRaw = "room-weekend"
        #expect(UserDefaults.standard.string(forKey: "chats.filter.project") == "mine", "the demo's filter was kept")
        #expect(UserDefaults.standard.string(forKey: "chats.byProject.collapsed") == "a")
        #expect(UserDefaults.standard.string(forKey: "chats.archivedRooms") == "r1")
        prefs.inDemo = false
        #expect(prefs.projectFilter == "mine" && prefs.collapsedRaw == "a" && prefs.archivedRoomsRaw == "r1", "leaving the demo did not bring the person's own back")

        // Where the person has none, leaving writes none: putting theirs back wrote "" over an absent key.
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        prefs.inDemo = true
        prefs.projectFilter = "proj-lake"; prefs.collapsedRaw = "proj-lab"; prefs.archivedRoomsRaw = "room-weekend"
        prefs.inDemo = false
        #expect(keys.allSatisfy { UserDefaults.standard.object(forKey: $0) == nil }, "leaving the demo wrote \(keys.compactMap { k in UserDefaults.standard.object(forKey: k).map { "\(k)=\($0)" } })")
        #expect(prefs.projectFilter == "" && prefs.collapsedRaw == "" && prefs.archivedRoomsRaw == "")
    }

    #if os(iOS)
    /// Nothing of a demo chat is kept as the app leaves the screen (#494): the record of the chat to reopen held the demo's
    /// chat under its gateway's id until the next launch. A gateway's chat is kept as before.
    @Test func theChatOnScreenIsNotKeptForTheDemo() throws {
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "dev.vory.tests.demotrace." + UUID().uuidString)!, connections: [])
        let demo = GatewayRuntime(connection: .demo, store: store, transport: .demo(DemoGateway(pace: .quick)))
        #expect(AppRestore.kept(id: DemoContent.botChatID, chat: nil, runtime: demo) == nil, "a demo chat was kept to reopen")
        let own = GatewayRuntime(connection: GatewayConnection(name: "own", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken), store: store)
        #expect(AppRestore.kept(id: "20261013_101500_abc123", chat: nil, runtime: own)?.storedID == "20261013_101500_abc123")
    }
    #endif

    /// A bot card has no Look in the demo (#494): edited there, a look went to the person's own bot of the same name.
    @Test func aBotCardHasNoLookInTheDemo() {
        #expect(!ProfileTab.available(withChat: true, look: false).contains(.look))
        #expect(!ProfileTab.available(withChat: false, look: false).contains(.look))
        #expect(ProfileTab.available(withChat: false, look: false).first == .instructions)
        #expect(ProfileTab.available(withChat: false) == [.look, .instructions, .model, .display])
    }

    /// This device registers for push only with a gateway of the person's own saved, and never in the demo (#501).
    @Test func pushRegistersOnlyWithAGatewayOfThePersonsOwnAndNeverInTheDemo() {
        #expect(PushRegistrar.mayRegister(inDemo: false, hasOwnGateway: true))
        #expect(!PushRegistrar.mayRegister(inDemo: true, hasOwnGateway: true))
        #expect(!PushRegistrar.mayRegister(inDemo: false, hasOwnGateway: false))
        #expect(!PushRegistrar.mayRegister(inDemo: true, hasOwnGateway: false))
    }

    /// The demo registers nowhere, and leaving it with no gateway of the person's own registers nowhere either (#501): a
    /// device token arriving (as after the demo's notification question is answered, or at a later launch), the daily
    /// relay refresh and the launch's registration send nothing; and the person's Companion does not hold back the demo's
    /// local notifications. The control first: with a gateway of their own, outside the demo, the same token goes to the
    /// relay, a request to its host through the shared session. Debug builds have no relay, so the test sets one
    /// (`PushRelay.testURL`, an `.invalid` host the watch catches) and fails without it.
    @Test func theDemoRegistersNowhere() async throws {
        PushRelay.testURL = URL(string: "https://relay.test.invalid")
        let model = AppModel.shared, push = AppModel.shared.push
        let tokenBefore = push.deviceToken, relayAtBefore = push.relayRegisteredAt
        URLProtocol.registerClass(SharedSessionWatch.self)
        defer {
            URLProtocol.unregisterClass(SharedSessionWatch.self)
            PushRelay.testURL = nil; PushRegistrar.ownGatewayForTests = nil
            push.deviceToken = tokenBefore; push.relayRegisteredAt = relayAtBefore
        }
        try #require(PushRelay.isConfigured, "no relay: the check would never see the relay path run")
        func toRelay() -> [String] { SharedSessionWatch.seen.filter { $0.contains("relay.test.invalid") } }
        let token = Data((0..<32).map { UInt8($0) })

        // The control: a gateway of the person's own, outside the demo. The token goes to the relay.
        #expect(!model.isInDemo)
        PushRegistrar.ownGatewayForTests = true
        SharedSessionWatch.reset()
        push.didRegister(token: token)
        let deadline = Date().addingTimeInterval(5)
        while toRelay().isEmpty, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(!toRelay().isEmpty, "the relay was not asked with a gateway of the person's own: the check sees nothing")

        // In the demo: nothing, the person's own gateway or not.
        await model.startDemo()
        #expect(model.isInDemo)
        #expect(!LocalNotifier.companionDelivers, "the person's Companion would hold back the demo's notifications")
        SharedSessionWatch.reset()
        push.didRegister(token: token)
        push.relayRegisteredAt = nil
        await push.refreshRelayIfStale()
        await push.registerForRemoteNotificationsIfAuthorized()
        try? await Task.sleep(for: .milliseconds(500))
        #expect(toRelay().isEmpty, "the demo asked the relay: \(toRelay())")
        #expect(SharedSessionWatch.seen.isEmpty, "the demo sent requests: \(SharedSessionWatch.seen)")
        await model.endDemo()
        // Leaving brings back the person's gateway, if the host has one; none is left running.
        if model.runtime != nil { await model.deactivate() }

        // After the demo, with no gateway of the person's own (notifications allowed in the demo, then a launch): nothing.
        PushRegistrar.ownGatewayForTests = false
        SharedSessionWatch.reset()
        push.didRegister(token: token)
        push.relayRegisteredAt = nil
        await push.refreshRelayIfStale()
        await push.registerForRemoteNotificationsIfAuthorized()
        try? await Task.sleep(for: .milliseconds(500))
        #expect(toRelay().isEmpty, "with no gateway of the person's own the relay was asked: \(toRelay())")
    }

    /// The demo's notification question goes with a message on the app's own demo runtime only (#501): a
    /// tour replayed while the demo is on runs its chat on a runtime of its own (`TourChat`), and its Send asked
    /// the system's question in the middle of the tour. And one question at a time: the settings' read can take seconds
    /// (after a boot, more than ten), and a second message meanwhile asked again. The chats are the app's own: the demo
    /// runtime's (`AppModel.runtime`, as the composer's chat is) and the tour's (`TourChat`, as the tour makes it); the
    /// message goes through the app's observer of a sent message. The question is the tests' stand-in
    /// (`demoNotificationsAskForTests`, here as slow as the system's after a boot): the real one would put up an alert the
    /// host never answers. That it is asked once, while unanswered, is the system's part (DemoNotificationsUITests).
    @Test func onlyTheDemosOwnMessagesAskForNotificationsOneAtATime() async throws {
        final class Asks { var n = 0 }
        let model = AppModel.shared, asks = Asks()
        AppModel.demoNotificationsAskForTests = { asks.n += 1; try? await Task.sleep(for: .milliseconds(800)) }
        defer { AppModel.demoNotificationsAskForTests = nil }
        func sent(_ chat: ChatSession, wait: Double = 0.3) async {
            NotificationCenter.default.post(name: .hermesMessageSent, object: chat)
            try? await Task.sleep(for: .seconds(wait))
        }

        await model.startDemo()
        let demo = try #require(model.runtime)
        #expect(model.isInDemo && demo.isEphemeral)
        // The tour, replayed with the demo on: its chat on a runtime of its own. Its Send asks nothing.
        let tour = TourChat(pace: .quick, appHasGateway: { model.hasConnections }, appInDemo: { model.isInDemo })
        await tour.start()
        let tourChat = try #require(tour.chat)
        #expect(tourChat.runtime !== demo && tourChat.runtime.isEphemeral)
        await sent(tourChat, wait: 1)
        #expect(asks.n == 0, "the tour's message asked the demo's notification question")
        await tour.stop()

        // The demo's own chat: two messages in a row, the second while the first's question is still under way. One ask.
        let chat = try await demo.newChat()
        #expect(chat.runtime === demo)
        await sent(chat, wait: 0.1)
        await sent(chat, wait: 1.2)
        #expect(asks.n == 1, "two messages in a row asked \(asks.n) times")
        // Once it is over, the next message may ask again (the system's own state then says it is answered).
        await sent(chat, wait: 1.2)
        #expect(asks.n == 2)

        await model.endDemo()
        if model.runtime != nil { await model.deactivate() }
        // Out of the demo, a message asks nothing.
        await sent(chat, wait: 0.3)
        #expect(asks.n == 2)
    }

    /// The relay forgets this device with the last of the person's gateways only (#509). Its record is one per install,
    /// and every gateway with this device's file sends through it: removing one of two gateways leaves it (the other's
    /// pushes go on) and keeps the day's registration; removing the last takes it away and clears that, so the next
    /// foreground registers again rather than up to a day later. Notifications turned off and the app reset take it away
    /// whatever is saved, with no gateway open too. Debug builds have no relay, so the test sets one (`PushRelay.testURL`, an `.invalid` host the
    /// watch catches).
    @Test func theRelayForgetsThisDeviceWithItsLastGatewayOnly() async throws {
        #expect(!PushRegistrar.relayForgets(everywhere: false, otherOwnGateways: true))
        #expect(PushRegistrar.relayForgets(everywhere: false, otherOwnGateways: false))
        #expect(PushRegistrar.relayForgets(everywhere: true, otherOwnGateways: true))

        PushRelay.testURL = URL(string: "https://relay.test.invalid")
        let push = AppModel.shared.push
        let tokenBefore = push.deviceToken, relayAtBefore = push.relayRegisteredAt, relayErrorBefore = push.relayError
        URLProtocol.registerClass(SharedSessionWatch.self)
        defer {
            URLProtocol.unregisterClass(SharedSessionWatch.self)
            PushRelay.testURL = nil; PushRegistrar.ownGatewaysForTests = nil; PushRegistrar.ownGatewayForTests = nil
            push.deviceToken = tokenBefore; push.relayRegisteredAt = relayAtBefore; push.relayError = relayErrorBefore
        }
        try #require(PushRelay.isConfigured, "no relay: the check would never see the relay path run")
        func toRelay(_ method: String) -> [String] {
            SharedSessionWatch.seen.filter { $0.hasPrefix(method + " ") && $0.contains("relay.test.invalid") }
        }
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "dev.vory.tests.relay." + UUID().uuidString)!, connections: [])
        func gateway(_ name: String) throws -> GatewayRuntime {
            GatewayRuntime(connection: GatewayConnection(name: name, gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken), store: store)
        }
        let a = try gateway("a"), b = try gateway("b")
        let registered = Date()

        // One of two removed: the relay keeps this device, and the day's registration stands.
        PushRegistrar.ownGatewaysForTests = [a.connection.id, b.connection.id]
        push.relayRegisteredAt = registered
        SharedSessionWatch.reset()
        await push.removeRegistration(runtime: a, everywhere: false)
        #expect(toRelay("DELETE").isEmpty, "removing one of two gateways took this device off the relay: the other's pushes stop")
        #expect(push.relayRegisteredAt == registered)

        // The last removed: the relay forgets this device, and the next foreground registers it again.
        PushRegistrar.ownGatewaysForTests = [b.connection.id]
        SharedSessionWatch.reset()
        await push.removeRegistration(runtime: b, everywhere: false)
        #expect(!toRelay("DELETE").isEmpty, "removing the last gateway left this device on the relay: \(SharedSessionWatch.seen)")
        #expect(push.relayRegisteredAt == nil, "the day's registration stood: the next foreground would not register for up to 24 h")
        PushRegistrar.ownGatewayForTests = true
        push.deviceToken = String(repeating: "0a", count: 32)
        SharedSessionWatch.reset()
        await push.refreshRelayIfStale()
        #expect(!toRelay("POST").isEmpty, "the foreground after did not register again: \(SharedSessionWatch.seen)")

        // Notifications off: the relay forgets this device with another gateway still saved.
        PushRegistrar.ownGatewaysForTests = [a.connection.id, b.connection.id]
        push.relayRegisteredAt = registered
        SharedSessionWatch.reset()
        await push.notificationsTurned(on: false, runtime: a)
        #expect(!toRelay("DELETE").isEmpty, "notifications off left this device on the relay")
        #expect(push.relayRegisteredAt == nil)

        // Notifications turned off with no gateway open (the toggle's step): the relay forgets this device all the same.
        push.relayRegisteredAt = registered
        SharedSessionWatch.reset()
        await push.notificationsTurned(on: false, runtime: nil)
        #expect(!toRelay("DELETE").isEmpty, "notifications off with no gateway open left this device on the relay")
        #expect(push.relayRegisteredAt == nil)

        // The app reset with no gateway open (`resetApp`'s step, not resetApp itself, which would wipe the test host): the
        // same.
        push.relayRegisteredAt = registered
        SharedSessionWatch.reset()
        await push.removeEverywhere(runtime: nil)
        #expect(!toRelay("DELETE").isEmpty, "a reset with no gateway open left this device on the relay")
        #expect(push.relayRegisteredAt == nil)
    }

    @Test func homesVisitMarkIsNeverTheDemos() {
        #expect(HomeVisit.mark(kept: 100, visitStart: 200, inDemo: true) == nil)
        #expect(HomeVisit.mark(kept: 0, visitStart: 200, inDemo: true) == nil)
        #expect(HomeVisit.mark(kept: 100, visitStart: 200, inDemo: false) == 200)
        #expect(HomeVisit.mark(kept: 300, visitStart: 200, inDemo: false) == 300)
    }
}
