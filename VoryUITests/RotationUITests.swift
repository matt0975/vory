import XCTest

/// A tester's exact steps: a chat open, the keyboard up, the phone turned to landscape. The app
/// must lay out for the new width and stay responsive; it hung and was killed on 1.3 (3).
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock gateway).
final class RotationUITests: XCTestCase {
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

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
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

    @discardableResult
    private func scrollUntilVisible(_ element: XCUIElement, swipes: Int = 6) -> Bool {
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp(velocity: .slow)
        }
        return element.exists
    }

    private func dismissKeyboard() {
        if app.keyboards.buttons["Return"].firstMatch.exists { app.keyboards.buttons["Return"].firstMatch.tap() }
        else if app.keyboards.buttons["return"].firstMatch.exists { app.keyboards.buttons["return"].firstMatch.tap() }
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
        dismissKeyboard()
        let test = app.buttons["gateway.test"].firstMatch
        XCTAssertTrue(scrollUntilVisible(test), "Test Connection button never came into view")
        test.tap()
        let wsResult = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'gateway.ready received'")).firstMatch
        let deadline = Date().addingTimeInterval(60)
        while !wsResult.exists, Date() < deadline { app.swipeUp(velocity: .slow); _ = wsResult.waitForExistence(timeout: 2) }
        XCTAssertTrue(wsResult.exists, "WebSocket leg did not pass")
        app.buttons["gateway.save"].firstMatch.tap()
    }

    func testLandscapeWithTheKeyboardUpStaysResponsive() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        connectIfNeeded(url: url, token: token)
        let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 40), "the chat list never showed the mock's chats")
        shot("rotation-0-list")
        // Every tab stays mounted, so the Home page's "Since you were here" carries the same
        // title out of sight: the hittable match is the list's row.
        let candidates = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).allElementsBoundByIndex
        if let rowButton = candidates.first(where: { $0.isHittable }) ?? candidates.min(by: { $0.frame.midY < $1.frame.midY }) {
            rowButton.tap()
        } else {
            text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let back = app.buttons["chat.back"].firstMatch
        if !back.waitForExistence(timeout: 15) {
            shot("rotation-0-after-row-tap")
            let kinds = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).allElementsBoundByIndex
                .map { "\($0.elementType.rawValue)@\(Int($0.frame.midX)),\(Int($0.frame.midY))" }.joined(separator: " ")
            print("ROW-TYPES \(kinds) text=\(text.frame)")
            // A tap at the row's place on the screen, the way a finger lands.
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: text.frame.midX, dy: text.frame.midY)).tap()
            _ = back.waitForExistence(timeout: 15)
        }
        XCTAssertTrue(back.exists, "the chat did not open")
        // The composer is a UITextView inside a representable; it may surface as any element type.
        let field = app.descendants(matching: .any).matching(identifier: "composer.text").firstMatch
        if !field.waitForExistence(timeout: 20) { shot("rotation-0-no-composer") }
        XCTAssertTrue(field.exists, "no composer")
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 10) { shot("rotation-0-no-keyboard") }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "no keyboard")
        shot("rotation-1-portrait-keyboard")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4)
        shot("rotation-2-landscape-keyboard")
        // Alive and laid out: the back button is there and takes a tap within a few seconds.
        XCTAssertEqual(app.state, .runningForeground, "the app left the foreground after rotating")
        XCTAssertTrue(back.waitForExistence(timeout: 8), "no header after rotating")
        app.typeText("ok")
        sleep(1)
        shot("rotation-3-landscape-typed")
        XCUIDevice.shared.orientation = .portrait
        sleep(3)
        shot("rotation-4-portrait-again")
        XCTAssertEqual(app.state, .runningForeground)
        // Back where it belongs on the portrait screen. (Not `isHittable`: XCUITest asks the
        // app's elements from the last to the first, so in a long chat the reply that runs up
        // under the floating header answers for Back's point; a finger, and VoiceOver, which
        // asks from the first, get Back.)
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(back.exists && window.contains(CGPoint(x: back.frame.midX, y: back.frame.midY)) && back.frame.minY < window.height / 4,
                      "the back button is not on screen after rotating back (\(back.frame) in \(window))")
        // Still taking input: the field keeps what was typed and takes more.
        app.typeText("!")
        XCTAssertEqual(app.state, .runningForeground, "the app left the foreground after typing")
        // And still answering a tap: Back, tapped where it is drawn, leaves the chat.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: back.frame.midX, dy: back.frame.midY)).tap()
        XCTAssertTrue(hittableNewChat(), "Back did not leave the chat after rotating back")
    }

    /// The compose circle is on screen and takes a tap: the chat list is in front.
    private func hittableNewChat() -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if app.buttons.matching(identifier: "chats.new").allElementsBoundByIndex.contains(where: { $0.isHittable }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }
}
