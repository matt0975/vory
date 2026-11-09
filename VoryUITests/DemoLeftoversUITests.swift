import XCTest

/// What the demo shows outside the app outlives neither the app nor the demo (#632, and #392's Leave demo with a voice
/// session up). Two cases, picked by HERMES_E2E_LEFT_CASE, each a run of its own; the rig reads the app's own activity
/// lines around them (`log show`, dev.vory / activity) and keys them by the "DEMO-LEFT … at <epoch>" lines printed here.
/// - "quit": a Demo voice session to its approval card, hidden; then a plain demo turn sent in another chat and the app
///   sent home at once, so the turn's end is a notification posted while away; then quit from the background; relaunched
///   under `-vory-demo`, then without it: the demo's notifications read 0 delivered and 0 waiting each time
///   (`-vory-delivered-readout`), and the launch lines say how many cards and notifications the sweep ended.
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
    /// A still of the screen, kept with the result and written as `<name>.png` into HERMES_E2E_SHOTS when it names a folder.
    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        guard let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty else { return }
        let d = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
    }

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

    /// Voice mode hidden to its pill. Hide by its own tap when it stands whole on the screen; else at the middle of its
    /// part on screen (on the closed Duo of 50 the voice screen's top row sits at the top edge, Hide cut in half). Its
    /// frame and the window's are printed, a still is kept after, and the voice screen must be gone.
    private func hideVoice(_ when: String) {
        let hide = app.buttons["Hide voice mode"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "no Hide button")
        let window = app.windows.firstMatch.frame
        print("DEMO-LEFT hide \(when) \(hide.frame) window \(window) hittable \(hide.isHittable)")
        if window.contains(hide.frame) {
            hide.tap()
        } else {
            let part = hide.frame.intersection(window)
            if part.isNull || part.width < 8 || part.height < 8 {
                XCTFail("the Hide button is off the screen (\(hide.frame) in \(window))")
            } else {
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: part.midX, dy: part.midY)).tap()
                mark("hide \(when) by its part on screen")
            }
        }
        pause(1.5)
        shot("after-hide-\(when)")
        XCTAssertFalse(app.buttons["End voice mode"].firstMatch.exists, "the voice screen is still up after Hide (\(when)); the still is after-hide-\(when)")
    }

    /// Out of the chat to the list. A touch at Back's centre, not the element tap: XCTest can't always compute Back's
    /// activation point here, while a touch, the app's hit test and VoiceOver all reach it (DemoNotificationsUITests).
    private func back() {
        let back = app.buttons["chat.back"].firstMatch
        if back.waitForExistence(timeout: 5) { back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5) }
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
            // The voice session's own card (#632's card half): voice mode to its approval card, in front, then hidden.
            voiceToTheCard()
            hideVoice("quit")
            // Then a plain demo turn in another chat, the app sent home as it is sent: the turn runs on while away (the
            // app holds itself up for a running turn, AwayWatch) and its end is a local notification there
            // (LocalNotifier.turnFinished), which the next launch's sweep must take (#632's notification half). A turn's
            // end, or a card, that comes in front posts none.
            back()
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Packing list' AND NOT (identifier BEGINSWITH 'chat.')")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20), "no demo chat to send in")
            row.tap()
            let field = any("composer.text")
            XCTAssertTrue(field.waitForExistence(timeout: 20), "no composer")
            field.tap()
            field.typeText("hello")
            let send = app.buttons["composer.send"].firstMatch
            let ready = Date().addingTimeInterval(30)
            while !(send.exists && send.isEnabled && send.isHittable), Date() < ready { pause(0.3) }
            send.tap()
            XCUIDevice.shared.press(.home)
            mark("away")
            // Quit while still away: back in front, the chat clears its own notifications as it shows (ConversationView),
            // and the sweep this case is for (#632) is of what a demo closed in the background left behind.
            pause(15)
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
            hideVoice("leave")
            back()
            // Settings from the tab strip. Every "tab.settings" match is listed with its frame and whether it can be tapped,
            // and the screen kept as a still, before one is chosen: on the closed Duo the first match sat past the screen's
            // edge (dl632 tags a and b). The first that can be tapped is; else the first's part on screen, by coordinate;
            // with none on screen the case fails here, plainly, the still showing why.
            let tabs = app.buttons.matching(identifier: "tab.settings")
            XCTAssertTrue(tabs.firstMatch.waitForExistence(timeout: 10), "no Settings tab")
            let window = app.windows.firstMatch.frame
            var all = tabs.allElementsBoundByIndex
            let until = Date().addingTimeInterval(5)
            while !all.contains(where: { $0.isHittable }), Date() < until { pause(0.5); all = tabs.allElementsBoundByIndex }
            shot("leave-before-settings")
            for (i, tab) in all.enumerated() {
                print("DEMO-LEFT settings tab \(i + 1)/\(all.count) \(tab.frame) window \(window) hittable \(tab.isHittable)")
            }
            if let tab = all.first(where: { $0.isHittable }) {
                tab.tap()
            } else {
                let part = all.first.map { $0.frame.intersection(window) } ?? .null
                guard !part.isNull, part.width >= 12, part.height >= 12 else {
                    XCTFail("no Settings tab on the screen (\(all.map { "\($0.frame)" }.joined(separator: ", ")) in \(window)); the still is leave-before-settings")
                    return
                }
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
