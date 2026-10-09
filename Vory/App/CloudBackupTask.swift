#if os(iOS)
import BackgroundTasks
import Foundation
import os

/// The daily iCloud backup when the app is not open: a BGAppRefreshTask the system runs when
/// it sees fit (best effort, roughly daily), asked for each time the app goes to the
/// background. It runs the same quiet backup the app runs on coming forward. (The Mac has
/// its own scheduler, NSBackgroundActivityScheduler, in VoryMac.)
enum CloudBackupTask {
    private static let log = Logger(subsystem: "dev.vory", category: "backup")

    /// Once, at launch: the handler for the task the Info.plist permits.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: CloudSync.backupTaskID, using: nil) { task in
            // The task comes on the scheduler's queue and is completed from the main actor: it
            // is carried over in a box (BGTask is not Sendable; completing it from any thread is fine).
            let handed = UncheckedBox(task)
            // Time up before the backup ran (the main actor was busy): the task is given back
            // unfinished; without this the system ends the app for an unfinished task.
            task.expirationHandler = { handed.value.setTaskCompleted(success: false) }
            Task { @MainActor in
                CloudSync.shared.backUpIfDue()
                log.notice("daily backup task ran; last own backup \(CloudSync.shared.lastOwnBackupAt?.description ?? "none", privacy: .public)\(CloudSync.shared.lastAutoBackupError.map { "; " + $0 } ?? "", privacy: .public)")
                handed.value.setTaskCompleted(success: CloudSync.shared.lastAutoBackupError == nil)
                schedule()
            }
        }
    }

    /// Ask for the next run, a day out at the earliest; a request already pending is replaced.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: CloudSync.backupTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: CloudSync.backupInterval)
        do { try BGTaskScheduler.shared.submit(request) } catch {
            // Not permitted on this device (Low Power Mode, a simulator): the app's own
            // activation path still backs up when it is due.
            log.notice("daily backup task not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
