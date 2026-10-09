import XCTest

/// The floating chat header over a long thread: Back, the title pill and the … circle are
/// hittable where they are drawn, and Back tapped as an element leaves the chat. XCUITest's
/// isHittable asks the app's accessibility hit test at the element's middle, the same test
/// VoiceOver's touch-to-explore makes: a thread element whose frame runs up under the header
/// (the last reply of a long chat does) and wins it there means a finger on Back hears the
/// message behind it. 1.4 (8)'s per-message groups did that to all three circles.
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock gateway).
final class HeaderHittableUITests: XCTestCase {
    private var app: XCUIApplication!
    private lazy var shotDir: URL = {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-chat-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override func setUpWithError() throws {
        continueAfterFailure = true
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

    /// Hittable within a few seconds: the header pops in and the thread lands at its end first.
    private func becomesHittable(_ e: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if e.exists, e.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return e.exists && e.isHittable
    }

    func testHeaderButtonsAreHittableOverALongThread() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        connectIfNeeded(url: url, token: token)
        let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 40), "the chat list never showed the mock's chats")
        // Every tab stays mounted, so the Home page's "Since you were here" carries the same
        // title out of sight: the hittable match is the list's row.
        let candidates = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).allElementsBoundByIndex
        if let rowButton = candidates.first(where: { $0.isHittable }) ?? candidates.min(by: { $0.frame.midY < $1.frame.midY }) {
            rowButton.tap()
        } else {
            text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let back = app.buttons["chat.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "the chat did not open")
        // The thread: the seeded history's last reply, which ends the long chat.
        let lastReply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] '4.2 GB freed'")).firstMatch
        XCTAssertTrue(lastReply.waitForExistence(timeout: 30), "the thread never showed the chat's history")
        // Past "Syncing…" and landed at the end.
        sleep(3)
        shot("header-hittable-1-chat")
        print("AX-TREE-BEGIN\n\(app.debugDescription)\nAX-TREE-END")

        let more = app.buttons["chat.more"].firstMatch
        let pill = app.buttons["chat.titlePill"].firstMatch
        for (name, e) in [("chat.back", back), ("chat.more", more), ("chat.titlePill", pill)] {
            XCTAssertTrue(e.exists, "\(name) is not in the header")
            let hit = becomesHittable(e)
            print("HEADER-HITTABLE \(name) \(hit) frame \(e.frame)")
            XCTAssertTrue(hit, "\(name) is on screen at \(e.frame) but not hittable: the accessibility hit test there finds something else")
        }

        // Back as an element, not a coordinate: XCUITest taps it only where it is hittable.
        back.tap()
        let newChat = app.buttons["chats.new"].firstMatch
        let left = becomesHittable(newChat, timeout: 10)
        if !left { shot("header-hittable-2-still-in-chat") }
        XCTAssertTrue(left, "Back did not bring the Chats list back")
    }
}
