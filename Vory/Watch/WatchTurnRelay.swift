#if os(iOS)
import Foundation
import VoryCore

/// The iPhone's turn surface, passed on to a Watch that has the chat open (#387). Every call goes to the inner reporter
/// (the Live Activity) unchanged and in order; a turn starting or ending and its cards changing also tell the Watch
/// (`WatchFeedRules.tellsWatch`), so a Watch chat at rest asks the iPhone nothing. A pure decorator: what the Live
/// Activity shows does not depend on the Watch. The Watch hears each of those once: a turn's start until its end, its
/// end, and its cards only when they changed. The Live Activity is started again as it is taken over or refreshed,
/// and passed on each time, one turn's start woke a following Watch three times (range B's gates).
@MainActor
final class WatchTurnRelay: TurnActivityReporting {
    let inner: any TurnActivityReporting
    /// Tells the Watch: WatchSync's sender, which says nothing unless a Watch follows that chat. Tests pass their own.
    private let tell: @MainActor (ChatSession, WatchFeedRules.TurnCall) -> Void

    init(inner: any TurnActivityReporting,
         tell: @escaping @MainActor (ChatSession, WatchFeedRules.TurnCall) -> Void = { WatchSync.shared.chatChanged($0, call: $1) }) {
        self.inner = inner
        self.tell = tell
    }

    /// What the Watch was last told of each chat, by stored id.
    private enum Told { case running, ended }
    private var told: [String: Told] = [:]
    private var toldCards: [String: [String]] = [:]

    func start(for chat: ChatSession) { inner.start(for: chat); pass(chat, .start) }
    func update(for chat: ChatSession, attention: Bool, detail: String?) { inner.update(for: chat, attention: attention, detail: detail); pass(chat, .update) }
    func end(for chat: ChatSession, phase: String) { inner.end(for: chat, phase: phase); pass(chat, .end) }
    func voiceMode(for chat: ChatSession, line: String?) { inner.voiceMode(for: chat, line: line); pass(chat, .voiceMode) }
    func showCards(for chat: ChatSession) { inner.showCards(for: chat); pass(chat, .showCards) }

    private func pass(_ chat: ChatSession, _ call: WatchFeedRules.TurnCall) {
        guard WatchFeedRules.tellsWatch(call) else { return }
        let id = chat.storedID
        switch call {
        case .start:
            guard told[id] != .running else { return }
            told[id] = .running
        case .end:
            guard told[id] != .ended else { return }
            told[id] = .ended
            toldCards[id] = nil
        case .showCards:
            let cards = chat.cards.map(\.id)
            guard toldCards[id] != cards else { return }
            toldCards[id] = cards
        default:
            break
        }
        tell(chat, call)
    }
}
#endif
