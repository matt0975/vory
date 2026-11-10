import XCTest

/// #572's audit gate: a reply holding tables (the mock answers a prompt starting "table" with two narrow tables), with the
/// wrap switch on and off (HERMES_E2E_TABLE_WRAP 1 or 0, set as the app's own `table.wrap` at launch), on the demo copy
/// and the mock. The chat screen's audit (contrast, element descriptions, hit regions, element detection): a finding
/// whose element lies wholly inside a table card's header (its "Table" title, the wrap switch, full screen, or anything
/// else that ever stands there) FAILS the test; every other finding is noted, a page behind the chat whose rows only
/// cross a header's band among them. One finding is accepted, not failed: the "Table" title's "Contrast nearly passed"
/// (caption2 .secondary, the code block header's style), until the app-wide caption contrast pass (#575); the same title
/// with "Contrast failed" fails. Checked too: each header's switch and full screen are 44 pt or more each way, and the
/// switch offers the change the mode allows (on: "Unwrap wide columns"; off: "Wrap columns to fit"). A hold for a still
/// (BARUP HOLD tables).
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
        // A point on the thread's window, as a coordinate hung on the composer: XCTest sends an element's taps and drags to
        // the display its window is on, but the app's own coordinates to the main display, which on the open Duo is the
        // closed cover (there they never reached the app, and the keyboard stayed up).
        let at = { (x: CGFloat, y: CGFloat) in
            composer.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - composer.frame.minX, dy: y - composer.frame.minY))
        }
        // The keyboard down, so the reply has the screen: a tap on the thread at the leading margin (clear of the cards and
        // their own sideways scroll views), 40% down the window, under the header and above the dock (both float over the
        // thread, and a tap on them leaves the keyboard up). If it's still up, a drag from there down into it. Still up
        // after both: no header can be audited, so the run fails here.
        // Noted for a run where it stays up: the spot, the composer, Back's bottom, and the keyboards before and after each
        // step (none to close at all, against a tap that missed).
        let win = app.windows.firstMatch.frame
        let spot = { at(composer.frame.minX + 10, win.minY + win.height * 0.4) }
        let backBottom = app.buttons["chat.back"].firstMatch.exists ? "\(app.buttons["chat.back"].firstMatch.frame.maxY)" : "-"
        Self.note("TABLES keyboard before: \(app.keyboards.count) keyboard(s); spot \(spot().screenPoint), composer \(composer.frame), Back's bottom \(backBottom), window \(win)")
        if app.keyboards.firstMatch.exists { spot().tap(); pause(1); Self.note("TABLES keyboard after the tap: \(app.keyboards.count)") }
        if app.keyboards.firstMatch.exists {
            spot().press(forDuration: 0.05, thenDragTo: at(composer.frame.minX + 10, win.maxY - 4)); pause(1)
            Self.note("TABLES keyboard after the drag: \(app.keyboards.count)")
        }
        let keyboardUp = app.keyboards.firstMatch.exists
        Self.note("TABLES keyboard \(keyboardUp ? "still up" : "down")")
        guard !keyboardUp else { XCTFail("VOID: the keyboard stayed up, so no table header can be audited"); app.terminate(); return }
        // The first table's header wholly on screen, under the top bar (Back's bottom) and above the composer: the thread
        // dragged at the leading margin a step at a time (back when the header is above, on when it's under the composer),
        // eight at most; else the run fails before any audit, since an audit with no header in sight passes on nothing.
        let firstTitle = app.staticTexts.matching(NSPredicate(format: "label == 'Table'")).firstMatch
        let window = app.windows.firstMatch.frame
        let back = app.buttons["chat.back"].firstMatch
        let barBottom = back.exists ? back.frame.maxY : window.minY + 100
        // The header stands about 16 pt above its title's top, in a 44 pt row.
        let headerTop = { firstTitle.frame.minY - 16 }, headerBottom = { firstTitle.frame.minY + 28 }
        let onScreen = { firstTitle.exists && headerTop() >= barBottom + 8 && headerBottom() <= composer.frame.minY - 8 }
        for _ in 0..<8 where !onScreen() {
            let step = window.height * 0.3, from = at(composer.frame.minX + 10, window.minY + window.height * 0.5)
            let down = !firstTitle.exists || headerTop() < barBottom + 8
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: down ? step : -step))); pause(1)
        }
        Self.note("TABLES first title \(firstTitle.exists ? "\(firstTitle.frame)" : "-") in the window \(window), bar bottom \(barBottom), composer top \(composer.frame.minY)")
        guard onScreen() else { XCTFail("header not on screen: the first table's header isn't wholly under the top bar and above the composer"); app.terminate(); return }

        // Each header: its switch, its full screen and its title, level with each other.
        let switches = app.buttons.matching(NSPredicate(format: "label IN %@", Self.switchLabels)).allElementsBoundByIndex.filter(\.exists)
        let opens = app.buttons.matching(NSPredicate(format: "label == %@", Self.openLabel)).allElementsBoundByIndex.filter(\.exists)
        let titles = app.staticTexts.matching(NSPredicate(format: "label == 'Table'")).allElementsBoundByIndex.filter(\.exists)
        Self.note("TABLES wrap \(wrap ? "on" : "off"): \(switches.count) switches, \(opens.count) full screens, \(titles.count) titles")
        XCTAssertGreaterThanOrEqual(switches.count, 1, "no table card's switch")
        var headers: [CGRect] = []
        let side = { (r: CGRect) in (min(r.width, r.height) * 1000).rounded() / 1000 }
        for s in switches {
            let f = s.frame
            let level = { (g: CGRect) in abs(g.midY - f.midY) <= 12 }
            let o = opens.map(\.frame).first(where: level), t = titles.map(\.frame).first(where: level)
            let header = [o, t].compactMap { $0 }.reduce(f) { $0.union($1) }
            headers.append(header)
            Self.note("TABLES header \(header): switch '\(s.label)' \(f), full screen \(o.map { "\($0)" } ?? "-"), title \(t.map { "\($0)" } ?? "-")")
            XCTAssertEqual(s.label, wrap ? "Unwrap wide columns" : "Wrap columns to fit", "the switch doesn't offer the change its mode allows")
            XCTAssertGreaterThanOrEqual(side(f), 44, "the switch \(f) under 44 pt")
            if let o { XCTAssertGreaterThanOrEqual(side(o), 44, "full screen \(o) under 44 pt") } else { XCTFail("no full screen level with the switch at \(f)") }
            if t == nil { XCTFail("no 'Table' title level with the switch at \(f)") }
        }

        Self.note("BARUP HOLD tables"); pause(3)
        var issues = 0
        // A finding whose element lies within a header fails (returned unhandled); anything else is noted and let go.
        // Contained, not crossing: Settings' rows behind the chat (370 pt wide) cross a header's band without being in it.
        // The title's "nearly passed" contrast is the one accepted finding, until the caption contrast pass (#575).
        try app.performAccessibilityAudit(for: [.contrast, .sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            issues += 1
            let el = issue.element, f = el?.frame ?? .null
            let inside = !f.isNull && headers.contains { $0.insetBy(dx: -1, dy: -1).contains(f) }
            let accepted = inside && issue.auditType == .contrast && el?.label == "Table" && issue.compactDescription == "Contrast nearly passed"
            Self.note("AUDIT tables \(accepted ? "accepted (#575)" : inside ? "FAIL" : "noted") \(issue.auditType) '\(el?.identifier ?? "")' '\(el?.label ?? "")' \(el.map { "\($0.frame)" } ?? "-") \(issue.compactDescription)")
            return !inside || accepted
        }
        Self.note("AUDIT tables done, \(issues) issues")
        // An audit that finds nothing saw nothing: this reply gives some twenty findings on a phone, the title's #575 among
        // them. On the open Duo the audit comes back empty (it seems to read the closed cover, as XCUIScreen.main does), so
        // an empty audit fails closed here. A screen that's truly clean will need another witness when that day comes.
        guard issues > 0 else { XCTFail("VOID: the audit saw nothing (0 issues), so it can't pass the headers"); app.terminate(); return }
        app.terminate()
    }
}
