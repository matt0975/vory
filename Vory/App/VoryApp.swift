import Speech
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
        // The 1.5 motion: painted bots run on the model (#304).
        // `-vory-motion-engine NO` leaves the 1.4 drawing on, for the CPU comparison (section 6).
        BotFace.motionEngine = UserDefaults.standard.object(forKey: "vory-motion-engine") == nil || UserDefaults.standard.bool(forKey: "vory-motion-engine")
        #if DEBUG
        BotAmbient.tickHook = { Perf.tick($0) }
        // Which defaults keys change (every write re-runs the views that read defaults). It reads all
        // the defaults on every write: `-vory-no-defaults-probe` leaves it off, for timings (#422).
        if !ProcessInfo.processInfo.arguments.contains("-vory-no-defaults-probe") { DefaultsWriteProbe.start() }
        // `-vory-ask-speech-permission`: the system's speech recognition prompt, a moment after launch, so a UI test can
        // read the words it shows on each device (#500). The app itself never asks: its dictation is on-device.
        if ProcessInfo.processInfo.arguments.contains("-vory-ask-speech-permission") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { SFSpeechRecognizer.requestAuthorization { @Sendable _ in } }
        }
        #endif
        _model = State(initialValue: AppModel.shared)
    }
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("colorSchemePreference") private var scheme = "system"
    @AppStorage(AppTheme.accentKey) private var accentID = "blue"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // The open chat in the scene's storage, for a cold launch after a system end (#371).
                .modifier(RestoreSceneKeeper(model: model))
                .tint(AppTheme.accent(accentID).color)
                .preferredColorScheme(scheme == "light" ? .light : scheme == "dark" ? .dark : nil)
                .onOpenURL { url in model.open(url) }
                // A chat handed over from the Mac (or another iPhone or iPad): open it here.
                .continuesHandoff(model)
                .task {
                    // Started in the background while the phone was locked, the app could not
                    // read which gateways have a remembered sign-in; the window opens unlocked.
                    model.store.remembered.reload()
                    await model.activateSavedConnection()
                    // A cold launch after the system ended the app in the background: the chat
                    // that was open, as it was left (#371).
                    AppRestore.reopenIfDue(model)
                    await model.refreshCompanionUpdateFlag()
                }
                .onChange(of: model.lock.isLocked) { _, locked in
                    if !locked { Task { await model.signInAgainIfExpired() } }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        LocalNotifier.isForeground = true
                        AppRestore.reopenIfDue(model)
                        AppRestore.cameToFront()
                        // A reply that streamed while the app was away is drawn now, once.
                        model.runtime?.isAway = false
                        BotAmbient.shared.displayAsleep = false
                        BotMotionSource.shared.apply(active: true)
                        model.lock.willEnterForeground()
                        // "Last checked" moves every time the app comes forward, and the day's
                        // backup runs from here when it is due (the Mac does the same on activation).
                        // A moment after the transition, not in it: the sync reads the synced
                        // Keychain several times and asks iCloud to flush, synchronous calls that
                        // can wait on the system right after an unlock, and the foreground
                        // transition is where the watchdog counts the main thread's seconds.
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1))
                            CloudSync.shared.syncNow()
                        }
                        // The rest waits for the system's return animation (about half a second):
                        // Keychain reads, the activities' settle and the network checks on the
                        // first frames made the app land with a hitch (Matt, 2026-10-12).
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(600))
                            Task { await model.push.refreshAuthorization() }
                            Task { await model.refreshCompanionUpdateFlag() }
                            // Live Activities whose turn ended while the app was away must not linger,
                            // and one whose turn is still going must not be ended on old knowledge.
                            LiveActivityController.settleAtForeground(runtime: model.runtime)
                            AwayWatch.shared.returned(runtime: model.runtime)
                            Task { await model.push.refreshRelayIfStale() }
                            // Which gateways have a remembered sign-in, read again: a launch while the
                            // phone was locked could not read them, and that process may still be
                            // the one running.
                            model.store.remembered.reload()
                            // A session that ran out while the app was away: a remembered sign-in
                            // signs it in again now (after the app's own lock, if that is up).
                            Task { await model.signInAgainIfExpired() }
                        }
                    case .background:
                        // Out of sight: streaming replies stop redrawing (see GatewayRuntime.isAway).
                        model.runtime?.isAway = true
                        AppRestore.leftFront(model)
                        CloudBackupTask.schedule()
                        AwayWatch.shared.left(runtime: model.runtime)
                        // Every face holds still out of sight, as on a sleeping Mac: a working bot's
                        // face redrew the chat's header at the display's rate in the background (#371).
                        BotAmbient.shared.displayAsleep = true
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


#if DEBUG
/// Prints the defaults keys whose values changed since the last change notification.
enum DefaultsWriteProbe {
    nonisolated(unsafe) private static var last: [String: String] = [:]
    private static func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where k.hasPrefix("composer") || k.hasPrefix("bots") || k.hasPrefix("chat") || k.hasPrefix("tab") || k.hasPrefix("vory") || k.hasPrefix("bot") || k.hasPrefix("summar") || k.hasPrefix("list") || k.hasPrefix("ai") {
            out[k] = String(describing: v).prefix(40).description
        }
        return out
    }
    static func start() {
        last = snapshot()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { _ in
            let now = snapshot()
            let changed = now.filter { last[$0.key] != $0.value }.map(\.key) + last.keys.filter { now[$0] == nil }
            if !changed.isEmpty { Perf.tick("defaults:" + changed.sorted().joined(separator: ",")) }
            last = now
        }
    }
}
#endif
