import XCTest

/// #433 ("chat got zoomed in?"): after a background process's notice whose output has lines with nowhere to break (a
/// long command, a /tmp path), a tester's whole chat was wider than the screen, every message and the message bar cut
/// at both edges. Opened, turned and turned back, scrolled and closed, nothing in the chat may reach past the window.
/// The cause was the message field's own width: asked for its ideal size it gave the width it had, so a bar laid out
/// wider once (the iPad turned and back) kept it, and the page with it. The iPhone cannot turn; the iPad shows it.
///
/// Wants the mock with MOCK_WIDE_NOTE=1 (the export chat's notice gets a 300-character token, a long command and a
/// URL). Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=com.vorantx.vory.demo drives the
/// demo copy. HERMES_E2E_SHOTS names a folder for the stills.
@MainActor
final class ThreadWidthUITests: XCTestCase {
    private var app: XCUIApplication!
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty {
            let d = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
        }
    }

    private func launch() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        let args = ["-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "dark"]
        if let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
    }

    /// Everything on screen that reaches past the window's sides, with what it is: one line each.
    private func overflow(_ stage: String) -> [String] {
        let window = app.windows.firstMatch.frame
        var out: [String] = []
        // What the tester saw cut: the words. (Containers and glass reach past the sides by design.)
        let kinds: [(String, XCUIElementQuery)] = [("text", app.staticTexts), ("view", app.textViews)]
        for (kind, query) in kinds {
            for el in query.allElementsBoundByIndex where el.exists {
                let f = el.frame
                // Off-screen rows of a lazy list and zero-sized holders are not drawn.
                guard f.width > 1, f.height > 1, f.maxY > window.minY, f.minY < window.maxY else { continue }
                if f.minX < window.minX - 1 || f.maxX > window.maxX + 1 {
                    out.append("\(kind) '\(el.label.prefix(60))' id '\(el.identifier)' x \(Int(f.minX))...\(Int(f.maxX)) in 0...\(Int(window.maxX))")
                }
            }
        }
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'proc_5e1f0c2a9d71' OR label CONTAINS 'sha256:9f86'")).allElementsBoundByIndex.filter(\.exists).map { "\(Int($0.frame.minX))...\(Int($0.frame.maxX))" }
        print("THREAD-WIDTH \(stage): window 0...\(Int(window.maxX)), notice text \(note), dock \(Int(app.otherElements["chat.dock"].firstMatch.frame.minX))...\(Int(app.otherElements["chat.dock"].firstMatch.frame.maxX))")
        print("THREAD-WIDTH \(stage): \(out.count) past the window" + (out.isEmpty ? "" : "\n  " + out.prefix(12).joined(separator: "\n  ")))
        return out
    }

    private func assertInside(_ stage: String) {
        let window = app.windows.firstMatch.frame
        for (id, el) in [("composer.text", app.textViews["composer.text"].firstMatch), ("chat.dock", app.otherElements["chat.dock"].firstMatch)] where el.exists {
            XCTAssertTrue(el.frame.minX >= window.minX - 1 && el.frame.maxX <= window.maxX + 1,
                          "\(stage): \(id) runs past the window: \(el.frame) in \(window)")
        }
        let past = overflow(stage)
        XCTAssertTrue(past.isEmpty, "\(stage): \(past.count) elements run past the window, first: \(past.first ?? "")")
    }

    func testAWideBackgroundNoticeKeepsTheChatInsideTheScreen() throws {
        continueAfterFailure = true
        try launch()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Rewrite the nightly export job'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "no export chat row")
        pause(1.5)
        row.tap()
        let notice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Background process'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "no background-process notice in the export chat")
        pause(2)
        for _ in 0..<6 where !notice.isHittable { app.swipeDown(velocity: .slow); pause(0.5) }
        shot("433-folded")
        assertInside("folded")

        notice.tap(); pause(1.5)
        shot("433-open")
        assertInside("open")

        // Turned and back: a width change while it is open.
        XCUIDevice.shared.orientation = .landscapeLeft; pause(2)
        shot("433-open-landscape")
        assertInside("open, landscape")
        XCUIDevice.shared.orientation = .portrait; pause(2)
        // The iPad (the iPhone app does not turn): the open notice kept its landscape row's width, and the thread and
        // the whole chat with it, wider than the column it came back to (#440).
        shot("433-open-portrait-again")
        assertInside("open, portrait again")

        // Scrolled away and back, then closed.
        app.swipeUp(velocity: .slow); pause(1); app.swipeDown(velocity: .slow); pause(1)
        assertInside("open, scrolled")
        if notice.isHittable { notice.tap(); pause(1.5) }
        shot("433-closed-again")
        assertInside("closed again")

        // The message bar's chrome after all that: the audit fails on anything in the bar.
        let dock = app.otherElements["chat.dock"].firstMatch.frame
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            let inDock = issue.element.map { dock.intersects($0.frame) } ?? false
            print("CHAT-AUDIT \(inDock ? "bar" : "chat") '\(issue.compactDescription)' label '\(issue.element?.label ?? "")' id '\(issue.element?.identifier ?? "")'")
            return !inDock
        }
    }
}
