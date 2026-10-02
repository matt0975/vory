import XCTest

/// Drives a full conversation against the mock gateway in Tools/mock-gateway and captures the
/// chat surfaces: streaming, tool cards, the approval card, the finished transcript, the context
/// sheet and the model picker. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
final class ChatShowcaseUITests: XCTestCase {
    private var app: XCUIApplication!
    private lazy var shotDir: URL = {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-chat-shots", isDirectory: true)
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
        print("CHAT-SHOT \(shotDir.appendingPathComponent("\(name).png").path)")
    }

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    /// SwiftUI Lists render lazily, so a row below the fold does not exist in the hierarchy
    /// until it is scrolled into view. Scroll until it does, or give up.
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

    private func waitForText(_ fragment: String, timeout: TimeInterval) -> Bool {
        let e = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
        return e.waitForExistence(timeout: timeout)
    }

    /// Fresh installs land on onboarding; a cold simulator can take well over 10 s to get there.
    private func connectIfNeeded(url: String, token: String) {
        // The first screen (Get Started / Restore from iCloud), then the tour's Skip.
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
        // XCUITest reports a `.disabled` SwiftUI toolbar button as enabled, so wait for the third
        // leg's own result text instead; Save only works once all three legs have passed.
        // The third leg's row sits below the fold, and a lazily rendered List row does not exist
        // until it is scrolled on screen — so scroll while waiting.
        let wsResult = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'gateway.ready received'")).firstMatch
        let deadline = Date().addingTimeInterval(60)
        while !wsResult.exists, Date() < deadline { app.swipeUp(velocity: .slow); _ = wsResult.waitForExistence(timeout: 2) }
        XCTAssertTrue(wsResult.exists, "WebSocket leg did not pass")
        app.buttons["gateway.save"].firstMatch.tap()
    }

    func testFullConversation() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }

        connectIfNeeded(url: url, token: token)

        // Chat list with the seeded sessions
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 30))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        XCTAssertTrue(waitForText("Disk cleanup", timeout: 20), "seeded sessions did not load")
        sleep(1)
        shot("11-chat-list")

        // New chat -> send
        newChat.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "composer.text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("The log host is at 94% disk. Can you take a look?")
        shot("12-composer-typed")
        app.buttons["composer.send"].firstMatch.tap()

        // Mid-stream: the first paragraph is on screen while more is still arriving.
        XCTAssertTrue(waitForText("What I found", timeout: 30), "streamed text never appeared")
        shot("13-streaming")

        // The terminal tool card.
        XCTAssertTrue(waitForText("terminal", timeout: 30), "tool card never appeared")
        sleep(1)
        shot("14-tool-card")

        // The approval card replaces the composer.
        XCTAssertTrue(waitForText("Approval needed", timeout: 60), "approval card never appeared")
        sleep(1)
        shot("15-approval-card")

        // Approve once and let the turn finish.
        let once = app.buttons["Once"].firstMatch
        XCTAssertTrue(once.waitForExistence(timeout: 10))
        once.tap()
        XCTAssertTrue(waitForText("4.2 GB freed", timeout: 90), "turn never completed")
        sleep(2)
        shot("16-finished-turn")

        // Scroll up to show the rendered markdown and code fence.
        app.swipeDown(velocity: .slow)
        sleep(1)
        shot("17-markdown-and-code")

        // Token chip -> context breakdown sheet.
        let chip = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Context usage'")).firstMatch
        if chip.waitForExistence(timeout: 10) {
            chip.tap()
            XCTAssertTrue(waitForText("By category", timeout: 20))
            sleep(1)
            shot("18-context-breakdown")
            app.buttons["Done"].firstMatch.tap()
            sleep(1)
        }

        // Model picker menu.
        let model = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Model:'")).firstMatch
        if model.waitForExistence(timeout: 10) {
            model.tap()
            XCTAssertTrue(waitForText("Anthropic", timeout: 20))
            sleep(1)
            shot("19-model-picker")
        }
    }

    /// Round six: instant open of a seeded chat, the tab bar straight after Back, the long-press
    /// peek, the tall info sheet with editable title, and the avatar picker on the profile card.
    func testRoundSixTour() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        connectIfNeeded(url: url, token: token)
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 30))
        XCTAssertTrue(waitForText("Disk cleanup", timeout: 30), "seeded sessions did not load")
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch

        // Open the chat: the transcript must be on screen well before the 3 s the old path took.
        row.tap()
        XCTAssertTrue(waitForText("94% disk", timeout: 10), "transcript never appeared")
        sleep(1)
        shot("20-chat-opened")

        // Back: the tab bar has to be there at once.
        // The hidden navigation bar still has an (inert) "Back" button; use the glass one, by
        // coordinate (an overlay button's AX tap can land on the scroll view under it).
        let back = app.buttons["chat.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        usleep(150_000); shot("21a-back-150ms")
        usleep(550_000); shot("21-after-back")
        if app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] '4.2 GB freed'")).firstMatch.exists {
            // Still in the chat: the edge swipe must work too.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)))
            usleep(800_000); shot("21c-after-edge-swipe")
        }
        XCTAssertTrue(app.tabBars.firstMatch.exists || app.buttons["Settings"].firstMatch.exists, "tab bar missing after Back")

        // Peek.
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.2)
        sleep(2)
        shot("22-peek")
        // Open straight from the peek's menu.
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()

        // Info sheet from the title pill: tall, title editable, model menu.
        // The glass pill is not exposed with its identifier; tap where it sits, top centre.
        XCTAssertTrue(waitForText("94% disk", timeout: 15))
        sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(waitForText("This chat", timeout: 10), "info sheet did not open from the pill")
        sleep(1)
        shot("23-info-sheet")

        // Profile card → avatar picker.
        // "default" also appears in the chat header behind the sheet; tap the row by its text.
        let profileRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Main agent'")).firstMatch
        XCTAssertTrue(profileRow.waitForExistence(timeout: 5))
        profileRow.tap()
        XCTAssertTrue(waitForText("Avatar", timeout: 10), "profile card never appeared")
        sleep(1)
        shot("24-profile-card")
        let pip = app.buttons["Pip"].firstMatch
        if pip.waitForExistence(timeout: 5) {
            pip.tap()
            sleep(1)
            shot("25-avatar-pip")
        }
        // The pushed card has only Back; Done lives on the sheet's root.
        let sheetBack = app.navigationBars.buttons.firstMatch
        if sheetBack.exists { sheetBack.tap(); sleep(1) }
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() } else { app.swipeDown(velocity: .fast) }
        sleep(1)
        shot("26-header-with-avatar")
    }

    /// Screens from the first TestFlight round: Sessions with the Advanced cog, the truncated
    /// System log with Show more, the maintenance section, the Bots empty state + room creation,
    /// and the tab bar editor. Assumes the gateway from testFullConversation is already saved.
    func testSettingsTour() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        connectIfNeeded(url: url, token: token)
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 40), "app should be past onboarding")
        app.buttons["Settings"].firstMatch.tap()

        // Sessions: list only, store stats behind the cog.
        let sessions = app.buttons["Sessions"].firstMatch
        XCTAssertTrue(scrollUntilVisible(sessions)); sessions.tap()
        XCTAssertTrue(waitForText("messages", timeout: 20))
        sleep(1); shot("20-sessions-list")
        let cog = app.buttons["Options"].firstMatch
        if cog.waitForExistence(timeout: 5) {
            cog.tap()
            let adv = app.buttons["Advanced"].firstMatch
            if adv.waitForExistence(timeout: 5) { adv.tap(); XCTAssertTrue(waitForText("By source", timeout: 10)); sleep(1); shot("21-sessions-advanced"); app.buttons["Done"].firstMatch.tap() }
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // System: 5 log entries then Show more; maintenance section.
        let system = app.buttons["System"].firstMatch
        XCTAssertTrue(scrollUntilVisible(system)); system.tap()
        XCTAssertTrue(waitForText("Recent log", timeout: 20))
        let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show'")).firstMatch
        XCTAssertTrue(scrollUntilVisible(more, swipes: 8), "log should be truncated with a Show more button")
        sleep(1); shot("22-system-log-truncated")
        more.tap(); sleep(1); shot("23-system-log-expanded")
        app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitForText("Maintenance", timeout: 10))
        let check = app.buttons["Check for updates"].firstMatch
        if scrollUntilVisible(check, swipes: 3) { check.tap(); _ = waitForText("commits behind", timeout: 15); sleep(1) }
        shot("24-system-maintenance")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Appearance: theme + tab bar editor.
        let appearance = app.buttons["Appearance"].firstMatch
        XCTAssertTrue(scrollUntilVisible(appearance)); appearance.tap()
        XCTAssertTrue(waitForText("Tab bar", timeout: 10))
        sleep(1); shot("25-appearance-tabs")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Bots: empty state, then a created room.
        let bots = app.buttons["Bots"].firstMatch
        if bots.waitForExistence(timeout: 5) {
            bots.tap()
            XCTAssertTrue(waitForText("No rooms yet", timeout: 15))
            sleep(1); shot("26-bots-empty")
            app.buttons["New Room"].firstMatch.tap()
            let field = app.textFields.firstMatch
            if field.waitForExistence(timeout: 5) { field.typeText("Ops standup"); app.buttons["Create"].firstMatch.tap() }
            XCTAssertTrue(waitForText("Ops standup", timeout: 15))
            sleep(1); shot("27-bots-room")
        }
    }
}
