import AppKit
import SwiftUI
import VoryCore

@main
struct VoryMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var model: AppModel
    @State private var board = TurnBoard.shared
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
                    // Looks changed on the phone since: take them.
                    if let rt = model.runtime { Task { await LooksSync.pull(runtime: rt) } }
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
        .commands {
            // Settings… (⌘,) is the Settings tab of the window; the app has one state, not two windows.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.selectedTab = .settings }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Chat") {
                Button("New Chat") { model.selectedTab = .chats; model.newChatRequest = UUID() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.runtime == nil)
                Divider()
                Button("Next Chat") { model.selectedTab = .chats; model.chatStepRequest = .init(direction: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(model.runtime == nil)
                Button("Previous Chat") { model.selectedTab = .chats; model.chatStepRequest = .init(direction: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(model.runtime == nil)
            }
        }

        // The Live Activity's job on the Mac: the turns in flight and the approvals waiting, up
        // in the menu bar, with a badge on the Dock for what needs you.
        MenuBarExtra {
            TurnMenu().environment(model)
        } label: {
            Image(systemName: board.attention > 0 ? "exclamationmark.bubble.fill" : (board.running > 0 ? "ellipsis.message.fill" : "cloud.fill"))
        }
        .menuBarExtraStyle(.window)
    }
}
