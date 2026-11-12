import XCTest

/// Feedback on 1.5 (21): "when holding a message the tail comes back weird after the animation". The
/// tail reached past the bubble's bounds, so the lift cut it off and it grew back a few frames
/// after the menu closed. Frames of the lift and the return are kept for the person's tailed
/// bubble, the bot's untailed and tailed ones, in light and dark; at rest the chat is kept whole
/// for comparing builds.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=com.vorantx.vory.demo
/// drives the demo copy.
@MainActor
final class BubbleLiftUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func launch(url: String, token: String, scheme: String) {
        let args = ["-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", scheme]
            + (ProcessInfo.processInfo.environment["HERMES_E2E_ARGS"] ?? "").split(separator: " ").map(String.init)
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func keep(_ s: XCUIScreenshot, _ name: String) { let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a) }

    /// The Disk cleanup chat, open and at rest at its end.
    private func openChat(_ url: String, _ token: String, _ scheme: String) {
        if app != nil { app.terminate() }
        launch(url: url, token: token, scheme: scheme)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "no chat rows")
        pause(1.5)
        row.tap()
        XCTAssertTrue(any("chat.dock").waitForExistence(timeout: 20), "the chat did not open")
        pause(2.5)
    }

    /// `text` brought to the middle of the screen by slow drags of the thread, clear of the bars.
    private func centre(_ text: XCUIElement) {
        for _ in 0..<8 {
            guard text.exists else { app.swipeDown(velocity: .slow); pause(1); continue }
            let delta = 420 - text.frame.midY
            if abs(delta) < 40 { break }
            let step = max(-300, min(300, delta + (delta > 0 ? 10 : -10)))
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: step > 0 ? 300 : 600))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: step)), withVelocity: .slow, thenHoldForDuration: 0.5)
            pause(1)
        }
    }

    /// Press and hold on `text`'s bubble: frames while it lifts and once the menu closes. `item` is
    /// in that bubble's menu only ("Edit & resend" for the person's, "Speak" for the bot's), so a
    /// press that landed on another bubble fails.
    private func lift(_ name: String, _ text: XCUIElement, item: String) {
        guard text.waitForExistence(timeout: 5) else { XCTFail("no \(name) bubble"); return }
        centre(text)
        print("BUBBLE-LIFT \(name) at \(text.frame)")
        keep(XCUIScreen.main.screenshot(), "\(name)-rest")
        nonisolated(unsafe) var up: [XCUIScreenshot] = []
        for t in stride(from: 0.3, through: 1.5, by: 0.15) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { up.append(XCUIScreen.main.screenshot()) } }
        }
        print("BUBBLE-PRESS \(name) at \(Date().timeIntervalSince1970)")
        let at = text.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: at.midX, dy: at.midY)).press(forDuration: 1.0); pause(1.2)
        for (i, s) in up.enumerated() { keep(s, "\(name)-lift-\(i)") }
        XCTAssertTrue(app.buttons[item].exists, "the \(name) bubble's menu did not open (no \(item))")
        nonisolated(unsafe) var back: [XCUIScreenshot] = []
        // The tap itself takes a moment to land: the window runs well past it.
        for t in stride(from: 0.1, through: 2.2, by: 0.06) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { MainActor.assumeIsolated { back.append(XCUIScreen.main.screenshot()) } }
        }
        // For a screen recording of the run: when each return starts, in wall-clock time.
        print("BUBBLE-BACK \(name) at \(Date().timeIntervalSince1970)")
        // Beside the lifted bubble, on the side its menu does not take (a tap at the top hit the
        // menu's Reply when it opened upward).
        let side: CGFloat = at.midX < app.frame.midX ? 0.97 : 0.03
        app.coordinate(withNormalizedOffset: CGVector(dx: side, dy: 0.5)).tap(); pause(2.4)
        for (i, s) in back.enumerated() { keep(s, "\(name)-back-\(i)") }
    }

    func testTheBubblesLiftWithTheirTails() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        for scheme in ["light", "dark"] {
            openChat(url, token, scheme)
            keep(XCUIScreen.main.screenshot(), "\(scheme)-chat-rest")
            // The last reply: the bot's tailed bubble.
            lift("\(scheme)-bot-tailed", app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Done")).firstMatch, item: "Speak")
            // Up the thread: the person's tailed bubble, and the bot's first reply, untailed (the
            // last one of its run carries the tail).
            lift("\(scheme)-user-tailed", app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "The log host")).firstMatch, item: "Edit & resend")
            lift("\(scheme)-bot-untailed", app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "I'll look at what")).firstMatch, item: "Speak")
        }
    }
}
