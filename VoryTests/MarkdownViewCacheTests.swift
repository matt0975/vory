import Foundation
import Testing
@testable import Vory
@testable import VoryCore

@MainActor @Suite struct MarkdownViewCacheTests {
    init() {
        MarkdownView.clearBlockCache()
    }

    @Test func settledMarkdownIsCachedInBlockCache() {
        MarkdownView.clearBlockCache()
        let text = "Settled text with **bold** and `code`"
        #expect(!MarkdownView.isCachedInBlockCache(text))

        let blocks = MarkdownView.blocks(text, streaming: false)
        #expect(!blocks.isEmpty)
        #expect(MarkdownView.isCachedInBlockCache(text), "settled text should be stored in blockCache")

        // Second call returns cached blocks
        let cached = MarkdownView.blocks(text, streaming: false)
        #expect(cached == blocks)
    }

    @Test func streamingMarkdownPrefixesAreExcludedFromBlockCache() {
        MarkdownView.clearBlockCache()
        let full = "The quick brown fox jumps over the lazy dog and produces many streaming tokens"
        var running = ""
        for word in full.split(separator: " ") {
            running += (running.isEmpty ? "" : " ") + String(word)
            let blocks = MarkdownView.blocks(running, streaming: true)
            #expect(!blocks.isEmpty)
            #expect(!MarkdownView.isCachedInBlockCache(running), "streaming prefix '\(running)' must not be inserted into blockCache")
        }

        // Once settled, it should be cached
        let finalBlocks = MarkdownView.blocks(running, streaming: false)
        #expect(!finalBlocks.isEmpty)
        #expect(MarkdownView.isCachedInBlockCache(running), "settled text must be inserted into blockCache")
    }

    @Test func historicalSettledMessagesArePreservedDuringStreamingStorm() {
        MarkdownView.clearBlockCache()
        // Populate historical messages into blockCache
        let historicalCount = 20
        var historicalMessages: [String] = []
        for i in 1...historicalCount {
            let msg = "Historical message #\(i): This was parsed and settled previously."
            _ = MarkdownView.blocks(msg, streaming: false)
            #expect(MarkdownView.isCachedInBlockCache(msg))
            historicalMessages.append(msg)
        }

        // Simulate a long streaming reply with 500 token updates (which exceeds the 400 countLimit if poisoned)
        var streamText = ""
        for token in 1...500 {
            streamText += "token\(token) "
            _ = MarkdownView.blocks(streamText, streaming: true)
        }

        // Verify none of the intermediate streaming prefixes polluted the cache
        #expect(!MarkdownView.isCachedInBlockCache(streamText))

        // Verify that all historical messages remain in blockCache without being evicted
        for msg in historicalMessages {
            #expect(MarkdownView.isCachedInBlockCache(msg), "historical message '\(msg)' should remain in blockCache")
        }
    }

    @Test func defaultStreamingParameterIsFalse() {
        MarkdownView.clearBlockCache()
        let text = "Default parameter test"
        _ = MarkdownView.blocks(text)
        #expect(MarkdownView.isCachedInBlockCache(text), "omitting streaming parameter defaults to settled (cached)")
    }

    @Test func markdownViewEqualityIncludesStreaming() {
        let viewA = MarkdownView(text: "Hello", streaming: true)
        let viewB = MarkdownView(text: "Hello", streaming: false)
        let viewC = MarkdownView(text: "Hello", streaming: true)

        #expect(viewA != viewB, "different streaming status must not be equal")
        #expect(viewA == viewC, "matching text and streaming status must be equal")
    }
}
