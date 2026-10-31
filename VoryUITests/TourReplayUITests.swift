import XCTest

/// "Replay the welcome tour" (#487): Settings › Troubleshooting's row (a Debug build, so it is offered) opens the tour
/// over the app on its first beat, with no Restore from iCloud; every beat passes the audit in light and dark, and so
/// does Troubleshooting with the row; Skip, Done on the last beat, Connect then Cancel, and Try a demo then Leave demo
/// each come back with the app as it was (`AppFingerprint`, `-vory-app-fingerprint`: the settings, gateways, chats, looks
/// and widgets); and with the demo already on, Try a demo is not offered. The demo copy over the mock (HERMES_E2E_URL,
/// HERMES_E2E_TOKEN, HERMES_E2E_BUNDLE).
final class TourReplayUITests: XCTestCase {
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

    private func launch(_ scheme: String = "light", _ extra: [String] = []) throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("needs the demo copy over the mock (HERMES_E2E_URL / TOKEN / BUNDLE)")
        }
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "settings",
                               "-colorSchemePreference", scheme, "-vory-app-fingerprint"] + extra
        app.launch()
    }

    /// Settings › Troubleshooting, scrolled down to the replay's row.
    private func openTroubleshooting() {
        XCTAssertTrue(any("settings.row.profile").waitForExistence(timeout: 30), "no Settings rows")
        let row = any("settings.row.troubleshooting")
        let limit = app.windows.firstMatch.frame.maxY - 150
        for _ in 0..<16 where !(row.exists && row.isHittable && row.frame.maxY < limit) { app.swipeUp(velocity: .slow); pause(0.6) }
        row.tap(); pause(1.5)
        let replay = any("troubleshooting.replayTour")
        for _ in 0..<24 where !(replay.exists && replay.isHittable && replay.frame.maxY < limit) { app.swipeUp(velocity: .fast); pause(0.4) }
        XCTAssertTrue(replay.exists && replay.isHittable, "no Replay the welcome tour on Troubleshooting")
    }

    /// The app's fingerprint: one part a line, "part=hash".
    private func fingerprint() -> [String: String] {
        let e = any("debug.appfingerprint")
        guard e.waitForExistence(timeout: 5), let v = e.value as? String else { XCTFail("no fingerprint (-vory-app-fingerprint)"); return [:] }
        let pairs = v.split(separator: "\n").compactMap { line -> (String, String)? in
            let p = line.split(separator: "=", maxSplits: 1)
            return p.count == 2 ? (String(p[0]), String(p[1])) : nil
        }
        return Dictionary(pairs, uniquingKeysWith: { a, _ in a })
    }

    /// The app as it was before the replay: every part of its fingerprint the same.
    private func checkUnchanged(_ before: [String: String], _ how: String) {
        pause(2)
        let after = fingerprint()
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
        print("REPLAY-TRACE \(how): \(before.count) parts, changed \(changed.map { "\($0) \(before[$0] ?? "-") -> \(after[$0] ?? "-")" })")
        XCTAssertTrue(changed.isEmpty, "\(how): the app changed: \(changed)")
    }

    private func startReplay() {
        any("troubleshooting.replayTour").tap()
        XCTAssertTrue(app.buttons["onboarding.getStarted"].firstMatch.waitForExistence(timeout: 10), "the replay did not open on its first beat")
        XCTAssertFalse(any("onboarding.restore").exists, "the replay offers Restore from iCloud")
    }

    /// From the first beat to the last with Get Started and Continue.
    private func toConnect() {
        app.buttons["onboarding.getStarted"].firstMatch.tap(); pause(1.5)
        toConnectFromHere()
    }

    /// On the last beat: its Done is up (the pages lie side by side in the tree, so the last beat's buttons exist from
    /// the beat before it).
    private var onLastBeat: Bool { app.buttons["onboarding.done"].firstMatch.exists }

    private func backOnTroubleshooting(_ how: String) {
        XCTAssertTrue(any("troubleshooting.replayTour").waitForExistence(timeout: 10), "\(how): not back on Troubleshooting")
        XCTAssertFalse(app.buttons["onboarding.getStarted"].exists || app.buttons["onboarding.addGateway"].exists, "\(how): the tour is still up")
    }

    /// The system's audit, as the tour's gate has it (#388): any finding fails but the app's reasoning row's hit region
    /// (#482, by its exact finding: anything else on that toggle still fails; out when #482 is fixed).
    private func audit(_ where: String) throws {
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            print("REPLAY-AUDIT \(`where`) '\(issue.compactDescription)' label '\(issue.element?.label ?? "")' id '\(issue.element?.identifier ?? "")' frame \(issue.element?.frame ?? .zero)")
            return issue.auditType == .hitRegion && issue.compactDescription == "Hit area is too small"
                && ["Show reasoning", "Hide reasoning"].contains(issue.element?.label ?? "")
        }
    }

    /// The fingerprint holds still with no replay over the same time: what a replay test finds changed is the replay's.
    func testTheFingerprintHoldsStillWithoutAReplay() throws {
        try launch()
        openTroubleshooting(); pause(2)
        let before = fingerprint()
        pause(30)
        checkUnchanged(before, "no replay, 30 s")
    }

    func testSkipGoesToTheLastPageAndDoneComesBackWithTheAppAsItWas() throws {
        try launch()
        openTroubleshooting(); pause(2)
        let before = fingerprint()
        startReplay()
        shot("487-replay-1")
        app.buttons["onboarding.getStarted"].firstMatch.tap(); pause(1.5)
        // Skip goes to the last page, as on a first launch (#492); Done there comes back.
        app.buttons["onboarding.skip"].firstMatch.tap(); pause(1.5)
        XCTAssertTrue(app.buttons["onboarding.done"].firstMatch.waitForExistence(timeout: 5), "a replay's Skip did not go to the last page")
        XCTAssertTrue(app.buttons["onboarding.addGateway"].firstMatch.isHittable, "a replay's Skip did not go to the last page")
        app.buttons["onboarding.done"].firstMatch.tap(); pause(1.5)
        backOnTroubleshooting("Skip then Done")
        checkUnchanged(before, "Skip then Done")
    }

    /// Through every beat, the tour's own chat sent and its card answered, then Done on the last.
    func testDoneOnTheLastBeatComesBackWithTheAppAsItWas() throws {
        try launch()
        openTroubleshooting(); pause(2)
        let before = fingerprint()
        startReplay()
        app.buttons["onboarding.getStarted"].firstMatch.tap(); pause(1.5)
        app.buttons["onboarding.continue"].firstMatch.tap()
        XCTAssertTrue(any("onboarding.chatDock").waitForExistence(timeout: 20), "no tour chat")
        pause(2)
        app.buttons["composer.send"].firstMatch.tap()
        let allow = app.buttons["Allow once"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 40), "no card in the tour's chat")
        pause(2); allow.tap(); pause(6)
        toConnectFromHere()
        shot("487-replay-6")
        let done = app.buttons["onboarding.done"].firstMatch
        XCTAssertTrue(done.exists && done.isHittable, "no Done on the replay's last beat")
        done.tap(); pause(1.5)
        backOnTroubleshooting("Done")
        checkUnchanged(before, "Done after the tour's chat")
    }

    private func toConnectFromHere() {
        for _ in 0..<6 where !onLastBeat {
            let next = app.buttons["onboarding.continue"].firstMatch
            guard next.waitForExistence(timeout: 5) else { break }
            next.tap(); pause(1.5)
        }
        XCTAssertTrue(app.buttons["onboarding.done"].firstMatch.waitForExistence(timeout: 10), "the replay did not reach its last beat (no Done)")
    }

    func testConnectThenCancelComesBackWithTheAppAsItWas() throws {
        try launch()
        openTroubleshooting(); pause(2)
        let before = fingerprint()
        startReplay(); toConnect()
        app.buttons["onboarding.addGateway"].firstMatch.tap()
        let cancel = app.navigationBars.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Connect your gateway did not open the form")
        shot("487-replay-form")
        cancel.tap(); pause(1.5)
        backOnTroubleshooting("Connect then Cancel")
        checkUnchanged(before, "Connect then Cancel")
    }

    func testTryADemoThenLeaveComesBackToTheGateway() throws {
        try launch()
        openTroubleshooting(); pause(2)
        let before = fingerprint()
        XCTAssertEqual(before["demo"], "false", "the demo was on before the replay")
        startReplay(); toConnect()
        let demo = app.buttons["onboarding.tryDemo"].firstMatch
        XCTAssertTrue(demo.exists && demo.isHittable, "no Try a demo on the replay's last beat")
        demo.tap(); pause(3)
        XCTAssertFalse(app.buttons["onboarding.addGateway"].exists, "the tour stayed up over the demo")
        XCTAssertEqual(fingerprint()["demo"], "true", "Try a demo did not start the demo")
        // Leave demo, on Settings.
        any("tab.settings").tap(); pause(1)
        for _ in 0..<4 where any("page.back").exists { any("page.back").tap(); pause(1) }
        let leave = any("settings.leaveDemo")
        for _ in 0..<8 where !(leave.exists && leave.isHittable) { app.swipeDown(velocity: .fast); pause(0.4) }
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "no Leave demo on Settings")
        leave.tap(); pause(3)
        checkUnchanged(before, "Try a demo then Leave demo")
        // Nothing of the demo's is left under its connection, whatever was there before the replay (#493).
        XCTAssertEqual(fingerprint()["demoKeys"], "none", "a setting of the demo's survived Leave demo")
    }

    /// With the demo already on, the replay's last beat does not offer it again.
    func testWithTheDemoOnTryADemoIsNotOffered() throws {
        try launch("light", ["-vory-demo"])
        openTroubleshooting()
        startReplay(); toConnect()
        XCTAssertFalse(app.buttons["onboarding.tryDemo"].exists, "Try a demo offered while the demo is on")
        app.buttons["onboarding.done"].firstMatch.tap(); pause(1.5)
        backOnTroubleshooting("Done in the demo")
    }

    /// A tour replayed with Demo mode on raises no notification question (#501 asks on the demo's own first message, not
    /// the tour's): no Springboard alert at the tour's Send or after its card, and the question still unanswered after.
    /// Needs the demo copy freshly installed, its question unanswered.
    func testAReplayInTheDemoAsksForNoNotifications() throws {
        try launch("light", ["-vory-demo", "-vory-notify-readout"])
        _ = fingerprint(); pause(1)
        XCTAssertEqual(fingerprint()["notify"], "notDetermined", "the notification question was already answered on this install")
        openTroubleshooting()
        startReplay()
        app.buttons["onboarding.getStarted"].firstMatch.tap(); pause(1.5)
        app.buttons["onboarding.continue"].firstMatch.tap()
        XCTAssertTrue(any("onboarding.chatDock").waitForExistence(timeout: 20), "no tour chat")
        pause(2)
        app.buttons["composer.send"].firstMatch.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = app.buttons["Allow once"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 40), "no card in the tour")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "a system question came up at the tour's Send: \(springboard.alerts.firstMatch.label)")
        allow.tap(); pause(4)
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "a system question came up after the tour's card: \(springboard.alerts.firstMatch.label)")
        toConnectFromHere()
        app.buttons["onboarding.done"].firstMatch.tap(); pause(1.5)
        backOnTroubleshooting("Done in the demo")
        _ = fingerprint(); pause(1)
        XCTAssertEqual(fingerprint()["notify"], "notDetermined", "the notification question was asked during the tour")
    }

    func testTroubleshootingAndEveryBeatOfTheReplayPassTheAudit() throws {
        for scheme in ["light", "dark"] {
            try launch(scheme)
            openTroubleshooting(); pause(1)
            try audit("\(scheme) troubleshooting")
            startReplay(); pause(3)
            try audit("\(scheme) 1 hello")
            app.buttons["onboarding.getStarted"].firstMatch.tap(); pause(2.5)
            try audit("\(scheme) 2 bots")
            app.buttons["onboarding.continue"].firstMatch.tap()
            XCTAssertTrue(any("onboarding.chatDock").waitForExistence(timeout: 20), "no tour chat")
            pause(2)
            try audit("\(scheme) 3 chat")
            app.buttons["composer.send"].firstMatch.tap()
            let allow = app.buttons["Allow once"].firstMatch
            XCTAssertTrue(allow.waitForExistence(timeout: 40), "no card in the tour")
            pause(4)
            try audit("\(scheme) 4 card")
            allow.tap(); pause(9)
            try audit("\(scheme) 4 answered")
            app.buttons["onboarding.continue"].firstMatch.tap(); pause(2)
            try audit("\(scheme) 5 everywhere")
            toConnectFromHere()
            try audit("\(scheme) 6 connect")
            app.buttons["onboarding.done"].firstMatch.tap(); pause(1)
            app.terminate()
        }
    }
}
