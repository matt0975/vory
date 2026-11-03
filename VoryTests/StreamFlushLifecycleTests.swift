import Foundation
import Testing
@testable import VoryCore

@MainActor @Suite struct StreamFlushLifecycleTests {
    private func chat() throws -> ChatSession {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        return ChatSession(runtime: rt, storedID: nil, title: nil)
    }

    private func send(_ chat: ChatSession, _ type: String, _ payload: [String: JSONValue] = [:]) {
        chat.handle(event: GatewayEvent(type: type, sessionID: chat.runtimeID, payload: .object(payload)))
    }

    @Test func streamFlushIsCancelledWhenToolStarts() throws {
        let c = try chat()
        send(c, "message.start")
        send(c, "message.delta", ["text": .string("Thinking about using a tool...")])

        // After receiving a delta, streamFlush debounce task should be scheduled
        #expect(c.isStreamFlushScheduled == true)

        // Tool begins execution: sealStreamingForTool should cancel and nil streamFlush immediately
        send(c, "tool.start", ["tool_id": .string("t1"), "name": .string("web_search")])

        #expect(c.isStreamFlushScheduled == false)
    }

    @Test func streamFlushIsCancelledWhenStreamingCompletes() throws {
        let c = try chat()
        send(c, "message.start")
        send(c, "message.delta", ["text": .string("Here is the final answer.")])

        #expect(c.isStreamFlushScheduled == true)

        // When the message completes, finishStreaming cancels and nils streamFlush immediately
        send(c, "message.complete", ["text": .string("Here is the final answer.")])

        #expect(c.isStreamFlushScheduled == false)
    }

    @Test func immediateSubsequentTurnSchedulesFreshFlushWithoutDrop() throws {
        let c = try chat()
        // Turn 1
        send(c, "message.start")
        send(c, "message.delta", ["text": .string("Turn 1 text")])
        #expect(c.isStreamFlushScheduled == true)

        send(c, "message.complete", ["text": .string("Turn 1 text")])
        #expect(c.isStreamFlushScheduled == false)

        // Turn 2 immediately begins: should be able to schedule fresh flush without being blocked
        send(c, "message.start")
        send(c, "message.delta", ["text": .string("Turn 2 text")])
        #expect(c.isStreamFlushScheduled == true)

        send(c, "message.complete", ["text": .string("Turn 2 text")])
        #expect(c.isStreamFlushScheduled == false)
    }

    @Test func largeAttachmentStagingAsyncOffMainActor() async throws {
        let c = try chat()
        let largeData = Data(repeating: 0x42, count: 1024 * 1024) // 1 MB
        await c.stageAttachmentAsync(data: largeData, name: "test-large.bin", kind: .file)

        #expect(c.staged.count == 1)
        #expect(c.staged.first?.name == "test-large.bin")
        #expect(c.staged.first?.byteCount == 1024 * 1024)
        #expect(c.staged.first?.localURL != nil)

        // Cleanup
        if let id = c.staged.first?.id {
            c.removeStaged(id)
        }
        #expect(c.staged.isEmpty)
    }

    @Test func streamFlushIsCancelledOnInterimMessage() throws {
        let c = try chat()
        send(c, "message.start")
        send(c, "message.delta", ["text": .string("Interim reply streaming...")])
        #expect(c.isStreamFlushScheduled == true)

        send(c, "message.interim", ["text": .string("Interim reply streaming..."), "already_streamed": true])
        #expect(c.isStreamFlushScheduled == false)
    }

    @Test func streamFlushIsCancelledOnError() throws {
        let c = try chat()
        send(c, "message.start")
        send(c, "message.delta", ["text": .string("About to hit an error...")])
        #expect(c.isStreamFlushScheduled == true)

        send(c, "error", ["message": .string("Gateway connection terminated")])
        #expect(c.isStreamFlushScheduled == false)
    }

    @Test func streamFlushIsCancelledOnSessionReclaimed() throws {
        let c = try chat()
        send(c, "message.start")
        send(c, "message.delta", ["text": .string("Generating text...")])
        #expect(c.isStreamFlushScheduled == true)

        send(c, "session.reclaimed", ["reason": .string("timeout")])
        #expect(c.isStreamFlushScheduled == false)
    }

    @Test func streamFlushIsCancelledOnUserStop() async throws {
        let c = try chat()
        send(c, "message.start")
        send(c, "message.delta", ["text": .string("Running a long generation...")])
        #expect(c.isStreamFlushScheduled == true)

        await c.stop()
        #expect(c.isStreamFlushScheduled == false)
    }

    @Test func stageAttachmentSyncApiDelegatesLargePayload() async throws {
        let c = try chat()
        let largeData = Data(repeating: 0x55, count: 600 * 1024) // 600 KB > 512 KB
        c.stageAttachment(data: largeData, name: "sync-large.dat", kind: .file)

        // Give background Task a brief moment to finish staging
        for _ in 0..<20 {
            if !c.staged.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(c.staged.count == 1)
        #expect(c.staged.first?.name == "sync-large.dat")
        if let id = c.staged.first?.id {
            c.removeStaged(id)
        }
    }

    @Test func uploadWithMissingLocalFileReportsError() async throws {
        let c = try chat()
        // Create an attachment preview pointing to a non-existent file
        let bogusURL = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID().uuidString).dat")
        let bogusAttachment = AttachmentPreview(id: "bogus", name: "missing.dat", serverPath: nil, kind: .file, localURL: bogusURL, byteCount: 100)
        c.staged = [bogusAttachment]

        // Send a message; upload will fail because file does not exist
        _ = await c.send("Test message with missing attachment")

        // Chat should report an error item rather than falsely including the missing attachment
        let hasErrorItem = c.items.contains { item in
            if case .error(let text) = item.kind {
                return text.contains("missing.dat")
            }
            return false
        }
        #expect(hasErrorItem == true)

        // The user transcript item should not have bogus attachment in its previews
        let userItem = c.items.first { item in
            if case .user = item.kind { return true }
            return false
        }
        if case .user(_, let attachments) = userItem?.kind {
            #expect(attachments.isEmpty == true)
        }
    }
}
