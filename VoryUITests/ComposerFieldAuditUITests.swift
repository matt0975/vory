import XCTest

/// The message bar's field in the app's own chat passes the audit with the keyboard down and up (#490 changed the field
/// for every chat: it takes no typing only where the bar is read-only, the tour's). Every finding is printed, and any
/// fails but two, each logged: the reasoning row's hit region (#482's), and one "Potentially inaccessible text" with no
/// label and no frame, on release before this change too, source not yet known (its own issue). Run it with predictive
/// text off on the simulator (com.apple.keyboard.preferences KeyboardPrediction, read back before and after): iOS 27's
/// predictive bar sits outside the keyboard's tree, and its cells, the system's, have no labels. The mock
/// (HERMES_E2E_URL, HERMES_E2E_TOKEN, HERMES_E2E_BUNDLE).
final class ComposerFieldAuditUITests: XCTestCase {
    private var app: XCUIApplication!

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func audit(_ when: String) throws {
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            let label = issue.element?.label ?? "", frame = issue.element?.frame ?? .zero
            print("COMPOSER-AUDIT \(when) '\(issue.compactDescription)' label '\(label)' id '\(issue.element?.identifier ?? "")' frame \(frame)")
            // The reasoning row's hit region, #482's (filed, open), by its exact finding: anything else on that toggle
            // still fails. Out when #482 is fixed.
            if issue.auditType == .hitRegion, issue.compactDescription == "Hit area is too small",
               ["Show reasoning", "Hide reasoning"].contains(label) {
                print("COMPOSER-AUDIT \(when) ignored: #482's hit region on '\(label)'")
                return true
            }
            // On release before this change too (4e264163), source not yet known: its own issue.
            if issue.compactDescription == "Potentially inaccessible text", frame == .zero, label.isEmpty {
                print("COMPOSER-AUDIT \(when) ignored: the known 0x0 'Potentially inaccessible text' (its own issue)")
                return true
            }
            return false
        }
    }

    func testTheAppsOwnChatPassesTheAuditWithTheKeyboardDownAndUp() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("needs the mock (HERMES_E2E_URL / TOKEN / BUNDLE)")
        }
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats"]
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup' AND identifier != 'chat.titlePill'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no Disk cleanup chat")
        row.tap(); pause(2)
        let field = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no message bar")
        XCTAssertEqual(app.keyboards.count, 0)
        try audit("keyboard down")
        field.tap(); pause(1.5)
        XCTAssertGreaterThan(app.keyboards.count, 0, "no keyboard for the message bar")
        try audit("keyboard up")
    }
}
