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
/// into a shape seen before, draws them where they last stood; before any, where the system stood them when measured
/// (`fallbackTops`). Only a settled place is kept (`Settle`).
@MainActor @Observable final class StripMarkers {
    static let shared = StripMarkers()
    enum Kind: String { case back, more }
    /// The markers' frames, window space, by `key`, then kind.
    private(set) var byShape: [String: [String: CGRect]]
    /// On the Duo's side or as a book, the chat on show and whether Back's marker is there (`ConversationView`), for the
    /// touch catchers over the system's floating bar (`SideStripCatchers`); nil anywhere else.
    struct Side: Equatable { let chat: ObjectIdentifier; var withBack: Bool }
    var side: Side?
    /// The catcher being pressed, so the page's Back or More under it shows the press, as closed's controls press
    /// (`StripPressMirror`).
    var pressed: Kind?
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

    /// Where the system stands the markers, for a shape none is read for yet: our 44 pt capsules' tops, centred on the
    /// system's own items (38 by 48) as measured on the Duo (2026-10-31) at default text with no Live Activity. Closed,
    /// the items at 238 and 308, so 240 and 310; at XXXL at 244 and 314, so 246 and 316. On its side with Back, 125 and
    /// 195, so 127 and 197; More alone beside the list at 125 (at XXXL too), so 127. Nothing else is measured (on its
    /// side with Back at XXXL, the other text sizes): those take the default. A first open with a Live Activity already
    /// up still steps once, 80 pt closed and 92 on its side, as no inset follows the status.
    nonisolated static func fallbackTops(closed: Bool, withBack: Bool, xxxl: Bool) -> [CGFloat] {
        if closed { return xxxl ? [246, 316] : [240, 310] }
        return withBack ? [127, 197] : [127]
    }

    /// A marker's middle, window space: its settled place for the window's shape (with Back's marker there or not), else
    /// where the system stood it when measured (`fallbackTops`), in the strip's middle line.
    func centre(_ kind: Kind, in g: WindowGeometry, withBack: Bool, closed: Bool, xxxl: Bool) -> CGPoint {
        let key = Self.key(shape: SystemBarItems.shapeKey(size: g.bounds.size, safeTop: g.safeArea.top, safeTrailing: g.safeArea.trailing), withBack: withBack)
        if let f = frame(kind, for: key) { return CGPoint(x: f.midX, y: f.midY) }
        let tops = Self.fallbackTops(closed: closed, withBack: withBack, xxxl: xxxl)
        let x = g.safeArea.trailing >= g.safeArea.leading ? g.bounds.width - VoryTabBar.stripCentreFromEdge : VoryTabBar.stripCentreFromEdge
        return CGPoint(x: x, y: (kind == .more && withBack ? tops[1] : tops[0]) + 22)
    }

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
/// rebuilds it). Never seen and never a control: no tint, no glass, out of VoiceOver, no action, and their views at
/// alpha 0, out of the hit test and, with everything under them, out of accessibility (`markerViews`,
/// `takeAccessibility`). On its side the system draws them in the split view's floating bar, over the page, where they
/// still took the taps meant for our Back and More; the catchers above it take those (`SideStripCatchers`, the
/// diagnosis, 2026-10-31). Each is read in the window (`frame(in:)`) on the layout, safe-area and margin passes of the
/// page, its navigation controller, its bar, the split view and the window, and on the strip's trait changes, and kept
/// once settled; after the items change or Back comes or goes they're read again a moment later, as the split lays its
/// strip out again with no event of ours (the diagnosis).
struct StripMarkerReader: UIViewControllerRepresentable {
    /// Whether Back's marker is there: not while the list stands beside the chat. The chat page says so from where its
    /// pane starts, as the header does (`ChatHeader.listBeside`): the page controller spans the window there, the list a
    /// safe-area inset beside the pane, so its own frame can't tell.
    var back: Bool

    func makeUIViewController(context: Context) -> Reader { Reader() }

    func updateUIViewController(_ reader: Reader, context: Context) {
        reader.geometry = context.environment.windowGeometry
        reader.back = back
        reader.read()
    }

    /// Our items as a page's groups (Back only when asked), set again only if anything replaced them, so a read never
    /// lays the bar out again by itself. True when it set them.
    @discardableResult @MainActor
    static func install(on i: UINavigationItem, back: Bool, backItem: UIBarButtonItem, moreItem: UIBarButtonItem) -> Bool {
        var changed = false
        let lead = back ? [backItem] : []
        if !i.leadingItemGroups.flatMap(\.barButtonItems).elementsEqual(lead, by: ===) {
            i.leadingItemGroups = back ? [UIBarButtonItemGroup(barButtonItems: lead, representativeItem: nil)] : []
            changed = true
        }
        if !i.trailingItemGroups.flatMap(\.barButtonItems).elementsEqual([moreItem], by: ===) {
            i.trailingItemGroups = [UIBarButtonItemGroup(barButtonItems: [moreItem], representativeItem: nil)]
            changed = true
        }
        return changed
    }

    /// The views the system draws our markers with, under `root` (at most `depth` levels down): a control with the marker's
    /// label whose window frame is the marker's, within a point. Only our items' own views match: a label alone, or the
    /// frame alone, never does.
    @MainActor static func markerViews(in root: UIView, targets: [(title: String, frame: CGRect)], depth: Int = 40) -> [UIView] {
        var found: [UIView] = []
        func near(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
        }
        func walk(_ v: UIView, _ level: Int) {
            if v is UIControl, let label = v.accessibilityLabel {
                let f = v.convert(v.bounds, to: nil)
                if targets.contains(where: { $0.title == label && near($0.frame, f) }) { found.append(v) }
            }
            guard level < depth else { return }
            v.subviews.forEach { walk($0, level + 1) }
        }
        walk(root, 0)
        return found
    }

    /// A view's accessibility as it stood before the markers' rule took it, to give back (`giveAccessibility`).
    struct TakenAccessibility { weak var view: UIView?; let element: Bool; let hidden: Bool }

    /// The markers' views and everything under them out of accessibility. The item's own settings don't reach its
    /// views: the label inside each ('Back', 'More') stood as an element, the likely source of an audit finding with no
    /// element the markers brought (the accessibility audit, 2026-10-31). Set every time, as the system can rebuild
    /// them; each view's settings as they were are returned the first time it's taken (`taken` holds those already
    /// recorded).
    @MainActor static func takeAccessibility(from views: [UIView], taken: [TakenAccessibility] = []) -> [TakenAccessibility] {
        var out: [TakenAccessibility] = []
        func walk(_ v: UIView) {
            if !taken.contains(where: { $0.view === v }), !out.contains(where: { $0.view === v }) {
                out.append(TakenAccessibility(view: v, element: v.isAccessibilityElement, hidden: v.accessibilityElementsHidden))
            }
            v.isAccessibilityElement = false
            v.accessibilityElementsHidden = true
            v.subviews.forEach(walk)
        }
        views.forEach(walk)
        return out
    }

    /// The views' accessibility given back as it stood.
    @MainActor static func giveAccessibility(_ taken: [TakenAccessibility]) {
        for t in taken {
            guard let v = t.view else { continue }
            v.isAccessibilityElement = t.element
            v.accessibilityElementsHidden = t.hidden
        }
    }

    final class Reader: UIViewController {
        weak var geometry: WindowGeometry?
        var back = true
        private let backItem = Reader.item("Back", "chevron.left"), moreItem = Reader.item("Chat options", "ellipsis")
        private var settles: [StripMarkers.Kind: StripMarkers.Settle] = [:]
        private var checks: [StripMarkers.Kind: Task<Void, Never>] = [:]
        private var watchers: [Watcher] = []
        private var lastKey: String?
        private var lastBack: Bool?
        private var again: Task<Void, Never>?
        private var axTaken: [StripMarkerReader.TakenAccessibility] = []

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
            for host in [navigationController?.view, navigationController?.navigationBar, splitViewController?.view, view.window as UIView?] {
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
            again?.cancel()
            again = nil
            StripMarkerReader.giveAccessibility(axTaken)
            axTaken = []
            if let i = page()?.navigationItem {
                if i.leadingItemGroups.flatMap(\.barButtonItems).contains(where: { $0 === backItem }) { i.leadingItemGroups = [] }
                if i.trailingItemGroups.flatMap(\.barButtonItems).contains(where: { $0 === moreItem }) { i.trailingItemGroups = [] }
            }
        }

        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); read() }
        override func viewSafeAreaInsetsDidChange() { super.viewSafeAreaInsetsDidChange(); read() }
        override func viewLayoutMarginsDidChange() { super.viewLayoutMarginsDidChange(); read() }

        /// The page whose bar carries the markers: the controller among its navigation controller's (on its side, the
        /// one that holds the list and the chat beside it).
        private func page() -> UIViewController? {
            var vc: UIViewController? = self
            while let c = vc, !(c.navigationController?.viewControllers.contains(c) ?? false) { vc = c.parent }
            return vc
        }

        /// On every event: our items in place, then each marker read; a changed place is read again once `delay` has passed.
        func read() {
            guard let page = page(), let window = view.window else { return }
            let changed = StripMarkerReader.install(on: page.navigationItem, back: back, backItem: backItem, moreItem: moreItem)
            let flipped = lastBack.map { $0 != back } ?? false
            lastBack = back
            #if DEBUG
            if !back, MorphFramesProbe.isOn { MorphFramesProbe.marks["markerBack"] = nil }
            #endif
            if changed || flipped { readAgain() }
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

        /// The items changed, or Back came or went: read again, and hide the markers' views, a quarter second and a second
        /// later, whether or not an event comes (the split lays its strip out again with none of ours).
        private func readAgain() {
            again?.cancel()
            again = Task { @MainActor [weak self] in
                for wait in [StripMarkers.Settle.delay, 0.75] {
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled, let self else { return }
                    self.read()
                    if let window = self.view.window { self.hideViews(in: window) }
                }
            }
        }

        /// Our markers' views at alpha 0, out of the hit test and out of accessibility, found under the split view (or the
        /// navigation controller's view) by `markerViews`. Only after the items change, Back comes or goes, or a place is kept.
        private func hideViews(in window: UIWindow) {
            guard let root = splitViewController?.view ?? navigationController?.view else { return }
            let kinds: [StripMarkers.Kind] = back ? [.back, .more] : [.more]
            let targets = kinds.compactMap { k in item(k).frame(in: window).flatMap { $0.width > 0 ? (item(k).title ?? "", $0) : nil } }
            let views = StripMarkerReader.markerViews(in: root, targets: targets)
            views.forEach { $0.alpha = 0; $0.isUserInteractionEnabled = false }
            axTaken.removeAll { $0.view == nil }
            axTaken += StripMarkerReader.takeAccessibility(from: views, taken: axTaken)
            #if DEBUG
            // For the bar's checks: how many of the laid-out markers' views were found and hidden (the readout's "stripHide":
            // found, then laid out).
            NSLog("STRIPHIDE found %ld of %ld", views.count, targets.count)
            if MorphFramesProbe.isOn { MorphFramesProbe.marks["stripHide"] = CGRect(x: views.count, y: targets.count, width: 1, height: 1) }
            #endif
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
                guard !Task.isCancelled, let self, let window = self.view.window else { return }
                guard let key = self.key(back: self.back, in: window), key == self.lastKey else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.settles[kind, default: .init()].note(self.place(kind, in: window), at: now) { self.check(kind); return }
                guard let f = self.settles[kind]?.due(at: now) else { return }
                #if DEBUG
                MorphFramesProbe.note(kind == .back ? "markerBack" : "markerMore", f)
                #endif
                StripMarkers.shared.settled(kind, f, for: key)
                self.hideViews(in: window)
            }
        }
    }

    /// A view the size of its host (the navigation controller's view, its bar, the split view, the window), resized with it, never seen or
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

/// Touch catchers over the system's floating bar on the Duo's side and as a book (#555): there the strip's markers stand in
/// the split view's own floating bar, over the chat's page, and its views took the taps meant for our Back and More, which
/// the page draws under it (the diagnosis, 2026-10-31). Two clear 44 pt targets at their places, above the bar: Back's sends
/// the chat its back request, as the page's own Back does; More's is the same menu sending the chat its requests, so it
/// opens where More stands. Never seen and out of VoiceOver: the page's Back and More stay the elements, in 44's order, and
/// show the press (`StripPressMirror`). Only while a chat shows there (`StripMarkers.side`).
struct SideStripCatchers: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowGeometry) private var windowGeometry
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if let side = StripMarkers.shared.side, let chat = model.visibleChat, ObjectIdentifier(chat) == side.chat {
            GeometryReader { proxy in
                let o = proxy.frame(in: .global).origin, g = windowGeometry, xxxl = typeSize == .xxxLarge
                let more = StripMarkers.shared.centre(.more, in: g, withBack: side.withBack, closed: false, xxxl: xxxl)
                ZStack(alignment: .topLeading) {
                    if side.withBack {
                        let back = StripMarkers.shared.centre(.back, in: g, withBack: true, closed: false, xxxl: xxxl)
                        Button { model.chatRequest = .init(.back) } label: { Self.target }
                            .buttonStyle(StripCatcherStyle(kind: .back))
                            .position(x: back.x - o.x, y: back.y - o.y)
                    }
                    Menu {
                        ChatMenuItems(chat: chat, onProfile: { model.chatRequest = .init(.profile) }, onRename: { model.chatRequest = .init(.rename) },
                                      onContext: { model.chatRequest = .init(.context) }, onNewChat: { model.chatRequest = .init(.newChat) },
                                      onClose: { model.chatRequest = .init(.close) })
                            // The menu showing ends the press, as closed's More shows none while its menu is up; the
                            // catcher's own press wasn't let go then (2026-10-31). Its going clears it too.
                            .onAppear { StripMarkers.shared.pressed = nil }
                            .onDisappear { StripMarkers.shared.pressed = nil }
                    } label: { Self.target }
                    .menuStyle(.button).buttonStyle(StripCatcherStyle(kind: .more))
                    .position(x: more.x - o.x, y: more.y - o.y)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
            .accessibilityHidden(true)
            // A press the catchers' going cut short leaves no control grown.
            .onDisappear { StripMarkers.shared.pressed = nil }
        }
    }

    /// A 44 pt round target, clear: its shape takes the touch.
    private static var target: some View { Color.clear.frame(width: 44, height: 44).contentShape(.circle) }
}

/// A catcher's press, passed to the page's control under it (`StripMarkers.pressed`); the catcher itself draws nothing.
struct StripCatcherStyle: ButtonStyle {
    let kind: StripMarkers.Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onChange(of: configuration.isPressed) { _, pressed in
            if pressed { StripMarkers.shared.pressed = kind } else if StripMarkers.shared.pressed == kind { StripMarkers.shared.pressed = nil }
        }
    }
}

/// The press of the catcher over this control (`SideStripCatchers`), in our bar's press look (`MorphPressStyle`: the fill
/// and the grow, Reduce Motion the fill alone, none with `-vory-press-style-off`), as closed's controls press.
struct StripPressMirror: ViewModifier {
    let kind: StripMarkers.Kind
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let pressed = StripMarkers.shared.pressed == kind && !MorphPressStyle.off
        content
            .scaleEffect(pressed && !reduceMotion ? MorphPressStyle.pressedScale : 1)
            .background { Circle().fill(MorphPressStyle.fill(scheme)).padding(3).opacity(pressed ? 1 : 0) }
            .animation(.easeOut(duration: pressed ? 0.08 : 0.2), value: pressed)
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
