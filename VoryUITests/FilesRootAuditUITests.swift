import XCTest

/// Files' root passes the accessibility audit, its bar's Home circle with the rest (the top bar's round buttons take a
/// square tap area, 2026-11-01). On a phone's layout the Home circle must be there; on a wide window (the iPad) the bar is
/// the system's, so the root is audited without it. Printed, not failed here: the gate holds the fix's issues against the
/// base's, as for the chat's audit ("AUDIT duo-<pose> files …" for each issue, then "… files done, N issues so far";
/// HERMES_E2E_POSE names the Duo's pose, "elsewhere" otherwise). Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
@MainActor
final class FilesRootAuditUITests: XCTestCase {
    func testTheFilesRootPassesTheAudit() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        let app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "files",
                               "-tabLayout", "chats,files,bots,settings", "-tabLayout.homeFirstApplied", "YES", "-colorSchemePreference", "light"]
        app.launch()
        let any = { (id: String) in app.descendants(matching: .any).matching(identifier: id).firstMatch }
        let tab = any("tab.files")
        XCTAssertTrue(tab.waitForExistence(timeout: 40), "no Files tab")
        let wide = app.windows.firstMatch.frame.width > 700
        let home = any("files.home")
        if !home.waitForExistence(timeout: 5) { tab.tap() }
        if wide { _ = home.waitForExistence(timeout: 5) }
        else { XCTAssertTrue(home.waitForExistence(timeout: 10), "no Home circle in Files' bar") }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        print("FILES window \(app.windows.firstMatch.frame) home \(home.exists ? "\(home.frame) hittable \(home.isHittable)" : "none")")
        let pose = e["HERMES_E2E_POSE"].flatMap { $0.isEmpty ? nil : $0 } ?? "elsewhere"
        var issues = 0
        try app.performAccessibilityAudit { issue in
            issues += 1
            let el = issue.element
            print("AUDIT duo-\(pose) files \(issue.auditType) '\(el?.identifier ?? "")' '\(el?.label ?? "")' \(el.map { "\($0.frame)" } ?? "-") \(issue.compactDescription)")
            return true
        }
        print("AUDIT duo-\(pose) files done, \(issues) issues so far")
        app.terminate()
    }
}
