import XCTest

/// CPU with six bots on screen and one working, the motion engine on
/// and off, as XCTest's CPU metric over ten seconds each: the numbers for review and the
/// Mac's comparison. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
final class BotMotionPerfUITests: XCTestCase {
    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func launch(url: String, token: String, engine: Bool) -> XCUIApplication {
        let app: XCUIApplication
        let args = ["-companionPromptShown", "YES", "-launchTab", "bots", "-vory-motion-bench", "-vory-motion-engine", engine ? "YES" : "NO", "-colorSchemePreference", "light"]
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
        return app
    }

    private func measureScene(engine: Bool, url: String, token: String) {
        let app = launch(url: url, token: token, engine: engine)
        XCTAssertTrue(app.staticTexts["working · blob"].firstMatch.waitForExistence(timeout: 40), "the bench scene is not up")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTCPUMetric(application: app)], options: options) {
            RunLoop.current.run(until: Date().addingTimeInterval(10))
        }
        app.terminate()
    }

    func testCPUWithTheEngineOn() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        measureScene(engine: true, url: url, token: token)
    }

    func testCPUWithTheEngineOff() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        measureScene(engine: false, url: url, token: token)
    }
}
