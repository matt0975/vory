import XCTest

/// #437: a Reasoning or tool card opening or closing keeps its place. Its top does not move while it animates (the rows
/// below glide), in the middle of the thread, just above the message bar, at the end, and while a turn streams below;
/// a close with the thread at its very end brings the rows above down in one smooth motion. Read from the app's DEBUG
/// probe (`-vory-card-probe`, `CardMotionProbe`): the toggled card's top at each layout since the tap.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock). HERMES_E2E_BUNDLE=com.vorantx.vory.demo drives
/// the demo copy.
@MainActor
final class CardMotionUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func launch(url: String, token: String) {
        let args = ["-companionPromptShown", "YES", "-vory-card-probe"]
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
    }

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    /// The probe: whether the thread holds a card now, and each toggled card's (seconds after the first tap, top).
    private func probe() -> (holding: Bool, cards: [String: [(t: Double, top: CGFloat)]]) {
        let e = app.descendants(matching: .any).matching(identifier: "debug.cardmotion").firstMatch
        guard e.waitForExistence(timeout: 5), let v = e.value as? String else { return (false, [:]) }
        let parts = v.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var cards: [String: [(t: Double, top: CGFloat)]] = [:]
        for s in (parts.count > 1 ? parts[1] : "").split(separator: ";") {
            let f = s.split(separator: ",").map(String.init)
            guard f.count == 4, let t = Double(f[1]), let top = Double(f[2]) else { continue }
            cards[f[0], default: []].append((t, CGFloat(top)))
        }
        return (parts.first == "1", cards)
    }

    /// The toggled card's tops in the first `within` seconds after the tap (the toggle's animation).
    private func tops(within: Double = 0.6) -> [CGFloat] {
        probe().cards.values.flatMap { $0 }.filter { $0.t <= within }.map(\.top)
    }

    /// Each card's movement (highest top minus lowest) over the first `within` seconds, and when it was first seen.
    private func drifts(within: Double) -> [(key: String, first: Double, drift: CGFloat, count: Int)] {
        probe().cards.map { key, v in
            let w = v.filter { $0.t <= within }.map(\.top)
            return (key, v.map(\.t).min() ?? 0, (w.max() ?? 0) - (w.min() ?? 0), w.count)
        }.sorted { $0.first < $1.first }
    }

    /// Taps `card`, waits for the animation and checks the card's top held (within half a point) over at least two
    /// layouts. Returns the tops.
    @discardableResult
    private func toggleHolds(_ card: XCUIElement, _ name: String, header: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> [CGFloat] {
        // A tool card by its header row: an open one's middle is its output, whose controls have taps of their own.
        if header { card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 16)).tap() } else { card.tap() }
        pause(1.1)
        let t = tops()
        let drift = (t.max() ?? 0) - (t.min() ?? 0)
        print("CARD-MOTION \(name): \(t.count) layouts, top \(t.first.map { String(format: "%.1f", $0) } ?? "-") drift \(String(format: "%.2f", drift))")
        XCTAssertGreaterThanOrEqual(t.count, 1, "\(name): the probe saw no layout", file: file, line: line)
        XCTAssertLessThanOrEqual(drift, 0.5, "\(name): the card's top moved \(drift) pt while it animated: \(t)", file: file, line: line)
        return t
    }

    /// The cards of a kind on screen, top to bottom, above the message bar.
    private func cards(_ predicate: NSPredicate) -> [XCUIElement] {
        let barTop = app.textViews["composer.text"].firstMatch.frame.minY - 20
        return app.buttons.matching(predicate).allElementsBoundByIndex
            .filter { $0.isHittable && $0.frame.minY > 140 && $0.frame.maxY < barTop }
            .sorted { $0.frame.minY < $1.frame.minY }
    }
    private let showReasoning = NSPredicate(format: "label == 'Show reasoning'")
    private let hideReasoning = NSPredicate(format: "label == 'Hide reasoning'")
    private let toolCard = NSPredicate(format: "label BEGINSWITH 'Done, terminal' OR label BEGINSWITH 'terminal'")

    private func startTurn(_ prompt: String) {
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap(); composer.typeText(prompt)
        app.buttons.matching(identifier: "composer.send").firstMatch.tap()
    }

    /// #634: a card tapped with the keyboard still up after a send keeps its place, and the keyboard stays up. The field
    /// keeps its focus after a send unless "Close keyboard after sending" is on, so this is the first tap after typing.
    /// The same tap used to close the keyboard as well (#350's tap in the chat): the thread's bottom margin then fell by
    /// the keyboard's height under the card's hold, and the card dropped about that far in one step, then slid back at
    /// the hold's end. Each kind on its own launch and turn, typed once, at the start.
    func testAReasoningCardTappedWithTheKeyboardUpKeepsItsPlace() throws { try tapWithTheKeyboardUp(tool: false) }
    func testAToolCardTappedWithTheKeyboardUpKeepsItsPlace() throws { try tapWithTheKeyboardUp(tool: true) }

    /// The lowest card of a kind tapped with the keyboard up, read from the probe over the first second after the tap: no
    /// step over 24 pt in it; 8 pt or less of movement in the first 0.6 s (a working hold reads 3 to 5 pt for one layout
    /// before its correction lands); back within 1 pt of the card's top before the tap by 0.6 s; and the keyboard still
    /// up after it. With the keyboard not up before the tap the case can't be judged, and fails as that.
    private func tapWithTheKeyboardUp(tool: Bool) throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        launch(url: url, token: token)
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        startTurn("steps 8")
        let done = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'shards read, no errors'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 90), "the steps turn did not finish")
        pause(2)
        let name = tool ? "tool card, keyboard up" : "reasoning, keyboard up"
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { XCTFail("\(name): can't judge: the keyboard isn't up before the tap"); return }
        guard let card = (tool ? cards(toolCard) : cards(showReasoning)).last else { XCTFail("\(name): no card above the bar"); return }
        // The card's frame before the tap is the probe's top at the tap (the probe's legs: 212.0 and 212.0, 250.0 and 250.0).
        let before = card.frame.minY
        if tool { card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 16)).tap() } else { card.tap() }
        pause(1.1)
        let all = probe().cards.values.flatMap { $0 }.sorted { $0.t < $1.t }
        let second = all.filter { $0.t <= 1.0 }.map(\.top)
        let early = [before] + all.filter { $0.t <= 0.6 }.map(\.top)
        let step = zip([before] + second, second).map { abs($1 - $0) }.max() ?? 0
        let drift = (early.max() ?? before) - (early.min() ?? before)
        let off = abs((early.last ?? before) - before)
        let up = keyboard.exists
        print("CARD-MOTION \(name): top \(String(format: "%.1f", before)) before, \(all.count) layouts; largest step \(String(format: "%.1f", step))"
              + " in 1.0 s; drift \(String(format: "%.1f", drift)), \(String(format: "%.1f", off)) off at 0.6 s; keyboard after \(up ? "up" : "down")")
        print("CARD-MOTION-ALL \(name): \(all.map { String(format: "%.2f:%.1f", $0.t, $0.top) }.joined(separator: " "))")
        XCTAssertGreaterThanOrEqual(second.count, 1, "\(name): the probe saw no layout")
        XCTAssertLessThanOrEqual(step, 24, "\(name): the card's top moved \(step) pt in one step: \(second)")
        XCTAssertLessThanOrEqual(drift, 8, "\(name): the card's top moved \(drift) pt in the first 0.6 s")
        XCTAssertLessThanOrEqual(off, 1, "\(name): at 0.6 s the card's top was \(off) pt from where it was")
        XCTAssertTrue(up, "\(name): the keyboard closed: a tap that opens a card leaves it up")
    }

    func testACardOpeningOrClosingKeepsItsPlace() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        launch(url: url, token: token)
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        startTurn("steps 8")
        let done = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'shards read, no errors'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 90), "the steps turn did not finish")
        pause(2)

        // Just above the message bar: the lowest card, the thread at its end.
        if let low = cards(showReasoning).last {
            toggleHolds(low, "reasoning above the bar, open")
            if let open = cards(hideReasoning).last { toggleHolds(open, "reasoning above the bar, close") }
        } else { XCTFail("no reasoning card above the bar") }

        // At the very end: the last tool card, opened and closed with the thread at its end.
        if let lastTool = cards(toolCard).last {
            toggleHolds(lastTool, "tool card at the end, open", header: true)
            lastTool.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 16)).tap(); pause(1.1)
            // Closing at the very end may bring the rows above down (the thread is shorter after it), in one motion.
            let t = tops()
            let steps = zip(t, t.dropFirst()).map { $1 - $0 }
            print("CARD-MOTION tool card at the end, close: \(t.count) layouts, steps \(steps.map { String(format: "%.1f", $0) })")
            XCTAssertFalse(steps.contains { $0 < -0.5 } && steps.contains { $0 > 0.5 }, "the close at the end went back and forth: \(t)")
        }

        // Mid-thread: up a little, then a card in the middle of the screen.
        app.swipeDown(velocity: .slow); pause(1.5)
        let mid = app.frame.height / 2
        if let card = cards(showReasoning).min(by: { abs($0.frame.midY - mid) < abs($1.frame.midY - mid) }) {
            toggleHolds(card, "reasoning mid-thread, open")
            if let open = cards(hideReasoning).min(by: { abs($0.frame.midY - mid) < abs($1.frame.midY - mid) }) {
                toggleHolds(open, "reasoning mid-thread, close")
            }
        } else { XCTFail("no reasoning card mid-thread") }
        if let tool = cards(toolCard).min(by: { abs($0.frame.midY - mid) < abs($1.frame.midY - mid) }) {
            toggleHolds(tool, "tool card mid-thread, open", header: true)
            toggleHolds(tool, "tool card mid-thread, close", header: true)
        } else { XCTFail("no tool card mid-thread") }

        // Rapid toggles: open, close, open on one card; then two cards; within the hold. No card moves and the hold ends.
        if let card = cards(showReasoning).min(by: { abs($0.frame.midY - mid) < abs($1.frame.midY - mid) }) {
            let at = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            at.tap(); at.tap(); at.tap()
            pause(1.6)
            let d = drifts(within: 1.0)
            for c in d { print("CARD-MOTION rapid one card: \(c.key) first at \(String(format: "%.2f", c.first)) s, \(c.count) layouts, drift \(String(format: "%.2f", c.drift))") }
            XCTAssertTrue(d.allSatisfy { $0.drift <= 0.5 }, "a card moved under rapid toggles: \(d)")
            XCTAssertFalse(probe().holding, "the hold stuck after rapid toggles")
            // Closed again if it was left open (three taps).
            if let open = cards(hideReasoning).first { open.tap(); pause(1.1) }
        }
        let two = cards(showReasoning)
        if two.count >= 2 {
            two[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            two[1].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            pause(1.6)
            let d = drifts(within: 1.0)
            for c in d { print("CARD-MOTION two cards: \(c.key) first at \(String(format: "%.2f", c.first)) s, \(c.count) layouts, drift \(String(format: "%.2f", c.drift))") }
            XCTAssertTrue(d.allSatisfy { $0.drift <= 0.5 }, "a card moved when two were toggled together: \(d)")
            XCTAssertFalse(probe().holding, "the hold stuck after two cards")
        }

        // While a turn streams below: a new turn, and a card of the last one opened and closed as it runs.
        startTurn("steps 10")
        pause(4)
        if let card = cards(showReasoning).first {
            toggleHolds(card, "reasoning while a turn streams, open")
            if let open = cards(hideReasoning).first { toggleHolds(open, "reasoning while a turn streams, close") }
        } else { XCTFail("no reasoning card on screen while the turn streamed") }

        // Following after the hold: back at the end, a card just above the bar toggled while the turn streams; once the
        // hold is over the thread follows the turn's end again (no "Jump to latest").
        let jump = app.buttons["Jump to latest"].firstMatch
        if jump.exists, jump.isHittable { jump.tap(); pause(1.5) }
        if let low = cards(showReasoning).last {
            toggleHolds(low, "reasoning near the end while a turn streams, open")
            var following = false
            for _ in 0..<8 { pause(0.5); if !(jump.exists && jump.isHittable) { following = true; break } }
            XCTAssertTrue(following, "the thread stopped following the turn after the hold")
            XCTAssertFalse(probe().holding, "the hold stuck")
        }
    }
}
