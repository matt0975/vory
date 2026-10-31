import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// #371: away with a turn running, the refreshes a long turn sets off are held back. Each of the
/// gateway's sessions.changed (one per flush, every 2 s of a long turn) fetched the list, wrote
/// the widget snapshot to the Keychain, reloaded the widgets and reloaded the chat list with its
/// Siri and Spotlight catalogs, on a main thread the system wants quiet in the background. Now
/// the snapshot runs once when the last turn ends and the list once after the return.
///
/// The snapshots are counted through this runtime's own callback; the list refresh by the
/// runtime's owed state (the notice goes to the shared centre, where tests running alongside
/// post it too, so its count can only be a lower bound).
///
/// Returning also refreshes once when suspension missed every sessions.changed notice.
@MainActor @Suite struct AwayRefreshTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    private func runtime() throws -> GatewayRuntime {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        return GatewayRuntime(connection: conn, store: ConnectionStore())
    }

    /// The gateway's real session-less event must bypass chats awaiting attach.
    private func sessionsChanged() -> GatewayEvent {
        GatewayEvent(type: "sessions.changed", sessionID: "", payload: .object([:]), seq: nil)
    }

    private func settle(until done: () -> Bool, seconds: Double = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func awayDuringATurnTheRefreshesWaitForTheTurnsEndAndTheReturn() async throws {
        let rt = try runtime()
        let snapshots = Counter()
        rt.onSnapshotPublished = { _ in snapshots.add() }
        let chat = ChatSession(runtime: rt, storedID: nil, title: nil)
        rt.registry.add(chat)
        rt.isAway = true
        chat.isRunning = true
        for _ in 0..<5 { rt.handle(batch: [sessionsChanged()]) }
        try await Task.sleep(for: .milliseconds(600))
        #expect(snapshots.value == 0, "a snapshot was published away with the turn running")
        #expect(rt.owedSnapshot && rt.owedSessionsRefresh)
        #expect(rt.owedListRefresh, "the lists were refreshed away with the turn running")

        // The turn ends while away: the widgets get its end state, once; the lists still wait.
        chat.isRunning = false
        await settle { snapshots.value >= 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(snapshots.value == 1)
        #expect(!rt.owedSnapshot && !rt.owedSessionsRefresh)
        #expect(rt.owedListRefresh)

        // Back: the lists are read once, after the return's animation.
        rt.isAway = false
        try await Task.sleep(for: .milliseconds(300))
        #expect(rt.owedListRefresh, "the lists were refreshed inside the return's animation")
        await settle { !rt.owedListRefresh }
        #expect(!rt.owedListRefresh, "the lists were not refreshed after the return")
        #expect(snapshots.value == 1)
    }

    @Test func inFrontEveryRefreshRunsAsBefore() async throws {
        let rt = try runtime()
        let snapshots = Counter(), lists = Counter()
        rt.onSnapshotPublished = { _ in snapshots.add() }
        let observer = NotificationCenter.default.addObserver(forName: .hermesSessionsChanged, object: nil, queue: nil) { _ in lists.add() }
        defer { NotificationCenter.default.removeObserver(observer) }

        let chat = ChatSession(runtime: rt, storedID: nil, title: nil)
        rt.registry.add(chat)
        chat.isRunning = true
        await settle { snapshots.value >= 1 }
        for _ in 0..<3 { rt.handle(batch: [sessionsChanged()]) }
        await settle { snapshots.value >= 4 }
        #expect(snapshots.value == 4)
        #expect(lists.value >= 3, "a sessions.changed in front did not refresh the lists")
        #expect(!rt.owedListRefresh && !rt.owedSnapshot)
    }

    /// No event is needed to owe a refresh after the foreground animation.
    @Test func theReturnWithNothingArrivingStillReadsTheListsOnce() async throws {
        let rt = try runtime()
        let snapshots = Counter()
        rt.onSnapshotPublished = { _ in snapshots.add() }
        let chat = ChatSession(runtime: rt, storedID: nil, title: nil)
        rt.registry.add(chat)
        #expect(!rt.owedListRefresh)
        rt.isAway = true
        #expect(!rt.owedListRefresh, "going away owed a read for a notice that never came")
        rt.isAway = false
        #expect(rt.owedListRefresh, "the way back owed no read with nothing delivered away")
        try await Task.sleep(for: .milliseconds(300))
        #expect(rt.owedListRefresh, "the lists were read inside the return's animation")
        await settle { !rt.owedListRefresh }
        #expect(!rt.owedListRefresh, "the way back did not read the lists")
        #expect(snapshots.value == 0, "the way back published a snapshot nothing owed")
    }

    /// A return cut short must leave its refresh owed until the next return.
    @Test func aReturnCutShortWithNothingArrivingOwesTheReadStill() async throws {
        let rt = try runtime()
        rt.isAway = true
        rt.isAway = false
        rt.isAway = true          // a glance at the app and away again, inside the 0.7 s
        try await Task.sleep(for: .milliseconds(1000))
        #expect(rt.owedListRefresh, "a return cut short paid the owed read while away")
        rt.isAway = false
        await settle { !rt.owedListRefresh }
        #expect(!rt.owedListRefresh)
    }

    /// Assigning the current foreground state must not schedule another refresh.
    @Test func sayingTheSameThingAgainOwesNothing() async throws {
        let rt = try runtime()
        rt.isAway = false
        rt.isAway = false         // in front already: the app says it again
        #expect(!rt.owedListRefresh, "a repeated \"in front\" owed a read")
        try await Task.sleep(for: .milliseconds(900))
        #expect(!rt.owedListRefresh, "a repeated \"in front\" read the lists")

        // One read per return; the same value again afterwards owes nothing.
        rt.isAway = true
        #expect(!rt.owedListRefresh, "going away owed a read for a notice that never came")
        rt.isAway = false
        await settle { !rt.owedListRefresh }
        #expect(!rt.owedListRefresh)
        rt.isAway = false
        rt.isAway = false
        try await Task.sleep(for: .milliseconds(900))
        #expect(!rt.owedListRefresh, "saying \"in front\" again owed a second read")
    }

    @Test func goingAwayAgainBeforeTheReturnSettlesOwesTheRefreshStill() async throws {
        let rt = try runtime()
        rt.isAway = true
        rt.handle(batch: [sessionsChanged()])
        #expect(rt.owedListRefresh)
        rt.isAway = false
        rt.isAway = true          // a glance at the app and away again, inside the 0.7 s
        try await Task.sleep(for: .milliseconds(1000))
        #expect(rt.owedListRefresh, "a return cut short paid the owed refresh while away")
        rt.isAway = false
        await settle { !rt.owedListRefresh }
        #expect(!rt.owedListRefresh)
    }
}
