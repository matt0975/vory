import XCTest

/// A model that sends its whole answer as reasoning (as some models do after a web search): the
/// answer shows as the bot's reply with a real table, not as a "Reasoning" card of raw markdown,
/// and it is still the reply after the app is relaunched and the chat reopened from history.
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock gateway answers a prompt
/// with "power rankings" in it this way). HERMES_E2E_BUNDLE=com.vorantx.vory.demo drives the
/// demo copy, pointed at the gateway by launch argument.
final class ReasoningReplyUITests: XCTestCase {
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

    private func launch(url: String, token: String) {
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES"]
        } else {
            app = XCUIApplication()
        }
        app.launch()
    }

    private func cell(_ fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
    }

    private var reasoningCards: Int {
        app.buttons.matching(NSPredicate(format: "label == 'Show reasoning' OR label == 'Hide reasoning'")).count
    }

    /// A chat the mock gateway always lists (chats made during a run are not in its list), so
    /// the same chat can be reopened after a relaunch.
    private func openListedChat() {
        // Every tab page is mounted: the row to tap is the one on screen.
        let rows = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Weekly dependency audit"))
        let deadline = Date().addingTimeInterval(40)
        var row: XCUIElement?
        while row == nil, Date() < deadline {
            row = rows.allElementsBoundByIndex.first { $0.isHittable }
            if row == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        }
        guard let row else { shot("listed-chat-missing"); return XCTFail("the listed chat is not on the chats page") }
        row.tap()
        if !app.textViews["composer.text"].firstMatch.waitForExistence(timeout: 30) { shot("listed-chat-not-open"); XCTFail("the chat did not open") }
        sleep(3)
    }

    func testAnAnswerSentAsReasoningIsTheReplyWithATable() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        launch(url: url, token: token)
        openListedChat()
        let cardsBefore = reasoningCards

        let composer = app.textViews["composer.text"].firstMatch
        composer.tap()
        composer.typeText("power rankings of the AI labs, with a table")
        app.buttons["composer.send"].firstMatch.tap()

        // The table's cells, as a table: a header cell and body cells that read "header: value".
        XCTAssertTrue(cell("Model Three Max").waitForExistence(timeout: 60), "the answer never showed")
        sleep(3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        sleep(1)
        shot("reasoning-only-live")
        XCTAssertTrue(app.staticTexts["Superpower"].firstMatch.exists, "the table's header is not drawn as a table")
        XCTAssertTrue(cell("Lab / Model:").exists, "the table's cells are not drawn as a table")
        XCTAssertFalse(cell("|---|").exists, "raw table markdown on screen")
        // No Reasoning card repeating the answer once the turn is over.
        XCTAssertEqual(reasoningCards, cardsBefore, "the answer is in a Reasoning card")

        // History: relaunched, the chat reopened from the gateway's stored rows (content empty,
        // the answer in reasoning) still shows the answer as the reply.
        app.terminate()
        launch(url: url, token: token)
        openListedChat()
        XCTAssertTrue(cell("Model Three Max").waitForExistence(timeout: 40), "the answer is gone after a relaunch")
        shot("reasoning-only-history")
        XCTAssertTrue(app.staticTexts["Superpower"].firstMatch.exists)
        XCTAssertFalse(cell("|---|").exists, "raw table markdown on screen after a relaunch")
        XCTAssertEqual(reasoningCards, cardsBefore, "the reopened answer is in a Reasoning card")
    }

    func testRealThinkingKeepsItsCardAboveTheAnswer() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        launch(url: url, token: token)
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("think it through: which log host fills first?")
        app.buttons["composer.send"].firstMatch.tap()
        let reasoning = app.buttons["Show reasoning"].firstMatch
        XCTAssertTrue(reasoning.waitForExistence(timeout: 60), "real thinking lost its card")
        XCTAssertTrue(cell("covers the 30-day audit window").waitForExistence(timeout: 30), "the reply never finished")
        sleep(2)
        shot("thinking-card")
        // Opened, the thinking reads as markdown above a reply that stays whole.
        // The keyboard down and the card out from under the floating header: with the software
        // keyboard up the thread sits at its end and the header covers the card's top, so a tap
        // there lands on the bot's pill.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        sleep(1)
        func headerCard() -> XCUIElement? {
            app.buttons.matching(NSPredicate(format: "label == 'Show reasoning'")).allElementsBoundByIndex.first { $0.isHittable }
        }
        for _ in 0..<4 where (headerCard()?.frame.minY ?? 0) < 140 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
            sleep(1)
        }
        // The one on screen: every tab page is mounted, so the first match can be another copy.
        try XCTUnwrap(headerCard(), "no Reasoning card on screen").tap()
        sleep(2)
        shot("thinking-card-open")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Hide reasoning'")).allElementsBoundByIndex.contains { $0.isHittable }, "the Reasoning card did not open")
        XCTAssertTrue(cell("so I left it alone").exists, "the reply under the open card is not whole")
        XCTAssertTrue(app.state == .runningForeground)
    }
}
