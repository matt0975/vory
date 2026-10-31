import XCTest

/// The top bar's capsule controls (+, sort and filters on Chats; a page's own on a pushed page) are the capsule's
/// full height to hit and pass the audit's hit region. The sort arrows' glyph alone (24 × 19) was the hit area and
/// failed it (#340's run, on the closed Duo and the iPhone). Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
final class BarHitAreaUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty else { return nil }
        return (url, token)
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty {
            let d = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
        }
    }

    func testTheChatsCapsulesControlsAreTheBarsHeightToHit() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        let args = ["-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "light"]
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
        let sort = any("chats.sort")
        guard sort.waitForExistence(timeout: 30) else {
            // The wide layout keeps sort and filters in the View menu, with the system's own bar.
            if app.windows.firstMatch.frame.width > 700 { throw XCTSkip("the morph bar is the phone's") }
            return XCTFail("no sort control on Chats")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("bar-hit-chats")
        for id in ["chats.newBot", "chats.sort", "chats.filters"] {
            let f = any(id).frame
            print("BAR-HIT \(id) \(f)")
            XCTAssertGreaterThanOrEqual(f.height, 44, "\(id) is \(f.height) pt tall to hit")
            XCTAssertGreaterThanOrEqual(f.width, 20, "\(id) is \(f.width) pt wide to hit")
            XCTAssertTrue(any(id).isHittable, "\(id) can't be reached")
        }
        // The audit, in the bar's band: nothing there may be too small to hit or go unnamed.
        let band = sort.frame.maxY + 8
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription]) { issue in
            print("BAR-AUDIT '\(issue.compactDescription)' label '\(issue.element?.label ?? "")' id '\(issue.element?.identifier ?? "")' frame \(issue.element?.frame ?? .zero)")
            return (issue.element?.frame.minY ?? 0) > band
        }
    }
}
