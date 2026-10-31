import XCTest

/// #516 (Duo stage 3), on the open iPhone Duo upright, checked by frames in whatever pose Device Hub has the simulator in:
/// - **The title pills clear of the page** (wherever the floating top bar is up): on Home, Chats, Bots and Settings and
///   on Settings › Config, no capsule of the bar's row (`-vory-morph-frames`, the capsules as drawn) meets the page's
///   heading or its search field, and the field starts under the row, within `fieldGapAllowed` of it. With the search
///   active, the field and Cancel stay clear of the row and Cancel ends the search, the field back where it was. The
///   same after a scroll down and back, after Back, and after a back swipe finished and one let go. A search held open
///   stays clear across another tab and back, and across a result pushed and popped.
/// Every frame is printed (DUO516); each tap that changes the room is marked on the wall clock (DUO516 MARK) for the
/// stills taken from a recording of the open display (XCUITest's own screenshot is of the closed one).
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock gateway).
@MainActor
final class Duo516UITests: XCTestCase {
    private var app: XCUIApplication!
    /// The search field's top within this of the row's bottom (stage 2's positional gate).
    static let fieldGapAllowed: CGFloat = 16

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func wall() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }
    private func mark(_ what: String) { print("DUO516 MARK \(what) wall \(wall())") }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func launch(_ extra: [String]) throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "dashboard",
                               "-colorSchemePreference", e["HERMES_E2E_APPEARANCE"] ?? "light"] + extra
        app.launch()
        XCTAssertTrue(element("tab.dashboard").waitForExistence(timeout: 40), "no Home tab")
        pause(2)
    }

    private func open(_ tab: String) {
        // The keyboard hides the bar: put it away with Return, which leaves a search open (a person does the same).
        if app.keyboards.count > 0, !element("tab.\(tab)").isHittable { app.typeText("\n"); pause(1) }
        let t = element("tab.\(tab)")
        XCTAssertTrue(t.waitForExistence(timeout: 10), "no tab \(tab)")
        t.tap()
        pause(1.5)
    }

    // MARK: The title pills

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

    private func caps() -> [String: CGRect] {
        let r = element("debug.morphframes")
        return r.exists ? Self.capsules(in: (r.value as? String) ?? "") : [:]
    }

    /// The page's heading or search field against the row's capsules: no overlap; a field starts under the row.
    @discardableResult
    private func checkClear(_ state: String, field: XCUIElement?, heading: XCUIElement?) -> CGRect? {
        let c = caps()
        guard !c.isEmpty else { XCTFail("\(state): no top bar frames (is the bar up?)"); return nil }
        let rowBottom = c.values.map(\.maxY).max() ?? 0
        print("DUO516 PILL \(state) capsules \(c.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) row bottom \(rowBottom)")
        var fieldFrame: CGRect?
        for (what, e) in [("field", field), ("heading", heading)] {
            guard let e, e.exists, e.frame.height > 0 else { continue }
            let f = e.frame
            print("DUO516 PILL \(state) \(what) \(f)")
            for (slot, cap) in c { XCTAssertFalse(f.intersects(cap), "\(state): the \(what) \(f) meets the bar's \(slot) capsule \(cap)") }
            XCTAssertGreaterThanOrEqual(f.minY, rowBottom - 0.5, "\(state): the \(what) starts above the row's bottom \(rowBottom): \(f)")
            if what == "field" {
                XCTAssertLessThanOrEqual(f.minY, rowBottom + Self.fieldGapAllowed, "\(state): the field \(f) stands more than \(Self.fieldGapAllowed) pt under the row \(rowBottom)")
                fieldFrame = f
            }
        }
        return fieldFrame
    }

    private var field: XCUIElement { app.searchFields.firstMatch }

    /// The button that ends the search: beside the field on its row, to its right ("Cancel" on older systems, a closing
    /// glyph on newer ones). None while the search is at rest. Its label is printed, to name it.
    private var endSearch: XCUIElement {
        guard field.exists else { return app.buttons["no such button"] }
        let f = field.frame
        let beside = app.buttons.allElementsBoundByIndex.first { b in
            b.exists && b.isHittable && abs(b.frame.midY - f.midY) < 12 && b.frame.minX >= f.maxX - 4 && b.frame.minX < f.maxX + 60
        }
        if let beside { print("DUO516 PILL end of search: '\(beside.identifier)' '\(beside.label)' \(beside.frame)"); return beside }
        return app.buttons["no such button"]
    }

    /// Tap the field, type, check, Cancel, check it's back at rest.
    private func searchRound(_ state: String, rest: CGRect?) {
        guard field.exists, field.isHittable else { print("DUO516 PILL \(state) no field to search"); return }
        mark("\(state) field tap")
        field.tap()
        pause(0.8)
        field.typeText("a")
        pause(0.8)
        let c = caps()
        let rowBottom = c.values.map(\.maxY).max() ?? 0
        let cancel = endSearch
        print("DUO516 PILL \(state) searching field \(field.frame) cancel \(cancel.exists ? "\(cancel.frame)" : "none") row bottom \(rowBottom)")
        for (slot, cap) in c {
            XCTAssertFalse(field.frame.intersects(cap), "\(state) searching: the field \(field.frame) meets the \(slot) capsule \(cap)")
            if cancel.exists { XCTAssertFalse(cancel.frame.intersects(cap), "\(state) searching: Cancel \(cancel.frame) meets the \(slot) capsule \(cap)") }
        }
        XCTAssertTrue(cancel.exists && cancel.isHittable, "\(state) searching: Cancel can't be hit")
        // The field stays where it was at rest while the search is presented (the bar is kept there).
        if let rest { XCTAssertEqual(field.frame.minY, rest.minY, accuracy: 1, "\(state) searching: the field moved from \(rest.minY) to \(field.frame.minY)") }
        guard cancel.exists else { return }
        mark("\(state) cancel tap")
        cancel.tap()
        pause(1.2)
        XCTAssertFalse(endSearch.exists && endSearch.isHittable, "\(state): Cancel didn't end the search")
        if let rest, field.exists {
            print("DUO516 PILL \(state) after cancel field \(field.frame) rest \(rest)")
            XCTAssertEqual(field.frame.minY, rest.minY, accuracy: 1, "\(state): the field didn't come back to rest: \(field.frame) against \(rest)")
        }
    }

    /// With a search open: the field and Cancel clear of the row's capsules.
    private func checkSearching(_ state: String, rest: CGRect) {
        let c = caps()
        let cancel = endSearch
        print("DUO516 PILL \(state) field \(field.exists ? "\(field.frame)" : "none") cancel \(cancel.exists ? "\(cancel.frame)" : "none") row bottom \(c.values.map(\.maxY).max() ?? 0)")
        XCTAssertTrue(field.exists && cancel.exists, "\(state): the search isn't open any more")
        if field.exists { XCTAssertEqual(field.frame.minY, rest.minY, accuracy: 1, "\(state): the field moved from \(rest.minY) to \(field.frame.minY)") }
        for (slot, cap) in c {
            if field.exists { XCTAssertFalse(field.frame.intersects(cap), "\(state): the field \(field.frame) meets the \(slot) capsule \(cap)") }
            if cancel.exists { XCTAssertFalse(cancel.frame.intersects(cap), "\(state): Cancel \(cancel.frame) meets the \(slot) capsule \(cap)") }
        }
    }

    /// A search held across the page being covered (#516): with Settings' search open, another tab and back,
    /// then a result pushed and popped; the room stays full each time, so the field and Cancel stay clear of the row.
    private func searchHeldAcrossCovers() {
        open("settings")
        guard field.exists, field.isHittable else { XCTFail("settings: no search field"); return }
        let rest = field.frame
        mark("settings held field tap")
        field.tap(); pause(0.8)
        field.typeText("Config\n"); pause(1)
        checkSearching("settings searching", rest: rest)
        open("dashboard")
        open("settings")
        checkSearching("settings searching, after another tab", rest: rest)
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Config'")).firstMatch
        if result.waitForExistence(timeout: 5) {
            result.tap(); pause(1.5)
            let back = element("page.back")
            if back.exists { back.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
            pause(1.5)
            checkSearching("settings searching, after a result pushed and popped", rest: rest)
        } else { XCTFail("settings searching: no Config result") }
        let cancel = endSearch
        if cancel.exists { mark("settings held cancel tap"); cancel.tap(); pause(1.2) }
    }

    func testTheTitlePillsStandClearOfTheirPages() throws {
        try launch(["-vory-morph-frames"])
        pause(1)
        guard element("debug.morphframes").exists, !caps().isEmpty else { throw XCTSkip("the floating top bar isn't up (a wide window)") }
        open("dashboard")
        checkClear("dashboard", field: nil, heading: element("home.heading"))
        for tab in ["chats", "bots", "settings"] {
            open(tab)
            // The field of a drawer that shows at the top of the list.
            let rest = checkClear(tab, field: field, heading: nil)
            searchRound(tab, rest: rest)
            // A scroll down and back: the frames as at rest.
            let w = app.windows.firstMatch
            w.swipeUp(); pause(0.8); w.swipeDown(); w.swipeDown(); pause(1.2)
            checkClear("\(tab) after scroll", field: field, heading: nil)
        }
        searchHeldAcrossCovers()
        // Settings › Config (its search always shown): there, searching, and after Back and the back swipes.
        open("settings")
        let config = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Config'")).firstMatch
        guard config.waitForExistence(timeout: 10) else { XCTFail("no Config row in Settings"); return }
        config.tap(); pause(1.5)
        let rest = checkClear("settings.config", field: field, heading: nil)
        searchRound("settings.config", rest: rest)
        let back = element("page.back")
        if back.exists { back.tap(); pause(1.5) }
        checkClear("settings after back", field: field, heading: nil)
        // A back swipe finished, then one let go halfway.
        config.tap(); pause(1.5)
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        pause(1.5)
        checkClear("settings after a back swipe", field: field, heading: nil)
        config.tap(); pause(1.5)
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.2)
        pause(1.5)
        checkClear("settings.config after a back swipe let go", field: field, heading: nil)
    }
}
