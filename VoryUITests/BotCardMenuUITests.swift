import XCTest

/// A bot's menu on Bots is behind press and hold only (feedback on 1.5 (21): "Remove 3 dots so it's
/// just press and hold"). The default bot's menu has no Rename or Delete; another bot's ends with
/// Delete bot…, which asks first. The lift shows the bot and its pill only: frames of it are kept
/// in light and dark.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=com.vorantx.vory.demo
/// drives the demo copy.
@MainActor
final class BotCardMenuUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func launch(url: String, token: String, scheme: String) {
        let args = ["-companionPromptShown", "YES", "-launchTab", "bots", "-colorSchemePreference", scheme]
            + (ProcessInfo.processInfo.environment["HERMES_E2E_ARGS"] ?? "").split(separator: " ").map(String.init)
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }

    /// The menu's items, by their labels, while it is open.
    private func menuItems() -> [String] {
        ["New chat", "Chats", "Make active", "Edit bot…", "Rename bot…", "Bot settings", "Delete bot…"].filter { app.buttons[$0].exists }
    }

    func testPressAndHoldOpensEachBotsMenu() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, scheme: "light")
        let main = any("bots.card.default"), work = any("bots.card.work")
        XCTAssertTrue(main.waitForExistence(timeout: 30), "no default card on Bots")
        XCTAssertTrue(work.waitForExistence(timeout: 5), "no work card on Bots")
        pause(2)
        // No … left on any card.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Actions for'")).firstMatch.exists, "a card still has its …")
        XCTAssertFalse(any("bots.actions.default").exists, "the default card still has its …")

        // The default bot: no Rename, no Delete.
        main.press(forDuration: 1.0); pause(1)
        let mainItems = menuItems()
        print("CARD-MENU default: \(mainItems)")
        XCTAssertTrue(mainItems.contains("New chat") && mainItems.contains("Edit bot…") && mainItems.contains("Bot settings"), "the default bot's menu is missing items: \(mainItems)")
        XCTAssertFalse(mainItems.contains("Delete bot…") || mainItems.contains("Rename bot…"), "the default bot's menu offers Rename or Delete: \(mainItems)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap(); pause(1)

        // Another bot: Delete bot… last, and it asks first.
        work.press(forDuration: 1.0); pause(1)
        let workItems = menuItems()
        print("CARD-MENU work: \(workItems)")
        XCTAssertEqual(workItems.last, "Delete bot…", "another bot's menu does not end with Delete bot…: \(workItems)")
        app.buttons["Delete bot…"].tap(); pause(1)
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete bot'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Delete bot… did not ask first")
        shot("delete-asks")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
        pause(1)
        XCTAssertTrue(work.exists, "the work bot went after Cancel")
    }

    /// The lift, in light and dark: frames while the menu opens, open, and as it closes.
    func testTheLiftShowsTheBotAndItsPill() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        for scheme in ["light", "dark"] {
            if app != nil { app.terminate() }
            launch(url: url, token: token, scheme: scheme)
            let work = any("bots.card.work")
            XCTAssertTrue(work.waitForExistence(timeout: 30), "no work card on Bots")
            pause(2)
            print("CARD-LIFT \(scheme) card \(work.frame)")
            shot("\(scheme)-rest")
            nonisolated(unsafe) var shots: [XCUIScreenshot] = []
            for t in stride(from: 0.3, through: 1.5, by: 0.15) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { shots.append(XCUIScreen.main.screenshot()) } }
            }
            work.press(forDuration: 1.0); pause(1.2)
            for (i, s) in shots.enumerated() { let a = XCTAttachment(screenshot: s); a.name = "\(scheme)-lift-\(i)"; a.lifetime = .keepAlways; add(a) }
            shot("\(scheme)-open")
            XCTAssertTrue(app.buttons["New chat"].exists, "the menu did not open")
            // The drop back.
            nonisolated(unsafe) var back: [XCUIScreenshot] = []
            for t in stride(from: 0.05, through: 0.65, by: 0.1) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { back.append(XCUIScreen.main.screenshot()) } }
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap(); pause(1)
            for (i, s) in back.enumerated() { let a = XCTAttachment(screenshot: s); a.name = "\(scheme)-drop-\(i)"; a.lifetime = .keepAlways; add(a) }
        }
    }
}
