import XCTest

/// Demo mode's chats put the keyboard away after a send (#490, Matt: swiping it away was hard). The app's own chats keep
/// it up after a send, as before. The app with `-vory-demo`; the app's own chat needs the mock (HERMES_E2E_URL,
/// HERMES_E2E_TOKEN, HERMES_E2E_BUNDLE).
final class DemoKeyboardUITests: XCTestCase {
    private var app: XCUIApplication!

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func keyboardGone(within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat { if app.keyboards.count == 0 { return true }; pause(0.25) } while Date() < deadline
        return false
    }

    private func type(_ words: String) {
        let field = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no message bar")
        field.tap(); pause(0.8)
        XCTAssertGreaterThan(app.keyboards.count, 0, "no keyboard for the message bar")
        field.typeText(words)
    }

    private func openDemoChat() {
        app = XCUIApplication()
        app.launchArguments = ["-vory-demo", "-companionPromptShown", "YES", "-launchTab", "chats"]
        app.launch()
        let chat = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Packing list for the lake weekend'")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 30), "the demo's chats did not load")
        chat.tap(); pause(1.5)
    }

    func testADemoChatPutsTheKeyboardAwayAfterASend() throws {
        openDemoChat()
        type("Thanks, what else is there to do?")
        app.buttons["composer.send"].firstMatch.tap()
        XCTAssertTrue(keyboardGone(within: 3), "the keyboard stayed up after a send in the demo")
    }

    /// The app's own chat is as it was: the keyboard stays up after a send, for the next message.
    func testTheAppsOwnChatKeepsTheKeyboardAfterASend() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("needs the mock (HERMES_E2E_URL / TOKEN / BUNDLE)")
        }
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats"]
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup' AND identifier != 'chat.titlePill'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no Disk cleanup chat")
        row.tap(); pause(1.5)
        type("Thanks")
        app.buttons["composer.send"].firstMatch.tap(); pause(2)
        XCTAssertGreaterThan(app.keyboards.count, 0, "the app's own chat put the keyboard away after a send")
    }
}
