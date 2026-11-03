import XCTest

/// The thread stays where the reader put it. A tester on 1.4 (8): "you often have to fight
/// against Vory to scroll", the thread pulled back to the end while a reply streamed, again
/// once it had finished, and again when scrolling back to earlier messages (#277).
///
/// Three checks on one long reply from the mock: scrolled up while it streams, the words on
/// screen stay put until it ends; after it ends, scrolled up again, they stay put; the jump
/// arrow shows while away from the end and brings the thread back. Run twice: with the keyboard
/// up, as typing the prompt leaves it, and with it closed first.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
@MainActor
final class ChatScrollUITests: XCTestCase {
    private var app: XCUIApplication!
    /// Added to the stills' names in the second case, so its stills don't replace the first's.
    private var shotTag = ""

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func shot(_ name: String) {
        let name = name + shotTag
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

    /// The keyboard on screen (XCTest goes on listing it below the screen once it has gone).
    private var keyboardUp: Bool {
        let k = app.keyboards.firstMatch
        return k.exists && k.frame.minY < app.frame.height - 20
    }

    /// The keyboard down, as ChatFollowUITests does it: a drag from just above the dock to the bottom of the screen pulls
    /// it away interactively (a swipe in the thread's middle only scrolled).
    private func keyboardDown() {
        guard keyboardUp else { return }
        let dock = app.otherElements["chat.dock"].firstMatch
        let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: dock.frame.minY - 12))
        let to = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: app.frame.height - 4))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    /// A row of the reply that is on screen, and where it is: the mark the checks hold the
    /// thread to.
    private func mark() -> (label: String, y: CGFloat)? {
        // One snapshot of the whole app, walked here: asking the tree per element costs a second
        // or more each with the hundreds of rows a long turn leaves.
        guard let snap = try? app.snapshot() else { return nil }
        let window = app.windows.firstMatch.frame
        var candidates: [(label: String, y: CGFloat)] = []
        // Every text in the thread, counted: the row held must be found again by its words, so a
        // line the report repeats ("Action: rotate the log and watch it", in most shards) cannot
        // be it. Picked, it was found again a hundred rows up, and read as the thread having moved
        // 11,165 pt.
        var seen: [String: Int] = [:]
        func count(_ s: XCUIElementSnapshot) {
            if s.elementType == .staticText { seen[s.label.lowercased(), default: 0] += 1 }
            for c in s.children { count(c) }
        }
        count(snap)
        func unique(_ label: String) -> Bool {
            let l = label.lowercased()
            return seen.filter { $0.key.contains(l) }.values.reduce(0, +) == 1
        }
        func walk(_ s: XCUIElementSnapshot) {
            if s.elementType == .staticText, unique(s.label) {
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

    /// The bottom edge of the lowest row of the thread (a card, the typing bubble, the status
    /// line): every row is an element named "thread.…".
    private func lowestRowBottom() -> CGFloat? {
        guard let snap = try? app.snapshot() else { return nil }
        var bottom: CGFloat?
        func walk(_ s: XCUIElementSnapshot) {
            if s.identifier.hasPrefix("thread."), s.frame.height > 0 { bottom = max(bottom ?? -.infinity, s.frame.maxY); return }
            for c in s.children { walk(c) }
        }
        walk(snap)
        return bottom
    }

    /// Back at the end, the last row ends clear of the bar (an 8 pt margin): nothing is hidden
    /// at rest, only while scrolling does text pass behind the field's glass.
    private func assertEndClearsTheDock(_ label: String) throws {
        let dock = app.otherElements["chat.dock"].firstMatch
        XCTAssertTrue(dock.exists, "\(label): no dock")
        let bottom = try XCTUnwrap(lowestRowBottom(), "\(label): no rows")
        let gap = dock.frame.minY - bottom
        if gap < 6 { shot("scroll-end-under-dock-\(label)") }
        XCTAssertGreaterThanOrEqual(gap, 6, "\(label): the last row ends \(Int(gap)) pt above the dock: under the bar")
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

    /// With the keyboard up, as typing the prompt leaves it: a reader's usual case, and where the arrow lost its tap to
    /// the row under it (#614).
    func testTheThreadStaysWhereItWasPutWhileAReplyStreamsAndAfter() throws { try threadStaysWhereItWasPut(closeFirst: false) }

    /// The same with the keyboard closed first.
    func testTheThreadStaysWhereItWasPutWithTheKeyboardDown() throws { try threadStaysWhereItWasPut(closeFirst: true) }

    private func threadStaysWhereItWasPut(closeFirst: Bool) throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        shotTag = closeFirst ? "-keyboard-down" : ""
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

        // 1. Up the thread while it streams: the words on screen stay put until the end. The
        // keyboard is still up from typing the prompt; the second case closes it first.
        if closeFirst {
            keyboardDown()
            XCTAssertFalse(keyboardUp, "the keyboard did not go down")
        }
        print("CHAT-SCROLL the keyboard \(keyboardUp ? "up" : "down") while scrolling up")
        // Three slow swipes up, for the distance: the first was meant to close the keyboard and only ever scrolled, and
        // with two the thread could stay near enough to its end to keep following the reply.
        app.swipeDown(velocity: .slow); RunLoop.current.run(until: Date().addingTimeInterval(0.6))
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

        // Back to the end by the arrow. The keyboard can still be up here, and the arrow then stands over a row: the
        // arrow must take the tap itself.
        let keyboardAtTap = keyboardUp
        let arrow = try XCTUnwrap(hittable(app.buttons.matching(NSPredicate(format: "label == 'Jump to latest'")), timeout: 5))
        print("CHAT-SCROLL arrow at \(arrow.frame), the keyboard \(keyboardAtTap ? "up" : "down")")
        arrow.tap()
        XCTAssertTrue(end.firstMatch.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("scroll-back-at-end")
        // The end's words existing doesn't put the thread at its end (the lazy stack keeps rows it has laid out); the
        // arrow going does.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: arrow)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 3), .completed,
                       "the arrow didn't bring the thread to its end (the keyboard \(keyboardAtTap ? "up" : "down") at the tap): it still shows")
        try assertEndClearsTheDock("after-arrow")

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

    /// A reader who leaves a chat partway up finds it there again when they open it next (#329:
    /// the place is kept per chat, `ChatViewMemory`), not pulled to the end. The open's own landing
    /// must not take it away (1.5 (24): the open lands a past-the-end at once while locked).
    func testAReaderReopensAChatAtTheirPlace() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        launch(url: url, token: token)
        // The list's row, not the chat's title pill, which carries the same words.
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup' AND identifier != 'chat.titlePill'"))
        let row = try XCTUnwrap(hittable(rows, timeout: 40), "no Disk cleanup row")
        row.tap()

        // A long reply, then up the thread a little and out of the chat.
        sendMarathon(20)
        XCTAssertTrue(text("Everything else looked healthy").firstMatch.waitForExistence(timeout: 90), "the turn did not finish")
        if app.keyboards.firstMatch.exists { app.swipeDown(velocity: .slow); RunLoop.current.run(until: Date().addingTimeInterval(0.6)) }
        app.swipeDown(velocity: .slow)
        app.swipeDown(velocity: .slow)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let place = try XCTUnwrap(mark(), "no row on screen up the thread")
        shot("place-before-leaving")
        let back = app.descendants(matching: .any).matching(identifier: "chat.back").firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no Back")
        back.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        // Open again: the same row, where it was, and the arrow, since the thread is away from its end.
        let again = try XCTUnwrap(hittable(rows, timeout: 10), "the list did not come back")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        again.tap()
        XCTAssertTrue(app.otherElements["chat.dock"].firstMatch.waitForExistence(timeout: 20), "the chat did not open again")
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        shot("place-after-reopening")
        let held = text(place.label).firstMatch
        XCTAssertTrue(held.exists, "the row the reader left (\(place.label.prefix(30))) is not on screen: the place was lost")
        print("CHAT-SCROLL place before \(Int(place.y)) after \(Int(held.frame.minY))")
        // #373, kept here as a check: on 1.5 (23) and (24) the reopened chat lands about
        // 750 pt from the reader's place. The place is remembered (#329); the open's landing moves
        // it. When it is fixed this expectation fails ("expected failure did not occur"): remove it.
        continueAfterFailure = true
        XCTExpectFailure("#373: the reopened chat lands about 750 pt from where the reader left it (1.5 (23), (24))") {
            XCTAssertEqual(held.frame.minY, place.y, accuracy: 40, "the reopened chat is \(Int(held.frame.minY - place.y)) pt from where the reader left it")
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Jump to latest'")).firstMatch.exists, "no jump arrow: the reopened chat is at its end")
        }
    }
}
