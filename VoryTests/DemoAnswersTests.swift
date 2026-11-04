import Foundation
import Testing
@testable import VoryCore

/// What the demo (#392) answers where it used to answer with an error a reviewer could hit: Steer, on a running turn
/// and on a queued message; deleting a group chat; System's Restart gateway and Run doctor; and the composer's
/// dictation, which a gateway with no speech-to-text provider hands to the device. Through the real client on the demo
/// transport, as DemoLiveTests; after each, the demo's tripwire is empty: nothing was answered by its catch-alls.
@MainActor
@Suite(.serialized) struct DemoAnswersTests {
    private func runtime() async -> (GatewayRuntime, DemoGateway) {
        let name = "dev.vory.tests.demoanswers." + UUID().uuidString
        let store = ConnectionStore(defaults: UserDefaults(suiteName: name)!, connections: [])
        let gateway = DemoGateway(pace: .quick)
        let rt = GatewayRuntime(connection: .demo, store: store, transport: .demo(gateway))
        await rt.start()
        return (rt, gateway)
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

    private func steers(_ chat: ChatSession) -> [String] {
        chat.items.compactMap { item -> String? in
            if case .steer(let text, let status) = item.kind { return "\(text) \(status)" }
            return nil
        }
    }

    /// The chat's history as the demo filed it: each row's role and text.
    private func filed(_ rt: GatewayRuntime, _ chat: ChatSession) async throws -> [(role: String, text: String)] {
        let r: JSONValue = try await rt.api.get("/api/sessions/\(chat.storedID)/messages", query: [])
        return (r["messages"]?.arrayValue ?? []).map { ($0["role"]?.stringValue ?? "", $0["content"]?.stringValue ?? "") }
    }

    private func noTrips(_ gateway: DemoGateway) async {
        let trips = await gateway.tripwire
        #expect(trips.isEmpty, "the demo answered without having it: \(trips)")
    }

    @Test func aSteerIntoARunningTurnIsQueuedAndKeptInTheChat() async throws {
        let (rt, gateway) = await runtime()
        defer { Task { await rt.stop() } }
        let chat = try await rt.newChat(profile: "default")
        _ = await chat.send("What should I plan for this weekend?")
        await waitUntil { chat.isRunning }
        #expect(await chat.steer("keep it short") == nil)
        #expect(steers(chat) == ["keep it short queued"])
        await waitUntil { !chat.isRunning && replyText(chat).contains(DemoLiveSteer.line) }
        #expect(replyText(chat).contains(DemoLiveSteer.line))
        // Filed as its own user row after the turn's tool rows and before its reply, as Hermes adds it.
        let rows = try await filed(rt, chat)
        let steered = try #require(rows.lastIndex { $0.role == "user" && $0.text == "keep it short" })
        let lastTool = try #require(rows.lastIndex { $0.role == "tool" })
        let reply = try #require(rows.lastIndex { $0.role == "assistant" })
        #expect(lastTool < steered && steered < reply)
        await noTrips(gateway)
    }

    @Test func aSteerWithNoTurnRunningGoesAsTheNextMessage() async throws {
        let (rt, gateway) = await runtime()
        defer { Task { await rt.stop() } }
        let chat = try await rt.newChat(profile: "default")
        #expect(await chat.steer("What should I plan for this weekend?") == nil)
        await waitUntil { !chat.isRunning && replyText(chat).contains("Want me to set a reminder") }
        #expect(replyText(chat).contains("Want me to set a reminder"))
        #expect(steers(chat).isEmpty, "a steer no turn took has no steer row")
        // As the gateway answers: no words, 4002; a chat it doesn't have, 4006.
        await #expect(throws: (any Error).self) { _ = try await rt.rpc("session.steer", ["session_id": .string(chat.runtimeID), "text": .string("  ")]) }
        await #expect(throws: (any Error).self) { _ = try await rt.rpc("session.steer", ["session_id": .string("nope"), "text": .string("hi")]) }
        await noTrips(gateway)
    }

    @Test func aQueuedMessageSteeredIntoTheTurnLeavesTheQueue() async throws {
        let (rt, gateway) = await runtime()
        defer { Task { await rt.stop() } }
        let chat = try await rt.newChat(profile: "default")
        _ = await chat.send("What should I plan for this weekend?")
        await waitUntil { chat.isRunning }
        _ = await chat.send("and the shed")
        let queued = try #require(chat.queue.first)
        await chat.steerQueued(queued.id)
        #expect(chat.queue.isEmpty)
        #expect(steers(chat) == ["and the shed queued"])
        await waitUntil { !chat.isRunning && replyText(chat).contains("and the shed") }
        // No second turn at the end: the queue was empty, so nothing was sent after it.
        try await Task.sleep(for: .seconds(1))
        #expect(!chat.isRunning && chat.queue.isEmpty)
        let rows = try await filed(rt, chat)
        #expect(rows.filter { $0.role == "assistant" }.count == 1)
        #expect(rows.filter { $0.role == "user" && $0.text == "and the shed" }.count == 1)
        await noTrips(gateway)
    }

    @Test func aGroupChatIsDisbandedAndGoneFromTheList() async throws {
        let (rt, gateway) = await runtime()
        defer { Task { await rt.stop() } }
        let caps = try await rt.rpc("groups.capabilities")
        #expect(caps["methods"]?.arrayValue?.contains { $0.stringValue == "groups.disband" } == true)
        let gone = try await rt.rpc("groups.disband", ["room_id": .string("room-weekend")])
        #expect(gone["disbanded"]?.boolValue == true)
        let list = try await rt.rpc("groups.list")
        #expect(list["rooms"]?.arrayValue?.contains { $0["room_id"]?.stringValue == "room-weekend" } == false)
        // A room the demo hasn't got is refused, as the gateway refuses it.
        await #expect(throws: (any Error).self) { _ = try await rt.rpc("groups.disband", ["room_id": .string("room-weekend")]) }
        await noTrips(gateway)
    }

    @Test func restartingTheGatewayFinishesDone() async throws {
        let (rt, gateway) = await runtime()
        defer { Task { await rt.stop() } }
        await rt.maintenance.restartGateway(runtime: rt)
        #expect(rt.maintenance.phase == .finished("Restarting gateway: done", exitCode: 0))
        #expect(rt.maintenance.actionLog.last == "gateway up (pid 4243)")
        await waitUntil { rt.socketState.isOpen }
        #expect(rt.socketState.isOpen)
        let status: JSONValue = try await rt.api.get("/api/status", query: [])
        #expect(status["gateway"]?["pid"]?.intValue == 4243)
        await noTrips(gateway)
    }

    @Test func runningDoctorReadsAsAReport() async throws {
        let (rt, gateway) = await runtime()
        defer { Task { await rt.stop() } }
        // As System's Run doctor reads them (MaintenanceViews.runDoctor): the POST's answer as text, then the output.
        let started: JSONValue = try await rt.api.send("POST", "/api/ops/doctor", body: EmptyBody())
        #expect(started.displayText == "Running hermes doctor…")
        let st: JSONValue = try await rt.api.get("/api/actions/doctor/status", query: [])
        let report = try #require(st["output"]?.stringValue)
        #expect(report.hasSuffix("All checks passed."))
        #expect(!report.hasPrefix("{"))
        #expect(!report.contains("\u{2014}") && !report.contains("\u{2013}"), "no dashes in what a person reads")
        await noTrips(gateway)
    }

    @Test func dictationHearsNoProviderAndFallsBackToTheDevice() async throws {
        let (rt, gateway) = await runtime()
        defer { Task { await rt.stop() } }
        do {
            _ = try await GatewayVoiceAPI(api: rt.api).transcribe(Data([0, 1, 2]))
            Issue.record("the demo transcribed a recording itself")
        } catch {
            // Automatic (the Speech default) takes this as "no provider" and transcribes on the device.
            #expect(VoiceRouting.isNoProvider(error))
            #expect(error.localizedDescription.contains("dictation uses this device"))
        }
        await noTrips(gateway)
    }
}

/// The line the demo's reply ends with for words steered into its turn, as the tests read it.
private enum DemoLiveSteer {
    static let line = DemoGateway.steered(["keep it short"])
}
