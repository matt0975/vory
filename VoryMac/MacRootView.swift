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
    @State private var voiceSession = HandsFreeSession.shared
    @Environment(\.openWindow) private var openWindow
    /// DEBUG: `-vory-show-welcome` shows the first screen over a configured app.
    static let forceWelcome: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-vory-show-welcome")
        #else
        return false
        #endif
    }()

    var body: some View {
        ZStack {
            if model.hasConnections && !Self.forceWelcome {
                MainSplitView()
            } else {
                OnboardingView()
                    .frame(minWidth: 520, minHeight: 680)
                    // No name in the title bar and no strip behind it: the first screens run
                    // to the top of the window, with only the three window buttons over them.
                    .toolbar(removing: .title)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
            if model.lock.isLocked {
                MacLockView()
                    .toolbar(removing: .title)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
        }
        // The first time a gateway comes up on this Mac (its own first connection, or one the
        // keychain already held): what the Companion needs from here, if anything.
        .onChange(of: model.runtime?.connection.id, initial: true) { _, _ in offerCompanion() }
        // "Read replies aloud": a reply that finishes in the chat on screen is spoken.
        .task { VoiceCoordinator.shared.observeReplies() }
        // The window's open action, kept for the places with no view to ask (an App Intent run
        // while the window is closed).
        .task { MacWindow.openMain = { openWindow(id: MacWindow.main) } }
        // Voice mode's window opens when a session starts, wherever it was started from.
        .onChange(of: voiceSession.isActive) { _, on in if on { openWindow(id: MacWindow.voice) } }
        #if DEBUG
        .task { if AppModel.forceSignIn, let c = model.store.active { model.signInPrompt = [c] } }
        #endif
        // One sheet at a time, and none over the lock: the sign-in a restore owes comes first,
        // the Companion prompt once that is settled (its check needs a signed-in gateway).
        .onChange(of: model.signInPrompt.isEmpty) { _, _ in offerCompanion() }
        .onChange(of: model.needsSignIn == nil) { _, _ in offerCompanion() }
        .onChange(of: model.lock.isLocked) { _, _ in offerCompanion() }
        .sheet(isPresented: Binding(get: { !model.signInPrompt.isEmpty && !model.lock.isLocked && !showCompanionPrompt && !showInstaller },
                                    set: { if !$0 { model.signInPrompt = [] } })) {
            GatewaySignInSheet(connections: model.signInPrompt).withAppModel()
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
            .withAppModel()
        }
        .sheet(isPresented: $showInstaller) {
            NavigationStack {
                SetupWizardHost()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showInstaller = false } } }
            }
            .frame(minWidth: 560, minHeight: 680)
            .withAppModel()
        }
    }
}

extension MacRootView {
    /// Shows the Companion prompt, once, when a gateway is up and nothing stands in its way.
    private func offerCompanion() {
        // Never for the demo (#494): it used the prompt up, and the person's own gateway was never offered it.
        guard !companionPromptShown, let rt = model.runtime, !rt.isEphemeral, model.signInPrompt.isEmpty, model.needsSignIn == nil, !model.lock.isLocked else { return }
        companionPromptShown = true
        Task {
            // The gateway must have answered before it can be asked about the Companion: asked
            // too soon, the probe found nothing and offered an install to a gateway that had
            // one (a restored gateway, with the Companion set up from the phone, got that).
            for _ in 0..<40 where rt.profileHome == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard model.runtime === rt, rt.profileHome != nil else {
                // Not connected within ten seconds: not asked now, and asked again next time.
                companionPromptShown = false
                return
            }
            let probe = PushSetupModel()
            await probe.checkCompanion(runtime: rt)
            guard probe.companionCheckError == nil else { companionPromptShown = false; return }
            companionFound = probe.installedVersion
            showCompanionPrompt = true
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
    /// Settings › Home › "Open Vory on": the page the window starts on, as on the phone.
    @AppStorage("launchTab") private var launchTab = "chats"
    @State private var openedOnLaunchTab = false
    @State private var appearedAt = Date.distantPast
    /// The rail's other pages, kept mounted once visited (first visit order). See `body`.
    @State private var kept: [AppModel.AppTab] = []
    /// Decided 2026-10-13: a page left with a
    /// page pushed on it keeps it, as the phone's tabs do. Setting this key (`defaults write <bundle id>
    /// mac.pages.popOnLeave -bool YES`) goes back to 1.5 (18)'s way: a page left is re-created at its
    /// root a moment after the switch, out of sight.
    static let popOnLeaveKey = "mac.pages.popOnLeave"
    /// Bumped to re-create a page left behind when `popOnLeaveKey` is set.
    @State private var resets: [AppModel.AppTab: Int] = [:]
    /// How long after the window appears a page that the gateway has to vouch for (the Board)
    /// may still take the start: its plugin is probed once the gateway answers, a second or two in.
    private static let launchTabGrace: TimeInterval = 8

    /// The pages in the rail, less the ones the gateway cannot show (the Board without its plugin).
    private var tabs: [AppModel.AppTab] { TabLayout.parse(tabLayoutRaw).visible(hiding: model.hiddenTabs) }

    /// The window's own liveness (visible and in front), to combine with the page's.
    @Environment(\.botsLive) private var windowLive

    var body: some View {
        let chats = model.selectedTab == .chats
        ZStack {
            // The Chats page (rail, list, chat) stays mounted while another page shows, as the
            // iPhone keeps every tab page alive (RootView): tearing it down cost ~250 ms of the
            // switch away and building it again ~450 ms of the switch back (the aligned hitch
            // tables of 2026-10-11/12, clean-click drive). Hidden, it follows `MacPage`.
            NavigationSplitView(columnVisibility: $columns) {
                // Its rail's ⌘ numbers only while it shows: the other page's rail has them then
                // (declared twice, ⌘2 from Bots fired on both rails, and on Chats ⌘3 and ⌘4 then did
                // nothing until the next click on the rail).
                Sidebar(tabs: tabs, shortcuts: chats)
            } content: {
                ChatListView(detailPath: $chatPath)
                    // A renamed bot's open chat is stale (#315): back to the placeholder;
                    // the list has the chat again under the new name.
                    .onReceive(NotificationCenter.default.publisher(for: .hermesBotRenamed)) { _ in chatPath = NavigationPath() }
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 560)
            } detail: {
                // The chat beside the list (`ChatNavigation`): shared with the iPad and the
                // open Duo in 1.5; no back chevron, the list is the way between chats.
                ChatDetailStack(path: $chatPath) { NoChatView() }
            }
            .modifier(MacPage(shown: chats, windowLive: windowLive))
            // Every other page the same way (2026-10-12, follow-up 1): mounted on its first visit
            // and kept, so a switch is an opacity change, not a split view, a rail and a page
            // built afresh (69 % of the 300 ms leaving Chats). One split per page, keyed by its
            // tab; a page whose tab leaves the rail is dropped.
            ForEach(keptPages, id: \.self) { tab in
                NavigationSplitView(columnVisibility: $columns) {
                    Sidebar(tabs: tabs, shortcuts: model.selectedTab == tab)
                } detail: {
                    page(tab)
                }
                // The whole split: what is pushed lives in the split's detail column, not in the page.
                .id(resets[tab, default: 0])
                .modifier(MacPage(shown: model.selectedTab == tab, windowLive: windowLive))
            }
        }
        // Room for the rail, the list and a reading column with a table in it: narrower than this
        // the bubbles squeezed to a few words a line.
        .frame(minWidth: 860, minHeight: 520)
        // The chosen first page, once, when it is still in the rail and the gateway can show it
        // (the Board without its plugin opened blank on the phone). A page the gateway has to
        // vouch for is hidden until its probe answers, so the start waits a few seconds for it,
        // and only while nothing else has been chosen meanwhile.
        .onAppear { appearedAt = Date(); openOnLaunchTab(tabs) }
        // Signpost intervals for the hitch traces (Smooth, 1.5): a page switch and a chat open
        // on the Mac, so Instruments can score each one by name; free when nothing listens.
        .onChange(of: model.selectedTab, initial: true) { was, now in
            if now != .chats, !kept.contains(now) { kept.append(now) }
            guard was != now else { return }
            Smooth.animate("page")
            if was != .chats, UserDefaults.standard.bool(forKey: Self.popOnLeaveKey) {
                Task { @MainActor in resets[was, default: 0] += 1 }
            }
            // The keyboard focus leaves the page that hides: it stays mounted, and its composer,
            // list or field kept the focus (keys and pastes aimed at a page not on show). The
            // window holds it, as when the page was torn down.
            if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(MacWindow.main) == true }), w.firstResponder !== w,
               !w.makeFirstResponder(nil) {
                Perf.stamp("page: the focus stayed with \(String(describing: w.firstResponder))")
            }
        }
        .onChange(of: chatPath) { _, _ in Smooth.animate("chatOpen") }
        .onChange(of: tabs) { _, now in
            kept.removeAll { !now.contains($0) }
            openOnLaunchTab(now)
            // The page showing left the rail (the plugin went, or the layout changed): back to Chats.
            if !now.contains(model.selectedTab) { model.selectedTab = .chats }
        }
    }

    /// The pages mounted beside Chats: those visited and still in the rail, and the one being
    /// shown now (in the same pass, so a first visit never draws a frame with no page).
    private var keptPages: [AppModel.AppTab] {
        var pages = kept.filter { tabs.contains($0) }
        let now = model.selectedTab
        if now != .chats, !pages.contains(now) { pages.append(now) }
        return pages
    }

    private func openOnLaunchTab(_ now: [AppModel.AppTab]) {
        guard !openedOnLaunchTab, let tab = AppModel.AppTab(rawValue: launchTab), tab != .chats else { openedOnLaunchTab = true; return }
        guard Date().timeIntervalSince(appearedAt) < Self.launchTabGrace, model.selectedTab == .chats else { openedOnLaunchTab = true; return }
        guard now.contains(tab) else { return }
        openedOnLaunchTab = true
        model.selectedTab = tab
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
        case .kanban: NavigationStack { MacBoardView() }
        case .approvals: NavigationStack { ApprovalsView() }
        case .system: NavigationStack { SystemView() }
        // Settings pages are Forms; grouped is the Mac's System Settings look.
        case .settings: SettingsView().formStyle(.grouped)
        }
    }
}

/// A page of the window's ZStack, on show or kept behind the one that is: hidden, it is not
/// drawn, not hit-testable, not read by accessibility, and its faces hold still (`botsLive`),
/// the four rules the iPhone's RootView applies to its tabs. The Mac's window toolbar items are
/// declared by the pages, so a hidden page drops its own (they read `macPageShown`).
private struct MacPage: ViewModifier {
    var shown: Bool
    var windowLive: Bool
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
            .environment(\.botsLive, windowLive && shown)
            .environment(\.macPageShown, shown)
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
    /// Whether this rail declares the pages' ⌘ numbers (only the rail on show does).
    var shortcuts = true

    static let width: CGFloat = 84

    var body: some View {
        // Every page can sit here, as many as wanted; with all of them on in a short window
        // the rail scrolls.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(Array(tabs.enumerated()), id: \.element) { i, tab in
                    RailItem(tab: tab, selected: model.selectedTab == tab, badge: badge(tab), shortcut: i < 9 ? Character("\(i + 1)") : nil, shortcutOn: shortcuts) {
                        // The page already showing, chosen again (a click or its ⌘ number): back to
                        // its top, as a second tap on the phone's tab bar does.
                        if model.selectedTab == tab { model.tabReselected[tab, default: 0] += 1 } else { model.selectedTab = tab }
                    }
                }
                RailMore()
            }
            .padding(.top, 6).padding(.horizontal, 6).padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contextMenu { RailPages() }
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
    var shortcutOn = true
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let button = Button(action: action) {
            VStack(spacing: 3) {
                // The same icons as the iPhone's tab bar: the Vory outline for Bots, and each
                // symbol as it is drawn there (no filled variant for the chosen one).
                RailIcon(tab: tab)
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
        // One name for VoiceOver (the icon and the word read as one), with what waits there.
        .accessibilityLabel(badge > 0 ? "\(tab.title), \(badge) need\(badge == 1 ? "s" : "") you" : tab.title)
        .accessibilityHint(shortcut.map { "Shows \(tab.title). Command \($0)." } ?? "Shows \(tab.title).")
        .accessibilityIdentifier("rail.\(tab.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Optional rather than an if/else, so the button keeps its identity when the rail hides.
        button.keyboardShortcut(shortcutOn ? shortcut.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) } : nil)
    }
}

/// A page's icon as the iPhone's tab bar draws it.
private struct RailIcon: View {
    var tab: AppModel.AppTab
    var size: CGFloat = 19

    var body: some View {
        if tab == .bots {
            VoryOutlineIcon().frame(width: size * 1.5, height: size * 1.28)
        } else {
            Image(systemName: tab.symbol).font(.system(size: size, weight: .medium))
        }
    }
}

/// The pages as switches: on puts a page in the rail, off takes it out. Chats and Settings stay.
/// `rows`: laid out for the popover (icon, name, switch at the edge); otherwise menu items.
private struct RailPages: View {
    @Environment(AppModel.self) private var model
    @AppStorage(TabLayout.storageKey) private var tabLayoutRaw = ""
    var rows = false

    private var layout: TabLayout { TabLayout.parse(tabLayoutRaw) }

    private func shown(_ tab: AppModel.AppTab) -> Binding<Bool> {
        Binding(get: { layout.contains(tab) }, set: { on in
            var l = layout
            l.set(tab, enabled: on)
            tabLayoutRaw = l.encoded
            // The page being looked at left the rail: back to Chats.
            if !on, model.selectedTab == tab { model.selectedTab = .chats }
        })
    }

    var body: some View {
        // The ones in the rail first, in their order, then the rest.
        ForEach(layout.tabs + AppModel.AppTab.allCases.filter { !layout.contains($0) }, id: \.self) { tab in
            // A page the gateway cannot show (the Board without its plugin) stays listed,
            // greyed, with the one line that says what it needs.
            let unavailable = model.hiddenTabs.contains(tab)
            if rows {
                HStack(spacing: 10) {
                    RailIcon(tab: tab, size: 14).frame(width: 24).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.title).foregroundStyle(unavailable ? .secondary : .primary)
                        if unavailable, let plugin = tab.needsPlugin {
                            Text("Needs the \(plugin) plugin turned on on the gateway.").font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 12)
                    Toggle("Show \(tab.title) in the sidebar", isOn: shown(tab)).labelsHidden()
                        .toggleStyle(.switch).controlSize(.small)
                        .disabled(TabLayout.required.contains(tab) || unavailable)
                }
            } else {
                Toggle(isOn: shown(tab)) {
                    if unavailable, let plugin = tab.needsPlugin { Label("\(tab.title) (needs the \(plugin) plugin)", systemImage: tab.symbol) }
                    else { Label(tab.title, systemImage: tab.symbol) }
                }
                .disabled(TabLayout.required.contains(tab) || unavailable)
            }
        }
    }
}

/// The last thing in the rail: the way to put more pages in it, or take some out.
private struct RailMore: View {
    @State private var choosing = false
    @State private var hovering = false

    var body: some View {
        Button { choosing = true } label: {
            VStack(spacing: 3) {
                Image(systemName: "ellipsis.circle").font(.system(size: 19, weight: .medium)).frame(height: 24).accessibilityHidden(true)
                Text("More").font(.caption2).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .frame(width: Sidebar.width - 12, height: 54)
            .background { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering || choosing ? Color.primary.opacity(0.06) : .clear) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Choose the pages in the sidebar")
        .accessibilityLabel("More pages")
        .accessibilityHint("Chooses the pages in the sidebar.")
        .accessibilityIdentifier("rail.more")
        .popover(isPresented: $choosing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pages in the sidebar").font(.headline)
                VStack(alignment: .leading, spacing: 8) { RailPages(rows: true) }
                Text("Switch on as many as you like. Their order is in Settings › Appearance.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 240)
            .withAppModel()
        }
    }
}

/// The detail column before a chat is chosen.
private struct NoChatView: View {
    @Environment(\.macPageShown) private var shown
    var body: some View {
        VStack(spacing: 12) {
            // The guide plays only while something is working; idle, it holds still (#248).
            BotFaceView(spec: liveVory, size: 72, mood: BotFaceView.Mood(profile: "vory-mac-empty", state: BotAmbient.shared.decorativeActive ? .guide : .idle))
            Text("No chat selected").font(.title3.weight(.semibold))
            Text("Pick one from the list, or press ⌘N for a new one.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Something of this column's own in the toolbar, however small: with nothing here the
        // list's buttons slid from over the list to the far end of the window, and came back
        // when a chat was opened.
        .toolbar {
            if shown {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                    .sharedBackgroundVisibility(.hidden)
            }
        }
        // The placeholder must not bring a toolbar strip with it: in dark mode it showed as a
        // lighter band across the top of the empty column.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

/// The gateway under the sidebar: its name, the socket, and the way to its form.
private struct GatewayFooter: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false

    private var name: String { model.runtime?.connection.name ?? model.store.active?.name ?? "No gateway" }
    /// The socket, and with a backup address (#283) the address in use.
    private var state: String { model.runtime.map { [$0.addressLabel, $0.socketState.label].compactMap { $0 }.joined(separator: " · ") } ?? (model.activationError ?? "Connecting…") }
    private var dot: Color {
        guard let s = model.runtime?.socketState else { return .secondary }
        switch s {
        case .open: return .green
        case .connecting, .reconnecting, .idle: return .orange
        case .authRejected, .failed, .unreachable: return .red
        }
    }

    var body: some View {
        // In the demo (#392) there is no gateway form to open: the click goes to Settings, where Leave demo is.
        Button { if model.isInDemo { model.selectedTab = .settings } else { editing = true } } label: {
            VStack(spacing: 4) {
                BotFaceView(spec: liveVory, size: 30, active: model.runtime != nil && BotAmbient.shared.decorativeActive, mood: BotFaceView.Mood(profile: "vory-mac-footer"))
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(dot).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
                Text(name).font(.caption2.weight(.medium)).lineLimit(1).foregroundStyle(.secondary)
                if model.isInDemo { DemoTag() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(name) · \(state)\nClick to edit the gateway")
        .accessibilityLabel("Gateway \(name)\(model.isInDemo ? ", demo" : ""), \(state)")
        .accessibilityHint(model.isInDemo ? "Opens Settings, to leave the demo." : "Edits the gateway.")
        .accessibilityIdentifier("rail.gateway")
        .disabled(model.store.active == nil)
        .sheet(isPresented: $editing) { GatewayFormSheet(existing: model.store.active).withAppModel() }
    }
}

/// The gateway form as the Mac shows it everywhere: a sheet with its own Cancel and Save (the
/// sidebar's gateway, Settings › Gateways, Status › Sign-in, Push setup's "Sign in again"),
/// never pushed beside a toolbar Back.
struct GatewayFormSheet: View {
    var existing: GatewayConnection?
    var body: some View {
        NavigationStack { GatewayFormView(existing: existing) }
            .frame(minWidth: 520, minHeight: 640)
    }
}

/// The lock, over everything, until Touch ID or the password says yes.
private struct MacLockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 34, weight: .medium)).foregroundStyle(.secondary).accessibilityHidden(true)
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
