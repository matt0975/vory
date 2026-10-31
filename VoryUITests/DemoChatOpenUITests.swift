import XCTest

/// #491: every demo chat, at four exchanges or fewer, opens at its end with no visible jump. Read from the app's DEBUG
/// probe (`-vory-coldopen-probe`, `ColdOpenProbe`, as #449 and #453 read a long chat's open): how the thread moved in
/// the four seconds after the chat appeared. Each chat is opened once per launch, so each open is its first; the demo
/// copy keeps nothing between launches. HERMES_E2E_CYCLES sets how many launches (2 by default). Runs on the demo copy
/// (HERMES_E2E_BUNDLE); skipped without it.
@MainActor
final class DemoChatOpenUITests: XCTestCase {
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    /// The demo's chats by title (DemoContent.chats).
    private let titles = ["Packing list for the lake weekend", "Morning checks on the home servers", "Bot Chat",
                          "Why is the NAS slow tonight?", "Newsletter intro, take two", "Colours for the garden sign",
                          "Compare three e-readers", "Weekly budget check-in"]

    /// The probe's reading of the last open: (title, items, moves of 80 pt or more in sight, settle ms, the largest throw
    /// up in pt, when the thread was shown with its whole history, ms).
    private func reading(_ app: XCUIApplication) -> (title: String, items: Int, moves: Int, settle: Int, thrown: Int, shown: Int)? {
        let e = app.descendants(matching: .any).matching(identifier: "debug.coldopen").firstMatch
        guard e.waitForExistence(timeout: 5), let v = e.value as? String else { return nil }
        let f = v.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 6, let items = Int(f[1]), let moves = Int(f[2]), let settle = Int(f[3]), let thrown = Int(f[4]), let shown = Int(f[5]) else { return nil }
        return (f[0], items, moves, settle, thrown, shown)
    }

    /// The row's tap point (its middle) in view between the list's header and a tab bar at the bottom (a row under the
    /// floating tab bar reads as hittable, and the tap goes to the tab; at the largest text sizes a row is taller than
    /// the gap), the list dragged a fifth of a screen at a time: down the list first, then back up.
    private func reveal(_ row: XCUIElement, in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        let bar = app.buttons["tab.chats"].firstMatch
        func clear() -> Bool {
            guard row.exists, row.isHittable else { return false }
            let w = window.frame
            let bottom = bar.exists && bar.frame.minY > w.midY ? bar.frame.minY - 12 : w.maxY - 24
            return row.frame.midY >= w.minY + 160 && row.frame.midY <= bottom - 20
        }
        func drag(_ from: CGFloat, _ to: CGFloat) {
            // In the list's own column (the iPad's list is a sidebar).
            let x = row.exists ? row.frame.midX / window.frame.width : 0.5
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: from))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: to)))
            pause(0.6)
        }
        for _ in 0..<8 where !clear() { drag(0.65, 0.45) }
        for _ in 0..<8 where !clear() { drag(0.35, 0.55) }
        return clear()
    }

    func testEveryDemoChatOpensAtItsEndWithoutAJump() throws {
        let e = ProcessInfo.processInfo.environment
        guard let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { throw XCTSkip("HERMES_E2E_BUNDLE not set") }
        continueAfterFailure = true
        let cycles = Int(e["HERMES_E2E_CYCLES"] ?? "") ?? 2
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo", "-companionPromptShown", "YES", "-launchTab", "chats", "-vory-coldopen-probe"]
            + (e["HERMES_E2E_GEOMETRY"] == "1" ? ["-vory-geometry-log"] : [])
        let back = app.buttons["chat.back"].firstMatch
        for c in 1...cycles {
            app.launch()
            for title in titles {
                let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND NOT (identifier BEGINSWITH 'chat.')", title)).firstMatch
                let chats = app.buttons["tab.chats"].firstMatch
                if chats.exists, !chats.isSelected { chats.tap(); pause(1) }
                guard row.waitForExistence(timeout: 30), reveal(row, in: app) else { XCTFail("no row in view for \(title) in cycle \(c)"); continue }
                pause(1)
                row.tap()
                pause(4)
                guard let r = reading(app) else { XCTFail("no reading for \(title) in cycle \(c)"); continue }
                guard r.title == title else { XCTFail("\(title) \(c): the reading is \(r.title)'s, the tap opened something else"); continue }
                print("DEMO-OPEN \(c): \(r.title), \(r.items) items, shown at \(r.shown) ms, \(r.moves) moves, settled at \(r.settle) ms, thrown \(r.thrown) pt")
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "demo-open-\(c)-\(title)"; shot.lifetime = .keepAlways; add(shot)
                XCTAssertTrue((0...800).contains(r.shown), "\(title) \(c): shown at \(r.shown) ms (-1: never in sight)")
                XCTAssertEqual(r.moves, 0, "\(title) \(c): \(r.moves) moves of 80 pt or more in sight as it opened")
                XCTAssertLessThanOrEqual(r.thrown, 10, "\(title) \(c): thrown \(r.thrown) pt up the thread as it opened")
                if back.waitForExistence(timeout: 5) { back.tap() }
                pause(1)
            }
            app.terminate()
            pause(1)
        }
    }
}
