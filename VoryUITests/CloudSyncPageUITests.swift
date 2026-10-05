import XCTest

/// Settings › iCloud Sync on a phone: the page's last footer clears the tab bar (it ended
/// under it), and the daily-backup switch is there. A screenshot of the page's end is kept.
final class CloudSyncPageUITests: XCTestCase {
    private var app: XCUIApplication!

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = query.allElementsBoundByIndex.first(where: { $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-chat-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
        print("CHAT-SHOT \(d.appendingPathComponent("\(name).png").path)")
    }

    func testTheICloudPageEndsAboveTheTabBar() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-launchTab", "settings"]
        app.launch()
        guard let row = hittable(app.buttons.matching(identifier: "settings.row.icloud"), timeout: 20) else { return XCTFail("no iCloud Sync row") }
        row.tap()
        let toggle = app.switches["cloud.autoBackup"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no Back up automatically switch")
        // To the end of the page: the last footer must sit above the bar, not under it.
        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("icloud-page-end")
        let footer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Stays on each device'")).firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "the page's last footer is not there")
        let bar = app.buttons["tab.settings"].firstMatch
        XCTAssertTrue(bar.exists)
        // The footer's bottom edge is above the bar's top edge.
        XCTAssertLessThanOrEqual(footer.frame.maxY, bar.frame.minY + 1, "the last footer ends under the tab bar (footer \(footer.frame), bar \(bar.frame))")
    }
}
