import XCTest

/// The bot's card from a chat's title pill (#282): a hero header (face, name, description as
/// one VoiceOver element), round Close and … buttons over it, a row of tabs read as a tab bar,
/// and one section per tab: This chat (the default from a chat, with the rename row, #286),
/// Look, Instructions, Model, Display. Light, then dark in a second launch; pictures land where
/// HERMES_E2E_SHOTS says.
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

    private func any(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Anything whose label carries the words: a row's text, a button ("Reset to default"), a link.
    private func labelled(_ fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
    }

    private func openCard() {
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let pill = app.buttons["chat.titlePill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "no title pill")
        pill.tap()
        XCTAssertTrue(any("profile.header").waitForExistence(timeout: 10), "the card's header did not show")
    }

    /// Taps a tab and scrolls its section until a word of it is on screen (a row below the
    /// fold does not exist to the tree until it is scrolled to).
    private func show(_ tab: String, expecting fragment: String) {
        // The tab row sits under the header: back up to it first when the sheet is scrolled.
        var t = any("profile.tab.\(tab)")
        for _ in 0..<6 where !(t.exists && t.isHittable) {
            app.swipeDown(velocity: .slow)
            t = any("profile.tab.\(tab)")
        }
        XCTAssertTrue(t.waitForExistence(timeout: 5), "no \(tab) tab")
        t.tap()
        var found = labelled(fragment).waitForExistence(timeout: 3)
        for _ in 0..<6 where !found {
            app.swipeUp(velocity: .slow)
            found = labelled(fragment).waitForExistence(timeout: 1)
        }
        XCTAssertTrue(found, "\(tab) does not show \(fragment)")
    }

    func testTheCardHasItsHeaderButtonsAndTabsInLightAndDark() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        launch(url: url, token: token, scheme: "light")
        openCard()
        // The header is one element: the name and the line under it.
        let header = any("profile.header")
        XCTAssertTrue(header.label.contains("default"), "the header does not read the bot's name: \(header.label)")
        XCTAssertTrue(app.buttons["profile.close"].firstMatch.exists, "no Close over the header")
        let more = app.buttons["profile.more"].firstMatch
        XCTAssertTrue(more.exists, "no … over the header")
        // The card opens at the medium height; the tall one for the pictures.
        app.swipeUp(velocity: .fast)
        sleep(1)
        // The tab row is there; from a chat, This chat is on show with the rename row.
        XCTAssertTrue(any("profile.tabs").waitForExistence(timeout: 5), "no tab row")
        XCTAssertTrue(text("Context").firstMatch.waitForExistence(timeout: 5), "This chat is not the tab on show from a chat")
        shot("profile-card-light-this-chat")
        let nameRow = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Name'")).firstMatch
        XCTAssertTrue(nameRow.waitForExistence(timeout: 5), "no Name row")
        nameRow.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "the Name row opened no dialog")
        app.alerts.buttons["Cancel"].firstMatch.tap()
        // The … menu's Rename reaches the same dialog.
        more.tap()
        XCTAssertTrue(app.buttons["Rename chat"].firstMatch.waitForExistence(timeout: 5), "the … menu has no Rename chat")
        shot("profile-card-light-menu")
        app.buttons["Rename chat"].firstMatch.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Rename chat opened no dialog")
        app.alerts.buttons["Cancel"].firstMatch.tap()
        // Each tab shows its own section.
        show("look", expecting: "Reset to default")
        shot("profile-card-light-look")
        show("instructions", expecting: "Instructions (SOUL.md)")
        XCTAssertTrue(labelled("Description").exists, "Instructions does not carry the description")
        show("model", expecting: "Writes this profile")
        XCTAssertTrue(labelled("Home").exists, "Model does not end with the home path")
        show("display", expecting: "Show in chats")
        shot("profile-card-light-display")
        show("thisChat", expecting: "Context")
        app.buttons["profile.close"].firstMatch.tap()
        XCTAssertFalse(app.buttons["profile.close"].firstMatch.waitForExistence(timeout: 3), "Close did not close the card")
        // From the chat itself: the … menu and a long press on the pill both offer Rename chat (#286).
        app.buttons["chat.more"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Rename chat"].firstMatch.waitForExistence(timeout: 5), "the chat's menu has no Rename chat")
        app.buttons["Rename chat"].firstMatch.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Rename chat from the menu opened no dialog")
        app.alerts.buttons["Cancel"].firstMatch.tap()
        app.buttons["chat.titlePill"].firstMatch.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Rename chat"].firstMatch.waitForExistence(timeout: 5), "a long press on the pill offers no Rename chat")
        shot("rename-from-pill")
        app.buttons["Rename chat"].firstMatch.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Rename chat from the pill opened no dialog")
        app.alerts.buttons["Cancel"].firstMatch.tap()

        // Dark.
        app.terminate()
        launch(url: url, token: token, scheme: "dark")
        openCard()
        app.swipeUp(velocity: .fast)
        sleep(1)
        shot("profile-card-dark-this-chat")
        show("look", expecting: "Reset to default")
        shot("profile-card-dark-look")
        show("display", expecting: "Show in chats")
        shot("profile-card-dark-display")
    }
}
