import XCTest

/// #673: a gateway whose scheduled tasks run every 5 minutes (the mock's `--cron-sessions 150`: 150 runs with no message,
/// three with replies, and a chat of the person's own two days old; the mock's own "Weekly dependency audit" is a fourth
/// with a reply). Chats lists the person's chats, the old one too, with no "New chat" row. The scheduled chats with a reply
/// wait in the Scheduled section, with their count; opened, each reads as its own words ("Scheduled task" for the one with
/// neither a title nor a preview, with no empty line under its title); the person's chats start their own group after
/// the open section; closed, they go. The audit (the gate's three types) runs with the section closed and
/// open, and fails only on the section: its header, and its rows while open. Every issue is printed ("AUDIT <device> chats
/// closed|open NEW|old|unplaced …"); one with no element can't be placed and is printed only. A still of each state is
/// attached ("scheduled-<state>-<device>-<scheme>"). The demo copy keeps its settings between launches, so a section an
/// earlier run left open is closed first. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set and HERMES_E2E_CRON=1
/// says the mock runs the fixture.
@MainActor
final class ScheduledChatsUITests: XCTestCase {
    private let types: XCUIAccessibilityAuditType = [.sufficientElementDescription, .hitRegion, .elementDetection]
    /// The scheduled chats with a reply, by words in their rows: the fixture's three and the mock's own.
    private let scheduled = ["Morning digest", "Check the backup log", "Scheduled task", "Weekly dependency audit"]
    /// The person's chats: the mock's and the fixture's old one.
    private let chats = ["Disk cleanup", "Rewrite the nightly export job", "Plan the storage upgrade"]
    private var app: XCUIApplication!
    private var device = "iphone"
    private var scheme = "light"

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    /// A row of the list by words in its label (its title or its preview), matched as written: "New Chat", the compose
    /// button, isn't "New chat".
    private func row(_ words: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (identifier BEGINSWITH 'chats.')", words)).firstMatch
    }

    private func launch() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        guard e["HERMES_E2E_CRON"] == "1" else { throw XCTSkip("HERMES_E2E_CRON=1 not set: the mock isn't running --cron-sessions") }
        continueAfterFailure = true
        scheme = e["HERMES_E2E_SCHEME"] ?? "light"
        let args = ["-companionPromptShown", "YES", "-launchTab", "chats", "-restore.openChat", "none", "-colorSchemePreference", scheme]
        if let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
        device = app.windows.firstMatch.frame.width > 700 ? "ipad" : "iphone"
    }

    /// The row in view, the list dragged a fifth of a screen at a time in its own column (the iPad's list is a sidebar).
    private func reveal(_ r: XCUIElement) -> Bool {
        let w = app.windows.firstMatch
        for _ in 0..<6 where !(r.exists && r.isHittable) {
            let x = r.exists ? r.frame.midX / w.frame.width : 0.25
            w.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)))
            pause(0.6)
        }
        return r.exists && r.isHittable
    }

    private func audit(_ state: String, region: CGRect, into flagged: inout [String]) throws {
        print("AUDIT \(device) chats \(state) region \(region)")
        var found: [String] = []
        try app.performAccessibilityAudit(for: types) { issue in
            guard let el = issue.element else {
                print("AUDIT \(self.device) chats \(state) unplaced \(issue.auditType) \(issue.compactDescription)")
                return true
            }
            let new = region.intersects(el.frame)
            let line = "\(issue.auditType) '\(el.identifier)' '\(el.label)' \(el.frame) \(issue.compactDescription)"
            print("AUDIT \(self.device) chats \(state) \(new ? "NEW" : "old") \(line)")
            if new { found.append("\(state): \(line)") }
            return true
        }
        flagged += found
    }

    private func shot(_ state: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        a.name = "scheduled-\(state)-\(device)-\(scheme)"; a.lifetime = .keepAlways; add(a)
    }

    func testScheduledChatsWaitInTheirSectionAndTheChatsStay() throws {
        try launch()
        XCTAssertTrue(row("Disk cleanup").waitForExistence(timeout: 40), "no chat rows")
        pause(2)

        // The person's chats, the one from two days ago too: the runs no longer fill the page.
        for title in chats { XCTAssertTrue(reveal(row(title)), "'\(title)' isn't in the list") }
        let newChat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (identifier BEGINSWITH 'chats.')", "New chat"))
        XCTAssertEqual(newChat.count, 0, "rows read \"New chat\": \(newChat.allElementsBoundByIndex.prefix(3).map(\.label))")

        // The section's header, with its count.
        let header = any("chats.scheduled")
        for _ in 0..<6 where !(header.exists && header.isHittable) {
            let w = app.windows.firstMatch
            w.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4))
                .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.7)))
            pause(0.6)
        }
        guard header.waitForExistence(timeout: 5) else {
            XCTFail("no Scheduled section (chats.scheduled)")
            return
        }
        print("SCHEDULED \(device) header '\(header.label)' \(header.frame)")
        XCTAssertTrue(header.label.hasPrefix("Scheduled, \(scheduled.count) chats"), "the header reads '\(header.label)'")
        if row(scheduled[0]).exists {
            print("SCHEDULED \(device) started open: an earlier run left it so; closed first")
            header.tap(); pause(1)
        }

        var flagged: [String] = []
        // Closed: the header alone.
        for words in scheduled { XCTAssertFalse(row(words).exists, "'\(words)' is listed with the section closed") }
        shot("closed")
        try audit("closed", region: header.frame.insetBy(dx: -2, dy: -2), into: &flagged)

        // Open: each scheduled chat in its own words.
        header.tap(); pause(1.2)
        var region = header.frame
        for words in scheduled {
            let r = row(words)
            XCTAssertTrue(reveal(r), "'\(words)' isn't in the open section")
            if r.exists { print("SCHEDULED \(device) row '\(r.label)' \(r.frame)"); region = region.union(r.frame) }
        }
        XCTAssertEqual(newChat.count, 0, "an open section's row reads \"New chat\"")
        // The scheduled chat with no preview is as tall as its words: under its title, the line of its project, model and
        // time, with no empty preview line between them.
        let bare = row("Scheduled task")
        if bare.exists {
            let title = bare.staticTexts.matching(NSPredicate(format: "label == %@", "Scheduled task")).firstMatch
            let under = bare.staticTexts.allElementsBoundByIndex.filter { !$0.label.isEmpty && $0.frame.minY >= title.frame.maxY - 1 }
            if title.exists, let next = under.map(\.frame.minY).min() {
                let gap = next - title.frame.maxY
                print("SCHEDULED \(device) bare row \(bare.frame.height) pt, \(gap) pt from its title to the line under it")
                XCTAssertLessThanOrEqual(gap, 10, "'Scheduled task' keeps an empty line under its title: \(gap) pt")
            } else {
                XCTFail("'Scheduled task': no title, or no line under it: \(bare.staticTexts.allElementsBoundByIndex.map(\.label))")
            }
        }
        // The person's chats start a group of their own after the open section.
        let last = row(scheduled[scheduled.count - 1]), first = row(chats[0])
        if reveal(last), first.exists {
            let gap = first.frame.minY - last.frame.maxY
            print("SCHEDULED \(device) break \(gap) pt from '\(scheduled[scheduled.count - 1])' to '\(chats[0])'")
            XCTAssertGreaterThanOrEqual(gap, 16, "no break after the open section: \(gap) pt")
        } else {
            XCTFail("'\(scheduled[scheduled.count - 1])' and '\(chats[0])' aren't both in view")
        }
        if !(header.exists && header.isHittable) { _ = reveal(header) }
        shot("open")
        try audit("open", region: region.insetBy(dx: -2, dy: -2), into: &flagged)

        // Closed again, and left so for the next run.
        _ = reveal(header)
        header.tap(); pause(1.2)
        for words in scheduled { XCTAssertFalse(row(words).exists, "'\(words)' stayed after the section closed") }
        print("AUDIT \(device) done, \(flagged.count) on the section")
        XCTAssertTrue(flagged.isEmpty, "the audit flags the section: \(flagged.joined(separator: "; "))")
        app.terminate()
    }
}
