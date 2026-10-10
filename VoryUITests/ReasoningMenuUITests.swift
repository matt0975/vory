import XCTest

/// Reasoning effort is its own item in the chat's … menu, next to Model (#301): it says the
/// level and opens a short list of levels; the model list no longer nests it.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
@MainActor
final class ReasoningMenuUITests: XCTestCase {
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

    private func labelled(_ fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
    }

    func testReasoningIsItsOwnItemWithALevelList() throws {
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
        // A moment for the chat's info (its level) to arrive.
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        app.buttons["chat.more"].firstMatch.tap()
        let item = labelled("Reasoning: ")
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no Reasoning item in the chat's menu")
        XCTAssertTrue(item.label.contains("medium"), "the item does not say the chat's level: \(item.label)")
        shot("reasoning-menu-item")
        item.tap()
        // The short list: the standard three and the gateway's extras.
        for level in ["minimal", "low", "medium", "high", "xhigh", "max"] {
            XCTAssertTrue(app.buttons[level].firstMatch.waitForExistence(timeout: 5), "no \(level) in the list")
        }
        // By strength: minimal above low, max last.
        XCTAssertLessThan(app.buttons["minimal"].firstMatch.frame.minY, app.buttons["low"].firstMatch.frame.minY)
        XCTAssertLessThan(app.buttons["xhigh"].firstMatch.frame.minY, app.buttons["max"].firstMatch.frame.minY)
        shot("reasoning-menu-levels")
        app.buttons["high"].firstMatch.tap()
        // The model list no longer nests it.
        app.buttons["chat.more"].firstMatch.tap()
        let model = labelled("Model: ")
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.tap()
        XCTAssertFalse(app.buttons["Reasoning effort"].firstMatch.waitForExistence(timeout: 2), "the model list still nests Reasoning effort")
    }
}
