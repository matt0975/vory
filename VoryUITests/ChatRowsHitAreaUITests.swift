import XCTest

/// The thread's working row passes the audit's hit region and names: its spinner was an element with no name and a
/// 14-point hit area. Found by onboarding's gate (#388), which shows the app's chat. The reasoning row's button is its
/// caption's 15 points to hit (#482, a separate change): only that hit region is left out of this audit. Run on the
/// iPhone and the iPad. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
final class ChatRowsHitAreaUITests: XCTestCase {
    private var app: XCUIApplication!

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            pause(0.2)
        } while Date() < deadline
        return nil
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty {
            let d = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
        }
    }

    /// The audit of the thread, between the bar's band and the message bar: anything there fails.
    private func auditThread(_ stage: String) throws {
        let window = app.windows.firstMatch.frame
        let dock = app.otherElements["chat.dock"].firstMatch
        let bottom = dock.exists ? dock.frame.minY : window.maxY - 120
        let top: CGFloat = 120
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription]) { issue in
            let f = issue.element?.frame ?? .zero
            print("CHAT-AUDIT \(stage) '\(issue.compactDescription)' label '\(issue.element?.label ?? "")' id '\(issue.element?.identifier ?? "")' frame \(f)")
            let inThread = f.minY >= top && f.maxY <= bottom && f.width > 0
            // The reasoning row's button is 15 points to hit: #482, its own change, takes this out. Only that hit
            // region: any other issue on it still fails.
            let reasoningHitRegion = issue.auditType == .hitRegion && ["Show reasoning", "Hide reasoning"].contains(issue.element?.label ?? "")
            return !inThread || reasoningHitRegion
        }
    }

    func testTheThreadsWorkingRowPassesTheAudit() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        if let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "light"]
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-launchTab", "chats", "-colorSchemePreference", "light"]
        }
        app.launch()
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup' AND identifier != 'chat.titlePill'"))
        try XCTUnwrap(hittable(rows, timeout: 40), "no Disk cleanup row").tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "no composer")
        composer.tap(); composer.typeText("Think it through: which logs can go?")
        try XCTUnwrap(hittable(app.buttons.matching(identifier: "composer.send"), timeout: 5), "no send").tap()
        // While it works: the working row, its spinner and words.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "thread.status").firstMatch.waitForExistence(timeout: 20), "no working row")
        shot("chat-rows-working")
        try auditThread("working")
    }
}
