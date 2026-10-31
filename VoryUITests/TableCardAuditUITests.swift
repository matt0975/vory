import XCTest

/// #572's audit gate: a reply holding tables (the mock answers a prompt starting "table" with two narrow tables), with the
/// wrap switch on and off (HERMES_E2E_TABLE_WRAP 1 or 0, set as the app's own `table.wrap` at launch), on the demo copy
/// and the mock. The chat screen's audit (contrast, element descriptions, hit regions, element detection): a finding
/// inside a table card's header (its "Table" title, the wrap switch, full screen) FAILS the test; every other finding is
/// noted. Checked too: each header's switch and full screen are 44 pt or more each way, and the switch offers the change
/// the mode allows (on: "Unwrap wide columns"; off: "Wrap columns to fit"). A hold for a still (BARUP HOLD tables).
/// Notes are XCTContext activities. Skipped unless HERMES_E2E_URL, HERMES_E2E_TOKEN and HERMES_E2E_TABLE_WRAP are set.
@MainActor
final class TableCardAuditUITests: XCTestCase {
    private var app: XCUIApplication!
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    nonisolated private static func note(_ line: String) { XCTContext.runActivity(named: line) { _ in } }
    private static let switchLabels = ["Unwrap wide columns", "Wrap columns to fit"]
    private static let openLabel = "Open the table full screen"

    func testTheTableCardsHeaderPassesTheAudit() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        guard let wrapSetting = e["HERMES_E2E_TABLE_WRAP"], wrapSetting == "1" || wrapSetting == "0" else {
            throw XCTSkip("no wrap mode to audit (HERMES_E2E_TABLE_WRAP 1 or 0)")
        }
        let wrap = wrapSetting == "1"
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats",
                               "-restore.openChat", "none", "-colorSchemePreference", e["HERMES_E2E_SCHEME"] ?? "light",
                               "-table.wrap", wrap ? "YES" : "NO"]
        app.launch()
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40), "no New Chat")
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "no composer")
        composer.tap()
        composer.typeText("table of what is using the disk")
        app.buttons["composer.send"].firstMatch.tap()
        let end = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Say the word")).firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 60), "the reply never finished")
        // The keyboard down, so the reply has the screen (the thread dismisses it on a drag into it).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        pause(2)
        // The first table's header on screen (the thread ends at the reply's last words, under the tables): back up the
        // thread a slow swipe at a time, six at most.
        let firstTitle = app.staticTexts.matching(NSPredicate(format: "label == 'Table'")).firstMatch
        let window = app.windows.firstMatch.frame
        for _ in 0..<6 {
            if firstTitle.exists, firstTitle.frame.minY >= window.minY + 60, firstTitle.frame.maxY <= window.maxY - 60 { break }
            app.swipeDown(velocity: .slow); pause(1)
        }
        Self.note("TABLES first title \(firstTitle.exists ? "\(firstTitle.frame)" : "-") in the window \(window)")

        // Each header: its switch, its full screen and its title, level with each other.
        let switches = app.buttons.matching(NSPredicate(format: "label IN %@", Self.switchLabels)).allElementsBoundByIndex.filter(\.exists)
        let opens = app.buttons.matching(NSPredicate(format: "label == %@", Self.openLabel)).allElementsBoundByIndex.filter(\.exists)
        let titles = app.staticTexts.matching(NSPredicate(format: "label == 'Table'")).allElementsBoundByIndex.filter(\.exists)
        Self.note("TABLES wrap \(wrap ? "on" : "off"): \(switches.count) switches, \(opens.count) full screens, \(titles.count) titles")
        XCTAssertGreaterThanOrEqual(switches.count, 1, "no table card's switch")
        var headers: [CGRect] = []
        for s in switches {
            let f = s.frame
            let level = { (g: CGRect) in abs(g.midY - f.midY) <= 12 }
            let o = opens.map(\.frame).first(where: level), t = titles.map(\.frame).first(where: level)
            let header = [o, t].compactMap { $0 }.reduce(f) { $0.union($1) }
            headers.append(header)
            Self.note("TABLES header \(header): switch '\(s.label)' \(f), full screen \(o.map { "\($0)" } ?? "-"), title \(t.map { "\($0)" } ?? "-")")
            XCTAssertEqual(s.label, wrap ? "Unwrap wide columns" : "Wrap columns to fit", "the switch doesn't offer the change its mode allows")
            XCTAssertGreaterThanOrEqual(min(f.width, f.height), 44, "the switch \(f) under 44 pt")
            if let o { XCTAssertGreaterThanOrEqual(min(o.width, o.height), 44, "full screen \(o) under 44 pt") } else { XCTFail("no full screen level with the switch at \(f)") }
            if t == nil { XCTFail("no 'Table' title level with the switch at \(f)") }
        }

        Self.note("BARUP HOLD tables"); pause(3)
        var issues = 0
        // A finding whose element stands inside a header fails (returned unhandled); anything else is noted and let go.
        try app.performAccessibilityAudit(for: [.contrast, .sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            issues += 1
            let el = issue.element, f = el?.frame ?? .null
            let inside = !f.isNull && headers.contains { $0.insetBy(dx: -1, dy: -1).intersects(f) }
            Self.note("AUDIT tables \(inside ? "FAIL" : "noted") \(issue.auditType) '\(el?.identifier ?? "")' '\(el?.label ?? "")' \(el.map { "\($0.frame)" } ?? "-") \(issue.compactDescription)")
            return !inside
        }
        Self.note("AUDIT tables done, \(issues) issues")
        app.terminate()
    }
}
