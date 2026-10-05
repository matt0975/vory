#if os(macOS)
import Foundation
import Testing
@testable import Vory

/// The Mac's daily backup scheduler: one scheduler for the process, started once, stopped cleanly.
@Suite struct MacBackupSchedulerTests {
    @MainActor @Test func startsOnceAndStops() {
        BackupScheduler.stop()
        #expect(!BackupScheduler.isRunning)
        BackupScheduler.start()
        #expect(BackupScheduler.isRunning)
        BackupScheduler.start()   // a second start keeps the first scheduler
        #expect(BackupScheduler.isRunning)
        BackupScheduler.stop()
        #expect(!BackupScheduler.isRunning)
        #expect(BackupScheduler.identifier == "com.vorantx.vory.backup")
    }

    @MainActor @Test func theRuleIsTheSharedOne() {
        // A day and a bit since the last backup is due; a few hours is not; none ever is.
        let now = Date().timeIntervalSince1970
        #expect(CloudSync.backupDue(lastBackupAt: nil, now: now))
        #expect(CloudSync.backupDue(lastBackupAt: now - 25 * 3600, now: now))
        #expect(!CloudSync.backupDue(lastBackupAt: now - 3 * 3600, now: now))
    }
}
#endif
