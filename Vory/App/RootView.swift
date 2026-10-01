import SwiftUI
import VoryCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    /// DEBUG: `-vory-show-tour` shows the first-run tour over a configured app.
    static let forceTour: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-vory-show-tour")
        #else
        return false
        #endif
    }()
    /// Shown once, right after the first gateway is saved: install the Companion now or later.
    @AppStorage("companionPromptShown") private var companionPromptShown = false
    @AppStorage("launchTab") private var launchTab = "chats"
    @AppStorage(TabLayout.storageKey) private var rootLayoutRaw = ""
    @AppStorage("notificationsSetupCardDone") private var setupCardDone = false
    @State private var showCompanionPrompt = false
    @State private var showInstaller = false

    var body: some View {
        ZStack {
            if !model.hasConnections || Self.forceTour {
                OnboardingView()
            } else {
                MainTabView()
            }
            if model.lock.isLocked {
                LockScreenView()
                    .transition(.opacity)
            }
        }
        .animation(.default, value: model.lock.isLocked)
        // The bar steps aside for the keyboard (a name field in Settings had it floating on top).
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in model.keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in model.keyboardUp = false }
        .onAppear {
            // Once per phone: the bar becomes Home, Chats, Bots, Settings. It can be changed after.
            if !UserDefaults.standard.bool(forKey: TabLayout.homeFirstAppliedKey) {
                rootLayoutRaw = TabLayout.default.encoded
                UserDefaults.standard.set(true, forKey: TabLayout.homeFirstAppliedKey)
            }
            // The chosen first screen (Settings › Home), when it is still on the bar.
            if let tab = AppModel.AppTab(rawValue: launchTab), TabLayout.parse(rootLayoutRaw).visible().contains(tab) { model.selectedTab = tab }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-vory-show-companion-prompt") { showCompanionPrompt = true }
            if ProcessInfo.processInfo.arguments.contains("-vory-show-setup") { showInstaller = true }
            #endif
        }
        .onChange(of: model.hasConnections) { had, has in
            if !had, has, !companionPromptShown {
                companionPromptShown = true
                Task { try? await Task.sleep(for: .milliseconds(700)); showCompanionPrompt = true }
            }
        }
        .sheet(isPresented: $showCompanionPrompt) {
            CompanionPromptSheet(install: {
                // Installed from here: the Settings suggestion never needs to show.
                setupCardDone = true
                showCompanionPrompt = false
                showInstaller = true
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
        }
    }
}

/// "You're connected — install the Companion now, or later?": Vory asks, once.
struct CompanionPromptSheet: View {
    var install: () -> Void
    var later: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            BotFaceView(spec: AboutView.voryBot, size: 96, active: true)
                .padding(.top, 26)
            Text("Unlock Vory's full potential").font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text("The Companion is a small plugin on your gateway. With it, replies arrive as notifications, a Live Activity follows every turn, and approval cards reach your phone the moment a bot needs a yes.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Button(action: install) { Text("Install now").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(.glassProminent)
                Button(action: later) { Text("Later").font(.subheadline) }
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
            Text("Later is fine — Settings will remind you.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28).padding(.bottom, 20)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct LockScreenView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Vory is locked").font(.title2.weight(.semibold))
                if let e = model.lock.lastError { Text(e).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                Button("Unlock with \(model.lock.biometryName)") { Task { await model.lock.unlock() } }
                    .buttonStyle(.glassProminent)
            }
            .padding()
        }
        .task { await model.lock.unlock() }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(TabLayout.storageKey) private var layoutRaw = ""

    var body: some View {
        let tabs = TabLayout.parse(layoutRaw).visible()
        ZStack {
            // Every page stays alive (its navigation stack, scroll position, drafts); only the
            // selected one is visible and touchable, which is what the system TabView does too.
            ForEach(tabs, id: \.self) { tab in
                content(for: tab)
                    .opacity(model.selectedTab == tab ? 1 : 0)
                    .allowsHitTesting(model.selectedTab == tab)
                    .accessibilityHidden(model.selectedTab != tab)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Reserves the bar's height so lists end above it; the bar itself is hidden (slid down)
            // inside a chat and the setup wizard, and the pages then use the full height. The bar
            // is never removed from the tree: an insert/remove transition got stuck on the first
            // chat opened after launch (the bar stayed, tappable, over the composer). It slides
            // and fades instead, and its reserved height collapses to nothing.
            VoryTabBar(tabs: tabs, compose: { compose() }, composeFull: { composeFull() })
                .offset(y: model.tabBarHidden ? 140 : 0)
                .opacity(model.tabBarHidden ? 0 : 1)
                // The slide and fade animate; the reserved height below does not. Animating the
                // safe-area inset while a chat opened made its thread bounce up and down.
                .animation(.snappy(duration: 0.3), value: model.tabBarHidden)
                .frame(height: model.tabBarHidden ? 0 : VoryTabBar.reservedHeight, alignment: .top)
                // Not tappable while it slides away: a tap then switched tabs under an open chat.
                .allowsHitTesting(!model.tabBarHidden)
                .accessibilityHidden(model.tabBarHidden)
        }
        // Lists on every page (roots and the pages pushed over them) do not pick up the bar's
        // inset on this iOS (their last rows ended under the bar), so their scroll content gets
        // the bar's height plus a breath of room. Inside a chat the bar is hidden and this is 0;
        // the thread measures its own margin against the composer.
        .contentMargins(.bottom, model.tabBarHidden ? 0 : VoryTabBar.reservedHeight + 16, for: .scrollContent)
        // No blank band under the bar at the top of any page: the first card sits right there.
        .contentMargins(.top, 0, for: .scrollContent)
        .onChange(of: tabs) { _, now in
            // The selected tab was removed from the layout: fall back to Chats instead of a blank pane.
            if !now.contains(model.selectedTab) { model.selectedTab = .chats }
        }
    }

    /// The compose circle: a chat with the bot whose page is in front, otherwise a new chat on Chats.
    private func compose() {
        if model.selectedTab != .bots || model.composeProfile == nil { model.selectedTab = .chats }
        model.newChatRequest = UUID()
    }
    private func composeFull() {
        model.selectedTab = .chats
        model.newChatSheetRequest = UUID()
    }

    @ViewBuilder private func content(for tab: AppModel.AppTab) -> some View {
        switch tab {
        case .chats: ChatListView()
        case .bots: BotsView()
        case .files: FilesView()
        case .settings: SettingsView()
        case .sessions: NavigationStack { SessionsView().navigationTitle("Sessions").tabRoot(.sessions) }
        case .cron: NavigationStack { CronView().navigationTitle("Scheduled Tasks").tabRoot(.cron) }
        case .approvals: NavigationStack { ApprovalsView().navigationTitle("Approvals").tabRoot(.approvals) }
        case .system: NavigationStack { SystemView().navigationTitle("System").tabRoot(.system) }
        case .dashboard: NavigationStack { DashboardView().tabRoot(.dashboard) }
        case .projects: NavigationStack { ProjectsView().tabRoot(.projects) }
        case .status: NavigationStack { StatusView().tabRoot(.status) }
        }
    }
}

/// Small glass status pill used in navigation bars.
struct ConnectionPill: View {
    var state: SocketState
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(state.label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .accessibilityLabel("Connection: \(state.label)")
    }
    private var color: Color {
        switch state {
        case .open: return .green
        case .connecting, .reconnecting: return .orange
        case .authRejected, .failed: return .red
        case .idle: return .gray
        }
    }
}
