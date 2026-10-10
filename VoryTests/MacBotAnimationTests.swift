#if os(macOS)
import Foundation
import Testing
@testable import Vory

/// #248: on the Mac the bots move only while something is working, and the switch for it stays
/// on this Mac.
@MainActor
@Suite(.serialized) struct MacBotAnimationTests {
    @Test func theTurnBoardTellsTheBotsWhenSomethingIsWorking() {
        let board = TurnBoard.shared
        let ambient = BotAmbient.shared
        let id = "test-\(UUID().uuidString)"
        defer { board.remove(id) }
        board.remove(id)
        #expect(ambient.anyWorking == !board.turns.isEmpty)
        board.upsert(TurnBoard.Turn(id: id, title: "T", bot: "B", profile: "default", detail: "Thinking…", attention: false, startedAt: Date()))
        #expect(ambient.anyWorking)
        #expect(ambient.decorativeActive)
        // Waiting on an approval still counts: the bot is mid-turn.
        board.upsert(TurnBoard.Turn(id: id, title: "T", bot: "B", profile: "default", detail: "Needs you", attention: true, startedAt: Date()))
        #expect(ambient.anyWorking)
        board.remove(id)
        #expect(ambient.anyWorking == !board.turns.isEmpty)
    }

    @Test func animateBotsIsNotSyncedThroughICloud() {
        #expect(!CloudMerge.syncedSettings.contains(BotAmbient.animateKey))
    }
}
#endif
