import XCTest

/// The bot's card from a chat's title pill (#282): a hero header (face, name, description as
/// one VoiceOver element), round Close and … buttons over it, then the Info sections in order
/// (Character, Instructions, Description, Model, This chat, Show in chats, Home). Light, then
/// dark in a second launch; pictures land where HERMES_E2E_SHOTS says.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
@MainActor
final class ProfileCardUITests: XCTestCase {
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

    private func text(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
    }

    /// Scrolls the sheet until the text shows, a few swipes at most.
    private func reach(_ fragment: String) -> Bool {
        for _ in 0..<8 {
            if let e = text(fragment).allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { _ = e; return true }
            app.swipeUp(velocity: .slow)
        }
        return text(fragment).firstMatch.exists
    }

    private func openCard() {
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let pill = app.buttons["chat.titlePill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "no title pill")
        pill.tap()
        XCTAssertTrue(app.otherElements["profile.header"].firstMatch.waitForExistence(timeout: 10)
                      || app.staticTexts["profile.header"].firstMatch.waitForExistence(timeout: 2), "the card's header did not show")
    }

    func testTheCardHasItsHeaderButtonsAndSectionsInLightAndDark() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        launch(url: url, token: token, scheme: "light")
        openCard()
        // The header is one element: the name and the line under it.
        let header = app.descendants(matching: .any).matching(identifier: "profile.header").firstMatch
        XCTAssertTrue(header.exists)
        XCTAssertTrue(header.label.contains("default"), "the header does not read the bot's name: \(header.label)")
        // Round buttons over it.
        XCTAssertTrue(app.buttons["profile.close"].firstMatch.exists, "no Close over the header")
        let more = app.buttons["profile.more"].firstMatch
        XCTAssertTrue(more.exists, "no … over the header")
        // The card opens at the medium height; the tall one for the pictures.
        app.swipeUp(velocity: .fast)
        sleep(1)
        shot("profile-card-light-top")
        more.tap()
        XCTAssertTrue(app.buttons["Rename chat"].firstMatch.waitForExistence(timeout: 5), "the … menu has no Rename chat")
        shot("profile-card-light-menu")
        app.buttons["Rename chat"].firstMatch.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Rename chat opened no dialog")
        app.alerts.buttons["Cancel"].firstMatch.tap()
        // The Info sections, in order, each reached by scrolling.
        for section in ["Character", "Instructions (SOUL.md)", "Description", "Default model", "This chat", "Show in chats", "Home"] {
            XCTAssertTrue(reach(section), "\(section) is not on the card")
        }
        shot("profile-card-light-bottom")
        app.buttons["profile.close"].firstMatch.tap()
        XCTAssertFalse(app.buttons["profile.close"].firstMatch.waitForExistence(timeout: 3), "Close did not close the card")

        // Dark.
        app.terminate()
        launch(url: url, token: token, scheme: "dark")
        openCard()
        app.swipeUp(velocity: .fast)
        sleep(1)
        shot("profile-card-dark-top")
        XCTAssertTrue(reach("Show in chats"))
        shot("profile-card-dark-bottom")
    }
}
