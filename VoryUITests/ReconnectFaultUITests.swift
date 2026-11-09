import UIKit
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
        var args = ["-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "light"]
        // HERMES_E2E_TEXT_SIZE: a text size for the app alone (a UIContentSizeCategory name, the accessibility sizes
        // included), with nothing changed on the simulator (#641's AX XXXL pass).
        if let size = ProcessInfo.processInfo.environment["HERMES_E2E_TEXT_SIZE"], !size.isEmpty {
            args += ["-UIPreferredContentSizeCategoryName", size]
        }
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
    private func fault(_ mode: String, status: Int? = nil, count: Int? = nil) {
        var s = base + "/mock/fault?mode=" + mode
        if let status { s += "&status=\(status)" }
        if let count { s += "&count=\(count)" }
        guard let u = URL(string: s) else { return }
        let done = expectation(description: "fault \(mode)")
        URLSession.shared.dataTask(with: u) { data, _, _ in
            print("MOCK-FAULT \(data.map { String(decoding: $0, as: UTF8.self) } ?? "no answer")")
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        log("fault \(mode)")
    }

    final class FaultRead: @unchecked Sendable {
        private let lock = NSLock()
        private var v: (mode: String, count: Int)?
        func set(_ x: (mode: String, count: Int)) { lock.withLock { v = x } }
        var value: (mode: String, count: Int)? { lock.withLock { v } }
    }

    /// The mock's fault switch as it stands (`/mock/fault-state`, which changes nothing): its mode and what's left.
    private func faultState() -> (mode: String, count: Int)? {
        guard let u = URL(string: base + "/mock/fault-state") else { return nil }
        let read = FaultRead()
        let done = expectation(description: "fault state")
        URLSession.shared.dataTask(with: u) { data, _, _ in
            if let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mode = o["mode"] as? String, let count = o["count"] as? Int { read.set((mode, count)) }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return read.value
    }

    private static let known = ["Connected", "Connecting…", "Offline", "Sign in required", "Connection failed",
                                "Cloudflare can't reach the gateway", "Cloudflare wants a sign-in",
                                "A web page answered, not the gateway", "The gateway isn't answering"]

    /// The Chats menu's connection lines. Its reconnecting line counts its attempts ("Reconnecting (2)…"), which keeps the
    /// chat's own quiet "Reconnecting…" (#641) out of it.
    private var lines: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@ OR label BEGINSWITH 'Reconnecting ('", Self.known))
    }

    /// Closes the open menu with a tap well away from it (it opens at the top left; the status bar takes a tap at
    /// the top), and makes sure it went.
    private func closeMenu() {
        for _ in 0..<3 where lines.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8)).tap()
            pause(0.8)
        }
    }

    /// The Chats menu's chip, the first that can be tapped within 10 s: the top bar's on a phone (chats.profile); on a
    /// wide window (the iPad's split view) the list's toolbar's, labelled "Profile: …".
    private func chatsChip() -> XCUIElement? {
        let chips = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'chats.profile' OR label BEGINSWITH 'Profile: '"))
        let end = Date().addingTimeInterval(10)
        repeat {
            if let c = chips.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return c }
            pause(0.2)
        } while Date() < end
        return nil
    }

    /// The connection as the Chats menu shows it, read with the menu open, then the menu closed.
    private func connectionLine(then tapReconnect: Bool = false) -> String {
        closeMenu()
        guard let profile = chatsChip() else { return "no Chats menu" }
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

    // MARK: #641: a chat that can't re-attach keeps trying by itself

    /// The old wording's banner (before #641): "Reconnected, but the chat could not be re-attached: …".
    private var oldBanner: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Reconnected, but the chat could not be re-attached'")).firstMatch
    }

    /// What the open chat's dock says of its attach, read once: "banner" (the re-attach banner with Try again, or the
    /// old wording's), "line" (the quiet "Reconnecting…"), or "none".
    private func reattachState() -> String {
        if any("chat.reattach.tryAgain").exists || oldBanner.exists { return "banner" }
        if any("chat.reattach").exists { return "line" }
        return "none"
    }

    /// Reads the dock about once a second for `seconds`, logging each change; every read, in seconds since `start`.
    private func readDock(for seconds: Double, from start: Date) -> [(t: Double, s: String)] {
        var reads: [(t: Double, s: String)] = []
        var last = ""
        let end = Date().addingTimeInterval(max(0, seconds))
        while Date() < end {
            let s = reattachState(), t = Date().timeIntervalSince(start)
            reads.append((t, s))
            if s != last { log(String(format: "dock %.0f s: %@", t, s)); last = s }
            pause(1)
        }
        return reads
    }

    /// Opens a stored chat from the list (back to the list first when a chat is open).
    private func open(_ title: String) {
        if app.buttons["chat.back"].exists { app.buttons["chat.back"].tap(); pause(1) }
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no row \(title)")
        row.tap()
        _ = composerClear()
    }

    private func launchConnected() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        fault("none")
        launch(url: url, token: token)
        XCTAssertTrue(any("chats.new").waitForExistence(timeout: 40), "the app did not come up")
        XCTAssertEqual(waitForLine(seconds: 20) { $0 == "Connected" }, "Connected", "not connected at the start")
    }

    /// U1, Matt's case: two chats open since launch (both re-attach after a reconnect), the second on screen. The
    /// network goes under the first one's re-attach (the mock aborts the socket on its session.resume). No banner at any
    /// read, back by 30 s, and the chat works. Before #641: about 42 s after the drop the second chat showed
    /// "Reconnected, but the chat could not be re-attached: Timed out waiting for gateway.ready."
    func testAReattachLostMidwayRecoversWithoutABanner() throws {
        try launchConnected()
        open("Disk cleanup")
        open("Rewrite the nightly export")
        fault("drop-on-resume", count: 1)
        dropSockets()
        let start = Date()
        let reads = readDock(for: 50, from: start)
        let banner = reads.first { $0.s == "banner" }
        XCTAssertNil(banner, String(format: "a banner at %.0f s", banner?.t ?? 0))
        shot("641-u1-after")
        let lastShown = reads.last { $0.s != "none" }?.t ?? 0
        XCTAssertLessThan(lastShown, 30, String(format: "not back by 30 s: still shown at %.0f s", lastShown))
        XCTAssertTrue(sendAndAnswer("Back after a re-attach lost midway", in: "Rewrite the nightly export"), "the chat did not work after")
    }

    /// Drags the open chat to its top: six quick drags down in its column (the composer's width), then a pause. Away from
    /// its bottom the transcript anchors size changes at its top (TranscriptView's awayFromBottom), so the row coming
    /// doesn't move the text under the glass top chrome, and the baseline audit and the row's see the same screen.
    private func toChatTop() {
        let column = app.textViews["composer.text"].firstMatch.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let h = app.frame.height
        for _ in 0..<6 {
            let from = origin.withOffset(CGVector(dx: column.midX, dy: h * 0.35))
            let to = origin.withOffset(CGVector(dx: column.midX, dy: h * 0.75))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
            pause(0.4)
        }
        pause(1)
        log("dragged the chat to its top")
    }

    /// The element-less issues the open chat has before the fault, by type and description, counted (auditBaseline).
    private var auditBase: [String: Int] = [:]

    /// The same audit on the open chat just before the fault, with no row up and the chat at its top (toChatTop). An issue
    /// with no element can't be placed, and the screen has its own: the transcript's text blurred under the glass status
    /// and top bars is legible pixels with no element behind them. So the row's audit flags only element-less issues beyond
    /// these. Every issue printed.
    private func auditBaseline() throws {
        var counts: [String: Int] = [:]
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            if let el = issue.element {
                print("RF-AUDIT-BASE '\(issue.compactDescription)' type \(el.elementType.rawValue) id '\(el.identifier)' label '\(el.label)' frame \(el.frame)")
            } else {
                counts["\(issue.auditType.rawValue) \(issue.compactDescription)", default: 0] += 1
                print("RF-AUDIT-BASE '\(issue.compactDescription)' no element")
            }
            return true
        }
        auditBase = counts
    }

    /// The audit gate's three checks (vory-a11y-audit-gate), flagging what falls in the re-attach row, and each issue with
    /// no element beyond the baseline's count of it (auditBaseline). Contrast isn't one of the checks: on glass it fails
    /// across the app (the chat's own banner, the bot card's rows, the title), so it's judged from the stills, not this row.
    private func auditRow() throws -> [String] {
        let row = any("chat.reattach").frame
        let base = auditBase
        var flagged: [String] = []
        var seen: [String: Int] = [:]
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            guard let el = issue.element else {
                let key = "\(issue.auditType.rawValue) \(issue.compactDescription)"
                seen[key, default: 0] += 1
                let beyond = seen[key, default: 0] > base[key, default: 0]
                let entry = "'\(issue.compactDescription)' no element"
                print("RF-AUDIT \(entry)\(beyond ? "" : " (as in the baseline)")")
                if beyond { flagged.append(entry) }
                return true
            }
            let entry = "'\(issue.compactDescription)' type \(el.elementType.rawValue) id '\(el.identifier)' label '\(el.label)' frame \(el.frame)"
            print("RF-AUDIT \(entry)")
            if row.intersects(el.frame) { flagged.append(entry) }
            return true
        }
        return flagged
    }

    /// U2: the gateway takes the upgrade but isn't ready for 30 s. Only the quiet line, pictured and audited while it's
    /// up; never the banner; back by 40 s, and the chat works. Before #641 there was no line at all.
    func testReadyHeld30sShowsOnlyTheQuietLine() throws {
        try launchConnected()
        open("Disk cleanup")
        toChatTop()
        try auditBaseline()
        fault("ready-held", count: 30)
        let start = Date()
        let line = any("chat.reattach")
        XCTAssertTrue(line.waitForExistence(timeout: 12), "no Reconnecting… line")
        pause(1.5)   // the row settled: the still and the audit catch it, not its way in
        if line.exists && !any("chat.reattach.tryAgain").exists {
            shot("641-u2-line")
            let flagged = try auditRow()
            XCTAssertTrue(flagged.isEmpty, "the audit flags the quiet line: \(flagged)")
        }
        let reads = readDock(for: 40 - Date().timeIntervalSince(start), from: start)
        let banner = reads.first { $0.s == "banner" }
        XCTAssertNil(banner, String(format: "a banner at %.0f s", banner?.t ?? 0))
        XCTAssertEqual(reads.last?.s, "none", "not back by 40 s")
        shot("641-u2-after")
        XCTAssertTrue(sendAndAnswer("Back after a held ready", in: "Disk cleanup"), "the chat did not work after")
    }

    /// U3: not ready for 90 s. The quiet line only before 58 s; the banner with Try again by 65 s, pictured and audited;
    /// then gone by itself by 105 s, and the chat works. Before #641 there was no line and no Try again.
    func testReadyHeld90sShowsTryAgainAfterAMinuteThenClearsItself() throws {
        try launchConnected()
        // HERMES_E2E_REDUCE_MOTION=1: the run set the simulator's Reduce Motion on; the pass counts only if it took.
        if ProcessInfo.processInfo.environment["HERMES_E2E_REDUCE_MOTION"] == "1" {
            XCTAssertTrue(UIAccessibility.isReduceMotionEnabled, "Reduce Motion isn't on in the simulator")
        }
        open("Disk cleanup")
        toChatTop()
        try auditBaseline()
        fault("ready-held", count: 90)
        let start = Date()
        let early = readDock(for: 58, from: start)
        XCTAssertTrue(early.contains { $0.s == "line" }, "no Reconnecting… line before a minute")
        let tooSoon = early.first { $0.s == "banner" }
        XCTAssertNil(tooSoon, String(format: "a banner before a minute, at %.0f s", tooSoon?.t ?? 0))
        let tryAgain = any("chat.reattach.tryAgain")
        XCTAssertTrue(tryAgain.waitForExistence(timeout: max(1, 65 - Date().timeIntervalSince(start))), "no Try again by 65 s")
        pause(1.5)   // the line's cross-fade to the banner done: the still and the audit catch the banner, not the change
        shot("641-u3-banner")
        if tryAgain.exists {
            let flagged = try auditRow()
            XCTAssertTrue(flagged.isEmpty, "the audit flags the re-attach banner: \(flagged)")
        }
        let late = readDock(for: 105 - Date().timeIntervalSince(start), from: start)
        XCTAssertEqual(late.last?.s, "none", "the banner didn't go by itself by 105 s")
        shot("641-u3-after")
        XCTAssertTrue(sendAndAnswer("Back after a long hold", in: "Disk cleanup"), "the chat did not work after")
    }

    /// U3b: Try again tries at once. The gateway refuses the chat's next six re-attaches (the mock's resume-refused 6),
    /// then the sockets drop: the tries at about 1, 3, 8, 18, 38 and 68 s are refused, and the schedule's seventh can't
    /// come sooner than 24 s after the sixth. Read from the mock, the sixth refusal and the banner both in, Try again is
    /// tapped: the chat is back within 5 s of the tap, before that seventh try could have come, and works.
    func testTryAgainTriesAtOnce() throws {
        try launchConnected()
        open("Disk cleanup")
        fault("resume-refused", count: 6)
        dropSockets()
        let start = Date()
        let tryAgain = any("chat.reattach.tryAgain")
        var refusing = 0.0, sixth: Double?, last = ""
        while Date().timeIntervalSince(start) < 110 {
            let t = Date().timeIntervalSince(start)
            if sixth == nil, let f = faultState() {
                if f.mode == "resume-refused" { refusing = t } else { sixth = t; log(String(format: "the sixth refusal by %.1f s (%@)", t, f.mode)) }
            }
            let s = reattachState()
            if s != last { log(String(format: "dock %.1f s: %@", t, s)); last = s }
            if sixth != nil, s == "banner", tryAgain.exists { break }
            pause(0.5)
        }
        guard sixth != nil, tryAgain.exists else {
            XCTFail("no sixth refusal with Try again up in 110 s (sixth \(sixth.map { String(format: "%.1f", $0) } ?? "none"), dock \(last))")
            return
        }
        // The sixth refusal came after the last read that still found the mode on, so the seventh try can't come
        // sooner than that read plus 24 s: the schedule's 30 s less its fifth (ReattachSchedule's jitter).
        let seventhNoSooner = refusing + 24
        shot("641-u3b-banner")
        let tapped = Date(), tapAt = tapped.timeIntervalSince(start)
        tryAgain.tap()
        log(String(format: "Try again tapped at %.1f s; the seventh try no sooner than %.1f s", tapAt, seventhNoSooner))
        let after = readDock(for: 6, from: tapped)
        let back = after.first { $0.s == "none" }
        XCTAssertNotNil(back, "not back within 6 s of Try again: \(after.map(\.s))")
        if let back {
            XCTAssertLessThan(back.t, 5, String(format: "back %.1f s after Try again", back.t))
            XCTAssertLessThan(tapAt + back.t, seventhNoSooner, String(format: "back at %.1f s, when the schedule's own try could have come", tapAt + back.t))
        }
        shot("641-u3b-after")
        XCTAssertTrue(sendAndAnswer("Back after Try again", in: "Disk cleanup"), "the chat did not work after")
    }

    /// U4: ten minutes away. Home; the sockets dropped at 30 s, as iOS drops a suspended app's; back at 600 s. Attached
    /// again within 20 s, with no banner at any read, and the chat works.
    func testTenMinutesAwayComesBackAttachedWithoutABanner() throws {
        try launchConnected()
        open("Disk cleanup")
        XCUIDevice.shared.press(.home)
        log("away")
        pause(30)
        dropSockets()
        pause(570)
        app.activate()
        log("back")
        let start = Date()
        let reads = readDock(for: 20, from: start)
        let banner = reads.first { $0.s == "banner" }
        XCTAssertNil(banner, String(format: "a banner at %.0f s after coming back", banner?.t ?? 0))
        XCTAssertEqual(reads.last?.s, "none", "not attached again within 20 s of coming back")
        shot("641-u4-after")
        XCTAssertTrue(sendAndAnswer("Back after ten minutes away", in: "Disk cleanup"), "the chat did not work after")
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
