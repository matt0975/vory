import XCTest

/// A link in an HTML card leaves for the browser and the card stays on its own document (it
/// used to load the link's page inside the chat). Skipped unless HERMES_E2E_URL /
/// HERMES_E2E_TOKEN are set (the mock gateway, whose "card" reply holds a link).
final class CardLinkUITests: XCTestCase {
    private var app: XCUIApplication!
    private lazy var shotDir: URL = {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-chat-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-launchTab", "chats"]
        app.launch()
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        try? s.pngRepresentation.write(to: shotDir.appendingPathComponent("\(name).png"))
        print("CHAT-SHOT \(shotDir.appendingPathComponent("\(name).png").path)")
    }

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

    func testALinkInACardOpensOutsideAndTheCardStays() throws {
        guard env != nil else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        guard let row = hittable(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Disk cleanup'")), timeout: 30) else { return XCTFail("no Disk cleanup chat") }
        row.tap()
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("card please")
        app.buttons["composer.send"].firstMatch.tap()
        // The mock answers with a card that ends in a link.
        let link = app.webViews.links.firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 40), "no link in the card")
        let heading = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS '/var/log'")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "the card's own heading is not there")
        shot("card-before-tap")
        link.tap()
        // The browser comes up (the app goes behind it), and the card keeps its own page.
        let wentOutside = app.wait(for: .runningBackground, timeout: 8)
        app.activate()
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "the card navigated away from its own document")
        XCTAssertFalse(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Example Domain'")).firstMatch.exists, "the link's page loaded inside the card")
        shot("card-after-tap")
        XCTAssertTrue(wentOutside, "the link did not open outside the app")
    }
}
