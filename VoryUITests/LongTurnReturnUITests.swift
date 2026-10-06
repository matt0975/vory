import XCTest

/// Coming back to a long turn that ran on while the app was away: the chat answers at once.
///
/// Testers on 1.3 left a long turn running (many tool calls, a long report), came back to the
/// app hours later and found it frozen: the + button did nothing, the arrow did not take them
/// down, and then the app was gone. This sends the mock's "marathon" turn (a step at a time,
/// each a sentence and a tool call with a screenful of output, then a long markdown report),
/// leaves the app on the Home Screen long enough to be suspended, has the mock drop the
/// suspended app's socket as iOS does after a while, and comes back: the + panel has to open
/// promptly, the arrow has to reach the end, and the report has to be there.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
/// HERMES_E2E_AWAY sets the seconds away (60 by default); HERMES_E2E_STEPS the turn's steps.
final class LongTurnReturnUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func setting(_ key: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[key].flatMap(Int.init) ?? fallback
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
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES"]
        } else {
            app = XCUIApplication()
        }
        app.launch()
    }

    /// The one on screen: every tab page is mounted, so the first match can be another copy.
    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    private func text(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
    }

    /// Asks the mock to drop every socket it holds, as iOS does to a suspended app's.
    private func dropSockets(_ base: String) {
        guard let u = URL(string: base + "/mock/drop-sockets") else { return }
        let done = expectation(description: "drop")
        URLSession.shared.dataTask(with: u) { data, _, _ in
            print("MOCK-DROP \(data.map { String(decoding: $0, as: UTF8.self) } ?? "no answer")")
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
    }

    private func report(_ name: String, _ seconds: TimeInterval) {
        let line = String(format: "RETURN-TIMING %@ %.2f s", name, seconds)
        print(line)
        let a = XCTAttachment(string: line); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testComingBackToALongTurnTheChatAnswersAtOnce() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        let steps = setting("HERMES_E2E_STEPS", 600)
        let away = setting("HERMES_E2E_AWAY", 60)
        launch(url: url, token: token)

        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        // Typed again if a key was lost (a busy simulator drops one now and then): "marathon 60"
        // is a different, much shorter turn.
        let prompt = "marathon \(steps)"
        for _ in 0..<3 {
            composer.typeText(prompt)
            let typed = composer.value as? String ?? ""
            if typed == prompt { break }
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count + 2))
        }
        XCTAssertEqual(composer.value as? String, prompt, "the prompt was not typed as written")
        // The send button on screen; tapped again if the first tap landed before the new chat
        // was ready and the words are still in the field.
        for _ in 0..<3 {
            guard let send = hittable(app.buttons.matching(identifier: "composer.send"), timeout: 5),
                  (composer.value as? String)?.contains("marathon") == true else { break }
            send.tap()
            if text(" of \(steps): checking shard").firstMatch.waitForExistence(timeout: 10) { break }
        }
        // Any step: the first ones scroll away fast.
        XCTAssertTrue(text(" of \(steps): checking shard").firstMatch.exists, "the long turn did not start")
        // No asking the screen anything while the turn runs: each question is a snapshot of the
        // whole thread taken on the app's main thread, which would be measured below as the app's own.
        sleep(4)
        shot("long-turn-before-away")

        // Away: the turn keeps going on the gateway. The app holds its connection for the half
        // minute iOS allows while a turn runs, is then suspended, and later loses the socket.
        XCUIDevice.shared.press(.home)
        sleep(UInt32(max(35, away * 2 / 3)))
        dropSockets(url)
        sleep(UInt32(max(5, away / 3)))

        let back = Date()
        app.activate()
        report("activate", Date().timeIntervalSince(back))
        // The + panel opens promptly.
        // Still in the chat: an app the system ended while it was away starts over on the chats page.
        let plus = try XCTUnwrap(hittable(app.buttons.matching(NSPredicate(format: "label == 'Attach'")), timeout: 30),
                                 "no + button after coming back: the app was ended while it was away and started over")
        plus.tap()
        let opened = app.buttons["attach.files"].firstMatch.waitForExistence(timeout: 30)
        let plusTime = Date().timeIntervalSince(back)
        report("plus-panel", plusTime)
        shot("long-turn-back-plus")
        XCTAssertTrue(opened, "the + panel did not open after coming back")
        if let close = hittable(app.buttons.matching(NSPredicate(format: "label == 'Close attach panel'")), timeout: 5) { close.tap() }

        // A while with nothing asked of the screen: what the app does with the rest of the turn
        // is its own (the perf log's "main thread busy" lines are read against this stretch).
        sleep(10)

        // The report the turn ended with is reached: by the thread itself, or by the arrow.
        let end = text("Everything else looked healthy")
        let deadline = Date().addingTimeInterval(180)
        var reached = false
        while Date() < deadline {
            if end.allElementsBoundByIndex.contains(where: { $0.isHittable }) { reached = true; break }
            if let arrow = hittable(app.buttons.matching(NSPredicate(format: "label == 'Jump to latest'")), timeout: 0.5) { arrow.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(4))
        }
        report("report-reached", Date().timeIntervalSince(back))
        shot("long-turn-back-end")
        XCTAssertTrue(reached, "the end of the long turn's report was not reached after coming back")
        XCTAssertEqual(app.state, .runningForeground, "the app is not in front after coming back")
        // Generous for a simulator under an XCTest runner; the frozen app never opened it at all.
        XCTAssertLessThan(plusTime, 12, "the + panel took \(Int(plusTime)) s to open after coming back")
    }
}
