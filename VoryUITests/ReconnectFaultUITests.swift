import XCTest

/// #423: stuck on "Reconnecting" behind a Cloudflare Tunnel until the app was quit. Against the mock's fault switch
/// (`/mock/fault`): Cloudflare's "origin unreachable" page and its Access sign-in are named where the connection is shown
/// (the Chats menu), a ticket that ran out is renewed without a sign-in, a gateway gone quiet is found, and each time the
/// app comes back on its own, without a quit, and works. Also: a Reconnect (which makes the REST session afresh) in the
/// middle of a turn loses neither the message nor its approval, and a long time away comes back working.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock). HERMES_E2E_BUNDLE=com.vorantx.vory.demo drives
/// the demo copy. Shots to HERMES_E2E_SHOTS.
@MainActor
final class ReconnectFaultUITests: XCTestCase {
    private var app: XCUIApplication!
    private var base = ""

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private var shotDir: URL {
        let given = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"].flatMap { $0.isEmpty ? nil : $0 }
        let d = given.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reconnect-fault", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        try? s.pngRepresentation.write(to: shotDir.appendingPathComponent("rf-\(name).png"))
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func log(_ s: String) { print(String(format: "RF %.1f %@", Date().timeIntervalSince1970, s)) }

    private func launch(url: String, token: String) {
        base = url
        let args = ["-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "light"]
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
    }

    /// The mock's fault switch (`/mock/fault?mode=…`).
    private func fault(_ mode: String, status: Int? = nil) {
        var s = base + "/mock/fault?mode=" + mode
        if let status { s += "&status=\(status)" }
        guard let u = URL(string: s) else { return }
        let done = expectation(description: "fault \(mode)")
        URLSession.shared.dataTask(with: u) { data, _, _ in
            print("MOCK-FAULT \(data.map { String(decoding: $0, as: UTF8.self) } ?? "no answer")")
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        log("fault \(mode)")
    }

    private static let known = ["Connected", "Connecting…", "Offline", "Sign in required", "Connection failed",
                                "Cloudflare can't reach the gateway", "Cloudflare wants a sign-in",
                                "A web page answered, not the gateway", "The gateway isn't answering"]

    private var lines: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@ OR label BEGINSWITH 'Reconnecting'", Self.known))
    }

    /// Closes the open menu with a tap well away from it (it opens at the top left; the status bar takes a tap at
    /// the top), and makes sure it went.
    private func closeMenu() {
        for _ in 0..<3 where lines.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8)).tap()
            pause(0.8)
        }
    }

    /// The connection as the Chats menu shows it, read with the menu open, then the menu closed.
    private func connectionLine(then tapReconnect: Bool = false) -> String {
        closeMenu()
        let profile = any("chats.profile")
        guard profile.waitForExistence(timeout: 10) else { return "no Chats menu" }
        profile.tap()
        pause(0.8)
        var seen = "nothing"
        if lines.firstMatch.waitForExistence(timeout: 3) { seen = lines.firstMatch.label }
        if tapReconnect, app.buttons["Reconnect"].exists {
            app.buttons["Reconnect"].tap()
            pause(0.6)
        } else {
            closeMenu()
        }
        return seen
    }

    /// Reads the connection line every two seconds until `want` says yes or `seconds` pass; the last line read.
    private func waitForLine(seconds: Double, shotName: String? = nil, _ want: (String) -> Bool) -> String {
        let deadline = Date().addingTimeInterval(seconds)
        var line = ""
        repeat {
            line = connectionLine()
            log("line: \(line)")
            if want(line) { if let shotName { profileShot(shotName) }; return line }
            pause(2)
        } while Date() < deadline
        return line
    }

    /// The Chats menu pictured open.
    private func profileShot(_ name: String) {
        closeMenu()
        any("chats.profile").tap(); pause(0.8); shot(name)
        closeMenu()
    }

    /// The open chat's composer, once any approval left waiting by an earlier test (the mock keeps it, and its card
    /// stands where the composer was) is denied: the tests do not depend on their order.
    private func composerClear() -> XCUIElement {
        let composer = app.textViews["composer.text"].firstMatch
        if !composer.waitForExistence(timeout: 8) {
            let deny = app.buttons.matching(NSPredicate(format: "label == 'Deny'")).firstMatch
            if deny.waitForExistence(timeout: 15) { deny.tap(); log("denied a waiting approval first") }
        } else if app.buttons["Deny"].exists {
            app.buttons["Deny"].tap(); log("denied a waiting approval first")
        }
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "no composer")
        return composer
    }

    /// A message in a chat, and its reply's approval answered: the app works.
    private func sendAndAnswer(_ words: String, in title: String) -> Bool {
        if app.buttons["chat.back"].exists { app.buttons["chat.back"].tap(); pause(1) }
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
        guard row.waitForExistence(timeout: 15) else { log("no row \(title)"); return false }
        row.tap()
        let composer = composerClear()
        guard composer.exists else { log("no composer"); return false }
        composer.tap()
        composer.typeText(words)
        let send = app.buttons.matching(identifier: "composer.send").firstMatch
        guard send.waitForExistence(timeout: 5) else { log("no send"); return false }
        send.tap()
        let once = app.buttons["Allow once"]
        guard once.waitForExistence(timeout: 40) else { log("no approval came"); return false }
        once.tap()
        pause(2)
        return true
    }

    // MARK: Cloudflare's pages, named and recovered from without a quit

    func testCloudflarePagesAreNamedAndTheAppRecoversWithoutAQuit() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        fault("none")
        launch(url: url, token: token)
        XCTAssertTrue(any("chats.new").waitForExistence(timeout: 40), "the app did not come up")
        XCTAssertEqual(waitForLine(seconds: 20) { $0 == "Connected" }, "Connected", "not connected at the start")

        fault("origin", status: 523)
        let origin = waitForLine(seconds: 30, shotName: "1-origin-523") { $0 == "Cloudflare can't reach the gateway" }
        XCTAssertEqual(origin, "Cloudflare can't reach the gateway", "Cloudflare's 523 was not named")

        fault("access")
        let access = waitForLine(seconds: 45, shotName: "2-access-sign-in") { $0 == "Cloudflare wants a sign-in" }
        XCTAssertEqual(access, "Cloudflare wants a sign-in", "Cloudflare Access's sign-in was not named")

        fault("none")
        let back = waitForLine(seconds: 50, shotName: "3-recovered") { $0 == "Connected" }
        XCTAssertEqual(back, "Connected", "the app did not come back on its own")
        XCTAssertTrue(sendAndAnswer("Back after Cloudflare", in: "Disk cleanup"), "the app did not work after coming back")
        shot("4-working-after")

        // A ticket that ran out between its minting and its use: renewed, not a sign-in. Read from the list.
        if app.buttons["chat.back"].exists { app.buttons["chat.back"].tap(); pause(1) }
        fault("ticket-expired")
        pause(2)
        let renewed = waitForLine(seconds: 20) { $0 == "Connected" || $0 == "Sign in required" }
        XCTAssertEqual(renewed, "Connected", "a ticket that ran out ended in a sign-in")
    }

    // MARK: The audit, with a problem named

    /// The Chats menu open while Cloudflare's 523 is named (the new line, its symbol and Reconnect): nothing in the menu
    /// is flagged by the accessibility audit.
    func testTheMenuWithAProblemNamedPassesTheAudit() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        fault("none")
        launch(url: url, token: token)
        XCTAssertTrue(any("chats.new").waitForExistence(timeout: 40))
        fault("origin", status: 523)
        XCTAssertEqual(waitForLine(seconds: 30) { $0 == "Cloudflare can't reach the gateway" }, "Cloudflare can't reach the gateway")
        closeMenu()
        any("chats.profile").tap(); pause(0.8)
        let line = lines.firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 3))
        let menu = line.frame.union(app.buttons["Reconnect"].frame)
        var flagged: [String] = []
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection, .contrast]) { issue in
            guard let el = issue.element else { print("RF-AUDIT '\(issue.compactDescription)' no element"); return true }
            let entry = "'\(issue.compactDescription)' type \(el.elementType.rawValue) id '\(el.identifier)' label '\(el.label)' frame \(el.frame)"
            print("RF-AUDIT \(entry)")
            if menu.intersects(el.frame) { flagged.append(entry) }
            return true
        }
        shot("9-audit-menu")
        closeMenu()
        fault("none")
        XCTAssertTrue(flagged.isEmpty, "the audit flags the connection lines: \(flagged)")
    }

    // MARK: A gateway gone quiet

    func testAGatewayThatGoesQuietIsFoundAndTheAppRecovers() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        fault("none")
        launch(url: url, token: token)
        XCTAssertTrue(any("chats.new").waitForExistence(timeout: 40))
        XCTAssertEqual(waitForLine(seconds: 20) { $0 == "Connected" }, "Connected")
        fault("stall")
        let quiet = waitForLine(seconds: 150, shotName: "5-quiet") { $0 == "The gateway isn't answering" }
        XCTAssertEqual(quiet, "The gateway isn't answering", "a gateway gone quiet was not named")
        fault("none")
        XCTAssertEqual(waitForLine(seconds: 60) { $0 == "Connected" }, "Connected", "the app did not come back on its own")
        XCTAssertTrue(sendAndAnswer("Back after the quiet", in: "Disk cleanup"))
    }

    // MARK: A reset in the middle of a turn, and a long time away

    func testAReconnectMidTurnLosesNeitherTheMessageNorItsApproval() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        fault("none")
        launch(url: url, token: token)
        XCTAssertTrue(any("chats.new").waitForExistence(timeout: 40))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Disk cleanup")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        let composer = composerClear()
        let words = "Mid-turn reset check"
        composer.tap(); composer.typeText(words)
        app.buttons.matching(identifier: "composer.send").firstMatch.tap()
        XCTAssertTrue(app.buttons["Allow once"].waitForExistence(timeout: 40), "no approval came")
        shot("6-approval-before")
        // Back to the list, Reconnect from the Chats menu (the REST session and the socket made afresh), and back.
        app.buttons["chat.back"].tap(); pause(1)
        _ = connectionLine(then: true)
        log("reconnect tapped")
        XCTAssertEqual(waitForLine(seconds: 30) { $0 == "Connected" }, "Connected")
        row.tap()
        XCTAssertTrue(app.buttons["Allow once"].waitForExistence(timeout: 20), "the approval was lost in the reset")
        shot("7-approval-after")
        // The message, once, where it is on screen: just above its approval. Counted before the reply moves it up and
        // out of the thread's tree (rows off screen are not in it), with the chat holding earlier tests' turns too.
        let sent = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", words))
        XCTAssertEqual(sent.count, 1, "the message shows \(sent.count) times")
        app.buttons["Allow once"].tap()
        pause(4)
        XCTAssertFalse(app.buttons["Allow once"].exists, "the approval did not go")
        shot("8-turn-after")
    }

    /// Away for 65 s while a long turn finishes on the gateway (the socket dropped meanwhile, as iOS does to a suspended
    /// app's) and another chat changes there: back, the REST session is made afresh beside the catch-up loads, and the
    /// open chat and the chat list are current, not merely working: the turn's report is in the chat, and the other
    /// chat's row shows what changed, without being asked.
    func testALongTimeAwayComesBackCurrent() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        fault("none")
        launch(url: url, token: token)
        XCTAssertTrue(any("chats.new").waitForExistence(timeout: 40))
        XCTAssertEqual(waitForLine(seconds: 20) { $0 == "Connected" }, "Connected")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Rewrite the nightly export")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let composer = composerClear()
        composer.tap(); composer.typeText("marathon 200")
        app.buttons.matching(identifier: "composer.send").firstMatch.tap()
        let step = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " of 200: checking shard"))
        XCTAssertTrue(step.firstMatch.waitForExistence(timeout: 20), "the long turn did not start")
        XCUIDevice.shared.press(.home)
        log("away")
        pause(40)
        dropSockets()
        touch(title: "Weekly dependency audit", preview: "Moved on while you were away")
        pause(25)
        app.activate()
        log("back")
        // The open chat: the turn's end, which came while away.
        let report = app.staticTexts.matching(NSPredicate(format: "label == 'Report' OR label CONTAINS 'Step 200 of 200'"))
        XCTAssertTrue(report.firstMatch.waitForExistence(timeout: 30), "the open chat is not current: no end of the turn")
        shot("9-away-chat-current")
        // The list: the chat changed on the gateway while away shows its change.
        app.buttons["chat.back"].tap(); pause(2)
        let changed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Moved on while you were away")).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 20), "the chat list is not current: the change made while away is not shown")
        log("row: \(changed.exists ? changed.label : "not changed")")
        shot("10-away-list-current")
        XCTAssertEqual(waitForLine(seconds: 20) { $0 == "Connected" }, "Connected")
    }

    /// Changes a chat's preview on the mock, as another device's turn would.
    private func touch(title: String, preview: String) {
        let q = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        guard let u = URL(string: base + "/mock/touch?title=\(q(title))&preview=\(q(preview))") else { return }
        let done = expectation(description: "touch")
        URLSession.shared.dataTask(with: u) { data, _, _ in
            print("MOCK-TOUCH \(data.map { String(decoding: $0, as: UTF8.self) } ?? "no answer")"); done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        log("touched \(title)")
    }

    /// Asks the mock to drop every socket it holds, as iOS does to a suspended app's.
    private func dropSockets() {
        guard let u = URL(string: base + "/mock/drop-sockets") else { return }
        let done = expectation(description: "drop")
        URLSession.shared.dataTask(with: u) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
        log("sockets dropped")
    }
}
