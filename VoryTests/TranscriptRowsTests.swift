import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// The thread's rows as the view compares them: a token landing in the reply at the end must
/// leave the older rows, and everything they are drawn with, equal to what they were (that
/// equality is what keeps a long history from being re-evaluated on every token).
@Suite struct TranscriptRowsTests {
    private func items(_ n: Int, tail: String) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<n {
            let ts = start.addingTimeInterval(Double(i) * 30)
            out.append(TranscriptItem(id: "u\(i)", kind: .user(text: "question \(i)", attachments: []), timestamp: ts, rowID: i * 2))
            out.append(TranscriptItem(id: "a\(i)", kind: .assistant(text: i == n - 1 ? tail : "answer \(i)", reasoning: nil, streaming: i == n - 1), timestamp: ts.addingTimeInterval(5), rowID: i * 2 + 1))
        }
        return out
    }

    @MainActor @Test func aTokenInTheLastReplyLeavesTheOlderRowsAndTheirContextEqual() {
        let before = TranscriptRowModel.build(items(40, tail: "The disk is"), now: Date(timeIntervalSince1970: 1_800_010_000))
        let after = TranscriptRowModel.build(items(40, tail: "The disk is full"), now: Date(timeIntervalSince1970: 1_800_010_000))
        #expect(before.count == 80 && after.count == 80)
        let split = TranscriptRowModel.split(count: before.count, tailFrom: nil)
        #expect(split > 0 && split < before.count, "a thread this long has lazy rows and a tail")
        #expect(Array(before[..<split]) == Array(after[..<split]), "the older rows are what they were")
        #expect(before[split...].map(\.id) == after[split...].map(\.id))
        #expect(before.last != after.last, "the reply at the end did change")

        // The context, with the actions object kept for the view's life: equal across the token.
        let actions = RowActions()
        func context(lastID: String?) -> RowContext {
            RowContext(profile: "ops", bot: "ops", typingTool: nil, showReasoning: true, currentStepOnly: false, showStats: false, interruptCause: nil, lastID: lastID,
                       openReasoning: [], openTools: ["t1"], showToolOutput: true, compactTools: false, wide: false, maxBubble: 320, actions: actions)
        }
        #expect(context(lastID: "a39") == context(lastID: "a39"))
        #expect(context(lastID: "a39") != context(lastID: "a40"), "a new row at the end is a change (the bot sits beside the last one)")
        // A fresh actions object makes the context unequal: that is why the view keeps one.
        var other = context(lastID: "a39")
        other.actions = RowActions()
        #expect(other != context(lastID: "a39"))
    }

    @Test func theTailBoundaryMovesByWholeBlocksAndTheThreadsOwnStandsWhileItIsSensible() {
        let block = TranscriptRowModel.tailBlock
        #expect(TranscriptRowModel.tailStart(block - 1) == 0)
        #expect(TranscriptRowModel.tailStart(block * 2) == block)
        #expect(TranscriptRowModel.tailStart(block * 2 + 5) == block)
        // The thread's own boundary holds while the tail it leaves is within the cap.
        #expect(TranscriptRowModel.split(count: block * 3, tailFrom: block) == block)
        // Too many rows piled up past it: the blocks take over.
        let cap = TranscriptRowModel.tailCap
        #expect(TranscriptRowModel.split(count: block + cap + 1, tailFrom: block) == TranscriptRowModel.tailStart(block + cap + 1))
        // A boundary past where the blocks would start is not honoured either.
        #expect(TranscriptRowModel.split(count: block * 4, tailFrom: block * 3 + 2) == TranscriptRowModel.tailStart(block * 4))
    }
}
