import Foundation

/// Events from the socket on their way to the main actor, gathered while it is busy.
///
/// Each event used to be its own trip to the main actor. A long turn that ran on while the app
/// was away comes back as thousands of frames at once (tokens, tool calls, status lines), and
/// the main thread spent its time hopping from one to the next with the screen redrawn between
/// them: testers came back to a frozen app. Now the socket fills one batch for as long as the
/// main actor has not taken it, and the main actor takes everything gathered in one go.
///
/// A reply or a server request closes the batch it follows: whatever arrives after it goes
/// into a new batch, so the main actor sees events and replies in the order they came (a
/// snapshot's reply is applied after the events sent before it and before those sent after).
public final class GatewayEventBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [GatewayEvent] = []
    private var taken = false

    public init() {}

    /// Adds an event unless the batch has been taken already (false: start a new one).
    func add(_ event: GatewayEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !taken else { return false }
        events.append(event)
        return true
    }

    /// Everything gathered, in order; what comes later goes into another batch.
    public func take() -> [GatewayEvent] {
        lock.lock(); defer { lock.unlock() }
        taken = true
        let out = events
        events = []
        return out
    }
}

public extension GatewayEvent {
    /// Events whose payload is a piece of text that adds onto the one before it.
    static let textPieces: Set<String> = ["message.delta", "reasoning.delta"]
    /// Events that only say "read the list again": the same however many come.
    static let listRefreshes: Set<String> = ["sessions.changed", "projects.changed", "cron.changed"]

    /// The same events with only the last of each list refresh kept, where it stood: a long
    /// turn's flushes each said the chats had changed, and every one of them reloaded the
    /// chat list, the widget and the projects.
    static func droppingRepeatedRefreshes(_ events: [GatewayEvent]) -> [GatewayEvent] {
        var last: [String: Int] = [:]
        for (i, e) in events.enumerated() where listRefreshes.contains(e.type) { last[e.type + "\u{1F}" + e.sessionID] = i }
        guard !last.isEmpty else { return events }
        return events.enumerated().compactMap { i, e in
            !listRefreshes.contains(e.type) || last[e.type + "\u{1F}" + e.sessionID] == i ? e : nil
        }
    }

    /// The same events with each run of text pieces for one session made one piece: the text
    /// is the run's text in order, so handling the one is handling them all, once.
    static func coalescingText(_ events: [GatewayEvent]) -> [GatewayEvent] {
        var out: [GatewayEvent] = []
        out.reserveCapacity(events.count)
        var run: [String] = []
        // `run` holds the texts of the run whose first event is the last one in `out`.
        func closeRun() {
            defer { run = [] }
            guard run.count > 1, let i = out.indices.last, case .object(var payload) = out[i].payload else { return }
            payload["text"] = .string(run.joined())
            out[i].payload = .object(payload)
        }
        for e in events {
            if let prev = out.last, textPieces.contains(e.type), prev.type == e.type, prev.sessionID == e.sessionID,
               !run.isEmpty, let text = e.payload["text"]?.stringValue {
                run.append(text)
                out[out.count - 1].seq = e.seq ?? out[out.count - 1].seq
                continue
            }
            closeRun()
            out.append(e)
            if textPieces.contains(e.type), case .object = e.payload, let text = e.payload["text"]?.stringValue { run = [text] }
        }
        closeRun()
        return out
    }
}
