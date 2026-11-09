import Foundation
import Testing
@testable import VoryCore

/// #641 against the mock (HERMES_E2E_URL with the mock's token; skipped without it), read by the chat's state, not the
/// screen: a chat on screen, and the gateway taking the upgrade but not ready, for 30 s and then for 90 s. On the iPhone
/// and the Mac both: the Mac has no UI test target, so this is its proof of the issue's arms.
@Suite(.serialized) struct ReattachAgainstMockTests {
    @MainActor private func fault(_ base: String, _ query: String) async throws {
        guard let url = URL(string: base + "/mock/fault?" + query) else { return }
        let (data, _) = try await URLSession.shared.data(from: url)
        print("MOCK-FAULT \(String(decoding: data, as: UTF8.self))")
    }

    /// Opens a stored chat on screen, holds the gateway's ready for `hold` seconds, and reads the chat's re-attach every
    /// quarter second for `watch` seconds: each change, then the last read. Nil without the mock.
    @MainActor private func heldArm(hold: Int, watch: Double) async throws -> [(t: Double, s: ReattachShow)]? {
        guard let env = GatewayIntegrationTests.env, env.token == "mock-token" else { return nil }
        // The Keychain in memory, as the demo copy keeps it: the Mac's test host has no Keychain entitlement (a save
        // there fails with -34018), and nothing here needs to outlive the test.
        let wasMemoryOnly = Keychain.memoryOnly
        Keychain.memoryOnly = true
        defer { Keychain.memoryOnly = wasMemoryOnly }
        let store = ConnectionStore()
        let conn = GatewayConnection(name: "e2e reattach \(hold)", gateway: try GatewayURL.normalize(env.url), authMode: .sessionToken)
        try store.upsert(conn, secrets: GatewaySecrets(sessionToken: env.token))
        defer { store.delete(id: conn.id) }
        let rt = GatewayRuntime(connection: conn, store: store)
        await rt.start()
        let list: SessionListResponse = try await rt.api.get("/api/sessions", query: [URLQueryItem(name: "limit", value: "5")], profile: rt.selectedProfile)
        let stored = try #require(list.sessions.first?.id)
        let chat = try await rt.openChat(storedID: stored, title: nil, waitForResume: true)
        chat.cameOnScreen()
        try await fault(env.url, "mode=ready-held&count=\(hold)")
        let start = Date()
        var reads: [(t: Double, s: ReattachShow)] = []
        var last: ReattachShow?
        while Date().timeIntervalSince(start) < watch {
            let s = chat.reattachShow
            if s != last {
                let t = Date().timeIntervalSince(start)
                reads.append((t, s))
                last = s
                print(String(format: "e2e reattach %d: %.1f s %@", hold, t, "\(s)"))
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        reads.append((Date().timeIntervalSince(start), chat.reattachShow))
        chat.wentOffScreen()
        try? await fault(env.url, "mode=none")
        await rt.stop()
        return reads
    }

    /// Not ready for 30 s: the quiet line before 30 s, never the banner, attached again by 40 s.
    @Test func aGatewayNotReadyFor30sShowsOnlyTheLineAndAttachesBy40s() async throws {
        guard let reads = try await heldArm(hold: 30, watch: 40) else { return }
        #expect(reads.contains { $0.s == .reconnecting && $0.t < 30 }, "no line before 30 s: \(reads)")
        #expect(!reads.contains { $0.s == .failed }, "a banner: \(reads)")
        #expect(reads.last?.s == ReattachShow.none, "not attached again by 40 s: \(reads)")
    }

    /// Not ready for 90 s: the banner with Try again from a minute (not before), attached again by 100 s.
    @Test func aGatewayNotReadyFor90sShowsTryAgainFromAMinuteAndAttachesBy100s() async throws {
        guard let reads = try await heldArm(hold: 90, watch: 100) else { return }
        let banner = reads.first { $0.s == .failed }
        #expect(banner != nil, "no banner: \(reads)")
        if let banner { #expect(banner.t >= 59, "the banner came before a minute: \(reads)") }
        #expect(reads.last?.s == ReattachShow.none, "not attached again by 100 s: \(reads)")
    }
}
