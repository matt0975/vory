import Foundation
import Observation

/// How the Watch reaches a chat: its own socket, the iPhone (HTTP relayed, chat ops answered by the phone), or neither.
public enum WatchFeedRoute: String, Sendable, Equatable {
    case live, throughPhone, offline
}

/// What moved the Watch's chat feed to read the chat again (#387).
public enum WatchFeedTrigger: Sendable, Equatable {
    /// The chat opened on the Watch.
    case opened
    /// The app came forward: a wrist raise does not run the view's task again.
    case sceneActive
    /// The iPhone came within reach.
    case phoneReachable
    /// The iPhone said the chat changed: a turn started or ended, or its cards changed.
    case chatChanged
    /// The working poll on the phone path.
    case poll
    /// The live chat on the socket changed (rows, cards, the turn, the socket itself).
    case liveChanged
    /// A message went out from the Watch.
    case sent
    /// "Show earlier".
    case loadEarlier
}

/// One arrival the Watch announces with a haptic, while the chat is open.
public enum WatchFeedEventKind: Sendable, Equatable {
    case replyArrived(itemID: String)
    case cardArrived(cardID: String)
    case turnFailed(itemID: String?)
}

/// What went wrong, as a short line under the thread instead of a reply.
public struct WatchFeedProblem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case notProcessed, interrupted, phoneAway, sendFailed }
    public var kind: Kind
    public var text: String
    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }

    /// A failure's words to a kind: the iPhone out of reach, the gateway's "not processed", or a send that failed.
    public static func from(_ text: String, phoneAway: Bool = false) -> WatchFeedProblem {
        if phoneAway { return WatchFeedProblem(kind: .phoneAway, text: text) }
        if text.localizedCaseInsensitiveContains("not processed") { return WatchFeedProblem(kind: .notProcessed, text: text) }
        return WatchFeedProblem(kind: .sendFailed, text: text)
    }
}

/// The Watch chat's rules (#387), apart from WatchConnectivity so they build for every platform and are tested in
/// VoryTests. The feed itself (VoryWatch/WatchChatFeed.swift) follows them.
public enum WatchFeedRules {
    /// How long the iPhone keeps telling the Watch about a chat after the Watch last asked about it. Each request about
    /// the chat renews it; leaving the chat ends it.
    public static let followSeconds: TimeInterval = 600
    /// How often the phone path reads a chat while its turn runs. A chat at rest is not read at all: it waits for the
    /// iPhone's word that it changed (each read through the phone wakes the iPhone).
    public static let workingPollSeconds: TimeInterval = 2

    /// The rows the Watch shows: settled ones. A reply still being written appears when it is done, and a step that only
    /// thought (a Reasoning card on the phone) is not shown on the wrist.
    public static func settled(_ items: [TranscriptItem]) -> [TranscriptItem] {
        items.filter { item in
            if item.isThinkingOnly { return false }
            if case .assistant(_, _, true) = item.kind { return false }
            return true
        }
    }

    /// This turn's steps so far: the tool rows after the last message of yours, in order.
    public static func turnTools(_ items: [TranscriptItem]) -> [ToolActivity] {
        let start = items.lastIndex { if case .user = $0.kind { return true }; return false }.map { $0 + 1 } ?? items.startIndex
        return items[start...].compactMap { if case .tool(let a) = $0.kind { return a }; return nil }
    }

    /// Seconds to the next read, or nil for none: only the phone path polls, and only while a turn runs. The live path
    /// follows the socket's changes; a resting chat waits for a trigger.
    public static func pollInterval(route: WatchFeedRoute, working: Bool) -> TimeInterval? {
        route == .throughPhone && working ? workingPollSeconds : nil
    }

    /// Seconds until the live path is tried again, or nil for no wake. Only on the phone path with the socket up: nothing
    /// else wakes a chat there at rest (no poll, and the socket, already open, no longer changes), so it stayed on the
    /// phone path, every read waking the iPhone, until something happened to wake it. After an attach failed, at
    /// `retryAt`; with no retry pending, at once: the socket opened after the read chose the phone path, and its change
    /// went by unseen (it opened while the read was out, and the chat stayed on the phone path with the socket up). In
    /// any other state nil: the live path needs no retry, and a socket coming back wakes the chat itself.
    public static func liveRetryWake(route: WatchFeedRoute, socketUsable: Bool, retryAt: Date, now: Date) -> TimeInterval? {
        guard route == .throughPhone, socketUsable else { return nil }
        return max(0, retryAt.timeIntervalSince(now))
    }

    /// How long a chat whose live attach failed waits before the socket is tried again, instead of flipping between the
    /// two paths.
    public static let liveRetrySeconds: TimeInterval = 30

    /// When the live path is tried again after an attach failed at `now`.
    public static func retryAfterFailedAttach(now: Date) -> Date { now.addingTimeInterval(liveRetrySeconds) }

    /// Whether a trigger reads the chat again. The phone path reads on every one. The live path has the socket, so only
    /// opening, coming forward (a socket may have dropped meanwhile) and its own changes count. Offline, anything that
    /// might bring a route back tries again.
    public static func refreshes(_ trigger: WatchFeedTrigger, route: WatchFeedRoute) -> Bool {
        switch route {
        case .throughPhone: return true
        case .live: return [.opened, .sceneActive, .liveChanged, .loadEarlier, .sent].contains(trigger)
        case .offline: return [.opened, .sceneActive, .phoneReachable, .chatChanged, .liveChanged].contains(trigger)
        }
    }

    /// The iPhone's turn-surface calls that it passes on to a Watch following the chat: a turn starting or ending and
    /// its cards changing. Not every status update (each would wake the Watch), nor voice mode's lines.
    public enum TurnCall: Sendable, Equatable { case start, update, end, voiceMode, showCards }

    public static func tellsWatch(_ call: TurnCall) -> Bool {
        call == .start || call == .end || call == .showCards
    }

    /// A card as the iPhone sends it to the Watch (the "cards" op): its words and request for older Watches and for a
    /// notification's Approve (`PendingCard.isNamed`), the whole card (`params`) so the Watch shows the same card on
    /// both paths, and an approval's offered choices and what "Always" would allow.
    public static func cardMessage(_ c: PendingCard) -> [String: Any] {
        var card: [String: Any] = ["id": c.id, "method": c.method,
                                   "text": c.approval?.description ?? c.approval?.command ?? c.clarify?.question ?? c.clarify?.questions?.first?.question ?? c.valuePrompt?.prompt ?? ""]
        if let rid = c.approval?.requestId { card["request"] = rid }
        if let params = try? JSONEncoder().encode(c.params) { card["params"] = params }
        if let a = c.approval { card["choices"] = a.offeredChoices; card["scope"] = a.alwaysScope }
        return card
    }

    /// The iPhone's cards on the Watch: the whole card when the phone sent it, else rebuilt from what an older phone said.
    public static func cards(from list: [[String: Any]]) -> [PendingCard] {
        list.compactMap { c in
            guard let id = c["id"] as? String, let method = c["method"] as? String else { return nil }
            if let data = c["params"] as? Data, let params = try? JSONDecoder().decode(JSONValue.self, from: data) {
                return PendingCard(id: id, method: method, params: params)
            }
            let text = JSONValue.string(c["text"] as? String ?? "")
            var params: [String: JSONValue] = method == "clarify" ? ["session_id": "", "question": text]
                : ["request_id": .string(c["request"] as? String ?? id), "session_id": "", "description": text]
            if let choices = c["choices"] as? [String] { params["choices"] = .array(choices.map { .string($0) }) }
            return PendingCard(id: id, method: method, params: .object(params))
        }
    }
}

/// Which arrivals the Watch announces. Nothing on the first read of a chat, nothing for rows or cards already seen (a
/// wrist raise reads the chat again), and nothing after a switch between the live and phone paths, whose rows carry
/// other ids for the same messages: those reads only learn what is there. The first read is the first of a completed
/// load: a live chat shows its cached transcript while it resumes, and the resume's history then brought rows the
/// cache didn't have, announced as arrivals (a buzz on opening, 2 of 6 opens in the gates). Everything present when the
/// load completes counts as seen, whichever read gets there first.
public struct WatchFeedEventGate: Sendable {
    private var seenItems: Set<String> = []
    private var seenCards: Set<String> = []
    private var seeded = false

    public init() {}

    /// The next read only learns what is there (a switch of path).
    public mutating func reseed() { seeded = false }

    /// The arrivals in `items` (settled rows) and `cardIDs` since the last read. `loaded`: the read is of a completed load
    /// (a live chat's resume done; a read through the iPhone always is). Until one has been, reads only learn.
    public mutating func arrivals(items: [TranscriptItem], cardIDs: [String], loaded: Bool = true) -> [WatchFeedEventKind] {
        defer {
            seenItems.formUnion(items.map(\.id))
            seenCards.formUnion(cardIDs)
            if loaded { seeded = true }
        }
        guard seeded else { return [] }
        var out: [WatchFeedEventKind] = []
        for item in items where !seenItems.contains(item.id) {
            switch item.kind {
            case .assistant(let text, _, false):
                out.append(InterruptedTurn.parse(text) == nil ? .replyArrived(itemID: item.id) : .turnFailed(itemID: item.id))
            case .error:
                out.append(.turnFailed(itemID: item.id))
            default:
                break
            }
        }
        for id in cardIDs where !seenCards.contains(id) { out.append(.cardArrived(cardID: id)) }
        return out
    }

    /// The one arrival to announce when a read brought several: a card first (it needs you), then a failure, then the
    /// newest reply.
    public static func strongest(_ arrivals: [WatchFeedEventKind]) -> WatchFeedEventKind? {
        if let c = arrivals.first(where: { if case .cardArrived = $0 { return true }; return false }) { return c }
        if let f = arrivals.last(where: { if case .turnFailed = $0 { return true }; return false }) { return f }
        return arrivals.last
    }
}

/// How long the iPhone keeps telling the Watch about one chat (`WatchFeedRules.followSeconds`), renewed by each request.
public struct WatchFollow: Sendable, Equatable {
    public private(set) var until: Date?
    public init() {}
    public mutating func renew(now: Date = Date()) { until = now.addingTimeInterval(WatchFeedRules.followSeconds) }
    public mutating func end() { until = nil }
    public func isActive(now: Date = Date()) -> Bool { until.map { now < $0 } ?? false }
}

/// The phone path's read with the Watch's socket watched across it (#387): the socket changing while the read is out
/// wakes the chat as much as a change after it. Watched only after the read, a socket that opened meanwhile went by
/// unseen, and the chat stayed on the phone path with the socket up.
public enum WatchFeedSocketWatch {
    /// Watches `isUp`, then runs `read`. `changed` is called once, on the first change from the moment of the call.
    @MainActor public static func across(_ isUp: () -> Bool, read: () async -> Void, changed: @escaping @Sendable () -> Void) async {
        withObservationTracking { _ = isUp() } onChange: { changed() }
        await read()
    }
}
