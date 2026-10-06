import SwiftUI
import VoryCore

@main
struct VoryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        #if DEBUG
        // The demo copy (its own bundle id): credentials in memory, iCloud a dictionary.
        DemoMode.prepare()
        // Waits of the main thread over a quarter of a second, in the "perf" log.
        Perf.watchMainThread()
        #endif
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
                // A chat handed over from the Mac (or another iPhone or iPad): open it here.
                .continuesHandoff(model)
                .task {
                    await model.activateSavedConnection()
                    await model.refreshCompanionUpdateFlag()
                }
                .onChange(of: model.lock.isLocked) { _, locked in
                    if !locked { Task { await model.signInAgainIfExpired() } }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        LocalNotifier.isForeground = true
                        // A reply that streamed while the app was away is drawn now, once.
                        model.runtime?.isAway = false
                        BotMotionSource.shared.apply(active: true)
                        model.lock.willEnterForeground()
                        // "Last checked" moves every time the app comes forward, and the day's
                        // backup runs from here when it is due (the Mac does the same on activation).
                        CloudSync.shared.syncNow()
                        Task { await model.push.refreshAuthorization() }
                        Task { await model.refreshCompanionUpdateFlag() }
                        // Live Activities whose turn ended while the app was away must not linger,
                        // and one whose turn is still going must not be ended on old knowledge.
                        LiveActivityController.settleAtForeground(runtime: model.runtime)
                        AwayWatch.shared.returned(runtime: model.runtime)
                        Task { await model.push.refreshRelayIfStale() }
                        // A session that ran out while the app was away: a remembered sign-in
                        // signs it in again now (after the app's own lock, if that is up).
                        Task { await model.signInAgainIfExpired() }
                    case .background:
                        // Out of sight: streaming replies stop redrawing (see GatewayRuntime.isAway).
                        model.runtime?.isAway = true
                        CloudBackupTask.schedule()
                        AwayWatch.shared.left(runtime: model.runtime)
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
