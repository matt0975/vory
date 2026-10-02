import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// End-to-end checks against a real gateway. Skipped unless the test runner has
/// HERMES_E2E_URL and HERMES_E2E_TOKEN (pass them as TEST_RUNNER_HERMES_E2E_URL=… to xcodebuild).
@Suite(.serialized) struct GatewayIntegrationTests {
    static var env: (url: String, token: String)? {
        let e = ProcessInfo.processInfo.environment
        if let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty { return (u, t) }
        // Fallback for app-hosted runs: a small config file dropped into the simulator's shared tmp.
        if let data = FileManager.default.contents(atPath: NSTemporaryDirectory() + "hermes-e2e.json"),
           let obj = try? JSONDecoder().decode([String: String].self, from: data), let u = obj["url"], let t = obj["token"] { return (u, t) }
        print("e2e skipped: no HERMES_E2E_URL/HERMES_E2E_TOKEN (env keys: \(e.keys.filter { $0.contains("HERMES") || $0.hasPrefix("TEST_RUNNER") }.sorted()))")
        return nil
    }

    @Test func testConnectionPassesAllLegs() async throws {
        guard let env = Self.env else { return }
        let gateway = try GatewayURL.normalize(env.url)
        let conn = GatewayConnection(name: "e2e", gateway: gateway, authMode: .sessionToken)
        let secrets = GatewaySecrets(sessionToken: env.token)
        let outcome = await ConnectionTester.run(connection: conn, secrets: secrets) { _ in }
        for s in outcome.steps { print("e2e step", s.title, s.status) }
        #expect(outcome.succeeded)
        #expect(outcome.version != nil)
    }

    @Test func restEndpointsAnswerJSON() async throws {
        guard let env = Self.env else { return }
        let gateway = try GatewayURL.normalize(env.url)
        let api = HermesAPI(gateway: gateway, signer: RequestSigner(authMode: .sessionToken, sessionToken: env.token))
        let profiles: ProfilesResponse = try await api.get("/api/profiles")
        #expect(!profiles.profiles.isEmpty)
        let options: ModelOptionsResult = try await api.get("/api/model/options")
        #expect(!options.providers.isEmpty)
        let config: JSONValue = try await api.get("/api/config")
        #expect(config["config"] != nil || config["approvals"] != nil)
        let schema: ConfigSchemaResponse = try await api.get("/api/config/schema")
        #expect(schema.fields["approvals.mode"]?.type == "select")
        let toolsets: [ToolsetInfo] = try await api.get("/api/tools/toolsets")
        #expect(!toolsets.isEmpty)
        let envVars: [String: EnvVarInfo] = try await api.get("/api/env")
        #expect(!envVars.isEmpty)
    }

    @Test func websocketStreamsATurn() async throws {
        guard let env = Self.env else { return }
        let gateway = try GatewayURL.normalize(env.url)
        let collector = EventCollector()
        let socket = GatewaySocket(
            urlProvider: { (RequestSigner.websocketURL(gateway: gateway, token: env.token, ticket: nil), [:]) },
            onEvent: { ev in Task { await collector.add(ev) } },
            onState: { _ in },
            onServerRequest: { req in
                // Answer any approval with "once" so the test never hangs.
                req.method == "approval" ? ["choice": "once"] : nil
            },
            onReconnected: {})
        await socket.connect()
        try await socket.waitUntilReady(timeout: 30)
        let caps = try await socket.call("client.capabilities", params: ["server_requests": true])
        #expect(caps["server_requests"]?.arrayValue?.contains(.string("approval")) == true)
        let pong = try await socket.call("ping")
        #expect(pong["pong"]?.boolValue == true)

        let created = try await socket.call("session.create", params: ["cols": 80])
        let sid = try #require(created["session_id"]?.stringValue)
        let stored = created["stored_session_id"]?.stringValue ?? sid
        print("e2e session", sid, stored)

        let submit = try await socket.call("prompt.submit", params: ["session_id": .string(sid), "text": "Reply with exactly the single word: pong"], timeout: 60)
        #expect(submit["status"]?.stringValue != nil)

        let deadline = Date().addingTimeInterval(180)
        var complete: GatewayEvent?
        while Date() < deadline {
            if let c = await collector.first(where: { $0.type == "message.complete" && $0.sessionID == sid }) { complete = c; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let done = try #require(complete, "message.complete never arrived")
        let deltas = await collector.count { $0.type == "message.delta" && $0.sessionID == sid }
        let finalText = done.payload["text"]?.stringValue ?? ""
        print("e2e deltas=\(deltas) status=\(done.payload["status"]?.stringValue ?? "?") text=\(finalText.prefix(80))")
        let turnError = done.payload["error"]?.stringValue ?? ""
        if turnError.localizedCaseInsensitiveContains("provider") {
            // The gateway has no model provider configured: the transport, session and error surfaces are
            // verified, but streaming cannot be. Reported, not failed, so CI on a bare install stays green.
            print("e2e streaming skipped: gateway has no AI provider configured (\(turnError))")
            #expect(done.payload["status"]?.stringValue == "error")
        } else {
            #expect(turnError.isEmpty, "turn error: \(turnError)")
            #expect(!finalText.isEmpty)
            #expect(deltas >= 1, "expected streamed deltas")
            if let usage = try? done.payload["usage"]?.decode(Usage.self) { #expect((usage.output ?? 0) > 0) }
            let usage: Usage = try await socket.call("session.usage", params: ["session_id": .string(sid)]).decode()
            #expect((usage.calls ?? 0) >= 1)
            let breakdown: ContextBreakdown = try await socket.call("session.context_breakdown", params: ["session_id": .string(sid)]).decode()
            #expect(breakdown.contextMax > 0)
            #expect(!breakdown.categories.isEmpty)
        }

        let catalog: CommandsCatalog = try await socket.call("commands.catalog", params: ["session_id": .string(sid)]).decode()
        #expect(!catalog.allPairs.isEmpty)

        // Clean up: close the live session and delete the stored row so nothing lingers on the user's gateway.
        _ = try? await socket.call("session.close", params: ["session_id": .string(sid)])
        _ = try? await socket.call("session.delete", params: ["session_id": .string(stored)])
        await socket.disconnect()
    }
}

extension GatewayIntegrationTests {
    /// Two devices with the same chat open: one sends, and the other shows the prompt as well as
    /// the reply. The gateway fans a chat's events out to everyone attached, but the events
    /// carry the reply only; the watching device fetches the prompt when the turn starts.
    @MainActor @Test func aTurnSentFromOneDeviceShowsOnTheOther() async throws {
        guard let env = Self.env else { return }
        let store = ConnectionStore()
        let conn = GatewayConnection(name: "e2e two devices", gateway: try GatewayURL.normalize(env.url), authMode: .sessionToken)
        try store.upsert(conn, secrets: GatewaySecrets(sessionToken: env.token))
        defer { store.delete(id: conn.id) }
        let mac = GatewayRuntime(connection: conn, store: store)
        let phone = GatewayRuntime(connection: conn, store: store)
        await mac.start()
        await phone.start()

        // An existing chat, opened on both: the mock shares a session between the clients that
        // resume it, the way the real gateway does.
        let list: SessionListResponse = try await mac.api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "5")], profile: mac.selectedProfile)
        let stored = try #require(list.sessions.first?.id)
        let sending = try await mac.openChat(storedID: stored, title: nil, waitForResume: true)
        let watching = try await phone.openChat(storedID: stored, title: nil, waitForResume: true)
        #expect(sending.runtimeID == watching.runtimeID, "the two clients are not attached to the same live session")

        func userTexts(_ chat: ChatSession) -> [String] {
            chat.items.compactMap { if case .user(let t, _) = $0.kind { return t }; return nil }
        }
        func replies(_ chat: ChatSession) -> Int {
            chat.items.filter { if case .assistant(let t, _, let streaming) = $0.kind { return !streaming && !t.isEmpty }; return false }.count
        }
        let before = (sent: replies(sending), watched: replies(watching))
        let prompt = "Reply with exactly the single word: pong \(UUID().uuidString.prefix(6))"
        _ = await sending.send(prompt)

        var sawItRunning = false
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            // The mock's scripted turn asks for an approval; either device may answer it.
            if let card = sending.cards.first(where: { $0.method == "approval" }) { await sending.respond(card: card, result: ["choice": "once"]) }
            if watching.isRunning { sawItRunning = true }
            if !sending.isRunning, !watching.isRunning, replies(sending) > before.sent, replies(watching) > before.watched { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        print("e2e two devices: sender items \(sending.items.count), watcher items \(watching.items.count), watcher saw it running \(sawItRunning)")
        #expect(replies(sending) > before.sent, "the sending device got no reply")
        #expect(sawItRunning, "the watching device never showed the turn as running")
        #expect(replies(watching) > before.watched, "the watching device did not show the reply")
        #expect(userTexts(watching).filter { $0 == prompt }.count == 1, "the watching device should show the other device's prompt, once")
        #expect(!watching.isRunning)

        await mac.stop()
        await phone.stop()
    }
}

extension GatewayIntegrationTests {
    /// Two devices with the same chat open, and the bot asks for an approval: both show the
    /// card. One answers; nothing tells the other, so its card used to stay up for good. It now
    /// goes once the gateway no longer lists the approval as waiting.
    @MainActor @Test func anApprovalAnsweredOnOneDeviceLeavesTheOther() async throws {
        guard let env = Self.env, env.token == "mock-token" else { return }
        let store = ConnectionStore()
        let conn = GatewayConnection(name: "e2e approval", gateway: try GatewayURL.normalize(env.url), authMode: .sessionToken)
        try store.upsert(conn, secrets: GatewaySecrets(sessionToken: env.token))
        defer { store.delete(id: conn.id) }
        let mac = GatewayRuntime(connection: conn, store: store)
        let phone = GatewayRuntime(connection: conn, store: store)
        await mac.start()
        await phone.start()
        let list: SessionListResponse = try await mac.api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "5")], profile: mac.selectedProfile)
        let stored = try #require(list.sessions.first?.id)
        let answering = try await mac.openChat(storedID: stored, title: nil, waitForResume: true)
        let watching = try await phone.openChat(storedID: stored, title: nil, waitForResume: true)

        _ = await answering.send("Clean up the log host \(UUID().uuidString.prefix(6))")
        func approval(_ chat: ChatSession) -> PendingCard? { chat.cards.first { $0.method == "approval" } }
        var deadline = Date().addingTimeInterval(60)
        while Date() < deadline, approval(answering) == nil || approval(watching) == nil { try await Task.sleep(for: .milliseconds(100)) }
        let card = try #require(approval(answering), "the sending device never got the approval")
        try #require(approval(watching) != nil, "the watching device never got the approval")
        #expect(phone.needsAttention.contains(stored))

        // Long enough that the card is no longer "just arrived" on the watching device.
        try await Task.sleep(for: .seconds(ChatSession.cardGrace + 0.5))
        await answering.respond(card: card, result: ["choice": "once"])

        var goneWhileRunning = false
        deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if approval(watching) == nil, watching.isRunning { goneWhileRunning = true }
            if !answering.isRunning, !watching.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("e2e approval: card left the watching device while the turn was still running: \(goneWhileRunning)")
        #expect(watching.cards.isEmpty, "the card answered on the other device is still showing")
        #expect(!phone.needsAttention.contains(stored), "the chat still asks for attention on the watching device")
        func notes(_ chat: ChatSession) -> [String] { chat.items.compactMap { if case .system(let t, _) = $0.kind { return t }; return nil } }
        #expect(notes(watching).contains("Answered on another device"))
        #expect(!notes(answering).contains("Answered on another device"), "the device that answered should not be told it was answered elsewhere")
        #expect(goneWhileRunning, "the card should go as the turn moves on, not only when it ends")

        await mac.stop()
        await phone.stop()
    }
}

actor EventCollector {
    private var events: [GatewayEvent] = []
    func add(_ e: GatewayEvent) { events.append(e) }
    func first(where p: (GatewayEvent) -> Bool) -> GatewayEvent? { events.first(where: p) }
    func count(_ p: (GatewayEvent) -> Bool) -> Int { events.filter(p).count }
}
