import XCTest

/// #346: a Bot Chat opened from a "Messaged <bot>" notice sits over the chat it came from, and
/// its Back goes back to that chat, not to the list (feedback on 1.5 (23)). Skipped unless
/// HERMES_E2E_URL / HERMES_E2E_TOKEN / HERMES_E2E_BUNDLE are set: the mock gateway's scripted turn
/// messages the "work" bot, and that bot's Bot Chat is on the gateway.
@MainActor
final class BotChatBackUITests: XCTestCase {
    func testBackFromABotChatReturnsToItsChat() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN / HERMES_E2E_BUNDLE not set")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats"]
        app.launch()
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("Can you look at the log host?")
        app.buttons["composer.send"].firstMatch.tap()

        // The turn messages the work bot: its notice opens that bot's Bot Chat over this chat.
        let notice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Messaged work")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 60), "no Messaged work notice")
        let pill = app.descendants(matching: .any).matching(identifier: "chat.titlePill").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        let firstChat = pill.label
        XCTAssertFalse(firstChat.contains("Bot Chat"), "the first chat already reads as the Bot Chat: \(firstChat)")
        for _ in 0..<4 where !notice.isHittable { app.swipeUp(velocity: .slow) }
        notice.tap()
        let onBotChat = NSPredicate(format: "label CONTAINS %@", "Bot Chat")
        wait(for: [expectation(for: onBotChat, evaluatedWith: pill)], timeout: 20)
        print("BOTCHAT-PILL \(pill.label)")

        // Back: the chat it came from, with its own bar, not the list.
        let back = app.descendants(matching: .any).matching(identifier: "chat.back").firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        sleep(2)
        print("BACK-PILL \(pill.exists ? pill.label : "none") list=\(app.buttons["chats.newBot"].exists)")
        XCTAssertTrue(pill.exists, "Back from the Bot Chat left no chat open (it went to the list)")
        XCTAssertFalse(pill.label.contains("Bot Chat"), "the bar still shows the Bot Chat")
        XCTAssertEqual(pill.label, firstChat, "Back from the Bot Chat did not return to the chat it came from")
        XCTAssertFalse(app.buttons["chats.newBot"].exists, "the list's controls are up")
    }
}
