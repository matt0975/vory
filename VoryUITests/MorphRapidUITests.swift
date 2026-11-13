import XCTest

/// Feedback on 1.5 (21): "This animation is choppy as well, can we smooth this up so it's fast, but
/// smooth and can handle going in and out of that fast". A chat opened from Chats and closed
/// again quickly, ten times over at 0.1 to 0.3 s, then the bar rests with one set of controls,
/// and its taps land: the list's +, a chat's Back. The run is recorded from outside
/// (`simctl io recordVideo`) for the frames in between.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=com.vorantx.vory.demo
/// drives the demo copy.
@MainActor
final class MorphRapidUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func launch(url: String, token: String) {
        let args = ["-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "light", "-chat.showBots", "YES"]
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
    private func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
    private func at(_ p: CGPoint) -> XCUICoordinate { app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y)) }

    /// The bar's controls at rest: which of the two sets is there, and whether each is hittable.
    private func barSet() -> String {
        let list = ["chats.newBot", "chats.sort", "chats.filters", "chats.profile"].filter { any($0).exists }
        let chat = ["chat.back", "chat.titlePill", "chat.more"].filter { any($0).exists }
        return "list \(list) chat \(chat)"
    }

    func testRapidInAndOutEndsWithOneSet() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "no chat rows")
        pause(2)
        // Where the row and the chat's Back are, from one slow open and close.
        let rowAt = CGPoint(x: row.frame.midX, y: row.frame.midY)
        at(rowAt).tap()
        let back = any("chat.back")
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the chat did not open")
        pause(1.5)
        let backAt = CGPoint(x: back.frame.midX, y: back.frame.midY)
        at(backAt).tap(); pause(1.5)
        print("MORPH-RAPID row \(rowAt) back \(backAt)")
        // In and out, quickly: the gaps cycle through 0.1, 0.2 and 0.3 s.
        let start = Date()
        print("MORPH-RAPID begin \(start.timeIntervalSince1970)")
        for i in 0..<10 {
            let gap = [0.1, 0.2, 0.3][i % 3]
            let t0 = Date().timeIntervalSince(start)
            at(rowAt).tap(); pause(gap)
            let t1 = Date().timeIntervalSince(start)
            at(backAt).tap(); pause(gap)
            print("MORPH-RAPID cycle \(i) in at \(String(format: "%.2f", t0)) out at \(String(format: "%.2f", t1)) gap \(gap)")
        }
        print("MORPH-RAPID end \(Date().timeIntervalSince1970)")
        pause(2)
        shot("rest-after-cycles")
        let rest = barSet()
        print("MORPH-RAPID at rest: \(rest)")
        // One set: the list's or the chat's, never both, never neither.
        let listShown = any("chats.newBot").exists, chatShown = any("chat.back").exists
        XCTAssertTrue(listShown != chatShown, "the bar rests with \(rest)")
        // Its taps land: whichever set it is, Back or the row and Back again.
        if chatShown {
            at(backAt).tap(); pause(1.5)
        }
        XCTAssertTrue(any("chats.newBot").isHittable, "the list's + is not hittable at rest: \(barSet())")
        at(rowAt).tap()
        XCTAssertTrue(any("chat.back").waitForExistence(timeout: 10), "the chat did not open after the cycles")
        pause(1.5)
        XCTAssertTrue(any("chat.back").isHittable && !any("chats.newBot").exists, "the chat's bar is not alone: \(barSet())")
        at(backAt).tap(); pause(1.5)
        XCTAssertTrue(any("chats.newBot").isHittable && !any("chat.back").exists, "Back did not bring the list's bar alone: \(barSet())")
    }
}
