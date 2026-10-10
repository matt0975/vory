import Foundation
import Testing
@testable import VoryCore

/// A long fenced code block, as a tool's output or a reasoning card can carry: parsed in one
/// pass. The lines used to be copied over once per line, so the parse grew with the square
/// of the block's length, on the main thread, at every streaming redraw.
@Suite struct MarkdownCodeBlockTests {
    @Test func aLongCodeBlockParsesInOnePass() throws {
        let lines = (0..<40_000).map { "2026-10-09 00:00:\(String(format: "%02d", $0 % 60)) shard-\($0) INFO request served in \($0 % 90 + 3) ms" }
        let text = "Here is the log:\n\n```\n" + lines.joined(separator: "\n") + "\n```\n\nDone."
        let began = Date()
        let blocks = MarkdownParser.blocks(from: text)
        let took = Date().timeIntervalSince(began)
        #expect(blocks.count == 3)
        guard case .code(let language, let body, let closed) = blocks[1] else { Issue.record("no code block"); return }
        #expect(language == nil)
        #expect(closed)
        #expect(body.split(separator: "\n").count == lines.count)
        #expect(body.hasPrefix(lines[0]))
        #expect(body.hasSuffix(lines[lines.count - 1]))
        // A debug build on a simulator under a test runner: generous, and far from the minutes
        // the square took.
        #expect(took < 3, "the block took \(took) s to parse")
    }

    @Test func anUnclosedCodeBlockKeepsEveryLine() {
        let text = "```swift\nlet a = 1\nlet b = 2"
        let blocks = MarkdownParser.blocks(from: text)
        #expect(blocks.count == 1)
        guard case .code(let language, let body, let closed) = blocks[0] else { Issue.record("no code block"); return }
        #expect(language == "swift")
        #expect(!closed)
        #expect(body == "let a = 1\nlet b = 2")
    }
}
