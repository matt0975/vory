import XCTest

/// A PDF the gateway refuses for want of its PDF tools: the chat says so in plain words, with
/// what still works, instead of quoting the tool's error (a tester's "attachments seem to be
/// broken", #284). The demo copy stages the PDF as the chat opens (`-vory-test-stage`), since
/// the system file picker cannot be driven; the mock runs with `--no-pdf-tools`.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
final class AttachRefusalUITests: XCTestCase {
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

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    private func text(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
    }

    func testAPDFTheGatewayCannotReadIsExplained() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        guard let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("needs the demo copy (HERMES_E2E_BUNDLE), which stages the PDF by launch argument")
        }
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-vory-test-stage", "report.pdf"]
        app.launch()

        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        // The staged PDF shows over the composer (its card is a button, "PDF: <name>").
        let staged = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "report.pdf")).firstMatch
        XCTAssertTrue(staged.waitForExistence(timeout: 30), "the PDF was not staged")
        shot("attach-refusal-staged")

        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("card: summarize the report")
        let send = try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10))
        send.tap()

        // The explained refusal, not the tool's words alone: shot at once, before the reply
        // streams over it.
        let explained = text("the gateway is missing the tool it reads PDFs with")
        XCTAssertTrue(explained.firstMatch.waitForExistence(timeout: 30), "the refusal was not explained")
        shot("attach-refusal-explained")
        XCTAssertTrue(text("Pictures and text files still go through").firstMatch.exists)
        XCTAssertTrue(text("pdftoppm not installed").firstMatch.exists, "the gateway's own words are not kept")
        // The message itself still went, without the PDF.
        XCTAssertTrue(text("summarize the report").firstMatch.waitForExistence(timeout: 10))
    }
}
