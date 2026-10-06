import XCTest

/// Settings › About says where the source code is and under which licence, as a link row. A
/// screenshot of the row is kept. HERMES_E2E_BUNDLE=com.vorantx.vory.demo drives the demo copy.
final class AboutSourceUITests: XCTestCase {
    private var app: XCUIApplication!

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

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = query.allElementsBoundByIndex.first(where: { $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    /// A list row below the fold does not exist to the test until it is scrolled to.
    private func scrolledTo(_ query: XCUIElementQuery, swipes: Int = 8) -> XCUIElement? {
        var found = hittable(query, timeout: 5)
        var n = 0
        while found == nil, n < swipes {
            app.swipeUp(velocity: .slow)
            n += 1
            found = hittable(query, timeout: 2)
        }
        return found
    }

    func testAboutLinksToTheSourceCodeAndNamesTheLicence() throws {
        continueAfterFailure = false
        let e = ProcessInfo.processInfo.environment
        if let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            var args = ["-companionPromptShown", "YES", "-launchTab", "settings"]
            if let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty { args = ["-vory-demo-gateway", u, t, "Workshop"] + args }
            app.launchArguments = args
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-launchTab", "settings"]
        }
        app.launch()
        if hittable(app.buttons.matching(identifier: "settings.row.about"), timeout: 5) == nil,
           let tab = hittable(app.buttons.matching(identifier: "tab.settings"), timeout: 20) {
            tab.tap()
        }
        guard let about = scrolledTo(app.buttons.matching(identifier: "settings.row.about")) else { shot("about-no-row"); return XCTFail("no About row") }
        about.tap()
        // A link or a button, depending on how the list exposes it.
        guard let source = scrolledTo(app.descendants(matching: .any).matching(identifier: "about.source")) else { shot("about-no-source"); return XCTFail("no source code row on About") }
        XCTAssertEqual(source.label, "Source code on GitHub, MIT licence")
        shot("about-source-row")
    }
}
