import SwiftUI

/// The window's own geometry, for the few places that lay out against the window rather than
/// their own frame: the chat thread's bottom edge and keyboard margin, the dock, the tab bar's
/// hang into the home-indicator area, and the caps that were a share of "the screen". It used
/// to come from `UIScreen.main` and a one-off read of the key window's insets, which is wrong
/// whenever the window is not the whole screen (an iPad window, Split View, the Duo's two
/// displays) and goes stale when the window changes size or the insets move (a fold, a vertical
/// bar appearing). This is read from the window every time it lays out, so it follows all of that.
///
/// One per scene, put into the environment by the root; the Mac's views get the empty default
/// and never read it (their layout is the window's own).
@MainActor @Observable
final class WindowGeometry {
    /// The window's bounds in its own space (origin zero).
    var bounds: CGRect = .zero
    /// The window's safe-area insets: each edge its own value, never assumed symmetric.
    var safeArea: EdgeInsets = EdgeInsets()
    /// The keyboard's frame in window space when one is up at the bottom of the window;
    /// `.null` when there is none, it is hidden, or it does not sit on the window's bottom edge
    /// (a floating iPad keyboard, another scene's).
    var keyboard: CGRect = .null
    /// Whether the reader is holding back a turn's passing window (`passing`): what else is read from the window holds
    /// with it, so nothing moves before the window settles (#548: the bars' edge).
    var holding = false

    /// Nonisolated so the environment's default (an empty geometry, what the Mac's views see)
    /// can be made anywhere; every read and write after that is on the main actor.
    nonisolated init() {}

    /// How much of the window's height the keyboard covers above the bottom safe-area inset:
    /// what the dock and the thread move up by. Zero with no keyboard.
    var keyboardOverlap: CGFloat { Self.keyboardOverlap(window: bounds, keyboard: keyboard, safeBottom: safeArea.bottom) }

    /// The keyboard frame `end` (already in window space) that counts: one that sits on the
    /// window's bottom edge (or is entirely below it, which is "hidden") and is less than two
    /// thirds of the window tall. Anything else (a floating keyboard, a hardware keyboard's bar
    /// somewhere else, a whole-window rect from another scene) is `.null`.
    /// Whether a keyboard frame known for a window of `old` size still means anything for one
    /// of `new` size: only while the size is the same (or nothing was known yet).
    nonisolated static func keyboardCarriesOver(from old: CGSize, to new: CGSize) -> Bool { old == .zero || old == new }
    nonisolated static func keyboardRect(window: CGRect, end: CGRect) -> CGRect {
        guard !end.isNull, window.height > 0, end.height < window.height * 0.66 else { return .null }
        if end.minY >= window.maxY - 0.5 { return .null }
        let onWindow = end.intersection(window)
        guard !onWindow.isNull, onWindow.maxY >= window.maxY - 1 else { return .null }
        return end
    }

    /// The rule `WindowGeometryReader` keeps (`publishes`), for a value worked out from the window elsewhere (the size
    /// class's `wide`, the reserved regions): while `holding` (the scene in the background), the last value read
    /// outside it, or the live one before any.
    nonisolated static func held<T>(live: T, holding: Bool, last: T?) -> T { holding ? (last ?? live) : live }

    nonisolated static func keyboardOverlap(window: CGRect, keyboard: CGRect, safeBottom: CGFloat) -> CGFloat {
        guard !keyboard.isNull, window.height > 0 else { return 0 }
        let covered = max(0, window.maxY - keyboard.minY)
        return min(max(0, covered - safeBottom), window.height * 0.6)
    }
}

extension EnvironmentValues {
    @Entry var windowGeometry: WindowGeometry = WindowGeometry()
}

#if os(iOS)
extension WindowGeometry {
    /// Whether a measure of the window is published: unless its scene is in the background, and the first one whatever
    /// the scene. In the background the system lays the window out again for its snapshot at other sizes (on the open
    /// Duo on its side, 466 × 678 with the top inset of the cover display), and everything that reads this followed it
    /// there and back on every trip (#537); the window is read again as the scene leaves the background. A scene that is
    /// only inactive (the switcher, an unfocused window still on screen, which can still be resized) is read as ever.
    nonisolated static func publishes(_ state: UIScene.ActivationState?, measured: Bool) -> Bool { state != .background || !measured }

    /// Whether a measure is the window a turn of the open Duo passes through (the probe, #547): its shape has turned from
    /// the last published measure's, taller than wide to wider, while its insets are still that measure's (the upright's
    /// status band on top, 82 there, and nothing at either side). The system corrects it about half a second later (the
    /// strip's 84 at the side and nothing on top). Since the bar's moves no longer rebuild the pages (#533), what was laid
    /// out in that half second stayed: the Chats split view's items squeezed into its overflow (#537) and Home's heading
    /// left of the window (#548). A window already wide, and an iPad turned (its status band 24 pt), are never held.
    nonisolated static func passing(size: CGSize, safeArea: EdgeInsets, published: CGSize, publishedSafeArea: EdgeInsets) -> Bool {
        published.height > published.width && size.width > size.height
            && safeArea.top >= 50 && abs(safeArea.top - publishedSafeArea.top) < 1
            && safeArea.leading < 1 && safeArea.trailing < 1
    }
    /// How long a passing window is held back at most, should it never be corrected.
    nonisolated static let settleLimit: TimeInterval = 1
}

/// Reads the window into a `WindowGeometry` on every layout and inset change. Put one in the
/// root; it draws nothing.
struct WindowGeometryReader: UIViewRepresentable {
    let geometry: WindowGeometry

    func makeUIView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.geometry = geometry
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: ReaderView, context: Context) { uiView.geometry = geometry }

    final class ReaderView: UIView {
        var geometry: WindowGeometry?
        /// The last keyboard frame the notification gave, in screen space, kept so a window
        /// resize (a fold) can re-place it in window space without waiting for a new one.
        private var keyboardEndOnScreen: CGRect = .null

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publish()
            guard !observing, window != nil else { return }
            observing = true
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            center.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
            center.addObserver(self, selector: #selector(sceneLeavesBackground(_:)), name: UIScene.willEnterForegroundNotification, object: nil)
            center.addObserver(self, selector: #selector(sceneLeavesBackground(_:)), name: UIScene.didActivateNotification, object: nil)
        }
        private var observing = false
        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func keyboardWillChange(_ n: Notification) {
            keyboardEndOnScreen = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .null
            publish()
        }
        @objc private func keyboardWillHide(_ n: Notification) {
            keyboardEndOnScreen = .null
            publish()
        }
        /// This window's scene is leaving the background: what was held there is read on the next turn, once the scene
        /// no longer says background. Again when it is active, since "will enter the foreground" can still read
        /// background on that turn, and a window back at its old size may lay out no more.
        @objc private func sceneLeavesBackground(_ n: Notification) {
            guard let scene = n.object as? UIWindowScene, scene === window?.windowScene else { return }
            DispatchQueue.main.async { [weak self] in self?.publish() }
        }

        override func layoutSubviews() { super.layoutSubviews(); publish() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); publish() }

        private var lastSize = CGSize.zero
        /// When a passing window was first held back (`passing`), for the hold's limit.
        private var passingSince: Date?
        private func publish() {
            guard let geometry, let window else { return }
            guard WindowGeometry.publishes(window.windowScene?.activationState, measured: geometry.bounds != .zero) else { return }
            let bounds = window.bounds
            let insets = window.safeAreaInsets
            // A turn's passing window: the last published measure stays until the window settles (`passing`), a second at
            // most.
            let measured = EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
            if WindowGeometry.passing(size: bounds.size, safeArea: measured, published: geometry.bounds.size, publishedSafeArea: geometry.safeArea) {
                let since = passingSince ?? .now
                if passingSince == nil {
                    passingSince = since
                    DispatchQueue.main.asyncAfter(deadline: .now() + WindowGeometry.settleLimit + 0.05) { [weak self] in self?.publish() }
                }
                if Date.now.timeIntervalSince(since) < WindowGeometry.settleLimit {
                    if !geometry.holding { geometry.holding = true }
                    return
                }
            } else { passingSince = nil }
            // A window of a new size (a turn, a fold, a resize): the keyboard's last frame is
            // forgotten. A keyboard that stays announces itself again (keyboardWillChangeFrame);
            // one the turn took away never posts a will-hide, and the open Duo's bar stayed
            // hidden behind a keyboard that was no longer there.
            if !WindowGeometry.keyboardCarriesOver(from: lastSize, to: bounds.size) { keyboardEndOnScreen = .null }
            lastSize = bounds.size
            // The notification's frame is in screen space; the window places it in its own.
            let end: CGRect = keyboardEndOnScreen.isNull ? .null : window.convert(keyboardEndOnScreen, from: window.screen.coordinateSpace)
            let keyboard = WindowGeometry.keyboardRect(window: bounds, end: end)
            if geometry.bounds != bounds { geometry.bounds = bounds }
            if geometry.safeArea != measured { geometry.safeArea = measured }
            if geometry.keyboard != keyboard { geometry.keyboard = keyboard }
            if geometry.holding { geometry.holding = false }
        }
    }
}
#endif
