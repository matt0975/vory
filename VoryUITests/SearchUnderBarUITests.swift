import XCTest

/// #648: where the floating top bar is up (a standard iPhone, the open Duo upright), a root page's search stays clear of
/// the bar's row while it's open. On Chats, Bots and Settings, twice each: tap the field and type, then clear it, then
/// end the search. While it's open, the field, its clear button and the button that ends the search meet no capsule of
/// the row, the field stays where it was at rest, and both buttons can be hit; cleared, the search stays open where it
/// was; ended, the field is back at rest. On a standard iPhone the open search hid the system's navigation bar and
/// moved up under the row, its clear button and Cancel under + / Sort / Filters, and it couldn't be ended until a
/// relaunch (two TestFlight reports on build 50).
/// Nothing that stands under a capsule is tapped: the tap would go to the bar. A page whose search can't be ended stops
/// there, and the next page starts from a fresh launch.
/// With each search open (the first round): the accessibility audit, every issue printed (SEARCHBAR-AUDIT) and one on the
/// field, its clear button or the end of the search a failure (the system field's own clear button's hit region aside);
/// and a screenshot kept ("<tab> searching").
/// Every frame is printed (SEARCHBAR). Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock gateway), and
/// where the bar isn't up (a wide window).
@MainActor
final class SearchUnderBarUITests: XCTestCase {
    private var app: XCUIApplication!
    /// The search field's top within this of the row's bottom at rest (as Duo516UITests and TopBarRoomUITests hold it).
    static let fieldGapAllowed: CGFloat = 16

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func launch() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "dashboard",
                               "-colorSchemePreference", e["HERMES_E2E_APPEARANCE"] ?? "light", "-vory-morph-frames"]
        app.launch()
        XCTAssertTrue(element("tab.dashboard").waitForExistence(timeout: 40), "no Home tab")
        pause(2)
    }

    private func open(_ tab: String) {
        let t = element("tab.\(tab)")
        XCTAssertTrue(t.waitForExistence(timeout: 10), "no tab \(tab)")
        t.tap()
        pause(1.5)
    }

    // MARK: The bar's capsules

    /// The bar's capsules as drawn: "lead x y w h;mid …;trail …" (`debug.morphframes`).
    static func capsules(in summary: String) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for part in summary.split(separator: ";") {
            let f = part.split(separator: " ")
            guard f.count == 5, let x = Double(f[1]), let y = Double(f[2]), let w = Double(f[3]), let h = Double(f[4]) else { continue }
            out[String(f[0])] = CGRect(x: x, y: y, width: w, height: h)
        }
        return out
    }

    /// The capsules shown now, without the readout's "stripPitch" entry (a length the closed Duo's column uses, written as
    /// a 1 pt rect at the origin, not a capsule).
    private func caps() -> [String: CGRect] {
        let r = element("debug.morphframes")
        return r.exists ? Self.capsules(in: (r.value as? String) ?? "").filter { $0.key != "stripPitch" } : [:]
    }

    private func describe(_ c: [String: CGRect]) -> String { c.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") }

    /// Whether a point stands under one of the bar's capsules (a tap there goes to the bar).
    private func underTheBar(_ p: CGPoint, _ c: [String: CGRect]) -> Bool { c.values.contains { $0.contains(p) } }

    /// An element that can take a tap of its own: there, hittable, its centre under no capsule.
    private func free(_ e: XCUIElement, _ c: [String: CGRect]) -> Bool {
        e.exists && e.isHittable && !underTheBar(CGPoint(x: e.frame.midX, y: e.frame.midY), c)
    }

    /// The element meets no capsule of the bar's row.
    private func clearOfTheBar(_ state: String, _ what: String, _ e: XCUIElement, _ c: [String: CGRect]) {
        guard e.exists else { return }
        for (slot, cap) in c { XCTAssertFalse(e.frame.intersects(cap), "\(state): the \(what) \(e.frame) meets the bar's \(slot) capsule \(cap)") }
    }

    // MARK: The search

    private var field: XCUIElement { app.searchFields.firstMatch }

    /// The field's own clear button, inside it at its trailing end.
    private var clearButton: XCUIElement {
        let b = field.buttons["Clear text"]
        return b.exists ? b : field.buttons.firstMatch
    }

    /// The button that ends the search: beside the field on its row, to its right ("Cancel" on older systems, a closing
    /// glyph, "Close", on newer ones), never one of the bar's own (+ / Sort / Filters stand on that row once a search
    /// has moved up under it). Never one under the bar either, unless `underTheBarToo`: that's for telling whether the
    /// search is still open (its Close can stand under the bar's trailing capsule), never for a tap. None while the search
    /// is at rest.
    private func endSearch(_ c: [String: CGRect], underTheBarToo: Bool = false) -> XCUIElement? {
        guard field.exists else { return nil }
        let f = field.frame
        let own = element("morph.bar").buttons.allElementsBoundByIndex.map(\.frame)
        return app.buttons.allElementsBoundByIndex.first { b in
            b.exists && abs(b.frame.midY - f.midY) < 12 && b.frame.minX >= f.maxX - 4 && b.frame.minX < f.maxX + 60
                && !own.contains(b.frame)
                && (underTheBarToo || !underTheBar(CGPoint(x: b.frame.midX, y: b.frame.midY), c))
        }
    }

    /// The field at rest: under the row, within `fieldGapAllowed` of it, clear of every capsule, hittable.
    private func atRest(_ state: String) -> CGRect? {
        let c = caps()
        guard !c.isEmpty else { XCTFail("\(state): no top bar frames"); return nil }
        guard field.waitForExistence(timeout: 15) else { XCTFail("\(state): no search field"); return nil }
        let rowBottom = c.values.map(\.maxY).max() ?? 0
        let f = field.frame
        print("SEARCHBAR \(state) rest field \(f) row bottom \(rowBottom) capsules \(describe(c))")
        clearOfTheBar(state, "field", field, c)
        XCTAssertGreaterThanOrEqual(f.minY, rowBottom - 0.5, "\(state): the field \(f) starts above the row's bottom \(rowBottom)")
        XCTAssertLessThanOrEqual(f.minY, rowBottom + Self.fieldGapAllowed, "\(state): the field \(f) stands more than \(Self.fieldGapAllowed) pt under the row \(rowBottom)")
        XCTAssertTrue(free(field, c), "\(state): the field can't take a tap")
        return f
    }

    /// The accessibility audit with the search open: every issue printed; one on the field, its clear button or the end of
    /// the search fails the test. One finding is skipped by its exact terms: the system search field's own clear button
    /// (UISearchTextField's "Clear text", 20 pt) has a hit region smaller than the audit's minimum. It's the system's
    /// control, not one this app draws or sizes. Skipped as ComposerFieldAuditUITests skips a known finding; anything else
    /// on the search, that button included, still fails.
    private func audit(_ tab: String, fieldFrame: CGRect, near frames: [CGRect]) throws {
        var flagged: [String] = []
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            guard let el = issue.element else { print("SEARCHBAR-AUDIT \(tab) '\(issue.compactDescription)' no element"); return true }
            let line = "'\(issue.compactDescription)' type \(el.elementType.rawValue) id '\(el.identifier)' label '\(el.label)' frame \(el.frame)"
            print("SEARCHBAR-AUDIT \(tab) \(line)")
            if issue.auditType == .hitRegion, issue.compactDescription == "Hit area is too small", el.label == "Clear text",
               fieldFrame.contains(el.frame) {
                print("SEARCHBAR-AUDIT \(tab) ignored: the system search field's own clear button")
                return true
            }
            if frames.contains(where: { $0.intersects(el.frame) }) { flagged.append(line) }
            return true
        }
        XCTAssertTrue(flagged.isEmpty, "\(tab) searching: accessibility issues on the search: \(flagged)")
    }

    /// One round: tap the field and type, check; clear, check; end the search, check. False where the page can't go on
    /// (something to tap stood under the bar, or the search didn't end).
    private func round(_ tab: String, _ n: Int, word: String, rest: CGRect, checksFilter: Bool) throws -> Bool {
        let state = "\(tab) round \(n)"
        var c = caps()
        guard free(field, c) else { XCTFail("\(state): the field can't take a tap"); return false }
        field.tap()
        pause(0.8)
        field.typeText(word)
        pause(1.2)

        // Open.
        c = caps()
        let clear = clearButton, end = endSearch(c)
        print("SEARCHBAR \(state) searching field \(field.frame) clear \(clear.exists ? "\(clear.frame)" : "none") end \(end.map { "'\($0.label)' \($0.frame)" } ?? "none") capsules \(describe(c))")
        clearOfTheBar("\(state) searching", "field", field, c)
        clearOfTheBar("\(state) searching", "clear button", clear, c)
        if let end { clearOfTheBar("\(state) searching", "end of the search", end, c) }
        XCTAssertEqual(field.frame.minY, rest.minY, accuracy: 1, "\(state) searching: the field moved from \(rest.minY) to \(field.frame.minY)")
        XCTAssertTrue(free(clear, c), "\(state) searching: the clear button can't take a tap")
        XCTAssertNotNil(end, "\(state) searching: nothing ends the search clear of the bar")
        if let end { XCTAssertTrue(free(end, c), "\(state) searching: the end of the search can't take a tap") }
        if checksFilter { XCTAssertTrue(chatsFiltered(), "\(state) searching: the list isn't filtered") }
        if n == 1 {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "\(tab) searching"
            shot.lifetime = .keepAlways
            add(shot)
            try audit(tab, fieldFrame: field.frame, near: [field.frame, clear.exists ? clear.frame : .null, end?.frame ?? .null].filter { !$0.isNull })
        }

        // Cleared: the search stays open where it was.
        guard free(clear, c) else { return false }
        clear.tap()
        pause(0.8)
        c = caps()
        let value = (field.value as? String) ?? ""
        print("SEARCHBAR \(state) cleared field \(field.frame) value '\(value)'")
        XCTAssertTrue(value.isEmpty || value == field.placeholderValue, "\(state) cleared: the field still reads '\(value)'")
        let stillOpen = endSearch(c, underTheBarToo: true)
        XCTAssertNotNil(stillOpen, "\(state) cleared: the search closed")
        clearOfTheBar("\(state) cleared", "field", field, c)
        XCTAssertEqual(field.frame.minY, rest.minY, accuracy: 1, "\(state) cleared: the field moved from \(rest.minY) to \(field.frame.minY)")

        // Ended: the field back at rest.
        guard let ender = stillOpen, free(ender, c) else { return false }
        ender.tap()
        pause(1.2)
        c = caps()
        print("SEARCHBAR \(state) ended field \(field.exists ? "\(field.frame)" : "none")")
        let after = endSearch(c, underTheBarToo: true)
        XCTAssertFalse(after?.isHittable == true, "\(state): the search didn't end")
        XCTAssertEqual(field.frame.minY, rest.minY, accuracy: 1, "\(state) ended: the field isn't back at rest: \(field.frame) against \(rest)")
        clearOfTheBar("\(state) ended", "field", field, c)
        return after?.isHittable != true
    }

    /// Chats narrowed to the mock's matching chat (as TopBarRoomUITests checks it).
    private func chatsFiltered() -> Bool {
        let found = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Disk cleanup' AND elementType != %d",
                                                                         XCUIElement.ElementType.searchField.rawValue))
        return found.count > 0 && !app.staticTexts["Bot Chat"].firstMatch.isHittable
    }

    func testSearchTypeClearCancelTwiceStaysClearOfTheBar() throws {
        // Each page from a fresh launch, so a search left open on one can't change the next. Only Chats' filtering is
        // checked; the other words are ones those pages match in the mock.
        let pages: [(tab: String, word: String)] = [("chats", "Disk"), ("bots", "work"), ("settings", "Config")]
        for page in pages {
            try launch()
            guard element("debug.morphframes").exists, !caps().isEmpty else { throw XCTSkip("the floating top bar isn't up (a wide window)") }
            open(page.tab)
            guard let rest = atRest(page.tab) else { app.terminate(); continue }
            for n in 1...2 {
                guard try round(page.tab, n, word: page.word, rest: rest, checksFilter: page.tab == "chats") else { break }
            }
            app.terminate()
        }
    }
}
