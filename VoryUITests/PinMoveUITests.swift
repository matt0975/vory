import XCTest

/// #372 (Matt on 24: "the pinned chats at the top has poor animations and stutters"): pinning a
/// chat moves its row up into the pinned rows once its swipe or its menu has closed, with nothing
/// left behind in its old place; unpinning moves it back down the same way; and the swipe on a
/// pinned row opens as any other. The marks are wall-clock, to line up with a recording of the run.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
@MainActor
final class PinMoveUITests: XCTestCase {
    private var app: XCUIApplication!
    /// The row pinned: the oldest of the person's own chats, under "Bot Chat", so a pin moves it up. The mock's
    /// "Weekly dependency audit" was the row until #673: it's scheduled, and waits in the Scheduled section.
    private let subject = "Rewrite the nightly export job"
    private var titles: [String] { ["Disk cleanup", "Bot Chat", subject] }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func mark(_ s: String) { print("PIN-AT \(s) \(String(format: "%.3f", Date().timeIntervalSince1970))") }

    private func launch() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        if let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "light"]
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-launchTab", "chats", "-colorSchemePreference", "light"]
        }
        app.launch()
        XCTAssertTrue(row("Rewrite the nightly export job").waitForExistence(timeout: 40), "no chat rows")
        pause(3)
    }

    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).allElementsBoundByIndex.first { $0.isHittable }
            ?? app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
    }

    /// Rows top to bottom, by their titles.
    private func order() -> [String] {
        titles.compactMap { t -> (String, CGFloat)? in
            let r = row(t)
            return r.exists ? (t, r.frame.minY) : nil
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    func testPinAndUnpinMoveTheRow() throws {
        try launch()
        let before = order()
        print("PIN-ORDER before \(before)")

        // Pin: the leading swipe, then Pin.
        mark("pin swipe")
        row(subject).swipeRight()
        let pin = app.buttons["Pin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "no Pin action")
        mark("pin tap")
        pin.tap()
        pause(2.4)
        let pinned = order()
        print("PIN-ORDER pinned \(pinned)")
        XCTAssertEqual(pinned.firstIndex(of: subject).map { $0 < 2 }, true, "the pinned row did not move up into the pinned rows")

        // The swipe on a pinned row, opened and held.
        mark("reveal")
        row(subject).swipeRight()
        let unpin = app.buttons["Unpin"].firstMatch
        XCTAssertTrue(unpin.waitForExistence(timeout: 5), "no Unpin action")
        pause(1.5)

        // Unpin: back down.
        mark("unpin tap")
        unpin.tap()
        pause(2.5)
        let after = order()
        print("PIN-ORDER after \(after)")
        XCTAssertEqual(after, before, "unpinning did not put the row back where it was")
        mark("done")
    }

    /// A wide window (the iPad's two columns), the chat open beside the list: pinning and unpinning
    /// it keeps it open there, though its row in the list is a new one each time (1.5 (26)). The
    /// selected row's tint is in the screenshots (attachments "pin-wide-*").
    func testPinningTheChatOpenBesideTheListKeepsItOpen() throws {
        try launch()
        let window = app.windows.firstMatch.frame
        guard window.width > 700 else { throw XCTSkip("needs a wide window (the iPad's two columns)") }
        // The list's row, not the open chat's header beside it (which names the chat too).
        func listRow(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).allElementsBoundByIndex
                .first { $0.isHittable && $0.frame.maxX < window.midX } ?? row(title)
        }
        listRow(subject).tap()
        let header = app.descendants(matching: .any).matching(identifier: "chat.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15), "the chat did not open beside the list")
        let opened = header.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", subject)).firstMatch
        pause(2)
        shot("pin-wide-open")
        for (action, name) in [("Pin", "pinned"), ("Unpin", "unpinned")] {
            mark("wide \(name) swipe")
            listRow(subject).swipeRight()
            let b = app.buttons[action].firstMatch
            XCTAssertTrue(b.waitForExistence(timeout: 5), "no \(action) action")
            mark("wide \(name) tap")
            b.tap()
            pause(2.4)
            shot("pin-wide-\(name)")
            XCTAssertTrue(header.exists, "the chat beside the list closed when it was \(name)")
            XCTAssertTrue(opened.exists || header.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Rewrite")).firstMatch.exists,
                          "another chat is open beside the list after it was \(name)")
        }
    }

    /// The accessibility audit on Chats with a chat pinned (its row a new one, 1.5 (26)): nothing on
    /// the chats' rows. What the audit flags elsewhere is printed (PIN-AUDIT).
    func testChatsAuditWithAPinnedChat() throws {
        try launch()
        row(subject).swipeRight()
        let pin = app.buttons["Pin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "no Pin action")
        pin.tap()
        pause(2.4)
        let rows = titles.map { row($0) }.filter { $0.exists }
        let region = rows.map { $0.frame }.reduce(rows.first?.frame ?? .zero) { $0.union($1) }
        var flagged: [String] = []
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            guard let el = issue.element else { print("PIN-AUDIT '\(issue.compactDescription)' no element"); return true }
            let line = "'\(issue.compactDescription)' type \(el.elementType.rawValue) id '\(el.identifier)' label '\(el.label)' frame \(el.frame)"
            print("PIN-AUDIT \(line)")
            if region.intersects(el.frame), el.frame.width < region.width + 1 { flagged.append(line) }
            return true
        }
        XCTAssertTrue(flagged.isEmpty, "the audit flags the chats' rows: \(flagged)")
        // Put it back for the tests after.
        row(subject).swipeRight()
        let unpin = app.buttons["Unpin"].firstMatch
        if unpin.waitForExistence(timeout: 5) { unpin.tap(); pause(2.4) }
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }

    /// The same move from the row's menu (no swipe): pressed and held, Pin; then Unpin the same way.
    func testPinFromTheMenu() throws {
        try launch()
        let before = order()
        mark("menu press")
        row(subject).press(forDuration: 1.0)
        let pin = app.buttons["Pin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "no Pin in the menu")
        mark("menu pin")
        pin.tap()
        pause(2.4)
        let pinned = order()
        print("PIN-ORDER menu pinned \(pinned)")
        XCTAssertEqual(pinned.firstIndex(of: subject).map { $0 < 2 }, true, "the pinned row did not move up into the pinned rows")

        row(subject).press(forDuration: 1.0)
        let unpin = app.buttons["Unpin"].firstMatch
        XCTAssertTrue(unpin.waitForExistence(timeout: 5), "no Unpin in the menu")
        mark("menu unpin")
        unpin.tap()
        pause(2.4)
        XCTAssertEqual(order(), before, "unpinning from the menu did not put the row back where it was")
        mark("done")
    }
}
