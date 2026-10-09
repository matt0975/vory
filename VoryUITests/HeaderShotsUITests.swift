import XCTest

/// Pictures of the floating header over a long chat, for a look at the status bar's fade
/// (#276): at rest up the thread, after a fast swipe, in landscape, and after a tap on the
/// status bar (which takes the thread to its top). Runs on an iPhone or an iPad simulator;
/// the pictures land where HERMES_E2E_SHOTS says.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
@MainActor
final class HeaderShotsUITests: XCTestCase {
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

    func testPicturesOfTheHeaderOverALongChat() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
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
        composer.typeText("marathon 24")
        // Tapped again if the first tap landed before the button had changed from the mic.
        for _ in 0..<4 {
            guard let send = hittable(app.buttons.matching(identifier: "composer.send"), timeout: 5),
                  (composer.value as? String)?.contains("marathon") == true else { break }
            send.tap()
            if text(" of 24: checking shard").firstMatch.waitForExistence(timeout: 8) { break }
        }
        XCTAssertTrue(text("Everything else looked healthy").firstMatch.waitForExistence(timeout: 120), "the turn did not finish")
        // The keyboard down, so the thread fills the screen.
        if let done = hittable(app.buttons.matching(NSPredicate(format: "label == 'Hide keyboard' OR label == 'Done'")), timeout: 1) { done.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("header-at-end")

        // Up the thread at rest: rows run under the header and fade out in the status bar's band.
        app.swipeDown(velocity: .slow)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        shot("header-scrolled-up")

        // A fast swipe (a fling): the picture a moment after it starts.
        app.swipeDown(velocity: .fast)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        shot("header-during-fling")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        // Landscape, then back.
        XCUIDevice.shared.orientation = .landscapeLeft
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("header-landscape")
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        // A tap on the status bar takes the thread to its top: the first message comes into view.
        let first = text("Step 1 of 24")
        let window = app.windows.firstMatch.frame
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.midX, dy: 12)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("header-after-status-bar-tap")
        XCTAssertTrue(first.firstMatch.exists && first.firstMatch.frame.minY < window.midY, "a tap on the status bar did not take the thread to its top")
    }
}
