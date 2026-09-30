import AppKit
import SwiftUI
import VoryCore

@main
struct VoryMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var model: AppModel
    @AppStorage("colorSchemePreference") private var scheme = "system"

    init() {
        // The notification service extension reads the same Keychain group; existing items move over once.
        Keychain.accessGroup = Keychain.sharedGroupFromBundle()
        Keychain.migrateToAccessGroupIfNeeded()
        BotFace.liveGlass = true
        _model = State(initialValue: AppModel.shared)
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(model)
                .preferredColorScheme(scheme == "light" ? .light : scheme == "dark" ? .dark : nil)
                .onOpenURL { url in model.open(url) }
                .task {
                    await model.activateSavedConnection()
                    await model.refreshCompanionUpdateFlag()
                }
                // Foreground on the Mac is "the frontmost app": local notifications only while not.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    LocalNotifier.isForeground = true
                    BotAmbient.shared.enabled = true
                    Task { await model.push.refreshAuthorization() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    LocalNotifier.isForeground = false
                }
                // The lock arms when the Mac sleeps or the screen locks, not on every app switch.
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in model.lock.didEnterBackground() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in model.lock.didEnterBackground() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in model.lock.willEnterForeground() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)) { _ in model.lock.willEnterForeground() }
        }
        .defaultSize(width: 980, height: 700)
    }
}
