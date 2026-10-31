import XCTest

/// #371's measurements (1.4 (10) "crashes" with no crash log: in the background during or after
/// a long turn, and in a chat). These drive the app; the host samples its memory and CPU
/// (scratchpad sample.sh) and reads the simulator's log for how it ended, lined up by the
/// `C371` lines' wall-clock times.
///
/// The app writes its footprint and CPU every 5 s to Caches/perf-resources.log
/// (`-vory-perf-resources`), which a phone run copies back.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy. HERMES_E2E_STEPS: the marathon's steps (400);
/// HERMES_E2E_AWAY: seconds in the background (330).
@MainActor
final class Crash371UITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func setting(_ key: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[key].flatMap(Int.init) ?? fallback
    }

    private func mark(_ what: String) {
        print(String(format: "C371 %.1f %@", Date().timeIntervalSince1970, what))
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
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-vory-perf-resources", "YES"]
            app.launch()
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-companionPromptShown", "YES", "-vory-perf-resources", "YES"]
            app.launch()
            connectIfNeeded(url: url, token: token)
        }
    }

    private func connectIfNeeded(url: String, token: String) {
        let start = app.buttons["onboarding.getStarted"].firstMatch
        let skip = app.buttons["onboarding.skip"].firstMatch
        let add = app.buttons["onboarding.addGateway"].firstMatch
        guard start.waitForExistence(timeout: 40) || skip.exists || add.exists else { return }
        if start.exists { start.tap() }
        if skip.waitForExistence(timeout: 10) { skip.tap() }
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let name = app.textFields["gateway.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("Workshop")
        let urlField = app.textFields["gateway.url"].firstMatch
        urlField.tap(); urlField.typeText(url)
        // The token field is further down the form: a lazy list has no element for it until it scrolls in.
        let tokenField = app.secureTextFields["gateway.sessionToken"].firstMatch
        for _ in 0..<8 where !(tokenField.exists && tokenField.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(tokenField.waitForExistence(timeout: 5), "no session token field")
        tokenField.tap(); tokenField.typeText(token)
        if app.keyboards.buttons["Return"].firstMatch.exists { app.keyboards.buttons["Return"].firstMatch.tap() }
        let test = app.buttons["gateway.test"].firstMatch
        for _ in 0..<6 where !(test.exists && test.isHittable) { app.swipeUp(velocity: .slow) }
        test.tap()
        let wsResult = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'gateway.ready received'")).firstMatch
        let deadline = Date().addingTimeInterval(60)
        while !wsResult.exists, Date() < deadline { app.swipeUp(velocity: .slow); _ = wsResult.waitForExistence(timeout: 2) }
        XCTAssertTrue(wsResult.exists, "WebSocket leg did not pass")
        app.buttons["gateway.save"].firstMatch.tap()
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

    private func stateName(_ s: XCUIApplication.State) -> String {
        switch s {
        case .notRunning: "notRunning"
        case .runningBackgroundSuspended: "suspended"
        case .runningBackground: "background"
        case .runningForeground: "foreground"
        default: "unknown"
        }
    }

    /// Sends a prompt in a new chat and waits for `started` to show.
    private func send(_ prompt: String, started: String, timeout: TimeInterval = 30) {
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        // By its place on screen: XCTest's own scroll-into-view of this button fails now and then.
        newChat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        for _ in 0..<3 {
            composer.typeText(prompt)
            let typed = composer.value as? String ?? ""
            if typed == prompt { break }
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count + 2))
        }
        XCTAssertEqual(composer.value as? String, prompt, "the prompt was not typed as written")
        for _ in 0..<3 {
            guard let button = hittable(app.buttons.matching(identifier: "composer.send"), timeout: 5),
                  (composer.value as? String)?.isEmpty == false else { break }
            button.tap()
            if text(started).firstMatch.waitForExistence(timeout: timeout) { break }
        }
        XCTAssertTrue(text(started).firstMatch.exists, "\(prompt) did not start")
    }

    /// A long tool-heavy turn left running: home, then the app's state each second for the time
    /// away (the host samples memory). Then back: still in the chat, or started over.
    func testBackgroundDuringALongTurn() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        let steps = setting("HERMES_E2E_STEPS", 400)
        let away = setting("HERMES_E2E_AWAY", 330)
        launch(url: url, token: token)
        send("marathon \(steps)", started: " of \(steps): checking shard")
        mark("turn-started steps=\(steps)")
        sleep(8)
        mark("away")
        XCUIDevice.shared.press(.home)
        let left = Date()
        var last = ""
        var marks = [30, 120, 300]
        while Date().timeIntervalSince(left) < Double(away) {
            let t = Int(Date().timeIntervalSince(left))
            let s = stateName(app.state)
            if s != last { mark("state \(s) at \(t) s"); last = s }
            if let m = marks.first, t >= m { mark("at \(m) s: \(s)"); marks.removeFirst() }
            sleep(1)
        }
        mark("return")
        app.activate()
        let inChat = hittable(app.textViews.matching(identifier: "composer.text"), timeout: 20) != nil
        mark(inChat ? "back in the chat" : "back NOT in the chat (started over?)")
        shot("c371-back")
    }

    /// The cold launch after the app was ended in the background (the host kills it while the
    /// test waits): what does it come back to?
    func testColdLaunchAfterABackgroundKill() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "no chat rows")
        sleep(1)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chat.dock").firstMatch.waitForExistence(timeout: 20), "the chat did not open")
        sleep(3)
        app.swipeDown(velocity: .fast); sleep(1); app.swipeDown(velocity: .fast); sleep(2)
        shot("c371-before-kill")
        mark("away")
        XCUIDevice.shared.press(.home)
        sleep(5)
        mark("KILL-NOW")
        let deadline = Date().addingTimeInterval(120)
        while app.state != .notRunning, Date() < deadline { sleep(1) }
        mark("killed: \(app.state == .notRunning)")
        sleep(2)
        app.activate()
        sleep(8)
        let inChat = app.descendants(matching: .any).matching(identifier: "chat.dock").firstMatch.exists
        mark(inChat ? "cold launch shows the chat" : "cold launch shows the chat list")
        shot("c371-after-cold-launch")
    }

    /// Candidate 3: one text too big to draw. Opens and closes a huge reasoning, scrolls a huge
    /// code block and a huge tool output's Show more. HERMES_E2E_HUGE: "reasoning 100",
    /// "code 2000" or "tool 60000".
    func testHugeTextOpenCloseScroll() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        let what = ProcessInfo.processInfo.environment["HERMES_E2E_HUGE"] ?? "reasoning 100"
        launch(url: url, token: token)
        send("huge \(what)", started: "every shard is checked", timeout: 60)
        mark("huge \(what) arrived")
        sleep(3)
        shot("c371-huge-arrived")
        if what.hasPrefix("reasoning") {
            for round in 1...3 {
                guard let open = hittable(app.buttons.matching(NSPredicate(format: "label == 'Show reasoning'")), timeout: 10) else { XCTFail("no Show reasoning"); return }
                mark("open reasoning \(round)"); open.tap(); sleep(4)
                shot("c371-reasoning-open-\(round)")
                XCTAssertEqual(app.state, .runningForeground, "the app ended after opening the reasoning")
                // The card's top (its Hide button) is far up the thread once it is open: scroll to it.
                let hide = app.buttons.matching(NSPredicate(format: "label == 'Hide reasoning'"))
                var swipes = 0
                while hittable(hide, timeout: 0.5) == nil, swipes < 60 { app.swipeDown(velocity: .fast); swipes += 1 }
                mark("scrolled \(swipes) swipes to the card's top")
                shot("c371-reasoning-top-\(round)")
                guard let close = hittable(hide, timeout: 10) else { XCTFail("no Hide reasoning"); return }
                mark("close reasoning \(round)"); close.tap(); sleep(4)
                XCTAssertEqual(app.state, .runningForeground, "the app ended after closing the reasoning")
            }
        } else {
            if what.hasPrefix("tool") {
                if let card = hittable(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'terminal' OR label CONTAINS[c] 'export.log'")), timeout: 10) {
                    mark("open tool card"); card.tap(); sleep(3)
                }
                if let more = hittable(app.buttons.matching(NSPredicate(format: "label == 'Show more'")), timeout: 10) {
                    mark("show more"); more.tap(); sleep(4)
                }
            }
            for k in 1...6 {
                mark("scroll \(k)"); app.swipeDown(velocity: .fast); sleep(1)
            }
            for k in 1...6 {
                mark("scroll back \(k)"); app.swipeUp(velocity: .fast); sleep(1)
            }
            shot("c371-huge-scrolled")
            XCTAssertEqual(app.state, .runningForeground, "the app ended while scrolling the huge text")
        }
        mark("done")
    }

    // MARK: #164: does a chat brought back through the resume path replay its rows?

    /// The highest "Step N of <of>" on screen (its frame inside the window), or 0, and whether the turn's last words
    /// are on screen. By frame, not hittability: XCTest fails the test when it cannot settle hittability on a thread
    /// that is still taking rows. From one copy of the tree: read element by element (each one's existence, then its
    /// frame), every lookup made the app build its whole accessibility tree, about 250 ms over a long chat, the very
    /// stalls the restore drive measures (found on 28).
    private func onScreen(of total: Int) -> (top: Int, endShown: Bool) {
        guard let snap = try? app.snapshot() else { return (0, false) }
        let window = snap.frame
        var top = 0, endShown = false
        func walk(_ s: XCUIElementSnapshot) {
            if s.elementType == .staticText, window.intersects(s.frame) {
                if s.label.contains(" of \(total): checking shard"), let m = s.label.firstMatch(of: /Step (\d+) of/), let n = Int(m.output.1) { top = max(top, n) }
                if s.label.contains("Everything else looked healthy") { endShown = true }
            }
            for c in s.children { walk(c) }
        }
        walk(snap)
        return (top, endShown)
    }

    /// What the thread shows in the first seconds after a chat opens: the top step on screen and
    /// whether the turn's last words are, at 0.3, 1, 2 and 4 s, with a picture each time.
    private func watchOpening(_ name: String, total: Int) {
        let opened = Date()
        for at in [0.3, 1.0, 2.0, 4.0] {
            let wait = at - Date().timeIntervalSince(opened)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            let seen = onScreen(of: total)
            mark("\(name) +\(at) s: top step \(seen.top), end shown \(seen.endShown)")
            shot("c164-\(name)-\(at)")
        }
    }

    private func backToList() {
        let back = app.buttons.matching(identifier: "chat.back").firstMatch
        if back.waitForExistence(timeout: 10) { back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(app.buttons["chats.new"].firstMatch.waitForExistence(timeout: 15), "not back on the list")
        sleep(1)
    }

    private func openRow(_ fragment: String) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no \(fragment) row")
        sleep(1)
        row.tap()
        mark("opened \(fragment)")
    }

    /// A chat the gateway lists across launches (a new chat's row is only the app's own until the
    /// gateway files it), with `marathon <total>` sent in it.
    private let listed = "Rewrite the nightly export"

    private func marathonInListedChat(_ total: Int) {
        toList()
        openRow(listed)
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "no composer in \(listed)")
        composer.tap()
        composer.typeText("marathon \(total)")
        if let button = hittable(app.buttons.matching(identifier: "composer.send"), timeout: 5) { button.tap() }
        XCTAssertTrue(text(" of \(total): checking shard").firstMatch.waitForExistence(timeout: 30), "the long turn did not start")
    }

    /// On the list (a chat a test left may have been reopened).
    private func toList() {
        if app.descendants(matching: .any).matching(identifier: "chat.dock").firstMatch.waitForExistence(timeout: 4) { backToList() }
        XCTAssertTrue(app.buttons["chats.new"].firstMatch.waitForExistence(timeout: 20), "not on the list")
    }

    /// Ended in the background as the system ends it: the host's SIGKILL on KILL-NOW (run with KILL=1).
    private func endedByTheSystem() {
        XCUIDevice.shared.press(.home); sleep(3)
        mark("KILL-NOW")
        sleep(8)
        // The same app and arguments again (no sign-in step: the gateway is saved).
        app.launch()
    }

    /// 1. A chat opened mid-turn after the app was ended (closed first, so nothing reopens it).
    func testResume1OpenedMidTurnAfterTheAppWasEnded() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        let total = setting("HERMES_E2E_STEPS", 400)
        launch(url: url, token: token)
        marathonInListedChat(total)
        sleep(12)
        backToList()
        endedByTheSystem()
        toList()
        openRow(listed)
        watchOpening("mid-turn", total: total)
    }

    /// 2. A chat opened after its turn finished while another chat was in front.
    func testResume2OpenedAfterItsTurnFinishedInAnotherChat() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        let total = setting("HERMES_E2E_STEPS", 150)
        launch(url: url, token: token)
        marathonInListedChat(total)
        sleep(3)
        backToList()
        openRow("Bot Chat")
        sleep(UInt32(setting("HERMES_E2E_AWAY", 75)))
        backToList()
        openRow(listed)
        watchOpening("finished-elsewhere", total: total)
    }

    /// 3. A cold launch that reopens the chat (restore), its turn still running.
    func testResume3ColdLaunchReopensTheChatMidTurn() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        let total = setting("HERMES_E2E_STEPS", 400)
        launch(url: url, token: token)
        marathonInListedChat(total)
        sleep(12)
        endedByTheSystem()
        mark("relaunched")
        watchOpening("restored", total: total)
    }
}
