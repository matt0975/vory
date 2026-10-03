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
    var compose: () -> Void
    /// The full New Message sheet (bots, project, files).
    var composeFull: () -> Void = {}
    /// What a tap and a press and hold do (Settings › Appearance › New Chat button).
    @AppStorage(ComposeAction.tapKey) private var tapRaw = ComposeAction.tapDefault.rawValue
    @AppStorage(ComposeAction.holdKey) private var holdRaw = ComposeAction.holdDefault.rawValue

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

    /// The system capsule is 62 pt; the user wanted it a little shorter, bottom edge kept.
    private let barHeight: CGFloat = 56
    private let inset: CGFloat = 4
    private let sideMargin: CGFloat = 21
    private let circleGap: CGFloat = 12
    /// The window's bottom safe-area inset: 34 pt on phones with a home indicator, 0 on a
    /// home-button phone (iPhone SE), which iOS 26 still runs on.
    private static var safeBottom: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }.first ?? 34
    }
    /// How far the capsule hangs into the home-indicator area: the full 13 pt when there is one.
    /// Without one the capsule would hang off the screen, so it hangs by what is there (nothing on
    /// an SE) and keeps the rest as a gap above the screen edge instead.
    static var overhang: CGFloat { min(13, safeBottom) }
    /// What the bar reserves above the home-indicator area (the system bar group's 49 pt); the
    /// capsule is drawn overflowing below it.
    static var reservedHeight: CGFloat { 56 - overhang + max(0, 13 - safeBottom) }

    var body: some View {
        GlassEffectContainer(spacing: circleGap) {
            HStack(spacing: circleGap) {
                capsule
                Button { run(ComposeAction.tap(tapRaw)) } label: {
                    // Centred on the square, not the glyph: the pencil hangs off its top-right
                    // corner. Measured from a simulator screenshot (the square sat 2.5 pt low).
                    Image(systemName: "square.and.pencil").font(.system(size: 23, weight: .medium))
                        .offset(x: 0, y: -2.5)
                        .frame(width: barHeight, height: barHeight)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
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
        .padding(.horizontal, sideMargin)
        // Reserve only the part above the home-indicator area, like the system bar group; the
        // capsule itself is drawn overflowing into it.
        .frame(height: Self.reservedHeight, alignment: .top)
    }

    private var capsule: some View {
        GeometryReader { geo in
            let slotWidth = max(1, (geo.size.width - inset * 2) / CGFloat(max(1, tabs.count)))
            let slotHeight = geo.size.height - inset * 2
            let selectedIndex = CGFloat(tabs.firstIndex(of: model.selectedTab) ?? 0)
            let dragging = dragX != nil
            let lensX: CGFloat = {
                guard let x = dragX else { return inset + selectedIndex * slotWidth }
                return min(max(inset, x - slotWidth / 2), geo.size.width - inset - slotWidth)
            }()
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
                .offset(x: lensX, y: inset)
                .animation(dragging ? .interactiveSpring(response: 0.18) : .snappy(duration: 0.32), value: lensX)
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
                                .position(x: lensX + slotWidth / 2, y: inset + slotHeight / 2)
                        }
                        .animation(.interactiveSpring(response: 0.18), value: lensX)
                        .allowsHitTesting(false)
                        .zIndex(3)
                }
            }
            .contentShape(Capsule())
            .gesture(barGesture(slotWidth: slotWidth))
        }
        .frame(height: barHeight)
        .glassEffect(.regular, in: .capsule)
    }

    private func iconRow(slotWidth: CGFloat, slotHeight: CGFloat, dragging: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                slot(tab, dragging: dragging).frame(width: slotWidth, height: slotHeight)
            }
        }
        .padding(inset)
    }

    /// One tab: a large icon on its own, or a smaller icon over its label when it is selected
    /// (no labels at all while the lens is being dragged, like the system bar).
    @ViewBuilder private func slot(_ tab: AppModel.AppTab, dragging: Bool) -> some View {
        let selected = model.selectedTab == tab
        let labelled = selected && !dragging
        VStack(spacing: 2) {
            icon(for: tab, size: labelled ? 21 : 25)
                .frame(height: labelled ? 24 : 30)
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
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { select(tab) }
    }

    /// A press moves the lens under the finger once it is held for a moment or slides sideways;
    /// the page switches as the lens passes each tab. A quick press is a tap on that tab.
    private func barGesture(slotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if pressStart == nil { pressStart = Date() }
                let held = Date().timeIntervalSince(pressStart ?? Date()) > 0.22
                let slid = abs(v.translation.width) > 8
                guard dragX != nil || held || slid else { return }
                if dragX == nil { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                dragX = v.location.x
                if let tab = tab(at: v.location.x, slotWidth: slotWidth), tab != model.selectedTab {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.snappy(duration: 0.28)) { model.selectedTab = tab }
                }
            }
            .onEnded { v in
                if dragX == nil, let tab = tab(at: v.location.x, slotWidth: slotWidth) { select(tab) }
                dragX = nil
                pressStart = nil
            }
    }

    private func tab(at x: CGFloat, slotWidth: CGFloat) -> AppModel.AppTab? {
        let i = Int((x - inset) / slotWidth)
        return tabs.indices.contains(i) ? tabs[i] : (x < inset ? tabs.first : tabs.last)
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
    var tab: AppModel.AppTab
    func body(content: Content) -> some View {
        content
            .onAppear { model.tabAtRoot[tab] = true }
            .onDisappear { model.tabAtRoot[tab] = false }
            .background(PopToRootProbe(tab: tab))
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
