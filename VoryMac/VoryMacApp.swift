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

    /// The approval the open chat waits on, if any.
    private var pendingApproval: PendingCard? { model.visibleChat?.cards.first { $0.method == "approval" } }

    private func answerApproval(_ choice: String) {
        guard let chat = model.visibleChat, let card = pendingApproval else { return }
        Task { await chat.respond(card: card, result: ["choice": .string(choice)]) }
    }

    var body: some Scene {
        // One window: the app has one gateway, one selection, one open chat. Closing it leaves
        // the menu bar item; the Dock icon, the Window menu or the menu bar item bring it back.
        Window("Vory", id: MacWindow.main) {
            MacRootView()
                .environment(model)
                .preferredColorScheme(scheme == "light" ? .light : scheme == "dark" ? .dark : nil)
                .onOpenURL { url in model.open(url) }
                .continuesHandoff(model)
                .task {
                    await model.activateSavedConnection()
                    await model.refreshCompanionUpdateFlag()
                }
                // Foreground on the Mac is "the frontmost app": local notifications only while not.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    LocalNotifier.isForeground = true
                    BotAmbient.shared.enabled = true
                    Task { await model.push.refreshAuthorization() }
                    // Anything changed on another device since: take it.
                    CloudSync.shared.syncNow()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    LocalNotifier.isForeground = false
                }
                // The lock arms when the Mac sleeps or the screen locks, not on every app switch.
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in model.lock.didEnterBackground() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in model.lock.didEnterBackground(); BotAmbient.shared.displayAsleep = true }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in model.lock.willEnterForeground() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)) { _ in model.lock.willEnterForeground(); BotAmbient.shared.displayAsleep = false }
        }
        .defaultSize(width: 980, height: 700)
        .commands {
            // Settings… (⌘,) is the Settings tab of the window; the app has one state, not two windows.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.selectedTab = .settings }.keyboardShortcut(",", modifiers: .command)
            }
            // File › Import from iPhone or iPad: Continuity Camera into the composer.
            ImportFromDevicesCommands()
            CommandMenu("Chat") {
                Button("New Chat") { model.selectedTab = .chats; model.newChatRequest = UUID() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.runtime == nil)
                Button("New Chat With…") { model.selectedTab = .chats; model.newChatSheetRequest = UUID() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.runtime == nil)
                Divider()
                Button("Next Chat") { model.selectedTab = .chats; model.chatStepRequest = .init(direction: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(model.runtime == nil)
                Button("Previous Chat") { model.selectedTab = .chats; model.chatStepRequest = .init(direction: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(model.runtime == nil)
                Button("Find Chats") { model.selectedTab = .chats; model.focusSearchRequest = UUID() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.runtime == nil)
                Divider()
                // The open chat's turn: stop it, or answer the approval it waits on.
                Button("Stop") { if let c = model.visibleChat { Task { await c.stop() } } }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.visibleChat?.isRunning != true)
                Button("Approve Once") { answerApproval("once") }
                    .keyboardShortcut("y", modifiers: [.command, .shift])
                    .disabled(pendingApproval == nil)
                Button("Deny") { answerApproval("deny") }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(pendingApproval == nil)
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

enum MacWindow {
    static let main = "main"
}
