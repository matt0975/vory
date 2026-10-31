import XCTest

/// A bot's face is tapped through what it sits in (#339): it has no gesture
/// of its own, so a tap on it does what a tap on its card or pill does, and the face reacts. On a
/// Bots card a tap on the face opens the bot; in a chat a tap on the face seated over the pill (its
/// top, its middle) opens Bot info, as the pill does. Before, the face's own tap took the touch:
/// neither opened.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=com.vorantx.vory.demo
/// drives the demo copy.
@MainActor
final class FaceTapUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func launch(url: String, token: String, tab: String) {
        let args = ["-companionPromptShown", "YES", "-launchTab", tab, "-colorSchemePreference", "light", "-chat.showBots", "YES"]
            + (ProcessInfo.processInfo.environment["HERMES_E2E_ARGS"] ?? "").split(separator: " ").map(String.init)
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
    private func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)) }

    /// Bots: a tap on a card's face opens the bot, as a tap on its name does.
    func testACardsFaceOpensTheBot() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "bots")
        // The card; the face is the 78 pt square at its top, centred.
        let card = any("bots.card.work")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no work card on Bots")
        pause(2)
        let f = card.frame
        print("FACE-TAP card \(f)")
        at(f.midX, f.minY + 39).tap(); pause(1.5); shot("card-face-tap")
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "a tap on the card's face did not open the bot")
        // Deeper and back (the bot page lands again with no new tap: nothing replays there).
        let profile = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Profile'")).firstMatch
        if profile.waitForExistence(timeout: 5) {
            print("FACE-TAP-AT profile push"); profile.tap(); pause(1.5)
            print("FACE-TAP-AT profile pop"); any("page.back").tap(); pause(2)
        }
        print("FACE-TAP-AT bot page pop"); any("page.back").tap(); pause(1.5)
        // The card's name still opens it too. (Read again: back on Bots the search field may have
        // folded away and the cards moved up.)
        let g = card.frame
        print("FACE-TAP card after Back \(g)")
        at(g.midX, g.minY + 78 + 12).tap(); pause(1.5)
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "a tap on the card's name did not open the bot")
    }

    /// A chat: a tap on the face over the pill, at its top and at its middle, opens Bot info, as
    /// the pill does.
    func testTheChatsFaceOpensBotInfo() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        for (name, dy) in [("face-top", -28.0), ("face-middle", -14.0), ("pill", 0.0)] {
            if app != nil { app.terminate() }
            launch(url: url, token: token, tab: "chats")
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 40), "no chat rows")
            pause(1.5)
            row.tap()
            XCTAssertTrue(any("chat.dock").waitForExistence(timeout: 20), "the chat did not open")
            pause(2)
            let pill = any("chat.titlePill")
            XCTAssertTrue(pill.exists, "no pill")
            let p = pill.frame
            let y = dy == 0 ? p.midY : p.minY + dy
            at(p.midX, y).tap(); pause(1.5); shot("tap-\(name)")
            print("FACE-TAP \(name) at (\(Int(p.midX)), \(Int(y))) pill \(p): Bot info \(app.buttons["Close"].exists)")
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 3), "a tap on the chat's \(name) did not open Bot info")
            // Closed again (the chat's face has nothing left to replay).
            print("FACE-TAP-AT close \(name)"); app.buttons["Close"].tap(); pause(1.5)
        }
    }
}
