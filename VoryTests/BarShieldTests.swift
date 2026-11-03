#if os(iOS)
import Testing
import UIKit
@testable import Vory

/// #344: the bars' shield decides at touch-down whether a touch is the bar's (the page's glass
/// under it then stays still). Inside a bar's shape and hit-testing to the view the bar is drawn
/// in: yes. On the compose and mic circles (their own glass), outside every shape, under a sheet
/// presented over the bar, or with the bar hidden: no.
@MainActor @Suite struct BarShieldTests {
    /// Stands in for SwiftUI's hosting view: the shield looks for the nearest "HostingView".
    final class FakeHostingView: UIView {}

    private func scene() -> (UIWindow, FakeHostingView, BarShieldRegion.RegionView, CGRect) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
        // A window starts hidden, and a hidden one hit-tests to nothing.
        window.isHidden = false
        let host = FakeHostingView(frame: window.bounds)
        window.addSubview(host)
        // The bar's shape along the bottom (the capsule and the circles, as the tab bar's catcher),
        // and a circle in it whose own glass is left alone (its frame given to the shield).
        let bar = BarShieldRegion.Catcher(frame: CGRect(x: 20, y: 800, width: 350, height: 56))
        let circle = CGRect(x: 310, y: 800, width: 56, height: 56)
        BarShield.setCircle("test", frame: circle)
        host.addSubview(bar)
        return (window, host, bar, circle)
    }

    @Test func aTouchOnTheBarIsTheBars() throws {
        let (window, _, _, _) = scene()
        let shield = try #require(BarShield.shield(for: window))
        #expect(shield.covers(CGPoint(x: 150, y: 828), in: window, event: nil))
        // Beside the bar the page answers as ever.
        #expect(!shield.covers(CGPoint(x: 150, y: 600), in: window, event: nil))
        // The capsule's rounded end, outside its shape.
        #expect(!shield.covers(CGPoint(x: 21, y: 801), in: window, event: nil))
    }

    @Test func aSquareShapeTakesItsCorners() throws {
        // A top bar slot whose control is a button across it takes touches across its frame, so the shield does too.
        let (window, host, _, _) = scene()
        let slot = BarShieldRegion.Catcher(frame: CGRect(x: 16, y: 26, width: 44, height: 44))
        slot.square = true
        host.addSubview(slot)
        let shield = try #require(BarShield.shield(for: window))
        #expect(shield.covers(CGPoint(x: 20.4, y: 30.4), in: window, event: nil))
        slot.square = false
        #expect(!shield.covers(CGPoint(x: 20.4, y: 30.4), in: window, event: nil))
        #expect(shield.covers(CGPoint(x: 38, y: 48), in: window, event: nil))
    }

    @Test func theCirclesKeepTheirOwnGlass() throws {
        let (window, _, _, _) = scene()
        let shield = try #require(BarShield.shield(for: window))
        #expect(!shield.covers(CGPoint(x: 338, y: 828), in: window, event: nil))
    }

    @Test func aSheetOverTheBarIsNotTheBar() throws {
        let (window, _, _, _) = scene()
        let shield = try #require(BarShield.shield(for: window))
        // A presented sheet sits above the root view in the same window.
        let sheet = UIView(frame: CGRect(x: 0, y: 500, width: 400, height: 400))
        window.addSubview(sheet)
        #expect(!shield.covers(CGPoint(x: 150, y: 828), in: window, event: nil))
        sheet.removeFromSuperview()
        #expect(shield.covers(CGPoint(x: 150, y: 828), in: window, event: nil))
    }

    @Test func aHiddenBarShieldsNothing() throws {
        let (window, _, bar, _) = scene()
        let shield = try #require(BarShield.shield(for: window))
        bar.isHidden = true
        #expect(!shield.covers(CGPoint(x: 150, y: 828), in: window, event: nil))
        bar.isHidden = false
        // Gone from the window, it is forgotten.
        bar.removeFromSuperview()
        #expect(!shield.covers(CGPoint(x: 150, y: 828), in: window, event: nil))
    }
}
#endif
