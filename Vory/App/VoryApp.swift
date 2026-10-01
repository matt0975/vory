import SwiftUI
import VoryCore

@main
struct VoryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        // Widgets and the watch app read the same Keychain group; existing items move over once.
        Keychain.accessGroup = Keychain.sharedGroupFromBundle()
        Keychain.migrateToAccessGroupIfNeeded()
        WatchSync.shared.start()
        ImageTranscode.install()
        TypingHaptics.shared.start()
        BotFace.liveGlass = true
        _model = State(initialValue: AppModel.shared)
    }
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("colorSchemePreference") private var scheme = "system"
    @AppStorage(AppTheme.accentKey) private var accentID = "blue"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(AppTheme.accent(accentID).color)
                .preferredColorScheme(scheme == "light" ? .light : scheme == "dark" ? .dark : nil)
                .onOpenURL { url in model.open(url) }
                .task {
                    await model.activateSavedConnection()
                    await model.refreshCompanionUpdateFlag()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        LocalNotifier.isForeground = true
                        BotMotionSource.shared.apply(active: true)
                        model.lock.willEnterForeground()
                        Task { await model.push.refreshAuthorization() }
                        Task { await model.refreshCompanionUpdateFlag() }
                        // Live Activities whose turn ended while the app was away must not linger.
                        let chats = model.runtime?.chats ?? []
                        LiveActivityController.endOrphans(runningStoredIDs: Set(chats.filter(\.isRunning).map(\.storedID)), knownStoredIDs: Set(chats.map(\.storedID)))
                        Task { await model.push.refreshRelayIfStale() }
                    case .background:
                        BotMotionSource.shared.apply(active: false)
                        LocalNotifier.isForeground = false
                        model.lock.didEnterBackground()
                    case .inactive:
                        LocalNotifier.isForeground = false
                    @unknown default: break
                    }
                }
        }
    }
}
