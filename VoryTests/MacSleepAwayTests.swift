#if os(macOS)
import AppKit
import Testing
@testable import Vory

/// The Mac's away and back are the system's sleep and wake, nothing else (#306: a Mac woken from
/// a closed lid used to wait for the heartbeat to notice its dead socket).
@Suite struct MacSleepAwayTests {
    @MainActor final class Seen { var values: [Bool] = [] }

    @MainActor @Test func sleepIsAwayAndWakeIsBack() {
        let center = NotificationCenter()
        let seen = Seen()
        let sleepAway = MacSleepAway { seen.values.append($0) }
        sleepAway.start(center: center)
        #expect(sleepAway.isObserving)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(seen.values == [true, false])
        // Neither the screen nor the app changing is away.
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(seen.values == [true, false])
        sleepAway.stop(center: center)
        #expect(!sleepAway.isObserving)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(seen.values == [true, false])
    }

    @MainActor @Test func startsOnce() {
        let center = NotificationCenter()
        let seen = Seen()
        let sleepAway = MacSleepAway { seen.values.append($0) }
        sleepAway.start(center: center)
        sleepAway.start(center: center)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(seen.values == [false])
        sleepAway.stop(center: center)
    }
}
#endif
