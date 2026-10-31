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
