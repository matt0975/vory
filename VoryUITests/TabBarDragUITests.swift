import XCTest

/// #375 (feedback on 24): dragging the lens along the tab bar and letting go on a tab moved the tint
/// there while the page stayed. Every drag let go on another tab shows that tab's page; and a drag
/// the system cancels (forced here with `-vory-test-cancel-bar-drag`, since a synthesized drag is
/// never cancelled) ends with the tint and the page on the same tab.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
@MainActor
final class TabBarDragUITests: XCTestCase {
    private var app: XCUIApplication!
    private let order = ["tab.chats", "tab.bots", "tab.dashboard"]
    private let titles = ["tab.chats": "Chats", "tab.bots": "Bots", "tab.dashboard": "Home"]
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func launch(_ extra: [String] = []) throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        if let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats"] + extra
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-launchTab", "chats"] + extra
        }
        app.launch()
        XCTAssertTrue(any("tab.bots").waitForExistence(timeout: 40), "no tab bar")
        pause(2)
    }

    /// The page in front (the top bar's title) and the tab the bar shows as selected.
    private func state() -> (page: String, tab: String) {
        (any("morph.title").label, order.first { any($0).isSelected } ?? "-")
    }

    private func drag(from: String, to: String, fast: Bool, hold: Double) {
        any(from).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.3, thenDragTo: any(to).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                   withVelocity: fast ? .fast : .slow, thenHoldForDuration: hold)
        pause(1.2)
    }

    func testEveryDragLetGoOnATabShowsItsPage() throws {
        try launch()
        for i in 0..<10 {
            let from = order[i % 3], to = order[(i + 1) % 3]
            drag(from: from, to: to, fast: i % 2 == 1, hold: 0.05)
            let s = state()
            XCTAssertEqual(s.page, titles[to], "drag \(i) let go on \(to): the page is \(s.page)")
            XCTAssertEqual(s.tab, to, "drag \(i) let go on \(to): the bar shows \(s.tab)")
        }
    }

    func testACancelledDragEndsWithTheTintAndThePageTogether() throws {
        try launch(["-vory-test-cancel-bar-drag"])
        // Neighbouring tabs (Home, Chats, Bots along the bar): the cancel comes 0.15 s after the
        // lens reaches the next tab, so a drag past one would end on the one passed.
        for (from, to) in [("tab.chats", "tab.bots"), ("tab.bots", "tab.chats"), ("tab.chats", "tab.dashboard")] {
            // Held on the new tab past the forced cancel.
            drag(from: from, to: to, fast: false, hold: 0.8)
            let s = state()
            XCTAssertEqual(titles.first { $0.value == s.page }?.key, s.tab, "after a cancelled drag the bar shows \(s.tab) over the \(s.page) page")
            XCTAssertEqual(s.tab, to, "a cancelled drag over \(to) did not go on to it")
        }
    }
}
