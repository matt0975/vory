#if os(iOS)
import SwiftUI
import UIKit

/// Where UIKit stands its own navigation bar items in the window (#554, #555), read off a navigation bar that is laid out
/// but never seen. On the Duo our top bar's last control ends where UIKit's trailing item ends: beside the status up in
/// the band, where UIKit moves it 92 pt clear when another app's Live Activity widens the status, and nothing the app can
/// read says so (the safe area, the status bar's frame and the reserved regions read the same with and without; the
/// probe, 2026-10-29); and beside the strip closed and on its side, where UIKit never puts its items in the strip. A real
/// item would need the system's bar in each chat and lose the morph between the list and a chat (#542). Kept per window
/// shape (`shapeKey`) and across launches, so a launch, or a turn into a shape seen before, draws the rows where the bar
/// last stood rather than stepping sideways once it's read; nil for a shape never read. Until a fresh layout, the last
/// place stands.
@MainActor @Observable final class SystemBarItems {
    static let shared = SystemBarItems()
    /// The trailing item's frame, window space, by window shape.
    private(set) var trailingByShape: [String: CGRect]
    @ObservationIgnored private let defaults: UserDefaults
    private static let storeKey = "vory.systemBarItems.trailing"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.storeKey) as? [String: [Double]] ?? [:]
        trailingByShape = stored.compactMapValues { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        loadLaunchState()
    }

    /// A window shape: its size, and the safe area's top and trailing, which tell the Duo's postures apart.
    nonisolated static func shapeKey(size: CGSize, safeTop: CGFloat, safeTrailing: CGFloat) -> String {
        String(format: "%.0fx%.0f t%.0f r%.0f", size.width, size.height, safeTop, safeTrailing)
    }

    func trailing(for shape: String) -> CGRect? { trailingByShape[shape] }

    /// A fresh read for a shape, kept for the next launch.
    func read(_ frame: CGRect, for shape: String) {
        guard trailingByShape[shape] != frame else { return }
        trailingByShape[shape] = frame
        defaults.set(trailingByShape.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }, forKey: Self.storeKey)
    }

    // A launch's first second (#554): the window is read about 0.2 s in and the fold about a second in, and until then the
    // rows stood as on a phone, then stepped up and sideways (122 pt upright, 88 closed; the launch probe, 2026-10-31).
    // So the Duo's last settled window, and whether the bar stood up in the band for each shape, are kept too, and a
    // launch lays out in them until the live ones come. A Duo turned while the app was closed takes one step, as before.

    /// Whether the bar stood up in the status band (`TopBarRoom.barUp`), by window shape, as the fold last said.
    private(set) var upByShape: [String: Bool] = [:]
    /// Whether the window was the closed strip (`MorphTopBar.stripClosed`: the system's bars vertical beside it), by shape.
    private(set) var closedByShape: [String: Bool] = [:]
    private static let closedKey = "vory.systemBarItems.closed"

    func closed(for shape: String) -> Bool? { closedByShape[shape] }

    /// The strip's verdict for a shape, kept for the next launch.
    func noteClosed(_ closed: Bool, for shape: String) {
        guard closedByShape[shape] != closed else { return }
        closedByShape[shape] = closed
        defaults.set(closedByShape, forKey: Self.closedKey)
    }
    /// The Duo's window as last settled: its size and safe area.
    private(set) var lastWindow: (size: CGSize, safeArea: EdgeInsets)?
    private static let upKey = "vory.systemBarItems.up"
    private static let windowKey = "vory.systemBarItems.window"

    func up(for shape: String) -> Bool? { upByShape[shape] }

    /// The fold's verdict for a shape, kept for the next launch.
    func noteUp(_ up: Bool, for shape: String) {
        guard upByShape[shape] != up else { return }
        upByShape[shape] = up
        defaults.set(upByShape, forKey: Self.upKey)
    }

    /// A settled window on the Duo, kept for the next launch.
    func settled(size: CGSize, safeArea s: EdgeInsets) {
        guard size.width > 0, size.height > 0, lastWindow?.size != size || lastWindow?.safeArea != s else { return }
        lastWindow = (size, s)
        defaults.set([size.width, size.height, s.top, s.leading, s.bottom, s.trailing].map { Double($0) }, forKey: Self.windowKey)
    }

    private func loadLaunchState() {
        upByShape = defaults.dictionary(forKey: Self.upKey) as? [String: Bool] ?? [:]
        closedByShape = defaults.dictionary(forKey: Self.closedKey) as? [String: Bool] ?? [:]
        if let w = defaults.array(forKey: Self.windowKey) as? [Double], w.count == 6 {
            lastWindow = (CGSize(width: w[0], height: w[1]), EdgeInsets(top: w[2], leading: w[3], bottom: w[4], trailing: w[5]))
        }
    }

    /// The window's geometry for a launch's first frames: on the Duo, its last settled window, marked `seeded` until the
    /// reader measures the live one; elsewhere (never seen on the Duo) empty, as before.
    func launchGeometry() -> WindowGeometry {
        let g = WindowGeometry()
        if let w = lastWindow {
            g.bounds = CGRect(origin: .zero, size: w.size)
            g.safeArea = w.safeArea
            g.seeded = true
        }
        return g
    }
}

/// Where the system lays out a chat page's two markers in the Duo's side strip, closed and on its side (#555): bar items of
/// ours (`StripMarkerReader`), never seen, that the system stands under the status and moves down with it as Live Activities
/// arrive, which nothing else the app can read follows (the probes, 2026-10-31: one activity moved the status 84 pt and the
/// items 80 closed; no safe area, margin or status bar frame says where the status ends). A chat's Back and More are drawn
/// centred on them (`MorphTopBar.columnFrame`, `ChatHeader.messagesSide`). Kept per window shape, and whether Back is
/// there (beside the list on its side it isn't, and More takes Back's place), and across launches, so a launch, or a turn
/// into a shape seen before, draws them where they last stood. Only a settled place is kept (`Settle`).
@MainActor @Observable final class StripMarkers {
    static let shared = StripMarkers()
    enum Kind: String { case back, more }
    /// The markers' frames, window space, by `key`, then kind.
    private(set) var byShape: [String: [String: CGRect]]
    @ObservationIgnored private let defaults: UserDefaults
    private static let storeKey = "vory.stripMarkers"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.storeKey) as? [String: [String: [Double]]] ?? [:]
        byShape = stored.mapValues { $0.compactMapValues { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil } }
    }

    /// A window shape (`SystemBarItems.shapeKey`) with or without Back's marker: More stands in Back's place without it.
    nonisolated static func key(shape: String, withBack: Bool) -> String { withBack ? shape : shape + " solo" }

    func frame(_ kind: Kind, for key: String) -> CGRect? { byShape[key]?[kind.rawValue] }

    /// Whether a frame (window space) stands in the window's side strip: its middle inside the safe area's inset on the
    /// strip's side.
    nonisolated static func inStrip(_ frame: CGRect, windowWidth: CGFloat, safeLeading: CGFloat, safeTrailing: CGFloat) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        if safeTrailing >= safeLeading { return frame.midX > windowWidth - safeTrailing && frame.midX < windowWidth }
        return frame.midX > 0 && frame.midX < safeLeading
    }

    /// A marker's settled place, kept for its key and the next launch. A move while the app runs (an activity arriving or
    /// leaving, a turn) is animated, as the system moves its own items.
    func settled(_ kind: Kind, _ frame: CGRect, for key: String) {
        guard byShape[key]?[kind.rawValue] != frame else { return }
        if byShape[key]?[kind.rawValue] == nil { byShape[key, default: [:]][kind.rawValue] = frame }
        else { withAnimation(.snappy(duration: 0.3)) { byShape[key, default: [:]][kind.rawValue] = frame } }
        defaults.set(byShape.mapValues { $0.mapValues { [$0.minX, $0.minY, $0.width, $0.height] } }, forKey: Self.storeKey)
    }

    /// When a marker's place has settled. The system passes through places on its way to one: closing mid-session, its
    /// items stood at 175 for 142 ms on their way to 238 (the probe, 2026-10-31). So a place is taken once it stands in the
    /// strip and a read `delay` after the last change still finds it there; a read that differs, or one off the strip
    /// (nil), starts the wait again. A place the system stops at is taken, whatever it is (after a turn from its side,
    /// closed, the system's items stayed at 175, and ours stand there with them).
    struct Settle: Equatable {
        static let delay: TimeInterval = 0.25
        /// The last place read (nil: off the strip or not laid out), and when it was first read.
        private(set) var place: CGRect?
        private(set) var since: TimeInterval = 0

        /// A read at `time`; true when it changed the place (the caller reads again `delay` later).
        mutating func note(_ frame: CGRect?, at time: TimeInterval) -> Bool {
            guard frame != place else { return false }
            place = frame
            since = time
            return true
        }

        /// The place, once it has stood `delay` with no change (a millisecond's grace for the timer); nil before, or off
        /// the strip.
        func due(at time: TimeInterval) -> CGRect? {
            guard let place, time - since >= Self.delay - 0.001 else { return nil }
            return place
        }
    }
}

/// A chat page's markers in the Duo's side strip (`StripMarkers`), closed and on its side: bar items of ours, Back (not
/// while the list stands beside the chat on its side) and Chat options, each an icon and a title, as Apple's iPhone Duo
/// notes ask (a custom view never goes vertical, and SwiftUI's toolbar items report no window frame: the probes,
/// 2026-10-31). They're the chat page's own item groups, put back whenever the page's navigation item is rebuilt (a turn
/// rebuilds it). Never seen and never a control: no tint, no glass, out of VoiceOver, no action; our Back and More stand
/// over them and take the taps. Each is read in the window (`frame(in:)`) on the layout, safe-area and margin passes of the
/// page, its navigation controller, its bar and the window, and on the strip's trait changes, and kept once settled.
struct StripMarkerReader: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Reader { Reader() }

    func updateUIViewController(_ reader: Reader, context: Context) {
        reader.geometry = context.environment.windowGeometry
        reader.read()
    }

    final class Reader: UIViewController {
        weak var geometry: WindowGeometry?
        private let backItem = Reader.item("Back", "chevron.left"), moreItem = Reader.item("Chat options", "ellipsis")
        private var settles: [StripMarkers.Kind: StripMarkers.Settle] = [:]
        private var checks: [StripMarkers.Kind: Task<Void, Never>] = [:]
        private var watchers: [Watcher] = []
        private var lastKey: String?

        private func item(_ kind: StripMarkers.Kind) -> UIBarButtonItem { kind == .back ? backItem : moreItem }

        private static func item(_ title: String, _ symbol: String) -> UIBarButtonItem {
            let item = UIBarButtonItem(title: title, image: UIImage(systemName: symbol))
            item.tintColor = .clear
            item.hidesSharedBackground = true
            item.isAccessibilityElement = false
            item.accessibilityElementsHidden = true
            return item
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            if #available(iOS 27.1, *) {
                registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (r: Reader, _: UITraitCollection) in r.read() }
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            for host in [navigationController?.view, navigationController?.navigationBar, view.window as UIView?] {
                guard let host else { continue }
                let w = Watcher(frame: host.bounds)
                w.onEvent = { [weak self] in self?.read() }
                host.insertSubview(w, at: 0)
                watchers.append(w)
            }
            read()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            watchers.forEach { $0.removeFromSuperview() }
            watchers = []
            checks.values.forEach { $0.cancel() }
            checks = [:]
            settles = [:]
            if let i = page()?.navigationItem {
                if i.leadingItemGroups.flatMap(\.barButtonItems).contains(where: { $0 === backItem }) { i.leadingItemGroups = [] }
                if i.trailingItemGroups.flatMap(\.barButtonItems).contains(where: { $0 === moreItem }) { i.trailingItemGroups = [] }
            }
        }

        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); read() }
        override func viewSafeAreaInsetsDidChange() { super.viewSafeAreaInsetsDidChange(); read() }
        override func viewLayoutMarginsDidChange() { super.viewLayoutMarginsDidChange(); read() }

        /// The chat page: the controller among its navigation controller's.
        private func page() -> UIViewController? {
            var vc: UIViewController? = self
            while let c = vc, !(c.navigationController?.viewControllers.contains(c) ?? false) { vc = c.parent }
            return vc
        }

        /// Whether the list stands beside the chat (on its side): the page starts past the window's leading safe edge.
        private func listBeside(_ page: UIViewController, in window: UIWindow) -> Bool {
            page.view.convert(page.view.bounds, to: nil).minX > window.safeAreaInsets.left + 1
        }

        /// Our items as the page's groups, set again if anything replaced them.
        private func install(on i: UINavigationItem, back: Bool) {
            let lead = back ? [backItem] : []
            if !i.leadingItemGroups.flatMap(\.barButtonItems).elementsEqual(lead, by: ===) {
                i.leadingItemGroups = back ? [UIBarButtonItemGroup(barButtonItems: lead, representativeItem: nil)] : []
            }
            if !i.trailingItemGroups.flatMap(\.barButtonItems).elementsEqual([moreItem], by: ===) {
                i.trailingItemGroups = [UIBarButtonItemGroup(barButtonItems: [moreItem], representativeItem: nil)]
            }
        }

        /// On every event: our items in place, then each marker read; a changed place is read again once `delay` has passed.
        func read() {
            guard let page = page(), let window = view.window else { return }
            let back = !listBeside(page, in: window)
            install(on: page.navigationItem, back: back)
            #if DEBUG
            if !back, MorphFramesProbe.isOn { MorphFramesProbe.marks["markerBack"] = nil }
            #endif
            guard let key = key(back: back, in: window) else { return }
            if key != lastKey {
                lastKey = key
                checks.values.forEach { $0.cancel() }
                checks = [:]
                settles = [:]
            }
            for kind in [StripMarkers.Kind.back, .more] where kind == .more || back {
                if settles[kind, default: .init()].note(place(kind, in: window), at: ProcessInfo.processInfo.systemUptime) { check(kind) }
            }
        }

        /// The marker's key, while the window is the one the app has settled (not a launch's seeded window, nor a turn's
        /// passing one); nil otherwise.
        private func key(back: Bool, in window: UIWindow) -> String? {
            guard let g = geometry, !g.seeded, !g.holding, window.bounds.size == g.bounds.size else { return nil }
            return StripMarkers.key(shape: SystemBarItems.shapeKey(size: g.bounds.size, safeTop: g.safeArea.top, safeTrailing: g.safeArea.trailing), withBack: back)
        }

        /// A marker's window frame when it stands in the strip; nil otherwise.
        private func place(_ kind: StripMarkers.Kind, in window: UIWindow) -> CGRect? {
            guard let g = geometry, let f = item(kind).frame(in: window) else { return nil }
            #if DEBUG
            // For the bar's checks: where the system laid the marker out (the frames readout's "markerBack", "markerMore").
            if MorphFramesProbe.isOn { MorphFramesProbe.marks[kind == .back ? "markerBack" : "markerMore"] = f.width > 0 ? f : nil }
            #endif
            return StripMarkers.inStrip(f, windowWidth: g.bounds.width, safeLeading: g.safeArea.leading, safeTrailing: g.safeArea.trailing) ? f : nil
        }

        /// `delay` after a change, the marker read again: the same place is kept; a new one waits again.
        private func check(_ kind: StripMarkers.Kind) {
            checks[kind]?.cancel()
            checks[kind] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(StripMarkers.Settle.delay))
                guard !Task.isCancelled, let self, let page = self.page(), let window = self.view.window else { return }
                let back = !self.listBeside(page, in: window)
                guard let key = self.key(back: back, in: window), key == self.lastKey else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.settles[kind, default: .init()].note(self.place(kind, in: window), at: now) { self.check(kind); return }
                guard let f = self.settles[kind]?.due(at: now) else { return }
                #if DEBUG
                MorphFramesProbe.note(kind == .back ? "markerBack" : "markerMore", f)
                #endif
                StripMarkers.shared.settled(kind, f, for: key)
            }
        }
    }

    /// A view the size of its host (the navigation controller's view, its bar, the window), resized with it, never seen or
    /// touched: its layout passes and safe-area and margin changes are when the system moves its items (a turn, a Live
    /// Activity widening the status).
    final class Watcher: UIView {
        var onEvent: (() -> Void)?
        override init(frame: CGRect) {
            super.init(frame: frame)
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() { super.layoutSubviews(); onEvent?() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); onEvent?() }
        override func layoutMarginsDidChange() { super.layoutMarginsDidChange(); onEvent?() }
    }
}

/// The bar the items are read off, from the first time the window is one of the Duo's (the bar up in the status band,
/// or the side strip) and from then on, so a turn never waits for it. Never on an iPhone or an iPad, where nothing reads
/// it and the bars stand where they did.
struct SystemBarItemsHost: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowGeometry) private var windowGeometry
    @Environment(\.reservedRegions) private var regions
    @Environment(\.scenePhase) private var scenePhase
    @State private var duo = false

    var body: some View {
        let g = windowGeometry
        let key = SystemBarItems.shapeKey(size: g.bounds.size, safeTop: g.safeArea.top, safeTrailing: g.safeArea.trailing)
        let read = !regions.reported.isEmpty, live = TopBarRoom.barUp(regions: regions, size: g.bounds.size, safeTop: g.safeArea.top)
        let up = TopBarRoom.barUpAtLaunch(live: live, regionsRead: read, remembered: SystemBarItems.shared.up(for: key))
        let now = VoryTabBar.statusStrip(g.safeArea) != nil || up
        ZStack {
            if duo || now {
                SystemBarItemsSensor(geometry: g, size: g.bounds.size, safeArea: g.safeArea, active: scenePhase == .active, holding: g.holding)
                    .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onChange(of: now, initial: true) { _, d in if d { duo = true } }
        // What a launch lays out in before the live window and fold come (`SystemBarItems.launchGeometry`,
        // `TopBarRoom.barUpAtLaunch`): only what was read live, settled and in front, and only on the Duo.
        .onChange(of: Settled(key: key, safe: g.safeArea, read: read, live: live,
                              closed: model.tabBarVertical && VoryTabBar.statusStrip(g.safeArea) != nil,
                              measured: !g.seeded && !g.holding && g.bounds.width > 0, front: scenePhase == .active, duo: duo || now),
                  initial: true) { _, s in
            guard s.measured, s.front, s.duo else { return }
            SystemBarItems.shared.settled(size: g.bounds.size, safeArea: g.safeArea)
            // By the time the regions are read the system has said where its bars stand (0.1 s in, against about a second).
            if s.read {
                SystemBarItems.shared.noteUp(s.live, for: s.key)
                SystemBarItems.shared.noteClosed(s.closed, for: s.key)
            }
        }
    }

    private struct Settled: Equatable {
        var key: String, safe: EdgeInsets, read: Bool, live: Bool, closed: Bool, measured: Bool, front: Bool, duo: Bool
    }
}

/// A UINavigationController with a 44 pt item at each end, the window's size, never seen, hit or read by VoiceOver. Its
/// bar reads the trailing item's frame after each of its layouts; a change of the window, the scene coming back, or a
/// turn's hold ending lays it out again. Only a bar laid out in the window as the app has it settled is read: none while
/// the window's reader holds back a turn's passing window (`WindowGeometry.holding`), and none whose window isn't the
/// size the reader has published. The rows then hold their place with the window, the bar's edge and everything else
/// read from it (#548), and take the settled place when the hold ends.
private struct SystemBarItemsSensor: UIViewControllerRepresentable {
    var geometry: WindowGeometry
    var size: CGSize
    var safeArea: EdgeInsets
    var active: Bool
    var holding: Bool

    func makeUIViewController(context: Context) -> UINavigationController {
        let nav = UINavigationController(navigationBarClass: Bar.self, toolbarClass: nil)
        nav.viewControllers = [Root()]
        nav.view.isUserInteractionEnabled = false
        nav.view.accessibilityElementsHidden = true
        return nav
    }

    func updateUIViewController(_ nav: UINavigationController, context: Context) {
        (nav.navigationBar as? Bar)?.geometry = geometry
        nav.navigationBar.setNeedsLayout()
        (nav.navigationBar as? Bar)?.readSoon()
    }

    private final class Root: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            navigationItem.largeTitleDisplayMode = .never
            navigationItem.leftBarButtonItem = UIBarButtonItem(customView: Self.item())
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: Self.item())
        }

        static func item() -> UIView {
            let v = UIView()
            v.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([v.widthAnchor.constraint(equalToConstant: 44), v.heightAnchor.constraint(equalToConstant: 44)])
            return v
        }
    }

    /// The items are placed by the bar's own content views after its layoutSubviews, so they're read on the next turn.
    private final class Bar: UINavigationBar {
        weak var geometry: WindowGeometry?

        override func layoutSubviews() {
            super.layoutSubviews()
            readSoon()
        }

        func readSoon() {
            Task { @MainActor [weak self] in self?.read() }
        }

        private func read() {
            guard let geometry, !geometry.holding, !geometry.seeded, let window, window.bounds.size == geometry.bounds.size,
                  let view = topItem?.rightBarButtonItem?.customView, view.window != nil else { return }
            let frame = view.convert(view.bounds, to: nil)
            guard frame.width > 0 else { return }
            let key = SystemBarItems.shapeKey(size: geometry.bounds.size, safeTop: geometry.safeArea.top, safeTrailing: geometry.safeArea.trailing)
            #if DEBUG
            // The launch probe (#554): UIKit's item when it's first read for a shape, or moves.
            if SystemBarItems.shared.trailing(for: key) != frame { MorphFramesProbe.note("sysitem", frame) }
            #endif
            SystemBarItems.shared.read(frame, for: key)
            #if DEBUG
            // For the bar's checks: where our row's last control must end (the frames readout's "system").
            if MorphFramesProbe.isOn { MorphFramesProbe.marks["system"] = frame }
            #endif
        }
    }
}
#endif
