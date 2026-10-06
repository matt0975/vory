import XCTest

/// Rows of the thread must never be drawn over one another, while a turn streams or after it:
/// testers sent screenshots of a reply drawn over their own bubble and of tool cards stacked
/// over the reply's text mid-turn. The mock gateway answers a prompt starting "tools" with a long
/// turn that is mostly tool calls (a dozen cards, words between some of them, a long answer);
/// three of them in a row make a thread long enough for its older rows to go lazy while the
/// newest one streams. Every row is an element named "thread.row.<kind>" (the typing bubble and
/// the status line are "thread.typing" and "thread.status"), so each check compares the frames
/// of neighbours in thread order: the next one must start below the one before it ends.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=com.vorantx.vory.demo
/// drives the demo copy (Tools/dev/make-demo-app-sim.sh), pointed at the gateway by launch
/// argument. HERMES_E2E_SHOTS names a folder for the screenshots.
@MainActor
final class ThreadLayoutUITests: XCTestCase {
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

    private func cell(_ fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
    }

    private struct Row { var id: String; var frame: CGRect }

    /// The thread's rows in thread order, from one snapshot of the app.
    private func threadRows() -> [Row] {
        guard let snap = try? app.snapshot() else { return [] }
        var out: [Row] = []
        func walk(_ s: XCUIElementSnapshot) {
            if s.identifier.hasPrefix("thread.") { out.append(Row(id: s.identifier, frame: s.frame)); return }
            for c in s.children { walk(c) }
        }
        walk(snap)
        return out
    }

    /// Neighbours that are drawn over each other: the later row starts above the end of the one
    /// before it (a point of slack for rounding).
    private func overlaps(_ rows: [Row]) -> [String] {
        zip(rows, rows.dropFirst()).compactMap { a, b in
            guard a.frame.height > 0, b.frame.height > 0, b.frame.minY < a.frame.maxY - 1 else { return nil }
            return "\(a.id) y \(Int(a.frame.minY))...\(Int(a.frame.maxY)) then \(b.id) y \(Int(b.frame.minY))...\(Int(b.frame.maxY))"
        }
    }

    private var problems: [String] = []
    private var overlapShots = 0
    private var checks = 0

    private func check(_ label: String) {
        let rows = threadRows()
        checks += 1
        let bad = overlaps(rows)
        guard !bad.isEmpty else { return }
        problems += bad.map { "\(label): \($0)" }
        for b in bad { print("THREAD-OVERLAP \(label): \(b)") }
        if overlapShots < 8 { overlapShots += 1; shot("thread-overlap-\(overlapShots)-\(label)") }
    }

    /// Sends a "tools" turn and checks the rows over and over while it streams, until its last
    /// words are on screen.
    private func streamTurn(_ n: Int) {
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("tools: check the whole host, pass \(n)")
        // The turn runs while the composer offers Stop; it is over once Stop has come and gone.
        let stop = app.buttons["Stop"].firstMatch
        let send = app.buttons["composer.send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        send.tap()
        var sentAt = Date()
        let deadline = Date().addingTimeInterval(90)
        var lastShot = Date.distantPast
        var frame = 0
        var running = false
        while Date() < deadline {
            check("turn\(n)")
            if Date().timeIntervalSince(lastShot) > 3 { frame += 1; shot("thread-turn\(n)-\(frame)"); lastShot = Date() }
            if stop.exists { running = true } else if running { break }
            // A tap that landed while the button was still changing from the mic: once more.
            if !running, Date().timeIntervalSince(sentAt) > 8, send.exists, send.isHittable { send.tap(); sentAt = Date() }
        }
        XCTAssertTrue(running, "turn \(n) never started")
        XCTAssertTrue(cell("start with the first two").exists, "turn \(n) did not finish")
        // The rest after a turn is when older rows move into the lazy stack: checked through it.
        let rest = Date().addingTimeInterval(2.5)
        while Date() < rest { check("turn\(n)-settling") }
        shot("thread-turn\(n)-done")
    }

    func testRowsNeverOverlapWhileATurnOfToolCardsStreams() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        launch(url: url, token: token)
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()

        for n in 1...3 { streamTurn(n) }
        XCTAssertGreaterThan(threadRows().filter { $0.id == "thread.row.tool" }.count, 6, "the tool cards are not on screen as rows")

        // Up the thread and back: rows the lazy stack draws for the first time must not land on
        // their neighbours either.
        for i in 1...6 {
            app.swipeDown(velocity: .fast)
            sleep(1)
            check("up\(i)")
        }
        shot("thread-scrolled-up")
        for i in 1...8 {
            app.swipeUp(velocity: .fast)
            sleep(1)
            check("down\(i)")
        }
        shot("thread-back-down")
        print("THREAD-LAYOUT checks \(checks), problems \(problems.count)")
        XCTAssertGreaterThan(checks, 30, "too few checks to mean anything")
        XCTAssertTrue(problems.isEmpty, "rows drawn over each other:\n" + problems.prefix(20).joined(separator: "\n"))
    }
}
