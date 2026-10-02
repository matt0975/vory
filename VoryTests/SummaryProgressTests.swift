import Testing
@testable import Vory

@Suite struct SummaryProgressTests {
    @Test func aRunCountsUpAndTheNextOneStartsFromNothing() {
        var p = SummaryProgress()
        #expect(!p.isWorking)
        #expect(p.fraction == 0)

        p.queued(); p.queued(); p.queued()
        #expect(p.isWorking)
        #expect(p.total == 3 && p.done == 0)
        #expect(p.current == 1, "the first of three is being written")

        p.finished()
        #expect(p.current == 2)
        #expect(abs(p.fraction - 1.0 / 3.0) < 0.0001)

        // More chats scrolled into view while it works: the same run grows.
        p.queued()
        #expect(p.total == 4 && p.done == 1)

        p.finished(); p.finished(); p.finished()
        #expect(!p.isWorking)
        #expect(p.fraction == 1)
        #expect(p.current == 4)

        // A stray extra finish does not run past the end.
        p.finished()
        #expect(p.done == 4)

        // Idle again: the next chat begins a new run rather than "5 of 5".
        p.queued()
        #expect(p.total == 1 && p.done == 0)
        #expect(p.isWorking)
    }
}
