import XCTest

/// Drives the real UI against a gateway. Needs HERMES_E2E_URL / HERMES_E2E_TOKEN in the runner's
/// environment (e.g. `xcrun simctl spawn <udid> launchctl setenv …` or TEST_RUNNER_ variables).
/// Screenshots are written to the runner's tmp directory (path printed) and attached to the result bundle.
final class VoryUITests: XCTestCase {
    private var app: XCUIApplication!
    private lazy var shotDir: URL = {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-ui-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        try? s.pngRepresentation.write(to: shotDir.appendingPathComponent("\(name).png"))
        print("UI-SHOT \(shotDir.appendingPathComponent("\(name).png").path)")
    }

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    func testOnboardingConnectChatAndSettings() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        shot("01-onboarding")
        // A fresh install opens on the first screen (Get Started / Restore from iCloud), then the
        // tour; both stand between it and the gateway form.
        let start = app.buttons["onboarding.getStarted"].firstMatch
        if start.waitForExistence(timeout: 10) { start.tap() }
        let skip = app.buttons["onboarding.skip"].firstMatch
        if skip.waitForExistence(timeout: 5) { skip.tap() }
        let add = app.buttons["onboarding.addGateway"].firstMatch
        if add.waitForExistence(timeout: 10) {
            add.tap()
            let name = app.textFields["gateway.name"].firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 10))
            name.tap(); name.typeText("Local")
            let urlField = app.textFields["gateway.url"].firstMatch
            urlField.tap(); urlField.typeText(url)
            let tokenField = app.secureTextFields["gateway.sessionToken"].firstMatch
            XCTAssertTrue(tokenField.waitForExistence(timeout: 5))
            tokenField.tap(); tokenField.typeText(token)
            shot("02-form-filled")
            let test = app.buttons["gateway.test"].firstMatch
            XCTAssertTrue(test.waitForExistence(timeout: 5))
            test.tap()
            let save = app.buttons["gateway.save"].firstMatch
            let exp = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: save)
            wait(for: [exp], timeout: 60)
            shot("03-test-passed")
            save.tap()
        } else {
            print("UI-NOTE gateway already saved in the Keychain; continuing from the Chats tab")
        }

        // Chats list
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 30))
        let newChatEnabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)
        wait(for: [newChatEnabled], timeout: 60)
        sleep(2)
        shot("04-chats")
        newChat.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "composer.text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap(); composer.typeText("Reply with exactly the single word: pong")
        shot("05-composer")
        app.buttons["composer.send"].firstMatch.tap()
        // Wait for either a streamed reply or the gateway's error surface.
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'pong' OR label CONTAINS[c] 'provider' OR label CONTAINS[c] 'failed'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 120), "no reply or error surfaced in the transcript")
        sleep(1)
        shot("06-conversation")

        // Settings
        // iPhone: bottom tab bar; iPad: top segmented tab control. Both expose a "Settings" button.
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        shot("07-settings")
        app.staticTexts["Tools"].firstMatch.tap()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 30))
        shot("08-tools")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["Config"].firstMatch.tap()
        // "general" is the first category; approvals.* is further down and off-screen on a long list.
        XCTAssertTrue(app.staticTexts["model"].firstMatch.waitForExistence(timeout: 45))
        shot("09-config")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["API Keys & Environment"].firstMatch.tap()
        sleep(3)
        shot("10-env")
    }
}
