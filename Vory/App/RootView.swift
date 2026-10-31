import os
import SwiftUI
import VoryCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    /// Two columns and the wide chat layout: see `wideLayout` below. Held while the scene is in the background (`shownWide`).
    private var wide: Bool { WindowGeometry.held(live: liveWide, holding: scenePhase == .background, last: shownWide) }
    private var liveWide: Bool { Self.isWide(regular: sizeClass == .regular, size: windowGeometry.bounds.size) }
    nonisolated static func isWide(regular: Bool, size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return regular }   // not measured yet
        return regular && (size.width > size.height || size.width >= 700)
    }
    /// `wide` as last read outside the background. There the system lays the scene out again for its snapshot, at
    /// another size class and shape (on the open Duo on its side: compact, then 466 × 678); read live, that took the
    /// Chats page to one column and back on every trip and left its header shifted (#537). The window's geometry and
    /// reserved regions hold the same way, and all of it is read again as the scene leaves the background. A scene
    /// that is only inactive (the switcher, an unfocused window still on screen) is never held.
    @State private var shownWide: Bool?
    /// The window's geometry for this scene, read from the window on every layout (see
    /// `WindowGeometry`); every view that lays out against the window reads it from the environment.
    @State private var windowGeometry = WindowGeometry()
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
        #if os(iOS)
        // The welcome tour again, over the app as it is (#487, Settings › Troubleshooting, test builds only).
        .fullScreenCover(isPresented: Binding(get: { model.replayingTour }, set: { model.replayingTour = $0 })) {
            TourReplayView().withAppModel()
        }
        #endif
        .background { WindowGeometryReader(geometry: windowGeometry).ignoresSafeArea() }
        .background { TouchSignpostProbe().frame(width: 0, height: 0) }
        // The fold and the camera, for every floating piece below (Step D).
        // Whether the status stands in a top corner, for the top bar's room on every tab (#516), read here once.
        .modifier(StatusCornerEnvironment())
        .modifier(ReservedRegionsEnvironment())
        #if DEBUG && os(iOS)
        // `-vory-ax-oracle`: what VoiceOver would stop on, for UI tests (`VoiceOverOracle`, #409).
        .overlay(alignment: .topLeading) {
            if VoiceOverOracle.isOn { VoiceOverOracle.Probe().frame(width: 1, height: 1).allowsHitTesting(false) }
            // `-vory-card-probe`: where a toggled card's top was at each frame, for the card checks (#437).
            if CardMotionProbe.isOn { CardMotionProbe.Readout().frame(width: 1, height: 1).allowsHitTesting(false) }
            // `-vory-app-fingerprint`: what a tour replay must leave as it was, for its no-trace test (#487).
            if AppFingerprint.isOn { AppFingerprint.Readout().frame(width: 1, height: 1).allowsHitTesting(false) }
            // `-vory-coldopen-probe`: how the thread moved as the last chat opened, for the open checks (#449).
            if ColdOpenProbe.isOn { ColdOpenProbe.Readout().frame(width: 1, height: 1).allowsHitTesting(false) }
            if DemoDeliveredReadout.isOn { DemoDeliveredReadout().frame(width: 1, height: 1).allowsHitTesting(false) }
            // `-vory-morph-frames`: the top bar's capsules as drawn, for the headings and search fields checks (#516).
            if MorphFramesProbe.isOn { MorphFramesProbe.Readout().frame(width: 1, height: 1).allowsHitTesting(false) }
            if MorphFramesProbe.isOn && MorphFramesProbe.logs { MorphFramesProbe.LogReadout().frame(width: 1, height: 1).allowsHitTesting(false) }
        }
        #endif
        #if DEBUG
        // `-vory-geometry-probe`: the window's numbers in the corner, for reading a pose off a
        // screenshot (the Duo simulator has no other way to report its insets).
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("-vory-geometry-probe") {
                VerticalBarEdge { edge in
                    let g = windowGeometry
                    Text(String(format: "%.0fx%.0f  safe t%.0f l%.0f b%.0f r%.0f  bar %@  wide %@  hidden %@ kb %@ open %@ hiders %d mw %@ v %@ row %.0f room %.0f", g.bounds.width, g.bounds.height, g.safeArea.top, g.safeArea.leading, g.safeArea.bottom, g.safeArea.trailing, edge.map { $0 == .leading ? "leading" : "trailing" } ?? "bottom", wide ? "yes" : "no", model.tabBarHidden ? "yes" : "no", model.keyboardUp ? "yes" : "no", model.chatsPathOpen ? "yes" : "no", model.tabBarHiders[model.selectedTab] ?? 0, model.wideLayout ? "yes" : "no", model.tabBarVertical ? "yes" : "no", MorphState.shared.rootRowBottom, TopBarRoom.lastRoom))
                        .font(.caption2.monospaced()).padding(4).background(.yellow.opacity(0.9)).foregroundStyle(.black)
                        .accessibilityIdentifier("geometry.window")
                        // Below the morph bar's chat row (its capsules sit 30 pt lower since
                        // 2026-10-12): at 40 the probe sat over Back and a UI test's tap missed.
                        .padding(.top, 150).allowsHitTesting(false)
                        .overlay(alignment: .bottomLeading) {
                            Text("root \(model.tabAtRoot[model.selectedTab].map { $0 ? "yes" : "no" } ?? "nil")  probe \(RootArrivalProbe.last)")
                                .font(.caption2.monospaced()).padding(4).background(.orange.opacity(0.9)).foregroundStyle(.black)
                                .offset(y: 22).allowsHitTesting(false)
                        }
                }
            }
        }
        // `-vory-geometry-probe`, the Duo's fold (stage 2): every reserved region the window reports, active or not, in
        // window space, and the margins the system gives each, read straight from the geometry; and the keyboard's overlap.
        .overlay {
            if ProcessInfo.processInfo.arguments.contains("-vory-geometry-probe") {
                #if os(iOS)
                if #available(iOS 27.1, *) { RegionsProbe(keyboard: windowGeometry.keyboardOverlap).ignoresSafeArea().allowsHitTesting(false) }
                #endif
            }
        }
        #if os(iOS)
        // `-vory-hinge-probe`: every hinge change the window reports (Duo stage 4, the blink as it opens).
        .modifier(HingeProbe.IfOn())
        #endif
        #endif
        #if os(iOS)
        // The faces blink once as a foldable phone opens (Duo stage 4).
        .modifier(HingeOpenBlink())
        #endif
        .environment(\.windowGeometry, windowGeometry)
        // Wide on a regular-width window that is wider than tall or at least 700 pt wide (any
        // iPad, the open Duo in landscape); the phone layout otherwise, which includes the open
        // Duo upright (669 pt: Matt chose one column there, 2026-10-10) and a narrow Stage
        // Manager or Split View window. The window's shape decides, never the device or a pose.
        .environment(\.wideLayout, wide)
        .onChange(of: liveWide, initial: true) { _, w in if scenePhase != .background { shownWide = w } }
        .onChange(of: scenePhase) { _, phase in if phase != .background { shownWide = liveWide } }
        .onChange(of: wide, initial: true) { _, w in model.wideLayout = w }
        // Belt and braces: the same value again once the layout has settled after a change of
        // shape (the Duo's turn from one column to two).
        .task(id: wide) { model.wideLayout = wide }
        // The probe answered and the chosen page is on the bar now: open on it, unless the
        // person has already gone somewhere else.
        .onChange(of: model.hiddenTabs) { was, hidden in
            guard let tab = launchTabPending, was.contains(tab), !hidden.contains(tab) else { return }
            launchTabPending = nil
            if model.selectedTab == TabLayout.parse(rootLayoutRaw).visible(hiding: hidden).first || model.selectedTab == .chats { model.selectedTab = tab }
        }
        // The bar steps aside for the keyboard (a name field in Settings had it floating on top).
        // A keyboard is up when its frame overlaps the window now (`WindowGeometry`), not when a
        // will-show was seen: a turn of the open Duo took the keyboard away without a will-hide
        // and the bar stayed hidden behind it; the iPad's hardware-keyboard bar counts the same way.
        .onChange(of: windowGeometry.keyboardOverlap > 0, initial: true) { _, up in model.keyboardUp = up }
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
        .onChange(of: model.hasOwnGateway) { had, has in
            if !had, has, !companionPromptShown { companionDue = true; offerCompanion() }
        }
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
            .withAppModel()
        }
        .sheet(isPresented: $showInstaller) {
            NavigationStack {
                SetupWizardHost()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showInstaller = false } } }
            }
            .withAppModel()
        }
    }
}

extension RootView {
    /// Shows the Companion prompt when it is owed and nothing stands in its way.
    private func offerCompanion() {
        guard companionDue, !companionPromptShown, model.hasOwnGateway, model.signInPrompt.isEmpty, model.needsSignIn == nil, !model.lock.isLocked else { return }
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
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary).accessibilityHidden(true)
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
    @Environment(\.windowGeometry) private var windowGeometry
    @AppStorage(TabLayout.storageKey) private var layoutRaw = ""

    var body: some View {
        let tabs = TabLayout.parse(layoutRaw).visible(hiding: model.hiddenTabs)
        let barHeight = VoryTabBar.reservedHeight(in: windowGeometry)
        let hiddenFraction: CGFloat = model.tabBarHidden ? max(0, 1 - model.popProgress) : 0
        // Where the system would put a vertical bar (the closed Duo's strip, the open Duo in
        // landscape), Vory's own bar goes there too, stacked on that edge (decision 1): the
        // pages are inset by its width instead of its height. Nil: along the bottom, as ever.
        VerticalBarEdge { edge in
            let vertical = edge != nil
            let pages = ZStack {
                // Every page stays alive (its navigation stack, scroll position, drafts); only the
                // selected one is visible and touchable, which is what the system TabView does too.
                ForEach(tabs, id: \.self) { tab in
                    content(for: tab)
                        .opacity(model.selectedTab == tab ? 1 : 0)
                        // The morph prototype's "cut" variant: the page swap is not animated. Only
                        // the swap: unscoped, this took the animation out of every change inside
                        // every page, and a page's own moves (a pinned chat going up, #372) jumped.
                        .transaction(value: model.selectedTab) { if MorphTopBar.cutsPages { $0.animation = nil } }
                        .allowsHitTesting(model.selectedTab == tab)
                        .accessibilityHidden(model.selectedTab != tab)
                        // A hidden page's faces hold still: at opacity 0 they kept their
                        // timelines running (the Bots grid's fourteen behind the Chats list).
                        .environment(\.botsLive, model.selectedTab == tab)
                }
            }
            // The morph prototype's top controls, over every page and outside the stacks.
            .overlay(alignment: .top) { if MorphTopBar.active(model) { MorphBarHost() } }
            // Reserves the bar's height (or width) so lists end before it; the bar itself is
            // hidden (slid off its edge) inside a chat and the setup wizard, and the pages then
            // use the full height. The bar is never removed from the tree: an insert/remove
            // transition got stuck on the first chat opened after launch (the bar stayed,
            // tappable, over the composer). It slides and fades instead, and its reserved
            // size collapses to nothing.
            let bar = VoryTabBar(tabs: tabs, axis: vertical ? .vertical : .horizontal, compose: { compose() }, composeFull: { composeFull() }, voice: { voiceChat($0) })
                // Hidden for an open chat, the bar comes back by the back swipe's progress (the
                // finger scrubs it, a cancelled swipe sends it out again); the button Back and
                // the push keep the snappy slide below.
                .offset(x: vertical ? (edge == .leading ? -140 : 140) * hiddenFraction : 0,
                        y: !vertical ? 140 * hiddenFraction : 0)
                .opacity(1 - hiddenFraction)
                // The slide and fade animate; the reserved size below does not. Animating the
                // safe-area inset while a chat opened made its thread bounce up and down. The
                // size comes back only after a popped chat has gone (`tabBarReserved`): with the
                // path alone it snapped back half a second early and re-laid out the chat while
                // it slid away.
                .animation(.snappy(duration: 0.3), value: model.tabBarHidden)
                // Anchored to the window's edge: with no room reserved the bar stands over
                // the page (as the system's does over a chat sliding away), not below the screen.
                .frame(width: vertical ? (model.tabBarReserved ? VoryTabBar.reservedWidth : 0) : nil,
                       height: vertical ? nil : (model.tabBarReserved ? barHeight : 0),
                       alignment: vertical ? .top : .bottom)
                // Not tappable while it slides away: a tap then switched tabs under an open chat.
                .allowsHitTesting(!model.tabBarHidden)
                .accessibilityHidden(model.tabBarHidden)
            // One structure wherever the bar stands (#533): along the bottom, beside a narrow strip, or in the strip,
            // each a slot that holds the bar or nothing, so only the bar moves. The pages stood in one of three branches
            // by the bar's place, each another identity: every move of the bar (a turn of the open Duo, closing or
            // opening it) rebuilt every tab's navigation stack at its root, and a pushed page went back to the root.
            let side = edge ?? .trailing
            // Into the system's strip itself (the window's inset on that side, where the status bar and the navigation
            // bars' items already stand), at the strip's foot under those items, so the pages keep the width the strip
            // leaves them. A strip too narrow for the capsule gets the bar beside it instead.
            let strip = side == .leading ? windowGeometry.safeArea.leading : windowGeometry.safeArea.trailing
            let inStrip = vertical && strip >= VoryTabBar.stripItemWidth
            // One column with the system's items: their width, their centre line (measured on the closed Duo: 50 pt
            // wide, centred 48 pt from the edge). The stack sits at the strip's foot, under the page's navigation items,
            // on the closed display and the open one alike (#516). On the open display it stood at the top under a
            // fixed allowance for the status items, and a taller status column (an extra pill in it on a real Duo)
            // covered its first tabs; at the foot nothing in the status column reaches it.
            let outer = VoryTabBar.stripCentreFromEdge - VoryTabBar.stripItemWidth / 2
            pages
                .safeAreaInset(edge: .bottom, spacing: 0) { if !vertical { bar } }
                .safeAreaInset(edge: side, spacing: 0) { if vertical && !inStrip { bar } }
                .overlay(alignment: side == .leading ? .bottomLeading : .bottomTrailing) {
                    if inStrip {
                        bar
                            .frame(width: VoryTabBar.stripItemWidth)
                            .padding(side == .leading ? .leading : .trailing, outer)
                            // The overlay already ends above the home-indicator area; the stack
                            // keeps one group gap over it, no more. Padding it by the inset again
                            // pushed the stack up until its first tab touched the page's own
                            // strip items (the list's filter met Home, Matt).
                            .padding(.bottom, VoryTabBar.stripGroupGap)
                            .ignoresSafeArea(.container, edges: side == .leading ? .leading : .trailing)
                    }
                }
                .onChange(of: vertical, initial: true) { _, v in model.tabBarVertical = v }
        }
        // Lists on every page (roots and the pages pushed over them) do not pick up the bar's
        // inset on this iOS (their last rows ended under the bar), so their scroll content gets
        // the bar's height plus a breath of room. Inside a chat the bar is hidden and this is 0;
        // the thread measures its own margin against the composer.
        .contentMargins(.bottom, model.tabBarReserved && !model.tabBarVertical ? barHeight + 16 : 0, for: .scrollContent)
        // No blank band under the bar at the top of any page: the first card sits right there.
        .contentMargins(.top, 0, for: .scrollContent)
        // "Read replies aloud" listens for finished replies in the chat in front.
        .task { VoiceCoordinator.shared.observeReplies() }
        // The back swipe's progress reaches the bar through FullScreenPop; the finish animates
        // over what is left of the transition, the scrub itself does not animate.
        .onAppear {
            FullScreenPop.onProgress = { fraction, ended, duration in
                if ended {
                    Perf.stamp("pop: progress ended fraction=\(fraction) over \(duration)")
                    withAnimation(.easeOut(duration: duration)) { model.popProgress = fraction }
                    // The morph prototype's controls finish with the bar, over the same remainder.
                    if MorphTopBar.on { MorphState.shared.release(fraction, over: duration) }
                    // After the transition the path has changed and the bar is shown by its own
                    // state again; the progress goes back to zero for the next chat, unanimated.
                    DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { model.popProgress = 0 } }
                } else {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { model.popProgress = fraction }
                    // The morph prototype's controls follow the finger (Matt, 2026-10-12).
                    if MorphTopBar.on { MorphState.shared.scrub(fraction) }
                }
            }
        }
        .onChange(of: model.tabBarHidden) { _, h in Perf.stamp("pop: tabBarHidden=\(h)") }
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
        // The list beside the open chat on a wide window; the list with the chat pushed over it
        // on a narrow one. One view for both, so a fold or a resize keeps the open chat.
        case .chats: ChatsSplitPage()
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


#if os(iOS)
/// The hinge's last reading (iOS 27.1, a foldable phone), kept from launch for Settings › Troubleshooting › Screen layout
/// (#516); nil before one has come, and always on a phone that doesn't fold.
@MainActor @Observable final class DevicePosture {
    static let shared = DevicePosture()
    struct Reading: Equatable { var status: String; var degrees: Double }
    var last: Reading?
}

/// The faces blink once as a foldable phone opens (Duo stage 4): the root watches the hinge and the window and stamps
/// `BotAmbient.opened` when `HingeOpenRule` says (the later of 0.3 s after the hinge leaves closed and the open
/// display's window; none if that window doesn't come within 2 s). Nothing on a phone that doesn't fold, where no hinge
/// reading comes, or before iOS 27.1.
struct HingeOpenBlink: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) { content.modifier(Watch()) } else { content }
    }

    @available(iOS 27.1, *)
    private struct Watch: ViewModifier {
        @Environment(\.windowGeometry) private var windowGeometry
        @State private var rule = HingeOpenRule()
        /// Bumped whenever the waiting opening changes: an earlier wait that wakes to a newer one does nothing.
        @State private var generation = 0

        private static var now: Double { Date().timeIntervalSinceReferenceDate }

        private static func status(_ s: DeviceHinge.Status) -> HingeOpenRule.Status {
            s == .closed ? .closed : s == .fullyOpen ? .open : .partly
        }

        func body(content: Content) -> some View {
            content
                .onHingeChange { old, new in
                    guard let n = new.hinge else { return }
                    DevicePosture.shared.last = .init(status: n.status == .closed ? "Closed" : n.status == .fullyOpen ? "Open" : n.status == .partiallyOpen ? "Partly open" : "Other",
                                                      degrees: n.angle.degrees)
                    let before = (rule.leftClosedAt, rule.windowAt)
                    rule.hinge(from: old.hinge.map { Self.status($0.status) }, to: Self.status(n.status), at: Self.now)
                    if before != (rule.leftClosedAt, rule.windowAt) { schedule() }
                }
                .onChange(of: windowGeometry.bounds.size, initial: true) { _, size in
                    let before = (rule.leftClosedAt, rule.windowAt)
                    rule.window(size, at: Self.now)
                    if before != (rule.leftClosedAt, rule.windowAt) { schedule() }
                    #if DEBUG
                    BotAmbient.blinkLog(String(format: "BLINKWIN %.0fx%.0f", size.width, size.height))
                    #endif
                }
                #if DEBUG
                // For the hinge legs: a second appearance means the root was made again (its rule with it), not resized.
                .onAppear { BotAmbient.blinkLog("BLINKWATCH appear") }
                #endif
        }

        /// Waits for the opening's blink and stamps it, or gives the opening up when no open window came in time.
        private func schedule() {
            generation += 1
            let g = generation
            if let at = rule.blinkAt {
                Task { @MainActor in
                    let wait = at - Self.now
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    guard g == generation, rule.blinkAt != nil else { return }
                    #if DEBUG
                    BotAmbient.blinkLog(String(format: "BLINKSTAMP left %.3f window %.3f due %.3f", rule.leftClosedAt ?? 0, rule.windowAt ?? 0, at))
                    #endif
                    rule.done()
                    BotAmbient.shared.opened = Date()
                }
            } else if let left = rule.leftClosedAt {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(max(0, left + HingeOpenRule.windowWait - Self.now) + 0.05))
                    guard g == generation, rule.gaveUp(at: Self.now) else { return }
                    #if DEBUG
                    BotAmbient.blinkLog(String(format: "BLINKGIVEUP left %.3f", left))
                    #endif
                    rule.done()
                }
            }
        }
    }
}
#endif

#if DEBUG && os(iOS)
/// DEBUG, `-vory-geometry-probe`: the window's reserved regions as the system reports them (stage 2 of the Duo work):
/// division (the fold) and occlusion (a camera), each with its frame in window space, its margins and whether it is
/// active, included inactive ones; printed in a band the fold doesn't cover.
@available(iOS 27.1, *)
private struct RegionsProbe: View {
    var keyboard: CGFloat
    var body: some View {
        GeometryReader { proxy in
            let line: (ReservedRegion) -> String = { r in
                let f = r.frame, m = r.margins
                return String(format: "%@ %@ x%.0f y%.0f w%.0f h%.0f m%.0f/%.0f/%.0f/%.0f", r.kind == .division ? "fold" : "occl",
                              r.isActive ? "ON" : "off", f.minX, f.minY, f.width, f.height, m.top, m.leading, m.bottom, m.trailing)
            }
            let all = proxy.reservedRegions(kind: .division, options: .includeInactive) + proxy.reservedRegions(kind: .occlusion, options: .includeInactive)
            Text((all.isEmpty ? ["no regions"] : all.map(line)).joined(separator: "\n") + String(format: "\nwin %.0fx%.0f kb %.0f", proxy.size.width, proxy.size.height, keyboard))
                .font(.caption2.monospaced()).padding(4).background(.mint.opacity(0.9)).foregroundStyle(.black)
                // The fold's frame for the pose tests (FoldPoseUITests), read off this text.
                .accessibilityIdentifier("geometry.regions")
                .position(x: min(proxy.size.width - 130, 160), y: 250)
        }
    }
}

/// DEBUG, `-vory-hinge-probe`: every hinge change the window reports, oldest first (the time, the old and the new
/// status, the new angle), in a band at the foot of the window and in the log as `HINGE` lines; the UI tests read
/// `hinge.probe`'s value. It tells whether the simulator sends them for Device Hub's posture buttons (Duo stage 4,
/// the blink as the phone opens).
private enum HingeProbe {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-vory-hinge-probe")

    struct IfOn: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 27.1, *), HingeProbe.isOn { content.modifier(Readout()) } else { content }
        }
    }

    @available(iOS 27.1, *)
    struct Readout: ViewModifier {
        @State private var lines: [String] = []

        func body(content: Content) -> some View {
            content
                .onHingeChange { old, new in
                    let angle = new.hinge.map { String(format: "%.0f", $0.angle.degrees) } ?? "-"
                    let line = "\(Date().formatted(.dateTime.hour().minute().second().secondFraction(.fractional(2)))) \(Self.name(old)) > \(Self.name(new)) \(angle)"
                    // Written straight to standard output, unbuffered: to a file (simctl launch --stdout) print's output is
                    // block-buffered, so the lines could come late, or be lost when the app is stopped.
                    FileHandle.standardOutput.write(Data("HINGE \(line)\n".utf8))
                    lines.append(line)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(lines.isEmpty ? "hinge: none yet" : lines.suffix(8).joined(separator: "\n"))
                        .font(.caption2.monospaced()).padding(4).background(.mint.opacity(0.9)).foregroundStyle(.black)
                        .accessibilityIdentifier("hinge.probe")
                        .accessibilityValue(lines.joined(separator: " | "))
                        .padding(.bottom, 140).allowsHitTesting(false)
                }
        }

        private static func name(_ c: DeviceHingeContext) -> String {
            guard let h = c.hinge else { return "nil" }
            if h.status == .closed { return "closed" }
            if h.status == .partiallyOpen { return "partly" }
            if h.status == .fullyOpen { return "open" }
            return "other"
        }
    }
}
#endif

/// Publishes the window's reserved regions (the fold, the camera) into the environment.
private struct ReservedRegionsEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        ReservedRegionsReader { content }
    }
}
