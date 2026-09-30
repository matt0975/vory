import AppKit
import SwiftUI

/// Force click: a firmer press on the trackpad. AppKit reports it as a pressure event to the
/// view under the pointer, which SwiftUI does not surface, so a local event monitor watches for
/// the second stage and looks the pointer up among the views that asked (`onForceClick`), by
/// the frames they last reported. One fire per press.
@MainActor
final class ForceClickMonitor {
    static let shared = ForceClickMonitor()
    private var targets: [UUID: (frame: CGRect, action: () -> Void)] = [:]
    private var monitor: Any?
    private var fired = false

    func register(_ id: UUID, frame: CGRect, action: @escaping () -> Void) {
        targets[id] = (frame, action)
        start()
    }

    func unregister(_ id: UUID) { targets[id] = nil }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.pressure, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseUp { fired = false; return }
        guard event.stage == 2, !fired, let window = event.window, let content = window.contentView else { return }
        // SwiftUI's global frames hang from the window's top-left; AppKit's point is from the bottom-left.
        let inContent = content.convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: inContent.x, y: content.isFlipped ? inContent.y : content.bounds.height - inContent.y)
        guard let hit = targets.values.first(where: { $0.frame.contains(point) }) else { return }
        fired = true
        hit.action()
    }
}

private struct ForceClickModifier: ViewModifier {
    let action: () -> Void
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                ForceClickMonitor.shared.register(id, frame: frame, action: action)
            }
            .onDisappear { ForceClickMonitor.shared.unregister(id) }
    }
}

extension View {
    /// Runs `action` on a force click over this view.
    func onForceClick(perform action: @escaping () -> Void) -> some View { modifier(ForceClickModifier(action: action)) }
}
