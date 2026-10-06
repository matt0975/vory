import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// The Board's store against the mock: the probe finds the plugin and keeps its answer for the
/// next launch, choosing another board reads that board (and remembers it), and events that
/// land together on the plugin's socket are one read of the board, not one each.
@Suite(.serialized) struct KanbanStoreIntegrationTests {
    @MainActor @Test func theProbeSelectAndTheLiveSocketBehaveAsTheBoardExpects() async throws {
        guard let env = GatewayIntegrationTests.env, env.token == "mock-token" else { return }
        let store = ConnectionStore()
        let conn = GatewayConnection(name: "e2e board store", gateway: try GatewayURL.normalize(env.url), authMode: .sessionToken)
        try store.upsert(conn, secrets: GatewaySecrets(sessionToken: env.token))
        defer { store.delete(id: conn.id) }
        let rt = GatewayRuntime(connection: conn, store: store)
        await rt.start()
        defer { Task { await rt.stop() } }
        let kanban = rt.kanban

        // The probe: the plugin answers, the boards and the gateway's current one are known,
        // and the answer is kept per gateway so the page does not flicker at the next launch.
        await kanban.probe()
        #expect(kanban.availability == .present && kanban.isPresent)
        #expect(kanban.boards.map(\.slug).sorted() == ["default", "homelab"], "the mock's two boards")
        #expect(kanban.selectedBoard == "default", "nothing chosen here: the gateway's current board")
        #expect(UserDefaults.standard.string(forKey: "kanban.available." + conn.id.uuidString) == "present")
        await kanban.refresh()
        let first = try #require(kanban.board)
        let firstIDs = first.columns.flatMap(\.tasks).map(\.id)

        // Another board put in front: its own read, remembered for this gateway.
        kanban.select(board: "homelab")
        #expect(kanban.selectedBoard == "homelab" && kanban.board == nil)
        for _ in 0..<50 where kanban.board == nil { try await Task.sleep(for: .milliseconds(100)) }
        let second = try #require(kanban.board, "the other board was read")
        let secondIDs = second.columns.flatMap(\.tasks).map(\.id)
        #expect(!secondIDs.isEmpty && secondIDs != firstIDs, "a different board's cards")
        #expect(UserDefaults.standard.string(forKey: "kanban.board." + conn.id.uuidString) == "homelab")
        #expect(kanban.selectedBoardMeta?.name == "Homelab")

        // Select also opens the plugin's socket for that board.
        for _ in 0..<50 where !kanban.liveConnected { try await Task.sleep(for: .milliseconds(100)) }
        #expect(kanban.liveConnected, "the events socket is up")

        // Three changes made straight on the gateway (not through the store, which reads after
        // each of its own): their events reach the socket in one frame (the mock looks once a
        // second) and the store reads the board once for all of them, twice at most if the
        // writes straddled its tick, never once each.
        let api = try #require(kanban.api)
        let task = try #require(second.columns.flatMap(\.tasks).first)
        let before = kanban.reads
        for i in 1...3 { try await api.comment(task.id, "coalesced \(i)") }
        for _ in 0..<100 where kanban.reads == before { try await Task.sleep(for: .milliseconds(100)) }
        #expect(kanban.reads > before, "the events reached the store and it read the board")
        // Then nothing more for the same events.
        try await Task.sleep(for: .seconds(1.5))
        let reads = kanban.reads - before
        #expect(reads <= 2, "events landing together are one read, not one each (\(reads))")

        kanban.stopEvents()
        #expect(!kanban.liveConnected)
    }
}
