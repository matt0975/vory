import AppKit

/// The daily iCloud backup while the app runs: the system picks a quiet moment once a day (the
/// phone's background refresh does the same there), and the shared rule decides whether one is
/// due at all (the Back up automatically switch, iCloud signed in, this device's last backup a
/// day old). Activation and launch are covered by `syncNow()`, which ends with the same check.
@MainActor
enum BackupScheduler {
    static let identifier = "com.vorantx.vory.backup"
    private static var scheduler: NSBackgroundActivityScheduler?
    static var isRunning: Bool { scheduler != nil }

    static func start() {
        guard scheduler == nil else { return }
        let s = NSBackgroundActivityScheduler(identifier: identifier)
        s.repeats = true
        s.interval = 24 * 60 * 60
        // A few hours either way: the system fits it around the person's work and power.
        s.tolerance = 3 * 60 * 60
        s.qualityOfService = .utility
        s.schedule { completion in
            // The block runs on the scheduler's own queue; the sync lives on the main actor.
            Task { @MainActor in
                CloudSync.shared.backUpIfDue()
                completion(.finished)
            }
        }
        scheduler = s
    }

    static func stop() {
        scheduler?.invalidate()
        scheduler = nil
    }
}
