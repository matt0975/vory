import XCTest

/// The Chats list's Archived filter on a Hermes that leaves archived chats out of its list unless asked (#474; upstream's
/// `archived=exclude` default, which the mock now has too). A chat opened this launch, then archived from the list with
/// Archived hidden, goes and stays gone through a reload and a page switch: the list adds back chats the app holds
/// that the gateway hasn't listed yet, and it added this one back as unarchived. With Archived shown it's listed,
/// marked Archived, from the gateway's own list; before the fix the app never asked for archived chats, so the filter
/// showed none.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=com.vorantx.vory.demo drives the demo
/// copy. HERMES_E2E_SHOTS names a folder for the stills.
@MainActor
final class ArchivedFilterUITests: XCTestCase {
    private var app: XCUIApplication!
    private let chat = "Backup verification"
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"].flatMap { $0.isEmpty ? nil : $0 }
        let d = folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-chat-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
    }

    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).allElementsBoundByIndex.first { $0.isHittable }
            ?? app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
    }

    /// The row titled `title`, scrolled clear of the bar above and the tab bar below; nil when the list hasn't got it.
    private func reveal(_ title: String) -> XCUIElement? {
        let height = app.windows.firstMatch.frame.height
        func clear() -> Bool { let r = row(title); return r.exists && r.isHittable && r.frame.midY > 140 && r.frame.midY < height - 130 }
        for _ in 0..<8 where !clear() { app.swipeUp(velocity: .slow); pause(0.5) }
        for _ in 0..<12 where !clear() { app.swipeDown(velocity: .slow); pause(0.5) }
        return clear() ? row(title) : nil
    }

    private var filters: XCUIElement { app.buttons["chats.filters"].firstMatch }

    /// An item of the open filters menu: a toggle shows as a button or a switch.
    private func menuItem(_ label: String) -> XCUIElement {
        let button = app.buttons[label].firstMatch
        return button.exists ? button : app.switches[label].firstMatch
    }

    /// The filters menu opened, `label` tapped (the menu closes with it).
    private func pick(_ label: String) {
        XCTAssertTrue(filters.waitForExistence(timeout: 5), "no filters menu")
        filters.tap(); pause(1)
        let item = menuItem(label)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no \(label) in the filters menu")
        item.tap(); pause(3)
    }

    /// Every filter off and Archived shown, the list's defaults: a run before may have left a filter on. With none on,
    /// the menu is closed through the system's own dismiss region: a tap at the top of the screen could land on the
    /// bar's title and open something else.
    private func clearFilters() {
        filters.tap(); pause(1)
        let clear = menuItem("Clear filters")
        if clear.exists {
            clear.tap()
        } else {
            let dismiss = app.otherElements["PopoverDismissRegion"].firstMatch
            if dismiss.exists { dismiss.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap() }
        }
        pause(2)
    }

    /// The row titled `title`, or a still and the element tree in the log when it can't be found.
    private func required(_ title: String, _ why: String) throws -> XCUIElement {
        if let row = reveal(title) { return row }
        shot("archived-missing-\(title.prefix(12))")
        print("ARCHIVED-TREE \(why):\n\(app.debugDescription)")
        return try XCTUnwrap(nil as XCUIElement?, why)
    }

    /// The chat's row menu: `item` tapped.
    private func rowMenu(_ title: String, _ item: String) throws {
        let target = try required(title, "\(title) is not listed")
        target.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons[item].firstMatch.waitForExistence(timeout: 5), "no \(item) in \(title)'s menu")
        app.buttons[item].firstMatch.tap(); pause(3)
    }

    /// Back from a chat to the list.
    private func back() {
        let button = ["chat.back", "page.back"].map { app.buttons[$0].firstMatch }.first { $0.exists && $0.isHittable }
        XCTAssertNotNil(button, "no Back in the chat")
        button?.tap(); pause(2)
    }

    func testTheArchivedFilterAsksTheGatewayForArchivedChats() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        if let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "dark"]
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-launchTab", "chats", "-colorSchemePreference", "dark"]
        }
        app.launch()
        XCTAssertTrue(row("Rewrite the nightly export job").waitForExistence(timeout: 40), "no chat rows")
        pause(2)
        clearFilters()

        // The chat opened this launch (so the app holds it), and back to the list.
        try required(chat, "\(chat) is not listed").tap(); pause(3)
        back()

        // Archived hidden, then the chat archived from its menu: it goes, and stays gone. The app holds the chat, and its
        // list adds back chats it holds that the gateway hasn't listed yet; this one it left out for being archived.
        pick("Archived")
        try rowMenu(chat, "Archive")
        XCTAssertNil(reveal(chat), "the archived chat is still listed with Archived hidden")
        // A reload (a pull) and a page switch.
        app.swipeDown(velocity: .fast); pause(3)
        XCTAssertNil(reveal(chat), "the archived chat came back with a reload")
        app.buttons["tab.settings"].firstMatch.tap(); pause(1.5)
        app.buttons["tab.chats"].firstMatch.tap(); pause(3)
        XCTAssertNil(reveal(chat), "the archived chat came back with a page switch")
        shot("archived-filter-off")

        // Archived shown: listed, marked Archived, from the gateway's own list.
        pick("Archived")
        let archived = try required(chat, "the archived chat isn't listed with Archived on")
        XCTAssertTrue(archived.label.hasPrefix("Archived"), "\(chat) isn't marked archived: \(archived.label)")
        shot("archived-filter-on")

        // Hidden again: gone; shown again: back, which only the gateway's list can bring.
        pick("Archived")
        XCTAssertNil(reveal(chat), "the archived chat is still listed with Archived hidden again")
        pick("Archived")
        let again = try required(chat, "the archived chat didn't come back with Archived on")
        XCTAssertTrue(again.label.hasPrefix("Archived"), "\(chat) came back unmarked: \(again.label)")

        // As found: the chat unarchived.
        try rowMenu(chat, "Unarchive")
        XCTAssertFalse(try required(chat, "the chat is gone after its unarchive").label.hasPrefix("Archived"), "\(chat) is still archived")
    }
}
