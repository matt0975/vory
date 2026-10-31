import Foundation
import Testing
@testable import Vory

/// The motion model behind the 1.5 bot (#304): symbols blend without pops however a change is
/// interrupted, the eyes go with the symbol, blinks close, the squash never stacks, and a bot
/// with nothing to do settles so its timeline can pause.
@Suite struct BotMotionModelTests {
    let states: [BotFace.State] = [.idle, .thinking, .searching, .usingTool, .streaming, .awaitingApproval, .error, .reconnecting, .listening]

    private func run(_ model: BotMotionModel, _ state: BotFace.State, from t0: Double, seconds: Double, hz: Double = 60, body: (BotMotionFrame, BotMotionFrame?) -> Void = { _, _ in }) -> Double {
        var t = t0
        var last: BotMotionFrame?
        let dt = 1 / hz
        while t < t0 + seconds {
            t += dt
            let f = model.advance(to: t, targets: .targets(for: state))
            body(f, last)
            last = f
        }
        return t
    }

    /// Back-to-back tools (the burst of 2026-10-10: terminal complete, todo start 0.2 s later,
    /// "Thinking…" in the gap) keep the toolbox: a change must last 0.3 s before it shows, so
    /// nothing flashes for a frame or two. An urgent symbol (words, an approval, an error, a
    /// lost connection) shows at once; a change that does last is taken up after the hold.
    @Test func aChangeShorterThanTheHoldNeverShows() throws {
        let m = BotMotionModel(seed: 5)
        m.snap(to: .targets(for: .usingTool), at: 0)
        var t = run(m, .usingTool, from: 0, seconds: 1.4)
        // The gap: 0.2 s of thinking between two tools.
        t = run(m, .thinking, from: t, seconds: 0.2) { f, _ in
            #expect(f.amount(of: .toolbox) > 0.97, "the toolbox left during a 0.2 s gap")
            #expect(f.amount(of: .orb) < 0.01, "the orb showed during a 0.2 s gap")
            #expect(f.halo < 0.01, "the halo lit during a 0.2 s gap")
        }
        t = run(m, .usingTool, from: t, seconds: 0.5) { f, _ in
            #expect(f.amount(of: .toolbox) > 0.97 && f.amount(of: .orb) < 0.01, "a pop after the gap")
        }
        #expect(m.shownTargets.visual == .toolbox)
        // A tool too short to show: rest, a 0.2 s tool, rest again.
        m.snap(to: .targets(for: .idle), at: t)
        t = run(m, .usingTool, from: t, seconds: 0.2) { f, _ in #expect(f.amount(of: .toolbox) < 0.01, "a 0.2 s tool showed its toolbox") }
        t = run(m, .idle, from: t, seconds: 0.5) { f, _ in #expect(f.amount(of: .toolbox) < 0.01) }
        // A tool that lasts is taken up once the hold has passed.
        var first: Double?
        t = run(m, .usingTool, from: t, seconds: 1) { f, _ in if first == nil, f.amount(of: .toolbox) > 0.01 { first = m.lastAdvanceTime } }
        let started = try #require(first)
        #expect(started - (t - 1) > 0.28 && started - (t - 1) < 0.36, "the toolbox came up \(started - (t - 1)) s in, not after the 0.3 s hold")
        #expect(m.shownTargets.visual == .toolbox)
        // Words arriving cut the hold short: the bubbles start within two frames.
        var bubblesAt: Double?
        t = run(m, .streaming, from: t, seconds: 0.5) { f, _ in if bubblesAt == nil, f.amount(of: .bubbles) > 0.01 { bubblesAt = m.lastAdvanceTime } }
        #expect(bubblesAt != nil && bubblesAt! - (t - 0.5) < 0.05, "the bubbles waited \(String(describing: bubblesAt.map { $0 - (t - 0.5) })) s")
    }

    @Test func aStateSettlesAndIdleHasNothingLeftToDo() {
        let m = BotMotionModel(seed: 3)
        m.advance(to: 0, targets: .targets(for: .idle))
        _ = run(m, .thinking, from: 0, seconds: 1.5)
        #expect(!m.isSettled, "thinking loops (the pulse) and never settles")
        // 1.5 s for the springs, after the 0.3 s hold on the change.
        _ = run(m, .idle, from: 1.5, seconds: 1.8)
        #expect(m.isSettled, "idle with every spring on its target should settle; still moving: \(m.unsettled)")
        #expect(m.advance(to: 3.4, targets: .targets(for: .idle)).amount(of: .orb) < 0.001)
    }

    @Test func everyInterruptedChangeStaysSmooth() {
        // A to B, then C before B has settled, at three moments: no symbol amount moves more
        // than 0.15 in one 60 Hz frame, and the eyes never come back while a hiding symbol grows.
        for a in states { for b in states where b != a { for c in states where c != b {
            for cut in [0.05, 0.15, 0.3] {
                let m = BotMotionModel(seed: 1)
                _ = run(m, a, from: 0, seconds: 1.5)
                var t = run(m, b, from: 1.5, seconds: cut)
                var worst = 0.0
                var eyeRose = false
                t = run(m, c, from: t, seconds: 1.0) { f, last in
                    guard let last else { return }
                    for v in BotVisual.allCases { worst = max(worst, abs(f.amount(of: v) - last.amount(of: v))) }
                    let hiding = BotVisual.allCases.filter(\.hidesEyes).contains { f.amount(of: $0) > last.amount(of: $0) + 0.001 && f.amount(of: $0) > 0.05 }
                    if hiding, f.eyeOpacity > last.eyeOpacity + 0.001 { eyeRose = true }
                }
                #expect(worst <= 0.15, "\(a) → \(b) → \(c) at \(cut) s: a symbol jumped \(worst) in one frame")
                #expect(!eyeRose, "\(a) → \(b) → \(c) at \(cut) s: the eyes came back while a symbol that hides them grew")
                _ = t
            }
        } } }
    }

    @Test func theSamePathAtAnyFrameRate() {
        func sample(hz: Double) -> [Double] {
            let m = BotMotionModel(seed: 2)
            m.advance(to: 0, targets: .targets(for: .idle))   // the clock starts here at every rate
            var out: [Double] = []
            var t = 0.0
            let dt = 1 / hz
            while t < 1.0 - 1e-9 {
                t += dt
                let f = m.advance(to: t, targets: .targets(for: .thinking))
                if abs(t * 10 - (t * 10).rounded()) < 1e-6 { out.append(f.amount(of: .orb)) }
            }
            return out
        }
        let a = sample(hz: 30), b = sample(hz: 60), c = sample(hz: 120)
        #expect(a.count == 10 && b.count == 10 && c.count == 10)
        for i in 0..<10 { #expect(abs(a[i] - b[i]) < 0.002 && abs(b[i] - c[i]) < 0.002, "sample \(i): \(a[i]) \(b[i]) \(c[i])") }
    }

    @Test func blinksCloseFullyAndNeverStackWithTheSquash() {
        let m = BotMotionModel(seed: 5)
        var lowest = 1.0
        _ = run(m, .idle, from: 0, seconds: 10) { f, _ in lowest = min(lowest, f.eyeOpen) }
        #expect(lowest <= 0.12, "a blink only reached \(lowest)")
        // Flipping states every 0.1 s: the squash is rate-limited and clamped.
        var t = 10.0
        var worst = 1.0
        for i in 0..<30 {
            let s: BotFace.State = i % 2 == 0 ? .thinking : .usingTool
            t = run(m, s, from: t, seconds: 0.1) { f, _ in worst = min(worst, f.sy) }
        }
        #expect(worst >= 0.94, "sy dipped to \(worst)")
    }

    @Test func oneWakeupPerBlink() {
        // The next blink after a moment is a real blink on the schedule, and there is none sooner.
        let seed = 7
        for s0 in stride(from: 0.0, to: 40.0, by: 1.3) {
            // From a moment with no blink under way (a wakeup is scheduled from such moments).
            var start = s0
            while BotMotionModel.blink(at: start, seed: seed) > 0.01 { start += 0.01 }
            let next = BotMotionModel.nextBlink(after: start, seed: seed)
            #expect(next > start)
            #expect(BotMotionModel.blink(at: next + 0.02, seed: seed) > 0.3, "no blink at \(next) (from \(start))")
            var quiet = true
            var t = start + 0.001
            while t < next - 0.001 { if BotMotionModel.blink(at: t, seed: seed) > 0.01 { quiet = false; break }; t += 0.01 }
            #expect(quiet, "a blink before \(next) (from \(start))")
        }
    }

    @Test func theFinishSpinOrbitsOnceAndEnds() {
        let m = BotMotionModel(seed: 1)
        _ = run(m, .idle, from: 0, seconds: 1)
        m.spin(at: 1)
        var peak = 0.0
        _ = run(m, .idle, from: 1, seconds: 0.6) { f, _ in peak = max(peak, f.orbit) }
        #expect(peak > 0.5 && peak < 1)
        _ = run(m, .idle, from: 1.6, seconds: 0.3)
        #expect(m.advance(to: 2.0, targets: .targets(for: .idle)).orbit == 0)
        #expect(m.isSettled)
    }

    /// A moment from `t` on with no scheduled blink for `seconds`, so a blink seen is the tap's.
    private func quiet(after t: Double, seed: Int, seconds: Double = 0.6) -> Double {
        var t0 = t
        while stride(from: t0, to: t0 + seconds, by: 1.0 / 120).contains(where: { BotMotionModel.blink(at: $0, seed: seed) > 0 }) { t0 += 0.25 }
        return t0
    }

    /// A tap: a blink and a small bounce, then rest. The model is unsettled
    /// while it plays, so the face's clock runs, and settled soon after, so it pauses again.
    @Test func aTapBlinksBouncesAndSettles() {
        let m = BotMotionModel(seed: 1)
        let t0 = quiet(after: 2, seed: 1)
        _ = run(m, .idle, from: 0, seconds: t0)
        #expect(m.isSettled)
        m.react(at: t0)
        var minEye = 1.0, minSy = 1.0
        _ = run(m, .idle, from: t0, seconds: 0.3) { f, _ in minEye = min(minEye, f.eyeOpen); minSy = min(minSy, f.sy) }
        #expect(minEye < 0.2, "no blink: \(minEye)")
        #expect(minSy < 0.97, "no bounce: \(minSy)")
        #expect(m.unsettled.contains("react"))
        _ = run(m, .idle, from: t0 + 0.3, seconds: 1.5)
        #expect(m.isSettled, "still moving: \(m.unsettled)")
    }

    /// A foldable phone opening (Duo stage 4): one blink, the tap's, with no bounce, then rest.
    @Test func anOpeningBlinksWithoutABounceAndSettles() {
        let m = BotMotionModel(seed: 1)
        let t0 = quiet(after: 2, seed: 1)
        _ = run(m, .idle, from: 0, seconds: t0)
        #expect(m.isSettled)
        m.blink(at: t0)
        var minEye = 1.0, sy = (lo: 1.0, hi: 1.0), sx = (lo: 1.0, hi: 1.0)
        _ = run(m, .idle, from: t0, seconds: 0.3) { f, _ in
            minEye = min(minEye, f.eyeOpen); sy = (min(sy.lo, f.sy), max(sy.hi, f.sy)); sx = (min(sx.lo, f.sx), max(sx.hi, f.sx))
        }
        #expect(minEye < 0.2, "no blink: \(minEye)")
        #expect(sy.lo > 0.999 && sy.hi < 1.001 && sx.lo > 0.999 && sx.hi < 1.001, "it bounced: sy \(sy) sx \(sx)")
        _ = run(m, .idle, from: t0 + 0.3, seconds: 1)
        #expect(m.isSettled, "still moving: \(m.unsettled)")
    }

    /// The opening's blink keeps the clock running while it plays, so a paused face wakes for it.
    @Test func anOpeningsBlinkHoldsTheClockUntilItEnds() {
        let m = BotMotionModel(seed: 1)
        let t0 = quiet(after: 2, seed: 1)
        _ = run(m, .idle, from: 0, seconds: t0)
        m.blink(at: t0)
        #expect(m.unsettled.contains("blink"))
        _ = run(m, .idle, from: t0, seconds: BotMotionModel.Reaction.blinkLength + 0.05)
        #expect(!m.unsettled.contains("blink"))
    }

    /// Reduce Motion and a held face snap to the still on every frame: an opening moves nothing.
    @Test func aSnappedFaceDoesNotBlinkForAnOpening() {
        let m = BotMotionModel(seed: 1)
        let t0 = quiet(after: 2, seed: 1)
        _ = run(m, .idle, from: 0, seconds: t0)
        m.blink(at: t0)
        var t = t0, minEye = 1.0
        for _ in 0..<30 {
            t += 1.0 / 60
            m.snap(to: .targets(for: .idle), at: t)
            minEye = min(minEye, m.advance(to: t, targets: .targets(for: .idle)).eyeOpen)
        }
        #expect(minEye > 0.99)
    }

    /// A face mounted for the tap (a list's still swapped for the live view) plays it from its
    /// first frame.
    @Test func aTapBeforeTheFirstFrameStillPlays() {
        let m = BotMotionModel(seed: 1)
        let t0 = quiet(after: 2, seed: 1)
        m.react(at: t0 - 0.02)
        var minEye = 1.0
        _ = run(m, .idle, from: t0, seconds: 0.3) { f, _ in minEye = min(minEye, f.eyeOpen) }
        #expect(minEye < 0.3, "no blink: \(minEye)")
    }

    /// Reduce Motion and a held face snap to the still on every frame: a tap moves nothing.
    @Test func aSnappedFaceDoesNotReact() {
        let m = BotMotionModel(seed: 1)
        let t0 = quiet(after: 2, seed: 1)
        _ = run(m, .idle, from: 0, seconds: t0)
        m.react(at: t0)
        var t = t0, minEye = 1.0, sy = (lo: 1.0, hi: 1.0)
        for _ in 0..<30 {
            t += 1.0 / 60
            m.snap(to: .targets(for: .idle), at: t)
            let f = m.advance(to: t, targets: .targets(for: .idle))
            minEye = min(minEye, f.eyeOpen); sy = (min(sy.lo, f.sy), max(sy.hi, f.sy))
        }
        #expect(minEye > 0.99 && sy.lo == 1 && sy.hi == 1)
    }

    /// A tap whose face is covered (a card's push, Bot info) leaves one
    /// arrival for the page that lands; it plays once there and is used up, so a pop back to the
    /// page, a remount or Bot info shown again without a new tap plays nothing. A stale one (the
    /// page never landed) is dropped.
    @MainActor @Test func anArrivalPlaysOnceAndIsUsedUp() {
        let a = BotAmbient.shared
        let bot = "arrival-test-bot"
        defer { a.tapped[bot] = nil }
        a.markArrival(profile: bot)
        #if os(macOS)
        // The Mac has no tap reaction and no arrival (Matt, 2026-10-13): nothing is held back.
        #expect(!a.arrivalWaits(profile: bot) && !a.arrive(profile: bot), "the Mac kept an arrival")
        #expect(!BotMotionModel.Reaction.plays, "a tap plays on the Mac")
        #else
        let now = Date()
        // A face mounting on the arriving page holds its reaction until the landing.
        #expect(a.arrivalWaits(profile: bot) && !a.arrivalWaits(profile: "another-bot") && !a.arrivalWaits(profile: nil))
        #expect(!a.arrive(profile: "another-bot", now: now), "another bot's page took the arrival")
        #expect(a.arrive(profile: bot, now: now))
        #expect(!a.arrivalWaits(profile: bot), "a used-up arrival still holds a face back")
        #expect(a.tapped[bot] == now, "the arriving face is not told")
        #expect(!a.arrive(profile: bot, now: now.addingTimeInterval(0.5)), "the arrival played twice")
        a.markArrival(profile: bot)
        #expect(!a.arrivalWaits(profile: bot, now: Date().addingTimeInterval(4)), "a stale arrival held a face back")
        #expect(!a.arrivalWaits(profile: bot), "a stale arrival was not dropped")
        a.markArrival(profile: bot)
        #expect(!a.arrive(profile: bot, now: Date().addingTimeInterval(4)), "a stale arrival played")
        #endif
    }

    @Test func snappingIsAStillFrameOfTheState() {
        let m = BotMotionModel(seed: 1)
        m.snap(to: .targets(for: .awaitingApproval), at: 0)
        let f = m.advance(to: 0, targets: .targets(for: .awaitingApproval))
        #expect(f.amount(of: .exclaim) == 1 && f.amount(of: .rest) == 0 && f.eyeOpacity == 0)
    }
}
