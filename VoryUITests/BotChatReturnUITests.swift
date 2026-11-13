import XCTest

/// Leaving a Bot Chat opened from a "Messaged <bot>" notice (#448, feedback on 1.5 (28)) and coming back to the chat it
/// came from (#450). BotChatBackUITests has Back itself. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN /
/// HERMES_E2E_BUNDLE are set: the mock gateway's scripted turn messages the "work" bot, and that bot's Bot Chat is on
/// the gateway.
@MainActor
final class BotChatReturnUITests: XCTestCase {
    private var app: XCUIApplication!
    private var pill: XCUIElement { app.descendants(matching: .any).matching(identifier: "chat.titlePill").firstMatch }
    private var back: XCUIElement { app.descendants(matching: .any).matching(identifier: "chat.back").firstMatch }
    private var more: XCUIElement { app.descendants(matching: .any).matching(identifier: "chat.more").firstMatch }
    private var notice: XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Messaged work")).firstMatch }
    private var sent: XCUIElement { app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Can you look at the log host")).firstMatch }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !dir.isEmpty {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// What the bar shows, for the log.
    private func bar(_ step: String) {
        print("BOTCHAT-BAR \(step): pill=\(pill.exists ? pill.label : "none") back=\(back.exists) more=\(more.exists) "
              + "listControls=\(app.buttons["chats.newBot"].exists)")
    }

    /// A new chat whose turn messages the work bot, its notice on screen; the chat's pill.
    private func chatWithANotice() throws -> String {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN / HERMES_E2E_BUNDLE not set")
        }
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: bundle)
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
        XCTAssertTrue(notice.waitForExistence(timeout: 60), "no Messaged work notice")
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertFalse(pill.label.contains("Bot Chat"), "the first chat already reads as the Bot Chat: \(pill.label)")
        return pill.label
    }

    /// The notice found and tapped: whether the work bot's Bot Chat came to the front.
    private func openBotChat(_ step: String) -> Bool {
        // The turn went on after its notice: back in the chat, the notice can be above the screen, or below it.
        for _ in 0..<6 where !notice.isHittable { app.swipeDown(velocity: .slow) }
        for _ in 0..<8 where !notice.isHittable { app.swipeUp(velocity: .slow) }
        print("BOTCHAT-NOTICE \(step): exists=\(notice.exists) hittable=\(notice.isHittable)")
        guard notice.exists else { XCTFail("\(step): no notice in the chat to tap"); return false }
        // Settled first: a tap on a thread still moving from the swipes only stops it.
        sleep(1)
        let onBotChat = NSPredicate(format: "label CONTAINS %@", "Bot Chat")
        notice.tap()
        var ok = XCTWaiter.wait(for: [expectation(for: onBotChat, evaluatedWith: pill)], timeout: 6) == .completed
        // Once more if the first tap fell while the thread still moved under it (a reply streaming): a notice that
        // does nothing does nothing twice.
        if !ok, notice.exists, notice.isHittable {
            print("BOTCHAT-NOTICE \(step): tapped again")
            notice.tap()
            ok = XCTWaiter.wait(for: [expectation(for: onBotChat, evaluatedWith: pill)], timeout: 6) == .completed
        }
        bar(step)
        return ok
    }

    /// A rightward drag from the screen's left edge, over `share` of its width.
    private func edgeSwipe(_ share: CGFloat, velocity: XCUIGestureVelocity) {
        let mid = app.frame.height * 0.45
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: mid))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * share, dy: mid))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0)
    }

    /// A swipe back from the Bot Chat: the chat it came from, with its own bar (Back, the bot's pill, ⋯). Followed as a
    /// pop to the list, the bar settled on the list's state over that chat and drew nothing at all (#448).
    func testAnEdgeSwipeBackFromABotChatKeepsTheChatsBar() throws {
        let firstChat = try chatWithANotice()
        XCTAssertTrue(openBotChat("tap"), "the notice did not open the Bot Chat")
        sleep(1)
        edgeSwipe(0.85, velocity: .default)
        sleep(2)
        bar("after the edge swipe")
        shot("botchat-after-edge-swipe")
        XCTAssertTrue(pill.exists, "after the swipe the chat has no bot pill")
        XCTAssertEqual(pill.exists ? pill.label : "", firstChat, "the swipe did not return to the chat it came from")
        XCTAssertTrue(back.exists, "after the swipe the chat has no Back")
        XCTAssertTrue(more.exists, "after the swipe the chat has no ⋯")
        XCTAssertFalse(app.buttons["chats.newBot"].exists, "the list's controls are up over the chat")
        // And its Back still goes to the list.
        back.tap()
        XCTAssertTrue(app.buttons["chats.newBot"].waitForExistence(timeout: 5), "Back from the chat did not reach the list")
    }

    /// A swipe from the edge let go early: the Bot Chat stays, with its own bar.
    func testASwipeCalledOffKeepsTheBotChatsBar() throws {
        _ = try chatWithANotice()
        XCTAssertTrue(openBotChat("tap"), "the notice did not open the Bot Chat")
        sleep(1)
        edgeSwipe(0.2, velocity: .slow)
        sleep(2)
        bar("after a swipe called off")
        shot("botchat-after-called-off-swipe")
        XCTAssertTrue(pill.exists && pill.label.contains("Bot Chat"), "a swipe called off left the bar on another chat: \(pill.exists ? pill.label : "none")")
        XCTAssertTrue(back.exists, "after the swipe the Bot Chat has no Back")
        // Its Back goes to the chat it came from, not past it.
        back.tap()
        sleep(2)
        bar("Back after the swipe called off")
        XCTAssertTrue(pill.exists && !pill.label.contains("Bot Chat"), "Back did not leave the Bot Chat")
        XCTAssertFalse(app.buttons["chats.newBot"].exists, "Back went past the chat to the list")
    }

    /// Back in a chat that began as a new chat: it is still that chat, its messages there. Each time the page came back
    /// into view it made another new chat, blank, in its place (#450).
    func testBackToANewChatKeepsItsMessages() throws {
        _ = try chatWithANotice()
        XCTAssertTrue(sent.exists, "the message sent is not in the chat")
        XCTAssertTrue(openBotChat("tap"), "the notice did not open the Bot Chat")
        back.tap()
        sleep(2)
        bar("after Back")
        shot("newchat-after-back")
        for _ in 0..<6 where !sent.exists { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(sent.exists, "back in the chat, the message sent is gone: a blank chat took its place")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Say something to")).firstMatch.exists,
                       "back in the chat, it is a blank new chat")
    }

    /// Back, then the same notice again: its Bot Chat opens again. The list took a route once only, and the same notice
    /// made the same route (#448).
    func testTheNoticeOpensItsBotChatAgainAfterBack() throws {
        let firstChat = try chatWithANotice()
        XCTAssertTrue(openBotChat("first tap"), "the notice did not open the Bot Chat the first time")
        back.tap()
        sleep(2)
        bar("after Back")
        XCTAssertEqual(pill.label, firstChat, "Back did not return to the chat it came from")
        let again = openBotChat("second tap")
        shot("botchat-second-tap")
        XCTAssertTrue(again, "the same notice did nothing after Back")
    }

    /// The same in a chat opened from the list, as in the report.
    func testTheNoticeInAStoredChatOpensItsBotChatAgainAfterBack() throws {
        _ = try chatWithANotice()
        sleep(2)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        // The chat just made, the newest in the list, still called New chat (another chat's title names the log host).
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label CONTAINS %@", "New chat", "Can you look at the log host")).firstMatch
        if !row.waitForExistence(timeout: 10) { print("BOTCHAT-LIST rows: \(app.buttons.allElementsBoundByIndex.prefix(14).map(\.label))") }
        XCTAssertTrue(row.exists, "the chat is not in the list")
        row.tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        sleep(2)
        let stored = pill.label
        bar("stored chat open")
        XCTAssertTrue(openBotChat("stored first tap"), "the notice did not open the Bot Chat from the stored chat")
        back.tap()
        sleep(2)
        bar("stored after Back")
        XCTAssertEqual(pill.label, stored, "Back did not return to the stored chat")
        let again = openBotChat("stored second tap")
        shot("botchat-stored-second-tap")
        XCTAssertTrue(again, "the same notice did nothing after Back")
    }
}
