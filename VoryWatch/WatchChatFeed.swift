import Foundation
import Observation
import VoryCore
import WatchKit

/// An arrival announced once while the chat is open: the view plays its haptic and scrolls to it (#387).
struct WatchFeedEvent: Equatable {
    let id = UUID()
    let kind: WatchFeedEventKind
}

/// A send or an answer that did not get through, in words for the status line.
struct WatchFeedSendError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

/// One chat's data on the Watch (#387): what the chat screen shows and does, on the Watch's own socket or through the
/// iPhone, moving between the two as the socket comes and goes. A chat at rest is not read at all:
/// - the live path follows the chat's own changes on the socket (no timer);
/// - the phone path reads the chat when the iPhone says it changed (`chatChanged`: a turn started or ended, or its
///   cards changed), when the app comes forward (a wrist raise does not run the view's task again), when the iPhone
///   comes within reach, after a send, and every 2 s only while a turn runs (`WatchFeedRules`). Each read through the
///   phone wakes the iPhone; the old chat view did it every 6 s at rest.
///
/// The iPhone keeps telling the Watch about the chat for 10 minutes after each request about it; while the chat stays
/// open at rest on the phone path, the feed renews that every 9 minutes, and leaving the chat ends it.
@MainActor
@Observable
final class WatchChatFeed {
    let storedID: String
    private(set) var title: String
    /// The chat's bot.
    private(set) var profile: String?
    /// The transcript, settled rows only (`WatchFeedRules.settled`): a reply still being written is not here; replies
    /// appear when done. Each row keeps its time from the history and the gateway's message id (`rowID`).
    private(set) var items: [TranscriptItem] = []
    private(set) var hasEarlier = false
    /// The first read, with nothing to show yet.
    private(set) var isLoading = true
    /// A turn is running.
    private(set) var isWorking = false
    /// This turn's steps so far, named, in order, with their status.
    private(set) var turnTools: [ToolActivity] = []
    /// The gateway's own status line while working.
    private(set) var statusLine: String?
    /// Approvals, questions and value prompts, the same cards on both paths; the first is shown.
    private(set) var cards: [PendingCard] = []
    private(set) var problem: WatchFeedProblem?
    private(set) var route: WatchFeedRoute = .offline
    /// One per arrival while the chat is open; never for what a first read, a wrist-raise read of rows already seen, or
    /// a switch between paths finds (`WatchFeedEventGate`). The only source of the chat's haptics.
    private(set) var event: WatchFeedEvent?

    @ObservationIgnored private let model: WatchModel
    @ObservationIgnored private var chat: ChatSession?
    /// Settled rows on screen: the last few, more with "Show earlier".
    @ObservationIgnored private var limit = 12
    @ObservationIgnored private var gate = WatchFeedEventGate()
    /// After the live chat failed to attach: the socket is not tried again before this.
    @ObservationIgnored private var liveRetryAt = Date.distantPast
    @ObservationIgnored private var wakes: AsyncStream<WatchFeedTrigger>.Continuation?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The wake that tries the live path again with the socket up (`WatchFeedRules.liveRetryWake`).
    @ObservationIgnored private var liveRetryTask: Task<Void, Never>?
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private var liveDebounce: Task<Void, Never>?
    @ObservationIgnored private var lastLiveSync = Date.distantPast
    /// Messages sent from the Watch on the phone path, shown until the history has them.
    @ObservationIgnored private var sentLocally: [TranscriptItem] = []

    init(storedID: String, model: WatchModel) {
        self.storedID = storedID
        self.model = model
        let stored = model.sessions.first { $0.id == storedID }
        title = stored?.displayTitle ?? "Chat"
        profile = stored?.profile
    }

    // MARK: Running

    /// Runs while the chat is on screen (the view's `.task`): reads the chat on each trigger, nothing in between.
    func run() async {
        let (stream, continuation) = AsyncStream<WatchFeedTrigger>.makeStream(bufferingPolicy: .bufferingNewest(8))
        wakes = continuation
        model.register(self)
        let forward = NotificationCenter.default.addObserver(forName: WKApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake(.sceneActive) }
        }
        await handle(.opened)
        for await trigger in stream {
            if Task.isCancelled { break }
            await handle(trigger)
        }
        NotificationCenter.default.removeObserver(forward)
        for t in [pollTask, followTask, liveDebounce, liveRetryTask] { t?.cancel() }
        pollTask = nil; followTask = nil; liveDebounce = nil; liveRetryTask = nil
        wakes = nil
        model.unregister(self)
        leave()
    }

    /// Asks for a read. Triggers that cannot change anything on the current path are dropped
    /// (`WatchFeedRules.refreshes`); the live chat's changes while a reply streams are read at most every 0.3 s.
    func wake(_ trigger: WatchFeedTrigger) {
        guard WatchFeedRules.refreshes(trigger, route: route) else { return }
        if trigger == .liveChanged, isWorking, Date().timeIntervalSince(lastLiveSync) < 0.3 {
            guard liveDebounce == nil else { return }
            liveDebounce = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self else { return }
                self.liveDebounce = nil
                self.wakes?.yield(.liveChanged)
            }
            return
        }
        wakes?.yield(trigger)
    }

    private func handle(_ trigger: WatchFeedTrigger) async {
        guard let rt = model.runtime else {
            route = .offline; isLoading = false
            return
        }
        // A runtime replaced (a new route or address): the old live chat went with it.
        if let c = chat, c.runtime !== rt { chat = nil }
        let before = route
        await chooseRoute(rt)
        // Rows on the two paths carry different ids for the same messages: a switch only learns what is there.
        if route != before || trigger == .loadEarlier { gate.reseed() }
        switch route {
        case .live:
            if let c = chat { syncLive(c) }
        case .throughPhone, .offline:
            // Off the socket, its coming back is a trigger too, watched from before the read (`WatchFeedSocketWatch`).
            let model = model
            await WatchFeedSocketWatch.across({ model.socketUsable }, read: { await refreshThroughPhone(rt) }) { [weak self] in
                Task { @MainActor in self?.wake(.liveChanged) }
            }
        }
        schedulePoll()
        scheduleFollow()
        scheduleLiveRetry()
    }

    /// The socket when it is open and the chat attached on it, else the iPhone. A chat whose attach failed waits 30 s
    /// before the socket is tried again, instead of flipping between the two.
    private func chooseRoute(_ rt: GatewayRuntime) async {
        if model.socketUsable, chat == nil || route != .live, Date() >= liveRetryAt {
            // The first open shows the cached transcript at once; a retry after a failed attach stays on the phone path
            // until the chat is attached.
            let retry = chat != nil
            if let live = try? await rt.openChat(storedID: storedID, title: nil, profile: profile, waitForResume: retry), !retry || live.resumeError == nil {
                chat = live
                route = .live
            } else {
                liveRetryAt = WatchFeedRules.retryAfterFailedAttach(now: Date())
            }
        }
        if route == .live, let c = chat, c.resumeError != nil, !c.isResuming {
            liveRetryAt = WatchFeedRules.retryAfterFailedAttach(now: Date())
            route = .throughPhone
        }
        if route == .live, chat == nil || !model.socketUsable { route = .throughPhone }
        if route == .offline { route = .throughPhone }
    }

    // MARK: The live path

    private func syncLive(_ c: ChatSession) {
        lastLiveSync = Date()
        let all = c.items
        let settled = WatchFeedRules.settled(all)
        // Still resuming, the chat shows its cached transcript: the gate learns, and announces nothing until the load is done.
        apply(settled: settled, cards: c.cards, working: c.isRunning, status: c.statusLine, tools: WatchFeedRules.turnTools(all),
              loaded: !c.isResuming)
        if c.interruptCause != nil, let b = c.banner { problem = WatchFeedProblem(kind: .interrupted, text: b) }
        else if let b = c.banner { problem = WatchFeedProblem.from(b) }
        isLoading = c.showsSyncing
        observe(c)
    }

    /// One read of the chat's state; any change to it, or to the socket, asks for the next read.
    private func observe(_ c: ChatSession) {
        withObservationTracking {
            _ = c.items; _ = c.cards; _ = c.isRunning; _ = c.statusLine
            _ = c.resumeError; _ = c.isResuming; _ = c.banner
            _ = model.socketUsable
        } onChange: { [weak self] in
            Task { @MainActor in self?.wake(.liveChanged) }
        }
    }

    // MARK: The phone path

    /// The history over HTTP (the Watch's own connection, or relayed by the iPhone when that does not reach the
    /// gateway), then the turn and its cards from the iPhone.
    private func refreshThroughPhone(_ rt: GatewayRuntime) async {
        var history: [TranscriptItem]?
        do {
            let r: JSONValue = try await rt.api.get("/api/sessions/\(storedID)/messages",
                                                    query: [URLQueryItem(name: "order", value: "latest"), URLQueryItem(name: "limit", value: String(limit + 2))],
                                                    profile: profile ?? rt.selectedProfile)
            let msgs = (r["messages"]?.arrayValue ?? r.arrayValue ?? []).compactMap { try? $0.decode(TranscriptMessage.self) }
            history = TranscriptItem.fromHistory(msgs).sorted { $0.timestamp < $1.timestamp }
            hasEarlier = msgs.count >= limit + 2
        } catch is CancellationError {
            return
        } catch {
            if items.isEmpty { problem = WatchFeedProblem.from(error.localizedDescription) }
        }
        var phoneCards = cards, working = isWorking, status = statusLine
        do {
            let reply = try await model.askPhone(["op": "cards", "session": storedID, "profile": profile ?? ""])
            if reply["ok"] as? Bool == true {
                phoneCards = WatchFeedRules.cards(from: reply["cards"] as? [[String: Any]] ?? [])
                working = reply["running"] as? Bool ?? false
                status = (reply["status"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if problem?.kind == .phoneAway { problem = nil }
            } else if let e = reply["error"] as? String {
                problem = WatchFeedProblem.from(e)
            }
        } catch is CancellationError {
            return
        } catch {
            problem = WatchFeedProblem.from(error.localizedDescription, phoneAway: true)
            if history == nil { route = .offline }
        }
        let built = history ?? []
        if history != nil {
            // A message sent from here stays until the history has it.
            sentLocally.removeAll { sent in
                guard case .user(let t, _) = sent.kind else { return true }
                return built.contains { if case .user(let h, _) = $0.kind { return h == t && $0.timestamp >= sent.timestamp.addingTimeInterval(-5) }; return false }
            }
        }
        let settled = history.map { WatchFeedRules.settled($0) + sentLocally } ?? items
        apply(settled: settled, cards: phoneCards, working: working, status: status, tools: WatchFeedRules.turnTools(built))
        isLoading = false
    }

    // MARK: Both paths

    private func apply(settled: [TranscriptItem], cards newCards: [PendingCard], working: Bool, status: String?, tools: [ToolActivity],
                       loaded: Bool = true) {
        let shown = Array(settled.suffix(limit))
        // Only what changed: a fresh array every read laid out every row again.
        if shown.map(\.id) != items.map(\.id) || shown.last?.kind != items.last?.kind { items = shown }
        if route == .live { hasEarlier = settled.count > limit }
        if newCards.map(\.id) != cards.map(\.id) { cards = newCards }
        if working != isWorking { isWorking = working }
        let line = working ? status : nil
        if line != statusLine { statusLine = line }
        let steps = working ? tools : []
        if steps != turnTools { turnTools = steps }
        if let kind = WatchFeedEventGate.strongest(gate.arrivals(items: settled, cardIDs: newCards.map(\.id), loaded: loaded)) {
            event = WatchFeedEvent(kind: kind)
        }
    }

    /// One wake when the live path may be tried again, while the chat is on the phone path with the socket up
    /// (`WatchFeedRules.liveRetryWake`): when an attach failed, after its wait; otherwise at once. None on the live path
    /// or with the socket down.
    private func scheduleLiveRetry() {
        guard let wait = WatchFeedRules.liveRetryWake(route: route, socketUsable: model.socketUsable, retryAt: liveRetryAt, now: Date()) else {
            liveRetryTask?.cancel(); liveRetryTask = nil
            return
        }
        guard liveRetryTask == nil else { return }
        liveRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.liveRetryTask = nil
            self.wake(.liveChanged)
        }
    }

    /// The next read only while a turn runs on the phone path (`WatchFeedRules.pollInterval`).
    private func schedulePoll() {
        guard let seconds = WatchFeedRules.pollInterval(route: route, working: isWorking) else {
            pollTask?.cancel(); pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.pollTask = nil
            self.wake(.poll)
        }
    }

    /// While the chat stays open at rest on the phone path, the iPhone's follow (10 minutes from the last request) is
    /// renewed every 9; the live path has the socket and needs none.
    private func scheduleFollow() {
        guard route != .live else { followTask?.cancel(); followTask = nil; return }
        guard followTask == nil else { return }
        followTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(WatchFeedRules.followSeconds - 60))
                guard !Task.isCancelled, let self, self.route != .live else { return }
                _ = try? await self.model.askPhone(["op": "follow", "session": self.storedID, "profile": self.profile ?? ""])
            }
        }
    }

    /// Leaving the chat: the iPhone stops telling the Watch about it.
    private func leave() {
        guard route != .live else { return }
        let model = model, id = storedID
        Task { _ = try? await model.askPhone(["op": "follow", "session": id, "on": false]) }
    }

    // MARK: Actions

    func loadEarlier() async {
        limit += 20
        wake(.loadEarlier)
    }

    func dismissProblem() {
        problem = nil
        chat?.banner = nil
    }

    /// Sends on the live chat, or through the iPhone. A live chat that could not attach hands the message to the phone.
    func send(_ text: String) async throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if route == .live, let c = chat {
            guard let why = await c.send(t) else { problem = nil; return }
            guard c.resumeError != nil else {
                problem = WatchFeedProblem.from(why)
                throw WatchFeedSendError(why)
            }
            liveRetryAt = WatchFeedRules.retryAfterFailedAttach(now: Date())
            route = .throughPhone
            gate.reseed()
        }
        do {
            let r = try await model.askPhone(["op": "prompt", "session": storedID, "profile": profile ?? "", "text": t])
            guard r["ok"] as? Bool == true else {
                let why = r["error"] as? String ?? "The iPhone could not send it."
                problem = WatchFeedProblem.from(why)
                throw WatchFeedSendError(why)
            }
            problem = nil
            isWorking = true
            sentLocally.append(TranscriptItem(id: "local-\(UUID().uuidString)", kind: .user(text: t, attachments: [])))
            items = Array((items + sentLocally.suffix(1)).suffix(limit))
            wake(.sent)
        } catch let e as WatchProxyError {
            problem = WatchFeedProblem.from(e.localizedDescription, phoneAway: true)
            throw e
        }
    }

    func stop() async {
        if route == .live, let c = chat { await c.stop(); return }
        _ = try? await model.askPhone(["op": "stop", "session": storedID, "profile": profile ?? ""])
        wake(.sent)
    }

    /// An approval by the gateway's choice key ("once", "session", "always", "deny"); a question by one of its offered
    /// answers.
    func answer(_ card: PendingCard, choice: String) async throws {
        guard card.method == "approval" else { return try await answer(card, text: choice) }
        if route == .live, let c = chat {
            await c.respond(card: card, result: ["choice": .string(choice)])
            return
        }
        let r = try await model.askPhone(["op": "approval", "session": storedID, "profile": profile ?? "", "card": card.id, "choice": choice])
        guard r["ok"] as? Bool == true else { throw WatchFeedSendError(r["error"] as? String ?? "The iPhone could not answer it.") }
        cards.removeAll { $0.id == card.id }
    }

    /// A question answered in words, or a value prompt's value.
    func answer(_ card: PendingCard, text: String) async throws {
        let key = card.method == "clarify" ? "answer" : "value"
        if route == .live, let c = chat {
            await c.respond(card: card, result: .object([key: .string(text)]))
            return
        }
        let r = try await model.askPhone(["op": "answer", "session": storedID, "profile": profile ?? "", "card": card.id, "text": text])
        guard r["ok"] as? Bool == true else { throw WatchFeedSendError(r["error"] as? String ?? "The iPhone could not answer it.") }
        cards.removeAll { $0.id == card.id }
    }

    /// Where Talk (a hold on the mic) sends: the live chat on its socket, else the iPhone.
    var talkTarget: TalkTarget? {
        if route == .live, let chat { return .live(chat) }
        guard let rt = model.runtime else { return nil }
        return .phone(PhoneTalk(model: model, runtime: rt, storedID: storedID, profile: profile))
    }
}
