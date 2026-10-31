import SwiftUI
import VoryCore

/// Our own tab bar, drawn to the system Liquid Glass tab bar on iOS 27: a glass capsule of
/// equal-width, icon-only tabs, a clear glass lens over the selected one (its label shows under
/// the icon only there), and a detached glass compose circle the full height of the capsule.
/// The system TabView cannot draw this on the current iOS (a search-role tab renders inline),
/// so the tab pages sit in a ZStack behind it instead.
///
/// Measurements from a UITabBar dump on iOS 27 / iPhone 17 Pro: capsule 62 pt with 4 pt inset
/// around 54 pt slots, 21 pt side margins, the bar group 49 pt above the home-indicator area with
/// the capsule overflowing 13 pt into it. Ours is 6 pt shorter at the user's request, same overhang.
struct VoryTabBar: View {
    @Environment(AppModel.self) private var model
    var tabs: [AppModel.AppTab]
    /// Horizontal along the bottom (every phone, the open Duo held upright), or a vertical
    /// strip on a side edge where the system lays its own bars that way (the closed iPhone
    /// Duo, the open Duo in landscape): the same capsule and circles, stacked.
    var axis: Axis = .horizontal
    var compose: () -> Void
    /// The full New Message sheet (bots, project, files).
    var composeFull: () -> Void = {}
    /// A fresh chat straight into voice mode, with the bot named (nil: the current one).
    var voice: (String?) -> Void = { _ in }
    /// What a tap and a press and hold do (Settings › Appearance › New Chat button).
    @AppStorage(ComposeAction.tapKey) private var tapRaw = ComposeAction.tapDefault.rawValue
    @AppStorage(ComposeAction.holdKey) private var holdRaw = ComposeAction.holdDefault.rawValue
    /// Settings › Appearance › Voice button: the mic circle beside the bar, or not (the capsule
    /// takes the room). Applies as it is switched, no relaunch.
    @AppStorage(Self.showVoiceKey) private var showVoice = true
    static let showVoiceKey = "tabBar.showVoice"
    /// Settings › Appearance › Tab labels: the word under the selected tab's icon, or icons only.
    @AppStorage(Self.showLabelsKey) private var showLabels = true
    static let showLabelsKey = "tabBar.showLabels"

    private func run(_ action: ComposeAction) {
        switch action {
        case .quick: compose()
        case .sheet: composeFull()
        case .none: break
        }
    }

    /// Where the finger is along the capsule while it drags the lens; nil when not dragging.
    @State private var dragX: CGFloat?
    @State private var pressStart: Date?
    /// The tab the lens is over while it is dragged: tinted, not yet shown. The page switches
    /// when the lens is dropped (Matt, 2026-10-11: switching as it passed made the drag lag,
    /// each pass cross-faded two whole pages under a live glass lens).
    @State private var hoverTab: AppModel.AppTab?
    /// True while a finger is on the capsule; back to false on a lift and on a cancel alike,
    /// which is how a cancelled drag is told apart (`onEnded` never runs for one, #375).
    @GestureState private var touching = false
    #if DEBUG
    /// UI tests of #375 (`TabBarDragTesting`): the drag's gesture is taken away for a moment.
    @State private var testCancel = false
    #endif

    /// The system capsule is 62 pt; the user wanted it a little shorter, bottom edge kept.
    private let barHeight: CGFloat = 56
    private let inset: CGFloat = 4
    private let sideMargin: CGFloat = 21
    /// Between the capsule and the circles, and between the circles: half what it was (the
    /// bar had a gap on each side of the mic that read as empty space).
    private let circleGap: CGFloat = 6
    /// How far past the drawn capsule and circles a touch still lands on the bar, not behind it.
    static let touchMargin: CGFloat = 4
    /// The window's bottom safe-area inset, read from the window as it is now (`WindowGeometry`):
    /// 34 pt on phones with a home indicator, 0 on a home-button phone (iPhone SE), which iOS 26
    /// still runs on, and whatever the window has after a fold or a resize.
    @Environment(\.windowGeometry) private var windowGeometry
    /// How far the capsule hangs into the home-indicator area: the full 13 pt when there is one.
    /// Without one the capsule would hang off the screen, so it hangs by what is there (nothing on
    /// an SE) and keeps the rest as a gap above the screen edge instead.
    nonisolated static func overhang(safeBottom: CGFloat) -> CGFloat { min(13, safeBottom) }
    /// What the bar reserves above the home-indicator area (the system bar group's 49 pt); the
    /// capsule is drawn overflowing below it.
    nonisolated static func reservedHeight(safeBottom: CGFloat) -> CGFloat { 56 - overhang(safeBottom: safeBottom) + max(0, 13 - safeBottom) }
    /// The same, for this window as it is now.
    static func reservedHeight(in geometry: WindowGeometry) -> CGFloat { reservedHeight(safeBottom: geometry.safeArea.bottom) }
    /// What a vertical strip takes from the window's width when the bar stands beside it (a strip
    /// too narrow to hold it): the capsule plus a margin each side.
    static let reservedWidth: CGFloat = 56 + 2 * 10
    /// The system's strip items, measured on the closed iPhone Duo: 50 pt wide, their centre
    /// line 48 pt in from the window's edge, 10 pt between groups. Ours line up with them (Matt).
    static let stripItemWidth: CGFloat = 50
    static let stripCentreFromEdge: CGFloat = 48
    static let stripGroupGap: CGFloat = 10
    /// The side of a status strip like the Duo's (closed, or open on its side: the safe area 84 on one side, 0 on the
    /// other): one side deep enough for the strip's items, the other none. Nil anywhere else, an iPhone held sideways among
    /// them (its Dynamic Island's inset on both sides) (#542).
    static func statusStrip(_ safe: EdgeInsets) -> HorizontalEdge? {
        if safe.trailing >= stripItemWidth, safe.leading < 1 { return .trailing }
        if safe.leading >= stripItemWidth, safe.trailing < 1 { return .leading }
        return nil
    }
    /// The longest the bar group (the capsule and the circles) runs along the bottom: its length on the
    /// widest iPhone, the 17 Pro Max (440 pt wide, less the two 21 pt side margins), so no iPhone
    /// reaches it (the iPhone app is portrait-only). An iPad and the open Duo upright keep the
    /// iPhone's bar, centred, instead of one stretched across the window (Matt for 1.5 (26)); a
    /// window narrower than that (a small Stage Manager window, a window tiled to half the screen)
    /// is filled, as on an iPhone. A compact height (the closed Duo, the open Duo on its side) has
    /// the vertical strip instead. If the iPhone's portrait lock is ever lifted, a phone on its side
    /// would get this capped, centred bar too, as an iPad does: look at it then.
    static let maxHorizontalLength: CGFloat = 440 - 2 * 21
    /// Down a strip the bar is compact, like the system's vertical bars: icons only, in 46 pt
    /// slots and circles, so it fits under the navigation items the strip already holds.
    private let verticalSlot: CGFloat = 42
    private var circleSize: CGFloat { axis == .vertical ? 42 : barHeight }

    var body: some View {
        let gap = axis == .horizontal ? circleGap : Self.stripGroupGap
        GlassEffectContainer(spacing: gap) {
            // The capsule then the circles, side by side along the bottom or stacked down a strip.
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
            layout {
                capsule
                // Voice: one tap is a fresh chat with the current bot, straight into voice mode;
                // held, it offers the bots (#237). With four tabs at most the capsule keeps 49 pt
                // slots on the narrowest phone. Off in Settings › Appearance, it is not there and
                // the capsule is wider (voice mode still starts from a chat and the + panel).
                if showVoice {
                    Menu {
                        ForEach(model.runtime?.profiles ?? []) { p in
                            Button { voice(p.name) } label: { Label(p.label, systemImage: "person.fill") }
                        }
                    } label: {
                        Image(systemName: "mic.fill").font(.system(size: axis == .vertical ? 19 : 22, weight: .medium))
                            .frame(width: circleSize, height: circleSize)
                            .glassEffect(.regular.interactive(), in: .circle)
                    } primaryAction: {
                        voice(nil)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    // Its own glass presses with the finger: left out of the bar's shield.
                    .barShieldCircle("mic")
                    .disabled(model.runtime == nil)
                    .accessibilityLabel("Voice chat")
                    .accessibilityHint("Tap for a voice chat with the current bot; press and hold to choose a bot")
                    .accessibilityIdentifier("chats.voice")
                    .transition(.scale.combined(with: .opacity))
                }
                Button { run(ComposeAction.tap(tapRaw)) } label: {
                    // Centred on the square, not the glyph: the pencil hangs off its top-right
                    // corner. Measured from a simulator screenshot (the square sat 2.5 pt low).
                    Image(systemName: "square.and.pencil").font(.system(size: axis == .vertical ? 20 : 23, weight: .medium))
                        .offset(x: 0, y: -2.5)
                        .frame(width: circleSize, height: circleSize)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .barShieldCircle("compose")
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    let action = ComposeAction.hold(holdRaw)
                    guard action != .none else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    run(action)
                })
                .disabled(model.runtime == nil)
                .accessibilityLabel("New Chat")
                .accessibilityHint("Tap to \(ComposeAction.tap(tapRaw).spoken); press and hold to \(ComposeAction.hold(holdRaw).spoken)")
                .accessibilityIdentifier("chats.new")
            }
        }
        // Capped before the shield is drawn round it, so the shield is the capped bar's and a touch
        // beside it reaches the page, as beside the bar on an iPhone.
        .frame(maxWidth: axis == .horizontal ? Self.maxHorizontalLength : nil)
        // The bar's own shape takes the touches that miss its buttons: in the gaps between the
        // capsule and the circles, or at the glass's edge, they reached the page behind and
        // opened the row there (Matt on (18): "I can tap it when touching the nav bar"). One
        // capsule around the capsule and the circles, a little wider than what is drawn, under
        // them: the lens drag and the buttons sit on top and keep their touches. Only the
        // shapes, not a strip: beside the bar the list still answers. The same shape keeps the
        // page's glass still under the bar (`BarShield`, #344).
        .barShieldShape(catches: true, margin: Self.touchMargin)
        .padding(axis == .horizontal ? .horizontal : .vertical, axis == .horizontal ? sideMargin : 0)
        // Along the bottom: reserve only the part above the home-indicator area, like the
        // system bar group; the capsule itself is drawn overflowing into it. Down a strip: the
        // strip's width, the stack kept to its top like the system's.
        .frame(width: axis == .vertical ? Self.stripItemWidth : nil, height: axis == .horizontal ? Self.reservedHeight(in: windowGeometry) : nil,
               alignment: axis == .horizontal ? .top : .top)
        .animation(.snappy(duration: 0.25), value: showVoice)
    }

    private var capsule: some View {
        GeometryReader { geo in
            // The slots run along the capsule's length (x along the bottom, y down a strip).
            let length = axis == .horizontal ? geo.size.width : geo.size.height
            let thickness = axis == .horizontal ? geo.size.height : geo.size.width
            let slotAlong = max(1, (length - inset * 2) / CGFloat(max(1, tabs.count)))
            let slotAcross = thickness - inset * 2
            let slotWidth = axis == .horizontal ? slotAlong : slotAcross
            let slotHeight = axis == .horizontal ? slotAcross : slotAlong
            let selectedIndex = CGFloat(tabs.firstIndex(of: model.selectedTab) ?? 0)
            let dragging = dragX != nil
            let lensAlong: CGFloat = {
                guard let x = dragX else { return inset + selectedIndex * slotAlong }
                return min(max(inset, x - slotAlong / 2), length - inset - slotAlong)
            }()
            let lensX = axis == .horizontal ? lensAlong : inset
            let lensY = axis == .horizontal ? inset : lensAlong
            ZStack(alignment: .topLeading) {
                // The lens: clear glass under the selected slot, or wherever the finger holds it
                // (grown a little while lifted). Under the icons at rest so the selected one stays
                // crisp; over them while dragged so it refracts them as it passes, like the system's.
                GlassEffectContainer {
                    Capsule().fill(.clear)
                        .frame(width: slotWidth, height: slotHeight)
                        .glassEffect(.clear.interactive(), in: .capsule)
                }
                .scaleEffect(dragging ? 1.12 : 1)
                .offset(x: lensX, y: lensY)
                .animation(dragging ? .interactiveSpring(response: 0.18) : .snappy(duration: 0.32), value: lensAlong)
                .animation(.snappy(duration: 0.22), value: dragging)
                .allowsHitTesting(false)
                .zIndex(dragging ? 2 : 0)
                iconRow(slotWidth: slotWidth, slotHeight: slotHeight, dragging: dragging)
                    .zIndex(1)
                // While dragged, a second copy of the icons rides on top of the lens, masked to
                // the lens minus its rim, so the icon under it stays crisp and only the edge
                // refracts (the system bar draws its icons twice for the same reason).
                if dragging {
                    let lensW = slotWidth * 1.12, lensH = slotHeight * 1.12
                    iconRow(slotWidth: slotWidth, slotHeight: slotHeight, dragging: true)
                        .mask {
                            Capsule()
                                .frame(width: lensW - 8, height: lensH - 8)
                                .position(x: lensX + slotWidth / 2, y: lensY + slotHeight / 2)
                        }
                        .animation(.interactiveSpring(response: 0.18), value: lensAlong)
                        .allowsHitTesting(false)
                        .zIndex(3)
                }
            }
            .contentShape(Capsule())
            .gesture(barGesture(slotAlong: slotAlong), including: gestureMask)
            .onChange(of: touching) { _, on in if !on { DispatchQueue.main.async { dragGone() } } }
        }
        .frame(width: axis == .vertical ? verticalSlot + inset * 2 : nil,
               height: axis == .horizontal ? barHeight : CGFloat(max(1, tabs.count)) * verticalSlot + inset * 2)
        .glassEffect(.regular, in: .capsule)
    }

    private func iconRow(slotWidth: CGFloat, slotHeight: CGFloat, dragging: Bool) -> some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            ForEach(tabs, id: \.self) { tab in
                slot(tab, dragging: dragging).frame(width: slotWidth, height: slotHeight)
            }
        }
        .padding(inset)
    }

    /// One tab: a large icon on its own, or a smaller icon over its label when it is selected
    /// (no labels at all while the lens is being dragged, like the system bar, or when
    /// Settings › Appearance › Tab labels is off).
    @ViewBuilder private func slot(_ tab: AppModel.AppTab, dragging: Bool) -> some View {
        let selected = (hoverTab ?? model.selectedTab) == tab
        let labelled = selected && !dragging && showLabels && axis == .horizontal
        VStack(spacing: 2) {
            icon(for: tab, size: axis == .vertical ? 21 : (labelled ? 21 : 25))
                .frame(height: axis == .vertical ? 26 : (labelled ? 24 : 30))
            if labelled {
                Text(tab.title).font(.system(size: 10, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(selected ? Color.vory : Color.primary)
        .animation(.snappy(duration: 0.24), value: labelled)
        .overlay(alignment: .top) {
            if let b = badge(for: tab) { b.offset(x: 14, y: 4) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier("tab.\(tab.rawValue)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { select(tab) }
    }

    /// A press moves the lens under the finger once it is held for a moment or slides sideways;
    /// the tab under the lens is tinted as it passes and the page switches to it when the lens
    /// is dropped. A quick press is a tap on that tab.
    private func barGesture(slotAlong: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($touching) { _, on, _ in on = true }
            .onChanged { v in
                if pressStart == nil { pressStart = Date() }
                let held = Date().timeIntervalSince(pressStart ?? Date()) > 0.22
                let slid = abs(axis == .horizontal ? v.translation.width : v.translation.height) > 8
                guard dragX != nil || held || slid else { return }
                if dragX == nil { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                let along = axis == .horizontal ? v.location.x : v.location.y
                dragX = along
                if let tab = tab(at: along, slotAlong: slotAlong), tab != (hoverTab ?? model.selectedTab) {
                    UISelectionFeedbackGenerator().selectionChanged()
                    hoverTab = tab
                    #if DEBUG
                    if tab != model.selectedTab { TabBarDragTesting.cancelSoon { testCancel = $0 } }
                    #endif
                }
            }
            .onEnded { v in
                let along = axis == .horizontal ? v.location.x : v.location.y
                let dropped = dragX != nil
                dragX = nil
                pressStart = nil
                hoverTab = nil
                guard let tab = tab(at: along, slotAlong: slotAlong) else { return }
                if dropped {
                    if tab != model.selectedTab { withAnimation(.snappy(duration: 0.28)) { model.selectedTab = tab } }
                } else {
                    select(tab)
                }
            }
    }

    private var gestureMask: GestureMask {
        #if DEBUG
        testCancel ? .subviews : .all
        #else
        .all
        #endif
    }

    /// The finger is off the capsule. After a lift `onEnded` has already put everything away; a
    /// drag the system cancelled (its edge gesture, or the window's glass recognizer that won the
    /// touch) never gets `onEnded`, and left the lens and the tint on the tab it was over with the
    /// page unchanged until the next touch (Matt on 24, #375). Run a turn later, so a lift's
    /// `onEnded` always comes first: here only a cancel is left. A lifted lens then goes on to the
    /// tab it was over, the page with it, as if dropped there; a press that had not lifted it
    /// (a cancelled tap) does nothing. The tint and the page never disagree.
    private func dragGone() {
        guard dragX != nil || pressStart != nil else { return }
        let lifted = dragX != nil
        let target = hoverTab
        dragX = nil
        pressStart = nil
        hoverTab = nil
        guard lifted, let target, target != model.selectedTab else { return }
        withAnimation(.snappy(duration: 0.28)) { model.selectedTab = target }
    }

    private func tab(at along: CGFloat, slotAlong: CGFloat) -> AppModel.AppTab? {
        let i = Int((along - inset) / slotAlong)
        return tabs.indices.contains(i) ? tabs[i] : (along < inset ? tabs.first : tabs.last)
    }

    /// A tap on the selected tab while it is deeper than its root page goes back to that page,
    /// like the system bar.
    private func select(_ tab: AppModel.AppTab) {
        // A tab chosen by hand is where the person wants to be: no going back after a chat.
        model.composeReturnTab = nil
        if tab == model.selectedTab {
            if model.tabAtRoot[tab] == false { model.popToRoot[tab, default: 0] += 1 }
            model.tabReselected[tab, default: 0] += 1
            return
        }
        withAnimation(.snappy(duration: 0.28)) { model.selectedTab = tab }
    }

    @ViewBuilder private func icon(for tab: AppModel.AppTab, size: CGFloat) -> some View {
        if tab == .bots {
            VoryOutlineIcon().frame(width: size * 1.5, height: size * 1.28)
        } else {
            Image(systemName: tab.symbol).font(.system(size: size, weight: .medium))
        }
    }

    /// Chats counts waiting cards; Settings flags a gateway that needs a restart, or a companion
    /// update waiting under Software Update.
    private func badge(for tab: AppModel.AppTab) -> CountBadge? {
        switch tab {
        case .chats:
            let n = model.runtime?.needsAttention.count ?? 0
            return n > 0 ? CountBadge(n) : nil
        case .settings:
            if model.runtime?.restartRequired != nil { return CountBadge(1) }
            return model.companionUpdateAvailable ? CountBadge(1) : nil
        default:
            return nil
        }
    }
}

/// Hides the custom tab bar while this view is on screen. On the Chats tab the list's own
/// navigation path hides the bar the instant a push begins and shows it the instant a pop
/// begins, so this only counts on the other tabs.
struct HidesTabBar: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var countedOn: AppModel.AppTab?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard countedOn == nil, model.selectedTab != .chats else { return }
                countedOn = model.selectedTab
                model.tabBarHiders[model.selectedTab, default: 0] += 1
            }
            .onDisappear {
                guard let tab = countedOn else { return }
                countedOn = nil
                model.tabBarHiders[tab] = max(0, (model.tabBarHiders[tab] ?? 0) - 1)
            }
    }
}

/// Marks a tab's root page: on screen means the tab is at its root. Chats reports through its
/// navigation path instead (a pushed chat keeps the list alive underneath). A tap on the tab
/// while deeper pops the stack the way a swipe back would, animated.
struct TabRoot: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.statusInCorner) private var statusInCorner
    /// The page's pull-to-refresh state when its `.reloadable` is applied outside this marker
    /// (Bots, Files): by environment then, by preference when it sits inside (Home, Projects,
    /// the Board, Status, Sessions, Tasks). The bar's title capsule hosts the wheel either way;
    /// Bots and Files had no wheel (Matt, 2026-10-12).
    @Environment(PullRefreshState.self) private var pullAround: PullRefreshState?
    @State private var pullBelow: PullRefreshState?
    var tab: AppModel.AppTab
    private func publishPull() { model.pullStates[tab] = pullBelow ?? pullAround }
    func body(content: Content) -> some View {
        content
            // The bar draws this page's actions (`barTab`); the page leaves its own out.
            .environment(\.barTab, tab)
            // Every root page shares the Chats page's heading (Matt, 2026-10-12); the pull-to-
            // refresh wheel sits beside it on the pages that can refresh.
            .pageHeading(tab.title, on: !model.wideLayout && !MorphTopBar.on)
            // Out of the accessibility tree while another tab is up. RootView hides the whole
            // page, but that flag sits outside the navigation stack, a UIKit container the flag
            // does not pass through: Home's blocks, bots and chat rows stayed in the Chats
            // tab's tree, off-screen, and VoiceOver and XCTest found the same chat twice (#326).
            .accessibilityHidden(model.selectedTab != tab)
            // The page's pull-to-refresh state, for the bar's title capsule to host its wheel.
            .onPreferenceChange(PullRefreshKey.self) { r in Task { @MainActor in pullBelow = r.state; publishPull() } }
            .onChange(of: pullAround.map(ObjectIdentifier.init), initial: true) { _, _ in publishPull() }
            // Under the morph prototype the bar draws the title: the stack's own (large by
            // default on a root) goes, as it does on Chats, so no root shows two.
            .navigationBarTitleDisplayMode(MorphTopBar.active(model) ? .inline : .automatic)
            .toolbar(removing: MorphTopBar.active(model) ? .title : nil)
            // An empty bar collapses (on the Duo the search drawer rode up under the capsules):
            // an invisible item keeps the bar at its height under the prototype.
            .toolbar { if MorphTopBar.active(model) { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 44).accessibilityHidden(true) } } }
            // Where nothing of the system's keeps a band under the bar's row (the closed Duo, the open Duo upright), the
            // stack starts under the row (#340).
            .background(TopBarRoomProbe(tab: tab, room: TopBarRoom.inset(barsVertical: model.tabBarVertical, statusInCorner: statusInCorner,
                                                               barOn: MorphTopBar.active(model), rowBottom: MorphState.shared.rootRowBottom)).frame(width: 0, height: 0))
            // "At root" is set by the probe below: on a swipe back SwiftUI's onAppear fires as
            // the pop begins, and the bar's capsules came back over the pushed page before it
            // had moved (Matt, 2026-10-12: "swiping back on other pages is broken"). The probe
            // waits for an interactive pop to finish (and stays put if it is cancelled).
            .onDisappear { model.tabAtRoot[tab] = false }
            .background(PopToRootProbe(tab: tab))
            .background(RootArrivalProbe(tab: tab, active: MorphTopBar.active(model), popOne: model.popOne[tab, default: 0]) { model.tabAtRoot[tab] = true })
    }
}

/// Under a tab's root page, a view that watches the stack's UIKit navigation controller:
/// - tells the root it has arrived (at once on a plain appearance or a Back button's pop, at
///   the end of an interactive pop, not at all if the swipe is cancelled), for `tabAtRoot`;
/// - drives the morph bar for a pushed page (Matt, 2026-10-12: the title capsule morphs into
///   the Back arrow and back, following the swipe like a chat);
/// - hides the pushed page's own back button under the bar's Back (its title stays);
/// - pops one page when the bar's Back bumps `popOne`.
/// Event-driven: a small view controller under the root page hears the root being covered (a
/// push from it starts) and uncovered (a pop back to it starts), with the transition's
/// coordinator; each page pushed gets one of its own (`PageProbe`), which hears the next push
/// from it, so a page at any depth hides its own Back; and a display link runs only while a
/// finger has a pop back to the root, for the scrub. Nothing runs at rest (the battery rule, #248;
/// the 60 Hz poll this replaced cost 1.3% CPU on a root at rest). Not the stack's delegate:
/// wrapped in a forwarder, SwiftUI pushed every page without its slide (1.5 (18), Matt: "there's
/// no longer an animation when clicking into panes").
struct RootArrivalProbe: UIViewControllerRepresentable {
    /// The last decision, for the geometry probe's banner (a UI test reads it; observable, so the
    /// banner follows a push past the root, which changes nothing else on screen).
    @MainActor static var last: String {
        get { ProbeRecord.shared.last }
        set { ProbeRecord.shared.last = newValue }
    }
    @MainActor @Observable final class ProbeRecord {
        static let shared = ProbeRecord()
        var last = "none"
    }
    let tab: AppModel.AppTab
    let active: Bool
    let popOne: Int
    let arrived: () -> Void
    func makeUIViewController(context: Context) -> ProbeController {
        let c = ProbeController()
        c.probe.tab = tab; c.probe.active = active; c.probe.arrived = arrived
        return c
    }
    func updateUIViewController(_ c: ProbeController, context: Context) {
        let v = c.probe
        let widthChanged = v.active != active
        v.arrived = arrived; v.active = active
        if popOne != v.popSeen { v.popSeen = popOne; if popOne > 0 { v.popOnePage() } }
        if widthChanged { DispatchQueue.main.async { v.chromeForWidth() } }
    }

    /// A child of the root page's controller, so the root's appearance reaches it: covered as a
    /// push from the root starts, uncovered as a pop back to it starts, each with the
    /// transition's coordinator. Its view is the ArrivalView.
    final class ProbeController: UIViewController {
        let probe = ArrivalView()
        override func loadView() { probe.isUserInteractionEnabled = false; view = probe }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            probe.pageWillHide(parent, animated: animated, coordinator: transitionCoordinator)
        }
        override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); probe.rootSettled() }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            probe.rootWillShow(coordinator: transitionCoordinator)
        }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); probe.rootSettled() }
    }

    /// Added to each pushed page's controller (a child, so the page's appearance reaches it): it
    /// hears the page going, covered by the next push or popped, with the transition's coordinator.
    final class PageProbe: UIViewController {
        weak var owner: ArrivalView?
        override func loadView() { let v = UIView(); v.isUserInteractionEnabled = false; v.isHidden = true; view = v }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            owner?.pageWillHide(parent, animated: animated, coordinator: transitionCoordinator)
        }
    }
    final class ArrivalView: UIView {
        var tab: AppModel.AppTab = .chats
        var active = true
        var arrived: (() -> Void)?
        var popSeen = 0
        /// Runs only while a finger has a pop back to the root.
        private var link: CADisplayLink?
        private var fingerHasPop = false
        /// This tab has a page pushed: kept from the stack's events whether or not the bar is up
        /// (the bar is off on a wide window), so it is right when the bar comes back.
        private var wasPushed: Bool {
            get { MorphState.shared.pushedTabs.contains(tab) }
            set { if newValue { MorphState.shared.pushedTabs.insert(tab) } else { MorphState.shared.pushedTabs.remove(tab) } }
        }
        /// The transition being followed: its start is reported twice on a pop (the root's
        /// appearance, then its return to the window).
        private weak var followed: AnyObject?
        private var nav: UINavigationController? { parentViewController?.navigationController }
        /// The pages whose back button and title this probe took for the bar, so only those are
        /// given back (a page's own `navigationBarBackButtonHidden` is its own).
        private let chromeTaken = NSHashTable<UIViewController>.weakObjects()
        override init(frame: CGRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(self, selector: #selector(markerChanged), name: OwnBarMarker.changed, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        /// A page's own-bar marker came or went: it can arrive with the page's first layout, after
        /// the push started, or with its content (the Board's chooser comes with its boards).
        @objc private func markerChanged() {
            guard tab != .chats, let nav else { return }
            settleSoon(nav)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { stopLink(); return }
            let nav = self.nav
            // The root's view re-enters the window as a page is pushed over it: not an arrival.
            if let nav, nav.viewControllers.count > 1, nav.transitionCoordinator?.isInteractive != true {
                Perf.stamp("root probe: under a pushed page, no arrival")
            } else if let c = nav?.transitionCoordinator, c.isInteractive {
                Perf.stamp("root probe: interactive pop, waiting"); RootArrivalProbe.last = "interactive, waiting"
                c.notifyWhenInteractionChanges { [weak self] ctx in
                    Perf.stamp("root probe: interaction ended cancelled=\(ctx.isCancelled)"); RootArrivalProbe.last = "interaction ended cancelled=\(ctx.isCancelled)"
                    if !ctx.isCancelled { self?.arrived?() }
                }
            } else {
                let why = nav == nil ? "no nav" : (nav?.transitionCoordinator == nil ? "coordinator nil" : "not interactive")
                Perf.stamp("root probe: arrived at once (\(why))"); RootArrivalProbe.last = "at once (\(why))"
                arrived?()
            }
            guard tab != .chats, let nav else { return }
            if let c = nav.transitionCoordinator { follow(c, in: nav) } else { settle(nav) }
        }

        /// A page of this stack (the root, or a pushed page through its PageProbe) is going: a push
        /// from it, or the pop of it, starts. Only a transition between this stack's own pages
        /// counts: a full-screen cover or a window move also takes a root out of view, and read as
        /// a push it would send the bar away over no page. Anything else settles.
        fileprivate func pageWillHide(_ page: UIViewController?, animated: Bool, coordinator c: UIViewControllerTransitionCoordinator?) {
            guard tab != .chats, let nav else { return }
            let inStack = c.map { isInStack($0, nav) } ?? false
            // A push (the page coming in sits deeper than the one going): its record, for the tests
            // (the geometry probe's banner) and the log. A push without a coordinator records too.
            let pages = nav.viewControllers
            if let page, let from = pages.firstIndex(of: page), pages.count > from + 1,
               c == nil || (c?.viewController(forKey: .to)).flatMap({ pages.firstIndex(of: $0) }).map({ $0 > from }) == true {
                let ownBar = (c?.viewController(forKey: .to)).map { ownsBar($0, in: nav) } ?? false
                RootArrivalProbe.last = "push animated=\(animated) coordinator=\(c != nil) depth=\(pages.count) ownbar=\(ownBar)"
                Perf.stamp("root probe \(tab.rawValue): \(RootArrivalProbe.last)")
            }
            if let c, inStack { follow(c, in: nav) } else { settleSoon(nav) }
        }

        /// The root is being uncovered: a pop back to it starts (one inside this stack only).
        fileprivate func rootWillShow(coordinator c: UIViewControllerTransitionCoordinator?) {
            guard tab != .chats, let nav else { return }
            if let c, isInStack(c, nav) { follow(c, in: nav) } else { settleSoon(nav) }
        }

        /// Both ends of the transition are pages of this stack.
        private func isInStack(_ c: UIViewControllerTransitionCoordinator, _ nav: UINavigationController) -> Bool {
            guard let from = c.viewController(forKey: .from), let to = c.viewController(forKey: .to) else { return false }
            return from.navigationController === nav && to.navigationController === nav
        }

        /// Gives a pushed page its own probe: it hears the next push from that page.
        private func watchPage(_ page: UIViewController) {
            guard !page.children.contains(where: { $0 is PageProbe }) else { return }
            let probe = PageProbe()
            probe.owner = self
            page.addChild(probe)
            page.view.addSubview(probe.view)
            probe.didMove(toParent: page)
        }

        /// The root's appearance has settled either way (a cancelled pop ends covered again).
        fileprivate func rootSettled() {
            guard tab != .chats, let nav else { return }
            settleSoon(nav)
        }

        /// One transition, from its start: which way it goes is read from its ends, not from the
        /// stack's depth (SwiftUI's stack keeps its depth until a pop commits).
        private func follow(_ c: UIViewControllerTransitionCoordinator, in nav: UINavigationController) {
            if followed === c { if fingerHasPop { startLink() }; return }
            followed = c
            let state = MorphState.shared
            let root = nav.viewControllers.first
            let from = c.viewController(forKey: .from), to = c.viewController(forKey: .to)
            // A page that keeps its own bar (or one pushed from it) coming in: the bar steps aside.
            // Leaving for one that doesn't brings it back as it was: at once for a button's pop,
            // once the finger lets go for a swipe (a cancelled swipe leaves it aside).
            if let to, to !== root, ownsBar(to, in: nav) {
                setAside(true)
            } else if MorphState.shared.ownBarTabs.contains(tab) {
                if c.isInteractive { c.notifyWhenInteractionChanges { [weak self] ctx in if !ctx.isCancelled { self?.setAside(false) } } }
                else { setAside(false) }
            }
            if let to, to !== root {
                // A push, or back to a page that is not the root: the bar's Back stays.
                showPushed(to)
            } else if to === root, from !== root, wasPushed, active {
                if c.isInteractive {
                    // The finger has it: the bar follows the page's slide frame by frame.
                    fingerHasPop = true
                    MorphState.shared.rootPopInFlight = true
                    startLink()
                    c.notifyWhenInteractionChanges { [weak self] ctx in
                        self?.fingerHasPop = false
                        self?.stopLink()
                        let remaining = max(0.12, ctx.transitionDuration * Double(1 - ctx.percentComplete))
                        MorphState.shared.release(ctx.isCancelled ? 0 : 1, over: remaining)
                        MorphState.shared.rootPopInFlight = false
                    }
                } else {
                    Perf.stamp("root probe \(tab.rawValue): pop seen (button)")
                    // Next turn: this runs inside SwiftUI's own update for the pop, where the
                    // morph's animation was dropped (the bar changed only once the page had gone).
                    DispatchQueue.main.async { MorphState.shared.pop() }
                }
            }
            c.animate(alongsideTransition: nil) { [weak self] _ in
                MorphState.shared.rootPopInFlight = false
                guard let self else { return }
                self.fingerHasPop = false
                self.stopLink()
                if self.followed === c { self.followed = nil }
                self.settleSoon(nav)
            }
        }

        /// A page other than the root is coming in: its own Back and title go, and the first
        /// one over the root sends the bar away.
        private func showPushed(_ vc: UIViewController) {
            watchPage(vc)
            let first = !wasPushed
            wasPushed = true
            guard active, let nav else { giveBackItem(under: vc); return }
            // A page that keeps its own bar keeps its back and title, and the bar's state under it
            // stays as it was (the root's, or the Back of the page it came from).
            if ownsBar(vc, in: nav) { giveBackItem(under: vc); return }
            hideChrome(of: vc)
            guard first else { return }
            Perf.stamp("root probe \(tab.rawValue): push seen")
            // Next turn: this runs inside SwiftUI's own update for the push (the root's appearance
            // changes there), where the morph's animation was dropped and the bar jumped to the
            // Back circle in one frame. The page's own Back is hidden above, before it shows.
            let tab = self.tab
            DispatchQueue.main.async { if MorphState.shared.pushedTab == nil { MorphState.shared.pushPage(tab) } }
        }

        /// Once the transition that just ended has let go of the stack (UIKit may still report
        /// its coordinator from inside its completion and didShow).
        private func settleSoon(_ nav: UINavigationController) {
            DispatchQueue.main.async { [weak self, weak nav] in if let self, let nav { self.settle(nav) } }
        }

        /// No transition under way: the bar matches the stack as it stands.
        private func settle(_ nav: UINavigationController) {
            guard nav.transitionCoordinator == nil else { return }
            let deep = nav.viewControllers.count > 1, was = wasPushed
            wasPushed = deep
            for page in nav.viewControllers.dropFirst() { watchPage(page) }
            // The page in front keeps its own bar, or doesn't (a marker that came late lands here).
            let aside = deep && nav.topViewController.map { ownsBar($0, in: nav) } == true
            setAside(aside)
            guard active else { return }
            let state = MorphState.shared
            if deep {
                if let top = nav.topViewController { aside ? showChrome(of: top) : hideChrome(of: top) }
                // Pushed without a transition (a restored path): the Back at once, unless the first
                // page keeps its own bar (the bar's state under it is the root's).
                if !was, state.pushedTab == nil, !OwnBarMarker.marks(nav.viewControllers[1]) { state.pushPage(tab) }
            } else if was, state.pushedTab == tab, !state.scrubbing, state.t < 1 {
                // The pop is over: back at the root.
                state.pop()
            }
        }

        /// The window widened (the bar steps aside: pushed pages get their own Back and title
        /// back) or narrowed again (the bar's Back takes over). The bar's state comes from
        /// `MorphState.showTab` as it reappears.
        func chromeForWidth() {
            guard tab != .chats, let nav else { return }
            for vc in nav.viewControllers.dropFirst() { active && !ownsBar(vc, in: nav) ? hideChrome(of: vc) : showChrome(of: vc) }
        }

        private func startLink() {
            guard link == nil else { return }
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
            Perf.stamp("root probe \(tab.rawValue): link started")
        }

        private func stopLink() {
            guard let link else { return }
            link.invalidate(); self.link = nil
            Perf.stamp("root probe \(tab.rawValue): link stopped")
        }

        /// While a finger has the pop: the page's own slide is the progress the eye sees (the
        /// coordinator's percentComplete lagged it on the phone).
        @objc private func tick() {
            guard active, fingerHasPop, let nav, let c = nav.transitionCoordinator, c.isInteractive else { stopLink(); return }
            let width = max(1, nav.view.bounds.width)
            let slid = (c.viewController(forKey: .from)?.view.frame.minX ?? 0) / width
            MorphState.shared.scrub(min(1, max(0, max(CGFloat(c.percentComplete), slid))))
        }

        /// A pushed page's own title stays, in the middle where the system puts it (Matt,
        /// 2026-10-12, on a bot's page: "it shows up in the middle where it should be but then
        /// disappears ... just have it actually stay appeared"). This is the one switch if that
        /// turns out to be for a bot's page only (`tab == .bots`).
        private var keepsTitle: Bool { true }

        /// The pushed page keeps its content and its title; its system back button is the bar's.
        /// A page without a title gets an empty title view all the same: with its back button gone
        /// its bar had nothing in it, and an empty bar collapses (a Settings page's content rose
        /// under the Back circle after a cancelled swipe). Again once its title is known.
        private func hideChrome(of vc: UIViewController) {
            chromeTaken.add(vc)
            let item = vc.navigationItem
            item.hidesBackButton = true
            // The page under it gives no Back either. Where the system's bars stand in a side strip (the closed iPhone
            // Duo), the strip drew a Back from the page underneath's own back item whenever something walked the page's
            // accessibility tree (VoiceOver, Voice Control, Full Keyboard Access), whatever `hidesBackButton` said: a
            // second Back beside the bar's.
            if let under = page(under: vc), under.navigationItem.backBarButtonItem == nil {
                under.navigationItem.backBarButtonItem = HiddenBack()
            }
            let titled = keepsTitle && !(item.title ?? "").isEmpty
            if !titled, !(item.titleView is BarHolder) { item.titleView = BarHolder() }
            else if titled, item.titleView is BarHolder { item.titleView = nil }
        }
        /// An empty title view: holds an untitled pushed page's bar at its height.
        private final class BarHolder: UIView {}
        /// The back item the bar puts on the page under a pushed one, hidden; only this one is taken back.
        private final class HiddenBack: UIBarButtonItem {
            override init() { super.init(); isHidden = true }
            required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        }

        /// The page a pushed page sits on, in this stack.
        private func page(under vc: UIViewController) -> UIViewController? {
            guard let pages = nav?.viewControllers, let i = pages.firstIndex(of: vc), i > 0 else { return nil }
            return pages[i - 1]
        }

        private func showChrome(of vc: UIViewController) {
            guard chromeTaken.contains(vc) else { return }
            chromeTaken.remove(vc)
            vc.navigationItem.hidesBackButton = false
            giveBackItem(under: vc)
            if vc.navigationItem.titleView is BarHolder { vc.navigationItem.titleView = nil }
        }

        /// A page keeps the system's Back after all (a wide window, or a page with its own bar): the page under it gets
        /// its back item back, where the bar had hidden it.
        private func giveBackItem(under vc: UIViewController) {
            if let under = page(under: vc), under.navigationItem.backBarButtonItem is HiddenBack {
                under.navigationItem.backBarButtonItem = nil
            }
        }

        /// This page keeps its own bar: it, or a page under it other than the root, carries the
        /// marker (`.pushedPage(keepsOwnBar: true)`). Off with `-vory-ownbar-off`.
        private func ownsBar(_ vc: UIViewController, in nav: UINavigationController) -> Bool {
            guard !MorphState.ownBarOff else { return false }
            let pages = nav.viewControllers
            guard vc !== pages.first else { return false }
            let upTo = pages.firstIndex(of: vc).map { pages[1...$0] } ?? pages.dropFirst()
            return OwnBarMarker.marks(vc) || upTo.contains { OwnBarMarker.marks($0) }
        }

        /// The bar steps aside on this tab, or comes back; next turn, as the bar's other changes
        /// from inside a transition's start are.
        private func setAside(_ on: Bool) {
            let tab = self.tab
            DispatchQueue.main.async {
                let state = MorphState.shared
                guard state.ownBarTabs.contains(tab) != on else { return }
                Perf.stamp("root probe \(tab.rawValue): bar \(on ? "steps aside (own bar)" : "back")")
                if on { state.ownBarTabs.insert(tab) } else { state.ownBarTabs.remove(tab) }
            }
        }

        func popOnePage() {
            guard let nav, nav.viewControllers.count > 1 else { return }
            nav.popViewController(animated: true)
        }
    }
}

/// Marks a pushed page that keeps its own bar (`.pushedPage(keepsOwnBar: true)`): a form with its
/// own Cancel, Done or Save keeps the system bar, its items, title and back, and the morph bar
/// steps aside while it, or a page pushed from it, is in front. A child of the page's controller,
/// read by the root's probe; its arrival and departure are announced, since a page's first layout
/// can come after its push has started.
struct OwnBarMarker: UIViewControllerRepresentable {
    static let changed = Notification.Name("vory.ownBarMarkerChanged")
    final class Controller: UIViewController {
        override func loadView() { let v = UIView(); v.isUserInteractionEnabled = false; v.isHidden = true; view = v }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            NotificationCenter.default.post(name: OwnBarMarker.changed, object: nil)
        }
    }
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ c: Controller, context: Context) {}
    /// This page, or a controller inside it, carries the marker.
    static func marks(_ vc: UIViewController) -> Bool {
        var queue = [vc], seen = 0
        while let c = queue.popLast(), seen < 64 {
            seen += 1
            if c is Controller { return true }
            queue += c.children
        }
        return false
    }
}

/// The top bar's room on a tab's navigation stack (#340, `TopBarRoom`): the stack's additional safe area at the top, so
/// its pages and the system's search drawer start under the bar's row where nothing of the system's keeps a band for it
/// (the closed iPhone Duo, the open Duo upright). On the stack, not the page: the drawer belongs to the stack's bar and
/// stays where the stack's safe area puts it (a page's own inset moved its rows and left the drawer under the row, as did
/// a SwiftUI inset or padding). Pages pushed on the stack get it too: they start that much lower there, never under the
/// row. A child view controller of the root page applies it when it changes and when the page appears, never in the
/// middle of a transition (again as the transition completes): nothing is read back from the page.
struct TopBarRoomProbe: UIViewControllerRepresentable {
    /// The tab whose root this is: the room each root applied is kept by tab (`AppliedRoom`).
    var tab: AppModel.AppTab
    var room: CGFloat
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ probe: Probe, context: Context) {
        probe.rootTab = tab
        probe.room = room
        DispatchQueue.main.async { probe.apply() }
    }

    final class Probe: UIViewController {
        /// Not `tab`: UIKit's view controllers have one of their own.
        var rootTab: AppModel.AppTab = .chats
        var room: CGFloat = 0
        override func loadView() { let v = UIView(); v.isUserInteractionEnabled = false; v.backgroundColor = .clear; view = v }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); apply() }

        func apply() {
            guard let nav = navigationController else { return }
            if let transition = nav.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { [weak self] _ in self?.apply() }
                return
            }
            // Only on a change: the readouts observe these, and every root applies on every update.
            if TopBarRoom.lastRoom != room { TopBarRoom.lastRoom = room }
            if AppliedRoom.shared.rooms[rootTab] != room { AppliedRoom.shared.rooms[rootTab] = room }
            guard nav.additionalSafeAreaInsets.top != room else { return }
            nav.additionalSafeAreaInsets.top = room
        }
    }
}

/// A zero-size view under a tab's root page that finds the UIKit navigation controller behind
/// the NavigationStack and pops it to the root, animated, whenever `popToRoot` bumps.
private struct PopToRootProbe: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    var tab: AppModel.AppTab

    func makeUIView(context: Context) -> UIView { let v = UIView(); v.isUserInteractionEnabled = false; return v }
    func updateUIView(_ v: UIView, context: Context) {
        let bump = model.popToRoot[tab, default: 0]
        guard bump != context.coordinator.seen else { return }
        context.coordinator.seen = bump
        guard bump > 0 else { return }
        DispatchQueue.main.async {
            var r: UIResponder? = v
            while let n = r { if let nav = n as? UINavigationController { nav.popToRootViewController(animated: true); return }; r = n.next }
            // The probe sits in the root page, which is inside the stack's hosting controller.
            if let nav = v.parentViewController?.navigationController { nav.popToRootViewController(animated: true) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var seen = 0 }
}

private extension UIView {
    var parentViewController: UIViewController? {
        var r: UIResponder? = self
        while let n = r { if let vc = n as? UIViewController { return vc }; r = n.next }
        return nil
    }
}

extension View {
    func hidesTabBar() -> some View { modifier(HidesTabBar()) }
    func tabRoot(_ tab: AppModel.AppTab) -> some View { modifier(TabRoot(tab: tab)) }
}

#if DEBUG
/// UI tests of #375: with `-vory-test-cancel-bar-drag`, a drag of the lens onto another tab is
/// cancelled 0.15 s later: the bar's gesture is taken away for a moment, which SwiftUI ends as a
/// cancel (its state reset, no `onEnded`), as when the system takes the touch. A synthesized drag
/// on the simulator is never cancelled, and SwiftUI's own touch recognizer is out of an app's reach.
@MainActor enum TabBarDragTesting {
    private static var last = Date.distantPast
    static func cancelSoon(_ set: @escaping @MainActor (Bool) -> Void) {
        guard ProcessInfo.processInfo.arguments.contains("-vory-test-cancel-bar-drag"), Date().timeIntervalSince(last) > 1 else { return }
        last = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            set(true)
            NSLog("bar drag: test cancel")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { set(false) }
        }
    }
}
#endif
