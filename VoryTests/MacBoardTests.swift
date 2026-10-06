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

/// What a drop on a column comes to: moved, asked first, or refused in the server's words.
@Suite struct MacBoardDropTests {
    private let ready = KanbanTask(id: "k-1", title: "Clear the logs", status: "ready")

    @Test func aDropOnAHandColumnMovesTheCard() {
        guard case .moves(let to) = BoardDrop.decide(ready, to: .todo) else { Issue.record("not a move"); return }
        #expect(to == .todo)
        guard case .moves(.triage) = BoardDrop.decide(ready, to: .triage) else { Issue.record("not a move"); return }
    }

    @Test func doneBlockedAndArchivedAskFirst() {
        guard case .asks(let done) = BoardDrop.decide(ready, to: .done), case .done(let t) = done, t.id == "k-1" else { Issue.record("done should ask for a summary"); return }
        guard case .asks(let blocked) = BoardDrop.decide(ready, to: .blocked), case .block = blocked else { Issue.record("blocked should ask for a reason"); return }
        guard case .asks(let archived) = BoardDrop.decide(ready, to: .archived), case .archive = archived else { Issue.record("archive should ask for a yes"); return }
        #expect(done.asksForText && blocked.asksForText && !archived.asksForText)
    }

    @Test func theGatewaysOwnColumnsRefuseInTheServersWords() {
        for s in [KanbanStatus.running, .review, .scheduled] {
            guard case .refused(let why) = BoardDrop.decide(ready, to: s) else { Issue.record("\(s) should refuse"); continue }
            #expect(!why.isEmpty && why == (s.notMovableReason ?? why))
        }
    }

    @Test func theSameColumnOrNoCardIsNothing() {
        guard case .nothing = BoardDrop.decide(ready, to: .ready) else { Issue.record("same column should do nothing"); return }
        guard case .nothing = BoardDrop.decide(nil, to: .todo) else { Issue.record("no card should do nothing"); return }
    }
}
#endif
