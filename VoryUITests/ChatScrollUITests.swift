import XCTest

/// The thread stays where the reader put it. A tester on 1.4 (8): "you often have to fight
/// against Vory to scroll", the thread pulled back to the end while a reply streamed, again
/// once it had finished, and again when scrolling back to earlier messages (#277).
///
/// Three checks on one long reply from the mock: scrolled up while it streams, the words on
/// screen stay put until it ends; after it ends, scrolled up again, they stay put; the jump
/// arrow shows while away from the end and brings the thread back.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
@MainActor
final class ChatScrollUITests: XCTestCase {
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
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES"]
        } else {
            app = XCUIApplication()
        }
        app.launch()
    }

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

    /// A row of the reply that is on screen, and where it is: the mark the checks hold the
    /// thread to.
    private func mark() -> (label: String, y: CGFloat)? {
        // One snapshot of the whole app, walked here: asking the tree per element costs a second
        // or more each with the hundreds of rows a long turn leaves.
        guard let snap = try? app.snapshot() else { return nil }
        let window = app.windows.firstMatch.frame
        var candidates: [(label: String, y: CGFloat)] = []
        func walk(_ s: XCUIElementSnapshot) {
            if s.elementType == .staticText {
                let f = s.frame
                // A row's own words, not a status that comes and goes ("Running terminal…").
                if s.label.count >= 12, !s.label.contains("…"), f.minY > window.minY + 120, f.maxY < window.maxY - 160 {
                    candidates.append((s.label, f.minY))
                }
            }
            for c in s.children { walk(c) }
        }
        walk(snap)
        return candidates.first { $0.label.hasPrefix("Step ") || $0.label.hasPrefix("grep ") } ?? candidates.first
    }

    private func sendMarathon(_ steps: Int) {
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        let prompt = "marathon \(steps)"
        for _ in 0..<3 {
            composer.typeText(prompt)
            let typed = composer.value as? String ?? ""
            if typed == prompt { break }
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count + 2))
        }
        XCTAssertEqual(composer.value as? String, prompt, "the prompt was not typed as written")
        for _ in 0..<3 {
            guard let send = hittable(app.buttons.matching(identifier: "composer.send"), timeout: 5),
                  (composer.value as? String)?.contains("marathon") == true else { break }
            send.tap()
            if text(" of \(steps): checking shard").firstMatch.waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(text(" of \(steps): checking shard").firstMatch.exists, "the turn did not start")
    }

    func testTheThreadStaysWhereItWasPutWhileAReplyStreamsAndAfter() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        launch(url: url, token: token)
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()

        // A few steps, then the long report streams for several seconds.
        sendMarathon(120)
        XCTAssertTrue(text("Shard 001").firstMatch.waitForExistence(timeout: 60), "the report did not start streaming")
        let end = text("Everything else looked healthy")
        XCTAssertFalse(end.firstMatch.exists, "the report had already finished: too short to scroll during")

        // 1. Up the thread while it streams: the words on screen stay put until the end.
        app.swipeDown(velocity: .slow)
        app.swipeDown(velocity: .slow)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        shot("scroll-during-stream")
        let during = try XCTUnwrap(mark(), "no row on screen after scrolling up")
        XCTAssertTrue(end.firstMatch.waitForExistence(timeout: 90), "the report never finished")
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        shot("scroll-after-stream-ended")
        let afterEnd = text(during.label).firstMatch
        XCTAssertTrue(afterEnd.exists, "the row held while streaming (\(during.label.prefix(30))) is no longer on screen: the thread moved")
        XCTAssertEqual(afterEnd.frame.minY, during.y, accuracy: 24, "the thread moved \(Int(afterEnd.frame.minY - during.y)) pt while the reply streamed and ended")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Jump to latest'")).firstMatch.exists, "no jump arrow while away from the end")

        // Back to the end by the arrow.
        let arrow = try XCTUnwrap(hittable(app.buttons.matching(NSPredicate(format: "label == 'Jump to latest'")), timeout: 5))
        arrow.tap()
        XCTAssertTrue(end.firstMatch.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        // 2. After the reply: up the thread again, and nothing brings it back.
        app.swipeDown(velocity: .slow)
        app.swipeDown(velocity: .slow)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let after = try XCTUnwrap(mark(), "no row on screen after scrolling up")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        shot("scroll-after-reply")
        let held = text(after.label).firstMatch
        XCTAssertTrue(held.exists, "the row held after the reply (\(after.label.prefix(30))) is no longer on screen: the thread moved")
        XCTAssertEqual(held.frame.minY, after.y, accuracy: 24, "the thread moved \(Int(held.frame.minY - after.y)) pt on its own after the reply")

        // 3. Further up, to the earlier messages, and it stays there too.
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let far = try XCTUnwrap(mark(), "nothing of the thread on screen far up")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        shot("scroll-far-up")
        let farHeld = text(far.label).firstMatch
        XCTAssertTrue(farHeld.exists, "the row held far up (\(far.label.prefix(30))) is no longer on screen: the thread moved")
        XCTAssertEqual(farHeld.frame.minY, far.y, accuracy: 24, "the thread moved \(Int(farHeld.frame.minY - far.y)) pt on its own while reading earlier messages")
    }
}
