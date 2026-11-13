import XCTest

/// The Chats tab on a wide window (an iPad, the open iPhone Duo): the list stands beside the
/// open chat and the tab bar stays; the same view collapses to the pushed chat on a phone.
/// Run on an iPad simulator (regular width). Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN
/// are set (the mock gateway).
final class SplitLayoutUITests: XCTestCase {
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
        // On a tall window the whole form is in view and nothing scrolls; a swipe there could
        // land on a row, so only swipe while the button sits in the lower half.
        while !wsResult.exists, Date() < deadline {
            if test.exists, test.frame.midY > app.windows.firstMatch.frame.height * 0.5 { app.swipeUp(velocity: .slow) }
            _ = wsResult.waitForExistence(timeout: 2)
        }
        if !wsResult.exists { shot("split-0-connection-test") }
        XCTAssertTrue(wsResult.exists, "WebSocket leg did not pass")
        app.buttons["gateway.save"].firstMatch.tap()
    }

    private func becomesHittable(_ e: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if e.exists, e.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return e.exists && e.isHittable
    }

    /// The hittable list row for a chat title (Home carries the same title out of sight).
    private func row(_ title: String) -> XCUIElement? {
        let candidates = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).allElementsBoundByIndex
        return candidates.first(where: { $0.isHittable }) ?? candidates.min(by: { $0.frame.midY < $1.frame.midY })
    }

    /// A regular-width window that is upright and under 700 pt wide (the open Duo in portrait,
    /// 669 pt): one column, the chat pushed over the list, as on a phone (2026-10-10),
    /// never the system's dimmed list overlay. Runs where the window is that shape; skipped
    /// elsewhere.
    func testOneColumnOnANarrowUprightWindow() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        XCUIDevice.shared.orientation = .portrait
        connectIfNeeded(url: url, token: token)
        let frame = app.windows.firstMatch.frame
        guard frame.width < 700, frame.height > frame.width, frame.width > 500 else { throw XCTSkip("not a narrow upright window (\(Int(frame.width))x\(Int(frame.height)))") }
        XCTAssertFalse(app.staticTexts["No chat selected"].firstMatch.exists, "a placeholder column on a narrow upright window")
        let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 40), "the chat list never showed the mock's chats")
        shot("narrow-upright-1-list")
        if let r = row("Disk cleanup") { r.tap() } else { text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let back = app.buttons["chat.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "the chat did not open")
        sleep(2)
        shot("narrow-upright-2-chat")
        XCTAssertLessThan(back.frame.minX, 80, "the chat does not cover the window: Back sits at \(Int(back.frame.minX))")
        XCTAssertFalse(row("Weekly dependency audit")?.isHittable == true, "the list is still beside (or over) the chat")
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.isHittable, "the composer is hidden (under the bar?)")
    }

    func testTheListStaysBesideTheOpenChatOnAWideWindow() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        XCUIDevice.shared.orientation = .landscapeLeft
        connectIfNeeded(url: url, token: token)
        let wide = app.windows.firstMatch.frame.width >= 700
        guard wide else { throw XCTSkip("a narrow window: this is the wide layout's test") }
        let placeholder = app.staticTexts["No chat selected"].firstMatch
        XCTAssertTrue(placeholder.waitForExistence(timeout: 40), "the detail column shows no placeholder before a chat is chosen")
        let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 40), "the chat list never showed the mock's chats")
        shot("split-1-list-and-placeholder")
        if let r = row("Disk cleanup") { r.tap() } else { text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let back = app.buttons["chat.back"].firstMatch
        if !back.waitForExistence(timeout: 15) {
            shot("split-2-after-tap")
            print("AX-TREE-BEGIN\n\(app.debugDescription.prefix(6000))\nAX-TREE-END")
        }
        XCTAssertTrue(back.exists, "the chat did not open")
        let lastReply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] '4.2 GB freed'")).firstMatch
        XCTAssertTrue(lastReply.waitForExistence(timeout: 30), "the thread never showed the chat's history")
        sleep(2)
        shot("split-2-list-beside-chat")
        // The list is still there beside the chat, and the tab bar did not step aside.
        let otherRow = row("Weekly dependency audit") ?? row("Rewrite the nightly export")
        XCTAssertTrue(otherRow?.isHittable == true, "the chat list is not beside the open chat")
        let compose = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(becomesHittable(compose, timeout: 5), "the tab bar hid although the list is beside the chat")
        // The window's width split between the two: the chat does not cover the list.
        let windowWidth = app.windows.firstMatch.frame.width
        XCTAssertLessThan(back.frame.minX, windowWidth, "Back is off the window")
        XCTAssertGreaterThan(back.frame.minX, 250, "the chat's Back sits where the list should be: the chat covers the list")
        // Another row replaces the open chat; the first one is not stacked under it.
        otherRow?.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        sleep(1)
        shot("split-3-another-chat")
        // Rotated to portrait an iPad's window is still at least 700 pt wide: both columns stay
        // (the open Duo upright, at 669 pt, gets one column: `testOneColumnOnANarrowUprightWindow`).
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        XCTAssertTrue(back.exists, "the open chat was lost on rotation")
        XCTAssertTrue(row("Disk cleanup")?.isHittable == true, "the list went away in portrait")
        shot("split-4-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        // A chat short enough to fit the column: its first bubble sits clear of the header pill.
        if let short = row("Bot Chat") { short.tap() }
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        sleep(3)
        shot("split-5-short-chat")
        let first = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'export is paused'")).firstMatch
        let pillFrame = app.buttons["chat.titlePill"].firstMatch.frame
        if first.waitForExistence(timeout: 10) { XCTAssertGreaterThan(first.frame.minY, pillFrame.maxY - 1, "the first bubble runs under the header pill: \(first.frame) vs \(pillFrame)") }
    }
}
