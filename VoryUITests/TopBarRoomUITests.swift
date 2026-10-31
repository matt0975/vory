import XCTest

/// #340: every root page starts under the floating top bar's row: its search field (Chats, Bots, Settings) or its first
/// row (Home), never under the bot circle, the title or the page's own buttons. On the closed iPhone Duo the system's
/// bars stand in a side strip and keep no band at the top, and the search drawer rode up under the row (the bot circle
/// over the magnifier, the title over "Search chats"); on any other phone the system's band keeps it there already, so
/// the test holds everywhere and is meant for the closed Duo. Chats' search also takes a tap and filters. Skipped unless
/// HERMES_E2E_URL / HERMES_E2E_TOKEN are set (and the bar is up: a wide window has the system's own bar).
@MainActor
final class TopBarRoomUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(url: String, token: String, tab: String) {
        let args = ["-companionPromptShown", "YES", "-launchTab", tab, "-colorSchemePreference", "light"]
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
    }

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    /// The bar's bottom on this page, once it has settled; nil without the bar (a wide window).
    private func barBottom() -> CGFloat? {
        let bar = app.descendants(matching: .any).matching(identifier: "morph.bar").firstMatch
        guard bar.waitForExistence(timeout: 30) else { return nil }
        pause(1.5)
        return bar.frame.maxY
    }

    /// The accessibility audit under the bar's row, down to the search field: every issue is printed (TOPROOM-AUDIT), and
    /// one whose element lies in that band fails the test. The bar's own controls (above `from`) are printed only:
    /// they are the bar's, the same with or without the room.
    private func auditTheTop(_ tab: String, from: CGFloat, down: CGFloat) throws {
        let band = CGRect(x: 0, y: from, width: app.frame.width, height: max(0, down - from))
        var flagged: [String] = []
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            guard let el = issue.element else { print("TOPROOM-AUDIT \(tab) '\(issue.compactDescription)' no element"); return true }
            let line = "'\(issue.compactDescription)' type \(el.elementType.rawValue) id '\(el.identifier)' label '\(el.label)' frame \(el.frame)"
            print("TOPROOM-AUDIT \(tab) \(line)")
            if band.contains(CGPoint(x: el.frame.midX, y: el.frame.midY)) { flagged.append(line) }
            return true
        }
        XCTAssertTrue(flagged.isEmpty, "\(tab): accessibility issues in the top band: \(flagged)")
    }

    func testEachRootPageStartsUnderTheBar() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        continueAfterFailure = true
        for tab in ["chats", "bots", "settings"] {
            launch(url: url, token: token, tab: tab)
            guard let bottom = barBottom() else { throw XCTSkip("no morph bar (a wide window)") }
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 15), "\(tab): no search field")
            XCTAssertGreaterThanOrEqual(search.frame.minY, bottom, "\(tab): the search field (\(search.frame)) starts under the bar's row (bottom \(bottom))")
            // And no empty band under the row (Duo stage 2: the open Duo upright once had 66 pt there): the drawer within
            // 16 pt of the row's bottom, on every device (a phone about 6, the closed Duo 8, the open Duo upright 11).
            XCTAssertLessThanOrEqual(search.frame.minY - bottom, 16, "\(tab): an empty band of \(Int(search.frame.minY - bottom)) pt under the bar's row")
            XCTAssertTrue(search.isHittable, "\(tab): the search field is not hittable")
            try auditTheTop(tab, from: bottom, down: search.frame.maxY + 4)
            if tab == "chats" {
                // It takes a tap and filters the list.
                XCTAssertTrue(app.staticTexts["Bot Chat"].firstMatch.waitForExistence(timeout: 15), "no Bot Chat row to filter out")
                search.tap()
                // One word: the mock's search matches the query as sent, and a space arrives encoded.
                search.typeText("Disk")
                pause(1.5)
                let found = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Disk cleanup' AND elementType != %d", XCUIElement.ElementType.searchField.rawValue))
                XCTAssertGreaterThan(found.count, 0, "the search lost the matching chat")
                XCTAssertFalse(app.staticTexts["Bot Chat"].firstMatch.isHittable, "the search did not filter the list")
            }
            app.terminate()
        }
        // Home has no search: its first row (the greeting) starts under the row.
        launch(url: url, token: token, tab: "dashboard")
        guard let bottom = barBottom() else { throw XCTSkip("no morph bar (a wide window)") }
        let greeting = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Good '")).firstMatch
        XCTAssertTrue(greeting.waitForExistence(timeout: 15), "Home: no greeting")
        XCTAssertGreaterThanOrEqual(greeting.frame.minY, bottom, "Home: the greeting (\(greeting.frame)) starts under the bar's row (bottom \(bottom))")
    }
}
