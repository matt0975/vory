import CoreGraphics

/// When the faces blink as a foldable phone opens (Duo stage 4, `BotAmbient.opened`). Once per opening, at the later of
/// `delay` after the hinge leaves closed and the first window of the open display after that (the window changes size as
/// the open display takes over); the faces blink where they're seen, not on the cover. Not at all when that window
/// doesn't come within `windowWait` (opened a little and closed again), and not for an opening that closes first.
/// Never for partly open to fully open (the same opening), a close, or the first reading after launch. The hinge reports a
/// stream while it moves (about every 50 ms, mostly the same status at a new angle): only a change of status counts.
/// Kept apart from SwiftUI's hinge types so it is tested the same on every platform; the root feeds it (`HingeOpenBlink`).
struct HingeOpenRule {
    enum Status: Equatable { case closed, partly, open }

    static let delay: Double = 0.3
    static let windowWait: Double = 2

    /// The opening waiting for its blink: when the hinge left closed, and when the open window came after it.
    private(set) var leftClosedAt: Double?
    private(set) var windowAt: Double?
    private var lastSize: CGSize?

    /// A reading of the hinge at `t`; `old` nil is the first one after launch.
    mutating func hinge(from old: Status?, to new: Status, at t: Double) {
        guard let old, old != new else { return }
        if old == .closed { leftClosedAt = t; windowAt = nil }
        else if new == .closed { leftClosedAt = nil; windowAt = nil }
    }

    /// The window's size at `t`. The first change after the hinge left closed is the open display's window.
    mutating func window(_ size: CGSize, at t: Double) {
        defer { lastSize = size }
        guard let left = leftClosedAt, windowAt == nil, let last = lastSize, last != size, t >= left else { return }
        windowAt = t
    }

    /// When the waiting opening's blink plays; nil while none is due (no opening, or no open window yet).
    var blinkAt: Double? {
        guard let left = leftClosedAt, let win = windowAt, win - left <= Self.windowWait else { return nil }
        return max(left + Self.delay, win)
    }

    /// Whether the waiting opening has given up at `t`: no open window within `windowWait`.
    func gaveUp(at t: Double) -> Bool {
        guard let left = leftClosedAt, windowAt == nil else { return false }
        return t - left > Self.windowWait
    }

    /// The blink played, or the opening gave up: nothing waits any more.
    mutating func done() { leftClosedAt = nil; windowAt = nil }
}
