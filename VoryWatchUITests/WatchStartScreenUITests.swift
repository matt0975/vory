import XCTest

/// The start screen and the pages it opens, as they are before #387's new screens: the harness's
/// first proof, at every size and mode. Each new screen brings its own test.
final class WatchStartScreenUITests: WatchUITestCase {
    func testStartScreenAndItsPages() throws {
        try launch()
        let settings = button("Settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 40), "no start screen")
        // The chat list from the mock.
        _ = app.staticTexts["Rewrite the nightly export job"].firstMatch.waitForExistence(timeout: 20)
        sleep(1)
        shot("start")

        settings.tap()
        XCTAssertTrue(button("Done").waitForExistence(timeout: 10), "no Settings")
        sleep(1)
        shot("settings")
        button("Done").tap()

        let activity = button("Activity")
        XCTAssertTrue(activity.waitForExistence(timeout: 10), "no Activity button")
        activity.tap()
        XCTAssertTrue(app.navigationBars["Activity"].firstMatch.waitForExistence(timeout: 10) || app.staticTexts["Activity"].firstMatch.waitForExistence(timeout: 5), "no Activity")
        sleep(1)
        shot("activity")
    }
}
