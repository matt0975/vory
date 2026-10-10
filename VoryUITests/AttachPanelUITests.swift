import XCTest

/// The + panel (#285): opens from the button, closes back into it, and the first open is not
/// slower than the ones after. Frames are shot a few times as it grows for a look at the
/// morph; the app writes "attach panel laid out N ms after the tap" to the perf log (DEBUG),
/// read after the run with
///   xcrun simctl spawn <udid> log show --last 5m --predicate 'subsystem == "Vory" AND category == "perf"'
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
@MainActor
final class AttachPanelUITests: XCTestCase {
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

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    /// Taps +, shoots the growth, and reports how long the Files row took to exist.
    private func open(_ tag: String) throws -> TimeInterval {
        let plus = try XCTUnwrap(hittable(app.buttons.matching(NSPredicate(format: "label == 'Attach'")), timeout: 15), "no + button")
        let tapped = Date()
        plus.tap()
        for i in 1...3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.06))
            shot("attach-\(tag)-grow-\(i)")
        }
        let files = app.buttons["attach.files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10), "the panel did not open (\(tag))")
        let took = Date().timeIntervalSince(tapped)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        shot("attach-\(tag)-open")
        print(String(format: "ATTACH-OPEN %@ %.0f ms", tag, took * 1000))
        return took
    }

    private func close(_ tag: String) throws {
        let close = try XCTUnwrap(hittable(app.buttons.matching(NSPredicate(format: "label == 'Close attach panel'")), timeout: 5))
        close.tap()
        for i in 1...2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            shot("attach-\(tag)-fold-\(i)")
        }
        XCTAssertFalse(app.buttons["attach.files"].firstMatch.waitForExistence(timeout: 2), "the panel did not close (\(tag))")
    }

    func testThePanelOpensFromThePlusAndFoldsBack() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES"]
        } else {
            app = XCUIApplication()
        }
        app.launch()
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        XCTAssertTrue(app.textViews["composer.text"].firstMatch.waitForExistence(timeout: 30))
        // A moment for the chat to settle (the camera question is warmed a second after it opens).
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        let first = try open("first")
        try close("first")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let second = try open("second")
        try close("second")
        // The first open may not be far slower than the second (XCUITest's own asking is in both).
        XCTAssertLessThan(first, second + 0.5, "the first open took \(Int(first * 1000)) ms, the second \(Int(second * 1000)) ms")
    }
}
