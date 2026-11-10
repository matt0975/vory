import XCTest

/// #683: Stop ends a running reply. Hermes's session authority takes a Stop only for the running turn's execution;
/// against the mock with --authority the Stop named none, was refused, and the refusal was dropped, so the reply ran on.
/// Against the default mock it stops either way.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN (the mock) and HERMES_E2E_BUNDLE (the demo copy, which takes the
/// gateway by launch argument) are set.
@MainActor
final class StopUITests: XCTestCase {
    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    func testStopEndsARunningReply() throws {
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
        composer.typeText("long 30")
        let send = try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10), "no send button")
        send.tap()

        // The mock's long answer streams for about 30 s; its first words are "The nightly export".
        let streaming = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "The nightly export")).firstMatch
        XCTAssertTrue(streaming.waitForExistence(timeout: 30), "the reply never started")
        let stop = try XCTUnwrap(hittable(app.buttons.matching(NSPredicate(format: "label == %@", "Stop")), timeout: 10),
                                 "no Stop button while the reply runs")
        stop.tap()

        let interrupted = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Interrupted")).firstMatch
        let ended = interrupted.waitForExistence(timeout: 15)
        let refused = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "couldn't be stopped")).firstMatch
        print("STOP ended \(ended), refused \(refused.exists ? "'\(refused.label)'" : "none")")
        XCTAssertFalse(refused.exists, "the Stop was refused: \(refused.label)")
        XCTAssertTrue(ended, "the reply ran on after Stop")
    }
}
