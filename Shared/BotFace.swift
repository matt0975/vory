import SwiftUI

/// A bot's look, made in the Creator Studio: a body shape, a pair of eyes and a colour. Drawn the
/// same way in the app, the Live Activity, the notification service and the reply window. The
/// bot itself is the icon: no disc behind it, no circular clip.
public struct BotLookSpec: Hashable, Sendable {
    public var shape: String
    public var eyes: String
    public var hex: String
    /// "flat" (the painted bot) or "glass" (Liquid Glass, like the app icon; beta).
    public var finish: String

    public init(shape: String, eyes: String, hex: String, finish: String = "flat") {
        self.shape = shape
        self.eyes = eyes
        self.hex = hex
        self.finish = finish
    }

    public var isGlass: Bool { finish == "glass" }

    public static let shapes = ["circle", "blob", "square", "pill", "triangle", "hexagon", "cloud", "drop"]
    public static let eyeStyles = ["classic", "tall", "sleepy", "tiny", "round", "wide", "curious", "bold"]
    public static let defaultShape = "blob"
    public static let defaultEyes = "classic"
    /// Vory itself: the glass cloud on the icon, the guide on the first run and in About.
    public static let vory = BotLookSpec(shape: "cloud", eyes: "classic", hex: "#3B7BFF", finish: "glass")

    /// The avatar choice string the app stores: "studio:<shape>:<eyes>" plus ":glass" for the
    /// glass finish. Older values ("initial", "animated:<style>") map onto a shape so nothing
    /// looks broken after the update.
    public static func from(choice raw: String?, hex: String) -> BotLookSpec {
        let parts = (raw ?? "").split(separator: ":").map(String.init)
        if parts.first == "studio", parts.count == 3 || parts.count == 4, shapes.contains(parts[1]), eyeStyles.contains(parts[2]) {
            return BotLookSpec(shape: parts[1], eyes: parts[2], hex: hex, finish: parts.count == 4 && parts[3] == "glass" ? "glass" : "flat")
        }
        if parts.first == "animated", parts.count == 2 {
            let legacy: [String: (String, String)] = ["nimbus": ("cloud", "classic"), "halo": ("circle", "round"), "pip": ("drop", "tiny"),
                                                      "ember": ("triangle", "bold"), "wisp": ("pill", "wide"), "prism": ("hexagon", "curious")]
            if let (s, e) = legacy[parts[1]] { return BotLookSpec(shape: s, eyes: e, hex: hex) }
        }
        return BotLookSpec(shape: defaultShape, eyes: defaultEyes, hex: hex)
    }

    public var choiceString: String { "studio:\(shape):\(eyes)" + (isGlass ? ":glass" : "") }

    public static func name(ofShape s: String) -> String {
        ["circle": "Circle", "blob": "Blob", "square": "Square", "pill": "Pill", "triangle": "Triangle", "hexagon": "Hex", "cloud": "Cloud", "drop": "Drop"][s] ?? s.capitalized
    }
    public static func name(ofEyes e: String) -> String { e.capitalized }
}

/// Procedural drawing of a bot: body path, colour, eyes with blink and glance. Everything is a
/// function of `time`, so a still frame is `time: 0` and the same code animates in a TimelineView.
public enum BotFace {
    /// The body, filling the square with a little breathing room.
    /// `phase`: the blob's outline phase, when the caller tracks it (BotFaceView keeps it
    /// continuous across working and rest); otherwise it creeps with `t` while active.
    public static func bodyPath(_ shape: String, in box: CGRect, time t: Double, active: Bool, morph: Double = 0, target: MorphTarget = .none, phase: Double? = nil) -> Path {
        let blobPhase = phase ?? (active ? t * 0.19 : 0)
        // A state hold: the rest silhouette blended toward the state's, one path on the same view.
        if target != .none, morph > 0.001 { return morphedPath(shape, in: box, target: target, amount: morph, blobPhase: blobPhase) }
        let r = box.insetBy(dx: box.width * 0.04, dy: box.height * 0.04)
        let c = CGPoint(x: r.midX, y: r.midY)
        switch shape {
        case "circle":
            return Path(ellipseIn: r)
        case "square":
            return Path(roundedRect: r, cornerRadius: r.width * 0.28, style: .continuous)
        case "pill":
            let h = r.height * 0.64
            return Path(roundedRect: CGRect(x: r.minX, y: c.y - h / 2, width: r.width, height: h), cornerRadius: h / 2, style: .continuous)
        case "triangle":
            // Inscribed in a circle a triangle sits high and small; centre it lower and larger so
            // the base reaches near the bottom and the eyes have a face to sit in.
            let d = r.width * 1.16
            let box2 = CGRect(x: c.x - d / 2, y: r.minY + r.height * 0.56 - d / 2, width: d, height: d)
            return roundedPolygon(sides: 3, in: box2, rotation: -.pi / 2, corner: r.width * 0.24)
        case "hexagon":
            return roundedPolygon(sides: 6, in: r, rotation: -.pi / 2, corner: r.width * 0.10)
        case "cloud":
            var p = Path()
            let w = r.width, h = r.height
            p.addRoundedRect(in: CGRect(x: r.minX + w * 0.06, y: r.minY + h * 0.45, width: w * 0.88, height: h * 0.42), cornerSize: CGSize(width: h * 0.21, height: h * 0.21))
            p.addEllipse(in: CGRect(x: r.minX + w * 0.16, y: r.minY + h * 0.26, width: w * 0.36, height: w * 0.36))
            p.addEllipse(in: CGRect(x: r.minX + w * 0.38, y: r.minY + h * 0.12, width: w * 0.42, height: w * 0.42))
            p.addEllipse(in: CGRect(x: r.minX + w * 0.58, y: r.minY + h * 0.34, width: w * 0.30, height: w * 0.30))
            return p
        case "drop":
            var p = Path()
            let w = r.width, h = r.height
            let bottom = CGPoint(x: c.x, y: r.maxY)
            let radius = w * 0.40
            let centre = CGPoint(x: c.x, y: r.maxY - radius)
            p.move(to: CGPoint(x: c.x, y: r.minY + h * 0.02))
            p.addCurve(to: CGPoint(x: centre.x + radius, y: centre.y), control1: CGPoint(x: c.x + w * 0.08, y: r.minY + h * 0.30), control2: CGPoint(x: centre.x + radius, y: centre.y - radius * 0.65))
            p.addArc(center: centre, radius: radius, startAngle: .zero, endAngle: .radians(.pi), clockwise: false)
            p.addCurve(to: CGPoint(x: c.x, y: r.minY + h * 0.02), control1: CGPoint(x: centre.x - radius, y: centre.y - radius * 0.65), control2: CGPoint(x: c.x - w * 0.08, y: r.minY + h * 0.30))
            _ = bottom
            p.closeSubpath()
            return p
        default: // blob: a soft, slightly irregular round that slowly morphs while the bot works
            var p = Path()
            let base = min(r.width, r.height) / 2
            // The only shape whose outline moves: a slow creep while working, frozen at rest.
            let n = 96
            for i in 0...n {
                let a = Double(i) / Double(n) * 2 * .pi
                let pt = CGPoint(x: c.x + cos(a) * base * blobWobble(a, phase: blobPhase), y: c.y + sin(a) * base * blobWobble(a, phase: blobPhase))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            return p
        }
    }

    /// The blob's radius at angle `a` as a factor of its base radius.
    static func blobWobble(_ a: Double, phase: Double) -> CGFloat {
        CGFloat(1 + 0.055 * sin(3 * a + 0.9 + phase) + 0.035 * sin(5 * a - 0.4 - phase * 0.7))
    }

    static func roundedPolygon(sides: Int, in r: CGRect, rotation: Double, corner: CGFloat) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) / 2
        let pts: [CGPoint] = (0..<sides).map { i in
            let a = rotation + Double(i) / Double(sides) * 2 * .pi
            return CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius)
        }
        var p = Path()
        for i in 0..<sides {
            let prev = pts[(i + sides - 1) % sides], cur = pts[i], next = pts[(i + 1) % sides]
            func towards(_ a: CGPoint, _ b: CGPoint, _ d: CGFloat) -> CGPoint {
                let dx = b.x - a.x, dy = b.y - a.y, len = max(1, (dx * dx + dy * dy).squareRoot())
                return CGPoint(x: a.x + dx / len * d, y: a.y + dy / len * d)
            }
            let inPt = towards(cur, prev, corner), outPt = towards(cur, next, corner)
            if i == 0 { p.move(to: inPt) } else { p.addLine(to: inPt) }
            p.addQuadCurve(to: outPt, control: cur)
        }
        p.closeSubpath()
        return p
    }

    /// Where the eyes sit for a shape (fraction of the square), and how far apart.
    static func eyeAnchor(_ shape: String) -> (y: CGFloat, spread: CGFloat) {
        switch shape {
        case "triangle": return (0.64, 0.10)
        case "drop": return (0.62, 0.11)
        case "cloud": return (0.58, 0.11)
        case "pill": return (0.50, 0.13)
        default: return (0.47, 0.13)
        }
    }

    /// Blink (0 open … 1 shut) and glance (−1 … 1) as functions of time, offset per bot so a
    /// list of bots does not blink in unison. `blinkPeriod` shortens while thinking or asking;
    /// `rare` adds the once-in-a-while slow blink or moment's squint that makes an idle bot alive.
    static func liveliness(time t: Double, seed: Int, blinkPeriod: Double = 4.3, blinkLength: Double = 0.15, doubleBlinks: Bool = true, glancePeriod: Double = 7.0, rare: Bool = true) -> (blink: Double, glance: Double, breath: Double) {
        guard t > 0 else { return (0, 0, 0) }
        let offset = Double(seed % 17) * 0.37
        let tt = t + offset
        // A blink every ~4.3 s, 150 ms long, every third one a double blink.
        let phase = tt.truncatingRemainder(dividingBy: blinkPeriod)
        var blink = 0.0
        if phase < blinkLength { blink = sin(phase / blinkLength * .pi) }
        else if doubleBlinks, Int(tt / blinkPeriod) % 3 == 0, phase > blinkLength + 0.09, phase < 2 * blinkLength + 0.09 { blink = sin((phase - blinkLength - 0.09) / blinkLength * .pi) }
        // Once in ~25 s something slower: a long blink (220 ms) or a moment's squint. Eyes only.
        if rare {
            let rp = (tt + Double(seed % 11) * 1.7).truncatingRemainder(dividingBy: 25)
            if rp > 9.0, rp < 9.22 { blink = max(blink, sin((rp - 9.0) / 0.22 * .pi)) }
            else if rp > 17.0, rp < 17.3 { blink = max(blink, 0.3 * sin((rp - 17.0) / 0.3 * .pi)) }
        }
        // A glance to one side every ~7 s, held for a moment, then back.
        let gp = (tt * 0.9).truncatingRemainder(dividingBy: glancePeriod)
        var glance = 0.0
        if gp > 1.2, gp < 2.6 {
            let u = (gp - 1.2) / 1.4
            let ease = u < 0.2 ? u / 0.2 : u > 0.8 ? (1 - u) / 0.2 : 1
            glance = ease * (Int(tt / glancePeriod) % 2 == 0 ? 1 : -1)
        }
        let breath = 0.5 + 0.5 * sin(tt * 2 * .pi / 2.6)
        return (blink, glance, breath)
    }

    /// What a bot is doing beyond idle. Each state is a pose the eyes and body settle into;
    /// `working` is the five-second routine blocks, the rest are one-shots that hold.
    public enum State: Equatable, Sendable { case idle, working, thinking, usingTool, streaming, awaitingApproval, error, reconnecting, guide }

    /// One frame's pose: the body's transforms (small, in place, never scaled) plus what the
    /// eyes and the glass rim are asked to do on top of their own life.
    public struct Motion: Equatable, Sendable {
        public var yaw: Double = 0        // radians about the vertical axis (a 3D turn, like a coin)
        public var roll: Double = 0       // radians about the centre, in the plane
        public var dx: CGFloat = 0        // horizontal offset as a fraction of the size
        public var dy: CGFloat = 0        // vertical offset as a fraction of the size (positive = down)
        /// Cap on how open the eyes are (1 = free; 0.42 is the thinking squint).
        public var eyeOpen: Double = 1
        /// Extra glance, −1…1 on each axis, on top of the eyes' own wandering (scaled like `gaze`).
        public var eyeX: Double = 0
        public var eyeY: Double = 0
        /// The eyes stop wandering on their own (they still blink): the asking pose.
        public var freezeGlance = false
        /// Blink cadence in seconds: 4.3 at rest, 2.8 while thinking or asking; and how long a
        /// blink takes (0.15; thinking's is a slower 0.22).
        public var blinkPeriod: Double = 4.3
        public var blinkLength: Double = 0.15
        /// The blob's outline phase, kept continuous by the view; nil = derive from the clock.
        public var blobPhase: Double? = nil
        /// Light travelling the rim: strength 0…1 centred at `sheenAngle` degrees (0 = right,
        /// clockwise; −130 is the lit top-left corner).
        public var sheen: Double = 0
        public var sheenAngle: Double = -130
        /// The silhouette a state holds and how far into it (0 rest … 1 held), lerped inside one
        /// path on the same view — never a second view, so the glass never rebuilds.
        public var morph: Double = 0
        public var morphTarget: MorphTarget = .none
        /// The eyes fade out for the exclamation (0 … 1).
        public var eyeOpacity: Double = 1
        /// The crown light and rim die away (0 … 1): the error pose.
        public var dim: Double = 0
        public static let still = Motion()
        /// The same pose with the body's transforms at rest and no light on the rim (Reduce
        /// Motion, painted renders): the eyes and the held silhouette keep theirs.
        public var bodyStill: Motion { var m = transformsStill; m.sheen = 0; return m }
        /// The transforms the view applies itself (yaw, roll, offsets) zeroed, for the painted
        /// twin drawn inside that view — everything else, the sheen included, stays.
        public var transformsStill: Motion { var m = self; m.yaw = 0; m.roll = 0; m.dx = 0; m.dy = 0; return m }
    }

    /// The silhouettes a state can hold: the ask's exclamation, thinking's heavier pebble, a
    /// tool's stem out of the top. Idle, working and the guide never morph.
    public enum MorphTarget: String, Equatable, Sendable { case none, exclamation, pebble, stem }

    public static func morphTarget(for state: State) -> MorphTarget {
        switch state {
        case .awaitingApproval: return .exclamation
        case .thinking: return .pebble
        case .usingTool: return .stem
        default: return .none
        }
    }

    /// Whether a colour is light enough (a white or cream bot) to vanish on a light background.
    public static func isLight(_ hex: String) -> Bool {
        var h = hex.trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return false }
        let r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.82
    }
    /// A near-black bot: on a dark page it needs a light hairline, as a white one needs a grey
    /// one on white.
    public static func isDark(_ hex: String) -> Bool {
        var h = hex.trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return false }
        let r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.16
    }

    static func smooth(_ x: Double) -> Double { let u = min(1, max(0, x)); return u * u * (3 - 2 * u) }
    /// Slow start, quick middle, slow stop — a whole turn in one stroke.
    static func stroke(_ x: Double) -> Double { let u = min(1, max(0, x)); return u * u * u * (u * (u * 6 - 15) + 10) }

    /// The pose at time `t` for a bot in `state`. `since`: seconds since the state began (the
    /// one-shots at a state's start count from here). `finishedAt` / `tappedAt`: the reply just
    /// ended / the bot was just tapped — a full turn / a small one, over anything else. `group`:
    /// in a group only one bot moves its body per block, in turn.
    /// Bots share the clock but not the phase: `seed` (shape, eyes and name) offsets each one's
    /// blocks and picks its routine, so a page of bots never moves in unison.
    /// Motion style (Settings › Bots): lively 1, calm 0.5, still 0. The app sets it from the
    /// stored choice; widgets and the watch leave it at 1.
    nonisolated(unsafe) public static var motionScale: Double = 1

    public static func motion(time t: Double, seed: Int, spec: BotLookSpec, state: State, since: Double = 0, finishedAt: Double? = nil, tappedAt: Double? = nil, group: (index: Int, count: Int)? = nil) -> Motion {
        let sign: Double = seed % 2 == 0 ? 1 : -1
        // Per-shape flavour: the cloud keeps its flat bottom planted, the pill's wide face makes
        // any roll read large, the drop's point should not stab.
        let rollAmp: Double = spec.shape == "cloud" ? 0.75 : 1
        let rollCap: Double = spec.shape == "pill" ? 0.052 : 1
        func roll(_ r: Double) -> Double { max(-rollCap, min(rollCap, r * rollAmp)) }
        var m = Motion()

        // The finish: one full turn, a blink as the face goes edge-on, then a glance down at the
        // new bubble. A tap: a small turn and back with a blink and a tick of light on the rim —
        // pressing a physical chip, not a button. Both play on top of whatever the state holds:
        // a "!" spins as a "!".
        var finishing: Double? = nil, tapping: Double? = nil
        if let f = finishedAt, t - f >= 0, t - f < 1.75 { finishing = t - f }
        else if let tp = tappedAt, t - tp >= 0, t - tp < 0.55 { tapping = (t - tp) / 0.55 }
        defer {
            if let u = finishing {
                if u < 1.15 {
                    let k = stroke(u / 1.15)
                    m.yaw = k * 2 * .pi
                    m.sheen = 0.7 * sin(k * .pi); m.sheenAngle = -130 + k * 360
                    if abs(u - 0.575) < 0.08 { m.eyeOpen = min(m.eyeOpen, 0.1) }
                } else if !m.freezeGlance {
                    m.eyeY += 0.5 * sin((u - 1.15) / 0.6 * .pi)
                }
            } else if let u = tapping {
                m.yaw = 0.314 * (u < 0.5 ? stroke(u * 2) : stroke((1 - u) * 2))
                m.sheen = 0.6 * sin(u * .pi); m.sheenAngle = -130 + 90 * u
                if u > 0.42, u < 0.68 { m.eyeOpen = min(m.eyeOpen, 0.12) }
            }
        }
        if finishing != nil || tapping != nil, state == .working { return m }

        switch state {
        case .idle:
            break
        case .guide:
            // Vory on a guided screen — not a working bot. In every eight seconds: one glance
            // down toward the speech bubble, one light across the rim, one tiny nod. Idle eyes
            // otherwise; the flat bottom never leaves the shelf.
            let l = (t + Double(seed % 7)).truncatingRemainder(dividingBy: 8)
            if l > 1.0, l < 2.6 { m.eyeY = 0.7 * (l < 1.3 ? smooth((l - 1.0) / 0.3) : l > 2.3 ? 1 - smooth((l - 2.3) / 0.3) : 1) }
            if l > 3.4, l < 4.3 { let u = (l - 3.4) / 0.9; m.sheen = 0.7 * sin(u * .pi); m.sheenAngle = -130 + u * 140 }
            if l > 5.6, l < 6.2 { m.dy = 0.015 * CGFloat(sin((l - 5.6) / 0.6 * .pi)) }
        case .streaming:
            // Tokens arriving: a held squint and light going round the rim every 2.2 s. The
            // shape does not change.
            m.eyeOpen = 0.55
            let u = t.truncatingRemainder(dividingBy: 2.2) / 2.2
            m.sheen = 0.7 * sin(u * .pi); m.sheenAngle = -130 + u * 160
        case .thinking:
            // The body settles into a shorter, heavier pebble (same bounds, the mass low) and
            // holds; eyes narrow, a hair of roll, blinks come sooner. No turn: that is for the finish.
            m.morphTarget = .pebble; m.morph = smooth(since / 0.55)
            m.eyeOpen = 0.42
            m.roll = roll(0.026 * sign) * smooth(since / 0.3)
            m.blinkPeriod = 2.8; m.blinkLength = 0.22
        case .usingTool:
            // A stem grows out of the top (a key, a lollipop) and holds; the eyes look down
            // toward where the tool is and stay there; one lean that way as it starts.
            m.morphTarget = .stem; m.morph = smooth(since / 0.6)
            m.eyeX = 0.8; m.eyeY = 0.6; m.freezeGlance = true
            if spec.eyes == "classic" || spec.eyes == "bold" { m.eyeOpen = 0.92 }
            if since < 0.9 {
                let e = since < 0.25 ? smooth(since / 0.25) : since < 0.65 ? 1 : 1 - smooth((since - 0.65) / 0.25)
                m.roll = roll(0.061 * e)
                m.dx = 0.012 * CGFloat(e)
            }
        case .awaitingApproval:
            // The ask: the body becomes a bold rounded exclamation and holds, leaning 8°, the
            // eyes gone with the morph; every 2.8 s a small nudge toward the person. "Well?"
            m.morphTarget = .exclamation; m.morph = smooth(since / 0.6)
            m.eyeOpacity = 1 - m.morph
            m.freezeGlance = true
            m.roll = 0.14 * sign * rollAmp * smooth(since / 0.5)
            let l = (t + Double(seed % 17) * 0.37).truncatingRemainder(dividingBy: 2.8)
            if l > 0.15, l < 0.6 { m.dx = 0.02 * CGFloat(sin((l - 0.15) / 0.45 * .pi)) * CGFloat(sign) }
        case .error:
            // Broken, not asleep: the eyes drop and shut to dashes and stay shut, the body rolls
            // back 4°, the light on the rim dies. No turn.
            m.eyeOpen = 0.08; m.eyeY = 1.0; m.freezeGlance = true
            m.roll = roll(-0.07) * smooth(since / 0.5)
            m.dim = smooth(since / 0.6)
        case .reconnecting:
            // A metronome the eye can see at any size: the eyes swing a side every 1.1 s. Body still.
            m.eyeX = 1.8 * sin(t * 2 * .pi / 2.2) * smooth(since / 0.4); m.freezeGlance = true
        case .working:
            // Blocks of 3.2 s: about a second of one routine, two of rest — lively, not frantic.
            // In a group the clock is shared and the bots take turns; alone, each bot's blocks
            // are offset by its seed.
            let block = 3.2
            let tt = group == nil ? t + Double(seed % 47) * 0.31 : t
            let index = Int(tt / block)
            let u = tt.truncatingRemainder(dividingBy: block)
            if let g = group, g.count > 1, index % g.count != g.index { break }
            // Swift's % keeps the sign: fold to 0…9 so a negative seed cannot pin one routine.
            // The order interleaves the eyes-only and rim-only beats (5 look-up, 6 squint, 8 sheen)
            // with body ones, so the body is never still for two blocks running.
            let order = [0, 5, 1, 8, 2, 6, 3, 7, 4, 9]
            var kind = order[(((index &+ seed) % 10) + 10) % 10]
            if spec.shape == "triangle", kind == 3 { kind = 4 }   // the triangle leans rather than nods
            switch kind {
            case 0: // the full turn on the spot, the light riding the rim with it
                guard u < 1.15 else { break }
                let k = stroke(u / 1.15)
                m.yaw = k * 2 * .pi
                m.sheen = 0.7 * sin(k * .pi); m.sheenAngle = -130 + k * 360
            case 1: // a glance to one side and back: a partial turn, the eyes 60 ms ahead of it
                guard u < 1.0 else { break }
                m.yaw = 0.45 * sin(u * .pi) * sign
                m.eyeX = 0.9 * sin(min(1, u + 0.06) * .pi) * sign
            case 2: // a small tilt of the head, once each way
                guard u < 1.1 else { break }
                m.roll = roll(0.07 * sin(u / 1.1 * 2 * .pi) * (1 - smooth((u - 0.7) / 0.4)))
            case 3: // a nod: two tiny dips (a move, not a squash)
                guard u < 0.8 else { break }
                m.dy = (spec.shape == "drop" ? 0.015 : 0.02) * CGFloat(abs(sin(u / 0.8 * 2 * .pi)))
            case 4: // a lean: a few degrees and a point sideways, then back
                guard u < 0.9 else { break }
                let e = sin(u / 0.9 * .pi)
                m.roll = roll(0.061 * e * sign)
                m.dx = 0.012 * CGFloat(e) * CGFloat(sign)
            case 5: // a look up and back, eyes only
                guard u < 0.9 else { break }
                m.eyeY = -0.7 * sin(u / 0.9 * .pi)
            case 6: // a squint and settle: narrow, hold, open most of the way
                if u < 0.18 { m.eyeOpen = 1 - 0.58 * smooth(u / 0.18) }
                else if u < 0.58 { m.eyeOpen = 0.42 }
                else if u < 0.8 { m.eyeOpen = 0.42 + 0.5 * smooth((u - 0.58) / 0.22) }
            case 7: // a scan: the eyes sweep one way then the other, the body barely following
                guard u < 1.2 else { break }
                let e = sin(u / 1.2 * 2 * .pi) * sign
                m.eyeX = e
                m.yaw = 0.14 * e
            case 8: // light across the rim, nothing else
                guard u < 0.9 else { break }
                let k = u / 0.9
                m.sheen = 0.7 * sin(k * .pi); m.sheenAngle = -130 + k * 140
            default: // a half turn: round to the other side, a blink there, then round again
                if u < 0.7 {
                    let k = stroke(u / 0.7)
                    m.yaw = k * .pi; m.sheen = 0.6 * sin(k * .pi); m.sheenAngle = -130 + k * 180
                } else if u < 1.25 {
                    m.yaw = .pi
                    if u > 0.85, u < 1.0 { m.eyeOpen = 0.1 }
                } else if u < 1.95 {
                    let k = stroke((u - 1.25) / 0.7)
                    m.yaw = .pi + k * .pi; m.sheen = 0.6 * sin(k * .pi); m.sheenAngle = 50 + k * 180
                }
            }
        }
        // The style scales the turns, leans and glances; the shapes a state takes (the squint,
        // the stem, the "!") and the blinks stay, so a still bot still says what it is doing.
        let scale = motionScale
        if scale != 1 { m.yaw *= scale; m.roll *= scale; m.dx *= CGFloat(scale); m.dy *= CGFloat(scale); m.eyeX *= scale; m.eyeY *= scale; m.sheen *= scale }
        return m
    }

    /// A still pose for the widgets, which cannot run a timeline: the squint of a working bot,
    /// the held lean of one asking, the lowered eyes of an error.
    public static func widgetPose(phase: String, attention: Bool) -> Motion {
        var m = Motion()
        if attention { m.morphTarget = .exclamation; m.morph = 1; m.eyeOpacity = 0; m.roll = 0.14; return m }
        switch phase {
        case "thinking", "working": m.morphTarget = .pebble; m.morph = 1; m.eyeOpen = 0.42
        case "streaming": m.eyeOpen = 0.55
        case "tool": m.morphTarget = .stem; m.morph = 1; m.eyeX = 0.8; m.eyeY = 0.6
        case "error", "failed": m.eyeOpen = 0.08; m.eyeY = 1.0; m.roll = -0.07; m.dim = 1
        default: break
        }
        return m
    }

    // MARK: Morph — a state's silhouette as one continuous path on the same view

    nonisolated(unsafe) private static var ringCache: [String: [([CGPoint], [CGPoint])]] = [:]
    private static let ringLock = NSLock()

    /// The rest silhouette blended `amount` of the way to `target`. Both are rings of points,
    /// paired point for point and lerped, so the result is always one path (two subpaths for the
    /// exclamation) that only changes shape — the plate is never swapped for another view.
    static func morphedPath(_ shape: String, in box: CGRect, target: MorphTarget, amount: Double, blobPhase: Double = 0) -> Path {
        // Rings are cached relative to the square's origin, per shape, size and target. The
        // blob's rest ring is not cached: its outline is wherever its creep has taken it, and
        // the morph must start and end exactly there.
        let key = "\(shape)|\(Int(box.width.rounded()))|\(Int(box.height.rounded()))|\(target.rawValue)"
        let origin = CGRect(origin: .zero, size: box.size)
        ringLock.lock(); var pairs = ringCache[key]; ringLock.unlock()
        if pairs == nil {
            let built = buildMorph(shape, in: origin, target: target)
            ringLock.lock(); ringCache[key] = built; ringLock.unlock()
            pairs = built
        }
        var rings = pairs ?? []
        if shape == "blob", !rings.isEmpty {
            let live = blobRing(in: origin, phase: blobPhase)
            if target == .exclamation, rings.count == 2 {
                let split = origin.minY + origin.height * 0.66, n = rings[0].0.count
                rings[0].0 = resample(clip(live, y: split, keepAbove: true), steps: n)
                rings[1].0 = resample(clip(live, y: split, keepAbove: false), steps: n)
            } else {
                rings[0].0 = live
            }
        }
        let k = CGFloat(min(1, max(0, amount)))
        var p = Path()
        for (a, b) in rings {
            for i in a.indices {
                let pt = CGPoint(x: box.minX + a[i].x + (b[i].x - a[i].x) * k, y: box.minY + a[i].y + (b[i].y - a[i].y) * k)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        }
        return p
    }

    private static func buildMorph(_ shape: String, in box: CGRect, target: MorphTarget) -> [([CGPoint], [CGPoint])] {
        let rest = bodyPath(shape, in: box, time: 0, active: false, phase: 0)
        let bounds = rest.boundingRect
        let restRing = shape == "blob" ? blobRing(in: box, phase: 0) : radialRing(rest, box: box)
        switch target {
        case .pebble:
            return [(restRing, radialRing(pebblePath(in: bounds), box: box))]
        case .stem:
            return [(restRing, radialRing(stemmedPath(rest, in: box), box: box))]
        case .exclamation:
            // The rest outline split at two thirds: the upper part becomes the stem, the lower
            // the dot. Overlapping along the split they fill as the whole; apart they read "!".
            let split = bounds.minY + bounds.height * 0.66
            let n = restRing.count
            let top = resample(clip(restRing, y: split, keepAbove: true), steps: n)
            let bottom = resample(clip(restRing, y: split, keepAbove: false), steps: n)
            // A short body (the pill) gets a taller "!" than itself, so the dot clears the stem.
            var mark = bounds
            if mark.height < box.height * 0.72 {
                let h = box.height * 0.72
                mark = CGRect(x: mark.minX, y: min(max(box.minY, mark.midY - h / 2), box.maxY - h), width: mark.width, height: h)
            }
            let (stem, dot) = exclamationRects(in: mark)
            let stemRing = resample(radialRing(Path(roundedRect: stem, cornerRadius: stem.width / 2), box: stem), steps: n)
            let dotRing = resample(radialRing(Path(ellipseIn: dot), box: dot), steps: n)
            return [(top, stemRing), (bottom, dotRing)]
        case .none:
            return [(restRing, restRing)]
        }
    }

    /// The blob's outline as a ring, straight from its formula (no ray marching), at `phase`.
    static func blobRing(in box: CGRect, phase: Double, steps: Int = 144) -> [CGPoint] {
        let r = box.insetBy(dx: box.width * 0.04, dy: box.height * 0.04)
        let c = CGPoint(x: r.midX, y: r.midY)
        let base = min(r.width, r.height) / 2
        return (0..<steps).map { i in
            let a = Double(i) / Double(steps) * 2 * .pi - .pi / 2
            let w = blobWobble(a, phase: phase)
            return CGPoint(x: c.x + CGFloat(cos(a)) * base * w, y: c.y + CGFloat(sin(a)) * base * w)
        }
    }

    /// The outline as points on rays from the square's centre (clockwise from the top). Every
    /// rest shape, the pebble and the stemmed body are star-shaped from there, so each ray
    /// meets the outline once: march out for the last inside sample, then bisect.
    static func radialRing(_ path: Path, box: CGRect, steps: Int = 144) -> [CGPoint] {
        let c = CGPoint(x: box.midX, y: box.midY)
        let reach = hypot(box.width, box.height) / 2
        let march = 48
        return (0..<steps).map { i in
            let a = Double(i) / Double(steps) * 2 * .pi - .pi / 2
            let dx = CGFloat(cos(a)), dy = CGFloat(sin(a))
            func inside(_ r: CGFloat) -> Bool { path.contains(CGPoint(x: c.x + dx * r, y: c.y + dy * r)) }
            var lastIn: CGFloat = 0
            for k in 1...march { let r = reach * CGFloat(k) / CGFloat(march); if inside(r) { lastIn = r } }
            var lo = lastIn, hi = min(reach, lastIn + reach / CGFloat(march))
            for _ in 0..<8 { let mid = (lo + hi) / 2; if inside(mid) { lo = mid } else { hi = mid } }
            return CGPoint(x: c.x + dx * lo, y: c.y + dy * lo)
        }
    }

    /// The polygon on one side of a horizontal line (Sutherland–Hodgman against a half-plane).
    private static func clip(_ poly: [CGPoint], y: CGFloat, keepAbove: Bool) -> [CGPoint] {
        var out: [CGPoint] = []
        func inside(_ p: CGPoint) -> Bool { keepAbove ? p.y <= y : p.y >= y }
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let ia = inside(a), ib = inside(b)
            if ia { out.append(a) }
            if ia != ib, b.y != a.y { out.append(CGPoint(x: a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y), y: y)) }
        }
        return out
    }

    /// `steps` points at even spacing along the polygon, starting from the point most directly
    /// above its centroid, so two rings pair up top to top and never twist while they blend.
    private static func resample(_ poly: [CGPoint], steps: Int) -> [CGPoint] {
        guard poly.count >= 3 else { return Array(repeating: poly.first ?? .zero, count: steps) }
        var lengths: [CGFloat] = [0]
        for i in poly.indices { let a = poly[i], b = poly[(i + 1) % poly.count]; lengths.append(lengths[lengths.count - 1] + hypot(b.x - a.x, b.y - a.y)) }
        let total = max(lengths[lengths.count - 1], 0.001)
        var out: [CGPoint] = []
        var seg = 0
        for k in 0..<steps {
            let d = total * CGFloat(k) / CGFloat(steps)
            while seg < poly.count - 1, lengths[seg + 1] < d { seg += 1 }
            let a = poly[seg], b = poly[(seg + 1) % poly.count]
            let u = (d - lengths[seg]) / max(lengths[seg + 1] - lengths[seg], 0.0001)
            out.append(CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u))
        }
        let cx = out.reduce(0) { $0 + $1.x } / CGFloat(out.count), cy = out.reduce(0) { $0 + $1.y } / CGFloat(out.count)
        var best = 0, bestAngle = CGFloat.greatestFiniteMagnitude
        for (i, p) in out.enumerated() { let ang = abs(atan2(p.x - cx, -(p.y - cy))); if ang < bestAngle { bestAngle = ang; best = i } }
        return Array(out[best...] + out[..<best])
    }

    /// Thinking's hold: a shorter, heavier pebble in the same bounds — the mass sits in the lower
    /// half, the underside flatter than the crown. Not a smaller body: a different one.
    /// `box` is the rest shape's own bounds: the pebble keeps that width and base, and its crown
    /// comes down to a quarter of the way from the top.
    static func pebblePath(in box: CGRect) -> Path {
        let ryBottom = box.height * 0.30, ryTop = box.height * 0.44
        let c = CGPoint(x: box.midX, y: box.maxY - ryBottom)
        let rx = box.width * 0.49
        var p = Path()
        let n = 96
        for i in 0...n {
            let a = Double(i) / Double(n) * 2 * .pi - .pi / 2
            let co = cos(a), si = sin(a)
            let e = si > 0 ? 2.0 / 2.8 : 2.0 / 2.15
            let x = c.x + rx * CGFloat(co < 0 ? -pow(-co, e) : pow(co, e))
            let y = c.y + (si > 0 ? ryBottom : ryTop) * CGFloat(si < 0 ? -pow(-si, e) : pow(si, e))
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.closeSubpath()
        return p
    }

    /// Using a tool: the body keeps its base and lets its crown down a fifth, and a rounded stem
    /// rises from the top to just under the square's edge — a key, a lollipop. One path.
    static func stemmedPath(_ rest: Path, in box: CGRect) -> Path {
        let b = rest.boundingRect
        // The crown comes down a seventh (the base stays put) to make room for the stem.
        let lowered = rest.applying(CGAffineTransform(translationX: 0, y: b.maxY).scaledBy(x: 1, y: 0.86).translatedBy(x: 0, y: -b.maxY))
        let top = lowered.boundingRect.minY
        let w = box.width * 0.15
        let stemTop = box.minY + box.height * 0.03
        var p = lowered
        p.addPath(Path(roundedRect: CGRect(x: box.midX - w / 2, y: stemTop, width: w, height: max(w, top + box.height * 0.14 - stemTop)), cornerRadius: w / 2))
        return p
    }

    /// The ask: a thick rounded stem and, apart from it, a dot — inside the same square.
    /// `box` is the rest shape's own bounds, so the "!" keeps the bot's footprint: as tall as the
    /// body was, the dot on its base.
    static func exclamationRects(in box: CGRect) -> (stem: CGRect, dot: CGRect) {
        let stem = CGRect(x: box.midX - box.width * 0.12, y: box.minY + box.height * 0.05, width: box.width * 0.24, height: box.height * 0.52)
        let d = min(box.width * 0.24, box.height * 0.26)
        let dot = CGRect(x: box.midX - d / 2, y: box.maxY - d, width: d, height: d)
        return (stem, dot)
    }

    /// The body inset by `d` for a rim: each separate piece of the path (the "!"'s stem and
    /// dot) shrinks toward its own centre, by `d` on every side; pieces that overlap (the
    /// cloud's bumps) shrink together so no inner edge appears.
    static func rimInner(_ body: Path, inset d: CGFloat) -> Path {
        var pieces: [Path] = []
        var current = Path()
        body.cgPath.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                if !current.isEmpty { pieces.append(current) }
                current = Path(); current.move(to: e.points[0])
            case .addLineToPoint: current.addLine(to: e.points[0])
            case .addQuadCurveToPoint: current.addQuadCurve(to: e.points[1], control: e.points[0])
            case .addCurveToPoint: current.addCurve(to: e.points[2], control1: e.points[0], control2: e.points[1])
            case .closeSubpath: current.closeSubpath()
            @unknown default: break
            }
        }
        if !current.isEmpty { pieces.append(current) }
        var groups: [(box: CGRect, path: Path)] = []
        // Pieces that overlap by a fifth of the smaller one's area belong together (the cloud's
        // bumps, the stem in the body); pieces that merely touch (the "!" as it parts) do not, so
        // the grouping never flips mid-morph.
        func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
            let i = a.intersection(b)
            guard !i.isNull else { return false }
            return i.width * i.height >= 0.2 * min(a.width * a.height, b.width * b.height)
        }
        for piece in pieces {
            let b = piece.boundingRect
            if let i = groups.firstIndex(where: { overlaps($0.box, b) }) {
                groups[i].box = groups[i].box.union(b); groups[i].path.addPath(piece)
            } else {
                groups.append((b, piece))
            }
        }
        var out = Path()
        for g in groups {
            let sx = max(0, 1 - 2 * d / max(g.box.width, 1)), sy = max(0, 1 - 2 * d / max(g.box.height, 1))
            out.addPath(g.path.applying(CGAffineTransform(translationX: g.box.midX, y: g.box.midY).scaledBy(x: sx, y: sy).translatedBy(x: -g.box.midX, y: -g.box.midY)))
        }
        return out
    }

    /// Where each shape's bottom edge sits, as a fraction of the square (the blob reaches
    /// 0.985; the pill, cloud and triangle end well above that). Set by hand from the drawing.
    public static func baseline(of shape: String) -> CGFloat {
        switch shape {
        case "blob": return 0.985
        case "pill": return 0.795
        case "cloud": return 0.825
        case "triangle": return 0.815
        default: return 0.96   // circle, square, hexagon, drop
        }
    }

    /// How far down (fraction of the size) to move a bot so its base lands where the blob's does,
    /// so every shape sits on a pill the same way.
    public static func seatDrop(_ shape: String) -> CGFloat { 0.985 - baseline(of: shape) }

    /// Whether the eyes have something to do around `t` (a blink or a glance): idle bots only
    /// redraw during these moments.
    public static func eyesBusy(time t: Double, seed: Int) -> Bool {
        for dt in [0.0, 0.12, 0.24] {
            let l = liveliness(time: t + dt, seed: seed)
            if l.blink > 0.01 || l.glance != 0 { return true }
        }
        return false
    }

    /// Which part of the bot to draw: everything, or just one layer (the app draws a glass bot as
    /// real glass for the body and the eyes, and only needs the eyes' geometry from here).
    public enum Part { case all, body, eyes }

    /// Set by the app: it can draw glass bots with real Liquid Glass (a backdrop exists). The
    /// extensions and offscreen renders keep the painted approximation.
    nonisolated(unsafe) public static var liveGlass = false

    /// The eyes' ink; on a glass bot they are dark glass, drawn a little lighter.
    static let ink = Color(red: 0.05, green: 0.05, blue: 0.07)

    /// The whisper of squash and stretch about the bottom while working.
    static func breathScale(time t: Double, active: Bool, spec: BotLookSpec) -> CGFloat {
        guard active else { return 1 }
        let seed = spec.shape.utf8.reduce(0) { $0 + Int($1) } + spec.eyes.utf8.reduce(0) { $0 + Int($1) }
        return 1 + 0.025 * (liveliness(time: t, seed: seed).breath - 0.5)
    }

    /// Draws body and eyes into `size` (square). `active` animates; otherwise `time` should be 0.
    public static func draw(_ spec: BotLookSpec, in ctx: inout GraphicsContext, size: CGSize, time t: Double, active: Bool, gaze: CGPoint = .zero, part: Part = .all, breathe: Bool = true, idleEyes: Bool = false, move: Bool = true, strain: Bool = false, glanceFree: Bool = true, finishedAt: Double? = nil, light: Bool = false, motion: Motion = .still) {
        let box = CGRect(origin: .zero, size: size)
        let s = min(size.width, size.height)
        let seed = spec.shape.utf8.reduce(0) { $0 + Int($1) } + spec.eyes.utf8.reduce(0) { $0 + Int($1) }
        // Idle bots still blink and glance (`idleEyes`); only a working one moves its body.
        let live = liveliness(time: (active || idleEyes) ? t : 0, seed: seed)
        let tint = Color(botHex: spec.hex) ?? Color(red: 0.49, green: 0.36, blue: 1)

        _ = move; _ = finishedAt   // yaw and offsets are applied by BotFaceView (a 3D turn needs a view)
        // A roll can be painted (the widgets' held lean).
        if motion.roll != 0 {
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: .radians(motion.roll))
            ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
        }
        // Breathing: a whisper of squash and stretch about the bottom while working.
        if active && breathe {
            let sy = 1 + 0.025 * (live.breath - 0.5)
            ctx.translateBy(x: size.width / 2, y: size.height * 0.96)
            ctx.scaleBy(x: 1 / sy, y: sy)
            ctx.translateBy(x: -size.width / 2, y: -size.height * 0.96)
        }

        let body = bodyPath(spec.shape, in: box, time: t, active: active, morph: motion.morph, target: motion.morphTarget, phase: motion.blobPhase)
        let pale = isLight(spec.hex)
        if part != .eyes {
            if spec.isGlass {
                drawGlassBody(body, tint: tint, in: &ctx, box: box, s: s, light: light, dim: motion.dim, pale: pale)
            } else {
                ctx.fill(body, with: .linearGradient(Gradient(colors: [tint.opacity(1), tint.opacity(0.84)]), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
                // A soft light across the top, clipped to the body so shapes made of several pieces (the
                // cloud) show no seams: just the shape and its colour. On a white bot the crown is
                // a cool grey instead, so it still shows on a light background.
                ctx.drawLayer { layer in
                    layer.clip(to: body)
                    let crown: Color = pale ? Color(red: 0.72, green: 0.76, blue: 0.86).opacity(0.5 * (1 - motion.dim)) : .white.opacity(0.22 * (1 - motion.dim))
                    layer.fill(Path(box), with: .linearGradient(Gradient(colors: [crown, crown.opacity(0)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.55)))
                }
            }
            // A light bot gets a hairline inside its edge so it does not vanish on a light page.
            if pale { drawInnerStroke(body, in: &ctx, s: s) }
            if motion.dim > 0.01 {
                ctx.drawLayer { layer in layer.clip(to: body); layer.fill(Path(box), with: .color(.black.opacity(0.22 * motion.dim))) }
            }
        }
        if part != .eyes, motion.sheen > 0.01 { drawSheen(body, in: &ctx, box: box, s: s, sheen: motion.sheen * (1 - motion.dim), angle: motion.sheenAngle, glass: spec.isGlass) }
        guard part != .body else { return }

        // Eyes: black shapes, blinking by squashing to a line, glancing by sliding. In their own
        // layer so their fade (the "!") never leaks into what a caller draws next.
        let eyes = eyePaths(spec, size: size, time: t, active: active || idleEyes, gaze: gaze, strain: strain, glanceFree: glanceFree, motion: motion)
        let eyeInk = spec.isGlass ? ink.opacity(0.9) : ink
        ctx.drawLayer { eyeLayer in
            eyeLayer.opacity = motion.eyeOpacity
            if eyes.stroked {
                eyeLayer.stroke(eyes.path, with: .color(eyeInk), style: StrokeStyle(lineWidth: s * 0.045, lineCap: .round))
            } else {
                eyeLayer.fill(eyes.path, with: .color(eyeInk))
                if spec.isGlass {
                    // The rim of a dark glass eye: a hair of light along its top edge.
                    eyeLayer.drawLayer { layer in
                        layer.clip(to: eyes.path)
                        layer.stroke(eyes.path, with: .linearGradient(Gradient(colors: [.white.opacity(0.55), .white.opacity(0)]), startPoint: CGPoint(x: 0, y: eyes.path.boundingRect.minY), endPoint: CGPoint(x: 0, y: eyes.path.boundingRect.maxY)), lineWidth: s * 0.03)
                    }
                }
            }
        }
    }

    /// One point of `#D0D0D5` at 40 % just inside the edge (the body minus the body inset), for
    /// white and cream bots.
    static func drawInnerStroke(_ body: Path, in ctx: inout GraphicsContext, s: CGFloat) {
        ctx.drawLayer { layer in
            layer.fill(body, with: .color(Color(red: 0.816, green: 0.816, blue: 0.835).opacity(0.4)))
            layer.blendMode = .destinationOut
            layer.fill(rimInner(body, inset: 1), with: .color(.black))
        }
    }

    /// The painted stand-in for Liquid Glass, for where real glass cannot render (widgets,
    /// notification images, menu icons): a translucent tinted body with a lit rim, a darker
    /// lower edge and a soft highlight across the top, like the app icon.
    /// `light`: match the live glass on a light background — the live version lays the colour
    /// down at 62 % plus a light glass tint, so the painted one stays airy: no dark rim, a
    /// lighter shadow, the colour itself a touch lifted. Dark mode keeps the deeper version.
    /// `dim`: the light dies (the error pose). `pale`: a white bot gets a cool grey crown so it
    /// still shows on a light page.
    static func drawGlassBody(_ body: Path, tint: Color, in ctx: inout GraphicsContext, box: CGRect, s: CGFloat, light: Bool = false, dim: Double = 0, pale: Bool = false) {
        let lit = 1 - dim
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(light ? 0.12 : 0.28), radius: s * 0.05, y: s * 0.03))
            let top = light ? tint.opacity(0.82) : tint.opacity(0.92)
            let bottom = light ? tint.opacity(0.68) : tint.opacity(0.62)
            layer.fill(body, with: .linearGradient(Gradient(colors: [top, bottom]), startPoint: CGPoint(x: 0, y: box.minY), endPoint: CGPoint(x: 0, y: box.maxY)))
        }
        ctx.drawLayer { layer in
            layer.clip(to: body)
            // Specular: light pooling along the top, fading out a third of the way down.
            let crown: Color = pale ? Color(red: 0.72, green: 0.76, blue: 0.86).opacity(0.5 * lit) : .white.opacity((light ? 0.5 : 0.42) * lit)
            layer.fill(Path(box), with: .linearGradient(Gradient(colors: [crown, crown.opacity(0.1), crown.opacity(0)]), startPoint: CGPoint(x: 0, y: box.minY), endPoint: CGPoint(x: 0, y: box.maxY * 0.5)))
        }
        let rimDark: Color = light ? .black.opacity(0.10) : .black.opacity(0.28)
        // Rim: bright where the light hits (top-left), dark on the underside. Not a stroke: the
        // cloud is several overlapping pieces and a stroke draws every inner edge (the doubled
        // cloud seen in the profile menu). Fill the body, then punch out the body inset a little
        // (each separate piece toward its own centre), which leaves only the outline.
        ctx.drawLayer { layer in
            layer.fill(body, with: .linearGradient(Gradient(colors: [.white.opacity(0.9 * lit), .white.opacity(0.15 * lit), rimDark]), startPoint: CGPoint(x: box.minX, y: box.minY), endPoint: CGPoint(x: box.maxX, y: box.maxY)))
            layer.blendMode = .destinationOut
            layer.fill(rimInner(body, inset: s * 0.0225), with: .color(.black))
        }
    }

    /// Light travelling the rim: a short bright arc of the outline at `angle`, the rest of the
    /// ring clear. Built like the glass rim (the body minus the body shrunk) so the cloud's
    /// inner edges do not show. On a flat bot it is fainter, a slide of the painted highlight.
    static func drawSheen(_ body: Path, in ctx: inout GraphicsContext, box: CGRect, s: CGFloat, sheen: Double, angle: Double, glass: Bool) {
        ctx.drawLayer { layer in
            let peak = Color.white.opacity((glass ? 0.95 : 0.55) * sheen)
            let stops: [Gradient.Stop] = [.init(color: .clear, location: 0), .init(color: .clear, location: 0.34), .init(color: peak, location: 0.5), .init(color: .clear, location: 0.66), .init(color: .clear, location: 1)]
            layer.fill(body, with: .conicGradient(Gradient(stops: stops), center: CGPoint(x: box.midX, y: box.midY), angle: .degrees(angle - 180)))
            layer.blendMode = .destinationOut
            layer.fill(rimInner(body, inset: s * 0.025), with: .color(.black))
        }
    }

    /// The eyes' geometry for a frame: one path (both eyes) and whether it is stroked (sleepy
    /// lids) rather than filled. Both eyes move together: a glance or a gaze shifts the pair,
    /// never their spacing.
    /// `strain`: the bot is thinking hard — the eyes narrow to a squint. `glanceFree`: false keeps
    /// the eyes from wandering on their own (they still blink), for when they follow the phone.
    public static func eyePaths(_ spec: BotLookSpec, size: CGSize, time t: Double, active: Bool, gaze: CGPoint = .zero, strain: Bool = false, glanceFree: Bool = true, motion: Motion = .still) -> (path: Path, stroked: Bool) {
        let s = min(size.width, size.height)
        let seed = spec.shape.utf8.reduce(0) { $0 + Int($1) } + spec.eyes.utf8.reduce(0) { $0 + Int($1) }
        // Tiny eyes blink faster (they are already small) and skip the double blink when small.
        let tiny = spec.eyes == "tiny"
        let live = liveliness(time: active ? t : 0, seed: seed, blinkPeriod: motion.blinkPeriod, blinkLength: tiny ? 0.09 : motion.blinkLength, doubleBlinks: !(tiny && s < 32), rare: motion.blinkPeriod == 4.3)
        let anchor = eyeAnchor(spec.shape)
        let dx = s * anchor.spread
        let wander = glanceFree && !motion.freezeGlance
        let gx = gaze.x + CGFloat(motion.eyeX), gy = gaze.y + CGFloat(motion.eyeY)
        let cx = size.width / 2 + (wander ? CGFloat(live.glance) * s * 0.06 : 0) + gx * s * 0.06
        let cy = s * anchor.y + gy * s * 0.07
        let open = min(CGFloat(1 - live.blink * 0.92), strain ? 0.42 : 1, CGFloat(motion.eyeOpen))
        var path = Path()
        func eye(at x: CGFloat, w: CGFloat, h: CGFloat, round: Bool) {
            let hh = max(s * 0.025, h * open)
            let rect = CGRect(x: x - w / 2, y: cy - hh / 2, width: w, height: hh)
            path.addPath(round && open > 0.5 ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: min(w, hh) / 2, style: .continuous))
        }
        if spec.eyes == "sleepy" {
            // Lids: two soft downward arcs. They never squash to a line; instead the lids get a
            // little heavier and lighter over a couple of seconds.
            let weight = active ? 0.5 + 0.5 * sin(t * .pi / 2.15) : 0
            for x in [cx - dx, cx + dx] {
                path.move(to: CGPoint(x: x - s * 0.075, y: cy - s * 0.01))
                path.addQuadCurve(to: CGPoint(x: x + s * 0.075, y: cy - s * 0.01), control: CGPoint(x: x, y: cy + s * (0.05 + 0.025 * weight)))
            }
            return (path, true)
        }
        switch spec.eyes {
        case "tall":
            eye(at: cx - dx, w: s * 0.085, h: s * 0.30, round: false); eye(at: cx + dx, w: s * 0.085, h: s * 0.30, round: false)
        case "tiny":
            eye(at: cx - dx * 0.8, w: s * 0.07, h: s * 0.07, round: true); eye(at: cx + dx * 0.8, w: s * 0.07, h: s * 0.07, round: true)
        case "round":
            eye(at: cx - dx, w: s * 0.13, h: s * 0.13, round: true); eye(at: cx + dx, w: s * 0.13, h: s * 0.13, round: true)
        case "wide":
            eye(at: cx - dx, w: s * 0.16, h: s * 0.075, round: false); eye(at: cx + dx, w: s * 0.16, h: s * 0.075, round: false)
        case "curious":
            // The tall eye follows a glance 60 ms behind the round one.
            let late = wander ? CGFloat(liveliness(time: active ? t - 0.06 : 0, seed: seed, blinkPeriod: motion.blinkPeriod).glance) * s * 0.06 : 0
            let rx = size.width / 2 + late + gx * s * 0.06 + dx
            eye(at: cx - dx, w: s * 0.09, h: s * 0.09, round: true); eye(at: rx, w: s * 0.085, h: s * 0.20, round: false)
        case "bold":
            eye(at: cx - dx, w: s * 0.13, h: s * 0.27, round: false); eye(at: cx + dx, w: s * 0.13, h: s * 0.27, round: false)
        default: // classic
            eye(at: cx - dx, w: s * 0.10, h: s * 0.22, round: false); eye(at: cx + dx, w: s * 0.10, h: s * 0.22, round: false)
        }
        return (path, false)
    }
}

/// What every bot on screen reacts to together: where the last scroll went (the eyes follow
/// it) and how the device is tilted (the bot leans with it). Fed by the app; the extensions
/// leave it at rest. `enabled` is the Settings › Bots switch.
@MainActor @Observable
public final class BotAmbient {
    public static let shared = BotAmbient()
    /// −1…1 on each axis; decays back to zero when the scrolling stops.
    public var gaze: CGPoint = .zero
    /// −1…1: roll (x) and pitch (y) away from the resting hold.
    public var tilt: CGPoint = .zero
    public var enabled = true
    /// The display is asleep or the screen is locked (Mac): every face holds still. Drawing
    /// into a window nobody can see made each frame wait on the render server.
    public var displayAsleep = false
    /// A turn is running or waiting anywhere (Mac, fed by the menu bar's turn board). Idle
    /// bots blink and glance only while it is; otherwise they hold still and cost nothing.
    public var anyWorking = false
    /// Settings › Appearance › Animate bots (Mac): off, every bot holds still.
    public static let animateKey = "bots.animate"
    /// For a decorative bot that plays the working routines (the sidebar's, Home's): on the
    /// Mac only while something is working, so an idle app holds still (#248); always elsewhere.
    public var decorativeActive: Bool {
        #if os(macOS)
        anyWorking
        #else
        true
        #endif
    }
    /// True while a list is being scrolled (cleared shortly after the last movement); the Bots
    /// page bots play while it is.
    public var scrolling = false
    /// When each bot (by profile name) last finished a turn: it spins once at that moment.
    public var finished: [String: Date] = [:]
    private var decayTask: Task<Void, Never>?
    private var lastGazeAt: Date = .distantPast

    public init() {}

    /// A scroll of `dy` points (positive = content moving up, the finger swiping up). Every bot
    /// on screen observes `gaze`, so it moves at most ~16 times a second and only when the change
    /// is worth a redraw; `scrolling` is set once, not on every tick.
    public func scrolled(dy: CGFloat) {
        guard abs(dy) > 0.5 else { return }
        let now = Date()
        if enabled, now.timeIntervalSince(lastGazeAt) > 0.06 {
            let y = max(-1, min(1, gaze.y * 0.6 + CGFloat(-dy) / 40))
            if abs(y - gaze.y) > 0.03 { gaze = CGPoint(x: gaze.x, y: y) }
            lastGazeAt = now
        }
        if !scrolling { scrolling = true }
        decayTask?.cancel()
        decayTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            self.gaze = .zero
            self.scrolling = false
        }
    }

    public func turnFinished(profile: String) { finished[profile] = Date() }
    /// When each bot was last tapped: a small turn and a blink at that moment.
    public var tapped: [String: Date] = [:]
    public func tap(profile: String) { tapped[profile] = Date() }
}

/// The bot's body as a Shape, so the app can give it real Liquid Glass.
public struct BotBodyShape: Shape {
    public var spec: BotLookSpec
    public var time: Double
    public var active: Bool
    public var morph: Double = 0
    public var target: BotFace.MorphTarget = .none
    public var phase: Double? = nil
    /// > 0: the body inset by this much for a rim mask (each piece toward its own centre).
    public var inset: CGFloat = 0
    public init(spec: BotLookSpec, time: Double, active: Bool, morph: Double = 0, target: BotFace.MorphTarget = .none, phase: Double? = nil, inset: CGFloat = 0) {
        self.spec = spec; self.time = time; self.active = active; self.morph = morph; self.target = target; self.phase = phase; self.inset = inset
    }
    public func path(in rect: CGRect) -> Path {
        let p = BotFace.bodyPath(spec.shape, in: rect, time: time, active: active, morph: morph, target: target, phase: phase)
        return inset > 0 ? BotFace.rimInner(p, inset: inset) : p
    }
}

/// The bot's eyes as a Shape (filled styles only; sleepy lids stay painted).
public struct BotEyesShape: Shape {
    public var spec: BotLookSpec
    public var time: Double
    public var active: Bool
    public var gaze: CGPoint
    public var strain = false
    public var glanceFree = true
    public var motion: BotFace.Motion = .still
    public init(spec: BotLookSpec, time: Double, active: Bool, gaze: CGPoint, strain: Bool = false, glanceFree: Bool = true, motion: BotFace.Motion = .still) {
        self.spec = spec; self.time = time; self.active = active; self.gaze = gaze; self.strain = strain; self.glanceFree = glanceFree; self.motion = motion
    }
    public func path(in rect: CGRect) -> Path { BotFace.eyePaths(spec, size: rect.size, time: time, active: active, gaze: gaze, strain: strain, glanceFree: glanceFree, motion: motion).path.offsetBy(dx: rect.minX, dy: rect.minY) }
}

/// The bot as a view. `active` runs the animation (blink, glance, the blob's morph and the
/// working routines); otherwise it is a still frame, so a list of idle bots costs nothing.
public struct BotFaceView: View {
    public var spec: BotLookSpec
    public var size: CGFloat
    public var active: Bool
    /// Where the eyes look, −1…1 on each axis (0,0 straight ahead); eased over a third of a second.
    public var gaze: CGPoint
    @State private var shownGaze: CGPoint = .zero
    @State private var gazeFrom: CGPoint = .zero
    @State private var gazeChangedAt: Date = .distantPast
    /// Idle bots redraw only while the eyes have something to do (a blink, a glance).
    @State private var eyesBusy = false
    @State private var spinTick = 0
    /// When the current state began: the one-shots at a state's start (the lean as a tool
    /// starts, the slow blink of an error) count from here.
    @State private var stateSince: Date = Date()
    /// The state just left and when: for 0.4 s its held pose (silhouette, roll, eyes, dim) eases
    /// out before the new state's eases in — one continuous path, even held to held.
    /// The pose that was on screen when the state last changed, and when: for 0.4 s the frame
    /// blends from it to the new state's pose, so a change never jumps — however far the old
    /// pose had got, held to held included.
    @State private var exitPose: BotFace.Motion = .still
    @State private var exitAt: Date = .distantPast
    /// The last pose rendered, kept in a box so recording it during a frame changes no state.
    @State private var shown = ShownPose()
    private final class ShownPose { var pose: BotFace.Motion = .still }
    /// The blob's outline phase runs while it works and freezes where it stopped, so the outline
    /// never jumps when the routines start or end.
    @State private var blobOffset: Double = 0
    @State private var blobFrozen: Double = 0
    @State private var blobRunning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether this bot's window is where someone can see it (Mac; always true elsewhere).
    @Environment(\.botsLive) private var windowLive
    #if os(macOS)
    @AppStorage(BotAmbient.animateKey) private var animateSetting = true
    #endif
    /// A few frames' grace after the bot stops or its look changes while held, so the frame it
    /// holds is the current one at rest (eyes open, body still), never a half blink.
    @State private var settling = false
    private var ambient: BotAmbient { BotAmbient.shared }
    /// Per-bot phase: shape, eyes and name, folded to a small non-negative number (the name's
    /// hash wraps, and a negative seed would skew every `%` below it).
    private var seed: Int {
        let raw = spec.shape.utf8.reduce(0) { $0 + Int($1) } + spec.eyes.utf8.reduce(0) { $0 + Int($1) }
            + (mood.profile ?? "").utf8.reduce(0) { $0 &* 31 &+ Int($1) }
        return Int(UInt(bitPattern: raw) % 1_000_003)
    }

    /// Paint the glass finish even in the app (for offscreen renders such as menu icons).
    public var drawn: Bool
    /// What the bot is up to, beyond `active`.
    public struct Mood: Equatable, Sendable {
        /// Thinking hard: the eyes squint. (Same as `state: .thinking`.)
        public var thinking = false
        /// Which profile this is, so a finished turn (`BotAmbient.finished`) spins it once.
        public var profile: String? = nil
        /// Bots page: past a few degrees of tilt the eyes stop wandering and follow the phone.
        public var followsTilt = false
        /// What the bot is doing. `.idle` with `active` on means the working routines.
        public var state: BotFace.State = .idle
        /// In a group only one bot moves its body per five-second block: this bot's slot.
        public var groupIndex = 0
        public var groupCount = 1
        /// No eye life at all: the bots behind the front one in a stack.
        public var still = false
        /// A squint on top of any state without the thinking hold (the guide while it waits).
        public var squint = false
        public init(thinking: Bool = false, profile: String? = nil, followsTilt: Bool = false, state: BotFace.State = .idle, groupIndex: Int = 0, groupCount: Int = 1, still: Bool = false, squint: Bool = false) {
            self.thinking = thinking; self.profile = profile; self.followsTilt = followsTilt
            self.state = state; self.groupIndex = groupIndex; self.groupCount = groupCount; self.still = still; self.squint = squint
        }
    }
    public var mood: Mood
    @Environment(\.colorScheme) private var colorScheme
    /// The app switcher's snapshot is taken with the glass effects stripped (the bots went
    /// grey), so once the scene is no longer active the painted glass stands in.
    @Environment(\.scenePhase) private var scenePhase

    public init(spec: BotLookSpec, size: CGFloat, active: Bool = false, gaze: CGPoint = .zero, drawn: Bool = false, mood: Mood = Mood()) {
        self.spec = spec
        self.size = size
        self.active = active
        self.gaze = gaze
        self.drawn = drawn
        self.mood = mood
    }

    private var state: BotFace.State {
        if mood.thinking { return .thinking }
        if mood.state == .idle, active { return .working }
        return mood.state
    }

    /// Seconds since the reference date when this bot's turn last finished, while the spin plays.
    private var finishedAt: Double? {
        guard let p = mood.profile, let d = ambient.finished[p], Date().timeIntervalSince(d) < 1.8 else { return nil }
        return d.timeIntervalSinceReferenceDate
    }
    private var tappedAt: Double? {
        guard let p = mood.profile, let d = ambient.tapped[p], Date().timeIntervalSince(d) < 0.6 else { return nil }
        return d.timeIntervalSinceReferenceDate
    }

    /// The frame's pose. For 0.4 s after a state change the frame blends from the pose that was
    /// on screen (`exitPose`) to the new state's, so nothing jumps — whatever the old state had
    /// got to, held to held included. When the old pose held a silhouette the new state's clock
    /// starts 0.4 s late (`stateSince` is set ahead), so the old shape is back at rest before the
    /// new one grows. Reduce Motion jumps to the end pose with the body frozen (a held lean stays;
    /// it does not move); painted renders keep the transforms still. Under 32 pt (beside a bubble,
    /// on the toolbar) the body keeps its shape: eyes, and a lean or nudge, only.
    private func pose(time t: Double, now: Date, since: Double, finished: Double?, tapped: Double?) -> BotFace.Motion {
        let group: (index: Int, count: Int)? = mood.groupCount > 1 ? (mood.groupIndex, mood.groupCount) : nil
        var m = BotFace.motion(time: t, seed: seed, spec: spec, state: state, since: since, finishedAt: finished, tappedAt: tapped, group: group)
        let back = now.timeIntervalSince(exitAt)
        if back < 0.4, !reduceMotion {
            let ex = exitPose
            let k = 1 - BotFace.smooth(back / 0.4)
            func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
            if ex.morph > 0.001 { m.morphTarget = ex.morphTarget; m.morph = ex.morph * k }
            m.roll = lerp(m.roll, ex.roll)
            m.dim = lerp(m.dim, ex.dim)
            m.eyeOpacity = lerp(m.eyeOpacity, ex.eyeOpacity)
            m.eyeOpen = lerp(m.eyeOpen, ex.eyeOpen)
            m.eyeX = lerp(m.eyeX, ex.eyeX); m.eyeY = lerp(m.eyeY, ex.eyeY)
            if k > 0.5 { m.freezeGlance = ex.freezeGlance }
        }
        if mood.squint { m.eyeOpen = min(m.eyeOpen, 0.42); m.blinkPeriod = 2.8; m.blinkLength = 0.22 }
        m.blobPhase = blobRunning ? t * 0.19 + blobOffset : blobFrozen
        if reduceMotion {
            let end = BotFace.motion(time: t, seed: seed, spec: spec, state: state, since: 10, group: group)
            m = m.bodyStill
            m.morphTarget = end.morphTarget; m.morph = end.morphTarget == .none ? 0 : 1
            m.eyeOpacity = end.morphTarget == .exclamation ? 0 : 1
            m.dim = state == .error ? 1 : 0
            m.roll = end.roll
        } else if drawn {
            m = m.bodyStill
        }
        if size < 32 { m.yaw = 0; m.dy = 0; m.morph = 0; m.morphTarget = .none; m.eyeOpacity = 1 }
        return m
    }

    /// The glass bot as the icon is built: the body a tinted piece of glass, the eyes a darker
    /// piece in front, each in its own container (in one container they would merge into a
    /// single shape). Sleepy lids are strokes, so they stay painted. The rim sheen is a ring
    /// (the body minus the body shrunk) lit along a short arc.
    @ViewBuilder private func liveGlass(time t: Double, gaze g: CGPoint, glanceFree: Bool, motion m: BotFace.Motion, wobble: Bool, eyeLife: Bool) -> some View {
        let tint = Color(botHex: spec.hex) ?? Color(red: 0.49, green: 0.36, blue: 1)
        // One shape for every layer: the same plate, morphing in place, never re-created.
        let plate = BotBodyShape(spec: spec, time: t, active: wobble, morph: m.morph, target: m.morphTarget, phase: m.blobPhase)
        // The plate inset for the rim masks: each piece toward its own centre (the "!").
        let hairline = BotBodyShape(spec: spec, time: t, active: wobble, morph: m.morph, target: m.morphTarget, phase: m.blobPhase, inset: 1)
        let ring = BotBodyShape(spec: spec, time: t, active: wobble, morph: m.morph, target: m.morphTarget, phase: m.blobPhase, inset: size * 0.025)
        let pale = BotFace.isLight(spec.hex)
        ZStack {
            // The colour itself under the glass: tinted glass alone reads dark on a light
            // background (a sky-blue bot came out navy), so the hue is laid down first and the
            // glass adds its rim and refraction on top.
            plate.fill(tint.opacity(colorScheme == .light ? 0.62 : 0.28))
            // The error's dimming goes under the glass, so the plate darkens as one piece and its
            // rim dies with it, rather than a dark shape sitting inside a lit one.
            if m.dim > 0.01 { plate.fill(.black.opacity(0.30 * m.dim)) }
            GlassEffectContainer {
                Color.clear
                    .glassEffect(.regular.tint(tint.opacity((colorScheme == .light ? 0.45 : 0.72) * (1 - 0.5 * m.dim))), in: plate)
                    // No materialize bloom when a glass bot appears or changes look.
                    .glassEffectTransition(.identity)
            }
            // A light bot: a hairline inside the edge, and a cool crown so it reads on white.
            if pale {
                plate.fill(Color(red: 0.816, green: 0.816, blue: 0.835).opacity(0.4))
                    .mask { ZStack { plate.fill(.white); hairline.fill(.black).blendMode(.destinationOut) }.compositingGroup() }
                    .allowsHitTesting(false)
                plate.fill(LinearGradient(colors: [Color(red: 0.72, green: 0.76, blue: 0.86).opacity(0.45 * (1 - m.dim)), .clear], startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
            }
            // A black bot on a dark page: a light hairline inside the edge, or it is a hole.
            if BotFace.isDark(spec.hex), colorScheme == .dark {
                plate.fill(Color.white.opacity(0.32))
                    .mask { ZStack { plate.fill(.white); hairline.fill(.black).blendMode(.destinationOut) }.compositingGroup() }
                    .allowsHitTesting(false)
            }
            if m.sheen > 0.01 {
                let stops: [Gradient.Stop] = [.init(color: .clear, location: 0), .init(color: .clear, location: 0.34), .init(color: .white.opacity(m.sheen * (1 - m.dim)), location: 0.5), .init(color: .clear, location: 0.66), .init(color: .clear, location: 1)]
                plate.fill(AngularGradient(gradient: Gradient(stops: stops), center: .center, angle: .degrees(m.sheenAngle - 180)))
                    .mask { ZStack { plate.fill(.white); ring.fill(.black).blendMode(.destinationOut) }.compositingGroup() }
                    .allowsHitTesting(false)
            }
            Group {
                if spec.eyes == "sleepy" {
                    // The lids are painted; the roll and the fade are applied by the view, once.
                    let lids: BotFace.Motion = { var e = m.transformsStill; e.eyeOpacity = 1; return e }()
                    Canvas(opaque: false, rendersAsynchronously: false) { ctx, sz in
                        BotFace.draw(spec, in: &ctx, size: sz, time: t, active: wobble, gaze: g, part: .eyes, breathe: false, idleEyes: eyeLife, move: false, glanceFree: glanceFree, motion: lids)
                    }
                } else {
                    GlassEffectContainer {
                        Color.clear
                            .glassEffect(.clear.tint(BotFace.ink.opacity(0.92)), in: BotEyesShape(spec: spec, time: t, active: eyeLife, gaze: g, glanceFree: glanceFree, motion: m))
                            .glassEffectTransition(.identity)
                    }
                }
            }
            .opacity(m.eyeOpacity)
        }
    }

    public var body: some View {
        // Whether this bot moves at all. On the Mac every bot cost CPU all the time, in the
        // background too (#248): it moves only while its window is visible and in front, the
        // display is awake, Animate bots is on and Reduce Motion is off; held, it shows its
        // current pose at rest. The idle eyes (blinks, glances) play only while something is
        // working. Elsewhere this is as before: the display flag is never set off the Mac.
        #if os(macOS)
        let live = !drawn && windowLive && !ambient.displayAsleep && animateSetting && !reduceMotion
        let eyeLife = live && ambient.anyWorking && !mood.still
        #else
        let live = !drawn && windowLive && !ambient.displayAsleep
        let eyeLife = live && !mood.still
        #endif
        // Tilted well past level (Bots page), the eyes stop wandering and follow the phone; within
        // a few degrees they add a little of the tilt to their own glances.
        // Small bots (beside a bubble, on the toolbar) do not follow scrolls or tilt: a long
        // thread has dozens of them and each would redraw on every scroll tick.
        #if os(macOS)
        let listens = size >= 32 && ambient.enabled && live
        #else
        let listens = size >= 32 && ambient.enabled
        #endif
        let tilt = listens ? ambient.tilt : .zero
        let tiltMag = hypot(tilt.x, tilt.y)
        let held = mood.followsTilt && listens && tiltMag > 0.3
        let tiltWeight: CGFloat = held ? 1.0 : 0.5
        let ambientGaze = listens ? CGPoint(x: ambient.gaze.x + tilt.x * tiltWeight, y: ambient.gaze.y + tilt.y * tiltWeight) : .zero
        let finished = finishedAt
        let tapped = tappedAt
        let state = state
        // The frame blends from the last pose for 0.4 s after a state change.
        let leaving = Date().timeIntervalSince(exitAt) < 0.5
        // Any state but idle keeps the clock running: the poses are functions of time.
        let animating = (active || state != .idle || finished != nil || tapped != nil || leaving) && live
        let wobble = state == .working && (live || drawn)
        let ticks = live && (animating || eyesBusy || gaze != shownGaze)
        let _ = spinTick
        TimelineView(.animation(minimumInterval: animating ? 1 / 30 : 1 / 24, paused: !ticks && !settling)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let u = min(1, max(0, timeline.date.timeIntervalSince(gazeChangedAt) / 0.35))
            let ease = u * u * (3 - 2 * u)
            let g0 = CGPoint(x: gazeFrom.x + (gaze.x - gazeFrom.x) * ease, y: gazeFrom.y + (gaze.y - gazeFrom.y) * ease)
            let g = CGPoint(x: max(-1, min(1, g0.x + ambientGaze.x)), y: max(-1, min(1, g0.y + ambientGaze.y)))
            // Held (not live), the bot stands at rest in its current state: no turn, nod or lean
            // part-way through, and the eyes open.
            let posed = pose(time: t, now: timeline.date, since: timeline.date.timeIntervalSince(stateSince), finished: finished, tapped: tapped)
            let m = live || drawn ? posed : posed.bodyStill
            let _ = { shown.pose = m }()
            Group {
                if spec.isGlass && BotFace.liveGlass && !drawn && scenePhase == .active {
                    liveGlass(time: t, gaze: g, glanceFree: !held, motion: m, wobble: wobble, eyeLife: eyeLife)
                } else {
                    // The painted twin: the view applies the transforms, so it gets them zeroed;
                    // the sheen, the hold and the dimming it paints itself.
                    Canvas(opaque: false, rendersAsynchronously: false) { ctx, sz in
                        BotFace.draw(spec, in: &ctx, size: sz, time: t, active: wobble, gaze: g, breathe: false, idleEyes: eyeLife, move: false, glanceFree: !held, light: colorScheme == .light, motion: m.transformsStill)
                    }
                }
            }
            // The routines: a turn about the vertical axis (3D, on the spot), a small roll, a
            // tiny nod or lean. Nothing scales and nothing leaves the bot's footprint.
            .rotation3DEffect(.radians(m.yaw), axis: (x: 0, y: 1, z: 0), perspective: 0)
            .rotationEffect(.radians(m.roll))
            .offset(x: m.dx * size, y: m.dy * size)
        }
        .animation(.interactiveSpring(response: 0.3), value: ambientGaze)
        // The bot leans with the phone: a few degrees, about the centre.
        .rotation3DEffect(.degrees(Double(tilt.y) * -7), axis: (x: 1, y: 0, z: 0))
        .rotation3DEffect(.degrees(Double(tilt.x) * 7), axis: (x: 0, y: 1, z: 0))
        .onChange(of: gaze) { old, new in
            gazeFrom = old; shownGaze = new; gazeChangedAt = Date()
        }
        .onChange(of: state) { _, _ in
            let now = Date()
            exitPose = shown.pose; exitAt = now
            // A silhouette on screen unwinds first: the new state starts 0.4 s later.
            stateSince = exitPose.morph > 0.01 ? now.addingTimeInterval(0.4) : now
            // Held, the bot still shows the new state, at rest.
            if !live { settle() }
        }
        // Stopping (or starting) to move, and the eyes going still: one more frame at rest, so
        // a held bot never keeps a half blink, an old state or a turn part-way through.
        .onChange(of: live) { _, _ in settle() }
        .onChange(of: eyeLife) { _, _ in settle() }
        // The blob's creep: the phase runs from where it froze, and freezes where it is. Reduce
        // Motion, and a held bot, keep it frozen.
        .onChange(of: wobble && !reduceMotion && live, initial: true) { _, running in
            let now = Date().timeIntervalSinceReferenceDate * 0.19
            if running { blobOffset = blobFrozen - now } else if blobRunning { blobFrozen = now + blobOffset }
            blobRunning = running
        }
        // Once the blend has played, a nudge re-evaluates the body so the timeline pauses.
        .task(id: exitAt) {
            guard exitAt != .distantPast else { return }
            try? await Task.sleep(for: .milliseconds(600))
            spinTick += 1
        }
        // A tap on the bot: the small turn. Simultaneous, so the row or link it sits in still gets it.
        .simultaneousGesture(TapGesture().onEnded { if let p = mood.profile, !drawn { ambient.tap(profile: p) } })
        // Once a finish spin or a tap has played, a nudge re-evaluates the body so the timeline
        // pauses again (nothing else changes afterwards and it would keep running otherwise).
        .task(id: "\(finished ?? 0)-\(tapped ?? 0)") {
            guard finished != nil || tapped != nil else { return }
            try? await Task.sleep(for: .milliseconds(1900))
            spinTick += 1
        }
        // A quarter-second poll decides whether an idle bot has a blink or a glance coming up;
        // between those it costs nothing. None at all while the eyes are held (not live, or on
        // the Mac while nothing is working): each poll was a wakeup per bot, four a second.
        .task(id: "\(animating)-\(eyeLife)") {
            guard eyeLife, !animating else { eyesBusy = false; return }
            while !Task.isCancelled {
                eyesBusy = BotFace.eyesBusy(time: Date().timeIntervalSinceReferenceDate, seed: seed)
                try? await Task.sleep(for: .milliseconds(eyesBusy ? 120 : 250))
            }
        }
        .frame(width: size, height: size)
        // A paused TimelineView does not redraw for a changed spec (a bot switched to glass kept
        // its painted look until something else re-created the row): un-pause it for a moment.
        // Not a new identity — re-creating a glass view makes it "materialize" (bloom in), which
        // is exactly the pop the studio must not do on every tap.
        .onChange(of: spec) { _, _ in
            eyesBusy = true
            settle()
            Task { try? await Task.sleep(for: .milliseconds(350)); eyesBusy = false }
        }
        .accessibilityHidden(true)
    }

    /// Lets a paused bot draw a few more frames, so the frame it holds is current.
    private func settle() {
        settling = true
        Task { try? await Task.sleep(for: .milliseconds(160)); settling = false }
    }
}

extension EnvironmentValues {
    /// Whether the bots in this window may move: false while the window is hidden, minimised,
    /// covered or (main window) not in front. Set per window on the Mac; true elsewhere.
    @Entry public var botsLive: Bool = true
}

extension Color {
    /// "#RRGGBB" → Color; nil when the string is not a colour.
    public init?(botHex: String) {
        var s = botHex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
