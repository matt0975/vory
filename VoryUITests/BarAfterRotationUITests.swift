import XCTest

/// The tab bar comes back after the window changes shape: landscape to portrait and back, with
/// the list in front and with a chat open. On the open iPhone Duo the turn is also the switch
/// between two columns and one (2026-10-10), after which the bar was missing once.
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
@MainActor
final class BarAfterRotationUITests: XCTestCase {
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
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "light", "-vory-geometry-probe"]
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-launchTab", "chats", "-colorSchemePreference", "light", "-vory-geometry-probe"]
        }
        app.launch()
    }

    private func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// The bar is on screen: its compose button is hittable and inside the window.
    private func checkBar(_ label: String) {
        let compose = app.buttons["chats.new"].firstMatch
        let window = app.windows.firstMatch.frame
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(compose.exists && compose.isHittable) { settle(0.3) }
        if !(compose.exists && compose.isHittable && window.contains(compose.frame)) { shot("bar-missing-\(label)") }
        XCTAssertTrue(compose.exists && compose.isHittable, "\(label): the tab bar is not on screen (compose exists \(compose.exists), hittable \(compose.isHittable), frame \(compose.frame), window \(window))")
    }

    func testTheBarComesBackAfterEachTurn() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
        launch(url: url, token: token)
        let compose = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: compose)], timeout: 60)
        settle(1)
        shot("bar-1-landscape")
        checkBar("landscape at launch")
        XCUIDevice.shared.orientation = .portrait
        settle(2.5)
        shot("bar-2-portrait")
        checkBar("portrait after the turn")
        XCUIDevice.shared.orientation = .landscapeLeft
        settle(2.5)
        shot("bar-3-landscape-again")
        checkBar("landscape again")
        // With a chat open: on a wide layout the bar stays; on a narrow one it hides in the chat and is back on the list.
        let rows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Disk cleanup'"))
        if let row = rows.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
            row.tap()
            settle(1.5)
            XCUIDevice.shared.orientation = .portrait
            settle(2.5)
            shot("bar-4-portrait-chat")
            let back = app.buttons["chat.back"].firstMatch
            if back.exists, back.isHittable, !compose.isHittable { back.tap(); settle(1.5) }
            checkBar("portrait after the chat")
            XCUIDevice.shared.orientation = .landscapeLeft
            settle(2.5)
            shot("bar-5-landscape-after-chat")
            checkBar("landscape after the chat")
            // With the keyboard up before the turn (the Duo's case: the keyboard went away with
            // the turn and the bar stayed hidden behind it).
            let composer = app.textViews["composer.text"].firstMatch
            if let row2 = rows.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }), row2.tap() == (), composer.waitForExistence(timeout: 10), composer.isHittable {
                composer.tap(); settle(1)
                if app.buttons["profile.close"].firstMatch.exists { app.buttons["profile.close"].firstMatch.tap(); settle(1) }
                XCUIDevice.shared.orientation = .portrait
                settle(2.5)
                if back.exists, back.isHittable, !compose.isHittable { back.tap(); settle(1.5) }
                shot("bar-6-portrait-after-keyboard")
                checkBar("portrait after a turn with the keyboard up")
                XCUIDevice.shared.orientation = .landscapeLeft
                settle(2.5)
                shot("bar-7-landscape-after-keyboard")
                checkBar("landscape after a turn with the keyboard up")
            }
        }
    }
}
