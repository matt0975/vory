import XCTest

/// #682: a new chat's first message, typed in the composer and sent, is answered. Hermes's session authority admits a
/// prompt.submit only with a non-empty submission_id or input_id; against the mock with --authority the message was
/// refused while it carried neither. Against the default mock it's answered either way.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN (the mock) and HERMES_E2E_BUNDLE (the demo copy, which takes the
/// gateway by launch argument) are set.
@MainActor
final class FirstMessageUITests: XCTestCase {
    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    func testANewChatsFirstMessageIsAnswered() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        guard let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("needs the demo copy (HERMES_E2E_BUNDLE), which takes the gateway by launch argument")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats"]
        app.launch()

        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40), "the app did not come up")
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "no composer in the new chat")
        composer.tap()
        composer.typeText("short link")
        let send = try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10), "no send button")
        send.tap()

        // The mock's answer to "short link" begins "The export finished".
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "The export finished")).firstMatch
        let answered = reply.waitForExistence(timeout: 30)
        let refused = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "invalid_params")).firstMatch
        print("FIRST-MESSAGE answered \(answered), refused row \(refused.exists ? "'\(refused.label)'" : "none")")
        XCTAssertFalse(refused.exists, "the message was refused: \(refused.label)")
        XCTAssertTrue(answered, "no reply in 30 s")
    }
}
