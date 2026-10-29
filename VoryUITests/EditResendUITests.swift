import XCTest

/// Edit & resend on the mock gateway (#556): the last message is edited under "Editing your message" and sent in its own
/// place, the old turn gone from the thread and taken back once on the gateway (`/api/_mock/undos`, a retry); then the
/// mock's faults: a busy gateway (undo-busy) keeps the words and the edit, and a gateway without the method (undo-unknown)
/// keeps the words, ends the edit and offers Copy to message from then on. With the busy banner up the dock still holds
/// Send and the box. The bubble menu, the reply strip, the edit strip and the banner pass the audit, with the composer
/// audit's two known findings logged (#482's reasoning row, the 0x0 text). First a message is queued behind a running reply
/// (the mock's `long`); the dock's frame and Send's go to the log as DOCK lines at each state (empty, queue, draft, reply
/// strip, edit strip, after resend, banner), to set one build's against another's. Run with predictive text off on the
/// simulator, as the composer audit is. The messages start "short link", the mock's short reply with no approval to wait
/// on, which keeps the person's message in view with the keyboard up (a tall reply pushed it off the top). Skipped unless
/// HERMES_E2E_URL / HERMES_E2E_TOKEN / HERMES_E2E_BUNDLE are set (the demo copy, pointed at the mock by launch argument).
final class EditResendUITests: XCTestCase {
    private var app: XCUIApplication!
    private var base = ""

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func text(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
    }

    /// With `tapCentreIfMissed`, a miss also taps the first match's frame centre and keeps the screen again: whether a finger
    /// reaches it where the runner's hit test didn't. Only for Send: a bubble above the screen has its centre off it.
    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval, tapCentreIfMissed: Bool = false) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            pause(0.2)
        } while Date() < deadline
        keep("not hittable", query)
        if tapCentreIfMissed, let first = query.allElementsBoundByIndex.first {
            first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            pause(3)
            keep("after a tap at its centre", query)
        }
        return nil
    }

    /// Each match as the runner saw it, the app's tree and the screen, kept in the result.
    private func keep(_ name: String, _ query: XCUIElementQuery) {
        let seen = query.allElementsBoundByIndex.map { "'\($0.identifier)' '\($0.label)' frame \($0.frame) enabled \($0.isEnabled) hittable \($0.isHittable)" }
        let tree = XCTAttachment(string: (seen.isEmpty ? "no match" : seen.joined(separator: "\n")) + "\n\n" + app.debugDescription)
        tree.name = name; tree.lifetime = .keepAlways; add(tree)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    /// A line in the run's log: the runner's own print isn't kept there, an activity's name is.
    private static func note(_ line: String) {
        XCTContext.runActivity(named: line) { _ in }
    }

    /// The dock's frame and Send's in the log, once the dock has settled, to set one build's against another's.
    private func dockReading(_ state: String) {
        pause(1)
        let dock = app.otherElements["chat.dock"].firstMatch, send = app.buttons["composer.send"].firstMatch
        Self.note("DOCK \(state) dock \(dock.exists ? "\(dock.frame)" : "none") send \(send.exists ? "\(send.frame)" : "none")")
    }

    /// Types into the box, then checks it holds all it should: a keyboard that went down partway fails here, by name,
    /// instead of sending part of the words (2026-10-29: the box took "lo" of "long 15", and the mock answered that).
    private func type(_ words: String, into box: XCUIElement, expecting whole: String) {
        box.typeText(words)
        let value = box.value as? String ?? ""
        XCTAssertEqual(value, whole, "the box took only '\(value)' of '\(whole)'")
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
            Self.note("EDIT-AUDIT \(when) '\(issue.compactDescription)' label '\(label)' id '\(issue.element?.identifier ?? "")' frame \(frame)")
            // The composer audit's two known findings, by their exact descriptions, each logged.
            if issue.auditType == .hitRegion, issue.compactDescription == "Hit area is too small", ["Show reasoning", "Hide reasoning"].contains(label) {
                Self.note("EDIT-AUDIT \(when) ignored: #482's hit region on '\(label)'"); return true
            }
            if issue.compactDescription == "Potentially inaccessible text", frame == .zero, label.isEmpty {
                Self.note("EDIT-AUDIT \(when) ignored: the known 0x0 'Potentially inaccessible text'"); return true
            }
            return false
        }
        Self.note("EDIT-AUDIT \(when) done")
    }

    /// Long-presses the bubble with exactly these words and returns the menu's buttons.
    private func openMenu(on words: String) throws {
        let query = app.staticTexts.matching(NSPredicate(format: "label == %@", words))
        // There but out of view (above the screen): the thread is drawn down to it once.
        if hittable(query, timeout: 5) == nil, query.firstMatch.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        }
        let bubble = try XCTUnwrap(hittable(query, timeout: 10), "no bubble '\(words)' in view")
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
        dockReading("empty")
        // A new chat dropped the keyboard about 5 s after it opened, two letters into the typing: the first tap comes after
        // that, so the keyboard it brings up stays.
        pause(6)
        composer.tap()

        // A message queued behind a running reply (the mock's `long`, about 15 s): the queue strip stands over the composer.
        type("long 15", into: composer, expecting: "long 15")
        try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10, tapCentreIfMissed: true)).tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10), "the long reply didn't start")
        composer.tap()
        type("short link while it runs", into: composer, expecting: "short link while it runs")
        try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10, tapCentreIfMissed: true)).tap()
        let queued = text("Queued (").firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 5), "nothing queued")
        // The reading is the strip over the box: not an approval card in the box's place.
        XCTAssertTrue(composer.exists, "no box under the queue")
        XCTAssertFalse(text("Approval needed").firstMatch.exists, "an approval stands in the box's place")
        dockReading("queue")
        // The long reply ends, the queued message goes, and its short reply ends.
        let gone = Date().addingTimeInterval(60)
        while Date() < gone, queued.exists { pause(0.5) }
        XCTAssertFalse(queued.exists, "the queued message didn't go")
        waitForIdle()

        composer.tap()
        type("short link for the export", into: composer, expecting: "short link for the export")
        dockReading("draft")
        try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10, tapCentreIfMissed: true)).tap()
        waitForIdle()

        // The reply strip's Cancel reply passes the audit too (the same 44 pt square as Cancel editing), then goes.
        try openMenu(on: "short link for the export")
        app.buttons["Reply"].tap()
        let cancelReply = app.buttons["composer.cancelReply"]
        XCTAssertTrue(cancelReply.waitForExistence(timeout: 5), "no reply strip")
        dockReading("reply strip")
        try audit("quote strip")
        cancelReply.tap()
        XCTAssertFalse(cancelReply.waitForExistence(timeout: 2), "the reply strip didn't go")

        // The last message offers Edit & resend, and Copy to message too.
        try openMenu(on: "short link for the export")
        XCTAssertTrue(app.buttons["Edit & resend"].exists, "the last message doesn't offer Edit & resend")
        try audit("bubble menu")
        app.buttons["Edit & resend"].tap()
        let editing = app.descendants(matching: .any)["composer.editing"]
        XCTAssertTrue(editing.waitForExistence(timeout: 5), "no 'Editing your message'")
        XCTAssertEqual(composer.value as? String, "short link for the export")
        XCTAssertTrue(app.buttons["Cancel editing"].exists)
        dockReading("edit strip")
        try audit("edit strip")

        // Sent in its place: the old turn leaves, the new words stand once, and the gateway took one turn back as a retry.
        composer.tap()
        type(" please", into: composer, expecting: "short link for the export please")
        let send = try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10, tapCentreIfMissed: true))
        XCTAssertEqual(send.label, "Send edited message")
        send.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "short link for the export please")).firstMatch.waitForExistence(timeout: 20))
        waitForIdle()
        XCTAssertFalse(editing.exists, "the edit didn't end")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "short link for the export")).count, 0, "the old message is still in the thread")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "short link for the export please")).count, 1)
        let taken = try undos().dropFirst(before)
        XCTAssertEqual(taken.count, 1, "not exactly one undo")
        XCTAssertEqual(taken.first?["intent"] as? String, "retry")
        XCTAssertGreaterThan(taken.first?["removed"] as? Int ?? 0, 0)
        dockReading("after resend")

        // A busy gateway: nothing sent, the words and the edit kept, the reason said.
        try openMenu(on: "short link for the export please")
        app.buttons["Edit & resend"].tap()
        XCTAssertTrue(editing.waitForExistence(timeout: 5))
        fault("undo-busy")
        composer.tap()
        type(" now", into: composer, expecting: "short link for the export please now")
        try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10, tapCentreIfMissed: true)).tap()
        XCTAssertTrue(text("A reply is running").firstMatch.waitForExistence(timeout: 10), "the busy gateway wasn't said")
        XCTAssertTrue(editing.exists, "the edit ended on a busy gateway")
        XCTAssertEqual(composer.value as? String, "short link for the export please now")
        // With the banner up the dock still holds the composer (its frame was the banner's alone, Send and the box outside
        // it, where the hit test missed them), and the banner passes the audit, its Close too.
        dockReading("banner")
        let dock = app.otherElements["chat.dock"].firstMatch.frame
        Self.note("DOCK banner box \(composer.frame)")
        XCTAssertTrue(dock.insetBy(dx: -1, dy: -1).contains(app.buttons["composer.send"].firstMatch.frame), "the dock doesn't hold Send with the banner up")
        XCTAssertTrue(dock.insetBy(dx: -1, dy: -1).contains(composer.frame), "the dock doesn't hold the box with the banner up")
        try audit("banner")

        // A gateway without the method: the words kept, the edit ended, Copy to message only from then on.
        fault("undo-unknown")
        try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10, tapCentreIfMissed: true)).tap()
        XCTAssertTrue(text("can't take back a sent message").firstMatch.waitForExistence(timeout: 10), "the missing method wasn't said")
        XCTAssertFalse(editing.exists, "the edit didn't end on a gateway without undo")
        XCTAssertEqual(composer.value as? String, "short link for the export please now")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "short link for the export please")).count, 1, "something was sent")
        try openMenu(on: "short link for the export please")
        XCTAssertFalse(app.buttons["Edit & resend"].exists, "Edit & resend still offered on a gateway without undo")
        XCTAssertEqual(try undos().dropFirst(before).count, 1, "an undo the faults should have refused was counted")
    }
}
