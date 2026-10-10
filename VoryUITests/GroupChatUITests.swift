import XCTest

/// A group chat with two bots: its header shows both bots' faces over the chat's name with the
/// members named under it and opens the member list; while the bots work, the thread shows
/// which ones, both side by side with their names, then the one still at it, then nobody once
/// both have answered. The chat is started the way a person starts one: New Message (press and
/// hold the compose circle), two bots in To:, a first message to @all. The mock gateway opens
/// every bot's turn at once for a group message with @all, and they answer a few seconds apart.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=com.vorantx.vory.demo
/// drives the demo copy (Tools/dev/make-demo-app-sim.sh). HERMES_E2E_SHOTS names a folder for
/// the screenshots.
@MainActor
final class GroupChatUITests: XCTestCase {
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

    /// The one on screen: every tab page is mounted, so the first match can be another copy.
    private func visible(_ query: XCUIElementQuery, _ label: String, timeout: TimeInterval = 15) -> XCUIElement? {
        let matches = query.matching(NSPredicate(format: "label == %@", label))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = matches.allElementsBoundByIndex.first(where: { $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        return nil
    }

    /// Waits for the typing indicator to read `label` (nil: for it to be gone).
    private func waitForTyping(_ label: String?, timeout: TimeInterval) -> Bool {
        let typing = app.otherElements["group.typing"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let label { if typing.exists, typing.label == label { return true } } else if !typing.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }

    func testTwoBotsWorkSideBySideAndTheHeaderShowsTheGroup() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        launch(url: url, token: token)
        let compose = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: compose)], timeout: 60)
        // Held, the compose circle opens New Message.
        compose.press(forDuration: 1.0)
        let field = app.textViews["newchat.text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "New Message did not open")
        for bot in ["default", "work"] {
            let card = try XCTUnwrap(visible(app.staticTexts, bot), "no \(bot) to add")
            card.tap()
            sleep(1)
        }
        XCTAssertTrue(app.staticTexts["New Group Chat"].firstMatch.waitForExistence(timeout: 5), "two bots did not make a group")
        field.tap()
        field.typeText("@all what is the plan for the release?")
        app.buttons["newchat.send"].firstMatch.tap()

        // The group's header: both faces over the name, the members named.
        let header = app.buttons["group.header"].firstMatch
        guard header.waitForExistence(timeout: 30) else { shot("group-0-no-header"); return XCTFail("the group chat has no header") }
        XCTAssertTrue(header.label.contains("Default and Work"), "the header does not name the members: \(header.label)")

        // Both bots at work: side by side, both named.
        XCTAssertTrue(waitForTyping("Default and Work are typing", timeout: 20), "the two bots were not shown working together")
        sleep(1)
        shot("group-1-both-working")
        // One has answered; the other is still at it.
        XCTAssertTrue(waitForTyping("Work is typing", timeout: 30), "the bot still working was not shown on its own")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "the notes and the changelog")).firstMatch.exists)
        sleep(1)
        shot("group-2-one-working")
        // Both answered: nobody is working.
        XCTAssertTrue(waitForTyping(nil, timeout: 30), "the typing indicator stayed after both bots answered")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "the build, the tests and the upload")).firstMatch.waitForExistence(timeout: 10))
        sleep(1)
        shot("group-3-answered")

        // The header opens the member list.
        header.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "2 bots")).firstMatch.waitForExistence(timeout: 10), "the member list did not open")
        for handle in ["@default", "@work"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", handle)).firstMatch.exists, "the member list does not list \(handle)")
        }
        sleep(1)
        shot("group-4-members")
        app.buttons["Done"].firstMatch.tap()
    }
}
