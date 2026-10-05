import XCTest

/// Voice mode from the Chats page's mic circle (#237): a fresh chat opens with the voice screen
/// over it, the stand-in microphone speaks and its words show in the transcript, the bot's reply
/// shows in full (#235), and End leaves the person in that chat. Then the New Message sheet's
/// + panel offers Voice mode and its mic button (#236). Skipped unless HERMES_E2E_URL /
/// HERMES_E2E_TOKEN are set (the mock gateway) on a simulator that has allowed the microphone.
final class VoiceEntryUITests: XCTestCase {
    private var app: XCUIApplication!
    private lazy var shotDir: URL = {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-chat-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-launchTab", "chats", "-vory-voice-fake-input"]
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

    /// The hittable one among duplicates (every tab page is mounted; only the front one can be tapped).
    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = query.allElementsBoundByIndex.first(where: { $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    func testMicCircleStartsAVoiceChatWithATranscriptAndTheSheetOffersVoice() throws {
        guard env != nil else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        guard let mic = hittable(app.buttons.matching(identifier: "chats.voice"), timeout: 30) else { return XCTFail("no mic circle on the bar") }
        shot("voice-entry-bar")
        mic.tap()

        // The voice screen is over the new chat.
        let end = app.buttons["End voice mode"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 20), "the voice screen did not open")
        // The stand-in mic says its line; the words land in the transcript as the person's (on
        // a simulator the device's transcriber has no model, so they are the mock's transcript).
        shot("voice-entry-screen")
        let heard = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'You said:'")).firstMatch
        if !heard.waitForExistence(timeout: 40) {
            shot("voice-entry-missing")
            print("VOICE-LABELS " + app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | "))
            XCTFail("the person's words are not in the transcript")
        }
        // The bot's reply, in full, as its own line.
        let said = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Bot said:'")).firstMatch
        XCTAssertTrue(said.waitForExistence(timeout: 60), "the bot's words are not in the transcript")
        shot("voice-entry-transcript")
        end.tap()

        // Ending leaves the person in the chat (its composer is there), not on the list.
        let send = app.buttons["composer.send"].firstMatch
        let composer = app.textViews.firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10) || composer.waitForExistence(timeout: 5), "not left in the chat")
        shot("voice-entry-chat-after")
        let back = app.buttons["chat.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()

        // The New Message sheet (the compose circle held): the + panel and the mic.
        guard let compose = hittable(app.buttons.matching(identifier: "chats.new"), timeout: 15) else { return XCTFail("no compose circle") }
        compose.press(forDuration: 0.8)
        let to = app.textFields["Bot name"].firstMatch
        XCTAssertTrue(to.waitForExistence(timeout: 10), "the New Message sheet did not open")
        // Return in the empty To: field takes the first bot listed.
        to.tap()
        to.typeText("\n")
        let attach = app.buttons["newchat.attach"].firstMatch
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        XCTAssertTrue(attach.isEnabled, "no bot was chosen, so the + button stayed off")
        XCTAssertTrue(app.buttons["newchat.voice"].firstMatch.exists, "no mic beside Send")
        attach.tap()
        XCTAssertTrue(app.buttons["attach.voice-mode"].firstMatch.waitForExistence(timeout: 5), "no Voice mode row in the + panel")
        XCTAssertFalse(app.buttons["attach.message-history"].firstMatch.isEnabled, "Message History should be greyed before a chat exists")
        shot("voice-entry-sheet-panel")
    }
}
