import XCTest

/// #350: the keyboard closes from the chat, on the iPhone and the iPad. A tap in the thread closes the on-screen keyboard,
/// and the tapped thing still does what it does: a tool card opens (once, staying on screen where it was tapped),
/// Reasoning opens, a link opens; a long press still shows its menu; a tap on the dock's own blank glass leaves the
/// keyboard up; a drag still scrolls. Close keyboard after sending, off by default: on, Send closes the keyboard; off, it
/// stays up. Settings › Appearance with the new row passes the audit. A chat over the mock (`-vory-demo-gateway`), not
/// Demo mode, which closes after a send either way (#490). The Mac has no on-screen keyboard and none of this.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN / HERMES_E2E_BUNDLE are set (the mock and the demo copy).
@MainActor
final class KeyboardCloseUITests: XCTestCase {
    private var app: XCUIApplication!

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private var field: XCUIElement { app.textViews["composer.text"].firstMatch }

    private func launch(_ extra: [String] = []) throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty,
              let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { throw XCTSkip("needs the mock (HERMES_E2E_URL / TOKEN / BUNDLE)") }
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-vory-card-probe"] + extra
        app.launch()
    }

    /// A still of the screen now, kept with the run and in HERMES_E2E_SHOTS, for a failure read later.
    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }

    /// The keyboard is up (or down) within `timeout`.
    @discardableResult
    private func keyboard(up: Bool, within timeout: Double = 5) -> Bool {
        let e = expectation(for: NSPredicate(format: up ? "count > 0" : "count == 0"), evaluatedWith: app.keyboards)
        return XCTWaiter().wait(for: [e], timeout: timeout) == .completed
    }

    /// A new chat with a finished turn from the mock (`steps 8`: Reasoning before each tool card, then the answer), the
    /// thread at its end and the keyboard up.
    private func chatWithCards(_ prompt: String = "steps 8", done: String = "shards read, no errors") {
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40), "no New Chat")
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 30), "no message bar")
        field.tap(); field.typeText(prompt)
        send()
        if !app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", done)).firstMatch.waitForExistence(timeout: 90) {
            // For the read: where the turn stood (a card waiting, still streaming, an error row).
            shot("turn-not-finished-\(prompt.replacingOccurrences(of: " ", with: "-"))")
            print("KEYBOARD-CLOSE turn '\(prompt)' not finished; last texts: \(app.staticTexts.allElementsBoundByIndex.suffix(6).map { $0.label })")
            XCTFail("the turn did not finish")
        }
        pause(1.5)
        if app.keyboards.count == 0 { field.tap() }
        XCTAssertTrue(keyboard(up: true), "no keyboard for the message bar")
        pause(0.8)
    }

    /// Sends what the field holds, with one tap on the visible Send: on screen, enabled and inside the window (the iPad
    /// keeps other chats' composers in its stacks, and the first match was one of theirs). No second tap: a Send that
    /// needs two would be the app's to answer. Every Send in the tree is printed, for which of them are exposed.
    private func send(file: StaticString = #filePath, line: UInt = #line) {
        let all = app.buttons.matching(identifier: "composer.send").allElementsBoundByIndex
        let window = app.windows.firstMatch.frame
        print("KEYBOARD-CLOSE sends in the tree: \(all.count): \(all.map { "\($0.frame) hittable \($0.isHittable) enabled \($0.isEnabled)" })")
        guard let button = all.first(where: { $0.isHittable && $0.isEnabled && window.contains($0.frame) }) else {
            shot("send-not-found"); XCTFail("no visible, enabled Send", file: file, line: line); return
        }
        print("KEYBOARD-CLOSE send tapped at \(button.frame)")
        button.tap()
        let sent = NSPredicate(format: "NOT (value CONTAINS[c] 'steps') AND NOT (value CONTAINS[c] 'hello') AND NOT (value CONTAINS[c] 'huge') AND NOT (value CONTAINS[c] 'link')")
        if XCTWaiter().wait(for: [expectation(for: sent, evaluatedWith: field)], timeout: 4) != .completed {
            shot("send-sent-nothing")
            XCTFail("one tap on Send sent nothing; the field holds '\(field.value as? String ?? "")'", file: file, line: line)
        }
    }

    /// The cards of a kind on screen, above the message bar and under the header.
    private func cards(_ predicate: NSPredicate) -> [XCUIElement] {
        let barTop = any("chat.dock").frame.minY
        let headerBottom = any("chat.header").exists ? any("chat.header").frame.maxY : 120
        return app.buttons.matching(predicate).allElementsBoundByIndex
            .filter { $0.isHittable && $0.frame.minY > headerBottom && $0.frame.maxY < barTop }
            .sorted { $0.frame.minY < $1.frame.minY }
    }
    private let toolCard = NSPredicate(format: "label BEGINSWITH 'Done, terminal' OR label BEGINSWITH 'terminal'")

    /// The card probe's samples since the last tap: each toggled card's key, and its (seconds, top, height).
    private func cardSamples() -> [String: [(t: Double, top: CGFloat, height: CGFloat)]] {
        let e = any("debug.cardmotion")
        guard e.waitForExistence(timeout: 5), let v = e.value as? String else { return [:] }
        let parts = v.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var out: [String: [(t: Double, top: CGFloat, height: CGFloat)]] = [:]
        for s in (parts.count > 1 ? parts[1] : "").split(separator: ";") {
            let f = s.split(separator: ",").map(String.init)
            guard f.count == 4, let t = Double(f[1]), let top = Double(f[2]), let h = Double(f[3]) else { continue }
            out[f[0], default: []].append((t, CGFloat(top), CGFloat(h)))
        }
        return out
    }

    func testATapInTheChatClosesTheKeyboard() throws {
        try launch()
        chatWithCards()
        // A plain part of the thread: the answer's own text, which does nothing on a tap.
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'shards read, no errors'")).firstMatch
        XCTAssertTrue(answer.isHittable, "the answer is not on screen")
        answer.tap()
        XCTAssertTrue(keyboard(up: false), "a tap in the chat left the keyboard up")
    }

    /// With the keyboard up and the thread at its end, a tool card's header tapped: the keyboard closes (the thread comes
    /// down with the dock, as in Messages) and the card opens, once, ending on screen with its header under the tapped
    /// point's column.
    func testACardTappedWithTheKeyboardUpOpensOnceAndStaysOnScreen() throws {
        try launch()
        chatWithCards()
        guard let card = cards(toolCard).last else { XCTFail("no tool card above the bar"); return }
        let before = card.frame
        let tap = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 16))
        tap.tap()
        XCTAssertTrue(keyboard(up: false), "the keyboard stayed up after a card was tapped")
        pause(1.5)
        let samples = cardSamples()
        print("KEYBOARD-CLOSE card \(before) samples \(samples.mapValues { $0.map { String(format: "%.2f:%.0f/%.0f", $0.t, $0.top, $0.height) } })")
        XCTAssertEqual(samples.count, 1, "not one card toggled: \(samples.keys.sorted())")
        // Opened: taller than the closed card was before the tap (the layout takes the open height at once, so the
        // probe's own first sample is already open).
        if let s = samples.values.first, let last = s.last {
            XCTAssertGreaterThan(last.height, before.height + 10, "the card did not open (height \(before.height) before the tap, \(last.height) after)")
            let window = app.windows.firstMatch.frame
            XCTAssertTrue(last.top >= window.minY && last.top + 44 <= window.maxY, "the card's header ended off screen at \(last.top)")
        }
        // Its header is still where the finger was, column-wise, and the card stays open (no second toggle).
        if let open = cards(toolCard).min(by: { abs($0.frame.minX - before.minX) + abs($0.frame.minY - before.minY) < abs($1.frame.minX - before.minX) + abs($1.frame.minY - before.minY) }) {
            XCTAssertTrue(open.frame.minX <= before.midX && before.midX <= open.frame.maxX, "the card moved out of the tapped column: \(before) to \(open.frame)")
        }
        pause(1)
        XCTAssertEqual(cardSamples().count, 1, "a second toggle after the first")
    }

    /// Reasoning tapped with the keyboard up: the keyboard closes and Reasoning opens.
    func testReasoningTappedWithTheKeyboardUpOpens() throws {
        try launch()
        chatWithCards()
        guard let reasoning = cards(NSPredicate(format: "label == 'Show reasoning'")).last else { XCTFail("no Reasoning above the bar"); return }
        reasoning.tap()
        XCTAssertTrue(keyboard(up: false), "the keyboard stayed up after Reasoning was tapped")
        XCTAssertTrue(app.buttons["Hide reasoning"].firstMatch.waitForExistence(timeout: 3), "Reasoning did not open")
    }

    /// A link in a reply tapped with the keyboard up: the link opens (Safari comes forward) and, back in the app, the
    /// keyboard is down.
    func testALinkTappedWithTheKeyboardUpOpensAndTheKeyboardCloses() throws {
        try launch()
        // A short reply ending on its link: with the keyboard up the link is in view at the thread's end (the long
        // paragraph's link sat above the screen on the iPhone, and drags did not bring it down).
        chatWithCards("short link", done: "every shard matched")
        let link = app.links["status page"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "no link in the reply")
        // Wholly into the thread's clear band (under the header, above the bar) by the link's own frame: each drag moves
        // the thread by what is left to go, at most 60% of the band, held before release so it doesn't fling. A drag that
        // moves nothing ends it, and the case fails saying where the link stayed (a link half under the header takes the
        // header's tap, as on the iPad).
        let headerBottom = any("chat.header").exists ? any("chat.header").frame.maxY : 120
        let barTop = any("chat.dock").frame.minY
        let bandTop = headerBottom + 12, bandBottom = barTop - 12
        let inBand = { link.frame.minY >= bandTop && link.frame.maxY <= bandBottom }
        let w = app.windows.firstMatch
        let origin = w.coordinate(withNormalizedOffset: .zero)
        var stuck = ""
        for _ in 0..<10 where !inBand() {
            let f = link.frame
            let need = f.minY < bandTop ? bandTop + 20 - f.minY : -(f.maxY - (bandBottom - 20))   // + moves the thread down
            let reach = (bandBottom - bandTop) * 0.6
            let step = max(-reach, min(reach, need))
            let mid = (bandTop + bandBottom) / 2
            origin.withOffset(CGVector(dx: w.frame.midX, dy: mid - step / 2))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: w.frame.midX, dy: mid + step / 2)), withVelocity: .slow, thenHoldForDuration: 0.3)
            pause(0.6)
            if abs(link.frame.minY - f.minY) < 1 { stuck = "a drag of \(Int(step)) pt moved nothing"; break }
        }
        guard inBand() else {
            shot("link-not-in-band")
            XCTFail("the link could not be brought wholly into the band \(Int(bandTop))...\(Int(bandBottom)): it stays at \(link.frame)\(stuck.isEmpty ? "" : "; " + stuck)")
            return
        }
        // On the link's last line, not the middle of its frame: a link that wraps ("status" ending one line, "page"
        // starting the next) has a frame round both pieces, and its middle is the plain text between them, where the
        // tap closed the keyboard and opened nothing. A wrapped link's last line starts at the text's leading edge.
        let f = link.frame
        let point = CGPoint(x: f.minX + 10, y: f.maxY - 10)
        print("KEYBOARD-CLOSE link frame \(f) hittable \(link.isHittable) window \(app.windows.firstMatch.frame) tap \(point)")
        origin.withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        if !safari.wait(for: .runningForeground, timeout: 15) {
            // For the read: whether it opened in a sheet in the app instead, or the tap missed the link.
            shot("link-not-opened")
            print("KEYBOARD-CLOSE link: Safari \(safari.state.rawValue), app \(app.state.rawValue), a Done button \(app.buttons["Done"].exists), keyboard \(app.keyboards.count)")
            XCTFail("the link did not open")
        }
        app.activate()
        pause(1.5)
        XCTAssertEqual(app.keyboards.count, 0, "the keyboard was up again after the link")
    }

    /// A long press on a message with the keyboard up still shows its menu.
    func testALongPressWithTheKeyboardUpShowsTheMenu() throws {
        try launch()
        chatWithCards()
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'shards read, no errors'")).firstMatch
        answer.press(forDuration: 1.2)
        let copy = app.buttons.matching(NSPredicate(format: "label == 'Copy' OR label == 'Copy Text'")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 4), "no menu after a long press with the keyboard up")
    }

    /// A tap on the dock's own glass beside the field (it floats over the thread, and such a tap reaches the scroll view
    /// under it) leaves the keyboard up.
    func testATapOnTheDocksBlankGlassLeavesTheKeyboardUp() throws {
        try launch()
        chatWithCards()
        let dock = any("chat.dock").frame
        let f = field.frame
        // The dock's top margin, above the field: glass, no control.
        let y = dock.minY + max(2, (f.minY - dock.minY) / 2)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: y)).tap()
        pause(1)
        XCTAssertGreaterThan(app.keyboards.count, 0, "a tap on the dock's glass closed the keyboard")
    }

    /// A drag on the thread with the keyboard up scrolls it and is not taken for a tap: the keyboard stays up.
    func testADragOnTheThreadScrollsAndLeavesTheKeyboardUp() throws {
        try launch()
        chatWithCards()
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'shards read, no errors'")).firstMatch
        let before = answer.frame.minY
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)), withVelocity: .slow, thenHoldForDuration: 0.2)
        pause(1)
        XCTAssertNotEqual(answer.frame.minY, before, "the drag did not scroll the thread")
        XCTAssertGreaterThan(app.keyboards.count, 0, "a drag in the chat closed the keyboard")
    }

    private func sendHello() {
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40), "no New Chat")
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 30), "no message bar")
        field.tap()
        XCTAssertTrue(keyboard(up: true), "no keyboard for the message bar")
        field.typeText("hello")
        send()
        pause(1.5)
    }

    func testWithCloseKeyboardAfterSendingOnSendClosesIt() throws {
        try launch(["-chat.closeKeyboardAfterSend", "YES"])
        sendHello()
        XCTAssertTrue(keyboard(up: false), "the keyboard stayed up after Send with the setting on")
    }

    func testWithCloseKeyboardAfterSendingOffTheKeyboardStaysUp() throws {
        try launch(["-chat.closeKeyboardAfterSend", "NO"])
        sendHello()
        XCTAssertGreaterThan(app.keyboards.count, 0, "the keyboard went down after Send with the setting off")
    }

    // MARK: #505: a swipe down the thread closes the keyboard, in a chat over the mock and in a Demo mode chat: a fast
    // swipe on a short thread and a slow drag down into the keyboard on a long one (the issue's report was a demo chat).

    /// A drag down the thread from its upper part into the keyboard, fast or slow, then the keyboard's state settles.
    private func swipeDown(fast: Bool) {
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)), withVelocity: fast ? .fast : .slow, thenHoldForDuration: 0)
        pause(1.2)
    }

    func testASwipeDownClosesTheKeyboardInAChatOverTheMock() throws {
        try launch()
        sendHello()
        XCTAssertTrue(keyboard(up: true), "no keyboard before the swipe")
        swipeDown(fast: true)
        XCTAssertTrue(keyboard(up: false), "a fast swipe down a short thread left the keyboard up")
        app.terminate()
        try launch()
        chatWithCards()
        swipeDown(fast: false)
        XCTAssertTrue(keyboard(up: false), "a slow drag down a long thread left the keyboard up")
    }

    func testASwipeDownClosesTheKeyboardInADemoChat() throws {
        guard let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { throw XCTSkip("HERMES_E2E_BUNDLE not set") }
        continueAfterFailure = true
        for (chatTitle, fast) in [("Packing list for the lake weekend", true), ("Morning checks on the home servers", false)] {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo", "-companionPromptShown", "YES", "-launchTab", "chats"]
            app.launch()
            let chat = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", chatTitle)).firstMatch
            XCTAssertTrue(chat.waitForExistence(timeout: 30), "no demo chat '\(chatTitle)'")
            chat.tap(); pause(1.5)
            XCTAssertTrue(field.waitForExistence(timeout: 20), "no message bar in '\(chatTitle)'")
            field.tap()
            XCTAssertTrue(keyboard(up: true), "no keyboard in '\(chatTitle)'")
            pause(0.8)
            swipeDown(fast: fast)
            XCTAssertTrue(keyboard(up: false), "a \(fast ? "fast swipe" : "slow drag") down '\(chatTitle)' left the keyboard up")
            app.terminate()
        }
    }

    /// Settings › Appearance with Close keyboard after sending on it passes the audit; every finding is printed.
    func testAppearanceWithTheNewRowPassesTheAudit() throws {
        try launch(["-launchTab", "settings"])
        var row = any("settings.row.appearance")
        XCTAssertTrue(any("settings.row.profile").waitForExistence(timeout: 30), "no Settings rows")
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow); pause(0.6); row = any("settings.row.appearance") }
        row.tap(); pause(1.5)
        let toggle = any("settings.closeKeyboardAfterSend")
        for _ in 0..<12 where !(toggle.exists && toggle.isHittable) { app.swipeUp(velocity: .slow); pause(0.5) }
        XCTAssertTrue(toggle.exists && toggle.isHittable, "no Close keyboard after sending row")
        XCTAssertEqual(toggle.value as? String, "0", "Close keyboard after sending is not off by default")
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            print("KEYBOARD-AUDIT '\(issue.compactDescription)' label '\(issue.element?.label ?? "")' id '\(issue.element?.identifier ?? "")' frame \(issue.element?.frame ?? .zero)")
            return false
        }
    }
}
