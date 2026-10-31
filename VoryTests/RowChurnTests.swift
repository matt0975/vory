import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// #422, the row churn: while a long turn streamed, every row of the thread was rebuilt at every tool step and every
/// new row (900 to 1,400 row evaluations a second), because each was given values only the last row uses. A row's
/// inputs now hold across a tool step and a new last row, and the typing bubble still gets its tool's name.
@MainActor
struct RowChurnTests {
    private let actions = RowActions()

    private func context(typingTool: String?, lastID: String?, interrupt: InterruptedTurn.Cause? = nil) -> RowContext {
        RowContext(profile: "default", bot: "default", botLabel: "Bot", typingTool: typingTool, showReasoning: true,
                   currentStepOnly: false, showStats: true, interruptCause: interrupt, lastID: lastID, openReasoning: [],
                   openTools: [], showToolOutput: true, compactTools: false, wide: false, maxBubble: 640, actions: actions)
    }

    private let tool = TranscriptItem(id: "t1", kind: .tool(ToolActivity(id: "t1", name: "terminal", context: "ls", status: .done)))
    private let reply = TranscriptItem(id: "r1", kind: .assistant(text: "Done.", reasoning: nil, streaming: false))
    private let user = TranscriptItem(id: "u1", kind: .user(text: "Check the disk", attachments: []))
    private let waiting = TranscriptItem(id: "r2", kind: .assistant(text: "", reasoning: nil, streaming: true))

    /// What a row is given that depends on the turn, as `RowContext.rowView` hands it to `TranscriptRow` (whose `==`
    /// compares them; the rest comes from the row's own item and the settings). TranscriptRow's own initializer is
    /// private to its file (its stored settings are), so the inputs are compared here.
    private struct Inputs: Equatable { var item: TranscriptItem; var typingTool: String?; var interruptCause: InterruptedTurn.Cause? }
    private func row(_ item: TranscriptItem, _ ctx: RowContext) -> Inputs {
        Inputs(item: item, typingTool: ctx.bubbleTool(for: item), interruptCause: ctx.interruptCause(for: item.id))
    }

    @Test func aRowThatDrawsNoBubbleIsEqualAcrossAToolStep() {
        let running = context(typingTool: "terminal", lastID: "r2")
        let between = context(typingTool: nil, lastID: "r2")
        for item in [tool, reply, user] {
            #expect(running.bubbleTool(for: item) == nil)
            #expect(row(item, running) == row(item, between), "\(item.id) is rebuilt at a tool step")
        }
    }

    @Test func theTypingBubbleStillGetsTheToolName() {
        let running = context(typingTool: "terminal", lastID: "r2")
        #expect(running.bubbleTool(for: waiting) == "terminal")
        #expect(context(typingTool: nil, lastID: "r2").bubbleTool(for: waiting) == nil)
        // A reply with words, or one that is not streaming, draws no bubble.
        #expect(running.bubbleTool(for: TranscriptItem(id: "r3", kind: .assistant(text: "Hi", reasoning: nil, streaming: true))) == nil)
        #expect(running.bubbleTool(for: TranscriptItem(id: "r4", kind: .assistant(text: "", reasoning: nil, streaming: false))) == nil)
        // The bubble's own row changes with the step, as it should.
        #expect(row(waiting, running) != row(waiting, context(typingTool: nil, lastID: "r2")))
    }

    @Test func aRowIsEqualWhenANewRowBecomesTheLast() {
        let before = context(typingTool: nil, lastID: "r1", interrupt: .appWasAway)
        let after = context(typingTool: nil, lastID: "t9", interrupt: .appWasAway)
        #expect(row(tool, before) == row(tool, after))
        #expect(row(user, before) == row(user, after))
        // Only the row that stops being the last one changes: it no longer carries the cut turn's cause.
        #expect(before.interruptCause(for: "r1") == .appWasAway)
        #expect(after.interruptCause(for: "r1") == nil)
    }

    @Test func theOlderRowsContextHoldsAcrossAToolStepAndANewRow() {
        let a = context(typingTool: "terminal", lastID: "r2", interrupt: .stopped)
        let b = context(typingTool: nil, lastID: "t9", interrupt: nil)
        // The whole context differs (the tail's rows read it per row)…
        #expect(a != b)
        // …but the older rows' does not: they are never the last row nor the typing one.
        #expect(a.forOlderRows(tail: []) == b.forOlderRows(tail: []))
        // What the older rows do draw with still counts.
        var wider = b
        wider.wide = true
        #expect(a.forOlderRows(tail: []) != wider.forOlderRows(tail: []))
    }

    /// A card toggled at the end leaves the older rows' context as it was: the open cards it carries are the older rows'
    /// own (#473; with the tail's in, the lazy stack was laid out again at every toggle and its rows not yet measured went
    /// back to their estimate). A card toggled in an older row still changes it.
    @Test func aCardToggledAtTheEndLeavesTheOlderRowsContextAlone() {
        let tail = TranscriptRowModel.build([tool, reply])[...]
        let closed = context(typingTool: nil, lastID: "r1")
        var tailOpen = closed
        tailOpen.openTools = ["t1"]
        tailOpen.openReasoning = ["r1"]
        #expect(closed != tailOpen)
        #expect(closed.forOlderRows(tail: tail) == tailOpen.forOlderRows(tail: tail))
        var olderOpen = closed
        olderOpen.openTools = ["t0"]
        #expect(closed.forOlderRows(tail: tail) != olderOpen.forOlderRows(tail: tail))
    }

    /// The older rows are drawn without the last row's inputs (`forOlderRows(tail:)`), which holds because the last row is
    /// never among them: the lazy part ends before the last row for every thread of one row or more, whatever boundary
    /// the thread has set. Kept true here if the split changes.
    @Test func theLastRowIsNeverInTheLazyPart() {
        var wrong: [String] = []
        for count in 1...600 {
            let bare = TranscriptRowModel.split(count: count, tailFrom: nil)
            if !(0..<count).contains(bare) { wrong.append("count \(count), no boundary: \(bare)") }
            for tailFrom in stride(from: 0, through: count + 40, by: count > 200 ? 7 : 1) {
                let split = TranscriptRowModel.split(count: count, tailFrom: tailFrom)
                if !(0..<count).contains(split) { wrong.append("count \(count), tailFrom \(tailFrom): \(split)") }
            }
        }
        #expect(wrong.isEmpty, "the lazy part reaches the last row: \(wrong.prefix(10))")
    }
}
