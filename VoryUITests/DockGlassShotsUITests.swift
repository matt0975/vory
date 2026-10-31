import XCTest

/// Pictures of the thread behind the composer's glass (Matt, 2026-10-10: no fade above the
/// bar, the text seen through the field as in 1.4; the page's background below the bar only).
/// Light and dark, keyboard up: scrolled to the middle so text passes behind the bar, and at
/// the end; then the end with the keyboard down. For review, not an assertion of
/// looks. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
final class DockGlassShotsUITests: XCTestCase {
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

    private func launch(url: String, token: String, scheme: String) {
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-colorSchemePreference", scheme, "-launchTab", "chats"]
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-colorSchemePreference", scheme, "-launchTab", "chats"]
        }
        app.launch()
    }

    private func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    func testTheThreadBehindTheGlass() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        for scheme in ["light", "dark"] {
            launch(url: url, token: token, scheme: scheme)
            // The seeded long chat.
            let rows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Disk cleanup'"))
            let deadline = Date().addingTimeInterval(40)
            var row: XCUIElement?
            while row == nil, Date() < deadline {
                row = rows.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
                if row == nil { settle(0.3) }
            }
            guard let row else { XCTFail("the seeded chat is not listed"); continue }
            row.tap()
            let composer = app.textViews["composer.text"].firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 30))
            settle(1.5)
            shot("dock-\(scheme)-1-end")
            composer.tap()
            settle(1.5)
            shot("dock-\(scheme)-2-end-keyboard")
            // Up the thread so its words pass behind the bar.
            app.swipeDown(velocity: .slow)
            settle(1.5)
            shot("dock-\(scheme)-3-middle-keyboard")
            app.terminate()
        }
    }
}
