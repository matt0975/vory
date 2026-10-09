import AppKit
import UserNotifications

/// AppKit delegate for APNs registration and notification taps: the Mac's `AppDelegate`.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var model: AppModel? { AppModel.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        LocalNotifier.registerCategories()
        // The daily backup while the app runs (the phone has its background refresh for this).
        Task { @MainActor in BackupScheduler.start() }
        // Continuity Camera only where a photo can go, not in every right-click menu.
        Task { @MainActor in ContinuityMenuFilter.start() }
        // Sleep and wake are the Mac's away and back (the phone's are its scene phase).
        Task { @MainActor in MacSleepAway.shared.start() }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in Self.model?.push.didRegister(token: deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in Self.model?.push.didFailToRegister(error) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // The app is in front: the chat itself shows what arrived, so no banner or sound. The
        // setup wizard's test push is the exception, since seeing it is the point.
        let info = notification.request.content.userInfo
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
