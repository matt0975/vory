import XCTest

/// What the person had under their hands survives a rotation: the open chat, the half-typed
/// draft, the keyboard focus and the thread's place. On the open iPhone Duo the rotation is
/// also a switch between one column (upright) and two (wide), which rebuilds the chat's views
/// (2026-10-10: one column in portrait). Run on a regular-width simulator (the Duo, an
/// iPad). Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
@MainActor
final class RotationSurvivalUITests: XCTestCase {
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
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "light"]
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-launchTab", "chats", "-colorSchemePreference", "light"]
        }
        app.launch()
    }

    private func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// A row of the thread on screen, by its words, with where it is.
    private func mark() -> (label: String, y: CGFloat)? {
        guard let snap = try? app.snapshot() else { return nil }
        let window = app.windows.firstMatch.frame
        // The chat's own column: from the composer's left edge (beside a list on a wide window).
        let columnLeft = app.textViews["composer.text"].firstMatch.frame.minX - 60
        var out: [(String, CGFloat)] = []
        func walk(_ s: XCUIElementSnapshot) {
            // A sentence of the thread, not the title pill, a status or a list row: long, in the
            // chat's column, and not the chat's name.
            if s.elementType == .staticText, s.label.count >= 40, !s.label.contains("…"), !s.label.hasPrefix("Disk cleanup"),
               s.frame.minX >= columnLeft, s.frame.minY > window.minY + 120, s.frame.maxY < window.maxY - 160 { out.append((s.label, s.frame.minY)) }
            for c in s.children { walk(c) }
        }
        walk(snap)
        return out.first
    }

    private func focused(_ e: XCUIElement) -> Bool { (e.value(forKey: "hasKeyboardFocus") as? Bool) ?? false }

    private func check(_ label: String, draft: String, marked: String) {
        XCTAssertTrue(app.buttons["chat.titlePill"].firstMatch.waitForExistence(timeout: 10), "\(label): the open chat was lost")
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "\(label): no composer")
        XCTAssertEqual(composer.value as? String, draft, "\(label): the draft changed")
        XCTAssertTrue(focused(composer), "\(label): the composer lost the keyboard")
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", marked)).firstMatch
        XCTAssertTrue(row.exists && app.windows.firstMatch.frame.intersects(row.frame), "\(label): the row that was on screen (\(marked.prefix(30))) is gone: the thread moved")
    }

    func testTheChatDraftFocusAndPlaceSurviveARotation() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        launch(url: url, token: token)
        let rows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Disk cleanup'"))
        let deadline = Date().addingTimeInterval(40)
        var row: XCUIElement?
        while row == nil, Date() < deadline { row = rows.allElementsBoundByIndex.first { $0.exists && $0.isHittable }; if row == nil { settle(0.3) } }
        try XCTUnwrap(row, "the seeded chat is not listed").tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        settle(1.5)
        // Up the thread a little, then a half-typed draft with the cursor in the box.
        app.swipeDown(velocity: .slow)
        settle(1)
        let marked = try XCTUnwrap(mark(), "no row on screen").label
        composer.tap()
        composer.typeText("half a draft")
        settle(0.5)
        shot("rotate-1-portrait")
        check("portrait", draft: "half a draft", marked: marked)

        XCUIDevice.shared.orientation = .landscapeLeft
        settle(2.5)
        shot("rotate-2-landscape")
        check("landscape", draft: "half a draft", marked: marked)

        XCUIDevice.shared.orientation = .portrait
        settle(2.5)
        shot("rotate-3-portrait-again")
        check("portrait again", draft: "half a draft", marked: marked)
        XCUIDevice.shared.orientation = .landscapeLeft
    }
}
