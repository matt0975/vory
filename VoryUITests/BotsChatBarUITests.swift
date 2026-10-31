import XCTest

/// #378's remainder on the Bots tab (#386): with a chat left open on Chats,
/// a chat pushed on the Bots stack (one of a bot's chats, or a new one from the compose circle on
/// its page) took the bar's Chats logic. Before the guard the chat had its bar, but back on the
/// bot's page that chat's bar stayed (its face, its title, its … and a Back that went nowhere),
/// and the compose circle then opened nothing. Each chat must have a Back a finger can reach by a
/// second, the bot's page its own bar once the chat has gone, and compose a new chat. Reached
/// through the Overview widget's link (vory://home), which leaves the open chat on Chats. Skipped
/// unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set; HERMES_E2E_BUNDLE picks the copy (the demo by
/// default).
@MainActor
final class BotsChatBarUITests: XCTestCase {
    private var app: XCUIApplication!

    private func mark(_ what: String) { print(String(format: "C386 %.1f %@", Date().timeIntervalSince1970, what)) }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"].flatMap { $0.isEmpty ? nil : $0 }
        let d = folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-chat-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func reachableBack() -> XCUIElement? {
        ["chat.back", "page.back"].map { any($0) }.first { $0.exists && $0.isHittable }
    }

    /// The bar a moment after a chat comes in: by a second, a Back a finger can reach.
    private func watch(_ name: String) {
        let opened = Date()
        for at in [0.2, 0.5, 1.0, 2.0] {
            let wait = at - Date().timeIntervalSince(opened)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            let seen = ["chat.header", "morph.bar", "page.back", "chat.back", "chat.dock"].filter { any($0).exists }
            let pill = any("chat.header").buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chat info: '")).firstMatch
            mark("\(name) +\(at) s: \(seen.joined(separator: " ")) back \(reachableBack() != nil ? "reachable" : "none") [\(pill.exists ? pill.label : "")]")
            shot("c386-\(name)-\(at)")
            if at >= 1.0 { XCTAssertNotNil(reachableBack(), "\(name): no Back a finger can reach at +\(at) s") }
        }
    }

    /// Back by the bar's Back, else by the edge swipe (the only way out of a stuck bar). Back on the
    /// bot's page, the bar is the page's again: no chat's bar left over it.
    private func leave(_ name: String, backToRootKnown: Bool = false) {
        if let b = reachableBack() { b.tap(); mark("\(name): left by Back") }
        else {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
            mark("\(name): left by the edge swipe")
        }
        sleep(2)
        let page = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Disk cleanup")).firstMatch
        // On screen only: the chat left open on Chats keeps its dock in the tree behind the tab.
        let left = !app.descendants(matching: .any).matching(identifier: "chat.dock").allElementsBoundByIndex.contains { $0.isHittable } && page.exists
        let stale = any("chat.header").exists
        mark("\(name) after: \(left ? "on the bot's page" : "not on the bot's page"), \(stale ? "a chat's bar left over it" : "the page's bar")")
        if backToRootKnown {
            // Not the bar's: the compose circle's chat is pushed by `navigationDestination(isPresented:)`
            // on the bot's page, outside the Bots stack's path, and the page's Back (one view
            // controller popped) lands on the Bots root. The same before #386's guard.
            XCTExpectFailure("A chat composed on a bot's page goes back to the Bots root, not the bot's page") {
                XCTAssertTrue(left, "\(name): Back did not come back to the bot's page")
            }
        } else {
            XCTAssertTrue(left, "\(name): Back did not come back to the bot's page")
        }
        XCTAssertFalse(stale, "\(name): the chat's bar stayed over the bot's page")
    }

    func testChatsPushedOnBotsHaveTheirBack() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["chats.new"].firstMatch.waitForExistence(timeout: 40), "no chat list")

        // A chat open on Chats.
        any("tab.chats").tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "nightly export")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no nightly export chat in the list")
        row.tap()
        XCTAssertTrue(any("chat.header").waitForExistence(timeout: 10), "the first chat has no chat bar")
        sleep(2)
        // The Overview widget's link: Home, the chat left open on Chats. Then Bots, and a bot's page.
        app.open(URL(string: "vory://home")!)
        XCTAssertTrue(any("tab.bots").waitForExistence(timeout: 20), "no Bots tab on Home")
        sleep(1)
        any("tab.bots").tap()
        let card = any("bots.card.default")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no default bot card")
        card.tap()
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Disk cleanup")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 20), "no Disk cleanup chat on the bot's page")
        sleep(1)
        shot("c386-bot-page")

        // One of the bot's chats.
        mark("tap bot chat")
        chat.tap()
        watch("botpage-chat")
        leave("botpage-chat")
        shot("c386-after-chat")

        // A new chat from the compose circle on the bot's page.
        // The tab bar's circle, the one on screen (the Chats page has a compose of its own).
        var found: XCUIElement?
        for _ in 0..<20 where found == nil {
            found = app.descendants(matching: .any).matching(identifier: "chats.new").allElementsBoundByIndex.first { $0.isHittable }
            if found == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        }
        let compose = try XCTUnwrap(found, "no compose circle on the bot's page")
        mark("tap compose")
        compose.tap()
        let opened = any("chat.dock").waitForExistence(timeout: 3)
        mark("compose: \(opened ? "a chat came in" : "no chat came in")")
        XCTAssertTrue(opened, "the compose circle on the bot's page opened no chat")
        watch("botpage-compose")
        leave("botpage-compose", backToRootKnown: true)
        shot("c386-after-compose")
        mark("done")
    }
}
