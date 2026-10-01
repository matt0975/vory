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
                            // No back chevron: the list beside it is the way between chats.
                            .navigationDestination(for: ChatRoute.self) { route in ConversationView(route: route).id(route).navigationBarBackButtonHidden(true) }
                            .navigationDestination(for: RoomRoute.self) { r in RoomView(room: r.room, initialText: r.initialText).id(r).navigationBarBackButtonHidden(true) }
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
            // New Chat belongs to the Chats tab; elsewhere the Chat menu (⌘N) switches there first.
            if model.selectedTab == .chats {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { model.newChatRequest = UUID() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                        Button { model.newChatSheetRequest = UUID() } label: { Label("New Chat With…", systemImage: "person.2") }
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    } primaryAction: {
                        model.newChatRequest = UUID()
                    }
                    .disabled(model.runtime == nil)
                    .help("New Chat (⌘N). Hold for bots, a project and a first message (⇧⌘N).")
                }
            }
        }
    }

    @ViewBuilder private func page(_ tab: AppModel.AppTab) -> some View {
        switch tab {
        case .chats: EmptyView()   // the three-column layout above
        case .dashboard: NavigationStack { DashboardView() }
        case .bots: BotsView()
        case .files: FilesView()
        case .projects: NavigationStack { ProjectsView() }
        case .status: NavigationStack { StatusView() }
        case .sessions: NavigationStack { SessionsView() }
        case .cron: NavigationStack { CronView() }
        case .approvals: NavigationStack { ApprovalsView() }
        case .system: NavigationStack { SystemView() }
        // Settings pages are Forms; grouped is the Mac's System Settings look.
        case .settings: SettingsView().formStyle(.grouped)
        }
    }
}

/// Vory itself, alive: the flat finish animates and keeps its colour in a background window
/// (the live glass one took on the window's inactive look).
private let liveVory = BotLookSpec(shape: "cloud", eyes: "classic", hex: "#3B7BFF", finish: "flat")

/// The tabs as a rail: an icon and a word each, the chosen one on a tinted tile, ⌘1…⌘9 to
/// switch, and the gateway at the foot. Narrow on purpose; the chat list is the wide column.
private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    var tabs: [AppModel.AppTab]

    static let width: CGFloat = 84

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(tabs.enumerated()), id: \.element) { i, tab in
                RailItem(tab: tab, selected: model.selectedTab == tab, badge: badge(tab), shortcut: i < 9 ? Character("\(i + 1)") : nil) {
                    model.selectedTab = tab
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The rail does not fold away, so it needs no toggle (which would not fit over it anyway).
        .toolbar(removing: .sidebarToggle)
        .safeAreaInset(edge: .bottom, spacing: 0) { GatewayFooter() }
        // Outermost, and as a closed range: set inside the toolbar modifier the column came out 144 pt wide.
        .navigationSplitViewColumnWidth(min: Self.width, ideal: Self.width, max: Self.width)
    }

    private func badge(_ tab: AppModel.AppTab) -> Int {
        switch tab {
        case .chats, .approvals: return model.runtime?.needsAttention.count ?? 0
        case .settings: return model.companionUpdateAvailable ? 1 : 0
        default: return 0
        }
    }
}

private struct RailItem: View {
    var tab: AppModel.AppTab
    var selected: Bool
    var badge: Int
    var shortcut: Character?
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let button = Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .symbolVariant(selected ? .fill : .none)
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 { CountBadge(badge).scaleEffect(0.78).offset(x: 12, y: -8) }
                    }
                Text(tab.title).font(.caption2.weight(selected ? .semibold : .regular)).lineLimit(1)
            }
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .frame(width: Sidebar.width - 12, height: 54)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.06) : .clear))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(shortcut.map { "\(tab.title) (⌘\($0))" } ?? tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        if let shortcut {
            button.keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        } else {
            button
        }
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

    private var name: String { model.runtime?.connection.name ?? model.store.active?.name ?? "No gateway" }
    private var state: String { model.runtime.map { $0.socketState.label } ?? (model.activationError ?? "Connecting…") }
    private var dot: Color {
        guard let s = model.runtime?.socketState else { return .secondary }
        switch s {
        case .open: return .green
        case .connecting, .reconnecting, .idle: return .orange
        case .authRejected, .failed: return .red
        }
    }

    var body: some View {
        Button { editing = true } label: {
            VStack(spacing: 4) {
                BotFaceView(spec: liveVory, size: 30, active: model.runtime != nil, mood: BotFaceView.Mood(profile: "vory-mac-footer"))
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(dot).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
                Text(name).font(.caption2.weight(.medium)).lineLimit(1).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(name) · \(state)\nClick to edit the gateway")
        .disabled(model.store.active == nil)
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
