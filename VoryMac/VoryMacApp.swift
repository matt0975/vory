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
        #if DEBUG
        // The demo copy (its own bundle id): credentials in memory, iCloud a dictionary.
        DemoMode.prepare()
        #endif
        // The notification service extension reads the same Keychain group; existing items move over once.
        Keychain.accessGroup = Keychain.sharedGroupFromBundle()
        Keychain.migrateToAccessGroupIfNeeded()
        BotFace.liveGlass = true
        _model = State(initialValue: AppModel.shared)
    }

    @State private var boardCommands = BoardCommands.shared
    @State private var voice = VoiceCoordinator.shared
    @State private var voiceSession = HandsFreeSession.shared

    /// Voice mode on the open chat; with none open, a new chat with the default bot, and the
    /// loop starts on it as soon as it is in front.
    private func toggleVoiceMode() {
        if voiceSession.isActive { voiceSession.end(); return }
        if let chat = model.visibleChat { voiceSession.start(chat: chat); return }
        model.requestVoiceMode()
    }
    /// The newest finished reply in the open chat, for Chat › Speak Last Reply.
    private var lastReply: String? { model.visibleChat.flatMap { VoiceCoordinator.lastReply(in: $0.items) } }
    /// The Board page is the one showing: its menu's keys apply, the Chat menu's ⌘N and ⌘R do not.
    private var boardInFront: Bool { model.selectedTab == .kanban }

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
                // ⌘N is New Task while the Board is in front (the Board menu has it there).
                Button("New Chat") { model.selectedTab = .chats; model.newChatRequest = UUID() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.runtime == nil || boardInFront)
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
                Button("Refresh Chats") { NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.runtime == nil || boardInFront)
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
                Divider()
                // The open chat's newest reply, read aloud by the Speech setting; again stops it.
                Button(voice.isSpeaking ? "Stop Speaking" : "Speak Last Reply") {
                    if voice.isSpeaking { voice.stop() } else if let text = lastReply { voice.speak(text) }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                // Not while voice mode runs: the window's own speech has the player.
                .disabled((!voice.isSpeaking && lastReply == nil) || voiceSession.isActive)
                // Voice mode: the open chat by voice, in the floating window; ⇧⌘V again ends it.
                Button(voiceSession.isActive ? "End Voice Mode" : "Voice Mode") { toggleVoiceMode() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(model.runtime == nil)
            }
            // The Board page's commands; they do nothing unless it is in front.
            CommandMenu("Board") {
                Button("New Task") { boardCommands.newTaskRequest = UUID() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!boardInFront || model.runtime?.kanban.isPresent != true)
                Button("Open Card") { boardCommands.openRequest = UUID() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!boardInFront || boardCommands.selectedID == nil)
                Divider()
                Button("Move Card Left") { boardCommands.move(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!boardInFront || boardCommands.selectedID == nil)
                Button("Move Card Right") { boardCommands.move(1) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!boardInFront || boardCommands.selectedID == nil)
                Divider()
                Button("Nudge Dispatcher") { Task { await model.runtime?.kanban.nudge() } }
                    .disabled(!boardInFront || model.runtime?.kanban.isPresent != true)
                Button("Refresh Board") { Task { await model.runtime?.kanban.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!boardInFront || model.runtime?.kanban.isPresent != true)
            }
        }

        // The Live Activity's job on the Mac: the turns in flight and the approvals waiting, up
        // in the menu bar, with a badge on the Dock for what needs you.
        MenuBarExtra {
            TurnMenu().environment(model)
        } label: {
            // A waveform while a voice session is live, else the turns and approvals.
            Image(systemName: voiceSession.isActive ? "waveform.badge.mic" : board.attention > 0 ? "exclamationmark.bubble.fill" : (board.running > 0 ? "ellipsis.message.fill" : "cloud.fill"))
        }
        .menuBarExtraStyle(.window)

        // Voice mode's window: small, above the others, opened by the main window when a
        // session starts and closed when it ends.
        Window("Voice Mode", id: MacWindow.voice) {
            MacVoiceHUD()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .windowLevel(.floating)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        .defaultSize(width: MacVoiceHUD.size.width, height: MacVoiceHUD.size.height)
    }
}

enum MacWindow {
    static let main = "main"
    static let voice = "voice"
}
