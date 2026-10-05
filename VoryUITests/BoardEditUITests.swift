import XCTest

/// The Board's task sheet edits the title and the description on the iPhone, as the Mac's
/// inspector does: Edit › Rename… changes the title the sheet shows (and the card on the
/// board), Edit › Edit the Description opens the editor and the words land in the task.
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock gateway, whose board
/// has "Clear rotated logs older than 90 days" in Ready).
final class BoardEditUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = query.allElementsBoundByIndex.first(where: { $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    /// The alert's field, emptied (a delete per character it holds; the cursor lands at the
    /// end on a tap) and given new words.
    private func replace(in field: XCUIElement, with text: String) {
        field.tap()
        let held = (field.value as? String) ?? ""
        if !held.isEmpty { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: held.count + 2)) }
        field.typeText(text)
    }

    private func rename(to title: String) {
        let edit = app.buttons["task.edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "no Edit menu on the task sheet")
        edit.tap()
        let rename = app.buttons["Rename…"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "no Rename in the Edit menu")
        rename.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the Rename alert has no field")
        replace(in: field, with: title)
        app.alerts.buttons["Save"].firstMatch.tap()
        if !app.navigationBars[title].waitForExistence(timeout: 15) {
            shot("board-rename-missing")
            let bars = app.navigationBars.allElementsBoundByIndex.map { $0.identifier }
            let alerts = app.alerts.allElementsBoundByIndex.map { $0.label }
            XCTFail("the sheet's title did not follow the rename (bars: \(bars); alerts: \(alerts))")
        }
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-chat-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
        print("CHAT-SHOT \(d.appendingPathComponent("\(name).png").path)")
    }

    func testTheTaskSheetRenamesAndEditsTheDescription() throws {
        guard env != nil else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        app = XCUIApplication()
        // The Board on the bar (the default bar has no Board), and the app opened on it: the
        // page is hidden until the plugin's probe answers, so the launch tab waits for it.
        app.launchArguments = ["-launchTab", "kanban", "-tabLayout", "chats,kanban,bots,settings"]
        app.launch()

        // The card is found by the start of its name: a run that failed after its rename leaves
        // the mock's task under the renamed title until the mock restarts.
        let original = "Clear rotated logs older than 90 days"
        let rows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Clear rotated logs'"))
        let chips = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ready,'"))
        if hittable(chips, timeout: 12) == nil {
            // Not in front after all: its tab, then.
            guard let tab = hittable(app.buttons.matching(identifier: "tab.kanban"), timeout: 10) else { return XCTFail("no Board page and no Board tab") }
            tab.tap()
        }
        if hittable(rows, timeout: 5) == nil {
            // Another column in front: Ready has the card.
            guard let ready = hittable(chips, timeout: 10) else { return XCTFail("no Ready column chip") }
            ready.tap()
        }
        guard let row = hittable(rows, timeout: 15) else { return XCTFail("no 'Clear rotated logs…' card on the board") }
        let before = row.label
        row.tap()
        XCTAssertTrue(app.navigationBars[before].waitForExistence(timeout: 10), "the task sheet did not open")

        // Rename, then put the name back (the mock keeps its state for the next test).
        let renamed = "Clear rotated logs (renamed \(Int(Date().timeIntervalSince1970) % 10000))"
        rename(to: renamed)
        rename(to: original)

        // The description: the editor opens with the words as they are, more are added, Save
        // puts them in the task and the sheet shows them.
        app.buttons["task.edit"].firstMatch.tap()
        let editBody = app.buttons["Edit the Description"].firstMatch
        XCTAssertTrue(editBody.waitForExistence(timeout: 5), "no Edit the Description in the menu")
        editBody.tap()
        let editor = app.textViews["Description"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the description editor did not open")
        let marker = " Checked by the UI test."
        editor.tap()
        editor.typeText(marker)
        app.buttons["Save"].firstMatch.tap()
        let shown = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Checked by the UI test.'")).firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 15), "the new words are not in the task's description")
        XCTAssertFalse(editor.exists, "the editor stayed open after Save")
        app.buttons["Done"].firstMatch.tap()
    }
}
