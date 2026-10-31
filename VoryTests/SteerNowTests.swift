import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// The composer's Steer now (#563): words the gateway doesn't take into a turn ("rejected": the turn had ended) go as the
/// next message, with no steer row, and words whose steer fails come back for the composer to put back. Neither is lost.
@MainActor @Suite struct SteerNowTests {
    private func chat() throws -> ChatSession {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        return ChatSession(runtime: rt, storedID: "s1", title: nil)
    }

    /// The send's own task has its moment.
    private func settle() async { for _ in 0..<50 { await Task.yield() } }

    private func submitted(_ calls: [(String, [String: JSONValue])]) -> [String] {
        calls.filter { $0.0 == "prompt.submit" }.compactMap { $0.1["text"]?.stringValue }
    }

    /// The composer's Steer now, rejected because the turn had ended: sent as the next message, not lost behind a steer row.
    @Test func theComposersSteerRejectedIsSentAsTheNextMessage() async throws {
        let c = try chat()
        var calls: [(String, [String: JSONValue])] = []
        c.gatewayStandIn = { m, p in
            calls.append((m, p))
            return m == "session.steer" ? .object(["status": .string("rejected")]) : .object(["status": .string("started")])
        }
        let back = await c.steer("after all")
        await settle()
        #expect(back == nil)
        #expect(calls.map(\.0) == ["session.steer", "prompt.submit"])
        #expect(submitted(calls) == ["after all"])
        #expect(!c.items.contains { if case .steer = $0.kind { true } else { false } })
    }

    /// The composer's Steer now that fails: its words come back for the composer to put back, with the banner.
    @Test func theComposersSteerThatFailsGivesItsWordsBack() async throws {
        let c = try chat()
        c.isRunning = true
        c.gatewayStandIn = { _, _ in throw SocketError.timeout("session.steer") }
        let back = await c.steer("keep these words")
        #expect(back == "keep these words")
        #expect(c.banner != nil)
        #expect(!c.items.contains { if case .steer = $0.kind { true } else { false } })
    }

    /// Taken into the running turn ("queued"): a steer row, nothing sent, nothing given back.
    @Test func theComposersSteerTakenShowsAsASteer() async throws {
        let c = try chat()
        c.isRunning = true
        var calls: [(String, [String: JSONValue])] = []
        c.gatewayStandIn = { m, p in calls.append((m, p)); return .object(["status": .string("queued")]) }
        let back = await c.steer("this way")
        await settle()
        #expect(back == nil)
        #expect(calls.map(\.0) == ["session.steer"])
        guard case .steer(let text, let status)? = c.items.last?.kind else { Issue.record("no steer row"); return }
        #expect(text == "this way" && status == "queued")
    }
}
