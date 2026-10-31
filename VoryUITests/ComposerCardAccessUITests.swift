import XCTest

/// The card composer (#320) at a large Dynamic Type size and in VoiceOver's order: the card
/// still fits with its control row reachable, and a swipe through it goes text, +, model chip,
/// mic or send. Pictures for review; the order asserted from the accessibility tree.
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
@MainActor
final class ComposerCardAccessUITests: XCTestCase {
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

    private func launch(url: String, token: String, size: String?) {
        var args = ["-colorSchemePreference", "light", "-launchTab", "chats"]
        if let size { args += ["-UIPreferredContentSizeCategoryName", size] }
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
    }

    private func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func openNewChat() {
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        XCTAssertTrue(app.textViews["composer.text"].firstMatch.waitForExistence(timeout: 30))
        settle(1.5)
    }

    /// The composer's pieces in accessibility order, by identifier or label.
    private func cardOrder() -> [String] {
        guard let snap = try? app.snapshot() else { return [] }
        var out: [String] = []
        func walk(_ s: XCUIElementSnapshot) {
            let id = s.identifier
            if ["composer.text", "composer.attach", "composer.modelChip", "composer.send"].contains(id) { out.append(id) }
            else if s.elementType == .button, ["Dictate", "Stop", "Send"].contains(where: { s.label.hasPrefix($0) }) { out.append(s.label) }
            for c in s.children { walk(c) }
        }
        walk(snap)
        return out
    }

    /// The largest text size, in a chat with the context ring (#396): Send stands inside the card
    /// and the window, and a tap on it sends. The +, the ring's number and the chip ran past the
    /// card there, Send was cut by its edge, and a tap on what showed of it sent nothing.
    func testSendStandsInTheCardAndSendsAtTheLargestSize() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        launch(url: url, token: token, size: "UICTContentSizeCategoryAccessibilityXXXL")
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup' AND identifier != 'chat.titlePill'"))
        let row = rows.allElementsBoundByIndex.first { $0.isHittable } ?? rows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "no Disk cleanup row")
        row.tap()
        let composer = app.textViews["composer.text"].firstMatch
        // An approval left waiting by an earlier test hides the composer: denied first.
        if !composer.waitForExistence(timeout: 8) {
            let deny = app.buttons.matching(NSPredicate(format: "label == 'Deny'")).firstMatch
            if deny.waitForExistence(timeout: 10) { deny.tap() }
        }
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "no composer")
        // The chat has its usage, so the context ring stands in the row (the tester's case).
        let ring = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Context'")).firstMatch
        XCTAssertTrue(ring.waitForExistence(timeout: 30), "no context ring in the row")
        composer.tap()
        composer.typeText("table 2 please")
        settle(1.5)
        shot("card-access-3-xxxl-typed")
        let send = app.buttons["composer.send"].firstMatch
        let dock = app.otherElements["chat.dock"].firstMatch
        XCTAssertTrue(send.exists, "no Send")
        print("SEND-FRAME send \(send.frame) dock \(dock.frame) window \(app.windows.firstMatch.frame)")
        XCTAssertTrue(dock.frame.insetBy(dx: -1, dy: -1).contains(send.frame), "Send runs past the card: \(send.frame) in \(dock.frame)")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(send.frame), "Send runs off the window")
        // Still a circle, at most a control's size: its arrow drawn at the text's size outgrew the
        // 28 pt circle, which was left as two blue arcs around a white arrow.
        XCTAssertLessThanOrEqual(send.frame.height, 44, "Send grew to \(send.frame.size)")
        XCTAssertLessThan(abs(send.frame.width - send.frame.height), 2, "Send is not round: \(send.frame.size)")
        XCTAssertTrue(send.isHittable, "Send cannot be tapped")
        // The audit at this size: anything in the composer's card fails it.
        let card = dock.frame
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            let inCard = issue.element.map { card.intersects($0.frame) } ?? false
            print("COMPOSER-AUDIT \(inCard ? "card" : "chat") '\(issue.compactDescription)' label '\(issue.element?.label ?? "")' id '\(issue.element?.identifier ?? "")'")
            return !inCard
        }
        send.tap()
        let sent = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'table 2 please'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 15), "the tap on Send sent nothing")
        settle(1)
        shot("card-access-4-xxxl-sent")
    }

    func testTheCardReadsInOrderAndFitsAtLargeType() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        launch(url: url, token: token, size: nil)
        openNewChat()
        let order = cardOrder()
        print("CARD-ORDER \(order)")
        let text = order.firstIndex(of: "composer.text") ?? -1
        let attach = order.firstIndex(of: "composer.attach") ?? -1
        let chip = order.firstIndex(of: "composer.modelChip") ?? -1
        XCTAssertTrue(text >= 0 && attach > text && chip > attach, "VoiceOver order is not text, +, chip: \(order)")
        app.terminate()

        // Accessibility large: the card and its row still on screen, the composer reachable.
        launch(url: url, token: token, size: "UICTContentSizeCategoryAccessibilityL")
        openNewChat()
        shot("card-access-1-large-empty")
        let composer = app.textViews["composer.text"].firstMatch
        let chipButton = app.buttons["composer.modelChip"].firstMatch
        XCTAssertTrue(composer.isHittable, "the composer is not reachable at the large size")
        XCTAssertTrue(chipButton.exists && app.windows.firstMatch.frame.contains(chipButton.frame), "the chip is off the window at the large size")
        composer.tap()
        composer.typeText("Large type, a few words that wrap in the card.")
        settle(2.5)
        shot("card-access-2-large-typed")
        XCTAssertTrue(app.buttons["composer.attach"].firstMatch.isHittable, "+ is not reachable at the large size with the keyboard up")
    }
}
