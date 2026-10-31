import XCTest
import UserNotifications

/// The demo's notifications (#501, Matt's call): its first message asks for notification permission, once, as nothing
/// else in the demo would; with permission, its replies and approvals are local notifications, and Leave demo takes them
/// away. The question is Springboard's alert. Run on the demo copy as installed fresh (the question not yet answered);
/// skipped unless HERMES_E2E_BUNDLE is set.
@MainActor
final class DemoNotificationsUITests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func launch(_ extra: [String] = []) throws {
        guard let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("HERMES_E2E_BUNDLE not set")
        }
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo", "-companionPromptShown", "YES", "-launchTab", "chats"] + extra
        app.launch()
    }

    private func openChat() {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Packing list' AND NOT (identifier BEGINSWITH 'chat.')")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the demo's chats did not load")
        row.tap()
        XCTAssertTrue(any("composer.text").waitForExistence(timeout: 20), "no composer")
        pause(1)
    }

    /// Types and sends, once Send can be pressed (not while a reply is still running).
    private func send(_ text: String) {
        let field = any("composer.text")
        field.tap()
        field.typeText(text)
        let send = app.buttons["composer.send"].firstMatch
        let deadline = Date().addingTimeInterval(30)
        while !(send.exists && send.isEnabled && send.isHittable), Date() < deadline { pause(0.3) }
        send.tap()
    }

    /// One run, in order, as the steps depend on each other: the question comes on the first message only (the
    /// system asks once, so a second test could not start unanswered); then, with permission, the approval turn is
    /// sent and the app put away before its card comes (a card that comes in front is a buzz, not a notification);
    /// then Leave demo takes its notifications away, delivered and pending.
    func testTheDemoAsksOnItsFirstMessageAndItsApprovalIsALocalNotificationThatLeavingTakesAway() throws {
        try launch(["-vory-delivered-readout"])
        let readout = any("debug.delivered")
        // "delivered/pending/most/read": `read` is the app's own read of the notification settings (-1 until it has come).
        func parts() -> [Int] { (readout.value as? String ?? "").split(separator: "/").compactMap { Int($0) } }
        func counts() -> (delivered: Int, pending: Int, most: Int) {
            let p = parts()
            return p.count == 4 ? (p[0], p[1], p[2]) : (-1, -1, -1)
        }
        openChat()

        // The app's own read of the settings first: after a boot the system's first read can take more than ten seconds,
        // and the question waits for it (seen 2026-10-21: the ask fired on the first message, the read had not returned
        // ten seconds later). Undetermined, as a fresh install is; then the question must come within ten seconds.
        XCTAssertTrue(readout.waitForExistence(timeout: 10), "no readout")
        let settled = Date().addingTimeInterval(60)
        while (parts().count == 4 ? parts()[3] : -1) < 0, Date() < settled { pause(0.5) }
        XCTAssertEqual(parts().count == 4 ? parts()[3] : -1, Int(UNAuthorizationStatus.notDetermined.rawValue),
                       "the settings' read never came, or the question was already answered (readout \(readout.value as? String ?? "none"))")

        send("hello")
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no notification question after the demo's first message")
        let allow = alert.buttons["Allow"].firstMatch
        XCTAssertTrue(allow.exists, "the question has no Allow")
        allow.tap()
        pause(8)   // the reply runs to its end
        send("thanks")
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 5), "the demo asked again on its second message")
        pause(8)

        // The turn with an approval (`DemoContent.cleanup`), the app away before its card comes.
        send("What's taking up the most space on my server?")
        XCUIDevice.shared.press(.home)
        // The approval's notification, as the person would see it while away.
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'approval needed'")).firstMatch
        let shown = banner.waitForExistence(timeout: 20)
        add({ let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = "away"; a.lifetime = .keepAlways; return a }())
        app.activate()
        XCTAssertTrue(readout.waitForExistence(timeout: 10), "no readout")
        XCTAssertTrue(shown || counts().most >= 1, "the demo's approval posted no local notification while the app was away (readout \(readout.value as? String ?? "none"))")

        // Out of the chat (its bar hides the tabs), then Settings, Leave demo.
        let back = app.buttons["chat.back"].firstMatch
        if back.waitForExistence(timeout: 5) { back.tap(); pause(1) }
        let settings = app.buttons["tab.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let leave = app.buttons["settings.leaveDemo"].firstMatch
        XCTAssertTrue(leave.waitForExistence(timeout: 10))
        leave.tap()
        pause(2.5)
        let left = counts()
        XCTAssertEqual(left.delivered, 0, "Leave demo left its delivered notifications")
        XCTAssertEqual(left.pending, 0, "Leave demo left pending notifications")
        print("DEMO-NOTIFY banner \(shown) readout \(readout.value as? String ?? "none")")
        app.terminate()
    }
}
