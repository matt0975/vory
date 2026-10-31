import Foundation
import Testing
@testable import VoryCore

/// The demo's live paths (#392), through the real client on the demo transport: a message gets a reply streamed with
/// two tool steps; one message asks for an approval and the card's answer decides how the reply ends; a group message
/// gets its members' replies; a board move is applied; a file the app sends is kept for the demo's life.
@MainActor
@Suite(.serialized) struct DemoLiveTests {
    private func runtime(approvalChoices: [String] = DemoGateway.allApprovalChoices) async -> GatewayRuntime {
        let name = "dev.vory.tests.demolive." + UUID().uuidString
        let store = ConnectionStore(defaults: UserDefaults(suiteName: name)!, connections: [])
        let rt = GatewayRuntime(connection: .demo, store: store, transport: .demo(DemoGateway(pace: .quick, approvalChoices: approvalChoices)))
        await rt.start()
        return rt
    }

    private func waitUntil(_ seconds: Double = 15, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func replyText(_ chat: ChatSession) -> String {
        chat.items.compactMap { item -> String? in
            if case .assistant(let t, _, _) = item.kind { return t }
            return nil
        }.joined(separator: "\n")
    }

    private func toolCount(_ chat: ChatSession) -> Int {
        chat.items.filter { if case .tool = $0.kind { return true }; return false }.count
    }

    @Test func aNewMessageGetsAReplyStreamedWithItsToolSteps() async throws {
        let rt = await runtime()
        defer { Task { await rt.stop() } }
        let chat = try await rt.newChat(profile: "default")
        _ = await chat.send("What should I plan for this weekend?")
        await waitUntil { !chat.isRunning && replyText(chat).contains("Want me to set a reminder") }
        #expect(replyText(chat).contains("Want me to set a reminder"))
        #expect(toolCount(chat) == DemoContent.everyday.steps.count)
        #expect(chat.cards.isEmpty)
        await waitUntil { chat.title != "New chat" }
        #expect(chat.title == "What should I plan for this weekend?")
    }

    @Test func oneMessageAsksForAnApprovalAndTheAnswerDecidesTheEnding() async throws {
        let rt = await runtime()
        defer { Task { await rt.stop() } }
        let chat = try await rt.newChat(profile: "default")
        // Onboarding's ready-made message (beat 3, Option A).
        _ = await chat.send("What's taking up the most space on my server?")
        await waitUntil { chat.cards.contains { $0.method == "approval" } }
        let card = try #require(chat.cards.first { $0.method == "approval" })
        let cleanup = try #require(DemoContent.cleanup.approval)
        #expect(card.approval?.command == cleanup.command)
        #expect(card.approval?.offeredChoices == ["once", "session", "always", "deny"])
        await chat.respond(card: card, result: .object(["choice": .string("once")]))
        await waitUntil { !chat.isRunning && replyText(chat).contains(cleanup.done) }
        #expect(replyText(chat).contains(cleanup.done))
        #expect(toolCount(chat) == DemoContent.cleanup.steps.count + 1)
        // Once per demo: the next cleanup is answered without asking.
        _ = await chat.send("And clean up the old screenshots too.")
        await waitUntil { !chat.isRunning && replyText(chat).components(separatedBy: "Want me to set a reminder").count > 1 }
        #expect(chat.cards.isEmpty)
    }

    /// The onboarding tour's demo (#388) asks with two answers only, Allow once and Deny (Matt's pick); "Try a demo"
    /// keeps all four (above).
    @Test func theToursApprovalOffersOnceAndDenyOnly() async throws {
        let rt = await runtime(approvalChoices: ["once", "deny"])
        defer { Task { await rt.stop() } }
        let chat = try await rt.newChat(profile: "default")
        _ = await chat.send("What's taking up the most space on my server?")
        await waitUntil { chat.cards.contains { $0.method == "approval" } }
        let card = try #require(chat.cards.first { $0.method == "approval" })
        #expect(card.approval?.offeredChoices == ["once", "deny"])
        await chat.respond(card: card, result: .object(["choice": .string("deny")]))
        let cleanup = try #require(DemoContent.cleanup.approval)
        await waitUntil { !chat.isRunning && replyText(chat).contains(cleanup.denied) }
        #expect(replyText(chat).contains(cleanup.denied))
    }

    @Test func aGroupMessageGetsItsMembersReplies() async throws {
        let rt = await runtime()
        defer { Task { await rt.stop() } }
        let sent = try await rt.rpc("groups.send", ["room_id": .string("room-weekend"), "event_id": .string(UUID().uuidString),
                                                    "payload": .object(["text": .string("Can you plan the garden beds too?"), "thread_id": .string("main")])])
        #expect(sent["seq"]?.intValue != nil)
        var members = 0
        for _ in 0..<60 {
            let log = try await rt.rpc("groups.log", ["room_id": .string("room-weekend"), "since_seq": .number(Double(DemoContent.groupLog.count))])
            members = log["events"]?.arrayValue?.filter { $0["kind"]?.stringValue == "message.member" }.count ?? 0
            if members >= DemoContent.groupMembers.count { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(members == DemoContent.groupMembers.count)
    }

    @Test func aBoardMoveIsAppliedAndRead() async throws {
        let rt = await runtime()
        defer { Task { await rt.stop() } }
        await rt.kanban.refresh()
        let task = try #require(rt.kanban.board?.columns.flatMap(\.tasks).first { $0.id == "t-106" })
        #expect(await rt.kanban.move(task, to: .done, summary: "Toner is fine."))
        await rt.kanban.refresh()
        let moved = rt.kanban.board?.columns.flatMap(\.tasks).first { $0.id == "t-106" }
        #expect(moved?.status == "done")
        #expect(moved?.result == "Toner is fine.")
    }

    @Test func aFileTheAppSendsIsKeptForTheDemosLife() async throws {
        let rt = await runtime()
        defer { Task { await rt.stop() } }
        let words = Data("Shed shelves, take two.".utf8)
        let _: ManagedUploadResult = try await rt.api.sendMultipart("/api/files/upload-stream", fields: ["path": "/home/demo/notes.txt"],
                                                                     fileField: "file", filename: "notes.txt", fileData: words, mimeType: "text/plain")
        let files: FilesListing = try await rt.api.get("/api/files", query: [])
        #expect(files.entries.contains { $0.name == "notes.txt" })
        // And it opens as its own bytes (the Files page's download).
        let url = try await rt.api.download("/api/files/download", query: [URLQueryItem(name: "path", value: "/home/demo/notes.txt")])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: url) == words)
    }
}
