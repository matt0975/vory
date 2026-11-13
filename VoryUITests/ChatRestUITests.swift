import XCTest

/// Feedback on 1.5 (21): "going into a chat and pressing/sliding on the white space above the message
/// bar gives this message a weird jump". A chat opened rests with its last row the designed margin
/// over the composer, and a small touch-drag in the band between them moves the thread no more
/// than the finger: on a short chat, on one about a screen long and on a long one. (The simulator
/// rests at the end on all three, before the fix too: the phone is where it came to rest past it.)
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=com.vorantx.vory.demo
/// drives the demo copy.
@MainActor
final class ChatRestUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func launch(url: String, token: String) {
        let args = ["-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "light"]
            + (ProcessInfo.processInfo.environment["HERMES_E2E_ARGS"] ?? "").split(separator: " ").map(String.init)
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
    private func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)) }

    /// The bottom edge of the thread's lowest row: every row is an element named "thread.…".
    private func lowestRowBottom() -> CGFloat? {
        guard let snap = try? app.snapshot() else { return nil }
        var bottom: CGFloat?
        func walk(_ s: XCUIElementSnapshot) {
            if s.identifier.hasPrefix("thread."), s.frame.height > 0 { bottom = max(bottom ?? -.infinity, s.frame.maxY); return }
            for c in s.children { walk(c) }
        }
        walk(snap)
        return bottom
    }

    /// The chat at rest after it opens, then a 4 pt touch-drag down in the band over the composer.
    private func check(_ name: String) {
        pause(3)
        let dock = app.otherElements["chat.dock"].firstMatch
        guard let rest = lowestRowBottom() else { XCTFail("\(name): no rows"); return }
        let gap = dock.frame.minY - rest
        print("CHAT-REST \(name) last row \(rest) dock \(dock.frame.minY) gap \(gap)")
        shot("\(name)-rest")
        // The thread's 8 pt margin over the dock: 8 on the phone, 18 on the simulator (where the
        // dock's frame reads 10 pt lower). Never under the composer, never a band over it.
        XCTAssertTrue((4...24).contains(gap), "\(name): at rest the last row ends \(Int(gap)) pt over the composer, not the designed margin")
        // The band between the last row and the composer, or 6 pt over the composer when there is
        // none to speak of.
        let y = max(rest + 2, dock.frame.minY - 6)
        at(app.frame.midX + 60, y).press(forDuration: 0.08, thenDragTo: at(app.frame.midX + 60, y + 4), withVelocity: .slow, thenHoldForDuration: 0.1)
        pause(1.5)
        guard let after = lowestRowBottom() else { XCTFail("\(name): no rows after the touch"); return }
        print("CHAT-REST \(name) after the touch \(after) moved \(after - rest)")
        shot("\(name)-touched")
        XCTAssertLessThanOrEqual(abs(after - rest), 5, "\(name): a 4 pt touch-drag over the composer moved the last row \(Int(after - rest)) pt")
    }

    private func open(_ title: String) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "no \(title) row")
        pause(1)
        row.tap()
        XCTAssertTrue(any("chat.dock").waitForExistence(timeout: 20), "\(title) did not open")
    }

    /// Shorter than the screen: it stays at the bottom, over the composer, not pulled to the top.
    func testAShortChatRestsAndHolds() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        open("Bot Chat")
        check("short")
    }

    func testALongChatRestsAndHolds() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        open("Disk cleanup")
        check("long")
    }

    /// About a screen: a new chat with a short marathon, opened again from the list.
    func testAOneScreenChatRestsAndHolds() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch.waitForExistence(timeout: 40), "no chat rows")
        any("chats.new").tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "no composer")
        composer.tap(); composer.typeText("marathon 6"); pause(0.5)
        any("composer.send").tap()
        XCTAssertTrue(app.buttons["Dictate"].firstMatch.waitForExistence(timeout: 60), "the reply did not end")
        pause(1)
        any("chat.back").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(2)
        open("marathon")
        check("one-screen")
    }

    /// #172 (a tester on build 21: "The contents keep scrolling below the input box"): a short new
    /// chat whose turn's only output is reasoning with its stats footer (the mock's "power
    /// rankings", where the gateway files the whole answer as reasoning). At rest the last row,
    /// the footer, sits over the composer with the designed margin, as the turn ends and when the
    /// chat is opened again, and a small drag in the band does not move it.
    func testAReasoningOnlyReplyRestsAndHolds() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch.waitForExistence(timeout: 40), "no chat rows")
        any("chats.new").tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "no composer")
        composer.tap(); composer.typeText("open-weight power rankings, please"); pause(0.5)
        any("composer.send").tap()
        XCTAssertTrue(app.buttons["Dictate"].firstMatch.waitForExistence(timeout: 60), "the reply did not end")
        check("reasoning-only")
        any("chat.back").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(2)
        open("power rankings")
        check("reasoning-only-reopened")
    }
}
