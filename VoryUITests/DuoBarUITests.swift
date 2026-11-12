import XCTest

/// Vory's own tab bar placed the iPhone Duo's way (1.5, decision 1): where the system would put
/// a vertical bar (the closed display's strip, the open display in landscape) the capsule and
/// the circles stand stacked on that edge; elsewhere the bar runs along the bottom as ever.
/// Needs the iPhone Duo simulator; on any other device the vertical case is skipped. Skipped
/// unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock gateway).
final class DuoBarUITests: XCTestCase {
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

    private func launch(url: String, token: String) {
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats"]
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-launchTab", "chats"]
        }
        app.launch()
    }

    private func tab(_ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "tab.\(name)").firstMatch
    }

    func testTheBarStandsOnTheSideWhereTheSystemWould() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        let chats = tab("chats"), settings = tab("settings")
        XCTAssertTrue(chats.waitForExistence(timeout: 40), "no Chats tab")
        XCTAssertTrue(settings.exists, "no Settings tab")
        let window = app.windows.firstMatch.frame
        let vertical = chats.frame.minY != settings.frame.minY && abs(chats.frame.midX - settings.frame.midX) < 2
        print("DUO-BAR window \(window) chats \(chats.frame) settings \(settings.frame) vertical \(vertical)")
        shot(vertical ? "duo-bar-vertical" : "duo-bar-horizontal")
        // The closed Duo is 466 pt wide in portrait; a phone is narrower. Only the Duo has a
        // strip, so only there the bar must be vertical.
        let closedDuo = abs(window.width - 466) < 2 && window.height > window.width
        if closedDuo {
            XCTAssertTrue(vertical, "on the closed Duo the bar should stand on the side: chats \(chats.frame), settings \(settings.frame)")
            // One column on the system strip's centre line, 48 pt in from the window's edge
            // (VoryTabBar.stripCentreFromEdge), within 1 pt. It was read off the navigation bar's
            // "+" (New bot) standing in the strip; the morph bar has had the page's own items at
            // the top since 1.5 (11), and that "+" is the top bar's now.
            let axis = chats.frame.midX > window.midX ? window.maxX - 48 : window.minX + 48
            let items = [("chats.voice", app.buttons["chats.voice"].firstMatch), ("chats.new", app.buttons["chats.new"].firstMatch), ("tab.chats", chats), ("tab.settings", settings)]
            for (name, e) in items where e.exists {
                print("STRIP-ITEM \(name) \(e.frame)")
                XCTAssertEqual(e.frame.midX, axis, accuracy: 1, "\(name) is off the strip's centre line: \(e.frame.midX) vs \(axis)")
            }
            // Three groups down the strip, never touching: the page's own items (the list's "+"
            // and View menu), then our tabs, then the circles. The first tab starts at least a
            // group gap (10 pt, the system's own) below the last of the page's items (feedback: the
            // filter and Home touched).
            let view = app.buttons["chats.view"].firstMatch
            let firstTab = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).allElementsBoundByIndex
                .filter { $0.exists }.min { $0.frame.minY < $1.frame.minY }
            if view.exists, let firstTab {
                let gap = firstTab.frame.minY - view.frame.maxY
                print("STRIP-GAP view \(view.frame) first tab \(firstTab.frame) gap \(gap)")
                XCTAssertGreaterThanOrEqual(gap, 10 - 0.5, "the first tab sits too close to the list's View menu: gap \(gap)")
            }
            // On the strip's edge, within its own width of it, and the tabs stacked in order.
            let nearEdge = chats.frame.maxX > window.maxX - 80 || chats.frame.minX < 80
            XCTAssertTrue(nearEdge, "the vertical bar is not on an edge: \(chats.frame)")
            XCTAssertLessThan(chats.frame.minY, settings.frame.minY, "the tabs are not stacked top to bottom")
        } else if window.width < 460 {
            XCTAssertFalse(vertical, "a phone keeps the bar along the bottom")
            XCTAssertGreaterThan(chats.frame.midY, window.height * 0.8, "the bar is not along the bottom")
        } else {
            throw XCTSkip("neither a phone nor the closed Duo: \(window)")
        }
        // The pages are inset by the bar, not under it: the list's first row does not overlap the bar.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch
        if row.waitForExistence(timeout: 30) {
            XCTAssertFalse(row.frame.intersects(chats.frame), "the first row runs under the bar: row \(row.frame) bar \(chats.frame)")
        }
    }
}
