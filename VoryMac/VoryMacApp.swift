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
        #if DEBUG
        // A local ad-hoc build has no provisioned access-group entitlement. It can still test the
        // complete gateway flow with process-lifetime storage; a signed build keeps the Keychain.
        Keychain.useMemoryIfKeychainIsMissingEntitlement()
        #endif
        Keychain.migrateToAccessGroupIfNeeded()
        BotFace.liveGlass = true
        // The 1.5 motion: painted bots run on the model (#304), the same rule as the iPhone's
        // VoryApp; `-vory-motion-engine NO` leaves the 1.4 drawing on for a comparison. Until
        // 2026-10-11 nothing on the Mac set this, so every Mac face kept the 1.4 yaw turn and
        // the Style picker scaled nothing (Matt: "make sure all bots are using the new animation
        // on both iOS and MacOS").
        BotFace.motionEngine = UserDefaults.standard.object(forKey: "vory-motion-engine") == nil || UserDefaults.standard.bool(forKey: "vory-motion-engine")
        // Settings › Bots › Style, as the iPhone applies it at launch (the Mac has no gyroscope
        // part); the 1.4 "Animate bots" switch folds into it first.
        MacBotMotion.migrateAnimateSwitch()
        MacBotMotion.apply()
        _model = State(initialValue: AppModel.shared)
    }

    @State private var boardCommands = BoardCommands.shared
    @State private var voice = VoiceCoordinator.shared
    @State private var voiceSession = HandsFreeSession.shared
    @Environment(\.openWindow) private var openWindow

    /// The chat in front: the open chat while the Chats page shows. The Chats page stays
    /// mounted behind the other pages (MacRootView), so `visibleChat` keeps its chat there;
    /// the Chat menu acts only on the one on screen, as it did when the page was torn down.
    private var frontChat: ChatSession? { model.selectedTab == .chats ? model.visibleChat : nil }

    /// Voice mode on the open chat; with none open, a new chat with the default bot, and the
    /// loop starts on it as soon as it is in front. The main window may be closed (the app
    /// lives on in the menu bar): it comes back first, or the new chat would have no list to open in.
    private func toggleVoiceMode() {
        if voiceSession.isActive { voiceSession.end(); return }
        if let chat = frontChat { voiceSession.start(chat: chat); return }
        openWindow(id: MacWindow.main)
        NSApp.activate()
        model.requestVoiceMode()
    }
    /// The newest finished reply in the open chat, for Chat › Copy and Speak Last Reply. While a
    /// turn runs it is the one kept from before the turn: reading the chat's items here made the
    /// whole app scene (the main menu, the windows' bars) update on every streamed token.
    private var lastReply: String? {
        guard let chat = frontChat else { return nil }
        let key = ObjectIdentifier(chat)
        if chat.isRunning { return Self.keptReply[key] }
        let reply = VoiceCoordinator.lastReply(in: chat.items)
        Self.keptReply[key] = reply
        return reply
    }
    /// The last finished reply read for each chat, for `lastReply` while a turn runs.
    @MainActor private static var keptReply: [ObjectIdentifier: String] = [:]
    /// The Board page is the one showing: its menu's keys apply, the Chat menu's ⌘N and ⌘R do not.
    private var boardInFront: Bool { model.selectedTab == .kanban }

    /// The approval the open chat waits on, if any.
    private var pendingApproval: PendingCard? { frontChat?.cards.first { $0.method == "approval" } }

    private func answerApproval(_ choice: String) {
        guard let chat = frontChat, let card = pendingApproval else { return }
        Task { await chat.respond(card: card, result: ["choice": .string(choice)]) }
    }

    var body: some Scene {
        // One window: the app has one gateway, one selection, one open chat. Closing it leaves
        // the menu bar item; the Dock icon, the Window menu or the menu bar item bring it back.
        Window("Vory", id: MacWindow.main) {
            MacRootView()
                // Bots move only while this window is visible and in front (#248).
                .botWindowLiveness(needsKey: true)
                .environment(model)
                .preferredColorScheme(scheme == "light" ? .light : scheme == "dark" ? .dark : nil)
                .onOpenURL { url in model.open(url) }
                .continuesHandoff(model)
                .task {
                    await model.activateSavedConnection()
                    await model.refreshCompanionUpdateFlag()
                    ActivationRecheck.companion.noteRun()
                }
                // Foreground on the Mac is "the frontmost app": local notifications only while not.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    LocalNotifier.isForeground = true
                    Task { await model.push.refreshAuthorization() }
                    // Anything changed on another device since: take it.
                    CloudSync.shared.syncNow()
                    // Which gateways have a remembered sign-in, read again: the list cannot be
                    // read while the Mac is locked, and the app may have started then.
                    model.store.remembered.reload()
                    // A session that ran out while another app was in front: a remembered
                    // sign-in signs it in again now.
                    Task { await model.signInAgainIfExpired() }
                    // A Companion installed from another device while the Mac ran: noticed
                    // within a few minutes, not at the next relaunch (#243). Throttled, since
                    // the Mac comes to the front at every app switch.
                    ActivationRecheck.companion.runIfDue { await model.refreshCompanionUpdateFlag() }
                }
                .onChange(of: model.lock.isLocked) { _, locked in
                    if !locked { Task { await model.signInAgainIfExpired() } }
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
        // Opening Vory always shows its window (#328: a window closed before quitting meant a
        // launch from Finder, Spotlight or Launchpad could show only the menu bar item). A launch at
        // login shows it too. Restoration stays on, so the window keeps its
        // size and place.
        .defaultLaunchBehavior(.presented)
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
                Button("Refresh Chats") { NotificationCenter.default.post(name: .refreshChats, object: nil) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.runtime == nil || boardInFront)
                Button("Find Chats") { model.selectedTab = .chats; model.focusSearchRequest = UUID() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.runtime == nil)
                Divider()
                // The open chat's turn: stop it, or answer the approval it waits on.
                Button("Stop") { if let c = frontChat { Task { await c.stop() } } }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(frontChat?.isRunning != true)
                Button("Allow Once") { answerApproval("once") }
                    .keyboardShortcut("y", modifiers: [.command, .shift])
                    .disabled(pendingApproval == nil)
                Button("Deny") { answerApproval("deny") }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(pendingApproval == nil)
                Divider()
                // The open chat's newest reply as markdown on the pasteboard (#255): the keyboard and
                // VoiceOver way to the hover button's Copy.
                Button("Copy Last Reply") { if let text = lastReply { UIPasteboard.general.string = TranscriptMedia.copyText(text) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(lastReply == nil)
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
                .botWindowLiveness(needsKey: false)
        } label: {
            // A waveform while a voice session is live, else the turns and approvals.
            Image(systemName: voiceSession.isActive ? "waveform.badge.mic" : board.attention > 0 ? "exclamationmark.bubble.fill" : (board.running > 0 ? "ellipsis.message.fill" : "cloud.fill"))
                // VoiceOver read the symbol's own name ("Mostly Cloudy" for the cloud): the app's
                // name instead, with what is going on, in the words the panel and the rail use (a
                // separate value does not reach the status item, so it rides in the name).
                .accessibilityLabel(voiceSession.isActive ? "Vory, voice mode" : board.attention > 0 ? "Vory, \(board.attention) need\(board.attention == 1 ? "s" : "") you" : board.running > 0 ? "Vory, \(board.running) working" : "Vory")
        }
        .menuBarExtraStyle(.window)

        // Voice mode's window: small, above the others, opened by the main window when a
        // session starts and closed when it ends.
        Window("Voice Mode", id: MacWindow.voice) {
            MacVoiceHUD()
                .botWindowLiveness(needsKey: false)
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

    /// Opens the main window from outside a view (an App Intent, say): the window's own open
    /// action, kept from the root view when it first appeared. Nil until then, which only
    /// happens before the window has ever shown.
    @MainActor static var openMain: (() -> Void)?

    /// The main window in front, by the kept action; before one exists, the app is activated
    /// and the window scene restores itself.
    @MainActor static func bringMainForward() {
        openMain?()
        NSApp.activate()
    }
}
