import XCTest

/// Onboarding's beat 4 plays itself (#490, Matt: "let's do just plays itself"): after the answer the mention types
/// itself, the message bar's list of bots comes up and Gizmo is picked, with no keyboard. Taps on the bar, the list and
/// the card then change nothing: no keyboard, the mention isn't typed over or started again, and the card stays in
/// view. VoiceOver reads the bar as its words, not as a field. A still of the list, in each bot's own look, light and
/// dark, on a first launch and in a replay over a gateway. The demo copy (HERMES_E2E_BUNDLE); the replay also needs the
/// mock (HERMES_E2E_URL, HERMES_E2E_TOKEN).
final class TourMentionUITests: XCTestCase {
    private var app: XCUIApplication!
    private static let mention = "@gizmo can you keep an eye on disk space?"

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

    /// The tour from its first screen: a first launch (no gateway), or a replay from Troubleshooting over the mock's.
    private func launch(_ scheme: String, replay: Bool, hold: Bool = true) throws {
        let e = ProcessInfo.processInfo.environment
        guard let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { throw XCTSkip("HERMES_E2E_BUNDLE not set (the demo copy)") }
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: bundle)
        // The list of bots held up for 8 s rather than 1.4 (DEBUG): a reading of the screen here can take two seconds.
        var args = ["-companionPromptShown", "YES", "-colorSchemePreference", scheme, "-vory-ax-oracle"] + (hold ? ["-vory-tour-list-hold", "8"] : [])
        if replay {
            guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty else { throw XCTSkip("the replay needs the mock") }
            args = ["-vory-demo-gateway", url, token, "Workshop", "-launchTab", "settings"] + args
        }
        app.launchArguments = args
        app.launch()
        if replay {
            XCTAssertTrue(any("settings.row.profile").waitForExistence(timeout: 30), "no Settings rows")
            let row = any("settings.row.troubleshooting")
            let limit = app.windows.firstMatch.frame.maxY - 150
            for _ in 0..<16 where !(row.exists && row.isHittable && row.frame.maxY < limit) { app.swipeUp(velocity: .slow); pause(0.6) }
            row.tap(); pause(1.5)
            let replayRow = any("troubleshooting.replayTour")
            for _ in 0..<24 where !(replayRow.exists && replayRow.isHittable && replayRow.frame.maxY < limit) { app.swipeUp(velocity: .fast); pause(0.4) }
            replayRow.tap()
        }
        XCTAssertTrue(app.buttons["onboarding.getStarted"].firstMatch.waitForExistence(timeout: 30), "no tour")
    }

    /// From the first beat to beat 4's answer: Get Started, Continue, Send, Allow once.
    private func answerTheCard() {
        app.buttons["onboarding.getStarted"].firstMatch.tap(); pause(1.5)
        app.buttons["onboarding.continue"].firstMatch.tap()
        XCTAssertTrue(any("onboarding.chatDock").waitForExistence(timeout: 20), "no tour chat")
        pause(2)
        XCTAssertEqual(app.keyboards.count, 0, "a keyboard on beat 3")
        app.buttons["composer.send"].firstMatch.tap()
        let allow = app.buttons["Allow once"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 40), "no card in the tour's chat")
        pause(2)
        allow.tap()
    }

    /// The bar's list of bots is up: "@Gi" typed in, the moment before Gizmo is picked from it (the list's rows are part
    /// of the bar's one piece of text while the beat plays, so the bar's value says when).
    private func waitForTheList() {
        let dock = any("onboarding.chatDock")
        wait(for: [expectation(for: NSPredicate(format: "value == '@Gi'"), evaluatedWith: dock)], timeout: 15)
        pause(0.4)
    }

    /// What VoiceOver stops on now, from the app's DEBUG oracle (`-vory-ax-oracle`, `VoiceOverOracle`): XCUITest's own tree
    /// also lists what VoiceOver skips, among them the parts of an element read as one.
    private func voiceOverStops() -> [String] {
        let oracle = any("debug.voiceover")
        guard oracle.waitForExistence(timeout: 5) else { XCTFail("no VoiceOver oracle (-vory-ax-oracle)"); return [] }
        return ((oracle.value as? String) ?? "").split(separator: "\n").map { String($0.split(separator: "|", maxSplits: 1).first ?? "") }
    }

    /// How many of VoiceOver's stops read "Message": the bar read as one, and its field when that's offered as well.
    /// (Printed as "VO-STOPS", so a run says what the stops were, not only how many.)
    private func messageStops() -> Int {
        let stops = voiceOverStops()
        print("VO-STOPS \(stops.joined(separator: " / "))")
        return stops.filter { $0 == "Message" }.count
    }

    /// The card's frame stays inside the window.
    private func checkTheCardInView(_ when: String) {
        let card = any("onboarding.chatDock")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(card.exists && window.contains(card.frame.insetBy(dx: 1, dy: 1)), "\(when): the tour's chat bar left the screen: \(card.frame)")
        XCTAssertEqual(app.keyboards.count, 0, "\(when): a keyboard came up")
    }

    func testBeatFourPlaysItselfAndTapsChangeNothing() throws {
        try launch("light", replay: false)
        answerTheCard()
        // While the mention types itself (the list up after "@Gi"), and once it's in: taps on the bar, its list and the
        // card's place.
        let dock = any("onboarding.chatDock")
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        waitForTheList()
        shot("490-list-light-first-launch-taps")
        for (i, at) in [CGVector(dx: 0.5, dy: 0.85), CGVector(dx: 0.3, dy: 0.5), CGVector(dx: 0.5, dy: 0.15)].enumerated() {
            dock.coordinate(withNormalizedOffset: at).tap(); pause(0.6)
            checkTheCardInView("tap \(i + 1)")
        }
        // The mention ends as written, never typed over or started again.
        let done = NSPredicate(format: "value == %@", Self.mention)
        wait(for: [expectation(for: done, evaluatedWith: dock)], timeout: 10)
        XCTAssertEqual(dock.label, "Message", "the bar isn't read as one piece of text while the beat plays")
        XCTAssertEqual(messageStops(), 1, "VoiceOver stops on the bar's field as well as the bar while the beat plays")
        pause(3)
        XCTAssertEqual(dock.value as? String, Self.mention, "the mention changed after it was in")
        checkTheCardInView("at rest")
        shot("490-beat4-done")
    }

    /// The bots' list in each bot's own look, in light and dark: on a first launch, and in a replay over a gateway (where
    /// the app's demo looks stay off and the list showed the plain faces).
    func testTheListOfBotsWearsEachBotsOwnLook() throws {
        for replay in [false, true] {
            for scheme in ["light", "dark"] {
                try launch(scheme, replay: replay)
                answerTheCard()
                waitForTheList()
                shot("490-list-\(scheme)-\(replay ? "replay" : "first-launch")")
                app.terminate()
            }
        }
    }

    /// The app's own list of bots, for the still beside the tour's: Demo mode's chat, "@Gi" typed, light and dark.
    func testTheAppsOwnListOfBotsInTheDemo() throws {
        guard let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { throw XCTSkip("HERMES_E2E_BUNDLE not set") }
        for scheme in ["light", "dark"] {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo", "-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", scheme]
            app.launch()
            let chat = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Packing list for the lake weekend'")).firstMatch
            XCTAssertTrue(chat.waitForExistence(timeout: 30), "the demo's chats did not load")
            chat.tap(); pause(1.5)
            let field = app.textViews["composer.text"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 20))
            field.tap(); field.typeText("@Gi"); pause(1)
            shot("490-app-list-\(scheme)")
            app.terminate()
        }
    }

    /// At its own pace (the list up 1.4 s, no hold): beat 4 ends with the mention in, read as the bar's text.
    func testBeatFourEndsWithTheMentionAtItsOwnPace() throws {
        try launch("light", replay: false, hold: false)
        answerTheCard()
        let dock = any("onboarding.chatDock")
        wait(for: [expectation(for: NSPredicate(format: "value == %@", Self.mention), evaluatedWith: dock)], timeout: 30)
        XCTAssertEqual(dock.label, "Message")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Page 4 of 6'")).firstMatch.exists, "not on beat 4")
    }

    /// The bar's field leaves VoiceOver's reach only while beat 4 plays: after the app has been away and back it's still
    /// out, and once the tour is left mid-beat a chat's field is there again. A replay (Skip goes to the last page, Done
    /// closes it), and a first launch (Skip, then Try a demo).
    func testTheFieldIsBackInAChatAfterLeavingBeatFour() throws {
        try launch("light", replay: true)
        answerTheCard()
        waitForTheList()
        XCTAssertEqual(messageStops(), 1, "VoiceOver stops on the field as well as the bar while beat 4 plays")
        XCUIDevice.shared.press(.home); pause(2)
        app.activate(); pause(2)
        XCTAssertEqual(any("onboarding.chatDock").label, "Message", "beat 4 lost its reading after the app was away")
        XCTAssertEqual(messageStops(), 1, "VoiceOver stops on the field again while beat 4 plays, after the app was away")
        app.buttons["onboarding.skip"].firstMatch.tap(); pause(1.5)
        let done = app.buttons["onboarding.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Skip in a replay did not reach the last page")
        done.tap(); pause(1.5)
        app.buttons["tab.chats"].firstMatch.tap(); pause(1.5)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup' AND identifier != 'chat.titlePill'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no Disk cleanup chat")
        row.tap()
        XCTAssertTrue(app.textViews["composer.text"].firstMatch.waitForExistence(timeout: 15), "a chat's field is gone after the replay was left on beat 4")
        XCTAssertGreaterThanOrEqual(messageStops(), 1, "VoiceOver doesn't reach a chat's field after the replay was left on beat 4")
        app.terminate()

        try launch("light", replay: false)
        answerTheCard()
        waitForTheList()
        app.buttons["onboarding.skip"].firstMatch.tap()
        let demo = app.buttons["onboarding.tryDemo"].firstMatch
        XCTAssertTrue(demo.waitForExistence(timeout: 10), "Skip did not reach Connect")
        demo.tap()
        let chat = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Packing list for the lake weekend'")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 30), "the demo's chats did not load")
        chat.tap()
        XCTAssertTrue(app.textViews["composer.text"].firstMatch.waitForExistence(timeout: 15), "a demo chat's field is gone after the tour was left on beat 4")
        XCTAssertGreaterThanOrEqual(messageStops(), 1, "VoiceOver doesn't reach a demo chat's field after the tour was left on beat 4")
    }

    /// Beat 4 passes the audit with the list of bots up and once the mention is in.
    func testBeatFourPassesTheAudit() throws {
        try launch("light", replay: false)
        answerTheCard()
        waitForTheList()
        try audit("list up")
        let done = NSPredicate(format: "value == %@", Self.mention)
        wait(for: [expectation(for: done, evaluatedWith: any("onboarding.chatDock"))], timeout: 15)
        try audit("mention in")
    }

    private func audit(_ when: String) throws {
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            print("MENTION-AUDIT \(when) '\(issue.compactDescription)' label '\(issue.element?.label ?? "")' id '\(issue.element?.identifier ?? "")' frame \(issue.element?.frame ?? .zero)")
            // The app's reasoning row's hit region is #482's (filed, open), by its exact finding, as in the tour's gate:
            // anything else on that toggle still fails. Out when #482 is fixed.
            return issue.auditType == .hitRegion && issue.compactDescription == "Hit area is too small"
                && ["Show reasoning", "Hide reasoning"].contains(issue.element?.label ?? "")
        }
    }
}
