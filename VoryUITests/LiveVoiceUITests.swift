import XCTest

/// The Live conversation, end to end on a simulator: the stand-in Gemini (Tools/fake-gemini-live
/// on 9121) hears the stand-in microphone, asks the bot through the mock gateway, and speaks;
/// the person's words and the bot's land in the transcript, and End leaves the chat. Skipped
/// unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set and the stand-in answers on its port.
final class LiveVoiceUITests: XCTestCase {
    private var app: XCUIApplication!
    static let fakeGemini = "ws://127.0.0.1:9121"

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    /// Whether anything listens on the stand-in's port (an HTTP request to a WebSocket server is
    /// refused with an answer; nothing there is a connection error).
    private func standInAnswers() -> Bool {
        guard let url = URL(string: Self.fakeGemini.replacingOccurrences(of: "ws://", with: "http://")) else { return false }
        var request = URLRequest(url: url); request.timeoutInterval = 3
        let done = expectation(description: "probe")
        var up = false
        URLSession.shared.dataTask(with: request) { _, response, error in
            up = response != nil || (error as? URLError)?.code != .cannotConnectToHost
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return up
    }

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = query.allElementsBoundByIndex.first(where: { $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    func testTheLiveLoopHearsAsksTheBotAndSpeaks() throws {
        guard env != nil else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        guard standInAnswers() else { throw XCTSkip("the stand-in Gemini is not on \(Self.fakeGemini)") }
        continueAfterFailure = false
        app = XCUIApplication()
        // Live, forced; the stand-in instead of Google; the canned line instead of the microphone.
        app.launchArguments = ["-launchTab", "chats", "-vory-voice-fake-input", "-vory-gemini-live-url", Self.fakeGemini, "-voice.conversation", "live", "-voice.liveProvider", "gemini", "-tabBar.showVoice", "YES"]
        app.launch()

        guard let mic = hittable(app.buttons.matching(identifier: "chats.voice"), timeout: 30) else { return XCTFail("no mic circle on the bar") }
        mic.tap()
        let end = app.buttons["End voice mode"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 20), "the voice screen did not open")

        // The stand-in transcribes what it heard; the bot's answer comes back through its tool
        // and is spoken with a transcript of its own. Both are lines of the screen's transcript.
        let heard = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'You said:'")).firstMatch
        if !heard.waitForExistence(timeout: 60) {
            print("LIVE-LABELS " + app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | "))
            XCTFail("the person's words are not in the transcript")
        }
        let said = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Bot said:'")).firstMatch
        XCTAssertTrue(said.waitForExistence(timeout: 90), "the bot's words are not in the transcript")
        XCTAssertFalse(app.staticTexts["Live needs your Gemini key in Settings › Voice."].exists, "Live ran without a key: the stand-in was used")
        end.tap()

        // Ending leaves the person in the chat, not on the list: its header, and at the bottom its
        // composer or, when the bot's turn has come to a question (the mock's scripted turn ends
        // at an approval), the card that takes the composer's place.
        XCTAssertTrue(leftInTheChat(), "not left in the chat")
    }

    /// In a chat: its Back button on screen, and its composer or a waiting card at the bottom.
    private func leftInTheChat(timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let back = app.buttons["chat.back"].firstMatch.exists
            let composer = app.descendants(matching: .any).matching(identifier: "composer.text").firstMatch.exists
            let card = app.staticTexts["Approval needed"].exists || app.buttons["Deny"].exists
            if back && (composer || card) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }
}
