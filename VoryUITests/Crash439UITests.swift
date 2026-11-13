import XCTest

/// #439 (feedback on 1.5 (27)): in an old chat loaded from history, no turn running, expanding reasoning and tool cards,
/// and the sideways swipe that shows the times, froze the screen for about 30 s and then the app ended. Against the
/// mock's long coding chat (MOCK_CODING=n: steps that only think before each tool call, tool rows with output, code
/// replies, about ten rows a round), opened from the list: cards expanded a few screens up, then the times swipe, a
/// few times. The app's stall log is at 50 ms; the host samples the app if a C439 line is late and looks for a crash
/// report. The tree is read sparingly (one copy per screen) and taps go by coordinate, so the test's own reads load
/// the app as little as they can. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
@MainActor
final class Crash439UITests: XCTestCase {
    private var app: XCUIApplication!

    private func mark(_ s: String) { print(String(format: "C439 %.2f %@", Date().timeIntervalSince1970, s)) }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func launch() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats",
                               "-vory-perf-stall-ms", "50"]
        app.launch()
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let d = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !d.isEmpty {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: d).appendingPathComponent("\(name).png"))
        }
    }

    /// One copy of the tree: the folds in reach (tool cards and "Show reasoning", by their header row), the rows of
    /// the thread, and the top of the dock.
    /// A fold in reach: a "Show reasoning" button (tapped where it is) or a folded tool card (tapped as an element,
    /// found by its label: a tap by coordinate on a card's header did not always open it).
    enum Fold { case reasoning(CGPoint), card(String) }

    private func folds() -> (folds: [Fold], rows: Int, dockTop: CGFloat, open: Int) {
        guard let snap = try? app.snapshot() else { return ([], 0, 0, 0) }
        var out: [Fold] = [], rows = 0, open = 0
        var dockTop = snap.frame.maxY - 140
        var found: [(CGRect, String, Bool)] = []
        func walk(_ s: XCUIElementSnapshot) {
            if s.identifier == "chat.dock" { dockTop = s.frame.minY }
            if s.identifier.hasPrefix("thread.row.") { rows += 1 }
            if s.elementType == .button {
                if s.label == "Show reasoning" { found.append((s.frame, s.label, false)) }
                else if s.label == "Hide reasoning" { open += 1 }
                else if s.identifier.isEmpty, s.label.localizedCaseInsensitiveContains("terminal") || s.label.localizedCaseInsensitiveContains("read file") {
                    if s.frame.height > 200 { open += 1 } else { found.append((s.frame, s.label, true)) }
                }
            }
            for c in s.children { walk(c) }
        }
        walk(snap)
        for (f, label, card) in found where f.width > 0 && f.midY > 150 && f.midY < dockTop - 12 {
            out.append(card ? .card(label) : .reasoning(CGPoint(x: f.midX, y: f.midY)))
        }
        return (out, rows, dockTop, open)
    }

    private func tap(_ p: CGPoint, _ name: String) {
        let t0 = Date()
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y)).tap()
        mark(String(format: "tap %@ %.2f s", name, Date().timeIntervalSince(t0)))
    }

    /// The times swipe: a slow, level drag from right to left across the middle of the thread (well inside the
    /// screen, where a thumb starts it, and away from the edge gestures), held a moment, let go.
    private func timesSwipe(_ n: Int, dockTop: CGFloat) {
        let y = max(260, dockTop - 160)
        let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.7, dy: y))
        let to = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.3, dy: y))
        let t0 = Date()
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.6)
        mark(String(format: "times swipe %d %.2f s", n, Date().timeIntervalSince(t0)))
    }

    func testAnOldChatsCardsAndTheTimesSwipe() throws {
        try launch()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup' AND NOT (identifier BEGINSWITH 'chat.')")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "no chat list")
        row.tap()
        XCTAssertTrue(app.textViews["composer.text"].firstMatch.waitForExistence(timeout: 40), "the chat did not open")
        pause(5)
        var seen = folds()
        mark("OPENED \(seen.rows) rows in the tree, \(seen.folds.count) folds in reach")
        shot("439-opened")
        // Cards and reasoning opened, a few screens up the thread: one copy per screen, then the taps.
        var opened = 0
        for screen in 1...4 {
            for f in seen.folds.prefix(4) {
                switch f {
                case .reasoning(let p): tap(p, "open \(opened + 1)")
                case .card(let label):
                    let card = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
                    let t0 = Date()
                    if card.exists { card.tap() }
                    mark(String(format: "tap open %d %.2f s", opened + 1, Date().timeIntervalSince(t0)))
                }
                opened += 1; pause(0.6)
            }
            let check = folds()
            mark("SCREEN \(screen) done, \(opened) tapped, \(check.open) open in view")
            app.swipeDown(velocity: .slow)
            pause(1.5)
            seen = folds()
        }
        shot("439-opened-cards")
        // The times swipe, several times, with the thread at rest between them.
        for n in 1...6 { timesSwipe(n, dockTop: seen.dockTop); pause(1.2) }
        shot("439-after-swipes")
        mark("SWIPES done")
        let ok = app.textViews["composer.text"].firstMatch.waitForExistence(timeout: 15)
        mark("ALIVE \(ok ? "answers" : "GONE")")
        XCTAssertTrue(ok, "the app stopped answering")
    }
}
