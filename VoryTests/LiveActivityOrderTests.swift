#if os(iOS)
import Foundation
import Testing
@testable import Vory

/// The Live Activity sends one update at a time and keeps only the newest state behind it. The
/// app's own alert (away from the app, no companion) went out by itself ahead of that line, so
/// the state waiting there landed after it: a turn asking a question showed "Running Clarify"
/// on the Lock Screen for the whole wait instead of that it needs the person.
@Suite struct LiveActivityOrderTests {
    private func state(_ detail: String, attention: Bool = false) -> HermesTurnAttributes.ContentState {
        HermesTurnAttributes.ContentState(phase: attention ? "waiting" : "tool", detail: detail, outputTokens: 0, contextPercent: nil,
                                          needsAttention: attention, startedAt: Date(timeIntervalSince1970: 1_000_000))
    }

    private let ask = ActivityAlert(title: "Bot", body: "Your input is needed. Tap to answer.")

    @Test func anAlertWaitsItsTurnAndReplacesTheStateWaiting() {
        var order = ActivityUpdateOrder()
        // The status line's update is on its way; the tool's own line waits behind it.
        #expect(order.offer(state("Running Clarify…")) == .init(state: state("Running Clarify…"), alert: nil))
        #expect(order.offer(state("Running Clarify")) == nil)
        // The question arrives: its alert does not overtake, it takes the waiting place.
        #expect(order.offer(state("Your input is needed", attention: true), alert: ask) == nil)
        #expect(order.sent() == .init(state: state("Your input is needed", attention: true), alert: ask))
        #expect(order.sent() == nil)
        #expect(!order.sending)
    }

    @Test func aNewerStateThatStillNeedsThePersonKeepsTheAlert() {
        var order = ActivityUpdateOrder()
        _ = order.offer(state("Running Clarify…"))
        _ = order.offer(state("Your input is needed", attention: true), alert: ask)
        // The token count moves on while the question waits: the buzz still goes, with it.
        #expect(order.offer(state("Your input is needed (1.2k)", attention: true)) == nil)
        #expect(order.sent() == .init(state: state("Your input is needed (1.2k)", attention: true), alert: ask))
    }

    @Test func anAnsweredQuestionDropsAnAlertNotYetOut() {
        var order = ActivityUpdateOrder()
        _ = order.offer(state("Running Clarify…"))
        _ = order.offer(state("Your input is needed", attention: true), alert: ask)
        // Answered on another device before the alert went out: no buzz for it.
        #expect(order.offer(state("Thinking…")) == nil)
        #expect(order.sent() == .init(state: state("Thinking…"), alert: nil))
    }

    @Test func anAlertWithNothingOnItsWayGoesAtOnceAndNothingFollowsTheEnd() {
        var order = ActivityUpdateOrder()
        #expect(order.offer(state("Approval needed", attention: true), alert: ask) == .init(state: state("Approval needed", attention: true), alert: ask))
        #expect(order.offer(state("Thinking…")) == nil)
        order.end()
        #expect(order.sent() == nil, "a state still waiting does not follow the end")
        #expect(order.offer(state("Thinking…")) == nil)
    }
}
#endif
