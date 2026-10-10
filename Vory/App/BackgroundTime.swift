#if os(iOS)
import UIKit

/// Background time for a stretch of async work started while the app is out of sight (a
/// notification action, a push-started Live Activity, Siri). Ended when the work ends or when
/// the system says the time is up, whichever comes first.
///
/// `beginBackgroundTask` without an expiration handler, or with an empty one, leaves the
/// assertion open when the time runs out, and the system ends the app for it: "crashed in the
/// background while I was in another app". The work here waited on the gateway, which could
/// wait for good on a socket that had died quietly (see `GatewaySocket`), so the time did run
/// out. Ending twice is harmless.
@MainActor
final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { self.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
