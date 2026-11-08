import XCTest

/// Demo mode's way in and out (#392), on a device with no gateway: the tour's "Try a demo" (its last beat, #388) opens
/// Vory on the demo's bots and chats, Settings tags the gateway "Demo" and offers Leave demo, and leaving brings back the
/// tour with nothing of the demo left. Runs on the demo copy (HERMES_E2E_BUNDLE), which keeps no gateway between
/// launches; skipped without it.
@MainActor
final class DemoEntryUITests: XCTestCase {
    private var app: XCUIApplication!

    private func text(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
    }

    /// A screenshot kept with the result, and written as `<name>.png` into HERMES_E2E_SHOTS when it names a folder.
    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        guard let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty else { return }
        let d = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
    }

    /// The first of `query` that is there and can be tapped, within `timeout`.
    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    /// The audit with `around` on screen: a finding on an element that overlaps it fails the test, except "Text clipped"
    /// and contrast, which are printed only (on iOS 27 the first lands on different words each run, as ApprovalCardUITests
    /// found; the stills show both); a finding elsewhere on the screen is printed, as the screen isn't this change's.
    private func audit(_ what: String, around: CGRect) throws {
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection, .textClipped, .contrast]) { issue in
            let mine = issue.element.map { $0.frame.intersects(around) } ?? false
            print("DEMO-ENTRY-AUDIT \(what) \(mine ? "mine" : "screen") '\(issue.compactDescription)' label '\(issue.element?.label ?? "")' id '\(issue.element?.identifier ?? "")'")
            return !mine || issue.auditType == .textClipped || issue.auditType == .contrast
        }
    }

    /// Each element's frame beside a still, in points, with the window's, for reading the still's contrast (#392); printed
    /// only.
    private func frames(_ still: String, _ named: [(String, XCUIElement)]) {
        let w = app.windows.firstMatch.frame
        print("DEMO-ENTRY window \(still) \(w.width) \(w.height)")
        for (name, el) in named where el.exists {
            let f = el.frame
            print("DEMO-ENTRY frame \(still) \(name) \(f.minX) \(f.minY) \(f.width) \(f.height)")
        }
    }

    /// Try a demo on the first screen (#392: where App Review looks): the tour's first beat offers it with Get Started, it
    /// opens the demo's Chats, and Leave demo in the Chats chip's menu brings the first screen back with nothing of the
    /// demo shown. The audit runs on the first beat and with the chip's menu open. HERMES_E2E_SIZE sets the text size as
    /// ApprovalCardUITests reads it (L, XL, XXL, XXXL, AccessibilityXXXL and the like); HERMES_E2E_SCHEME light or dark
    /// (light when unset, and then the stills' names don't carry it); HERMES_E2E_SHOTS names a folder for the stills;
    /// HERMES_E2E_CONNECT=1 adds the tour's last beat, by Skip, at the end. On a phone the chip is the bar's
    /// (chats.profile); on a wide window, the toolbar's.
    func testTryADemoOnTheFirstScreenAndLeaveDemoFromTheChatsMenu() throws {
        let e = ProcessInfo.processInfo.environment
        guard let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { throw XCTSkip("HERMES_E2E_BUNDLE not set") }
        continueAfterFailure = false
        let size = e["HERMES_E2E_SIZE"].flatMap { $0.isEmpty ? nil : $0 }
        let scheme = e["HERMES_E2E_SCHEME"].flatMap { $0.isEmpty ? nil : $0 }
        let tag = (size ?? "default") + (scheme.map { "-\($0)" } ?? "")
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-companionPromptShown", "YES", "-colorSchemePreference", scheme ?? "light"]
            + (size.map { ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategory\($0)"] } ?? [])
        app.launch()

        XCTAssertTrue(app.buttons["onboarding.getStarted"].firstMatch.waitForExistence(timeout: 30), "no tour on a device with no gateway")
        let first = app.buttons["onboarding.tryDemo.first"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "no Try a demo on the tour's first beat (\(tag))")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("demo-first-beat-\(tag)")
        frames("demo-first-beat-\(tag)", [("getStarted", app.buttons["onboarding.getStarted"].firstMatch), ("tryDemo", first),
                                          ("restore", app.buttons["onboarding.restore"].firstMatch),
                                          ("subtitle", text("Your Hermes agents").firstMatch)])
        XCTAssertEqual(first.label, "Try a demo")
        XCTAssertTrue(first.isHittable, "Try a demo on the first beat can't be tapped (\(tag))")
        print("DEMO-ENTRY first beat \(tag): Try a demo at \(first.frame)")
        try audit("first-beat-\(tag)", around: first.frame)
        first.tap()
        XCTAssertTrue(text("Packing list for the lake weekend").firstMatch.waitForExistence(timeout: 30), "Try a demo on the first beat didn't open the demo's chats")

        let chips = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'chats.profile' OR label BEGINSWITH 'Profile: '"))
        let chip = try XCTUnwrap(hittable(chips, timeout: 15), "no Chats chip to open")
        print("DEMO-ENTRY chip \(tag): id '\(chip.identifier)' label '\(chip.label)'")
        chip.tap()
        let leaves = app.buttons.matching(NSPredicate(format: "identifier == 'chats.leaveDemo' OR label == 'Leave demo'"))
        let leave = try XCTUnwrap(hittable(leaves, timeout: 10), "no Leave demo in the Chats chip's menu")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        shot("demo-chats-menu-\(tag)")
        frames("demo-chats-menu-\(tag)", [("leaveDemo", leave)])
        try audit("chats-menu-\(tag)", around: leave.frame)
        leave.tap()

        XCTAssertTrue(app.buttons["onboarding.getStarted"].firstMatch.waitForExistence(timeout: 30), "Leave demo in the Chats menu didn't bring back the first screen")
        XCTAssertTrue(app.buttons["onboarding.tryDemo.first"].firstMatch.waitForExistence(timeout: 10), "the first screen came back without Try a demo")
        XCTAssertFalse(text("Packing list for the lake weekend").firstMatch.exists, "the demo's chats are still shown")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("demo-first-beat-after-\(tag)")
        if e["HERMES_E2E_CONNECT"] == "1" {
            // The tour's last beat, which shares the first beat's column (its scroll at the largest text), by Skip.
            app.buttons["onboarding.skip"].firstMatch.tap()
            XCTAssertTrue(app.buttons["onboarding.addGateway"].firstMatch.waitForExistence(timeout: 10), "Skip didn't reach the tour's last beat")
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            shot("tour-connect-\(tag)")
            frames("tour-connect-\(tag)", [("addGateway", app.buttons["onboarding.addGateway"].firstMatch),
                                           ("tryDemo", app.buttons["onboarding.tryDemo"].firstMatch),
                                           ("setupHelp", app.descendants(matching: .any)["onboarding.setupHelp"].firstMatch),
                                           ("subtitle", text("need a Hermes gateway").firstMatch)])
        }
        app.terminate()
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
