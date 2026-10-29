import XCTest

/// Edit & resend on the mock gateway (#556): the last message is edited under "Editing your message" and sent in its own
/// place, the old turn gone from the thread and taken back once on the gateway (`/api/_mock/undos`, a retry); then the
/// mock's faults: a busy gateway (undo-busy) keeps the words and the edit, and a gateway without the method (undo-unknown)
/// keeps the words, ends the edit and offers Copy to message from then on. The bubble menu and the edit strip pass the
/// audit, with the composer audit's two known findings logged (#482's reasoning row, the 0x0 text). Run with predictive text
/// off on the simulator, as the composer audit is. The messages start "table", the mock's quick turn with no approval
/// to wait on. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN / HERMES_E2E_BUNDLE are
/// set (the demo copy, pointed at the mock by launch argument).
final class EditResendUITests: XCTestCase {
    private var app: XCUIApplication!
    private var base = ""

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func text(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
    }

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            pause(0.2)
        } while Date() < deadline
        return nil
    }

    /// The reply has ended: no Stop in the composer.
    private func waitForIdle(_ timeout: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, app.buttons["Stop"].exists { pause(0.5) }
        XCTAssertFalse(app.buttons["Stop"].exists, "the reply didn't end")
        pause(1)
    }

    /// The mock's fault switch (`/mock/fault?mode=…`).
    private func fault(_ mode: String) {
        guard let u = URL(string: base + "/mock/fault?mode=" + mode) else { return }
        let done = expectation(description: "fault \(mode)")
        URLSession.shared.dataTask(with: u) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    /// Every session.undo the mock answered.
    private func undos() throws -> [[String: Any]] {
        let url = try XCTUnwrap(URL(string: base + "/api/_mock/undos"))
        var request = URLRequest(url: url); request.timeoutInterval = 5
        let done = expectation(description: "undos")
        var list: [[String: Any]]?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { list = obj["undos"] as? [[String: Any]] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 8)
        return try XCTUnwrap(list, "the mock gateway did not list its undos")
    }

    private func audit(_ when: String) throws {
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            let label = issue.element?.label ?? "", frame = issue.element?.frame ?? .zero
            print("EDIT-AUDIT \(when) '\(issue.compactDescription)' label '\(label)' id '\(issue.element?.identifier ?? "")' frame \(frame)")
            // The composer audit's two known findings, by their exact descriptions, each logged.
            if issue.auditType == .hitRegion, issue.compactDescription == "Hit area is too small", ["Show reasoning", "Hide reasoning"].contains(label) {
                print("EDIT-AUDIT \(when) ignored: #482's hit region on '\(label)'"); return true
            }
            if issue.compactDescription == "Potentially inaccessible text", frame == .zero, label.isEmpty {
                print("EDIT-AUDIT \(when) ignored: the known 0x0 'Potentially inaccessible text'"); return true
            }
            return false
        }
    }

    /// Long-presses the bubble with exactly these words and returns the menu's buttons.
    private func openMenu(on words: String) throws {
        let bubble = try XCTUnwrap(hittable(app.staticTexts.matching(NSPredicate(format: "label == %@", words)), timeout: 15), "no bubble '\(words)'")
        bubble.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Copy to message"].waitForExistence(timeout: 5), "the bubble's menu didn't open")
    }

    override func tearDown() {
        if !base.isEmpty { fault("none") }
        super.tearDown()
    }

    func testTheLastMessageIsEditedInItsPlaceAndAFaultKeepsTheWords() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty,
              let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { throw XCTSkip("needs the mock (HERMES_E2E_URL / TOKEN / BUNDLE)") }
        base = url
        continueAfterFailure = false
        fault("none")
        let before = try undos().count
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES"]
        app.launch()

        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("table of the cache folders")
        try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10)).tap()
        waitForIdle()

        // The last message offers Edit & resend, and Copy to message too.
        try openMenu(on: "table of the cache folders")
        XCTAssertTrue(app.buttons["Edit & resend"].exists, "the last message doesn't offer Edit & resend")
        try audit("bubble menu")
        app.buttons["Edit & resend"].tap()
        let editing = app.descendants(matching: .any)["composer.editing"]
        XCTAssertTrue(editing.waitForExistence(timeout: 5), "no 'Editing your message'")
        XCTAssertEqual(composer.value as? String, "table of the cache folders")
        XCTAssertTrue(app.buttons["Cancel editing"].exists)
        try audit("edit strip")

        // Sent in its place: the old turn leaves, the new words stand once, and the gateway took one turn back as a retry.
        composer.tap()
        composer.typeText(" by size")
        let send = try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10))
        XCTAssertEqual(send.label, "Send edited message")
        send.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "table of the cache folders by size")).firstMatch.waitForExistence(timeout: 20))
        waitForIdle()
        XCTAssertFalse(editing.exists, "the edit didn't end")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "table of the cache folders")).count, 0, "the old message is still in the thread")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "table of the cache folders by size")).count, 1)
        let taken = try undos().dropFirst(before)
        XCTAssertEqual(taken.count, 1, "not exactly one undo")
        XCTAssertEqual(taken.first?["intent"] as? String, "retry")
        XCTAssertGreaterThan(taken.first?["removed"] as? Int ?? 0, 0)

        // A busy gateway: nothing sent, the words and the edit kept, the reason said.
        try openMenu(on: "table of the cache folders by size")
        app.buttons["Edit & resend"].tap()
        XCTAssertTrue(editing.waitForExistence(timeout: 5))
        fault("undo-busy")
        composer.tap()
        composer.typeText(" now")
        try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10)).tap()
        XCTAssertTrue(text("A reply is running").firstMatch.waitForExistence(timeout: 10), "the busy gateway wasn't said")
        XCTAssertTrue(editing.exists, "the edit ended on a busy gateway")
        XCTAssertEqual(composer.value as? String, "table of the cache folders by size now")

        // A gateway without the method: the words kept, the edit ended, Copy to message only from then on.
        fault("undo-unknown")
        try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10)).tap()
        XCTAssertTrue(text("can't take back a sent message").firstMatch.waitForExistence(timeout: 10), "the missing method wasn't said")
        XCTAssertFalse(editing.exists, "the edit didn't end on a gateway without undo")
        XCTAssertEqual(composer.value as? String, "table of the cache folders by size now")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "table of the cache folders by size")).count, 1, "something was sent")
        try openMenu(on: "table of the cache folders by size")
        XCTAssertFalse(app.buttons["Edit & resend"].exists, "Edit & resend still offered on a gateway without undo")
        XCTAssertEqual(try undos().dropFirst(before).count, 1, "an undo the faults should have refused was counted")
    }
}
