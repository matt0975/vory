import XCTest

/// Cards far from the screen let their web views go (#24): after two cards and a run of plain
/// replies that push them off the top, no web view is left in the thread; scrolling back up
/// to them draws them again. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the
/// mock gateway answers "card" with a card, anything else with words).
final class CardsAwayUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = query.allElementsBoundByIndex.first(where: { $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    /// Types into the composer (by its identifier: once a card is in the thread, the first text
    /// view is not the composer) and sends.
    private func send(_ text: String) {
        let field = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no composer (text views: \(app.textViews.allElementsBoundByIndex.map { $0.identifier }))")
        field.tap()
        field.typeText(text)
        let send = app.buttons["composer.send"].firstMatch
        if !send.waitForExistence(timeout: 5) {
            shot("cards-no-send")
            let buttons = app.buttons.allElementsBoundByIndex.map { $0.identifier.isEmpty ? $0.label : $0.identifier }.filter { !$0.isEmpty }
            XCTFail("no send button after typing; field value: \(String(describing: field.value)); buttons: \(buttons.prefix(30))")
        }
        send.tap()
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-chat-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
        print("CHAT-SHOT \(d.appendingPathComponent("\(name).png").path)")
    }

    /// Waits until the thread shows `n` cards (each card's page holds one link; a web view is
    /// several elements to accessibility, so the links are the count), or gives up.
    private func cards(reach n: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.webViews.links.count >= n { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return app.webViews.links.count >= n
    }

    /// Waits until no web view is left in the thread, or gives up.
    private func noWebViews(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.webViews.count == 0 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return app.webViews.count == 0
    }

    func testCardsOffTheScreenLetTheirWebViewsGoAndComeBackWhenScrolledTo() throws {
        guard env != nil else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-launchTab", "chats"]
        app.launch()
        guard let row = hittable(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Disk cleanup'")), timeout: 30) else { return XCTFail("no Disk cleanup chat") }
        row.tap()

        // Two cards, each drawn (a web view each) when it arrives.
        send("card please")
        XCTAssertTrue(cards(reach: 1, timeout: 40), "the first card did not draw")
        send("card again please")
        XCTAssertTrue(cards(reach: 2, timeout: 40), "the second card did not draw (\(app.webViews.links.count) links)")
        XCTAssertGreaterThan(app.webViews.count, 0)

        // A run of plain replies pushes both cards well off the top of the screen.
        for i in 1...10 {
            send("plain line \(i), a few words so the thread grows")
            let sent = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'plain line \(i)'")).firstMatch
            XCTAssertTrue(sent.waitForExistence(timeout: 20))
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }
        // Off the screen for longer than the grace: let go.
        XCTAssertTrue(noWebViews(timeout: 20), "cards off the screen kept their web views (\(app.webViews.count))")

        // Back up to them: drawn again.
        let thread = app.scrollViews.firstMatch
        for _ in 0..<12 where app.webViews.count == 0 {
            thread.swipeDown(velocity: .fast)
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, app.webViews.count == 0 { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        XCTAssertGreaterThan(app.webViews.count, 0, "a card scrolled back to did not draw again")
    }
}
