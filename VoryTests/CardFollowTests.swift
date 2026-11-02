import Testing
@testable import Vory

/// After a card's hold, the thread follows its end again only for a reader who was at the end as the card was toggled.
/// Following a running turn whatever the reader's place pulled someone who had opened a card up the thread down to the
/// bottom; following only rows that arrived during the hold stopped a reader at the end being followed after a toggle.
@Suite struct CardFollowTests {
    @Test func aReaderAtTheEndIsFollowedAgain() {
        #expect(CardFollow.afterHold(atEndWhenToggled: true, rowsArrived: false, turnRunning: true), "a turn still running")
        #expect(CardFollow.afterHold(atEndWhenToggled: true, rowsArrived: true, turnRunning: false), "rows that came in during the hold")
        #expect(CardFollow.afterHold(atEndWhenToggled: true, rowsArrived: true, turnRunning: true))
    }

    @Test func aReaderUpTheThreadStaysPut() {
        #expect(!CardFollow.afterHold(atEndWhenToggled: false, rowsArrived: false, turnRunning: true), "a turn still running")
        #expect(!CardFollow.afterHold(atEndWhenToggled: false, rowsArrived: true, turnRunning: false), "rows that came in during the hold")
        #expect(!CardFollow.afterHold(atEndWhenToggled: false, rowsArrived: true, turnRunning: true))
    }

    @Test func nothingMovesWithNothingToFollow() {
        #expect(!CardFollow.afterHold(atEndWhenToggled: true, rowsArrived: false, turnRunning: false))
        #expect(!CardFollow.afterHold(atEndWhenToggled: false, rowsArrived: false, turnRunning: false))
    }
}
