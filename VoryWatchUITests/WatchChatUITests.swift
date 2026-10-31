import XCTest

/// The chat screen on its feed (#387 range B), at every size and mode the harness runs. Unpaired, the Watch reads the
/// mock on its own socket. A chat from the list opens at its end; a turn started on the gateway after that first read
/// (the mock's /mock/start-turn) brings an approval card, answered with the names the iPhone uses (#36).
final class WatchChatUITests: WatchUITestCase {
    /// The export chat open, past its first read.
    private func openExportChat() throws { try openChat("Rewrite the nightly export job", rows: "export") }

    /// The chat titled `title` open, past its first read (a row containing `rows` on screen).
    private func openChat(_ title: String, rows: String) throws {
        try launch()
        XCTAssertTrue(button("Settings").waitForExistence(timeout: 40), "no start screen")
        // The chat's row: at the largest text the start screen shows one chat, and the list makes the rest only as they
        // come into view. Swipes went past it (the row ending above the screen), short drags cancelled each other out,
        // small crown turns (0.15) barely moved the list, and a half turn could leave it under the title bar, where a
        // tap at its centre opened Settings (45 mm, ax). So the crown turns until enough of the row shows below the
        // title bar (back again if it went past), and the tap lands on the middle of what shows.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        _ = row.waitForExistence(timeout: 10)
        let window = app.windows.firstMatch.frame
        let below = CGRect(x: window.minX, y: window.minY + 60, width: window.width, height: window.height - 60)
        func shown() -> CGRect { row.exists ? row.frame.intersection(below) : .null }
        for _ in 0..<16 where shown().isNull || shown().height < 24 {
            let past = row.exists && row.frame.midY < below.minY
            XCUIDevice.shared.rotateDigitalCrown(delta: past ? -0.3 : 0.4)
            sleep(1)
        }
        let part = shown()
        if part.isNull || part.height < 24 {
            shot("chat-no-row")
            mark("chat-no-row tree:\n\(app.debugDescription)")
        }
        XCTAssertFalse(part.isNull || part.height < 24, "no chat list")
        sleep(1)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: part.midX, dy: part.midY)).tap()
        // The field by its identifier: a TextField's "Message" is its placeholder, which the queries don't match on.
        // Missing, the screen as it was goes in the log and the shots.
        let bar = any("watch.chat.message")
        if !bar.waitForExistence(timeout: 20) {
            shot("chat-no-bar")
            mark("chat-no-bar tree:\n\(app.debugDescription)")
        }
        XCTAssertTrue(bar.exists, "no message bar in the chat")
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", rows)).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "no rows in the chat")
        sleep(2)
    }

    /// A turn in the open chat, as if its prompt had been sent from elsewhere.
    private func startTurn(_ prompt: String, in session: String = "nightly export") async throws {
        let base = ProcessInfo.processInfo.environment["HERMES_E2E_URL"] ?? ""
        var c = try XCTUnwrap(URLComponents(string: base + "/mock/start-turn"))
        c.queryItems = [URLQueryItem(name: "session", value: session), URLQueryItem(name: "prompt", value: prompt)]
        let (_, response) = try await URLSession.shared.data(from: try XCTUnwrap(c.url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "the mock did not start the turn")
    }

    /// The screen's controls each have a name and a hit area a finger can take, and can be reached. Checked through
    /// the element queries: the system's accessibility audit is not one watchOS UI tests run. The system's own Back
    /// (its navigation bar's, which names itself a moment after the push) is the system's. Every control is listed in
    /// the log, and every problem in one failure.
    private func checkControls(_ stage: String, minimum: CGFloat = 28) {
        let window = app.windows.firstMatch.frame
        var problems: [String] = []
        for b in app.buttons.allElementsBoundByIndex where b.exists && b.frame.width > 0 && window.intersects(b.frame) {
            mark("control \(stage) '\(b.label)' id '\(b.identifier)' \(b.frame) hittable \(b.isHittable)")
            guard b.identifier != "BackButton" else { continue }
            if b.label.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("a button with no name at \(b.frame) (id '\(b.identifier)')") }
            if b.frame.width < minimum || b.frame.height < minimum { problems.append("'\(b.label)' is too small to hit: \(b.frame)") }
        }
        XCTAssertTrue(problems.isEmpty, "\(stage): \(problems.joined(separator: "; "))")
    }

    func testAChatOpensAtItsEnd() throws {
        try openExportChat()
        mark("chat open")
        shot("chat")
        checkControls("chat")
        checkEndsAboveTheBar()
    }

    /// The chat's title is one still line, cut at its end, clear of Back and Stop, and reads whole to VoiceOver. The
    /// system's title of a long chat ran as a marquee under Back ("…k cleanup"): its frame grew and shrank as it moved,
    /// so the frame is read three times, two seconds apart, and must not change its width.
    func testTheTitleStaysClearOfTheBarsButtons() async throws {
        try openExportChat()
        let full = "Rewrite the nightly export job"
        let title = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'watch.chat.title' OR (elementType == %d AND label == %@)", XCUIElement.ElementType.staticText.rawValue, full))
            .firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "no title")
        XCTAssertEqual(title.label, full, "the title doesn't read whole")
        var widths: [CGFloat] = []
        for pass in 0..<3 {
            let t = title.frame
            widths.append(t.width)
            mark("title pass \(pass) \(t)")
            for b in app.buttons.allElementsBoundByIndex where b.exists && b.frame.width > 0 && b.frame.minY < t.maxY + 4 {
                guard b.identifier != "watch.chat.title" else { continue }
                XCTAssertFalse(t.intersects(b.frame.insetBy(dx: 1, dy: 1)), "the title \(t) runs under '\(b.label)' \(b.frame)")
            }
            shot("chat-title-\(pass)")
            if pass < 2 { sleep(2) }
        }
        XCTAssertLessThan((widths.max() ?? 0) - (widths.min() ?? 0), 0.5, "the title moves (a marquee): widths \(widths)")
    }

    /// Brief points 1 and 4: at rest the conversation ends above the composer, its last line never under the bar.
    private func checkEndsAboveTheBar() {
        let field = any("watch.chat.message")
        let bar = app.toolbars.firstMatch
        let barTop = min(field.exists ? field.frame.minY : .infinity, bar.exists ? bar.frame.minY : .infinity)
        let window = app.windows.firstMatch.frame
        let lines = app.scrollViews.firstMatch.staticTexts.allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 0 && $0.frame.minY < window.maxY }
        let lastLine = lines.map(\.frame.maxY).max() ?? 0
        mark("rest: the last line ends at \(lastLine), the bar starts at \(barTop)")
        XCTAssertTrue(barTop.isFinite, "no bar to measure against")
        XCTAssertLessThanOrEqual(lastLine, barTop + 1, "the conversation runs under the composer")
    }

    func testAnApprovalArrivesWithTheNamesTheIPhoneUses() async throws {
        try openExportChat()
        try await startTurn("morph")
        let allow = app.buttons["Allow once"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 30), "no approval card arrived")
        XCTAssertTrue(app.buttons["Deny"].firstMatch.exists, "the card has no Deny")
        sleep(1)
        mark("card arrived")
        shot("chat-card")
        checkControls("card")
        XCTAssertTrue(allow.isHittable, "Allow once cannot be reached")
        // The bar gives way to the card, as the iPhone's dock turns into it, and comes back with the answer.
        XCTAssertFalse(any("watch.chat.message").exists, "the message bar stays over the card")
        allow.tap()
        XCTAssertTrue(allow.waitForNonExistence(timeout: 20), "Allow once did not answer the card")
        XCTAssertTrue(any("watch.chat.message").waitForExistence(timeout: 10), "the message bar didn't come back after the answer")
        sleep(2)
        shot("chat-card-answered")
    }

    /// Onboarding's Watch picture (#388 beat 5, `TourWatch`): the mock's tour ask in "Disk cleanup on the log host", as
    /// the Watch shows it. Made by Tools/dev/tour-frames.sh; skipped unless TOUR_FRAMES_OUT names the folder.
    func testTheToursAskOnTheWatch() async throws {
        guard let out = ProcessInfo.processInfo.environment["TOUR_FRAMES_OUT"], !out.isEmpty else { throw XCTSkip("TOUR_FRAMES_OUT not set") }
        try openChat("Disk cleanup on the log host", rows: "disk")
        try await startTurn("tour", in: "disk cleanup")
        XCTAssertTrue(app.buttons["Allow once"].firstMatch.waitForExistence(timeout: 30), "no approval card arrived")
        sleep(2)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: out).appendingPathComponent("TourWatch.png"))
        shot("TourWatch")
    }
}
