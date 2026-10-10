import AppKit
import SwiftUI

/// Bots move only where someone can see them (#248): their window must be on screen (not
/// minimised, not hidden with the app, not on another Space, not fully covered, the screen not
/// locked) and, for the main window, Vory must be the app in front. App activity rather than
/// the key window: the voice window becomes key while it runs, and the main window's bots should
/// not hold still under it. The floating voice window and the menu bar panel ask only to be seen.
struct BotWindowLiveness: ViewModifier {
    var needsKey: Bool
    @State private var visible = true
    @State private var appActive = NSApp?.isActive ?? true
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .background(WindowVisibilityProbe(visible: $visible))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
            .environment(\.botsLive, visible && (!needsKey || appearsActive || appActive))
    }
}

extension View {
    /// See `BotWindowLiveness`.
    func botWindowLiveness(needsKey: Bool) -> some View { modifier(BotWindowLiveness(needsKey: needsKey)) }
}

/// Reports whether its window can be seen: AppKit's occlusion state (covered, hidden, another
/// Space, a locked screen) and miniaturisation, as they change.
private struct WindowVisibilityProbe: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        let binding = $visible
        view.report = { if binding.wrappedValue != $0 { binding.wrappedValue = $0 } }
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        var report: ((Bool) -> Void)?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { send(false); return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.check() }
                })
            }
            check()
        }

        private func check() {
            send(window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false)
        }

        /// After the current update: a window change can arrive while SwiftUI lays out.
        private func send(_ visible: Bool) {
            Task { @MainActor [weak self] in self?.report?(visible) }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
