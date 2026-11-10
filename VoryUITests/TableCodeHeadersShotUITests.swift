import XCTest

/// #643: a table card's header beside a code block's, for stills of the two (the mock answers a prompt starting
/// "codetable" with a small table and a bash block in one reply). Wrap on (`-table.wrap YES`, the default), the demo copy
/// on the mock, the scheme from HERMES_E2E_SCHEME (light by default). Both headers wholly on screen under the top bar and
/// above the composer; then one still of the window ("table-code-headers-<device>-<scheme>"), and every frame printed
/// (SHOT lines): the table's switch, full screen and title, and the code block's switch and language, so the two
/// switches' places can be read in numbers too. Checked: both switches 44 pt or more each way. TableCardAuditUITests' launch
/// and its way of putting the keyboard down. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
@MainActor
final class TableCodeHeadersShotUITests: XCTestCase {
    private var app: XCUIApplication!
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private static let tableSwitch = ["Unwrap wide columns", "Wrap columns to fit"]
    private static let codeSwitch = ["Unwrap long lines", "Wrap long lines"]

    func testTheTableAndCodeHeadersSideBySide() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        let scheme = e["HERMES_E2E_SCHEME"] ?? "light"
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats",
                               "-restore.openChat", "none", "-colorSchemePreference", scheme, "-table.wrap", "YES"]
        app.launch()
        let device = app.windows.firstMatch.frame.width > 700 ? "ipad" : "iphone"
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40), "no New Chat")
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "no composer")
        composer.tap()
        composer.typeText("codetable of what fills the disk")
        app.buttons["composer.send"].firstMatch.tap()
        let end = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "the command together")).firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 60), "the reply never finished")
        // The keyboard down, as TableCardAuditUITests puts it down: a tap on the thread at the leading margin, 40% down the
        // window, then a drag from there into the keyboard if it's still up.
        let at = { (x: CGFloat, y: CGFloat) in
            composer.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - composer.frame.minX, dy: y - composer.frame.minY))
        }
        let win = app.windows.firstMatch.frame
        let spot = { at(composer.frame.minX + 10, win.minY + win.height * 0.4) }
        if app.keyboards.firstMatch.exists { spot().tap(); pause(1) }
        if app.keyboards.firstMatch.exists { spot().press(forDuration: 0.05, thenDragTo: at(composer.frame.minX + 10, win.maxY - 4)); pause(1) }
        guard !app.keyboards.firstMatch.exists else { XCTFail("VOID: the keyboard stayed up"); app.terminate(); return }

        // Both headers wholly on screen, under the top bar and above the composer: the thread dragged at the leading margin
        // a step at a time, eight at most.
        let table = app.buttons.matching(NSPredicate(format: "label IN %@", Self.tableSwitch)).firstMatch
        let code = app.buttons.matching(NSPredicate(format: "label IN %@", Self.codeSwitch)).firstMatch
        let back = app.buttons["chat.back"].firstMatch
        let barBottom = back.exists ? back.frame.maxY : win.minY + 100
        let inView = { (b: XCUIElement) in b.exists && b.frame.minY >= barBottom + 4 && b.frame.maxY <= composer.frame.minY - 4 }
        for _ in 0..<8 where !(inView(table) && inView(code)) {
            let step = win.height * 0.2, from = at(composer.frame.minX + 10, win.minY + win.height * 0.5)
            let down = !table.exists || table.frame.minY < barBottom + 4
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: down ? step : -step))); pause(1)
        }
        guard inView(table) && inView(code) else {
            XCTFail("the two headers aren't both on screen: table \(table.exists ? "\(table.frame)" : "-"), code \(code.exists ? "\(code.frame)" : "-")")
            app.terminate(); return
        }
        pause(1)
        let open = app.buttons["Open the table full screen"].firstMatch
        let title = app.staticTexts.matching(NSPredicate(format: "label == 'Table'")).firstMatch
        let lang = app.staticTexts.matching(NSPredicate(format: "label == 'bash'")).firstMatch
        let frame = { (el: XCUIElement) in el.exists ? "\(el.frame)" : "-" }
        print("SHOT \(device) \(scheme) table switch '\(table.label)' \(table.frame), full screen \(frame(open)), title \(frame(title))")
        print("SHOT \(device) \(scheme) code switch '\(code.label)' \(code.frame), language \(frame(lang))")
        print("SHOT \(device) \(scheme) switches' centres apart: x \(code.frame.midX - table.frame.midX), y \(code.frame.midY - table.frame.midY)")
        XCTAssertGreaterThanOrEqual(min(table.frame.width, table.frame.height), 44, "the table's switch \(table.frame) under 44 pt")
        XCTAssertGreaterThanOrEqual(min(code.frame.width, code.frame.height), 44, "the code block's switch \(code.frame) under 44 pt")
        let still = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        still.name = "table-code-headers-\(device)-\(scheme)"; still.lifetime = .keepAlways; add(still)
        app.terminate()
    }
}
