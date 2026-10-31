import XCTest

/// Pictures of the 1.5 bot symbols (#304) on the chat header and the pinned thread bot, state
/// by state, driven through the mock: thinking (the orb), a tool (the toolbox), writing (the
/// bubbles), an approval (the exclamation), and the plain bot at rest. For review,
/// not an assertion of looks. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
final class BotSymbolShotsUITests: XCTestCase {
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
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-colorSchemePreference", "light", "-chat.showBots", "YES"]
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-colorSchemePreference", "light", "-chat.showBots", "YES"]
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

    func testPicturesOfEachSymbol() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        launch(url: url, token: token)
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let pill = app.buttons["chat.titlePill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "no title pill")
        settle(2)
        shot("symbol-0-rest")

        // Thinking: the orb (the mock thinks for a while on "think").
        send("think about it")
        settle(1.2)
        shot("symbol-1-thinking")
        _ = text("Over to").firstMatch.waitForExistence(timeout: 5)
        settle(1)
        shot("symbol-2-writing-or-done")

        // A tool: the toolbox, then the reply as it writes.
        send("marathon 2")
        settle(1.5)
        shot("symbol-3-tool")
        settle(2.5)
        shot("symbol-4-mid-turn")
        settle(12)
        shot("symbol-5-after-turn")

        // An approval: the exclamation, eyes gone.
        send("card")
        settle(2)
        shot("symbol-6-approval")
        if app.keyboards.buttons["Hide keyboard"].firstMatch.exists { app.keyboards.buttons["Hide keyboard"].firstMatch.tap() }
        settle(1)
        shot("symbol-7-approval-no-keyboard")
    }
}
