import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import UserNotifications
import VoryCore

/// Registers this device for APNs and publishes the registration to the gateway so the
/// user's `hermes-push` companion (see server/hermes-push) can deliver background notifications.
@MainActor
@Observable
final class PushRegistrar: PushRegistrationSyncing {
    static let installIDKey = "pushInstallID"

    var deviceToken: String?
    /// One Live Activity per running chat: every open activity's token by stored session id, so
    /// two chats running at once (two bots, a group chat) each get their own pushes and end.
    var liveActivities: [String: (token: String, startedAt: Double)] = [:]
    /// The latest activity, in the single fields older companions (< 1.0.28) read.
    var liveActivityToken: String?
    var liveActivityStartedAt: Double?
    var liveActivitySessionID: String?
    /// When the current activity's push token arrived (nil once the activity ended).
    var liveActivityTokenAt: Date?
    /// Lets the gateway start a Live Activity while the app is closed (push to start).
    var pushToStartToken: String? = UserDefaults.standard.string(forKey: "liveActivity.pushToStartToken")
    var authorization: UNAuthorizationStatus = .notDetermined
    var lastRegistrationPath: String?
    var lastError: String?
    var registeredAt: Date?
    var registrationFailure: String?

    let installID: String

    init() {
        // The id names this phone's device file on the gateway, so it must outlive a reinstall:
        // in the Keychain, with the UserDefaults copy of earlier builds carried over once (a
        // fresh id after a reinstall left the old file behind, and the companion pushed to both).
        if let d = Keychain.get(account: Self.installIDKey), let s = String(data: d, encoding: .utf8), !s.isEmpty { installID = s }
        else {
            let s = UserDefaults.standard.string(forKey: Self.installIDKey) ?? UUID().uuidString.lowercased()
            try? Keychain.set(Data(s.utf8), account: Self.installIDKey)
            installID = s
        }
        UserDefaults.standard.set(installID, forKey: Self.installIDKey)
        NotificationCenter.default.addObserver(forName: .hermesLiveActivityPushToStartToken, object: nil, queue: .main) { [weak self] n in
            let token = n.userInfo?["token"] as? String
            Task { @MainActor in
                guard let self, let token, !token.isEmpty, token != self.pushToStartToken else { return }
                self.pushToStartToken = token
                UserDefaults.standard.set(token, forKey: "liveActivity.pushToStartToken")
                NotificationCenter.default.post(name: .hermesPushRegistrationNeedsSync, object: nil)
            }
        }
        NotificationCenter.default.addObserver(forName: .voryGoalChanged, object: nil, queue: .main) { [weak self] n in
            let sid = n.userInfo?["storedID"] as? String
            let goal = n.userInfo?["goal"] as? String
            Task { @MainActor in
                guard let self, let sid, let goal, let rt = AppModel.shared.runtime else { return }
                self.noteGoal(session: sid, goal: goal, runtime: rt)
            }
        }
        NotificationCenter.default.addObserver(forName: .hermesLiveActivityToken, object: nil, queue: .main) { [weak self] n in
            let token = n.userInfo?["token"] as? String
            let started = n.userInfo?["startedAt"] as? Double
            let sid = n.userInfo?["storedID"] as? String
            Task { @MainActor in
                guard let self, let sid, !sid.isEmpty else { return }
                let active = (token?.isEmpty == false)
                if active, let token { self.liveActivities[sid] = (token, started ?? Date().timeIntervalSince1970) }
                else { self.liveActivities[sid] = nil }
                // The single fields carry the most recently started activity that is still open.
                let latest = self.liveActivities.max { $0.value.startedAt < $1.value.startedAt }
                self.liveActivityToken = latest?.value.token
                self.liveActivityStartedAt = latest?.value.startedAt
                self.liveActivitySessionID = latest?.key
                self.liveActivityTokenAt = latest == nil ? nil : (self.liveActivityTokenAt ?? Date())
                if active { self.liveActivityTokenAt = Date() }
                LiveActivityController.note(active ? "publishing token to the gateway (\(self.liveActivities.count) open)" : "token cleared on the gateway (\(self.liveActivities.count) open)")
                // The gateway's device file carries the tokens; the relay gets each one with the
                // push itself, so it is not re-registered here (that was a KV write per turn,
                // per phone, against a 1,000-a-day free tier).
                NotificationCenter.default.post(name: .hermesPushRegistrationNeedsSync, object: nil)
            }
        }
    }

    var apnsEnvironment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        authorizationRead = true
    }
    /// Whether `authorization` has been read from the system yet (until then it is the default, not the answer). The
    /// first read after a boot can take more than ten seconds.
    private(set) var authorizationRead = false

    func requestAuthorization() async -> Bool {
        do {
            let ok = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])
            await refreshAuthorization()
            if ok { registerForRemote() }
            return ok
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func registerForRemoteNotificationsIfAuthorized() async {
        await refreshAuthorization()
        if authorization == .authorized || authorization == .provisional {
            registerForRemote()
        }
    }

    /// Whether this device registers for push at all (#501): only with a gateway of the person's own saved, and never while
    /// the demo runs. The demo sends nothing anywhere (its replies and approvals are local notifications), and
    /// notifications allowed in it, with no gateway of the person's own, had every launch after send the token to the
    /// relay for nothing that could ever be delivered. With a gateway of their own, nothing changes.
    nonisolated static func mayRegister(inDemo: Bool, hasOwnGateway: Bool) -> Bool { !inDemo && hasOwnGateway }
    private var mayRegisterNow: Bool {
        var own = AppModel.shared.hasOwnGateway
        #if DEBUG
        if let o = Self.ownGatewayForTests { own = o }
        #endif
        return Self.mayRegister(inDemo: AppModel.shared.isInDemo, hasOwnGateway: own)
    }
    #if DEBUG
    /// The tests' say on whether a gateway of the person's own is saved (#501), so the registration checks run the same
    /// whatever gateways the test host has kept. DEBUG only, checked absent from Release at each cut.
    nonisolated(unsafe) static var ownGatewayForTests: Bool?
    #endif

    private func registerForRemote() {
        guard mayRegisterNow else { return }
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// What the device file and the relay call this platform; `hermes_push.py` knows both.
    #if os(macOS)
    static let platform = "macos"
    #else
    static let platform = "ios"
    #endif

    /// The name the gateway shows for this device.
    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    func didRegister(token: Data) {
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
        registrationFailure = nil
        NotificationCenter.default.post(name: .hermesPushRegistrationNeedsSync, object: nil)
        Task { await registerWithRelay() }
    }

    /// With a relay baked into the build, the phone registers itself there; the gateway then only
    /// needs the install id + secret from the device file, never an APNs key.
    func registerWithRelay() async {
        guard notificationsEnabled, PushRelay.isConfigured, mayRegisterNow, let token = deviceToken else { return }
        do {
            try await PushRelay.register(deviceToken: token, platform: Self.platform, bundleID: Bundle.main.bundleIdentifier ?? "", environment: apnsEnvironment, liveActivityToken: nil)
            relayRegisteredAt = Date(); relayError = nil
        } catch { relayError = error.localizedDescription }
    }

    /// Once a day is enough for the relay to know this phone is still around.
    func refreshRelayIfStale() async {
        if let at = relayRegisteredAt, Date().timeIntervalSince(at) < 24 * 3600 { return }
        await registerWithRelay()
    }
    var relayRegisteredAt: Date?
    var relayError: String?

    func didFailToRegister(_ error: Error) {
        registrationFailure = error.localizedDescription
    }

    /// Writes `<profile home>/push/devices/<install id>.json` through the gateway's managed files API.
    /// Settings › Notifications › Notifications. Off removes this phone from the gateway and the
    /// relay, so nothing is sent; on registers it again.
    static let enabledKey = "notificationsEnabled"
    static let muteDesktopOriginKey = "push.muteDesktopOrigin"
    var notificationsEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// When this device last marked a session as its own, so one per chat per minute goes up.
    private var originNoted: [String: Date] = [:]

    /// `<profile home>/push/origins/<stored session id>.json`: which device prompted the chat
    /// last. The Companion skips a phone that asked for quiet while the marker says Mac; a
    /// prompt from the phone writes it again and takes the chat back. Fire and forget.
    func noteSend(session: String, runtime: GatewayRuntime) {
        guard !session.isEmpty, let home = runtime.profileHome else { return }
        if let last = originNoted[session], Date().timeIntervalSince(last) < 60 { return }
        originNoted[session] = Date()
        let safe = session.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) ? Character($0) : "_" }
        let path = "\(home)/push/origins/\(String(safe)).json"
        let marker: JSONValue = ["device_id": .string(installID), "platform": .string(Self.platform), "at": .number(Date().timeIntervalSince1970)]
        Task {
            guard let data = try? JSONEncoder().encode(marker) else { return }
            let body: JSONValue = ["path": .string(path), "data_url": .string("data:application/json;base64," + data.base64EncodedString()), "overwrite": true]
            do { let _: ManagedUploadResult = try await runtime.api.send("POST", "/api/files/upload", json: body) }
            catch { LiveActivityController.note("origin marker failed: \(error.localizedDescription)") }
        }
    }

    /// `<profile home>/push/answers/<request id>.json`: this device answered that approval. The
    /// Companion takes the request's banner down on the other devices and leaves this one be.
    func noteAnswer(requestID: String, session: String, runtime: GatewayRuntime) {
        guard notificationsEnabled, !requestID.isEmpty, let home = runtime.profileHome else { return }
        let safe = requestID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) ? Character($0) : "_" }
        let path = "\(home)/push/answers/\(String(safe)).json"
        let marker: JSONValue = ["device_id": .string(installID), "session_id": .string(session), "at": .number(Date().timeIntervalSince1970)]
        Task {
            guard let data = try? JSONEncoder().encode(marker) else { return }
            let body: JSONValue = ["path": .string(path), "data_url": .string("data:application/json;base64," + data.base64EncodedString()), "overwrite": true]
            do { let _: ManagedUploadResult = try await runtime.api.send("POST", "/api/files/upload", json: body) }
            catch { LiveActivityController.note("answer marker failed: \(error.localizedDescription)") }
        }
    }

    /// `<profile home>/push/goals/<stored session id>.json`: the goal line Vory Summaries wrote
    /// for a working chat. The Companion puts it into the Live Activity updates it pushes (its
    /// own updates would otherwise wipe the line from the card while the app is away), and a
    /// line written on the Mac reaches the phone's card the same way. Fire and forget.
    func noteGoal(session: String, goal: String, runtime: GatewayRuntime) {
        guard notificationsEnabled, !session.isEmpty, !goal.isEmpty, let home = runtime.profileHome else { return }
        let safe = session.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) ? Character($0) : "_" }
        let path = "\(home)/push/goals/\(String(safe)).json"
        let marker: JSONValue = ["goal": .string(String(goal.prefix(160))), "device_id": .string(installID), "at": .number(Date().timeIntervalSince1970)]
        Task {
            guard let data = try? JSONEncoder().encode(marker) else { return }
            let body: JSONValue = ["path": .string(path), "data_url": .string("data:application/json;base64," + data.base64EncodedString()), "overwrite": true]
            do { let _: ManagedUploadResult = try await runtime.api.send("POST", "/api/files/upload", json: body) }
            catch { LiveActivityController.note("goal marker failed: \(error.localizedDescription)") }
        }
    }

    func syncRegistration(runtime: GatewayRuntime) async {
        guard notificationsEnabled, !runtime.isEphemeral else { return }
        guard let token = deviceToken, let home = runtime.profileHome else { return }
        let path = "\(home)/push/devices/\(installID).json"
        var payload: [String: JSONValue] = [
            "schema": 1,
            "device_id": .string(installID),
            "platform": .string(Self.platform),
            "app": "Vory",
            "bundle_id": .string(Bundle.main.bundleIdentifier ?? ""),
            "apns_token": .string(token),
            "apns_environment": .string(apnsEnvironment),
            "live_activity_token": liveActivityToken.map { .string($0) } ?? .null,
            "live_activity_started_at": liveActivityStartedAt.map { .number($0) } ?? .null,
            "live_activity_session_id": liveActivitySessionID.map { .string($0) } ?? .null,
            "live_activities": .array(liveActivities.map { .object(["session_id": .string($0.key), "token": .string($0.value.token), "started_at": .number($0.value.startedAt)]) }),
            // Push to start: with this the companion can begin an activity for a turn that starts
            // while the app is closed. It fills the activity's attributes from `bots` below.
            "live_activity_push_to_start_token": pushToStartToken.map { .string($0) } ?? .null,
            "connection_id": .string(runtime.connection.id.uuidString),
            "gateway": .string(runtime.connection.gateway.description),
            "connection_name": .string(runtime.connection.name),
            "profiles": .array(runtime.profiles.map { .string($0.name) }),
            "device_name": .string(Self.deviceName),
            "registered_at": .string(ISO8601DateFormatter().string(from: Date())),
        ]
        #if os(iOS)
        // The bots' looks, for the activity the companion starts by push; the Mac has no Live Activity.
        payload["bots"] = .object(Dictionary(uniqueKeysWithValues: runtime.profiles.map { p in
            let looks = BotLooks.load()
            let key = looks.key(profile: p.name, label: p.label) ?? p.name
            return (p.name, JSONValue.object(["label": .string(p.label), "hex": .string(looks.colors[key] ?? BotColors.hex(for: p.name)),
                                               "avatar": .string(looks.avatars[key] ?? BotAvatarStore.choice(for: p.name).raw)]))
        }))
        #endif
        #if os(iOS)
        // Quiet while a Mac drives the chat (Settings › Notifications); the Companion reads this.
        payload["mute_desktop_origin"] = .bool(UserDefaults.standard.bool(forKey: Self.muteDesktopOriginKey))
        #endif
        payload.merge(PushRelay.deviceFileFields()) { $1 }
        do {
            let data = try JSONEncoder().encode(JSONValue.object(payload.compactingNulls))
            let body: JSONValue = ["path": .string(path), "data_url": .string("data:application/json;base64," + data.base64EncodedString()), "overwrite": true]
            let _: ManagedUploadResult = try await runtime.api.send("POST", "/api/files/upload", json: body)
            lastRegistrationPath = path
            registeredAt = Date()
            lastError = nil
            // Registered: whether the gateway runs the Companion can be read now. The launch
            // read ran before this (it needs a registration) and found nothing, so until the
            // next foreground the app posted its own banner beside the Companion's push: two
            // per reply and per approval (on the Mac, until Settings was opened).
            if AppModel.shared.companionInstalledVersion == nil {
                Task { @MainActor in await AppModel.shared.refreshCompanionUpdateFlag() }
            }
            if let sid = liveActivitySessionID { LiveActivityController.note("token published for session \(sid.prefix(12))") }
        } catch {
            lastError = "Could not publish the push registration: \(error.localizedDescription)"
            if liveActivityToken != nil { LiveActivityController.note("token publish FAILED: \(error.localizedDescription)") }
        }
    }

    /// Takes this device's registration away from one gateway: its device file there, and the relay's record when no
    /// other gateway of the person's own is left to send through it (`relayForgets`). `everywhere`: this device is to take
    /// pushes from no gateway now (notifications turned off, the app reset), so the relay forgets it whatever is saved.
    func removeRegistration(runtime: GatewayRuntime, everywhere: Bool) async {
        if Self.relayForgets(everywhere: everywhere, otherOwnGateways: ownGateways(besides: runtime.connection.id)) {
            await unregisterFromRelay()
        }
        guard let home = runtime.profileHome else { return }
        let path = "\(home)/push/devices/\(installID).json"
        let _: JSONValue? = try? await runtime.api.send("DELETE", "/api/files", json: ["path": .string(path), "recursive": false])
        if lastRegistrationPath == path { lastRegistrationPath = nil; registeredAt = nil }
    }

    /// Settings' Notifications toggle: on registers this device with the relay and the open gateway; off takes it off
    /// every gateway, the relay with them, whether a gateway is open or not (#509; with none open, off left the relay
    /// holding the token).
    func notificationsTurned(on: Bool, runtime: GatewayRuntime?) async {
        guard on else { await removeEverywhere(runtime: runtime); return }
        guard let runtime else { return }
        await registerWithRelay()
        await syncRegistration(runtime: runtime)
    }

    /// This device is to take pushes from no gateway any more (notifications turned off, the app reset, #509): the open gateway's device file goes,
    /// and the relay forgets the install whether a gateway is open or not. With none open, the relay kept this device's
    /// token after the reset, and an old gateway's Companion could go on pushing to it. The relay needs only the install's
    /// id and secret, so call this before the Keychain is wiped.
    func removeEverywhere(runtime: GatewayRuntime?) async {
        if let runtime { await removeRegistration(runtime: runtime, everywhere: true) } else { await unregisterFromRelay() }
    }

    private func unregisterFromRelay() async {
        await PushRelay.unregister()
        // Registered again at the next foreground, not up to a day later (`refreshRelayIfStale`).
        relayRegisteredAt = nil
    }

    /// Whether the relay forgets this install as one gateway's registration goes (#509). The relay keeps one record per
    /// install, and every gateway with this device's file sends through it: taken away with one gateway's removal (or its
    /// Companion's), the other gateways' pushes stopped. It goes with the last of the person's gateways only, or when the
    /// device is to take pushes from none.
    nonisolated static func relayForgets(everywhere: Bool, otherOwnGateways: Bool) -> Bool { everywhere || !otherOwnGateways }

    /// Whether a gateway of the person's own other than `id` is saved. A removed gateway is still saved when its
    /// registration goes.
    private func ownGateways(besides id: UUID) -> Bool {
        var ids = AppModel.shared.store.connections.map(\.id)
        #if DEBUG
        if let saved = Self.ownGatewaysForTests { ids = saved }
        #endif
        return ids.contains { $0 != id }
    }
    #if DEBUG
    /// The tests' list of the person's saved gateways (#509), so the relay checks run the same whatever gateways the test
    /// host has kept. DEBUG only, checked absent from Release at each cut.
    nonisolated(unsafe) static var ownGatewaysForTests: [UUID]?
    #endif
}

extension Notification.Name {
    static let hermesPushRegistrationNeedsSync = Notification.Name("hermesPushRegistrationNeedsSync")
    static let hermesLiveActivityPushToStartToken = Notification.Name("hermesLiveActivityPushToStartToken")
}

/// Adapter so the core can raise local notifications without importing UserNotifications.
@MainActor
final class LocalCardNotifier: CardNotifying {
    func cardArrived(_ card: PendingCard, chat: ChatSession) { LocalNotifier.cardArrived(card, chat: chat) }
    func turnFinished(chat: ChatSession, error: String?) { LocalNotifier.turnFinished(chat: chat, error: error) }
    func cardSettled(_ card: PendingCard, chat: ChatSession) { LocalNotifier.cardSettled(card) }
}

/// Local notifications for cards and finished turns while the app is not in the foreground.
enum LocalNotifier {
    /// Removes every notification a gateway's chats left, delivered or waiting: leaving the demo (#392) leaves none.
    static func removeAll(connection: UUID) {
        let center = UNUserNotificationCenter.current()
        let id = connection.uuidString
        @Sendable func ours(_ c: UNNotificationContent) -> Bool { (c.userInfo["hermes"] as? [String: Any])?["connection_id"] as? String == id }
        center.getDeliveredNotifications { d in center.removeDeliveredNotifications(withIdentifiers: d.filter { ours($0.request.content) }.map(\.request.identifier)) }
        center.getPendingNotificationRequests { p in center.removePendingNotificationRequests(withIdentifiers: p.filter { ours($0.content) }.map(\.identifier)) }
    }

    static let approvalCategory = "HERMES_APPROVAL"
    static let clarifyCategory = "HERMES_CLARIFY"
    static let turnCategory = "HERMES_TURN"
    static let errorCategory = "HERMES_ERROR"
    static let approveOnceAction = "HERMES_APPROVE_ONCE"
    static let denyAction = "HERMES_DENY"
    static let replyAction = "HERMES_REPLY"

    @MainActor static var isForeground = true
    /// Once this phone is registered with the gateway, the companion sends these; a local copy
    /// would arrive as a duplicate.
    /// Only a gateway with the Companion on it sends anything: registered with a gateway that has
    /// none, the phone would have waited for pushes that never come and shown nothing itself.
    /// Never in the demo (#501): the Companion is the person's gateway's, and its installed version, left from that gateway
    /// until the next refresh, kept the demo's local notifications from showing.
    @MainActor static var companionDelivers: Bool {
        !AppModel.shared.isInDemo && AppModel.shared.push.registeredAt != nil && PushRelay.isConfigured && AppModel.shared.companionInstalledVersion != nil
    }
    @MainActor private static func botName(_ chat: ChatSession) -> String {
        chat.runtime.profiles.first { $0.name == chat.profileName }?.label ?? chat.profileName
    }

    static func registerCategories() {
        // With "Confirm approvals" on (Settings › Security) the actions open the app, which asks
        // once more on the card; off, they answer from the notification without opening it.
        var approveOptions: UNNotificationActionOptions = [.authenticationRequired]
        var denyOptions: UNNotificationActionOptions = [.destructive, .authenticationRequired]
        if ApprovalConfirm.isOn { approveOptions.insert(.foreground); denyOptions.insert(.foreground) }
        let approve = UNNotificationAction(identifier: approveOnceAction, title: "Allow once", options: approveOptions)
        let deny = UNNotificationAction(identifier: denyAction, title: "Deny", options: denyOptions)
        let approval = UNNotificationCategory(identifier: approvalCategory, actions: [approve, deny], intentIdentifiers: [], options: [])
        let clarify = UNNotificationCategory(identifier: clarifyCategory, actions: [], intentIdentifiers: [], options: [])
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let turn = UNNotificationCategory(identifier: turnCategory, actions: [reply], intentIdentifiers: [], options: [])
        let err = UNNotificationCategory(identifier: errorCategory, actions: [], intentIdentifiers: [], options: [])
        let enc = UNNotificationCategory(identifier: "HERMES_ENC", actions: [], intentIdentifiers: [], options: [])
        let test = UNNotificationCategory(identifier: "HERMES_TEST", actions: [], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([approval, clarify, turn, err, enc, test])
    }

    /// Removes the delivered notifications that belong to one chat: its thread, or a push whose
    /// payload names its session.
    static func clearDelivered(for storedID: String) {
        guard !storedID.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { n in
                let c = n.request.content
                if c.threadIdentifier == storedID { return true }
                return ((c.userInfo["hermes"] as? [String: Any])?["session_id"] as? String) == storedID
            }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// A card answered on another device: the notification that offered Approve for it comes
    /// down, whether this app posted it ("card-<id>") or the Companion pushed it (its payload
    /// names the request).
    static func cardSettled(_ card: PendingCard) {
        let center = UNUserNotificationCenter.current()
        let local = "card-\(card.id)"
        center.removePendingNotificationRequests(withIdentifiers: [local])
        let request = card.approval?.requestId
        let ids = Set([card.id, request, request.map { "queue-" + $0 }].compactMap { $0 })
        center.getDeliveredNotifications { delivered in
            let stale = delivered.filter { n in
                if n.request.identifier == local || ids.contains(n.request.identifier) { return true }
                let h = n.request.content.userInfo["hermes"] as? [String: Any]
                return (h?["request_id"] as? String).map(ids.contains) ?? false
            }.map(\.request.identifier)
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    @MainActor
    static func cardArrived(_ card: PendingCard, chat: ChatSession) {
        // In front of the user the card is on screen: a buzz, nothing more.
        #if os(iOS)
        if isForeground { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        #endif
        guard !isForeground, !companionDelivers else { return }
        let bot = botName(chat)
        let content = UNMutableNotificationContent()
        content.threadIdentifier = chat.storedID
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        // The bot (profile) is the sender; the chat title rides in the subtitle, like a thread name.
        content.subtitle = chat.title
        if let a = card.approval {
            content.title = "\(bot) · approval needed"
            content.body = a.description?.isEmpty == false ? a.description! : (a.command ?? "A command is waiting for your decision")
            content.categoryIdentifier = approvalCategory
        } else if let c = card.clarify {
            content.title = "\(bot) · question"
            content.body = c.question ?? c.questions?.first?.question ?? "Hermes needs an answer"
            content.categoryIdentifier = clarifyCategory
        } else {
            content.title = "\(bot) · input needed"
            content.body = card.valuePrompt?.prompt ?? "Hermes is asking for a value"
            content.categoryIdentifier = clarifyCategory
        }
        content.userInfo = userInfo(chat: chat, kind: card.method, card: card)
        schedule(content, id: "card-\(card.id)")
    }

    @MainActor
    static func turnFinished(chat: ChatSession, error: String?) {
        guard !isForeground, !companionDelivers else { return }
        let bot = botName(chat)
        let content = UNMutableNotificationContent()
        content.threadIdentifier = chat.storedID
        content.sound = .default
        content.subtitle = chat.title
        if let error, !error.isEmpty {
            content.title = "\(bot) · turn failed"
            content.body = error
            content.categoryIdentifier = errorCategory
        } else {
            content.title = bot
            let last = chat.items.last(where: { if case .assistant = $0.kind { return !$0.isThinkingOnly }; return false })
            if case .assistant(let text, _, _)? = last?.kind { content.body = String(text.prefix(180)) } else { content.body = "Turn finished" }
            content.categoryIdentifier = turnCategory
        }
        content.userInfo = userInfo(chat: chat, kind: "turn", card: nil)
        schedule(content, id: "turn-\(chat.storedID)-\(Int(Date().timeIntervalSince1970))")
    }

    /// What a notification carries back when it is tapped or answered (`PendingRoute`): the
    /// chat, and for a card the card itself and its request (an approval's own id, as the
    /// Companion's pushes name it), so Approve answers that approval and no other.
    @MainActor
    static func userInfo(chat: ChatSession, kind: String, card: PendingCard?) -> [String: Any] {
        var hermes: [String: Any] = ["connection_id": chat.runtime.connection.id.uuidString,
                                     "gateway": chat.runtime.connection.gateway.description,
                                     "session_id": chat.storedID,
                                     "profile": chat.profileName,
                                     "kind": kind]
        if let card {
            hermes["card_id"] = card.id
            hermes["request_id"] = card.approval?.requestId ?? card.id
        }
        return ["hermes": hermes]
    }

    private static func schedule(_ content: UNMutableNotificationContent, id: String) {
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

#if DEBUG && os(iOS)
import SwiftUI

/// DEBUG, for #501's check: with `-vory-delivered-readout`, a 1 pt element ("debug.delivered") whose value is how many of
/// the demo's local notifications are delivered and how many are pending, and the most ever delivered at once,
/// "delivered/pending/most" (by their `hermes.connection_id`), read again every second, in the background too while the
/// app is kept awake (a notification cleared on the way back counts in "most"). A UI test reads it after sending the app
/// away in the demo, and again after Leave demo. DEBUG only, checked absent from Release at each cut.
struct DemoDeliveredReadout: View {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-vory-delivered-readout")
    @State private var value = "-1/-1/0/-1"
    @State private var most = 0

    var body: some View {
        Text(" ").font(.system(size: 1))
            .accessibilityIdentifier("debug.delivered")
            .accessibilityValue(value)
            .task {
                func demo(_ c: UNNotificationContent) -> Bool {
                    (c.userInfo["hermes"] as? [String: Any])?["connection_id"] as? String == GatewayConnection.demoID.uuidString
                }
                while !Task.isCancelled {
                    // The app's own read of the notification settings, -1 until it has come (the UI test waits for it
                    // before its first message: after a boot the read can outlast the test's wait for the question).
                    let push = AppModel.shared.push
                    let read = push.authorizationRead ? push.authorization.rawValue : -1
                    let center = UNUserNotificationCenter.current()
                    let delivered = await center.deliveredNotifications().filter { demo($0.request.content) }.count
                    let pending = await center.pendingNotificationRequests().filter { demo($0.content) }.count
                    most = max(most, delivered)
                    value = "\(delivered)/\(pending)/\(most)/\(read)"
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}
#endif
