import SwiftUI
import VoryCore

/// The Mac window's root: the first-run tour until a gateway is saved, then the app. The lock
/// covers either while it is on.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    /// Asked once, on the first connection: the Companion on this gateway, or one to install.
    @AppStorage("companionPromptShown") private var companionPromptShown = false
    @AppStorage("notificationsSetupCardDone") private var setupCardDone = false
    @State private var showCompanionPrompt = false
    @State private var showInstaller = false
    @State private var companionFound: String?

    var body: some View {
        ZStack {
            if model.hasConnections {
                MainSplitView()
            } else {
                OnboardingView()
                    .frame(minWidth: 520, minHeight: 680)
            }
            if model.lock.isLocked {
                MacLockView()
            }
        }
        // The first time a gateway comes up on this Mac (its own first connection, or one the
        // keychain already held): what the Companion needs from here, if anything.
        .onChange(of: model.runtime?.connection.id, initial: true) { _, id in
            guard id != nil, !companionPromptShown, let rt = model.runtime else { return }
            companionPromptShown = true
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                companionFound = await CompanionPromptSheet.installedVersion(on: rt)
                showCompanionPrompt = true
            }
        }
        .sheet(isPresented: $showCompanionPrompt) {
            CompanionPromptSheet(found: companionFound, install: {
                setupCardDone = true
                showCompanionPrompt = false
                showInstaller = true
            }, allow: {
                setupCardDone = true
                showCompanionPrompt = false
                Task { _ = await model.push.requestAuthorization() }
            }, later: {
                setupCardDone = false
                showCompanionPrompt = false
            })
        }
        .sheet(isPresented: $showInstaller) {
            NavigationStack {
                SetupWizardHost()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showInstaller = false } } }
            }
            .frame(minWidth: 560, minHeight: 680)
        }
    }
}

/// The iOS tab bar as a sidebar: the same tabs, in the user's order, with no limit of four.
/// Chats get three columns like Messages (list in the middle, the open chat beside it); the
/// other tabs take the rest of the window.
private struct MainSplitView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(TabLayout.storageKey) private var tabLayoutRaw = ""
    @State private var columns = NavigationSplitViewVisibility.all
    /// The detail column's stack: the chat (or group chat) beside the list.
    @State private var chatPath = NavigationPath()

    private var tabs: [AppModel.AppTab] { TabLayout.parse(tabLayoutRaw).visible() }

    var body: some View {
        Group {
            if model.selectedTab == .chats {
                NavigationSplitView(columnVisibility: $columns) {
                    Sidebar(tabs: tabs)
                } content: {
                    ChatListView(detailPath: $chatPath)
                        .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 560)
                } detail: {
                    NavigationStack(path: $chatPath) {
                        NoChatView()
                            .navigationDestination(for: ChatRoute.self) { route in ConversationView(route: route) }
                            .navigationDestination(for: RoomRoute.self) { r in RoomView(room: r.room, initialText: r.initialText) }
                    }
                }
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    Sidebar(tabs: tabs)
                } detail: {
                    page(model.selectedTab)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.newChatRequest = UUID() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.runtime == nil || model.selectedTab != .chats)
                    .help("New Chat (⌘N)")
            }
        }
    }

    @ViewBuilder private func page(_ tab: AppModel.AppTab) -> some View {
        switch tab {
        case .chats: EmptyView()   // the three-column layout above
        case .bots: BotsView()
        case .files: FilesView()
        case .sessions: NavigationStack { SessionsView() }
        case .cron: NavigationStack { CronView() }
        case .approvals: NavigationStack { ApprovalsView() }
        case .system: NavigationStack { SystemView() }
        case .settings: SettingsView()
        }
    }
}

/// Vory itself, alive: the flat finish animates and keeps its colour in a background window
/// (the live glass one took on the window's inactive look).
private let liveVory = BotLookSpec(shape: "cloud", eyes: "classic", hex: "#3B7BFF", finish: "flat")

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    var tabs: [AppModel.AppTab]

    var body: some View {
        List(selection: Binding(get: { Optional(model.selectedTab) }, set: { if let t = $0 { model.selectedTab = t } })) {
            ForEach(tabs, id: \.self) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
        }
        .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
        .safeAreaInset(edge: .bottom) { GatewayFooter() }
    }
}

/// The detail column before a chat is chosen.
private struct NoChatView: View {
    var body: some View {
        VStack(spacing: 12) {
            BotFaceView(spec: liveVory, size: 72, active: true, mood: BotFaceView.Mood(profile: "vory-mac-empty", state: .guide))
            Text("No chat selected").font(.title3.weight(.semibold))
            Text("Pick one from the list, or press ⌘N for a new one.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The gateway under the sidebar: its name, the socket, and the way to its form.
private struct GatewayFooter: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                BotFaceView(spec: liveVory, size: 24, active: model.runtime != nil, mood: BotFaceView.Mood(profile: "vory-mac-footer"))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.runtime?.connection.name ?? model.store.active?.name ?? "No gateway").font(.caption.weight(.semibold)).lineLimit(1)
                    Text(model.runtime.map { $0.socketState.label } ?? (model.activationError ?? "Connecting…")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { editing = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Edit gateway")
                    .disabled(model.store.active == nil)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .sheet(isPresented: $editing) {
            NavigationStack { GatewayFormView(existing: model.store.active) }
                .frame(minWidth: 520, minHeight: 640)
        }
    }
}

/// The lock, over everything, until Touch ID or the password says yes.
private struct MacLockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 34, weight: .medium)).foregroundStyle(.secondary)
            Text("Vory is locked").font(.headline)
            if let e = model.lock.lastError { Text(e).font(.footnote).foregroundStyle(.secondary) }
            Button("Unlock with \(model.lock.biometryName)") { Task { await model.lock.unlock() } }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .task { await model.lock.unlock() }
    }
}
