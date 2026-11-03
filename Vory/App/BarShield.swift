#if os(iOS)
import os
import SwiftUI
import UIKit

/// The tab bar and the top bar keep their touches from the glass of the page behind them (#344).
///
/// Liquid Glass's `.interactive()` reacts through a pan recognizer on the window
/// (`_UIFlexInteractionPanGestureRecognizer`), which finds glass by the touch's position whatever
/// SwiftUI hit-tests: a tab tapped over a group chat card on Bots lit the card up and grew it under
/// the bar (Matt on 1.5 (24)). The same recognizer is a pan that can win over the bar's own drag,
/// which then never ends (#375). The shield is one recognizer on the window that sees each touch
/// as it comes down: where a bar is what the finger is on, it turns those glass recognizers off and
/// on again, which takes this touch from them (a recognizer turned back on does not pick up a touch
/// already down), so the page's glass stays still; everywhere else it does nothing, and glass
/// reacts as before. (Made to wait for the shield with `require(toFail:)`, they began regardless.)
/// The shield never cancels or delays a touch itself, and recognizes alongside every other
/// recognizer, so the bars' own buttons, drag and hold, the back swipe and the system's gestures
/// are as they were. Found by class name: if a later iOS renames them, none is found and the bars
/// behave as they did before.
///
/// The shapes are the bars' own (`BarShieldRegion`, a background UIView of each). The compose and
/// mic circles are left out (`barShieldCircle`, by their frames): their own glass presses with the
/// finger there.
@MainActor final class BarShield: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private static let shields = NSMapTable<UIWindow, BarShield>.weakToStrongObjects()
    private let regions = NSHashTable<BarShieldRegion.RegionView>.weakObjects()
    /// The bar's circles (compose, mic) in window coordinates, by name: left to their own glass.
    /// Frames, not views: a view behind a circle's button made XCUITest see the circle twice and
    /// reach neither.
    private static var circles: [String: CGRect] = [:]
    static func setCircle(_ name: String, frame: CGRect?) { circles[name] = frame }
    /// The window's glass recognizers found so far (each logged once).
    private let glass = NSHashTable<UIGestureRecognizer>.weakObjects()

    static func register(_ region: BarShieldRegion.RegionView, in window: UIWindow) {
        let shield = shields.object(forKey: window) ?? {
            let s = BarShield()
            window.addGestureRecognizer(s)
            shields.setObject(s, forKey: window)
            return s
        }()
        shield.regions.add(region)
        shield.findGlass()
        #if DEBUG
        let host = region.host.map { String(describing: type(of: $0)).prefix(40) } ?? "none"
        Logger(subsystem: "com.vorantx.vory", category: "bars").notice("bar shield: a shape in \(host, privacy: .public)")
        #endif
    }

    /// The window's shield, once a bar's shape is in it.
    static func shield(for window: UIWindow) -> BarShield? { shields.object(forKey: window) }

    static func unregister(_ region: BarShieldRegion.RegionView) {
        for case let s as BarShield in shields.objectEnumerator() ?? NSEnumerator() { s.regions.remove(region) }
    }

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        // Fingers, and the iPad pointer's clicks; hover is a recognizer of its own and untouched.
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        delegate = self
    }

    /// The glass recognizers on the window, looked for again on each touch (glass that comes on
    /// screen later brings its own).
    private func findGlass() {
        guard let window = view else { return }
        for g in window.gestureRecognizers ?? [] where g !== self && !glass.contains(g) {
            let name = String(describing: type(of: g))
            guard name.contains("FlexInteraction") else { continue }
            glass.add(g)
            #if DEBUG
            Logger(subsystem: "com.vorantx.vory", category: "bars").notice("bar shield: found \(name, privacy: .public)")
            #endif
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        findGlass()
        guard let window = view as? UIWindow else { state = .failed; return }
        let onBar = touches.contains { covers($0.location(in: window), in: window, event: event) }
        if onBar {
            for g in glass.allObjects where g.isEnabled {
                g.isEnabled = false
                g.isEnabled = true
            }
        }
        state = onBar ? .recognized : .failed
    }

    /// Whether a touch at `point` (in the window) is on a bar: inside one of its shapes (not on one
    /// of its circles), and what the window hit-tests there is that bar itself (the hosting view it
    /// is drawn in, or its own catcher), not a sheet, menu or alert presented over it, and not the
    /// page under a bar that is hidden or sliding away (no hit-testing then). The shapes' frames
    /// are read now, never kept.
    func covers(_ point: CGPoint, in window: UIWindow, event: UIEvent?) -> Bool {
        guard !Self.circles.values.contains(where: { UIBezierPath(ovalIn: $0).contains(point) }) else { return false }
        let live = regions.allObjects.filter { $0.window === window && !$0.isHidden }
        func inside(_ r: BarShieldRegion.RegionView) -> Bool { r.point(inside: r.convert(point, from: window), with: event) }
        let hits = live.filter(inside)
        guard !hits.isEmpty, let hit = window.hitTest(point, with: event) else { return false }
        return hits.contains { $0 === hit || $0.host === hit }
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

extension View {
    /// Backs this view with a bar's shape for the shield (`BarShieldRegion`), out of the
    /// accessibility tree and, unless it catches, of SwiftUI's hit-testing.
    func barShieldShape(catches: Bool = false, margin: CGFloat = 0, square: Bool = false) -> some View {
        background {
            BarShieldRegion(catches: catches, square: square)
                .padding(-margin)
                .accessibilityHidden(true)
                .allowsHitTesting(catches)
        }
    }

    /// One of the bar's circles, left to its own glass: its frame goes to the shield.
    func barShieldCircle(_ name: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { BarShield.setCircle(name, frame: $0) }
            .onDisappear { BarShield.setCircle(name, frame: nil) }
    }
}

/// A bar's shape for the shield: a capsule the size of what it backs. `catches`: it also takes
/// the touches inside it that miss the bar's buttons (the tab bar's gaps and edges, `TouchCatcher`
/// before), so they never reach the page. `square`: the whole frame, for a top bar slot whose control is a
/// button across the slot (#584).
struct BarShieldRegion: UIViewRepresentable {
    var catches = false
    var square = false

    func makeUIView(context: Context) -> RegionView {
        let v = catches ? Catcher() : RegionView()
        v.square = square
        return v
    }
    func updateUIView(_ v: RegionView, context: Context) { v.square = square }

    class RegionView: UIView {
        var square = false
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            // A shape only: it takes no touch (the catcher below does).
            isUserInteractionEnabled = self is Catcher
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            square ? bounds.contains(point) : UIBezierPath(roundedRect: bounds, cornerRadius: min(bounds.width, bounds.height) / 2).contains(point)
        }

        /// The hosting view the bar is drawn in (the nearest one above the shape).
        var host: UIView? {
            var v = superview
            while let cur = v, !String(describing: type(of: cur)).contains("HostingView") { v = cur.superview }
            return v
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { BarShield.register(self, in: window) } else { BarShield.unregister(self) }
        }
    }

    /// Takes the touches inside the capsule of its bounds and does nothing with them: under the
    /// tab bar, the gaps and edges that miss its buttons. A UIKit view: SwiftUI's clear view with a
    /// tap gesture there read to VoiceOver as an element with no description the size of the bar,
    /// whatever hid it (accessibilityHidden, an empty representation), and without one a touch in a
    /// gap went to the nearest button (the next tab, a new chat). A UIView that hit-tests takes the
    /// touch by itself, with no recognizer, and stays out of the accessibility tree.
    final class Catcher: RegionView {}
}
#endif
