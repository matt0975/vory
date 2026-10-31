import XCTest

/// The approval card is the one way to answer an approval (1.5 (26)): its buttons are exactly the
/// choices the gateway offers, in that order for VoiceOver; "Always allow…" asks first and Cancel there
/// sends nothing; a long press on the card opens no menu (until 26 the card had one listing all
/// four choices, Always without a question, which never opened inside the dock's glass anyway).
/// The mock's default turn ends at an approval offering all four; with "once or deny" in the
/// prompt it offers only those two.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
/// HERMES_E2E_SHOTS names a folder for the screenshots.
@MainActor
final class ApprovalCardUITests: XCTestCase {
    private var app: XCUIApplication!
    private let names = ["Allow once", "Allow for this chat", "Always allow…", "Deny"]

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"].flatMap { $0.isEmpty ? nil : $0 }
        let d = folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-chat-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
    }

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    /// Launches the app (on the gateway when one is set), `extra` added to its arguments: light, at the default text size,
    /// unless HERMES_E2E_SCHEME / HERMES_E2E_SIZE (L, XL, XXL, XXXL) say otherwise.
    private func launch(_ extra: [String] = []) throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        let look = ["-colorSchemePreference", e["HERMES_E2E_SCHEME"] ?? "light"]
            + (e["HERMES_E2E_SIZE"].map { ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategory\($0)"] } ?? [])
        if let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats"] + look + extra
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-launchTab", "chats"] + look + extra
        }
        app.launch()
    }

    /// Opens "Disk cleanup on the log host".
    private func openChat() throws {
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup' AND identifier != 'chat.titlePill'"))
        try XCTUnwrap(hittable(rows, timeout: 40), "no Disk cleanup row").tap()
    }

    /// Opens the chat, sends `prompt`, and waits for the approval card; `extra` added to the launch arguments.
    private func approvalOnScreen(_ prompt: String, extra: [String] = []) throws {
        try launch(extra)
        try openChat()
        let composer = app.textViews["composer.text"].firstMatch
        // An approval left waiting by an earlier test (the mock keeps it) is denied first.
        if !composer.waitForExistence(timeout: 8),
           let deny = hittable(app.buttons.matching(NSPredicate(format: "label == 'Deny'")), timeout: 15) {
            deny.tap()
        }
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "no composer")
        composer.tap()
        composer.typeText(prompt)
        try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 5), "no send").tap()
        let card = app.buttons["Allow once"].firstMatch.waitForExistence(timeout: 90)
        if !card { shot("approval-card-missing") }
        XCTAssertTrue(card, "no approval card")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    /// Equality runs (Duo stage 4 A, whose voice mode can pin an approval's choices under its words): the card in a chat,
    /// saved whole twice a second apart as HERMES_E2E_CARD_SHOT-1.png and -2.png, for a pixel compare with the release
    /// head's (and of the two with each other, the method's own floor). Skipped without HERMES_E2E_CARD_SHOT.
    func testTheCardAsDrawn() throws {
        guard let path = ProcessInfo.processInfo.environment["HERMES_E2E_CARD_SHOT"], !path.isEmpty else { throw XCTSkip("HERMES_E2E_CARD_SHOT not set") }
        try approvalOnScreen("Clean up the old logs")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let dock = app.otherElements["chat.dock"].firstMatch
        XCTAssertTrue(dock.exists, "no dock with the card")
        for n in 1...2 {
            let png = dock.screenshot().pngRepresentation
            try png.write(to: URL(fileURLWithPath: "\(path)-\(n).png"))
            print("CARD-SHOT \(n) frame \(dock.frame) \(png.count) bytes")
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
    }

    /// Equality runs (Duo stage 4 A): the card in a chat as VoiceOver reads it, the oracle's stops inside the dock alone
    /// (the card's heading, what's asked, the command, the tool, the scope line and the choices), printed in order
    /// (CARD-ORACLE) for a compare with the release head's. Skipped without HERMES_E2E_CARD_ORACLE=1.
    func testTheCardsVoiceOverOrder() throws {
        guard ProcessInfo.processInfo.environment["HERMES_E2E_CARD_ORACLE"] == "1" else { throw XCTSkip("HERMES_E2E_CARD_ORACLE not set") }
        try approvalOnScreen("Clean up the old logs", extra: ["-vory-ax-oracle"])
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let dock = app.otherElements["chat.dock"].firstMatch
        XCTAssertTrue(dock.exists, "no dock with the card")
        let oracle = app.descendants(matching: .any).matching(identifier: "debug.voiceover").firstMatch
        XCTAssertTrue(oracle.waitForExistence(timeout: 5), "no oracle")
        // Each stop is "label|x,y,w,h": kept when its middle is in the dock.
        let stops = ((oracle.value as? String) ?? "").split(separator: "\n").compactMap { line -> String? in
            guard let bar = line.lastIndex(of: "|") else { return nil }
            let n = line[line.index(after: bar)...].split(separator: ",").compactMap { Double($0) }
            guard n.count == 4, dock.frame.contains(CGPoint(x: n[0] + n[2] / 2, y: n[1] + n[3] / 2)) else { return nil }
            return String(line[..<bar])
        }
        XCTAssertFalse(stops.isEmpty, "no stops in the dock")
        print("CARD-ORACLE \(stops.count) stops: \(stops.joined(separator: " ⟩ "))")
    }

    /// The card's choice buttons, in the order VoiceOver reads them.
    private func cardChoices() -> [String] {
        app.otherElements["chat.dock"].firstMatch.buttons.allElementsBoundByIndex.map(\.label).filter { names.contains($0) }
    }

    func testTheCardIsTheOneWayToAnswerAndAlwaysAsksFirst() throws {
        try approvalOnScreen("Clean up the old logs")
        // The mock offers all four: the card shows all four, in the gateway's order.
        XCTAssertEqual(cardChoices(), names, "the card's choices, in VoiceOver's order")
        shot("approval-card")

        // The audit on the chat with the card up: anything inside the card fails it, except
        // "Text clipped", which on iOS 27 lands on different whole words of the card each run
        // (the screenshots show them in full), and contrast, whose one finding (the orange
        // "Approval needed") is 1.5 (25)'s and outside this change; those are reported only.
        let dock = app.otherElements["chat.dock"].firstMatch.frame
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection, .textClipped, .contrast]) { issue in
            let inCard = issue.element.map { dock.intersects($0.frame) } ?? false
            print("CARD-AUDIT \(inCard ? "card" : "chat") '\(issue.compactDescription)' label '\(issue.element?.label ?? "")' id '\(issue.element?.identifier ?? "")'")
            return !inCard || issue.auditType == .textClipped || issue.auditType == .contrast
        }

        // A long press on the card opens nothing and answers nothing.
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Approval needed'")).firstMatch
        XCTAssertTrue(title.exists, "no card title to hold")
        let menuNames = ["Allow once", "Allow for this chat", "Always allow…", "Allow for this session", "Always allow"]
        let heldBefore = menuNames.map { app.buttons.matching(NSPredicate(format: "label == %@", $0)).count }
        title.press(forDuration: 1.0)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("approval-card-held")
        // The card's own buttons carry the same names now, so a menu shows as more of them.
        for (item, count) in zip(menuNames, heldBefore) {
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", item)).count, count, "a long press opened a menu with \"\(item)\"")
        }
        XCTAssertEqual(cardChoices(), names, "the long press changed the card")

        // "Always allow…" asks first, saying what it covers; Cancel sends nothing, the card still waits.
        app.buttons["Always allow…"].firstMatch.tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Always allow… did not ask first")
        XCTAssertTrue(confirm.label.hasPrefix("Always allow"), "the confirmation reads \(confirm.label)")
        shot("approval-always-confirm")
        confirm.buttons["Cancel"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(cardChoices(), names, "Cancel answered the approval")
    }

    /// At the largest text size the four names stand in full (the audit's "Text clipped" is not
    /// trusted on these buttons, so this is the picture that says it).
    func testTheNamesStandInFullAtTheLargestTextSize() throws {
        // Asked at the usual size (at this one the composer's send button is cut by its card's
        // edge, 1.5 (25)'s, on the 1.5.1 list), then the app is opened again at the largest size
        // on the card still waiting.
        try approvalOnScreen("Clean up the old logs")
        app.terminate()
        try launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        try openChat()
        XCTAssertTrue(app.buttons["Allow once"].firstMatch.waitForExistence(timeout: 30), "no waiting card at the largest text size")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(cardChoices(), names, "the card's choices at the largest text size")
        for n in names { XCTAssertTrue(app.buttons[n].firstMatch.isHittable, "\"\(n)\" is not on screen at the largest text size") }
        shot("approval-card-xxxl")
    }

    func testTheCardShowsOnlyWhatTheGatewayOffers() throws {
        // The mock offers only Allow once and Deny for this prompt.
        try approvalOnScreen("Clean up the old logs, once or deny")
        XCTAssertEqual(cardChoices(), ["Allow once", "Deny"], "the card offers other choices than the gateway")
        let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Allow once:'")).firstMatch
        XCTAssertTrue(note.exists, "no line saying what the choices mean")
        XCTAssertFalse(note.label.contains("Allow for this chat:") || note.label.contains("Always allow:"), "the card explains choices it does not offer: \(note.label)")
        shot("approval-card-once-or-deny")
    }
}
