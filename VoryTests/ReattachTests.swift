import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// #641: a chat that can't re-attach keeps trying by itself. A chat on screen is tried on the schedule
/// (`ReattachScheduleTests`), saying nothing for 2 s, then a quiet line, then from a minute a banner with Try again; one
/// off screen is tried once per trigger. A socket that went is waited for, with no tries of the chat's own. A chat the
/// gateway no longer has is said at once and not tried again. A try a newer reconnect superseded says nothing. Away, the
/// tries and the clock stop; back, a fresh minute. A long chat's slow resume gets a longer second try.
@MainActor @Suite struct ReattachTests {
    private func chat() throws -> ChatSession {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        return ChatSession(runtime: rt, storedID: "s1", title: nil)
    }

    private func chatOnManualClock() throws -> (ChatSession, ManualClock) {
        let c = try chat()
        let clock = ManualClock()
        c.reattachClock = clock.reattach
        return (c, clock)
    }

    static let snapshot: JSONValue = ["session_id": "rt1", "running": false, "messages": []]

    /// The re-attach's clock in a test's hands: time moves only when the test says, and each sleeper it reaches wakes
    /// in turn, with what it starts let run before the next.
    @MainActor final class ManualClock {
        private let start = Date(timeIntervalSince1970: 1_000_000)
        private(set) var now = Date(timeIntervalSince1970: 1_000_000)
        private var sleepers: [(id: Int, until: Date, c: CheckedContinuation<Void, Error>)] = []
        private var nextID = 0

        var elapsed: Double { now.timeIntervalSince(start) }

        nonisolated var reattach: ReattachClock {
            ReattachClock(now: { MainActor.assumeIsolated { self.now } }, sleep: { d in try await self.sleep(d) })
        }

        func sleep(_ seconds: Double) async throws {
            let until = now.addingTimeInterval(seconds)
            let id = nextID
            nextID += 1
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in sleepers.append((id, until, c)) }
            } onCancel: {
                Task { @MainActor in self.cancel(id) }
            }
        }

        private func cancel(_ id: Int) {
            guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return }
            sleepers.remove(at: i).c.resume(throwing: CancellationError())
        }

        func advance(_ seconds: Double) async {
            let end = now.addingTimeInterval(seconds)
            while let next = sleepers.filter({ $0.until <= end }).min(by: { $0.until < $1.until }) {
                now = max(now, next.until)
                sleepers.removeAll { $0.id == next.id }
                next.c.resume()
                await settle()
            }
            now = end
            await settle()
        }

        func settle() async { for _ in 0..<60 { await Task.yield() } }
    }

    /// When each session.resume was asked (in the clock's seconds), and how many were out at once.
    @MainActor final class ResumeLog {
        var at: [Double] = []
        var succeed = false
        var inFlight = 0
        var maxInFlight = 0
    }

    /// Each gap between tries is the schedule's, within its jitter (and the test's half-second steps).
    private func backsOff(_ at: [Double], _ delays: [Double]) -> Bool {
        let gaps = zip(at.dropFirst(), at).map { $0 - $1 }
        return zip(gaps, delays).allSatisfy { gap, d in gap >= d * 0.8 - 0.5 && gap <= d * 1.2 + 0.5 }
    }

    /// 4. A slow gateway is tried again on its own until it answers: timing out on the first two tries (at 0 and about
    /// 2 s), answering on the third (about 7 s). Before #641: two tries, then "Reconnected, but the chat could not be
    /// re-attached: Timed out waiting for session.resume." (still pinned at the base by the test this replaces).
    @Test func aSlowGatewayIsTriedAgainOnItsOwnUntilItAnswers() async throws {
        let c = try chat()
        let log = ResumeLog()
        c.gatewayStandIn = { method, _ in
            guard method == "session.resume" else { return .object([:]) }
            log.at.append(Date().timeIntervalSince1970)
            if log.at.count < 3 { throw SocketError.timeout("session.resume") }
            return Self.snapshot
        }
        c.cameOnScreen()
        await c.reattachAfterReconnect()
        for _ in 0..<120 where c.stale || c.reattachShow != .none { try await Task.sleep(for: .milliseconds(100)) }
        #expect(log.at.count == 3, "tries: \(log.at.count)")
        #expect(!c.stale)
        #expect(c.banner == nil)
        #expect(c.reattachShow == .none)
    }

    /// 5. The tries back off: six failures land at about 0, 2, 7, 17, 37 and 67 s.
    @Test func theTriesBackOff() async throws {
        let (c, clock) = try chatOnManualClock()
        let log = ResumeLog()
        c.gatewayStandIn = { method, _ in
            guard method == "session.resume" else { return .object([:]) }
            log.at.append(clock.elapsed)
            throw SocketError.closed(code: 1011, reason: "server error")
        }
        c.cameOnScreen()
        await c.reattachAfterReconnect()
        for _ in 0..<170 { await clock.advance(0.5) }
        #expect(log.at.count >= 6, "tries at \(log.at)")
        #expect(backsOff(log.at, [2, 5, 10, 20, 30]), "tries at \(log.at)")
    }

    /// 6. Nothing for 2 s, the quiet line, the banner with Try again from a minute, and gone when a try works.
    @Test func theBannerWithTryAgainComesAtAMinuteAndGoesWhenATryWorks() async throws {
        let (c, clock) = try chatOnManualClock()
        c.gatewayStandIn = { method, _ in
            guard method == "session.resume" else { return .object([:]) }
            if clock.elapsed < 70 { throw SocketError.closed(code: 1011, reason: "server error") }
            return Self.snapshot
        }
        c.cameOnScreen()
        await c.reattachAfterReconnect()
        await clock.advance(1)
        #expect(c.reattachShow == .none)
        await clock.advance(2)
        #expect(c.reattachShow == .reconnecting)
        for _ in 0..<56 { await clock.advance(1) }
        #expect(c.reattachShow == .reconnecting, "at 59 s")
        await clock.advance(2)
        #expect(c.reattachShow == .failed, "at 61 s")
        #expect(c.banner == nil)
        for _ in 0..<120 { await clock.advance(0.5) }
        #expect(c.reattachShow == .none)
        #expect(!c.stale)
    }

    /// 7. Try again tries at once: the banner is up and the next try is seconds off.
    @Test func tryAgainTriesAtOnce() async throws {
        let (c, clock) = try chatOnManualClock()
        let log = ResumeLog()
        c.gatewayStandIn = { method, _ in
            guard method == "session.resume" else { return .object([:]) }
            log.at.append(clock.elapsed)
            if !log.succeed { throw SocketError.closed(code: 1011, reason: "server error") }
            return Self.snapshot
        }
        c.cameOnScreen()
        await c.reattachAfterReconnect()
        for _ in 0..<122 { await clock.advance(0.5) }
        #expect(c.reattachShow == .failed)
        let before = log.at.count
        log.succeed = true
        c.tryAgain()
        await clock.settle()
        #expect(log.at.count == before + 1)
        #expect(c.reattachShow == .none)
        #expect(!c.stale)
    }

    /// 8. A chat the gateway no longer has is said at once and not tried again.
    @Test func aChatTheGatewayNoLongerHasIsSaidAtOnceAndNotTriedAgain() async throws {
        let c = try chat()
        let log = ResumeLog()
        c.gatewayStandIn = { method, _ in
            guard method == "session.resume" else { return .object([:]) }
            log.at.append(0)
            throw RPCError(code: 4007, message: "session not found")
        }
        c.cameOnScreen()
        await c.reattachAfterReconnect()
        try await Task.sleep(for: .seconds(3))
        #expect(log.at.count == 1)
        #expect(c.banner == ChatSession.goneBanner)
        #expect(c.reattachShow == .none)
    }

    /// 9. A socket that went is waited for quietly: no banner, the line after 2 s, no try of the chat's own, and the
    /// socket's return tries it and attaches it.
    @Test func aSocketThatWentWaitsForTheSocketQuietly() async throws {
        let (c, clock) = try chatOnManualClock()
        let log = ResumeLog()
        c.gatewayStandIn = { method, _ in
            guard method == "session.resume" else { return .object([:]) }
            log.at.append(clock.elapsed)
            if !log.succeed { throw SocketError.notConnected }
            return Self.snapshot
        }
        c.cameOnScreen()
        await c.reattachAfterReconnect()
        #expect(c.stale)
        #expect(c.banner == nil)
        await clock.advance(3)
        #expect(c.reattachShow == .reconnecting)
        for _ in 0..<20 { await clock.advance(1) }
        #expect(log.at.count == 1, "tried while waiting for the socket: \(log.at)")
        #expect(c.banner == nil)
        log.succeed = true
        c.reattachNow()
        await clock.settle()
        #expect(log.at.count == 2)
        #expect(!c.stale)
        #expect(c.reattachShow == .none)
    }

    /// 10. A re-attach a newer reconnect superseded says nothing. Its wait for the socket was cancelled, and a
    /// cancelled wait throws the socket's timeout ("gateway.ready (cancelled)"), not a CancellationError, so it read as a
    /// slow gateway: tried once more, then the banner.
    @Test func aReattachCancelledByANewerReconnectSaysNothing() async throws {
        let c = try chat()
        c.gatewayStandIn = { _, _ in
            // As the socket's ready wait does: it waits until its task is cancelled, then throws its timeout.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            throw SocketError.timeout("gateway.ready (cancelled)")
        }
        let reattach = Task { await c.reattachAfterReconnect() }
        try await Task.sleep(for: .milliseconds(100))
        reattach.cancel()
        await reattach.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(c.banner == nil, "a superseded re-attach said: \(c.banner ?? "")")
    }

    /// 11. Away stops the tries and the clock; coming back tries at once, with a fresh minute before any banner.
    @Test func awayStopsTheTriesAndComingBackTriesAtOnceWithAFreshMinute() async throws {
        let (c, clock) = try chatOnManualClock()
        let log = ResumeLog()
        c.gatewayStandIn = { method, _ in
            guard method == "session.resume" else { return .object([:]) }
            log.at.append(clock.elapsed)
            throw SocketError.closed(code: 1011, reason: "server error")
        }
        c.cameOnScreen()
        await c.reattachAfterReconnect()
        for _ in 0..<20 { await clock.advance(0.5) }
        let beforeAway = log.at.count
        c.wentAwayForReattach()
        for _ in 0..<60 { await clock.advance(10) }
        #expect(log.at.count == beforeAway, "tried while away: \(log.at)")
        c.cameBackForReattach()
        c.reattachNow()
        await clock.settle()
        #expect(log.at.count == beforeAway + 1, "no try at once on coming back")
        await clock.advance(1)
        #expect(c.reattachShow == .none)
        await clock.advance(2)
        #expect(c.reattachShow == .reconnecting)
        for _ in 0..<56 { await clock.advance(1) }
        #expect(c.reattachShow == .reconnecting, "a banner within a minute of coming back")
    }

    /// 12. Any other failure (a close, a server error) is tried again quietly, and said only from a minute, in the
    /// re-attach's own banner, not the chat's.
    @Test func anyOtherFailureIsTriedAgainQuietlyAndSaidAfterAMinute() async throws {
        let (c, clock) = try chatOnManualClock()
        c.gatewayStandIn = { method, _ in
            guard method == "session.resume" else { return .object([:]) }
            throw SocketError.closed(code: 1011, reason: "server error")
        }
        c.cameOnScreen()
        await c.reattachAfterReconnect()
        #expect(c.banner == nil)
        #expect(c.reattachShow == .none)
        await clock.advance(3)
        #expect(c.reattachShow == .reconnecting)
        for _ in 0..<58 { await clock.advance(1) }
        #expect(c.reattachShow == .failed)
        #expect(c.banner == nil)
    }

    /// 17. A long chat's resume, slow on the link (each try answered 45 s after it's asked):
    /// the first try times out at 30 s, the second has 60 s and attaches.
    @Test func aSlowResumeOfALongChatAttachesOnTheSecondTry() async throws {
        let (c, clock) = try chatOnManualClock()
        let log = ResumeLog()
        c.gatewayStandIn = { method, _ in
            guard method == "session.resume" else { return .object([:]) }
            log.at.append(clock.elapsed)
            try await clock.sleep(45)
            return Self.snapshot
        }
        c.cameOnScreen()
        let first = Task { await c.reattachAfterReconnect() }
        await clock.settle()
        for _ in 0..<200 { await clock.advance(0.5) }
        await first.value
        #expect(log.at.count == 2, "tries at \(log.at)")
        if log.at.count >= 2 { #expect(log.at[1] >= 30, "the second try came before the first's 30 s: \(log.at)") }
        #expect(!c.stale)
        #expect(c.reattachShow == .none)
    }

    /// 18. Ten chats in the registry, one on screen, every try failing for two minutes after
    /// a reconnect: the shown chat tries on the schedule; each of the other nine tries once, one at a time.
    @Test func tenChatsInTheRegistryMakeOneTryEachPerTriggerAndOnlyTheShownOneBacksOff() async throws {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        let clock = ManualClock()
        let shown = ResumeLog(), others = ResumeLog()
        var chats: [ChatSession] = []
        for i in 0..<10 {
            let c = ChatSession(runtime: rt, storedID: "s\(i)", title: nil)
            c.reattachClock = clock.reattach
            let log = i == 0 ? shown : others
            c.gatewayStandIn = { method, _ in
                guard method == "session.resume" else { return .object([:]) }
                log.at.append(clock.elapsed)
                log.inFlight += 1
                log.maxInFlight = max(log.maxInFlight, log.inFlight)
                defer { log.inFlight -= 1 }
                for _ in 0..<5 { await Task.yield() }
                throw SocketError.closed(code: 1011, reason: "server error")
            }
            rt.registry.add(c)
            chats.append(c)
        }
        chats[0].cameOnScreen()
        rt.reattachChats(all: true)
        await clock.settle()
        for _ in 0..<240 { await clock.advance(0.5) }
        #expect(others.at.count == 9, "the nine off screen tried \(others.at.count) times")
        #expect(others.maxInFlight == 1, "\(others.maxInFlight) off-screen resumes were out at once")
        #expect(shown.at.count >= 6, "the shown chat tried at \(shown.at)")
        #expect(backsOff(shown.at, [2, 5, 10, 20, 30, 30]), "the shown chat tried at \(shown.at)")
    }

    /// A reconnect that comes while an off-screen pass from a return (or a network
    /// change) is running still reaches an off-screen chat whose open failed, as every reconnect did before #641.
    @Test func aReconnectDuringAnOffScreenPassStillReachesAChatWhoseOpenFailed() async throws {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        let gate = ResumeLog(), reached = ResumeLog()
        let lost = ChatSession(runtime: rt, storedID: "a", title: nil)
        let failedOpen = ChatSession(runtime: rt, storedID: "b", title: nil)
        lost.gatewayStandIn = { method, _ in
            guard method == "session.resume" else { return .object([:]) }
            // Held until the reconnect has come, so the pass is still running then.
            while !gate.succeed { try? await Task.sleep(for: .milliseconds(10)) }
            return Self.snapshot
        }
        failedOpen.gatewayStandIn = { method, _ in
            guard method == "session.resume" else { return .object([:]) }
            reached.at.append(0)
            return Self.snapshot
        }
        rt.registry.add(lost)
        rt.registry.add(failedOpen)
        lost.socketWent()
        failedOpen.resumeError = "Timed out waiting for gateway.ready."
        rt.reattachChats(all: false)
        try await Task.sleep(for: .milliseconds(100))
        rt.reattachChats(all: true)
        gate.succeed = true
        for _ in 0..<150 where reached.at.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!reached.at.isEmpty, "the off-screen chat whose open failed wasn't reached by the reconnect")
    }
}
