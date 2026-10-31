import XCTest

/// Settings › Appearance's tab bar header: its Edit button has a 44 pt hit area (the audit flagged 22 by 14 pt) and the
/// header looks as it did. A still of the header and the frames printed (EDIT-HIT), for a before-and-after comparison,
/// and the screen's audit, with nothing excused. The mock (HERMES_E2E_URL / TOKEN / BUNDLE), for a gateway in use.
@MainActor
final class SettingsEditButtonUITests: XCTestCase {
    private var app: XCUIApplication!
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    func testTheTabBarHeadersEditButtonHasItsHitAreaAndTheScreenPassesTheAudit() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty,
              let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { throw XCTSkip("needs the mock (HERMES_E2E_URL / TOKEN / BUNDLE)") }
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "settings", "-colorSchemePreference", "light"]
        app.launch()
        XCTAssertTrue(any("settings.row.profile").waitForExistence(timeout: 30), "no Settings rows")
        var row = any("settings.row.appearance")
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow); pause(0.6); row = any("settings.row.appearance") }
        row.tap(); pause(1.5)
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] 'Tab bar'")).firstMatch
        // Into the screen's middle, clear of the tab bar floating over the bottom of the list.
        let middle = app.windows.firstMatch.frame.height * 0.55
        for _ in 0..<10 where !(header.exists && header.isHittable && header.frame.midY < middle) { app.swipeUp(velocity: .slow); pause(0.5) }
        XCTAssertTrue(header.exists, "no tab bar header")
        let edit = app.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.exists, "no Edit button")
        // VoiceOver reads "Edit" once: the label of the button's own size under it is hidden.
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Edit'")).count, 1, "more than one element reads Edit")
        let notOnTheBar = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Not on the bar'")).firstMatch
        XCTAssertFalse(notOnTheBar.exists, "the list is editing before Edit")
        pause(1)
        print("EDIT-HIT header \(header.frame) edit \(edit.frame)")
        XCTAssertGreaterThanOrEqual(edit.frame.width, 44, "the Edit button's hit area is narrower than 44 pt")
        XCTAssertGreaterThanOrEqual(edit.frame.height, 44, "the Edit button's hit area is shorter than 44 pt")
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = "edit-header"; a.lifetime = .keepAlways; add(a)
        if let folder = e["HERMES_E2E_SHOTS"], !folder.isEmpty {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("edit-header.png"))
        }
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            print("EDIT-AUDIT '\(issue.compactDescription)' label '\(issue.element?.label ?? "")' frame \(issue.element?.frame ?? .zero)")
            return false
        }

        // The 44 pt button reaches about 12 pt past the header, over the first row's trailing edge: a tap there, 4 pt
        // under the row's top, is the row's (its tab does nothing on a tap), not Edit's.
        let rows = { () -> [XCUIElement] in
            self.app.cells.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.minY >= header.frame.maxY - 1 && $0.frame.minY < header.frame.maxY + 400 }
                .sorted { $0.frame.minY < $1.frame.minY }
        }
        // A row by its tab's name; in editing its text reads "Remove, <name>" (the delete control's words come first).
        let names = { rows().map { r -> String in let t = r.staticTexts.firstMatch.label; return t.hasPrefix("Remove, ") ? String(t.dropFirst(8)) : t } }
        let order = names()
        print("EDIT-HIT rows \(order) first \(rows().first?.frame ?? .zero)")
        guard let first = rows().first, order.count >= 2 else { XCTFail("no rows under the header"); return }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: first.frame.maxX - 12, dy: first.frame.minY + 4)).tap()
        pause(1)
        XCTAssertFalse(notOnTheBar.exists, "a tap on the first row's top edge reached Edit")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Edit'")).count, 1, "a tap on the first row's top edge reached Edit")

        // Edit puts the list in editing (the hidden tabs' section comes) and reads Done, once; Done takes it out again.
        edit.tap(); pause(1)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Not on the bar'")).firstMatch.waitForExistence(timeout: 3), "Edit did not put the list in editing")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Done'")).count, 1, "not one element reads Done")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Edit'")).count, 0, "Edit still reads while editing")
        let done = app.buttons["Done"].firstMatch
        print("EDIT-HIT done \(done.frame)")
        XCTAssertGreaterThanOrEqual(done.frame.height, 44, "Done's hit area is shorter than 44 pt")
        // In editing the first row's reorder handle, at its trailing edge under the button's reach, still drags the row
        // to second place, and back.
        let handles = { () -> [XCUIElement] in
            self.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'")).allElementsBoundByIndex
                .filter { $0.frame.minY >= header.frame.maxY - 1 }.sorted { $0.frame.minY < $1.frame.minY }
        }
        if handles().count >= 2 {
            let h = handles()
            print("EDIT-HIT handles \(h.prefix(2).map { $0.frame })")
            h[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.8, thenDragTo: h[1].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
            pause(1)
            XCTAssertEqual(Array(names().prefix(2)), [order[1], order[0]], "the first row's handle did not drag it to second place")
            let back = handles()
            back[1].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.8, thenDragTo: back[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            pause(1)
            XCTAssertEqual(Array(names().prefix(2)), Array(order.prefix(2)), "the row did not drag back to first place")
        } else { XCTFail("no reorder handles in editing") }
        done.tap(); pause(1)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Not on the bar'")).firstMatch.exists, "Done did not take the list out of editing")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Edit'")).count, 1, "not one element reads Edit after Done")
    }
}
