import Foundation
import Testing
@testable import VoryCore

/// #641: the re-attach's schedule. After a failed try the chat waits 2, 5, 10 and 20 s, then every 30 s; nothing shows
/// for 2 s, then the quiet line, and from a minute the banner with Try again; a chat the gateway no longer has shows no
/// line (it has its own banner). A try may take 30 s, then 60, then 120 at most.
@Suite struct ReattachScheduleTests {
    @Test func theDelaysAre2Then5Then10Then20ThenEvery30() {
        #expect((1...8).map(ReattachSchedule.delay(afterFailures:)) == [2, 5, 10, 20, 30, 30, 30, 30])
        #expect(ReattachSchedule.jitter == 0.2)
        #expect((1...5).map(ReattachSchedule.tryTimeout(try:)) == [30, 60, 120, 120, 120])
    }

    @Test func nothingShowsForTwoSecondsThenTheQuietLineThenTheBannerAtAMinute() {
        #expect(ReattachSchedule.show(after: 0) == .none)
        #expect(ReattachSchedule.show(after: 1.9) == .none)
        #expect(ReattachSchedule.show(after: 2) == .reconnecting)
        #expect(ReattachSchedule.show(after: 59.9) == .reconnecting)
        #expect(ReattachSchedule.show(after: 60) == .failed)
        #expect(ReattachSchedule.show(after: 600) == .failed)
    }

    @Test func aChatTheGatewayNoLongerHasShowsNoReattachLine() {
        for elapsed in [0.0, 3, 61, 600] {
            #expect(ReattachSchedule.show(after: elapsed, gone: true) == .none)
        }
    }
}
