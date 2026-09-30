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
        #if os(iOS)
        let probe = PushSetupModel()
        await probe.checkCompanion(runtime: rt)
        companionUpdateAvailable = probe.updateAvailable
        companionInstalledVersion = probe.installedVersion
        #else
        // The Mac gets the companion setup with Settings; until then there is nothing to compare.
        _ = rt
        companionUpdateAvailable = false
        #endif
    }

    enum AppTab: String, Hashable, CaseIterable, Sendable {
        case chats, bots, files, sessions, cron, approvals, system, settings

        var title: String {
            switch self {
            case .chats: return "Chats"
            case .bots: return "Bots"
            case .files: return "Files"
            case .sessions: return "Sessions"
            case .cron: return "Tasks"
            case .approvals: return "Approvals"
            case .system: return "System"
            case .settings: return "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .chats: return "bubble.left.and.bubble.right"
            case .bots: return "person.2.wave.2"
            case .files: return "folder"
            case .sessions: return "list.bullet.rectangle"
            case .cron: return "calendar.badge.clock"
            case .approvals: return "checkmark.shield"
            case .system: return "server.rack"
            case .settings: return "gear"
            }
        }
    }

    /// Raised when the compose circle is tapped; the screen in front decides which bot the new
    /// chat is with.
    var newChatRequest: UUID?
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
    var tabBarHidden: Bool { (selectedTab == .chats && chatsPathOpen) || (tabBarHiders[selectedTab] ?? 0) > 0 }

    init() {
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
        rt.activityReporterFactory = { NoTurnActivity() }   // the menu-bar reporter comes with the Mac's Phase 4
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

    func deactivate() async {
        await runtime?.stop()
        runtime = nil
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
