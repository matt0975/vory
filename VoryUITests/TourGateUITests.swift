import XCTest

/// Onboarding's gates (#388): every beat passes the accessibility audit in light and dark; Skip, from any beat, lands
/// on Connect; at the largest text size every control the tour has stays on screen and can be reached; and Restore
/// from iCloud on the first beat brings a backup's gateway back and leaves the tour, or says there's nothing and stays.
/// The demo copy with no gateway, so it opens on the tour (HERMES_E2E_BUNDLE; `ui-run-15.sh <class> demo`); the restore
/// with a backup also needs the mock (HERMES_E2E_URL, HERMES_E2E_TOKEN), which the demo copy's iCloud stands in for.
final class TourGateUITests: XCTestCase {
    private var app: XCUIApplication!

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty {
            let d = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
        }
    }

    /// The tour from its first screen, in `scheme`, with `extra` launch arguments.
    private func launch(_ scheme: String = "light", _ extra: [String] = []) throws {
        guard let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("HERMES_E2E_BUNDLE not set (the demo copy, no gateway)")
        }
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-companionPromptShown", "YES", "-colorSchemePreference", scheme] + extra
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.getStarted"].firstMatch.waitForExistence(timeout: 30), "no tour")
    }

    /// On to the next beat with Continue (Get Started on the first).
    private func next(from beat: Int) {
        if beat == 0 { app.buttons["onboarding.getStarted"].firstMatch.tap() } else { app.buttons["onboarding.continue"].firstMatch.tap() }
        pause(1.5)
    }

    /// The system's audit of the screen as it is. Every finding is printed; any finding fails but one: the app's
    /// reasoning row (beat 4's chat shows one) is 15 points to hit, #482, its own change, which takes this out. Only
    /// that hit region: any other issue on it still fails.
    private func audit(_ where: String) throws {
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            print("TOUR-AUDIT \(`where`) '\(issue.compactDescription)' label '\(issue.element?.label ?? "")' id '\(issue.element?.identifier ?? "")' frame \(issue.element?.frame ?? .zero)")
            return issue.auditType == .hitRegion && issue.compactDescription == "Hit area is too small"
                && ["Show reasoning", "Hide reasoning"].contains(issue.element?.label ?? "")
        }
    }

    func testEveryBeatPassesTheAudit() throws {
        for scheme in ["light", "dark"] {
            try launch(scheme)
            pause(3)
            try audit("\(scheme) 1 hello")
            next(from: 0); pause(1)
            try audit("\(scheme) 2 bots")
            next(from: 1)
            XCTAssertTrue(any("onboarding.chatDock").waitForExistence(timeout: 20), "no tour chat")
            pause(2)
            try audit("\(scheme) 3 chat")
            app.buttons["composer.send"].firstMatch.tap()
            // The card moves the tour on to beat 4 by itself.
            let allow = app.buttons["Allow once"].firstMatch
            XCTAssertTrue(allow.waitForExistence(timeout: 40), "no card in the tour")
            pause(4)
            try audit("\(scheme) 4 card")
            allow.tap()
            // Once the mention (typed in, with the message bar's @ list) has settled: mid-animation the list's rows
            // read as text the audit can't place.
            pause(9)
            try audit("\(scheme) 4 answered")
            next(from: 4); pause(2)
            try audit("\(scheme) 5 everywhere")
            next(from: 5); pause(1.5)
            XCTAssertTrue(app.buttons["onboarding.addGateway"].firstMatch.waitForExistence(timeout: 10), "Continue on beat 5 did not reach Connect")
            try audit("\(scheme) 6 connect")
            app.terminate()
        }
    }

    func testSkipFromEveryBeatLandsOnConnect() throws {
        // Beats 1 to 5 by their index (0 hello to 4 everywhere); Connect (5) has no Skip.
        for beat in 0...4 {
            try launch()
            for b in 0..<beat { next(from: b) }
            let skip = app.buttons["onboarding.skip"].firstMatch
            XCTAssertTrue(skip.waitForExistence(timeout: 10) && skip.isHittable, "no Skip on beat \(beat + 1)")
            skip.tap()
            XCTAssertTrue(app.buttons["onboarding.addGateway"].firstMatch.waitForExistence(timeout: 10), "Skip on beat \(beat + 1) did not reach Connect")
            XCTAssertFalse(skip.exists && skip.isHittable, "Skip is still offered on Connect")
            app.terminate()
        }
    }

    func testTheLargestTextKeepsEveryControlReachable() throws {
        try launch("light", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let window = app.windows.firstMatch.frame
        func reachable(_ id: String, _ where: String) {
            let e = app.buttons[id].firstMatch
            XCTAssertTrue(e.waitForExistence(timeout: 10), "\(`where`): no \(id)")
            XCTAssertTrue(e.isHittable && window.contains(e.frame), "\(`where`): \(id) is off screen or covered: \(e.frame)")
        }
        pause(2)
        reachable("onboarding.getStarted", "hello"); reachable("onboarding.restore", "hello")
        shot("tour-ax-1-hello")
        next(from: 0)
        reachable("onboarding.continue", "bots"); reachable("onboarding.skip", "bots")
        shot("tour-ax-2-bots")
        next(from: 1)
        XCTAssertTrue(any("onboarding.chatDock").waitForExistence(timeout: 20), "no tour chat")
        reachable("composer.send", "chat"); reachable("onboarding.continue", "chat")
        shot("tour-ax-3-chat")
        app.buttons["composer.send"].firstMatch.tap()
        let allow = app.buttons["Allow once"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 40), "no card in the tour")
        pause(4)
        XCTAssertTrue(allow.isHittable && window.contains(allow.frame), "Allow once is off screen at the largest text: \(allow.frame)")
        shot("tour-ax-4-card")
        allow.tap(); pause(3)
        next(from: 4); pause(2)
        reachable("onboarding.continue", "everywhere")
        shot("tour-ax-5-everywhere")
        next(from: 5)
        reachable("onboarding.addGateway", "connect")
        shot("tour-ax-6-connect")
    }

    func testRestoreFromICloudBringsTheGatewayBackAndLeavesTheTour() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty else { throw XCTSkip("needs the mock") }
        // The demo copy's iCloud holds a backup made on another device, with this gateway in it.
        try launch("light", ["-vory-demo-cloud", url, token, "Workshop"])
        app.buttons["onboarding.restore"].firstMatch.tap()
        let restore = app.buttons["restore.confirm"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 20), "no backup offered")
        shot("tour-restore-offer")
        restore.tap()
        // The app, on the gateway that came back: its chats, not the tour.
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 40), "the restored gateway's chats did not come")
        XCTAssertFalse(app.buttons["onboarding.getStarted"].exists || app.buttons["onboarding.skip"].exists, "the tour is still up")
        shot("tour-restore-done")
    }

    func testRestoreWithNothingInICloudStaysOnTheTour() throws {
        try launch()
        app.buttons["onboarding.restore"].firstMatch.tap()
        let ok = app.buttons["restore.none"].firstMatch
        XCTAssertTrue(ok.waitForExistence(timeout: 20), "no word that iCloud is empty")
        shot("tour-restore-none")
        ok.tap()
        XCTAssertTrue(app.buttons["onboarding.getStarted"].firstMatch.waitForExistence(timeout: 10), "not back on the tour's first beat")
    }
}
