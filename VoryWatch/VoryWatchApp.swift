import SwiftUI
import UserNotifications
import VoryCore
import WatchKit
import WidgetKit

@main
struct VoryWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var model: WatchModel

    init() {
        // Same Keychain group as the iPhone app's widgets, so gateways synced from the phone and the
        // widget snapshot are visible to the complications extension too.
        Keychain.accessGroup = Keychain.sharedGroupFromBundle()
        Keychain.migrateToAccessGroupIfNeeded()
        let model = WatchModel()
        _model = State(initialValue: model)
        // From the first moment, not from the first screen: a complication push or a notification
        // action that launches the app in the background found no model and did nothing.
        WatchAppDelegate.model = model
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                .dimmedForTests()
                .task { WatchAppDelegate.model = model; await model.start() }
                .onOpenURL { url in model.open(url) }
        }
    }
}

extension View {
    /// DEBUG only: `-vory-test-dimmed YES` draws the app as with the wrist down (the always-on,
    /// dimmed state, `isLuminanceReduced`), which the simulator cannot be put in, for the screenshot
    /// gate and the battery test (#387). It sets that one environment value and nothing else; a
    /// Release build has none of it, the argument's name included.
    @ViewBuilder func dimmedForTests() -> some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "vory-test-dimmed") { environment(\.isLuminanceReduced, true) } else { self }
        #else
        self
        #endif
    }
}

/// Push token, complication refresh pushes and notification actions.
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var model: WatchModel?

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        WatchNotifier.registerCategories()
        WKApplication.shared().registerForRemoteNotifications()
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in Self.model?.push.deviceToken = hex; await Self.model?.syncPush() }
    }

    // WatchKit's spelling of the callback; the UIKit-style name only "nearly matched" it, so
    // a failed registration was never reported on the watch.
    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        Task { @MainActor in Self.model?.push.lastError = error.localizedDescription }
    }

    /// A `complication` push from hermes-push: refresh state, then let WidgetKit redraw.
    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> WKBackgroundFetchResult {
        await Self.model?.refreshForWidgets()
        WidgetCenter.shared.reloadAllTimelines()
        return .newData
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? nil : response.actionIdentifier
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run { Self.model?.route(from: info, action: action, replyText: reply) }
    }
}
