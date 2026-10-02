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
        homes.append("/Users/andrea")
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

        let created = try await socket.call("session.create", params: ["cols": 80])
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

actor EventCollector {
    private var events: [GatewayEvent] = []
    func add(_ e: GatewayEvent) { events.append(e) }
    func first(where p: (GatewayEvent) -> Bool) -> GatewayEvent? { events.first(where: p) }
    func count(_ p: (GatewayEvent) -> Bool) -> Int { events.filter(p).count }
}
