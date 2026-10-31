import XCTest

/// The battery rule (#387): a working bot's face moves only while the screen is lit. With the wrist
/// down (the always-on, dimmed state, drawn through the DEBUG launch argument) it holds still; lit,
/// it moves, which shows the comparison can see motion at all. Needs a bot at work: run the mock
/// with MOCK_WORKING set to a chat of the default bot ("nightly export") and tell the tests so with
/// TEST_RUNNER_HERMES_E2E_WORKING=1 (they skip otherwise), and the start screen's grid of faces
/// (#387 screen 1); before that grid they skip.
final class WatchBatteryUITests: WatchUITestCase {
    /// Two looks at the working bot's face a second apart: whether they differ.
    private func faceMoves(dimmed: Bool) throws -> Bool {
        guard ProcessInfo.processInfo.environment["HERMES_E2E_WORKING"] == "1" else {
            throw XCTSkip("needs the mock's MOCK_WORKING and HERMES_E2E_WORKING=1")
        }
        try launch(arguments: dimmed ? ["-vory-test-dimmed", "YES"] : [])
        XCTAssertTrue(any("watch.home").waitForExistence(timeout: 40) || button("Settings").waitForExistence(timeout: 5), "no start screen")
        guard any("watch.home").exists else { throw XCTSkip("needs the start screen's grid of faces (#387 screen 1)") }
        let bot = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'watch.bot.' AND label CONTAINS[c] 'working'")).firstMatch
        XCTAssertTrue(bot.waitForExistence(timeout: 30), "no working bot (is MOCK_WORKING set?)")
        sleep(2)
        let frame = bot.frame
        let first = XCUIScreen.main.screenshot(), second: XCUIScreenshot
        Thread.sleep(forTimeInterval: 1.0)
        second = XCUIScreen.main.screenshot()
        shot(dimmed ? "battery-dimmed" : "battery-lit")
        mark("face \(bot.identifier) at \(frame), dimmed \(dimmed)")
        return crop(first, frame) != crop(second, frame)
    }

    /// The pixels inside `frame` (points), from a screenshot.
    private func crop(_ s: XCUIScreenshot, _ frame: CGRect) -> Data? {
        guard let cg = s.image.cgImage else { return nil }
        let scale = CGFloat(cg.width) / max(1, s.image.size.width)
        let r = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale).integral
        guard let part = cg.cropping(to: r), let data = part.dataProvider?.data else { return nil }
        return data as Data
    }

    // The skip has to leave the test itself: thrown inside an assertion it counts as a failure.
    func testAWorkingFaceHoldsStillWithTheWristDown() throws {
        let moves = try faceMoves(dimmed: true)
        XCTAssertFalse(moves, "the working bot's face moves with the wrist down")
    }

    func testAWorkingFaceMovesWhenLit() throws {
        let moves = try faceMoves(dimmed: false)
        XCTAssertTrue(moves, "the working bot's face does not move while lit (the comparison sees no motion)")
    }
}
