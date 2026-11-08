import XCTest

/// What the demo shows outside the app outlives neither the app nor the demo (#632, and #392's Leave demo with a voice
/// session up). Two cases, picked by HERMES_E2E_LEFT_CASE, each a run of its own; the rig reads the app's own activity
/// lines around them (`log show`, dev.vory / activity) and keys them by the "DEMO-LEFT … at <epoch>" lines printed here.
/// - "quit": a Demo voice session to its approval card, the app sent home with the card waiting (its notification comes),
///   then quit; relaunched under `-vory-demo`, then without it: the demo's notifications read 0 delivered and 0 waiting
///   each time (`-vory-delivered-readout`), and the launch lines say how many cards the sweep ended.
/// - "leave": a Demo voice session to its card, hidden to its pill, then Settings › Leave demo: no voice screen or pill
///   comes back, and a relaunch's sweep finds no card.
/// - "warm": one launch and quit after an install, so neither case starts on the first launch of a new install; it asks
///   the system's notification question and allows it, so the quit case's card can post while away.
/// Skipped unless HERMES_E2E_LEFT_CASE is set.
@MainActor
final class DemoLeftoversUITests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func mark(_ what: String) { print(String(format: "DEMO-LEFT %@ at %.1f", what, Date().timeIntervalSince1970)) }

    private func launch(demo: Bool, askNotifications: Bool = false) {
        app = XCUIApplication()
        app.launchArguments = (demo ? ["-vory-demo"] : []) + ["-vory-delivered-readout", "-companionPromptShown", "YES", "-launchTab", "chats",
                                                             "-restore.openChat", "none", "-tabBar.showVoice", "YES"]
            + (askNotifications ? ["-vory-request-notifications"] : [])
        app.launch()
        mark("launched demo \(demo)")
    }

    /// "delivered/pending/most/read" from the readout; nil until it reads.
    private func readout() -> [Int]? {
        let r = any("debug.delivered")
        guard r.waitForExistence(timeout: 10) else { return nil }
        let p = (r.value as? String ?? "").split(separator: "/").compactMap { Int($0) }
        return p.count == 4 ? p : nil
    }

    /// The readout at 0 delivered and 0 waiting within ten seconds of a launch, its every read printed.
    private func expectNoDemoNotifications(_ when: String) {
        let end = Date().addingTimeInterval(10)
        var last: [Int]?
        repeat { last = readout(); if let l = last, l[0] == 0, l[1] == 0 { break }; pause(0.5) } while Date() < end
        print("DEMO-LEFT \(when) readout \(last.map { $0.map(String.init).joined(separator: "/") } ?? "none")")
        XCTAssertEqual(last?[0], 0, "\(when): the demo's notifications are still delivered")
        XCTAssertEqual(last?[1], 0, "\(when): the demo's notifications are still waiting")
    }

    /// From the Chats list: the mic, the voice screen, and the scripted line to its approval card. The system's
    /// notification question, if it comes on the demo's first message, is allowed (the demo's own, #501).
    private func voiceToTheCard() {
        let mic = app.buttons.matching(identifier: "chats.voice").firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 30), "no mic on the Chats list")
        mic.tap()
        XCTAssertTrue(app.buttons["End voice mode"].firstMatch.waitForExistence(timeout: 30), "the voice screen did not open")
        mark("voice on")
        let allowCard = app.buttons["Allow once"].firstMatch
        let end = Date().addingTimeInterval(90)
        while !allowCard.exists, Date() < end {
            let alert = springboard.alerts.firstMatch
            if alert.exists, alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); mark("notifications allowed") }
            pause(0.5)
        }
        XCTAssertTrue(allowCard.exists, "no approval card in the demo's voice mode")
        mark("card up")
        pause(1.5)
    }

    func testDemoLeftovers() throws {
        guard let leftCase = ProcessInfo.processInfo.environment["HERMES_E2E_LEFT_CASE"], !leftCase.isEmpty else {
            throw XCTSkip("HERMES_E2E_LEFT_CASE not set")
        }
        continueAfterFailure = true
        switch leftCase {
        case "warm":
            // The system's notification question, asked at launch (the app's DEBUG -vory-request-notifications) and
            // allowed here, so the quit case's card can post while away; a fresh install that never asks fails here.
            launch(demo: true, askNotifications: true)
            var allowed = false
            let end = Date().addingTimeInterval(15)
            while !allowed, Date() < end {
                let alert = springboard.alerts.firstMatch
                if alert.exists, alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); allowed = true; mark("notifications allowed") }
                pause(0.5)
            }
            XCTAssertTrue(allowed, "warm: the system's notification question never came, so the demo can't post while away")
            pause(3); app.terminate(); mark("warm done")
        case "quit":
            launch(demo: true)
            voiceToTheCard()
            // Away with the card waiting: its notification comes (the readout's "most" counts it), then the app quits.
            XCUIDevice.shared.press(.home)
            pause(8)
            app.activate()
            let most = readout()?[2] ?? -1
            print("DEMO-LEFT away most \(most)")
            XCTAssertGreaterThanOrEqual(most, 1, "the demo's approval posted no notification while away")
            XCUIDevice.shared.press(.home)
            pause(2)
            mark("quit")
            app.terminate()
            pause(2)
            launch(demo: true)
            expectNoDemoNotifications("relaunch under -vory-demo")
            pause(3); app.terminate(); mark("relaunch 1 done")
            pause(2)
            launch(demo: false)
            expectNoDemoNotifications("relaunch without the demo")
            pause(3); app.terminate(); mark("relaunch 2 done")
        case "leave":
            launch(demo: true)
            voiceToTheCard()
            let hide = app.buttons["Hide voice mode"].firstMatch
            XCTAssertTrue(hide.waitForExistence(timeout: 5), "no Hide button")
            hide.tap(); pause(1.5)
            let back = app.buttons["chat.back"].firstMatch
            if back.waitForExistence(timeout: 5) { back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5) }
            // Settings from the tab strip. On the closed Duo the strip stands down the side and its foot can sit at the
            // screen's edge: the tab once it can be tapped, else its part on screen, tapped by coordinate.
            let settings = app.buttons["tab.settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "no Settings tab")
            let window = app.windows.firstMatch.frame
            var hittable = false
            let until = Date().addingTimeInterval(5)
            repeat { hittable = settings.isHittable; if !hittable { pause(0.5) } } while !hittable && Date() < until
            print("DEMO-LEFT settings tab \(settings.frame) window \(window) hittable \(hittable)")
            if hittable {
                settings.tap()
            } else {
                let part = settings.frame.intersection(window)
                XCTAssertFalse(part.isNull || part.height < 12 || part.width < 12, "the Settings tab is off the screen (\(settings.frame) in \(window))")
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: part.midX, dy: part.midY)).tap()
                mark("settings by its part on screen")
            }
            let leave = app.buttons["settings.leaveDemo"].firstMatch
            XCTAssertTrue(leave.waitForExistence(timeout: 10), "no Leave demo")
            mark("leave")
            leave.tap()
            for t in [1.0, 4.0, 10.0] {
                pause(t)
                let screen = app.buttons["End voice mode"].firstMatch.exists
                let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Voice mode is on'")).firstMatch.exists
                print("DEMO-LEFT after leave screen \(screen) pill \(pill)")
                XCTAssertFalse(screen || pill, "voice mode is still up after Leave demo")
            }
            mark("left")
            app.terminate()
            pause(2)
            launch(demo: false)
            expectNoDemoNotifications("relaunch after leaving")
            pause(3); app.terminate(); mark("relaunch done")
        default:
            XCTFail("no such case: \(leftCase)")
        }
    }
}
