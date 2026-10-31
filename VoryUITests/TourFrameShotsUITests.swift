import XCTest

/// The pictures onboarding's beat 5 shows of the app on the other devices (#388): the app on the demo, with Sprout's
/// "Packing list for the lake weekend" open, in light and in dark. Run on an iPad for `TourPad` and on an iPhone for
/// `TourPhone` (what an iPad's tour shows beside the Mac). `Tools/dev/tour-frames.sh` runs it on both, then sizes the
/// pictures into the asset catalog. The demo only (`-vory-demo`, DEBUG): no gateway, so no real name can get in.
/// Skipped unless TOUR_FRAMES_OUT names the folder for the pictures.
final class TourFrameShotsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    func testTheAppOnTheDemoInLightAndDark() throws {
        guard let out = ProcessInfo.processInfo.environment["TOUR_FRAMES_OUT"], !out.isEmpty else {
            throw XCTSkip("TOUR_FRAMES_OUT not set")
        }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for scheme in ["light", "dark"] {
            app = XCUIApplication()
            app.launchArguments = ["-vory-demo", "-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", scheme]
            app.launch()
            let name = app.windows.firstMatch.frame.width > 700 ? "TourPad" : "TourPhone"
            let chat = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Packing list for the lake weekend")).firstMatch
            XCTAssertTrue(chat.waitForExistence(timeout: 30), "the demo's chats did not load")
            chat.tap()
            XCTAssertTrue(app.textViews.matching(identifier: "composer.text").firstMatch.waitForExistence(timeout: 20), "the chat did not open")
            // Settled: the thread at its end, the bot still.
            sleep(3)
            let shot = XCUIScreen.main.screenshot()
            try shot.pngRepresentation.write(to: folder.appendingPathComponent("\(name)-\(scheme).png"))
            let a = XCTAttachment(screenshot: shot); a.name = "\(name)-\(scheme)"; a.lifetime = .keepAlways; add(a)
            app.terminate()
        }
    }
}
