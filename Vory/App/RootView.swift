import os
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
    /// DEBUG: `-vory-show-welcome` shows the first screen (Get Started / Restore from iCloud)
    /// over a configured app.
    static let forceWelcome: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-vory-show-welcome")
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
    /// The first gateway was just saved: the Companion prompt is owed once the gateway is
    /// signed in and nothing else is asking.
    @State private var companionDue = false
    @State private var showInstaller = false
    /// The Companion's version when the gateway already runs one: the prompt then only asks to allow notifications.
    @State private var companionFound: String?
    /// The chosen first screen while its page is still hidden: the Board is off the bar until
    /// the plugin's probe answers, so "Open Vory on: Board" opened on Chats. It waits for the
    /// answer, a few seconds at most, as the Mac's launch page does.
    @State private var launchTabPending: AppModel.AppTab?

    var body: some View {
        ZStack {
            if !model.hasConnections || Self.forceTour || Self.forceWelcome {
                OnboardingView(skipWelcome: Self.forceTour)
            } else {
                MainTabView()
            }
            if model.lock.isLocked {
                LockScreenView()
                    .transition(.opacity)
            }
        }
        .animation(.default, value: model.lock.isLocked)
        // The probe answered and the chosen page is on the bar now: open on it, unless the
        // person has already gone somewhere else.
        .onChange(of: model.hiddenTabs) { was, hidden in
            guard let tab = launchTabPending, was.contains(tab), !hidden.contains(tab) else { return }
            launchTabPending = nil
            if model.selectedTab == TabLayout.parse(rootLayoutRaw).visible(hiding: hidden).first || model.selectedTab == .chats { model.selectedTab = tab }
        }
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
            // A page the gateway cannot show (the Board without its plugin) is not opened on: it drew blank.
            if let tab = AppModel.AppTab(rawValue: launchTab), TabLayout.parse(rootLayoutRaw).visible().contains(tab) {
                if !model.hiddenTabs.contains(tab) {
                    model.selectedTab = tab
                } else {
                    launchTabPending = tab
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(8))
                        launchTabPending = nil
                    }
                }
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-vory-show-companion-prompt") { showCompanionPrompt = true }
            if ProcessInfo.processInfo.arguments.contains("-vory-show-setup") { showInstaller = true }
            if AppModel.forceSignIn, let c = model.store.active { model.signInPrompt = [c] }
            // The intents' work without Siri: `-vory-start-voice` does what "Start voice mode" does;
            // `-vory-ask <question>` runs "Ask Vory" and logs the answer (subsystem dev.vory).
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-vory-start-voice") { model.requestVoiceMode() }
            if let i = args.firstIndex(of: "-vory-ask"), i + 1 < args.count {
                let question = args[i + 1]
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    let answer = await SiriAsk.ask(question)
                    UtteranceListener.log.notice("Ask Vory → \(answer, privacy: .public)")
                }
            }
            #endif
        }
        .onChange(of: model.hasConnections) { had, has in
            if !had, has, !companionPromptShown { companionDue = true; offerCompanion() }
        }
        // One sheet at a time, and none over the lock: the sign-in a restore owes comes first,
        // the Companion prompt once that is settled (its check needs a signed-in gateway).
        .onChange(of: model.signInPrompt.isEmpty) { _, _ in offerCompanion() }
        .onChange(of: model.needsSignIn == nil) { _, _ in offerCompanion() }
        .onChange(of: model.lock.isLocked) { _, _ in offerCompanion() }
        .sheet(isPresented: Binding(get: { !model.signInPrompt.isEmpty && !model.lock.isLocked && !showCompanionPrompt && !showInstaller },
                                    set: { if !$0 { model.signInPrompt = [] } })) {
            GatewaySignInSheet(connections: model.signInPrompt)
        }
        .sheet(isPresented: $showCompanionPrompt) {
            CompanionPromptSheet(found: companionFound, install: {
                // Installed from here: the Settings suggestion never needs to show.
                setupCardDone = true
                showCompanionPrompt = false
                showInstaller = true
            }, allow: {
                // Allowed: the token arrives, the device file goes up, the Companion sends here.
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
        }
    }
}

extension RootView {
    /// Shows the Companion prompt when it is owed and nothing stands in its way.
    private func offerCompanion() {
        guard companionDue, !companionPromptShown, model.hasConnections, model.signInPrompt.isEmpty, model.needsSignIn == nil, !model.lock.isLocked else { return }
        companionDue = false
        companionPromptShown = true
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            // A gateway set up from another device already has the Companion: no install to offer.
            if let rt = model.runtime { companionFound = await CompanionPromptSheet.installedVersion(on: rt) }
            showCompanionPrompt = true
        }
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
        let tabs = TabLayout.parse(layoutRaw).visible(hiding: model.hiddenTabs)
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
            VoryTabBar(tabs: tabs, compose: { compose() }, composeFull: { composeFull() }, voice: { voiceChat($0) })
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
        // "Read replies aloud" listens for finished replies in the chat in front.
        .task { VoiceCoordinator.shared.observeReplies() }
        .onChange(of: tabs) { _, now in
            // The selected tab was removed from the layout: fall back to Chats instead of a blank pane.
            if !now.contains(model.selectedTab) { model.selectedTab = .chats }
        }
    }

    /// The compose circle: a chat with the bot whose page is in front, otherwise a new chat on Chats.
    private func compose() {
        if model.selectedTab != .bots || model.composeProfile == nil { leaveForChats() }
        model.newChatRequest = UUID()
    }
    private func composeFull() {
        leaveForChats()
        model.newChatSheetRequest = UUID()
    }
    /// The mic circle: a fresh chat with the bot named under it, else the bot whose page is in
    /// front, else the selected one, straight into voice mode (#237).
    private func voiceChat(_ profile: String?) {
        let front = model.selectedTab == .bots ? model.composeProfile : nil
        leaveForChats()
        model.voiceChatRequest = AppModel.VoiceChatRequest(profile: profile ?? front)
    }
    /// Over to Chats for the new chat, remembering where the tap came from: a tester composed
    /// from Settings, closed the chat without sending, and found himself on Chats.
    private func leaveForChats() {
        model.composeReturnTab = model.selectedTab == .chats ? nil : model.selectedTab
        model.selectedTab = .chats
    }

    @ViewBuilder private func content(for tab: AppModel.AppTab) -> some View {
        switch tab {
        case .chats: ChatListView()
        case .bots: BotsView()
        case .files: FilesView()
        case .settings: SettingsView()
        case .sessions: NavigationStack { SessionsView().navigationTitle("Sessions").tabRoot(.sessions) }
        case .cron: NavigationStack { CronView().navigationTitle("Scheduled Tasks").tabRoot(.cron) }
        case .kanban: NavigationStack { KanbanView().tabRoot(.kanban) }
        case .approvals: NavigationStack { ApprovalsView().navigationTitle("Approvals").tabRoot(.approvals) }
        case .system: NavigationStack { SystemView().navigationTitle("System").tabRoot(.system) }
        case .dashboard: NavigationStack { DashboardView().tabRoot(.dashboard) }
        case .projects: NavigationStack { ProjectsView().tabRoot(.projects) }
        case .status: NavigationStack { StatusView().tabRoot(.status) }
        }
    }
}
