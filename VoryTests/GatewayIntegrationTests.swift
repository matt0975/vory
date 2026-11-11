import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Where the E2E settings come from, in order of precedence per key:
///  1. HERMES_E2E_* in the runner's environment (TEST_RUNNER_HERMES_E2E_* for xcodebuild);
///  2. a KEY=VALUE file kept outside the repo: $HERMES_E2E_ENV_FILE, else ~/.config/vory/e2e.env
///     in the real home directory (a simulator's own HOME is a sandbox, so it is looked up by uid);
///  3. the legacy hermes-e2e.json in the simulator's tmp (keys: url, token).
/// Keys: HERMES_E2E_URL, plus either HERMES_E2E_TOKEN (session token) or
/// HERMES_E2E_USER + HERMES_E2E_PASSWORD (exchanged for a session; never stored, never printed).
struct E2EConfig {
    var url: String
    var token: String?
    var user: String?
    var password: String?

    /// Files tried in order; the first readable one wins. Names only, never values.
    static var candidatePaths: [String] {
        let e = ProcessInfo.processInfo.environment
        var homes: [String] = []
        if let p = e["HERMES_E2E_ENV_FILE"], !p.isEmpty { return [p] }
        if let h = e["SIMULATOR_HOST_HOME"], !h.isEmpty { homes.append(h) }
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { homes.append(String(cString: dir)) }
        var seen = Set<String>()
        return homes.filter { seen.insert($0).inserted }.map { $0 + "/.config/vory/e2e.env" }
    }

    /// Why the E2E tests would be skipped: the paths tried, whether each was readable, and which keys are missing.
    static func diagnosis() -> String {
        var parts: [String] = []
        for p in candidatePaths {
            let exists = FileManager.default.fileExists(atPath: p)
            let readable = FileManager.default.isReadableFile(atPath: p)
            parts.append("\(p) [exists=\(exists) readable=\(readable)]")
        }
        let v = merged()
        let missing = ["HERMES_E2E_URL"].filter { v[$0] == nil }
            + ((v["HERMES_E2E_TOKEN"] != nil || (v["HERMES_E2E_USER"] != nil && v["HERMES_E2E_PASSWORD"] != nil)) ? [] : ["HERMES_E2E_TOKEN or HERMES_E2E_USER+HERMES_E2E_PASSWORD"])
        return "tried " + parts.joined(separator: ", ") + "; keys found: " + v.keys.sorted().joined(separator: ",") + "; missing: " + (missing.isEmpty ? "none" : missing.joined(separator: ", "))
    }

    /// True when HERMES_E2E_REQUIRED is set (scheme/environment, or a line in the settings file): the run then
    /// insists the E2E settings exist. Independent of which CI runs the tests.
    static func required() -> Bool { merged()["HERMES_E2E_REQUIRED"] != nil }

    private static func merged() -> [String: String] {
        var v = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("HERMES_E2E_") && !$0.value.isEmpty }
        for (k, val) in fileValues() where v[k] == nil { v[k] = val }
        if let data = FileManager.default.contents(atPath: NSTemporaryDirectory() + "hermes-e2e.json"),
           let obj = try? JSONDecoder().decode([String: String].self, from: data) {
            if v["HERMES_E2E_URL"] == nil, let u = obj["url"], !u.isEmpty { v["HERMES_E2E_URL"] = u }
            if v["HERMES_E2E_TOKEN"] == nil, let t = obj["token"], !t.isEmpty { v["HERMES_E2E_TOKEN"] = t }
        }
        return v
    }

    static func load() -> E2EConfig? {
        let v = merged()
        guard let url = v["HERMES_E2E_URL"] else { return nil }
        let c = E2EConfig(url: url, token: v["HERMES_E2E_TOKEN"], user: v["HERMES_E2E_USER"], password: v["HERMES_E2E_PASSWORD"])
        return c.token != nil || (c.user != nil && c.password != nil) ? c : nil
    }

    private static func fileValues() -> [String: String] {
        guard let text = candidatePaths.lazy.compactMap({ try? String(contentsOfFile: $0, encoding: .utf8) }).first else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.count >= 2, let f = val.first, f == val.last, f == "\"" || f == "'" { val = String(val.dropFirst().dropLast()) }
            if !val.isEmpty { out[key] = val }
        }
        return out
    }

    /// A signed-in view of the gateway: the URL, how requests authenticate, and the secrets to do it.
    func resolve() async throws -> (gateway: GatewayURL, mode: AuthMode, secrets: GatewaySecrets) {
        let gateway = try GatewayURL.normalize(url)
        if let token, !token.isEmpty { return (gateway, .sessionToken, GatewaySecrets(sessionToken: token)) }
        let access = CloudflareAccess()
        let providers = (try? await NativeAuthClient.providers(gateway: gateway, access: access)) ?? []
        let provider = providers.first(where: { $0.supportsPassword ?? false })?.name ?? "basic"
        let secrets = try await NativeAuthClient.signInWithPassword(gateway: gateway, provider: provider, username: user ?? "", password: password ?? "", access: access)
        return (gateway, .password, secrets)
    }
}

/// End-to-end checks against a real gateway. Reported as skipped unless E2EConfig finds settings.
/// The streaming test names its prompt `vory-e2e-…` and deletes the session it creates.
@Suite(.serialized) struct GatewayIntegrationTests {
    static let configured: Bool = {
        let ok = E2EConfig.load() != nil
        if !ok { print("e2e skipped:", E2EConfig.diagnosis()) }
        return ok
    }()

    /// The URL and session token, for the two-device tests, which attach a second connection by
    /// token (a password sign-in would mean a second exchange).
    static var env: (url: String, token: String)? {
        guard let c = E2EConfig.load(), let t = c.token, !t.isEmpty else { return nil }
        return (c.url, t)
    }

    /// Diagnostic: fails with the paths tried and the keys missing (never values) when the E2E settings
    /// cannot be found. Runs only when HERMES_E2E_REQUIRED is set, so no CI has to be special-cased; without it
    /// the E2E tests are reported as skipped instead.
    @Test(.enabled(if: E2EConfig.required(), "set HERMES_E2E_REQUIRED=1 to require the E2E settings"))
    func e2eSettingsAreFound() {
        #expect(E2EConfig.load() != nil, "\(E2EConfig.diagnosis())")
    }

    @Test(.enabled(if: GatewayIntegrationTests.configured, "no HERMES_E2E_URL with a token or user/password"))
    func testConnectionPassesAllLegs() async throws {
        let cfg = try #require(E2EConfig.load())
        let (gateway, mode, secrets) = try await cfg.resolve()
        let conn = GatewayConnection(name: "e2e", gateway: gateway, authMode: mode)
        let outcome = await ConnectionTester.run(connection: conn, secrets: secrets) { _ in }
        for s in outcome.steps { print("e2e step", s.title, s.status) }
        #expect(outcome.succeeded)
        #expect(outcome.version != nil)
    }

    @Test(.enabled(if: GatewayIntegrationTests.configured, "no HERMES_E2E_URL with a token or user/password"))
    func restEndpointsAnswerJSON() async throws {
        let cfg = try #require(E2EConfig.load())
        let (gateway, mode, secrets) = try await cfg.resolve()
        let api = HermesAPI(gateway: gateway, signer: RequestSigner(authMode: mode, secrets: secrets))
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

    @Test(.enabled(if: GatewayIntegrationTests.configured, "no HERMES_E2E_URL with a token or user/password"))
    func websocketStreamsATurn() async throws {
        let cfg = try #require(E2EConfig.load())
        let (gateway, mode, secrets) = try await cfg.resolve()
        let api = HermesAPI(gateway: gateway, signer: RequestSigner(authMode: mode, secrets: secrets))
        let collector = EventCollector()
        let socket = GatewaySocket(
            urlProvider: {
                var ticket: String?
                if mode.usesBearer {
                    let r: [String: JSONValue] = try await api.send("POST", "/api/auth/ws-ticket", body: EmptyBody())
                    ticket = r["ticket"]?.stringValue
                }
                return (RequestSigner.websocketURL(gateway: gateway, token: secrets.sessionToken, ticket: ticket), secrets.access.headers)
            },
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

        let created = try await socket.call("session.create")
        let sid = try #require(created["session_id"]?.stringValue)
        let stored = created["stored_session_id"]?.stringValue ?? sid
        print("e2e session", sid, stored)

        // Clean up: close the live session and delete the stored row so nothing lingers on the gateway.
        func cleanup() async {
            _ = try? await socket.call("session.close", params: ["session_id": .string(sid)])
            _ = try? await socket.call("session.delete", params: ["session_id": .string(stored)])
            await socket.disconnect()
        }

        let marker = "vory-e2e-\(UUID().uuidString.prefix(8))"
        let submit: JSONValue
        do {
            submit = try await socket.call("prompt.submit", params: ["session_id": .string(sid), "text": .string("\(marker): reply with exactly the single word: pong")], timeout: 60)
        } catch {
            await cleanup()
            throw error
        }
        #expect(submit["status"]?.stringValue != nil)

        let deadline = Date().addingTimeInterval(180)
        var complete: GatewayEvent?
        while Date() < deadline {
            if let c = await collector.first(where: { $0.type == "message.complete" && $0.sessionID == sid }) { complete = c; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let done = complete else {
            await cleanup()
            Issue.record("message.complete never arrived")
            return
        }
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

        await cleanup()
    }

    /// Removes every stored session whose title or first prompt starts with `vory-e2e` (any case), including
    /// the chats the UI test leaves behind, then re-lists to prove they are gone. Nothing else is touched.
    @Test(.enabled(if: GatewayIntegrationTests.configured, "no HERMES_E2E_URL with a token or user/password"))
    func cleansUpLeftoverE2ESessions() async throws {
        let cfg = try #require(E2ECleanup.config())
        let r = try await E2ECleanup.removeLeftovers(cfg)
        print("e2e cleanup found=\(r.found) deleted=\(r.deleted) remaining=\(r.remaining)")
        let report = "found \(r.found), deleted \(r.deleted), still listed \(r.remaining). " + r.diagnostics.joined(separator: " | ")
        // Finding nothing is fine on a clean gateway. Set HERMES_E2E_EXPECT_LEFTOVERS when a UI run just
        // created chats, so a blind listing or filter cannot pass as "clean".
        if ProcessInfo.processInfo.environment["HERMES_E2E_EXPECT_LEFTOVERS"] != nil {
            #expect(r.found > 0, "no vory-e2e sessions found. \(report)")
        }
        #expect(r.deleted == r.found && r.remaining == 0, "\(report)")
    }
}

enum E2ECleanup {
    static func config() -> E2EConfig? { E2EConfig.load() }

    static func isE2E(_ s: StoredSession) -> Bool {
        [s.title, s.preview].compactMap { $0 }.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("vory-e2e") }
    }

    /// IDs of matching sessions, plus a diagnostic line per profile (counts and error text, never titles)
    /// so a filter or listing that sees nothing is visible instead of passing silently.
    static func leftoverIDs(api: HermesAPI) async throws -> (ids: Set<String>, diagnostics: [String]) {
        let profiles: ProfilesResponse = try await api.get("/api/profiles")
        var names: [String?] = [nil]
        names += profiles.profiles.map { $0.name }
        var ids = Set<String>()
        var diag: [String] = []
        for p in names {
            let label = p ?? "(no profile)"
            let query = [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "100")]
            do {
                let r: SessionListResponse = try await api.get("/api/sessions", query: query, profile: p)
                let hits = r.sessions.filter { isE2E($0) }
                for s in hits { ids.insert(s.id) }
                let sources = Set(r.sessions.compactMap { $0.source }).sorted().joined(separator: "/")
                diag.append("\(label): listed \(r.sessions.count) of total \(r.total.map(String.init) ?? "?"), matched \(hits.count), sources [\(sources)]")
            } catch {
                diag.append("\(label): list failed: \(String(describing: error).replacingOccurrences(of: "\n", with: " ").prefix(160))")
            }
        }
        return (ids, diag)
    }

    static func removeLeftovers(_ cfg: E2EConfig) async throws -> (found: Int, deleted: Int, remaining: Int, diagnostics: [String]) {
        let (gateway, mode, secrets) = try await cfg.resolve()
        let api = HermesAPI(gateway: gateway, signer: RequestSigner(authMode: mode, secrets: secrets))
        let (ids, diag) = try await leftoverIDs(api: api)
        guard !ids.isEmpty else { return (0, 0, 0, diag) }
        let socket = GatewaySocket(
            urlProvider: {
                var ticket: String?
                if mode.usesBearer {
                    let r: [String: JSONValue] = try await api.send("POST", "/api/auth/ws-ticket", body: EmptyBody())
                    ticket = r["ticket"]?.stringValue
                }
                return (RequestSigner.websocketURL(gateway: gateway, token: secrets.sessionToken, ticket: ticket), secrets.access.headers)
            },
            onEvent: { _ in },
            onState: { _ in },
            onServerRequest: { _ in nil },
            onReconnected: {})
        await socket.connect()
        try await socket.waitUntilReady(timeout: 30)
        var deleted = 0
        var deleteErrors: [String] = []
        for id in ids {
            // A session another client left open is "active" and cannot be deleted: take it over with
            // session.resume (which hands back a live id), close that, then delete the stored row.
            if let r = try? await socket.call("session.resume", params: ["session_id": .string(id), "cols": 80]) {
                let live = r["session_id"]?.stringValue ?? id
                _ = try? await socket.call("session.close", params: ["session_id": .string(live)])
            }
            do { _ = try await socket.call("session.delete", params: ["session_id": .string(id)]); deleted += 1 }
            catch { deleteErrors.append(error.localizedDescription) }
        }
        await socket.disconnect()
        let after = try await leftoverIDs(api: api)
        return (ids.count, deleted, after.ids.count, diag + deleteErrors.prefix(3).map { "delete failed: \($0)" })
    }
}

extension GatewayIntegrationTests {
    /// #665: a new chat opens on a gateway that refuses keys a method's contract doesn't declare, as Hermes v0.23.0's
    /// session authority does (4001 "invalid_params"). Against the mock with --strict-params it was refused while
    /// session.create sent "cols"; against the default mock it opens either way.
    @MainActor @Test func aNewChatOpensOnAGatewayThatRefusesUnknownKeys() async throws {
        guard let env = Self.env else { return }
        let store = ConnectionStore()
        let conn = GatewayConnection(name: "e2e strict create", gateway: try GatewayURL.normalize(env.url), authMode: .sessionToken)
        try store.upsert(conn, secrets: GatewaySecrets(sessionToken: env.token))
        defer { store.delete(id: conn.id) }
        let runtime = GatewayRuntime(connection: conn, store: store)
        await runtime.start()
        let chat = ChatSession.draft(runtime: runtime, profile: runtime.selectedProfile)
        do {
            try await chat.create()
        } catch let e as RPCError {
            Issue.record("session.create refused: \(e.code) \(e.message) \(e.data.map { "\($0)" } ?? "")")
        }
        #expect(!chat.runtimeID.isEmpty, "no session from session.create")
        print("e2e strict create:", chat.runtimeID.isEmpty ? "none" : chat.runtimeID)
    }

    /// #665, part A: an approval is shown and answered on a gateway served by Hermes's session authority, which asks
    /// by event and takes its answer by approval.respond (the mock with --authority), and on one that asks by request
    /// (the default mock). The mock's "tour" turn asks one approval, Allow once or Deny, and says "Done." once allowed.
    @MainActor @Test func anApprovalIsShownAndAnsweredOnEitherWire() async throws {
        guard let env = Self.env else { return }
        let store = ConnectionStore()
        let conn = GatewayConnection(name: "e2e approval wire", gateway: try GatewayURL.normalize(env.url), authMode: .sessionToken)
        try store.upsert(conn, secrets: GatewaySecrets(sessionToken: env.token))
        defer { store.delete(id: conn.id) }
        let runtime = GatewayRuntime(connection: conn, store: store)
        await runtime.start()
        let chat = try await runtime.newChat()
        _ = await chat.send("tour")
        var deadline = Date().addingTimeInterval(20)
        while chat.cards.first(where: { $0.method == "approval" }) == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
        let card = try #require(chat.cards.first { $0.method == "approval" }, "no approval card in 20 s")
        print("e2e approval wire: card", card.id, card.approval?.offeredChoices ?? [])
        await chat.respond(card: card, result: ["choice": "once"])
        func replied() -> Bool { chat.items.contains { if case .assistant(let t, _, _) = $0.kind { return t.contains("Done.") }; return false } }
        deadline = Date().addingTimeInterval(20)
        while !replied(), Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
        #expect(replied(), "the turn didn't go on after Allow once")
        #expect(chat.cards.isEmpty)
    }
}

/// #666: the session calls on either wire. Against the mock with --authority, the five calls Hermes v0.23.0's session
/// authority doesn't serve answer -32601 and a steer needs the running turn's generation, so these were red until the
/// app took the 0.23 ways (session.stats, session.mutate, session.detach). Against the default mock they're green either
/// way. Move to project is `aChatMovesToAProjectAndOut` (ProjectsAndGoalsTests.swift), on either wire as well.
extension GatewayIntegrationTests {
    /// A started runtime on the mock, and what to remove after.
    struct E2ERuntime { let runtime: GatewayRuntime; let store: ConnectionStore; let conn: GatewayConnection }

    @MainActor private func e2eRuntime(_ name: String) async throws -> E2ERuntime? {
        guard let env = Self.env, env.token == "mock-token" else { return nil }
        let store = ConnectionStore()
        let conn = GatewayConnection(name: name, gateway: try GatewayURL.normalize(env.url), authMode: .sessionToken)
        try store.upsert(conn, secrets: GatewaySecrets(sessionToken: env.token))
        let runtime = GatewayRuntime(connection: conn, store: store)
        await runtime.start()
        return E2ERuntime(runtime: runtime, store: store, conn: conn)
    }

    @MainActor private func waitFor(_ seconds: TimeInterval, _ done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
    }

    @MainActor @Test func theRingFillsOnOpenOnEitherWire() async throws {
        guard let e = try await e2eRuntime("e2e ring") else { return }
        defer { e.store.delete(id: e.conn.id) }
        let runtime = e.runtime
        let chat = try await runtime.newChat()
        print("e2e ring: authority \(runtime.sessionAuthority), usage \(String(describing: chat.usage))")
        #expect(chat.usage?.contextMax != nil, "no context figures on open")
        #expect((chat.usage?.contextUsed ?? 0) > 0)
        await runtime.stop()
    }

    @MainActor @Test func aSteerReachesARunningTurnOnEitherWire() async throws {
        guard let e = try await e2eRuntime("e2e steer") else { return }
        defer { e.store.delete(id: e.conn.id) }
        let runtime = e.runtime
        let chat = try await runtime.newChat()
        let created = chat.executionGeneration ?? 0
        _ = await chat.send("long 15")
        // On the session authority a steer names the running turn, which the chat learns from the turn's claim (its
        // session.info), a moment after the send: prompt.submit's answer is the admission, before the turn has a
        // generation. On the old wire, running is enough.
        func started() -> Bool { chat.isRunning && (!runtime.sessionAuthority || (chat.executionGeneration ?? 0) > created) }
        await waitFor(15) { started() }
        try #require(started(), "the turn never started on the gateway")
        chat.queue = [QueuedMessage(text: "and keep the last week's batches")]
        await chat.steerQueued(chat.queue[0].id)
        let steered = chat.items.contains { if case .steer(let t, let s) = $0.kind { return t == "and keep the last week's batches" && s == "queued" }; return false }
        print("e2e steer: authority \(runtime.sessionAuthority), steered \(steered), queue \(chat.queue.map(\.text)), banner \(chat.banner ?? "none")")
        #expect(steered, "the steer didn't reach the running turn")
        #expect(chat.queue.isEmpty)
        #expect(chat.banner == nil)
        await chat.stop()
        await runtime.stop()
    }

    @MainActor @Test func aRenameSticksOnEitherWire() async throws {
        guard let e = try await e2eRuntime("e2e rename") else { return }
        defer { e.store.delete(id: e.conn.id) }
        let runtime = e.runtime
        let chat = try await runtime.newChat()
        let name = "E2E rename \(UUID().uuidString.prefix(6))"
        await chat.rename(name)
        print("e2e rename: authority \(runtime.sessionAuthority), title \(chat.title)")
        #expect(chat.title == name)
        await runtime.stop()
    }

    @MainActor @Test func anEditAndResendTakesTheTurnBackOnEitherWire() async throws {
        guard let e = try await e2eRuntime("e2e edit resend") else { return }
        defer { e.store.delete(id: e.conn.id) }
        let runtime = e.runtime
        let chat = try await runtime.newChat()
        _ = await chat.send("short link")
        await waitFor(5) { chat.isRunning }
        await waitFor(30) { !chat.isRunning }
        try #require(!chat.isRunning, "the first turn didn't end")
        let id = try #require(chat.lastResendableID, "nothing to edit")
        #expect(chat.beginEdit(id))
        let outcome = await chat.resend("short link, edited")
        let undos: JSONValue = try await runtime.api.get("/api/_mock/undos", profile: runtime.selectedProfile)
        let mine = (undos["undos"]?.arrayValue ?? []).filter { $0["session_id"]?.stringValue == chat.runtimeID }
        print("e2e edit resend: authority \(runtime.sessionAuthority), outcome \(outcome), taken back \(mine)")
        #expect(outcome == .sent)
        #expect(mine.count == 1, "the gateway should have taken back exactly one turn")
        #expect((mine.first?["removed"]?.intValue ?? 0) >= 2)
        await waitFor(30) { !chat.isRunning }
        await runtime.stop()
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

/// The Board's writes against the mock: a change the server refuses is refused with the
/// server's own words still there for the screen after the board has been read again (the read
/// that follows a refusal used to wipe them, and a refused move looked like nothing at all).
@Suite(.serialized) struct KanbanRefusalIntegrationTests {
    @MainActor @Test func aRefusedMoveKeepsTheServersWordsAfterTheReadThatFollows() async throws {
        guard let env = GatewayIntegrationTests.env, env.token == "mock-token" else { return }
        let store = ConnectionStore()
        let conn = GatewayConnection(name: "e2e board refusal", gateway: try GatewayURL.normalize(env.url), authMode: .sessionToken)
        try store.upsert(conn, secrets: GatewaySecrets(sessionToken: env.token))
        defer { store.delete(id: conn.id) }
        let rt = GatewayRuntime(connection: conn, store: store)
        await rt.start()
        defer { Task { await rt.stop() } }
        let kanban = rt.kanban
        await kanban.probe()
        await kanban.refresh()
        let ready = try #require(kanban.board?.tasks(in: .ready).first, "the mock's board has a Ready task")
        // Done without a summary: the mock answers 409 with its reason, as the server does.
        let ok = await kanban.move(ready, to: .done)
        #expect(!ok)
        #expect(kanban.lastError?.contains("marked done") == true, "the refusal should be there for the screen: \(kanban.lastError ?? "nil")")
        #expect(kanban.lastRefusal == kanban.lastError)
        #expect(kanban.board?.task(id: ready.id)?.column == .ready, "the task stays where it was")
        // The next successful write clears it.
        #expect(await kanban.setPriority(ready, ready.priority ?? 0))
        #expect(kanban.lastRefusal == nil && kanban.lastError == nil)
    }
}

/// Quick answers against the mock: voice mode turns the chat's reasoning down and fast on, keeps
/// what it had on disk for the restore, and puts it back when voice ends; off, it changes nothing.
@Suite(.serialized) struct QuickAnswersIntegrationTests {
    @MainActor @Test func voiceModeTurnsTheChatsReasoningDownAndPutsItBack() async throws {
        guard let env = GatewayIntegrationTests.env, env.token == "mock-token" else { return }
        let store = ConnectionStore()
        let conn = GatewayConnection(name: "e2e quick answers", gateway: try GatewayURL.normalize(env.url), authMode: .sessionToken)
        try store.upsert(conn, secrets: GatewaySecrets(sessionToken: env.token))
        defer { store.delete(id: conn.id) }
        let rt = GatewayRuntime(connection: conn, store: store)
        await rt.start()
        defer { Task { await rt.stop() } }
        let chat = try await rt.newChat()
        defer { rt.closeChat(chat) }
        let key = "voice.quick.restore." + chat.storedID
        let setting = UserDefaults.standard.object(forKey: VoiceSettings.quickAnswersKey)
        defer { UserDefaults.standard.set(setting, forKey: VoiceSettings.quickAnswersKey) }

        UserDefaults.standard.set(true, forKey: VoiceSettings.quickAnswersKey)
        await chat.beginQuickAnswers()
        #expect(chat.quickAnswersOn)
        let kept = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
        #expect(kept?["reasoning"] == "medium" && kept?["fast"] == "off", "what the chat had is kept for the restore: \(String(describing: kept))")
        await chat.endQuickAnswers()
        #expect(!chat.quickAnswersOn)
        #expect(UserDefaults.standard.dictionary(forKey: key) == nil)

        // Off: voice mode leaves the chat as it is.
        UserDefaults.standard.set(false, forKey: VoiceSettings.quickAnswersKey)
        await chat.beginQuickAnswers()
        #expect(!chat.quickAnswersOn && UserDefaults.standard.dictionary(forKey: key) == nil)
    }
}

/// #682: a new chat's first message is answered on either wire. Hermes v0.23's session authority (the mock with
/// --authority) admits a prompt.submit only with a non-empty submission_id or input_id and the keys its submission()
/// knows, else 4001 "invalid_params" with no fields; so this was red there while a message carried neither. Against the
/// default mock it's answered either way.
extension GatewayIntegrationTests {
    @MainActor @Test func aNewChatsFirstMessageIsAnsweredOnEitherWire() async throws {
        guard let e = try await e2eRuntime("e2e first message") else { return }
        defer { e.store.delete(id: e.conn.id) }
        let chat = try await e.runtime.newChat()
        _ = await chat.send("short link")
        func errors() -> [String] { chat.items.compactMap { if case .error(let t) = $0.kind { return t }; return nil } }
        func replied() -> Bool { chat.items.contains { if case .assistant(let t, _, let streaming) = $0.kind { return !t.isEmpty && !streaming }; return false } }
        await waitFor(20) { replied() || !errors().isEmpty }
        print("e2e first message: authority \(e.runtime.sessionAuthority),", errors().isEmpty ? "answered \(replied())" : "refused: \(errors())")
        #expect(errors().isEmpty, "the message was refused: \(errors())")
        #expect(replied(), "no reply in 20 s")
        await e.runtime.stop()
    }
}

/// #683: Stop ends a running turn on either wire. Hermes's session authority (the mock with --authority) takes a
/// session.interrupt only for the running turn's execution, else a bare 4001 "stale_generation" and the turn runs on;
/// so this was red there while Stop named none, and the refusal was dropped. Against the default mock it's green either
/// way. The mock's turn ends "interrupted" when a Stop is taken.
extension GatewayIntegrationTests {
    @MainActor @Test func aStopEndsARunningTurnOnEitherWire() async throws {
        guard let e = try await e2eRuntime("e2e stop") else { return }
        defer { e.store.delete(id: e.conn.id) }
        let runtime = e.runtime
        let chat = try await runtime.newChat()
        let created = chat.executionGeneration ?? 0
        _ = await chat.send("long 15")
        // As the steer test: on the authority the chat learns the turn's execution from its claim, a moment after the send.
        func started() -> Bool { chat.isRunning && (!runtime.sessionAuthority || (chat.executionGeneration ?? 0) > created) }
        await waitFor(15) { started() }
        try #require(started(), "the turn never started on the gateway")
        await chat.stop()
        await waitFor(10) { !chat.isRunning }
        let interrupted = chat.items.contains { if case .system(let t, _) = $0.kind { return t == "Interrupted" }; return false }
        print("e2e stop: authority \(runtime.sessionAuthority), running \(chat.isRunning), interrupted \(interrupted), banner \(chat.banner ?? "none")")
        #expect(chat.banner == nil, "the Stop was refused: \(chat.banner ?? "")")
        #expect(!chat.isRunning, "the turn ran on after Stop")
        #expect(interrupted, "no Interrupted line")
        await runtime.stop()
    }
}

/// #684: the Watch's Stop through this iPhone is answered with what the gateway said to it. With the mock's
/// MOCK_INTERRUPT_MOVED_ON=1 (and --authority) the first Stop finds the turn moved on and is refused stale_generation:
/// the Watch is answered with the words that ask for Stop again, where it was answered "ok", and the turn runs on. A Stop
/// sent once the chat has heard of the newer execution names it and ends the turn, and the refusal's line goes. It runs
/// only when the host says the mock has that fault (HERMES_E2E_INTERRUPT_MOVED_ON=1).
#if os(iOS)
extension GatewayIntegrationTests {
    static var interruptMovedOn: Bool { ProcessInfo.processInfo.environment["HERMES_E2E_INTERRUPT_MOVED_ON"] == "1" }

    @MainActor @Test(.enabled(if: GatewayIntegrationTests.interruptMovedOn, "the mock isn't run with MOCK_INTERRUPT_MOVED_ON"))
    func aStopFromTheWatchTheGatewayRefusesIsAnsweredSoAndStopAgainEndsTheTurn() async throws {
        guard let e = try await e2eRuntime("e2e watch stop") else { return }
        defer { e.store.delete(id: e.conn.id) }
        let runtime = e.runtime
        try #require(runtime.sessionAuthority, "the fault needs the mock's --authority")
        let chat = try await runtime.newChat()
        let created = chat.executionGeneration ?? 0
        _ = await chat.send("long 15")
        func started() -> Bool { chat.isRunning && (chat.executionGeneration ?? 0) > created }
        await waitFor(15) { started() }
        try #require(started(), "the turn never started on the gateway")
        let known = chat.executionGeneration ?? 0
        let first = await WatchSync.stopAnswer(chat)
        print("e2e watch stop 1: ok \(first["ok"] ?? "none"), error \(first["error"] ?? "none"), running \(chat.isRunning)")
        #expect(first["ok"] as? Bool == false, "the Watch was answered ok to a Stop the gateway refused")
        #expect(first["error"] as? String == "The reply couldn't be stopped. Try Stop again.")
        #expect(chat.isRunning, "the turn ended after a refused Stop")
        // The newer execution, as the gateway published it: the person's second press comes a moment later.
        await waitFor(5) { (chat.executionGeneration ?? 0) > known }
        let second = await WatchSync.stopAnswer(chat)
        await waitFor(10) { !chat.isRunning }
        let interrupted = chat.items.contains { if case .system(let t, _) = $0.kind { return t == "Interrupted" }; return false }
        print("e2e watch stop 2: ok \(second["ok"] ?? "none"), running \(chat.isRunning), interrupted \(interrupted), banner \(chat.banner ?? "none")")
        #expect(second["ok"] as? Bool == true, "the second Stop wasn't taken: \(second["error"] ?? "")")
        #expect(!chat.isRunning, "the turn ran on after the second Stop")
        #expect(interrupted, "no Interrupted line")
        #expect(chat.banner == nil, "the refusal's line stayed after the Stop was taken")
        await runtime.stop()
    }
}
#endif
