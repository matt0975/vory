import XCTest

/// #668: Settings › Troubleshooting's new row (Crash and freeze reports) and its page pass the accessibility audit, for the
/// gate's three types (sufficientElementDescription, hitRegion, elementDetection), the page filled by the DEBUG fixture
/// (`-vory-health-fixture`: one day's counts, a crash and a freeze, nothing written). It fails only on issues in the new
/// row or anywhere on the new page, and prints every issue ("AUDIT <device> troubleshooting|reports NEW|old …"), the rest
/// of Troubleshooting's for the record, as the gate asks. FilesRootAuditUITests' launch. Skipped unless HERMES_E2E_URL /
/// HERMES_E2E_TOKEN are set.
@MainActor
final class HealthReportsAuditUITests: XCTestCase {
    private let types: XCUIAccessibilityAuditType = [.sufficientElementDescription, .hitRegion, .elementDetection]

    func testTheReportsRowAndPagePassTheAudit() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        let app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "settings",
                               "-tabLayout", "chats,files,bots,settings", "-tabLayout.homeFirstApplied", "YES", "-colorSchemePreference", "light",
                               "-vory-health-fixture"]
        app.launch()
        let any = { (id: String) in app.descendants(matching: .any).matching(identifier: id).firstMatch }
        let tab = any("tab.settings")
        XCTAssertTrue(tab.waitForExistence(timeout: 40), "no Settings tab")
        let device = app.windows.firstMatch.frame.width > 700 ? "ipad" : "iphone"
        let troubleshooting = any("settings.row.troubleshooting")
        if !troubleshooting.waitForExistence(timeout: 5) { tab.tap() }
        // Down Settings' list to Troubleshooting, as BarUpUITests does.
        for _ in 0..<12 where !(troubleshooting.exists && troubleshooting.isHittable) {
            let w = app.windows.firstMatch
            w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 0.05,
                thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)), withVelocity: .slow, thenHoldForDuration: 0.3)
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        }
        XCTAssertTrue(troubleshooting.isHittable, "Troubleshooting not reached")
        troubleshooting.tap()
        let row = any("troubleshooting.healthReports")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Crash and freeze reports row")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        var flagged: [String] = []
        let rowFrame = row.frame.insetBy(dx: -2, dy: -2)
        try app.performAccessibilityAudit(for: types) { issue in
            let el = issue.element
            let new = el.map { $0.identifier == "troubleshooting.healthReports" || rowFrame.contains($0.frame) } ?? false
            let line = "\(issue.auditType) '\(el?.identifier ?? "")' '\(el?.label ?? "")' \(el.map { "\($0.frame)" } ?? "-") \(issue.compactDescription)"
            print("AUDIT \(device) troubleshooting \(new ? "NEW" : "old") \(line)")
            if new { flagged.append("troubleshooting: \(line)") }
            return true
        }

        row.tap()
        let page = any("healthReports.page")
        XCTAssertTrue(page.waitForExistence(timeout: 10), "the page didn't open")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        // Everything on the page is new: an issue counts unless its element lies wholly in the shared bars, found as elements
        // the way the base's tests find them (the top bar, morph.bar, or the system's on a wide window; Vory's tab bar, by its
        // tab.* buttons), or wholly outside the page's own frame (healthReports.page: on a wide window, the columns beside it).
        // An issue with no element counts. Audited at its top, then at its foot: on a phone the fixture's page runs past the
        // screen, and a lazy list's rows off screen aren't there to audit (#668's first iPhone run).
        func auditPage(_ at: String) throws {
            var bars: [CGRect] = []
            if any("morph.bar").exists { bars.append(any("morph.bar").frame) }
            if app.navigationBars.firstMatch.exists { bars.append(app.navigationBars.firstMatch.frame) }
            let tabs = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
                .allElementsBoundByIndex.filter(\.exists).map(\.frame)
            if let first = tabs.first { bars.append(tabs.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -8, dy: -8)) }
            let pageFrame = page.exists ? page.frame : app.windows.firstMatch.frame
            print("AUDIT \(device) reports page \(pageFrame) bars \(bars) at the \(at)")
            try app.performAccessibilityAudit(for: types) { issue in
                let el = issue.element
                let new = el.map { e in
                    let f = e.frame
                    return !bars.contains { $0.insetBy(dx: -1, dy: -1).contains(f) } && f.intersects(pageFrame)
                } ?? true
                let line = "\(issue.auditType) '\(el?.identifier ?? "")' '\(el?.label ?? "")' \(el.map { "\($0.frame)" } ?? "-") \(issue.compactDescription)"
                print("AUDIT \(device) reports \(new ? "NEW" : "old") \(line)")
                if new { flagged.append("reports: \(line)") }
                return true
            }
        }
        try auditPage("top")
        // Down the page to Copy, as BarUpUITests drags, and the foot audited too.
        let copy = any("healthReports.copy")
        for _ in 0..<8 where !(copy.exists && copy.isHittable) {
            let w = app.windows.firstMatch
            w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 0.05,
                thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)), withVelocity: .slow, thenHoldForDuration: 0.3)
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        }
        XCTAssertTrue(copy.exists && copy.isHittable, "Copy wasn't reached: the fixture's rows didn't show")
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        try auditPage("foot")
        print("AUDIT \(device) done, \(flagged.count) on the new row and page")
        XCTAssertTrue(flagged.isEmpty, "the audit flags the new row or page: \(flagged.joined(separator: "; "))")
        app.terminate()
    }
}
