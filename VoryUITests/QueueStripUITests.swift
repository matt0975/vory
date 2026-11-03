import XCTest

/// #546: the Queued strip with three messages behind a running turn, and Steer on one of them. A chat opened from the
/// Chats list (HERMES_E2E_CHAT, else "Disk cleanup"), the mock's "long 180" turn sent, then three messages, each queued
/// behind it, each starting "short link" so the turn it gets when it's sent is the mock's short reply, which asks for no
/// approval (its usual turn ends on an approval card, which takes the composer's place). Checked:
/// - the strip lists three, each row with Steer, Edit and Delete, every one 44 pt or more each way (frames noted);
/// - VoiceOver's order (`-vory-ax-oracle`): each message's words before its Steer, Edit and Delete, row by row;
/// - with HERMES_E2E_AUDIT=1, the chat screen's audit (contrast, element descriptions, hit regions, element detection):
///   any finding on the strip's own controls (queue.steer, queue.edit, queue.delete) FAILS the test; every other finding is
///   noted (the tabs and pages behind the chat, the strip's heading and words: not #546's);
/// - Steer on the second: it leaves the strip, the first and third keep their order, and a steer row with its words
///   comes in the thread.
/// A hold for a still before the Steer (BARUP HOLD queued) and after it (BARUP HOLD steered). In the scheme and text size
/// the script names (HERMES_E2E_SCHEME, HERMES_E2E_SIZE: a content size category). Notes are XCTContext activities: this
/// Xcode leaves the runner's print() out of xcodebuild's log. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
@MainActor
final class QueueStripUITests: XCTestCase {
    private var app: XCUIApplication!
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    /// A line in the run's log: the runner's own print isn't kept there, an activity's name is. Static, so the audit's
    /// handler calls it without taking `self` along.
    nonisolated private static func note(_ line: String) { XCTContext.runActivity(named: line) { _ in } }
    private static let words = ["short link first", "short link second", "short link third"]

    /// What VoiceOver stops on, in order (the oracle's readout, "label|x,y,w,h" a line).
    private func voiceOverStops() -> [String]? {
        let oracle = element("debug.voiceover")
        guard oracle.waitForExistence(timeout: 5) else { return nil }
        return ((oracle.value as? String) ?? "").split(separator: "\n").compactMap { line in
            line.lastIndex(of: "|").map { String(line[..<$0]) }
        }
    }

    /// Types `words` into the box and checks it holds exactly them: a keyboard that drops while XCTest types on loses
    /// the rest, and the part would then be sent and read as something else. Then waits for the keyboard to settle.
    private func type(_ words: String, into composer: XCUIElement) {
        composer.tap()
        composer.typeText(words)
        let held = (composer.value as? String) ?? ""
        XCTAssertEqual(held, words, "the box took only '\(held)' of '\(words)'")
        keyboardSettled()
    }

    /// For about a second after typeText the keyboard is off screen while `app.keyboards` still finds it, and then it
    /// comes back: a control tapped by a frame read in that time meets the returning keyboard. Waits (5 s at most) for
    /// the keyboard's frame on screen and the same twice, 0.2 s apart; noted if it never is.
    private func keyboardSettled() {
        let window = app.windows.firstMatch.frame, keyboard = app.keyboards.firstMatch
        var last = CGRect.null
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            let k = keyboard.exists ? keyboard.frame : .null
            let on = !k.isNull && k.height > 0 && k.minY < window.maxY
            if on && k == last { return }
            last = on ? k : .null
            pause(0.2)
        }
        Self.note("QUEUE the keyboard didn't settle on screen in 5 s")
    }

    private func send(_ text: String) throws {
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")
        type(text, into: composer)
        let sendButton = app.buttons.matching(identifier: "composer.send").firstMatch
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "no send")
        // Send where it stands over the settled keyboard: its frame the same twice, 0.2 s apart, clear of the keyboard's top.
        let keyboard = app.keyboards.firstMatch
        var at = CGRect.null
        for _ in 0..<15 {
            let f = sendButton.frame, top = keyboard.exists ? keyboard.frame.minY : .greatestFiniteMagnitude
            if f == at, f.maxY <= top + 1 { break }
            at = f
            pause(0.2)
        }
        sendButton.tap()
        // Sent or queued, the words leave the box. A tap that didn't take leaves them there: read now, with where the
        // button and the keyboard stood, not found later as two messages run together in the box.
        let left = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", text), object: composer)
        if XCTWaiter().wait(for: [left], timeout: 3) != .completed {
            let keyboard = app.keyboards.firstMatch
            Self.note("QUEUE send of '\(text)' didn't take: send \(sendButton.frame) hittable \(sendButton.isHittable), keyboard \(keyboard.exists ? "\(keyboard.frame)" : "none")")
            XCTFail("the send of '\(text)' didn't take: its words stayed in the box")
        }
    }

    /// The strip's rows top to bottom: each Steer button and the words standing level with it before it. Only the three
    /// words' texts are asked for, and each frame is read once, so the strip is read in a moment, not a walk of the tree.
    private func stripRows() -> [(words: String, steer: XCUIElement)] {
        let steers = app.buttons.matching(identifier: "queue.steer").allElementsBoundByIndex.compactMap { b in b.exists ? (b, b.frame) : nil }
        let texts = app.staticTexts.matching(NSPredicate(format: "label IN %@", Self.words)).allElementsBoundByIndex
            .compactMap { t in t.exists ? (t.label, t.frame) : nil }
        return steers.sorted { $0.1.minY < $1.1.minY }.map { steer, frame in
            let row = texts.first { abs($0.1.midY - frame.midY) <= 12 && $0.1.maxX <= frame.minX + 1 }
            return (row?.0 ?? "?", steer)
        }
    }

    /// The app on Chats with the mock, the chat the script names opened; the mock's address.
    @discardableResult private func openChat() throws -> String {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        var args = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats",
                    "-restore.openChat", "none", "-colorSchemePreference", e["HERMES_E2E_SCHEME"] ?? "light", "-vory-ax-oracle"]
        if let size = e["HERMES_E2E_SIZE"], !size.isEmpty { args += ["-UIPreferredContentSizeCategoryName", size] }
        app.launchArguments = args
        app.launch()
        XCTAssertTrue(element("tab.chats").waitForExistence(timeout: 40), "no tab bar")
        pause(2)
        let chat = e["HERMES_E2E_CHAT"].flatMap { $0.isEmpty ? nil : $0 } ?? "Disk cleanup"
        let row = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND identifier != 'chat.titlePill'", chat))
            .allElementsBoundByIndex.first { $0.exists && $0.isHittable }, "no row with '\(chat)'")
        row.tap()
        return url
    }

    /// The mock's fault switch (GET /mock/fault?mode=…), as the other mock-driven tests set it.
    private func fault(_ mode: String, _ base: String) {
        guard let u = URL(string: "\(base)/mock/fault?mode=\(mode)") else { return XCTFail("no fault URL") }
        let done = expectation(description: "fault \(mode)")
        URLSession.shared.dataTask(with: u) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
        Self.note("QUEUE fault \(mode)")
    }

    /// The user rows carrying `words` (the thread's own, never the strip's). A row is a container with no label of its own,
    /// so its texts are read.
    private func userRows(_ words: String) -> Int {
        app.descendants(matching: .any).matching(identifier: "thread.row.user").allElementsBoundByIndex
            .filter { $0.exists && $0.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", words)).count > 0 }.count
    }

    func testThreeQueuedAndSteerOne() throws {
        let e = ProcessInfo.processInfo.environment
        try openChat()
        // The mock's long turn: it streams for three minutes, so the three sent after it queue behind it, and it outlasts the
        // audit and the reads (a 60 s turn ended mid-test, and the queue moved on under the read after Steer).
        try send("long 180")
        pause(2)
        for w in Self.words { try send(w); pause(1) }
        XCTAssertTrue(app.buttons.matching(identifier: "queue.steer").firstMatch.waitForExistence(timeout: 10), "no Steer: nothing queued, or the turn ended")
        pause(1)

        let rows = stripRows()
        Self.note("QUEUE rows \(rows.map(\.words))")
        XCTAssertEqual(rows.map(\.words), Self.words, "the strip's rows")
        let side = { (f: CGRect) in (min(f.width, f.height) * 1000).rounded() / 1000 }
        for id in ["queue.steer", "queue.edit", "queue.delete"] {
            let all = app.buttons.matching(identifier: id).allElementsBoundByIndex.filter(\.exists)
            Self.note("QUEUE \(id) \(all.count): \(all.map { "\($0.frame)" }.joined(separator: ", "))")
            XCTAssertEqual(all.count, 3, "\(id) on every row")
            for b in all { XCTAssertGreaterThanOrEqual(side(b.frame), 44, "\(id) \(b.frame) under 44 pt") }
        }

        // VoiceOver: a row's words, then its Steer, Edit and Delete, before the next row's words.
        if let stops = voiceOverStops() {
            Self.note("QUEUEAX \(stops.count) stops: \(stops.joined(separator: " ⟩ "))")
            var last = -1
            for w in Self.words {
                guard let at = stops.firstIndex(where: { $0.contains(w) }) else { XCTFail("VoiceOver doesn't stop on '\(w)'"); continue }
                let after = stops[(at + 1)...].prefix(3).map { $0.components(separatedBy: ",").first ?? $0 }
                Self.note("QUEUEAX '\(w)' at \(at), then \(after)")
                XCTAssertGreaterThan(at, last, "'\(w)' read out of order")
                XCTAssertEqual(after, ["Steer", "Edit", "Delete"], "'\(w)' isn't followed by its Steer, Edit and Delete")
                last = at
            }
        } else { Self.note("QUEUEAX no oracle") }

        Self.note("BARUP HOLD queued"); pause(3)
        if e["HERMES_E2E_AUDIT"] == "1" {
            var issues = 0
            // The strip's own controls fail the audit (returned unhandled); anything else is noted and let go.
            let own: Set<String> = ["queue.steer", "queue.edit", "queue.delete"]
            try app.performAccessibilityAudit(for: [.contrast, .sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
                issues += 1
                let el = issue.element, id = el?.identifier ?? ""
                Self.note("AUDIT queue \(own.contains(id) ? "FAIL" : "noted") \(issue.auditType) '\(id)' '\(el?.label ?? "")' \(el.map { "\($0.frame)" } ?? "-") \(issue.compactDescription)")
                return !own.contains(id)
            }
            Self.note("AUDIT queue done, \(issues) issues")
        }

        // Steer the second: it leaves the strip, the other two keep their order, and its words come as a steer row.
        // Only with all three rows: with fewer there's no second to steer, and the run fails by name rather than crashing.
        guard rows.count == 3 else {
            XCTFail("missing '\(Self.words.filter { w in !rows.contains { $0.words == w } }.joined(separator: "', '"))': no second row to steer")
            app.terminate(); return
        }
        rows[1].steer.tap()
        pause(2)
        let after = stripRows()
        Self.note("QUEUE after Steer: \(after.map(\.words))")
        XCTAssertEqual(after.map(\.words), [Self.words[0], Self.words[2]], "the strip after Steer")
        let steered = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Steered'")).firstMatch
        XCTAssertTrue(steered.waitForExistence(timeout: 5), "no steer row")
        XCTAssertTrue(app.staticTexts.allElementsBoundByIndex.contains { $0.exists && $0.label == Self.words[1] }, "the steer row lacks its words")
        Self.note("BARUP HOLD steered"); pause(3)
        app.terminate()
    }

    /// Steer tapped as a reply ends: the gateway answers "rejected" (its turn ended a moment before the app knew; made
    /// certain by the mock's steer-rejected fault, not timed). Both ways in, the words arrive as their own message once
    /// the turn ends, exactly once, with no "Steered" row. They start "short link" so each gets the mock's short reply,
    /// which ends by itself, and the second isn't held behind an approval card:
    /// - Steer on a queued message: it stays in the strip (back where it was);
    /// - the composer's Steer now: the box is empty and the words stand in the strip, queued.
    /// The mock's "long 30" turn outlasts the typing and taps, then ends on its own; its end is waited for (90 s at most)
    /// only to see the words arrive.
    func testARejectedSteerArrivesAsTheNextMessage() throws {
        let base = try openChat()
        fault("steer-rejected", base)
        defer { fault("none", base) }
        try send("long 30")
        pause(1.5)
        try send("short link from the queue")
        let steer = app.buttons.matching(identifier: "queue.steer").firstMatch
        XCTAssertTrue(steer.waitForExistence(timeout: 10), "nothing queued: the turn had ended")
        steer.tap()
        pause(1.5)
        let inStrip = { (w: String) in self.app.staticTexts.allElementsBoundByIndex.contains { $0.exists && $0.label == w } }
        XCTAssertTrue(inStrip("short link from the queue"), "a rejected Steer left the strip")
        // The composer's Steer now, rejected the same way.
        let composer = app.textViews["composer.text"].firstMatch
        type("short link from the box", into: composer)
        let steerNow = app.buttons["Steer now"].firstMatch
        XCTAssertTrue(steerNow.waitForExistence(timeout: 5), "no Steer now")
        steerNow.tap()
        pause(1.5)
        XCTAssertTrue(inStrip("short link from the box"), "a rejected Steer now didn't queue its words")
        XCTAssertEqual((composer.value as? String) ?? "", "", "the box kept words that were queued")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Steered'")).firstMatch.exists,
                       "a rejected steer showed as steered")
        Self.note("BARUP HOLD rejected"); pause(2)
        // The turn ends, the queue sends each as its own message, once.
        let end = Date().addingTimeInterval(90)
        while Date() < end, userRows("short link from the queue") == 0 || userRows("short link from the box") == 0 { pause(1) }
        pause(3)
        Self.note("QUEUE arrived: queue \(userRows("short link from the queue")), box \(userRows("short link from the box"))")
        XCTAssertEqual(userRows("short link from the queue"), 1, "the queued words didn't arrive once as a message")
        XCTAssertEqual(userRows("short link from the box"), 1, "Steer now's words didn't arrive once as a message")
        app.terminate()
    }
}
