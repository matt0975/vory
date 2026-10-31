import Foundation

/// The symbols a bot can become while it works (1.5, #304): the plain body at rest, or one of
/// these in its place. Each has its own amount in the motion model, so an outgoing symbol
/// shrinks while the incoming one grows and an interrupted change never pops.
public enum BotVisual: String, CaseIterable, Sendable {
    case rest, orb, lens, toolbox, warn, exclaim, bolt, bubbles
    /// Symbols that are something other than the body: these take the eyes with them (the eyes
    /// fade with the symbol's amount), except the lens, whose eyes sit inside the glass.
    public var hidesEyes: Bool { self == .bolt || self == .bubbles || self == .warn || self == .exclaim }
    /// Symbols with a reason of their own to show at once (words arriving, an approval, an error,
    /// a lost connection): these cut short the hold on the symbol before them.
    public var urgent: Bool { self == .bubbles || self == .exclaim || self == .warn || self == .bolt }
    /// Symbols with a loop of their own (a pulse, a hop, a glint): the timeline keeps ticking.
    public var loops: Bool { self == .orb || self == .bubbles || self == .bolt || self == .lens }
}

/// What a state asks of the bot: which symbol, where the eyes look and how open, and what
/// loops. A pure function of the state (and `since`, for the one-shots at a state's start), so
/// it is the same on every frame rate and in every test.
public struct BotMotionTargets: Equatable, Sendable {
    public var visual: BotVisual = .rest
    public var eyeOpen: Double = 1
    public var eyeX: Double = 0
    public var eyeY: Double = 0
    public var dim: Double = 0
    /// The orb's halo and the listening arcs, 0 to 1.
    public var halo: Double = 0
    public var arcs: Double = 0
    /// A gentle sway (working), on top of the rest body.
    public var sway: Bool = false
    /// The eyes are held (no wander): asking, error, a tool.
    public var freezeGlance = false
    public init() {}

    /// Anything that keeps moving on its own while the state lasts.
    public var loops: Bool { visual.loops || arcs > 0 || sway }

    /// The targets for `state`. `since` is seconds since the state began.
    public static func targets(for state: BotFace.State, since: Double = 10) -> BotMotionTargets {
        var t = BotMotionTargets()
        switch state {
        case .idle, .guide:
            break
        case .working:
            t.sway = true
        case .thinking:
            t.visual = .orb; t.halo = 1
        case .searching:
            t.visual = .lens
        case .usingTool:
            t.visual = .toolbox; t.eyeX = 0.6; t.eyeY = 0.5; t.freezeGlance = true
        case .streaming:
            t.visual = .bubbles
        case .awaitingApproval:
            t.visual = .exclaim; t.freezeGlance = true
        case .error:
            t.visual = .warn; t.dim = 1; t.freezeGlance = true
        case .reconnecting:
            t.visual = .bolt
        case .listening:
            t.arcs = 1
        }
        return t
    }
}

/// One frame of a bot's motion, as the drawing reads it. Every value is continuous in time.
public struct BotMotionFrame: Equatable, Sendable {
    /// How much of each symbol is showing (0 none, 1 whole). At most one is heading for 1.
    public var amounts: [BotVisual: Double] = [:]
    /// Eyes: how open (blinks included), where they look, how visible.
    public var eyeOpen: Double = 1
    public var eyeX: Double = 0
    public var eyeY: Double = 0
    public var eyeOpacity: Double = 1
    /// The body's squash and stretch (1 is rest) and the error's dimming.
    public var sx: Double = 1
    public var sy: Double = 1
    public var dim: Double = 0
    public var halo: Double = 0
    public var arcs: Double = 0
    /// The finish spin's progress (0 none, 0 to 1 while the eyes orbit the body).
    public var orbit: Double = 0
    /// Seconds into the active symbol's loop, for the pulse, the hop and the glint.
    public var loopTime: Double = 0
    public func amount(of v: BotVisual) -> Double { amounts[v] ?? 0 }
    /// The symbol most on show, if any beyond the body.
    public var leading: BotVisual? { amounts.filter { $0.key != .rest && $0.value > 0.001 }.max { $0.value < $1.value }?.key }
}

/// The springs behind a bot's motion, stepped by the view's clock: one amount per symbol, the
/// eyes, the squash, the dim and the halo, each picking up from wherever it is when the target
/// changes. Blinks run on a deterministic schedule seeded per bot; the finish spin is an orbit
/// of the eyes. A reference type held by the view; the drawing reads a `BotMotionFrame`.
public final class BotMotionModel {
    /// The reel's tempo (decision 2): a change settles in about a third of a second.
    static let symbolOmega = 14.0, symbolZeta = 0.9
    public private(set) var amounts: [BotVisual: BotSpring] = [:]
    var eyeOpen = BotSpring(1, omega: 26, zeta: 0.9)
    var eyeX = BotSpring(0, omega: 12, zeta: 0.9)
    var eyeY = BotSpring(0, omega: 12, zeta: 0.9)
    var eyeOpacity = BotSpring(1, omega: 10, zeta: 0.9)
    var sx = BotSpring(1, omega: 8, zeta: 0.72)
    var sy = BotSpring(1, omega: 8, zeta: 0.72)
    var dim = BotSpring(0, omega: 6, zeta: 0.9)
    var halo = BotSpring(0, omega: 9, zeta: 1.0)
    var arcs = BotSpring(0, omega: 8, zeta: 0.9)
    public let seed: Int
    private var lastTime: Double?
    private var lastVisual: BotVisual = .rest
    private var lastKick: Double = -10
    private var loopStart: Double?
    private var orbitStart: Double?
    /// A tap's reaction under way, and whether its bounce has been given (on the first frame
    /// past its start, so the springs carry it).
    private var reactStart: Double?
    private var reactKicked = false
    /// A blink on its own (`blink(at:)`): the tap's blink without its squash.
    private var blinkStart: Double?
    /// The targets last advanced toward, for `isSettled`.
    private var lastTargets = BotMotionTargets()
    /// Once a symbol that hides the eyes is the target, the eyes only go down until a symbol
    /// that keeps them is the target and the hiding ones are mostly gone: no peeking between
    /// two hiding symbols, no flash on the way into one (item 5).
    private var eyesHeldDown = false
    private var lastEyeOpacity = 1.0
    /// No symbol for a frame or two: a change of targets must last `minimumHold` before the bot
    /// takes it up (a tool completing and the next one starting 0.2 s later kept the toolbox
    /// instead of popping to the orb and back), unless the new symbol is `urgent`, which shows
    /// at once. `shown` is what the springs head for; `pending` is the change waiting its turn.
    public static let minimumHold = 0.3
    private var shown: BotMotionTargets?
    private var pending: (targets: BotMotionTargets, since: Double)?

    /// The targets to head for at `t`, given what the state asks for.
    private func held(_ targets: BotMotionTargets, at t: Double) -> BotMotionTargets {
        guard let s = shown else { shown = targets; return targets }
        if targets == s { pending = nil; return s }
        if targets.visual.urgent, targets.visual != s.visual { shown = targets; pending = nil; return targets }
        if let p = pending, p.targets == targets {
            if t - p.since >= Self.minimumHold { shown = targets; pending = nil; return targets }
            return s
        }
        pending = (targets, t)
        return s
    }
    /// What the bot is heading for now (the held targets), for tests and the view's wake-ups.
    public var shownTargets: BotMotionTargets { shown ?? lastTargets }
    /// The time of the last `advance`, for tests.
    public var lastAdvanceTime: Double { lastTime ?? 0 }

    public init(seed: Int) {
        self.seed = seed
        for v in BotVisual.allCases { amounts[v] = BotSpring(v == .rest ? 1 : 0, omega: Self.symbolOmega, zeta: Self.symbolZeta) }
    }

    /// Blinks: every 4.3 s or so, offset per bot so a page never blinks in unison, 0.15 s long,
    /// every third one a double. Deterministic in `t`, so stills and tests repeat.
    public static let blinkPeriod = 4.3, blinkLength = 0.15
    public static func blink(at t: Double, seed: Int) -> Double {
        let tt = t + Double(seed % 17) * 0.37
        let phase = tt.truncatingRemainder(dividingBy: blinkPeriod)
        if phase < blinkLength { return sin(phase / blinkLength * .pi) }
        if Int(tt / blinkPeriod) % 3 == 0, phase > blinkLength + 0.09, phase < 2 * blinkLength + 0.09 { return sin((phase - blinkLength - 0.09) / blinkLength * .pi) }
        return 0
    }
    /// When the next blink starts after `t`: one wakeup per blink instead of a poll.
    public static func nextBlink(after t: Double, seed: Int) -> Double {
        let offset = Double(seed % 17) * 0.37
        let tt = t + offset
        let phase = tt.truncatingRemainder(dividingBy: blinkPeriod)
        let n = Int(tt / blinkPeriod)
        // The double blink of a third cycle still to come in this period.
        if n % 3 == 0, phase < blinkLength + 0.09 { return t + (blinkLength + 0.09 - phase) }
        return t + (blinkPeriod - phase)
    }

    /// Starts the finish spin (the eyes orbit the body once, 0.68 s).
    public static let orbitLength = 0.68
    public func spin(at t: Double) { orbitStart = t }

    /// A tap's reaction (the look): a blink and a small bounce, then rest.
    /// One set of numbers: how long it holds the clock, the blink's length, and the squash given
    /// to the body's springs (they bounce it back over the next few tenths).
    public enum Reaction {
        public static let length = 0.42
        public static let blinkLength = 0.16
        public static let squash = 1.1
        /// `-vory-tap-reaction-off` leaves a tapped
        /// face still (the tap still does what it did).
        public static let off = ProcessInfo.processInfo.arguments.contains("-vory-tap-reaction-off")
        /// Whether a tap plays at all: not off, and the bots not still (Settings › Bots › Style ›
        /// Still, or their motion turned off). Reduce Motion is the view's: it snaps the face.
        /// Never on the Mac (Matt, 2026-10-13: "You can keep Mac as is"): there a click on a face
        /// opens what it opens and the face stays as it was. (Its arrival never landed, held the
        /// bot's other faces back, and the click swapped a still face for a paused live one, a
        /// darker flash with no reaction.)
        @MainActor public static var plays: Bool {
            #if os(macOS)
            false
            #else
            !off && BotFace.motionScale > 0 && BotAmbient.shared.enabled
            #endif
        }
    }
    /// Starts the reaction to a tap at `t`.
    public func react(at t: Double) { reactStart = t; reactKicked = false }
    /// A blink on its own at `t`, with nothing else moving: the tap's blink (`Reaction.blinkLength`), no squash. The
    /// faces blink so as a foldable phone opens (Duo stage 4); a bounce on every face at once read as a jolt.
    public func blink(at t: Double) { blinkStart = t }

    /// Advances to `t` (seconds) toward `targets` and returns the frame to draw.
    @discardableResult
    public func advance(to t: Double, targets asked: BotMotionTargets) -> BotMotionFrame {
        // A face's first frame is its settled pose: nothing springs in from a neutral face when a
        // row scrolls into view, so an idle face draws once and its timeline pauses at once
        // (the list fling's main-thread cost on the phone was rows' faces settling, 2026-10-11).
        // A reaction started before the face's first frame (a face mounted for it) plays on.
        if lastTime == nil { let r = reactStart, b = blinkStart; snap(to: asked, at: t); reactStart = r; blinkStart = b }
        let dt = lastTime.map { max(0, t - $0) } ?? 0
        lastTime = t
        let targets = held(asked, at: t)
        lastTargets = targets
        // A tap: the squash once, from the frame its reaction starts on.
        if let r = reactStart, !reactKicked, t >= r { sy.v -= Reaction.squash; sx.v += Reaction.squash / 2; reactKicked = true }
        // A change of symbol: a small squash kick, rate-limited so fast flips never stack (item 15).
        if targets.visual != lastVisual {
            lastVisual = targets.visual
            loopStart = targets.visual.loops ? t : nil
            if t - lastKick > 0.4 { sy.v -= 0.5; sx.v += 0.25; lastKick = t }
        } else if loopStart == nil, targets.loops { loopStart = t }
        for v in BotVisual.allCases { amounts[v]?.step(toward: v == targets.visual ? 1 : 0, dt: dt) }
        let part = BotVisual.allCases.filter { $0 != .rest }.map { amounts[$0]?.x ?? 0 }.max() ?? 0
        // Eyes: the state's own openness, the hidden-with-the-symbol rule, then the blink last
        // (after the springs, so a blink closes fully, item 3).
        eyeOpen.step(toward: targets.eyeOpen, dt: dt)
        eyeX.step(toward: targets.eyeX, dt: dt)
        eyeY.step(toward: targets.eyeY, dt: dt)
        let hidden = targets.visual.hidesEyes
        eyeOpacity.step(toward: hidden ? 0 : 1, dt: dt)
        sx.step(toward: 1, dt: dt); sy.step(toward: 1, dt: dt)
        sy.x = max(0.94, min(1.06, sy.x)); sx.x = max(0.94, min(1.06, sx.x))
        dim.step(toward: targets.dim, dt: dt)
        halo.step(toward: targets.halo, dt: dt)
        arcs.step(toward: targets.arcs, dt: dt)
        var f = BotMotionFrame()
        for v in BotVisual.allCases { f.amounts[v] = amounts[v]?.x ?? 0 }
        var blink = Self.blink(at: t, seed: seed)
        if let r = reactStart {
            let u = t - r
            if u >= Reaction.length { reactStart = nil }
            else if u >= 0, u < Reaction.blinkLength { blink = max(blink, sin(u / Reaction.blinkLength * .pi)) }
        }
        if let b = blinkStart {
            let u = t - b
            if u >= Reaction.blinkLength { blinkStart = nil }
            else if u >= 0 { blink = max(blink, sin(u / Reaction.blinkLength * .pi)) }
        }
        f.eyeOpen = min(eyeOpen.x, 1 - blink * 0.92)
        f.eyeX = eyeX.x; f.eyeY = eyeY.x
        // The eyes go with the symbol that hides them: gone by the time it is a third grown (item 5).
        let hiding = BotVisual.allCases.filter { $0.hidesEyes }.map { amounts[$0]?.x ?? 0 }.max() ?? 0
        if hidden { eyesHeldDown = true } else if hiding < 0.3 { eyesHeldDown = false }
        var opacity = min(eyeOpacity.x, 1 - BotFace.smooth(hiding / 0.35))
        if eyesHeldDown { opacity = min(opacity, lastEyeOpacity) }
        lastEyeOpacity = opacity
        f.eyeOpacity = opacity
        _ = part
        f.sx = sx.x; f.sy = sy.x
        f.dim = dim.x; f.halo = halo.x; f.arcs = arcs.x
        if let o = orbitStart {
            let u = (t - o) / Self.orbitLength
            if u >= 1 { orbitStart = nil } else { f.orbit = BotFace.stroke(max(0, u)) }
        }
        f.loopTime = loopStart.map { t - $0 } ?? 0
        return f
    }

    /// At rest: every spring on its target, no spin, and the state has nothing that loops.
    public var isSettled: Bool { unsettled.isEmpty }
    /// What is still moving (for the tests).
    public var unsettled: [String] {
        var out: [String] = []
        if orbitStart != nil { out.append("orbit") }
        if reactStart != nil { out.append("react") }
        if blinkStart != nil { out.append("blink") }
        if lastTargets.loops { out.append("loop") }
        for v in BotVisual.allCases where !(amounts[v]?.isSettled(at: v == lastTargets.visual ? 1 : 0) ?? true) { out.append(v.rawValue) }
        let hidden = lastTargets.visual.hidesEyes
        let named: [(String, Bool)] = [("eyeOpen", eyeOpen.isSettled(at: lastTargets.eyeOpen)), ("eyeX", eyeX.isSettled(at: lastTargets.eyeX)), ("eyeY", eyeY.isSettled(at: lastTargets.eyeY)),
                                       ("eyeOpacity", eyeOpacity.isSettled(at: hidden ? 0 : 1)), ("sx", sx.isSettled(at: 1)), ("sy", sy.isSettled(at: 1)),
                                       ("dim", dim.isSettled(at: lastTargets.dim)), ("halo", halo.isSettled(at: lastTargets.halo)), ("arcs", arcs.isSettled(at: lastTargets.arcs))]
        for (n, ok) in named where !ok { out.append(n) }
        // A change waiting out the hold keeps the clock running until it is taken up.
        if pending != nil { out.append("hold") }
        return out
    }

    /// Jumps every spring to its target (a held bot, Reduce Motion, a still frame).
    public func snap(to targets: BotMotionTargets, at t: Double) {
        lastTime = t; lastTargets = targets; lastVisual = targets.visual
        shown = targets; pending = nil
        for v in BotVisual.allCases { amounts[v]?.snap(to: v == targets.visual ? 1 : 0) }
        eyeOpen.snap(to: targets.eyeOpen); eyeX.snap(to: targets.eyeX); eyeY.snap(to: targets.eyeY)
        eyeOpacity.snap(to: targets.visual.hidesEyes ? 0 : 1)
        eyesHeldDown = targets.visual.hidesEyes; lastEyeOpacity = eyesHeldDown ? 0 : 1
        sx.snap(to: 1); sy.snap(to: 1); dim.snap(to: targets.dim); halo.snap(to: targets.halo); arcs.snap(to: targets.arcs)
        orbitStart = nil; reactStart = nil; blinkStart = nil; loopStart = targets.loops ? t : nil
    }
}
