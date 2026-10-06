import XCTest

/// A table wider than the bubble: it scrolls sideways inside its card (and the drag moves the
/// table, not the thread) and opens full screen from its corner button, where it can be copied
/// as Markdown; a long press keeps the reply's own menu. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the
/// mock gateway answers a prompt starting "wide" with markdown reasoning and a six-column table).
///
/// HERMES_E2E_BUNDLE=com.vorantx.vory.demo drives the demo copy instead (Tools/dev/
/// make-demo-app-sim.sh), pointed at the gateway by launch argument: nothing saved on the
/// simulator is used or changed. HERMES_E2E_SHOTS names a folder for the screenshots.
final class TableRenderUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"].flatMap { $0.isEmpty ? nil : $0 }
        let d = folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-chat-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
        print("CHAT-SHOT \(d.appendingPathComponent("\(name).png").path)")
    }

    private func waitForText(_ fragment: String, timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch.waitForExistence(timeout: timeout)
    }

    private func connectIfNeeded(url: String, token: String) {
        let start = app.buttons["onboarding.getStarted"].firstMatch
        let skip = app.buttons["onboarding.skip"].firstMatch
        let add = app.buttons["onboarding.addGateway"].firstMatch
        guard start.waitForExistence(timeout: 40) || skip.exists || add.exists else { return }
        if start.exists { start.tap() }
        if skip.waitForExistence(timeout: 10) { skip.tap() }
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let name = app.textFields["gateway.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("Workshop")
        let urlField = app.textFields["gateway.url"].firstMatch
        urlField.tap(); urlField.typeText(url)
        let tokenField = app.secureTextFields["gateway.sessionToken"].firstMatch
        XCTAssertTrue(tokenField.waitForExistence(timeout: 5))
        tokenField.tap(); tokenField.typeText(token)
        if app.keyboards.buttons["Return"].firstMatch.exists { app.keyboards.buttons["Return"].firstMatch.tap() }
        let test = app.buttons["gateway.test"].firstMatch
        for _ in 0..<6 where !(test.exists && test.isHittable) { app.swipeUp(velocity: .slow) }
        test.tap()
        let wsResult = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'gateway.ready received'")).firstMatch
        let deadline = Date().addingTimeInterval(60)
        while !wsResult.exists, Date() < deadline { app.swipeUp(velocity: .slow); _ = wsResult.waitForExistence(timeout: 2) }
        XCTAssertTrue(wsResult.exists, "WebSocket leg did not pass")
        app.buttons["gateway.save"].firstMatch.tap()
    }

    func testAWideTableScrollsInItsCardAndOpensFullScreen() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES"]
            app.launch()
        } else {
            app = XCUIApplication()
            app.launch()
            connectIfNeeded(url: url, token: token)
        }

        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("wide table of the log hosts, please")
        app.buttons["composer.send"].firstMatch.tap()
        XCTAssertTrue(waitForText("fills in about three weeks", timeout: 60), "the reply never finished")
        // The keyboard down (the thread dismisses it interactively: drag from above it into it),
        // so the bubble has the screen.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        sleep(2)
        shot("tables-1-bubble")

        // The table is wider than the bubble: its last column starts off the card.
        let first = app.staticTexts["Rank"].firstMatch
        let last = app.staticTexts["Health"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        let lastBefore = last.frame
        XCTAssertGreaterThan(lastBefore.maxX, window.maxX, "a six-column table should run past the screen")

        // The whole accessibility tree read (what VoiceOver does): a wide table once took the
        // Mac app down this way.
        XCTAssertFalse(app.debugDescription.isEmpty)
        XCTAssertTrue(app.state == .runningForeground, "reading the accessibility tree took the app down")

        // A sideways drag on the table scrolls it, not the thread.
        let cell = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Disk:'")).firstMatch
        XCTAssertTrue(cell.exists)
        let firstBefore = first.frame
        cell.swipeLeft(velocity: .slow)
        sleep(1)
        XCTAssertLessThan(first.frame.minX, firstBefore.minX - 40, "the table did not scroll sideways")
        XCTAssertLessThan(last.frame.maxX, lastBefore.maxX - 40)
        shot("tables-2-scrolled")

        // Full screen from the card's corner: every column at once, no line cap.
        let open = app.buttons["Open the table full screen"].firstMatch
        for _ in 0..<4 where !(open.exists && open.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the table sheet did not open")
        sleep(1)
        XCTAssertTrue(app.navigationBars["Table"].firstMatch.exists)
        shot("tables-3-sheet")
        XCTAssertTrue(app.buttons["Copy as Markdown"].firstMatch.exists, "no Copy as Markdown on the table sheet")
        done.tap()
        sleep(1)

        // A long press on the table is the reply's menu, not one of the table's own.
        let header = app.staticTexts["Host / Role"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        header.press(forDuration: 1.2)
        sleep(1)
        shot("tables-4-menu")
        XCTAssertFalse(app.buttons["Open Table"].firstMatch.exists, "the table took over the reply's menu")
    }
}
