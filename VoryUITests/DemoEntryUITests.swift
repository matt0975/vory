import XCTest

/// Demo mode's way in and out (#392), on a device with no gateway: the tour's "Try a demo" (its last beat, #388) opens
/// Vory on the demo's bots and chats, Settings tags the gateway "Demo" and offers Leave demo, and leaving brings back the
/// tour with nothing of the demo left. Runs on the demo copy (HERMES_E2E_BUNDLE), which keeps no gateway between
/// launches; skipped without it.
final class DemoEntryUITests: XCTestCase {
    private var app: XCUIApplication!

    private func text(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
    }

    func testTryADemoOpensTheDemoAndLeavingItGoesBack() throws {
        guard let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("HERMES_E2E_BUNDLE not set")
        }
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-companionPromptShown", "YES"]
        app.launch()

        // Try a demo is on the tour's last beat (#388): Skip goes there.
        let skip = app.buttons["onboarding.skip"].firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 30), "no tour on a device with no gateway")
        skip.tap()
        let tryDemo = app.buttons["onboarding.tryDemo"].firstMatch
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 10), "no Try a demo on the tour's last beat")
        XCTAssertEqual(tryDemo.label, "Try a demo")
        tryDemo.tap()
        XCTAssertTrue(text("Packing list for the lake weekend").firstMatch.waitForExistence(timeout: 30), "the demo's chats did not load")

        let settings = app.buttons["tab.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(text("Vory demo").firstMatch.waitForExistence(timeout: 10), "Settings does not name the demo's gateway")
        XCTAssertTrue(app.staticTexts["Demo"].firstMatch.exists, "no Demo tag by the gateway's name")
        let leave = app.buttons["settings.leaveDemo"].firstMatch
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "no Leave demo")
        XCTAssertTrue(app.buttons["settings.connectGateway"].firstMatch.exists, "no Connect your gateway")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "demo-settings"; shot.lifetime = .keepAlways; add(shot)
        leave.tap()

        XCTAssertTrue(app.buttons["onboarding.getStarted"].firstMatch.waitForExistence(timeout: 30), "leaving the demo did not go back to the tour")
        XCTAssertFalse(text("Packing list for the lake weekend").firstMatch.exists, "the demo's chats are still shown")
    }

    /// The demo offers no Companion (#494): neither the prompt nor Settings' card. Both used themselves up in the demo,
    /// and the person's own gateway, added after it, was never offered them. Started as if never offered. Nor a sign-in
    /// in Status: the demo has none, and its form could remember one under the demo's id.
    func testTheDemoOffersNoCompanionOrSignIn() throws {
        guard let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("HERMES_E2E_BUNDLE not set")
        }
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-companionPromptShown", "NO", "-notificationsSetupCardDone", "NO"]
        app.launch()
        let skip = app.buttons["onboarding.skip"].firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 30), "no tour on a device with no gateway")
        skip.tap()
        let tryDemo = app.buttons["onboarding.tryDemo"].firstMatch
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 10))
        tryDemo.tap()
        XCTAssertTrue(text("Packing list for the lake weekend").firstMatch.waitForExistence(timeout: 30), "the demo's chats did not load")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(text("Unlock Vory's full potential").firstMatch.exists, "the Companion prompt showed for the demo")
        XCTAssertFalse(text("The Companion is already here").firstMatch.exists, "the Companion prompt showed for the demo")

        let settings = app.buttons["tab.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(text("Vory demo").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(text("Unlock Vory's full potential").firstMatch.exists, "Settings offered the Companion for the demo")

        // Status is in the App section, below the fold: a row of a lazy list is only there once scrolled to.
        let status = app.buttons["settings.row.status"].firstMatch
        for _ in 0..<8 where !(status.exists && status.isHittable && status.frame.maxY < app.windows.firstMatch.frame.maxY - 120) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(status.waitForExistence(timeout: 5), "no Status in Settings")
        status.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Gateway:'")).firstMatch.waitForExistence(timeout: 10), "Status did not open")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sign-in'")).firstMatch.exists, "Status offered a sign-in for the demo")
        // The demo is never kept, so the next launch starts without it.
        app.terminate()
    }

    /// The demo has no look editor and no New bot (#494): a look edited there, a colour or a photo, went to the person's
    /// own bot of the same name, and to their other devices. Neither the Chats bar's +, a bot card's Look tab, nor the
    /// Bots page's +.
    func testTheDemoHasNoLookEditorOrNewBot() throws {
        guard let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("HERMES_E2E_BUNDLE not set")
        }
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo", "-companionPromptShown", "YES", "-launchTab", "chats"]
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Packing list' AND NOT (identifier BEGINSWITH 'chat.')")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the demo's chats did not load")
        XCTAssertFalse(app.buttons["chats.newBot"].exists, "the Chats bar offers New bot in the demo")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == 'New bot'")).firstMatch.exists, "New bot is offered in the demo")

        row.tap()
        let pill = app.buttons["chat.titlePill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 15), "no title pill")
        pill.tap()
        let instructions = app.descendants(matching: .any).matching(identifier: "profile.tab.instructions").firstMatch
        XCTAssertTrue(instructions.waitForExistence(timeout: 10), "the bot card did not open")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "profile.tab.look").firstMatch.exists, "the bot card has Look in the demo")
        app.terminate()

        app.launchArguments = ["-vory-demo", "-companionPromptShown", "YES", "-launchTab", "bots"]
        app.launch()
        XCTAssertTrue(text("Sprout").firstMatch.waitForExistence(timeout: 30), "the demo's bots did not load")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == 'New bot'")).firstMatch.exists, "the Bots page offers New bot in the demo")
        app.terminate()
    }
}
