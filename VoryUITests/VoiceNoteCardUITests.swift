import XCTest

/// A voice note handed back in inline code plays in its own card (#309): the mock's "voice" turn
/// names a WAV in a reply, the card appears with a play control, a tap starts playback and the
/// elapsed time moves, and a second tap pauses. The card is named for the file, no path in words.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
@MainActor
final class VoiceNoteCardUITests: XCTestCase {
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

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    private func text(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
    }

    func testAVoiceNoteInAReplyPlaysInTheBubble() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES"]
        } else {
            app = XCUIApplication()
        }
        app.launch()
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("voice note please")
        for _ in 0..<3 {
            guard let send = hittable(app.buttons.matching(identifier: "composer.send"), timeout: 5),
                  (composer.value as? String)?.contains("voice note") == true else { break }
            send.tap()
            if text("Here is the voice note").firstMatch.waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(text("Here is the voice note").firstMatch.waitForExistence(timeout: 30), "the reply did not arrive")
        if let done = hittable(app.buttons.matching(NSPredicate(format: "label == 'Hide keyboard' OR label == 'Done'")), timeout: 1) { done.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        // One card, named by the file; the inline-code path is out of the words.
        let card = app.buttons["audio.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no voice note card")
        XCTAssertTrue(card.label.contains("voice-note.wav"), "the card is not named for the file: \(card.label)")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "/home/hermes/out/voice-note.wav")).firstMatch.exists,
                       "the path is still in the bubble")
        shot("voice-note-card")

        // A tap fetches the clip and starts it.
        card.tap()
        let playing = Date().addingTimeInterval(20)
        while Date() < playing, card.label != "Pause voice-note.wav" {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(card.label, "Pause voice-note.wav", "the card did not start playing; last label: \(card.label)")

        // The position moves off zero.
        let elapsed = app.staticTexts["audio.elapsed"].firstMatch
        let moving = Date().addingTimeInterval(3)
        while Date() < moving, !(elapsed.exists && elapsed.label != "0:00") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(elapsed.exists && elapsed.label != "0:00", "the elapsed time stayed at \(elapsed.exists ? elapsed.label : "nothing")")
        shot("voice-note-player")

        // A second tap pauses.
        card.tap()
        let paused = Date().addingTimeInterval(5)
        while Date() < paused, card.label != "Play voice-note.wav" {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(card.label, "Play voice-note.wav", "the card did not pause; last label: \(card.label)")
    }
}