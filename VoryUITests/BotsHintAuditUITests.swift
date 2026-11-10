import XCTest

/// The Bots page's hint line ("Each bot is a Hermes profile: ...") is words, not a control, so the hit-region audit must not
/// report it as a tap target that's too small (#652). Where the line fits on one line, as on the iPad either way up and on
/// the open Duo upright, it's about 16 pt tall, and the audit reported it there. Each test judges only a one-line hint
/// (under 30 pt tall); where the line wraps, as on any iPhone, it skips and says so, so it can't pass on a line the audit
/// never reported. Every finding on the page is printed ("BOTSHINT-AUDIT ..."); only one on the hint fails. Skipped unless
/// HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock gateway); drives the demo copy.
@MainActor
final class BotsHintAuditUITests: XCTestCase {
    private static let words = "Each bot is a Hermes profile"

    func testTheHintIsNotATapTargetUpright() throws { try check(onItsSide: false) }
    func testTheHintIsNotATapTargetOnItsSide() throws { try check(onItsSide: true) }

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func check(onItsSide: Bool) throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        let pose = onItsSide ? "landscape" : "portrait"
        // Each test starts and ends upright (no tearDown: XCTest runs it off the main actor, and setting the orientation
        // there is a Swift 6 warning).
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "bots",
                               "-colorSchemePreference", "light"]
        app.launch()
        let words = Self.words
        let hint = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
        if !hint.waitForExistence(timeout: 40) {
            let tab = app.descendants(matching: .any).matching(identifier: "tab.bots").firstMatch
            if tab.waitForExistence(timeout: 10) { tab.tap() }
        }
        guard hint.waitForExistence(timeout: 30) else { XCTFail("no hint line on the Bots page (\(pose))"); return }
        if onItsSide { XCUIDevice.shared.orientation = .landscapeLeft; pause(2.5) }
        pause(2)
        bringOnScreen(hint, in: app)
        let frame = hint.frame
        print("BOTSHINT \(pose): window \(app.windows.firstMatch.frame) hint \(frame) hittable \(hint.isHittable) label '\(hint.label)'")
        // The words are still there to be read.
        XCTAssertTrue(hint.label.contains("one for its chats"), "the hint's words changed (\(pose)): '\(hint.label)'")
        var findings = 0
        var onHint: [String] = []
        try app.performAccessibilityAudit(for: [.hitRegion]) { issue in
            findings += 1
            let el = issue.element
            let isHint = el?.label.hasPrefix(words) ?? false
            if isHint { onHint.append(issue.compactDescription) }
            print("BOTSHINT-AUDIT \(pose) '\(issue.compactDescription)' type \(el?.elementType.rawValue ?? 0) id '\(el?.identifier ?? "")'"
                  + " label '\(el?.label ?? "")' frame \(el.map { "\($0.frame)" } ?? "-")\(isHint ? " is the hint" : "")")
            return true
        }
        print("BOTSHINT \(pose): audit done, \(findings) findings, \(onHint.count) on the hint")
        guard frame.height < 30 else {
            print("BOTSHINT \(pose): skipped, the hint wraps (\(frame.height) pt tall)")
            throw XCTSkip("the hint wraps here (\(Int(frame.height.rounded())) pt tall); only a one-line hint is judged")
        }
        XCTAssertEqual(onHint, [], "the audit reports the Bots hint as a tap target (\(pose)): \(onHint.joined(separator: "; "))")
    }

    /// A short landscape screen can hold the line below the grid: up to three small drags bring it on screen.
    private func bringOnScreen(_ hint: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 {
            let f = hint.frame, w = app.frame
            if hint.exists, f.minY >= w.minY + 60, f.maxY <= w.maxY - 60 { return }
            let win = app.windows.firstMatch
            win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            pause(1)
        }
    }
}
