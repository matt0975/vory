import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Re-attaching a chat after a reconnect: a socket that went in the meantime is "not yet", not
/// a failure to show (the next reconnect re-attaches the chat itself); a slow gateway is asked
/// once more before the banner; anything else is said.
@MainActor @Suite struct ReattachTests {
    private func chat() throws -> ChatSession {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        return ChatSession(runtime: rt, storedID: "s1", title: nil)
    }

    @Test func aSocketThatWentIsNotABannerJustStale() async throws {
        let c = try chat()
        var calls = 0
        c.gatewayStandIn = { _, _ in calls += 1; throw SocketError.notConnected }
        await c.reattachAfterReconnect()
        #expect(calls == 1)
        #expect(c.stale)
        #expect(c.banner == nil)
    }

    @Test func aSlowGatewayIsAskedOnceMoreBeforeTheBanner() async throws {
        let c = try chat()
        var calls = 0
        c.gatewayStandIn = { _, _ in calls += 1; throw SocketError.timeout("session.resume") }
        await c.reattachAfterReconnect()
        #expect(calls == 2)
        #expect(c.stale)
        #expect(c.banner?.hasPrefix("Reconnected, but the chat could not be re-attached") == true)
    }

    @Test func anyOtherFailureIsSaid() async throws {
        let c = try chat()
        c.gatewayStandIn = { _, _ in throw SocketError.closed(code: 1011, reason: "server error") }
        await c.reattachAfterReconnect()
        #expect(c.stale)
        #expect(c.banner?.hasPrefix("Reconnected, but the chat could not be re-attached") == true)
    }
}
