import XCTest

/// "@name" in a reply (#302): a bot's mention in its colour as a link to its card, the person's
/// with the stronger mark, code left plain, an unknown name plain. The mock's "mention" turn
/// writes one of each; a tap on "@work" opens that bot's card. Light, then dark; pictures land
/// where HERMES_E2E_SHOTS says.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
@MainActor
final class MentionsUITests: XCTestCase {
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
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-colorSchemePreference", scheme]
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-colorSchemePreference", scheme]
        }
        app.launch()
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

    private func sendMention() {
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("mention the others")
        for _ in 0..<3 {
            guard let send = hittable(app.buttons.matching(identifier: "composer.send"), timeout: 5),
                  (composer.value as? String)?.contains("mention") == true else { break }
            send.tap()
            if text("Over to").firstMatch.waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(text("for the go").firstMatch.waitForExistence(timeout: 30), "the reply with mentions did not arrive")
        if let done = hittable(app.buttons.matching(NSPredicate(format: "label == 'Hide keyboard' OR label == 'Done'")), timeout: 1) { done.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }

    func testMentionsAreMarkedAndABotsOpensItsCard() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        launch(url: url, token: token, scheme: "light")
        sendMention()
        shot("mentions-light")
        // A bot's mention is a link: the reply carries links for @work and @default and no other.
        let reply = text("Handing the deploy").firstMatch
        XCTAssertTrue(reply.exists)
        let links = app.links.allElementsBoundByIndex.filter { $0.exists }
        let names = links.map(\.label)
        XCTAssertTrue(names.contains("@work"), "no link for @work: \(names)")
        XCTAssertTrue(names.contains("@default"), "no link for @default: \(names)")
        XCTAssertFalse(names.contains("@Ops"), "an unknown name became a link")
        XCTAssertFalse(names.contains("@you"), "the person's mention became a link")
        // The tap opens the bot's card.
        if let work = links.first(where: { $0.label == "@work" }), work.isHittable {
            work.tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "profile.header").firstMatch.waitForExistence(timeout: 10), "the card did not open from @work")
            shot("mentions-card-from-tap")
            app.buttons["profile.close"].firstMatch.tap()
        }

        app.terminate()
        launch(url: url, token: token, scheme: "dark")
        sendMention()
        shot("mentions-dark")
    }
}
