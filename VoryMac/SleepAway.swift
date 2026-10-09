import AppKit
import VoryCore

/// Sleep is the Mac's "away". The phone sets the runtime's `isAway` from its scene phase, and
/// coming back is what draws a reply that gathered meanwhile and checks the socket is alive;
/// the Mac app had no scene phase and never set it, so a Mac woken from a closed lid waited for
/// the heartbeat to notice a socket that had died in the night. The Mac sets it as the system
/// sleeps and wakes, and only then: a window behind another still redraws.
@MainActor
final class MacSleepAway {
    static let shared = MacSleepAway { away in AppModel.shared.runtime?.isAway = away }

    private let away: @MainActor (Bool) -> Void
    private var observers: [any NSObjectProtocol] = []
    var isObserving: Bool { !observers.isEmpty }

    init(away: @escaping @MainActor (Bool) -> Void) { self.away = away }

    /// Listens to the workspace (or any centre handed in, as the tests do). The workspace posts
    /// these on the main thread.
    func start(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        guard observers.isEmpty else { return }
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.away(true) }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.away(false) }
            },
        ]
    }

    func stop(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        for o in observers { center.removeObserver(o) }
        observers = []
    }
}
