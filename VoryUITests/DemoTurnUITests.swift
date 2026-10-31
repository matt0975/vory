import XCTest

/// A turn in the demo (#392), with no gateway at all: the app started on the built-in demo (`-vory-demo`, DEBUG), a chat
/// opened, a message that asks for a cleanup, the approval card answered, the reply finished; then a second message
/// answered without one (the demo asks once).
final class DemoTurnUITests: XCTestCase {
    private var app: XCUIApplication!

    private func text(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
    }

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.last(where: { $0.exists && $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    private func send(_ words: String) {
        guard let composer = hittable(app.textViews.matching(identifier: "composer.text"), timeout: 20) else {
            return XCTFail("no composer for \"\(words)\"")
        }
        composer.tap()
        composer.typeText(words)
        guard let send = hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10) else {
            return XCTFail("no send button")
        }
        send.tap()
    }

    /// The card's first choice.
    private static var allowOnce: NSPredicate { NSPredicate(format: "label == 'Allow once'") }

    func testADemoTurnStreamsAsksOnceAndFinishes() throws {
        app = XCUIApplication()
        app.launchArguments = ["-vory-demo", "-companionPromptShown", "YES"]
        app.launch()

        let chat = text("Packing list for the lake weekend").firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 30), "the demo's chats did not load")
        chat.tap()

        // Onboarding's ready-made message (beat 3, Option A), and its approval (beat 4).
        send("What's taking up the most space on my server?")
        guard let once = hittable(app.buttons.matching(Self.allowOnce), timeout: 30) else {
            return XCTFail("no approval card")
        }
        XCTAssertTrue(text("find ./logs -mtime +30 -delete").firstMatch.exists, "the card does not show the command")
        once.tap()
        XCTAssertTrue(text("I cleared 3.1 GB").firstMatch.waitForExistence(timeout: 30), "the approved reply did not finish")

        send("Thanks, what else is there to do?")
        XCTAssertTrue(text("Want me to set a reminder").firstMatch.waitForExistence(timeout: 30), "the second reply did not come")
        XCTAssertNil(hittable(app.buttons.matching(Self.allowOnce), timeout: 1), "the demo asked again")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "demo-turn"; shot.lifetime = .keepAlways; add(shot)
    }
}
