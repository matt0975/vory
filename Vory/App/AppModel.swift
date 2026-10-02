import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif
import UserNotifications
import WidgetKit
import VoryCore

/// A deep-link target (from a push/local notification or a Live Activity tap).
struct PendingRoute: Hashable, Sendable {
    var connectionID: UUID?
    var gateway: String?
    var storedSessionID: String
    var profile: String?
    var kind: String?
    var replyText: String?
    var requestID: String?
    var action: String?
}

@MainActor
@Observable
final class AppModel {
    /// The one model, owned here rather than by the scene, so a notification action that launches
    /// the app in the background (no window yet) still has somewhere to go.
    static let shared = AppModel()
    let store = ConnectionStore()
    let lock = AppLock()
    let push = PushRegistrar()
    private(set) var runtime: GatewayRuntime?
    var pendingRoute: PendingRoute?
    /// The chat on screen right now (stored id), so a route to it (a Live Activity tap, a
    /// notification) does not push a second copy of the same chat on top of it.
    var visibleChatID: String?
    /// The chat on screen itself (a fresh one has no stored id yet), for the Mac's Chat menu:
    /// Stop, Approve, Deny.
    var visibleChat: ChatSession?
    /// ⌘F on the Mac: put the cursor in the chat list's search field.
    var focusSearchRequest: UUID?
    /// An Approve/Deny that came from the Live Activity or a notification while "Confirm
    /// approvals" is on: the chat shows it as a question and answers only on a yes.
    var approvalConfirm: ApprovalConfirm?
    var activationError: String?
    var selectedTab: AppTab = .chats
    /// The gateway's companion plugin is older than the one this build ships: Settings › Notifications ›
    /// Background Notifications carry a badge until it is updated.
    var companionUpdateAvailable = false
    /// Companion version found on the gateway by the last check (About shows it).
    var companionInstalledVersion: String?

    /// Re-reads the companion's manifest on the gateway (cheap: two small file reads) and sets
    /// `companionUpdateAvailable`. Called when the app comes to the foreground.
    func refreshCompanionUpdateFlag() async {
        guard let rt = runtime, push.registeredAt != nil else { companionUpdateAvailable = false; return }
        let probe = PushSetupModel()
        await probe.checkCompanion(runtime: rt)
        companionUpdateAvailable = probe.updateAvailable
        companionInstalledVersion = probe.installedVersion
    }

    enum AppTab: String, Hashable, CaseIterable, Sendable, Identifiable {
        var id: String { rawValue }
        case chats, dashboard, bots, files, sessions, cron, approvals, system, projects, status, settings

        var title: String {
            switch self {
            case .chats: return "Chats"
            case .dashboard: return "Home"
            case .bots: return "Bots"
            case .files: return "Files"
            case .sessions: return "Sessions"
            case .cron: return "Tasks"
            case .approvals: return "Approvals"
            case .system: return "System"
            case .projects: return "Projects"
            case .status: return "Status"
            case .settings: return "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .chats: return "bubble.left.and.bubble.right"
            case .dashboard: return "house.fill"
            case .bots: return "person.2.wave.2"
            case .files: return "folder"
            case .sessions: return "list.bullet.rectangle"
            case .cron: return "calendar.badge.clock"
            case .approvals: return "checkmark.shield"
            case .system: return "server.rack"
            case .projects: return "folder.fill"
            case .status: return "waveform.path.ecg"
            case .settings: return "gear"
            }
        }
    }

    /// Raised when the compose circle is tapped; the screen in front decides which bot the new
    /// chat is with.
    var newChatRequest: UUID?
    /// Next (+1) or previous (−1) chat in the list, from the Mac's Chat menu.
    struct ChatStepRequest { let direction: Int; let id = UUID() }
    var chatStepRequest: ChatStepRequest?
    /// The compose circle held down: the full New Message sheet instead of a fresh chat.
    var newChatSheetRequest: UUID?
    /// The bot's page in front, if any, so compose there starts a chat with that bot.
    var composeProfile: String?
    /// The custom tab bar hides while a chat is open on the Chats tab (path-driven, instant)…
    var chatsPathOpen = false
    /// …and while any view marked `hidesTabBar()` is on screen on that tab. Counted per tab: a
    /// tap on the bar as it slides away switches tabs, and the new tab must show it again while
    /// the old one keeps its chat open.
    var tabBarHiders: [AppTab: Int] = [:]
    /// Whether each tab shows its root page (reported by the root views). Tapping the selected
    /// tab while deeper in it bumps `popToRoot`, which re-creates that tab at its root.
    var tabAtRoot: [AppTab: Bool] = [:]
    var popToRoot: [AppTab: Int] = [:]
    /// Bumped on every tap of the already-selected tab (root or not): lists scroll to the top.
    var tabReselected: [AppTab: Int] = [:]
    /// A keyboard is up somewhere: the bar hides rather than floating over it.
    var keyboardUp = false
    var tabBarHidden: Bool { (selectedTab == .chats && chatsPathOpen) || (tabBarHiders[selectedTab] ?? 0) > 0 || keyboardUp }

    init() {
        // Settings, looks and gateways through the person's iCloud (it reads nothing until the
        // next turn of the run loop, when this model exists).
        CloudSync.shared.start(store: store)
        NotificationCenter.default.addObserver(forName: .hermesPushRegistrationNeedsSync, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let rt = self.runtime else { return }
                await self.push.syncRegistration(runtime: rt)
            }
        }
    }

    var hasConnections: Bool { !store.connections.isEmpty }

    func activateSavedConnection() async {
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
        rt.cardNotifier = LocalCardNotifier()
        #if os(iOS)
        rt.activityReporterFactory = { LiveActivityController() }
        #else
        rt.activityReporterFactory = { MenuBarTurnReporter() }   // the menu-bar item is the Mac's Live Activity
        #endif
        rt.onSnapshotPublished = { _ in WidgetCenter.shared.reloadAllTimelines() }
        runtime = rt
        activationError = nil
        await rt.start()
        await push.registerForRemoteNotificationsIfAuthorized()
        #if os(iOS)
        WatchSync.shared.push(store: store)
        #endif
    }

    /// `vory://chat/<stored id>[?profile=<bot>]` from a widget, the Live Activity or a
    /// complication; `vory://chats` just lands on the list.
    func open(_ url: URL) {
        guard url.scheme == "vory" else { return }
        if url.host == "home" {
            // From the Overview widget: Home when it is on the bar, else Chats.
            selectedTab = TabLayout.parse(UserDefaults.standard.string(forKey: TabLayout.storageKey)).visible().contains(.dashboard) ? .dashboard : .chats
            return
        }
        selectedTab = .chats
        if url.host == "chat", let id = url.pathComponents.dropFirst().first {
            let profile = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "profile" }?.value
            pendingRoute = PendingRoute(connectionID: runtime?.connection.id, storedSessionID: id, profile: (profile?.isEmpty == false ? profile : nil) ?? runtime?.selectedProfile)
        }
        // From the Live Activity's Approve / Deny: open the chat on its card and apply the choice.
        if url.host == "approval", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let sid = items.first(where: { $0.name == "session" })?.value, !sid.isEmpty {
            let choice = items.first(where: { $0.name == "choice" })?.value ?? "once"
            var r = PendingRoute(connectionID: runtime?.connection.id, storedSessionID: sid, profile: runtime?.selectedProfile)
            r.action = choice == "deny" ? LocalNotifier.denyAction : LocalNotifier.approveOnceAction
            pendingRoute = r
            Task { await ensureConnection(for: r) }
        }
    }

    /// A "Messaged X" notice was tapped: X's own chat (its Bot Chat session) opens read-only.
    /// X is a routing alias; it matches a profile by name or display name. The session is the
    /// one titled Bot Chat among X's recent chats, the newest if there are several.
    func openBotChat(_ handle: String) async -> String? {
        guard let rt = runtime else { return "Not connected." }
        let key = BotDelivery.key(handle)
        guard let profile = rt.profiles.first(where: { BotDelivery.key($0.name) == key || BotDelivery.key($0.label) == key }) else {
            return "No bot called \(handle) on this gateway."
        }
        do {
            // The gateway names each profile's Bot Chat itself (profiles.list → canonical_session,
            // the live tip of the lineage), which is how the companion finds it too. The recent
            // list is the fallback for a gateway without that field, then a title search.
            var storedID: String?
            if let r = try? await rt.rpc("profiles.list"), let rows = r["profiles"]?.arrayValue {
                for row in rows where row["name"]?.stringValue == profile.name {
                    if let cs = row["canonical_session"], !cs.isNull {
                        storedID = cs["resolved_id"]?.stringValue ?? cs["id"]?.stringValue
                    }
                }
            }
            if storedID == nil {
                let r: SessionListResponse = try await rt.api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "100")], profile: profile.name)
                let own = r.sessions.filter { ($0.profile ?? profile.name) == profile.name }
                storedID = (own.first { $0.title == "Bot Chat" } ?? own.first { ($0.title ?? "").localizedCaseInsensitiveContains("bot chat") })?.id
            }
            if storedID == nil, let r: SessionListResponse = try? await rt.api.get("/api/sessions/search", query: [URLQueryItem(name: "q", value: "Bot Chat")], profile: profile.name) {
                storedID = r.sessions.first { $0.title == "Bot Chat" }?.id
            }
            guard let sid = storedID else { return "\(profile.label) has no Bot Chat yet. Its first bot-to-bot message creates one." }
            var route = PendingRoute(connectionID: rt.connection.id, storedSessionID: sid, profile: profile.name)
            route.kind = "readonly"
            selectedTab = .chats
            pendingRoute = route
            return nil
        } catch { return "Could not list \(profile.label)'s chats: \(error.localizedDescription)" }
    }

    func deactivate() async {
        await runtime?.stop()
        runtime = nil
    }

    /// Back to the first screen on this device, as if Vory had just been installed: every saved
    /// gateway and sign-in, every setting, every bot look. The gateway is told to stop sending
    /// here first. Chats and bots live on the gateway and are not touched. What is in iCloud
    /// stays (Restore brings it back) unless `eraseCloud` asks for that too.
    func resetApp(eraseCloud: Bool) async {
        let sync = CloudSync.shared
        sync.suspended = true
        if let rt = runtime { await push.removeRegistration(runtime: rt) }
        await deactivate()
        for c in store.connections { store.delete(id: c.id) }
        if eraseCloud { sync.eraseCloud() } else { sync.removeOwnDeviceEntry() }
        // What the extensions and widgets read, and the last notification's breadcrumb.
        Keychain.delete(account: BotLooks.account)
        Keychain.delete(account: WidgetSnapshot.account)
        Keychain.delete(account: "push.nse.last")
        BotAvatarStore.removeAllPhotos()
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        lock.isEnabled = false
        selectedTab = .chats
        pendingRoute = nil
        visibleChat = nil
        visibleChatID = nil
        companionUpdateAvailable = false
        companionInstalledVersion = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        WidgetCenter.shared.reloadAllTimelines()
        #if os(iOS)
        WatchSync.shared.push(store: store)
        #endif
        // The screens being torn down save a thing or two on their way out (a last-visit
        // time): once they are gone, wipe once more so the start really is clean.
        try? await Task.sleep(for: .milliseconds(500))
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        sync.resumeAfterReset()
    }

    func deleteConnection(_ id: UUID) async {
        if runtime?.connection.id == id {
            if let rt = runtime { await push.removeRegistration(runtime: rt) }
            await deactivate()
        }
        store.delete(id: id)
        if let next = store.active { await activate(next) }
        #if os(iOS)
        WatchSync.shared.push(store: store)
        #endif
    }

    // MARK: Notification routing

    func route(from userInfo: [AnyHashable: Any], action: String?, replyText: String? = nil) {
        guard let hermes = userInfo["hermes"] as? [String: Any], let sid = hermes["session_id"] as? String else { return }
        var r = PendingRoute(storedSessionID: sid)
        r.connectionID = (hermes["connection_id"] as? String).flatMap(UUID.init(uuidString:))
        r.gateway = hermes["gateway"] as? String
        r.profile = hermes["profile"] as? String
        r.kind = hermes["kind"] as? String
        r.requestID = hermes["request_id"] as? String
        r.action = action
        r.replyText = replyText
        pendingRoute = r
        selectedTab = .chats
        Task { await ensureConnection(for: r) }
    }

    private func ensureConnection(for r: PendingRoute) async {
        // Launched in the background for a notification action: keep the process alive long enough
        // to connect and send, and bring the saved gateway up first.
        #if os(iOS)
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "vory.notification.route")
        defer { if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) } }
        #endif
        if runtime == nil { await activateSavedConnection() }
        let target: GatewayConnection? = r.connectionID.flatMap { store.connection(id: $0) }
            ?? store.connections.first { c in r.gateway.map { c.gateway.description == $0 } ?? false }
            ?? store.active
        guard let target else { return }
        if runtime?.connection.id != target.id { await activate(target) }
        if let p = r.profile, !p.isEmpty, runtime?.selectedProfile != p { runtime?.selectedProfile = p }
        if let action = r.action, let rt = runtime {
            // Quick actions from the notification: reply or answer the approval without opening the chat.
            if action == LocalNotifier.replyAction {
                guard let text = r.replyText, !text.isEmpty else { return }
                // The socket may still be connecting right after a background launch.
                let deadline = Date().addingTimeInterval(12)
                while rt.socketState != .open, Date() < deadline { try? await Task.sleep(for: .milliseconds(250)) }
                if let chat = try? await rt.openChat(storedID: r.storedSessionID, title: nil) {
                    LiveActivityController.note("reply from notification → sending to \(r.storedSessionID.prefix(12))")
                    await chat.send(text)
                } else {
                    LiveActivityController.note("reply from notification: could not open the chat")
                }
                return
            }
            if let chat = try? await rt.openChat(storedID: r.storedSessionID, title: nil) {
                let choice = action == LocalNotifier.approveOnceAction ? "once" : "deny"
                let deadline = Date().addingTimeInterval(8)
                while chat.cards.isEmpty, Date() < deadline { try? await Task.sleep(for: .milliseconds(250)) }
                guard let card = chat.cards.first(where: { $0.method == "approval" }) else { return }
                if ApprovalConfirm.shouldAsk(for: card.approval) {
                    // Settings › Security › Confirm approvals: the chat is open on its card; the
                    // conversation asks once more and only then answers.
                    approvalConfirm = ApprovalConfirm(storedID: chat.storedID, cardID: card.id, choice: choice)
                    LiveActivityController.note("\(choice) from the Lock Screen: waiting for the confirmation")
                } else {
                    await chat.respond(card: card, result: ["choice": .string(choice)])
                }
            }
        }
    }
}

#if os(iOS)
/// UIKit delegate for APNs registration and notification taps. The Mac's is `MacAppDelegate`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var model: AppModel? { AppModel.shared }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Push-to-start tokens and activities the gateway starts by push: observed from the
        // first moment, since the system may have launched the app in the background for one.
        LiveActivityController.observePushStarts()
        UNUserNotificationCenter.current().delegate = self
        LocalNotifier.registerCategories()
        BotLooksMirror.mirror()   // so the notification extensions show the right bot from the start
        #if DEBUG
        // Simulator testing: `simctl push` only works once the app has asked for notification permission.
        if ProcessInfo.processInfo.arguments.contains("-vory-request-notifications") {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
        #endif
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in Self.model?.push.didRegister(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in Self.model?.push.didFailToRegister(error) }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        .noData
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        let nonce = (info["hermes"] as? [String: Any])?["nonce"] as? String
        await MainActor.run {
            // The setup's test watches for these: any push counts as arrived, a nonce as decrypted too.
            PushSetupModel.lastPresentedAt = Date()
            if let nonce { PushSetupModel.presentedNonces.insert(nonce) }
        }
        // The app is in front: the chat itself shows what arrived, so no banner or sound. The
        // setup wizard's test push is the exception, since seeing it is the point.
        let kind = (info["hermes"] as? [String: Any])?["kind"] as? String
        return kind == "test" ? [.banner, .sound, .list] : []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? nil : response.actionIdentifier
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run { Self.model?.route(from: info, action: action, replyText: reply) }
    }
}
#endif

/// A second step for approvals that arrive from outside the chat (Settings › Security).
struct ApprovalConfirm: Equatable {
    /// "risky" (writes, deletes, spends and what the guardian flagged; the default), "all", "off".
    static let modeKey = "approvals.confirmMode"
    /// The first cut's on/off switch, honoured if it was ever set.
    static let key = "approvals.confirmFromOutside"
    static var mode: String {
        if let m = UserDefaults.standard.string(forKey: modeKey) { return m }
        if let old = UserDefaults.standard.object(forKey: key) as? Bool { return old ? "all" : "off" }
        return "risky"
    }
    /// Whether the Lock Screen / notification answers open the app instead of applying at once.
    static var isOn: Bool { mode != "off" }
    /// Whether THIS approval gets the second question. A second yes on everything becomes one
    /// two-tap gesture within a week; it keeps its meaning by staying rare.
    static func shouldAsk(for approval: ApprovalRequest?) -> Bool {
        switch mode {
        case "off": return false
        case "all": return true
        default: return approval.map(ApprovalRisk.isRisky) ?? true
        }
    }
    var storedID: String
    var cardID: String
    /// "once" or "deny".
    var choice: String
}
