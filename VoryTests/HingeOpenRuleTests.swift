import CoreGraphics
import Testing
@testable import Vory

/// When the faces blink as a foldable phone opens (Duo stage 4, `HingeOpenRule`): the later of 0.3 s after the hinge
/// leaves closed and the open display's window, once per opening; none when that window doesn't come within 2 s, for an
/// opening that closes first, for partly to fully open, or for the first reading after launch. Times in seconds.
@Suite struct HingeOpenRuleTests {
    let cover = CGSize(width: 466, height: 678)
    let inner = CGSize(width: 669, height: 951)

    /// The rule as the root holds it: the window's size known from launch (the root reads it at once).
    private func closedPhone() -> HingeOpenRule {
        var r = HingeOpenRule()
        r.window(cover, at: -10)
        return r
    }

    @Test func anOpeningBlinksAtTheLaterOfTheDelayAndTheOpenWindow() {
        // The window came after the delay: the blink waits for it.
        var late = closedPhone()
        late.hinge(from: .closed, to: .partly, at: 0)
        #expect(late.blinkAt == nil)
        late.window(inner, at: 0.5)
        #expect(late.blinkAt == 0.5)
        // The window came first: the blink waits for the delay.
        var early = closedPhone()
        early.hinge(from: .closed, to: .partly, at: 0)
        early.window(inner, at: 0.1)
        #expect(early.blinkAt == HingeOpenRule.delay)
    }

    @Test func theStreamAndPartlyToFullyOpenAddNothing() {
        var r = closedPhone()
        r.hinge(from: .closed, to: .partly, at: 0)
        r.window(inner, at: 0.5)
        // The hinge reports every ~50 ms while it turns, mostly the same status.
        r.hinge(from: .partly, to: .partly, at: 0.6)
        r.hinge(from: .partly, to: .open, at: 1.0)
        r.hinge(from: .open, to: .open, at: 1.05)
        #expect(r.blinkAt == 0.5)
        // Partly to fully open on its own is no opening.
        var halfway = closedPhone()
        halfway.hinge(from: .partly, to: .open, at: 0)
        halfway.window(inner, at: 0.4)
        #expect(halfway.blinkAt == nil)
    }

    @Test func theFirstReadingAfterLaunchIsNoOpening() {
        var r = closedPhone()
        r.hinge(from: nil, to: .open, at: 0)
        r.window(inner, at: 0.2)
        #expect(r.blinkAt == nil)
        r.hinge(from: nil, to: .partly, at: 1)
        #expect(r.blinkAt == nil)
    }

    @Test func noOpenWindowWithinTwoSecondsGivesUp() {
        var r = closedPhone()
        r.hinge(from: .closed, to: .partly, at: 0)
        #expect(!r.gaveUp(at: 1.9))
        #expect(r.gaveUp(at: 2.1))
        // A window later than that is too late for this opening.
        r.window(inner, at: 2.5)
        #expect(r.blinkAt == nil)
    }

    @Test func anOpeningThatClosesFirstNeverBlinks() {
        var r = closedPhone()
        r.hinge(from: .closed, to: .partly, at: 0)
        r.hinge(from: .partly, to: .closed, at: 0.2)
        r.window(inner, at: 0.25)
        #expect(r.blinkAt == nil)
        #expect(!r.gaveUp(at: 5))
    }

    @Test func aWindowChangeWithoutAnOpeningDoesNothing() {
        // A rotation or a resize, the hinge not moving.
        var r = closedPhone()
        r.window(CGSize(width: 678, height: 466), at: 1)
        #expect(r.blinkAt == nil)
    }

    @Test func eachOpeningBlinksOnce() {
        var r = closedPhone()
        r.hinge(from: .closed, to: .partly, at: 0)
        r.window(inner, at: 0.4)
        #expect(r.blinkAt == 0.4)
        r.done()
        #expect(r.blinkAt == nil)
        // Closed again, then opened again: one more.
        r.hinge(from: .open, to: .closed, at: 10)
        r.window(cover, at: 10.2)
        r.hinge(from: .closed, to: .partly, at: 20)
        r.window(inner, at: 20.6)
        #expect(r.blinkAt == 20.6)
    }
}
