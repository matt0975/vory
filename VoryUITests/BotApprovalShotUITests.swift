import XCTest

/// Pictures of the bot while an approval waits (the exclamation) and while a reply writes (the
/// bubbles on the header), at full resolution, for review (#304). Skipped unless
/// HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock gateway).
final class BotApprovalShotUITests: XCTestCase {
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

    private func launch(url: String, token: String, scheme: String) {
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-colorSchemePreference", scheme, "-chat.showBots", "YES"]
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-colorSchemePreference", scheme, "-chat.showBots", "YES"]
        }
        app.launch()
    }

    private func text(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
    }

    private func send(_ prompt: String) {
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText(prompt)
        if let send = app.buttons.matching(identifier: "composer.send").allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { send.tap() }
    }

    private func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func hideKeyboard() {
        if app.keyboards.buttons["Hide keyboard"].firstMatch.exists { app.keyboards.buttons["Hide keyboard"].firstMatch.tap() }
    }

    func testApprovalAndWritingPictures() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        for scheme in ["light", "dark"] {
            launch(url: url, token: token, scheme: scheme)
            let newChat = app.buttons["chats.new"].firstMatch
            XCTAssertTrue(newChat.waitForExistence(timeout: 40))
            wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
            newChat.tap()
            XCTAssertTrue(app.buttons["chat.titlePill"].firstMatch.waitForExistence(timeout: 30), "no title pill")
            // One turn of the mock's default flow, started with "think": 20 s of silence (the
            // orb), the first words, a terminal tool for 1.4 s (the toolbox), a todo and a word
            // to the other bot, more words, then the approval (the exclamation, eyes gone);
            // approved, a second tool and the rest of the reply, then the bot at rest.
            send("think it over")
            settle(1.6)
            shot("motion-\(scheme)-1-thinking")
            // The terminal tool runs 1.4 s, less than a query of the tree takes to notice it: a
            // burst of plain frames from the end of the silence until the approval, named by
            // their time since the prompt; the toolbox is picked from them by eye.
            let sent = Date()
            let approval = text("Approval needed").firstMatch
            var frames = 0
            while !approval.exists, Date().timeIntervalSince(sent) < 60 {
                if Date().timeIntervalSince(sent) > 19 {
                    let s = XCUIScreen.main.screenshot()
                    let ms = Int(Date().timeIntervalSince(sent) * 1000)
                    let d = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? URL(fileURLWithPath: NSTemporaryDirectory())
                    try? s.pngRepresentation.write(to: d.appendingPathComponent("burst-\(scheme)-\(ms).png"))
                    frames += 1
                } else {
                    settle(0.5)
                }
            }
            print("BURST \(scheme) \(frames) frames")
            XCTAssertTrue(text("Approval needed").firstMatch.waitForExistence(timeout: 60), "no approval card")
            settle(1.5)
            hideKeyboard()
            settle(1)
            shot("motion-\(scheme)-3-approval")
            let once = app.buttons.matching(NSPredicate(format: "label == 'Allow once'")).firstMatch
            XCTAssertTrue(once.waitForExistence(timeout: 5), "no Once button")
            once.tap()
            XCTAssertTrue(text("filesystem is back").firstMatch.waitForExistence(timeout: 60), "the turn did not finish")
            settle(2.5)
            shot("motion-\(scheme)-4-rest-after-turn")
            app.terminate()
        }
    }
}
