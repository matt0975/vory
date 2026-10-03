#if os(macOS)
import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Where the Board's keys take the choice and the card.
@Suite struct MacBoardNavTests {
    @Test func theChoiceSkipsEmptyColumnsAndStopsAtTheEdge() {
        let filled: Set<KanbanStatus> = [.todo, .ready, .done]
        let has: (KanbanStatus) -> Bool = { filled.contains($0) }
        #expect(BoardNav.neighbour(of: .todo, direction: 1, filled: has) == .ready)
        #expect(BoardNav.neighbour(of: .ready, direction: 1, filled: has) == .done)   // running, blocked, review are empty
        #expect(BoardNav.neighbour(of: .done, direction: 1, filled: has) == nil)
        #expect(BoardNav.neighbour(of: .todo, direction: -1, filled: has) == nil)     // triage is empty
        #expect(BoardNav.neighbour(of: .ready, direction: 0, filled: has) == nil)
    }

    @Test func theCardMovesToTheNearestColumnAHandMayUse() {
        // Right from Ready skips Running (the dispatcher's) and lands on Blocked.
        #expect(BoardNav.moveTarget(from: .ready, direction: 1) == .blocked)
        // Right from Blocked skips Review and lands on Done; Done is the edge (Archived has its own command).
        #expect(BoardNav.moveTarget(from: .blocked, direction: 1) == .done)
        #expect(BoardNav.moveTarget(from: .done, direction: 1) == nil)
        // Left from Running (not a target itself) goes to Ready; left from Scheduled to To do.
        #expect(BoardNav.moveTarget(from: .running, direction: -1) == .ready)
        #expect(BoardNav.moveTarget(from: .scheduled, direction: -1) == .todo)
        #expect(BoardNav.moveTarget(from: .triage, direction: -1) == nil)
        #expect(BoardNav.moveTarget(from: .archived, direction: 1) == nil)
    }
}
#endif
