import XCTest

/// Feedback on 1.5 (18): "don't allow taps behind the nav bar on iPhone as when the group chats appear
/// behind nav bar I can tap it when touching the nav bar". Points on the tab bar that miss its
/// buttons are tapped one at a time, with the page behind at rest: on Chats (the list runs under
/// the bar), on Bots (a group chat brought under the bar) and on Home. Before the fix, a touch
/// 2 pt over the bar's top edge, or in the notch at the top of a gap, opened the row behind it;
/// mid-height in a gap the nearest control took it. None may reach the page behind. Beside the
/// bar, 8 pt in from the screen's edge, the row must still answer: the bar takes its shapes,
/// not a strip.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=com.vorantx.vory.demo
/// drives the demo copy. Wants the mock with --extra-sessions 60 --extra-bots 12.
@MainActor
final class TabBarGapsUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func launch(url: String, token: String, tab: String) {
        let args = ["-companionPromptShown", "YES", "-launchTab", tab, "-colorSchemePreference", "light",
                    "-tabLayout", "dashboard,chats,bots,settings", "-tabLayout.homeFirstApplied", "YES"]
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

    /// One call to the mock's own controls.
    private final class Answer: @unchecked Sendable { var json: [String: Any]? }
    private func mock(_ gateway: String, _ path: String, _ body: [String: Any]) {
        guard let url = URL(string: gateway + path) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 12)
    }

    /// The bar's shapes, from the mic circle (its frame is its circle on the simulator and the
    /// phone; the compose button's is only its glyph on the phone, and the tab slots' are narrower
    /// than the capsule): the compose circle the same size one 6 pt gap after it, the side margins
    /// equal, the capsule ending one gap before the mic.
    private func barShapes() -> (capsule: CGRect, mic: CGRect, compose: CGRect) {
        let mic = any("chats.voice").frame
        let compose = CGRect(x: mic.maxX + 6, y: mic.minY, width: mic.width, height: mic.height)
        let left = app.frame.width - compose.maxX
        return (CGRect(x: left, y: mic.minY, width: mic.minX - 6 - left, height: mic.height), mic, compose)
    }

    /// The points on the bar that miss every button: the middle of the gap between the capsule and
    /// the mic and of the gap between the circles, the notch at the top of the first gap, 2 pt
    /// over the capsule's and the mic's top edges, and 2 pt past the capsule's left end. All of
    /// them lie on the bar's drawn shapes or within its 4 pt touch margin.
    private func gapPoints() -> [(String, CGPoint)] {
        let (cap, mic, new) = barShapes()
        return [("capsule-mic", CGPoint(x: mic.minX - 3, y: mic.midY)),
                ("mic-compose", CGPoint(x: (mic.maxX + new.minX) / 2, y: new.midY)),
                ("notch", CGPoint(x: mic.minX - 3, y: mic.minY + 4)),
                ("over-capsule", CGPoint(x: cap.midX, y: cap.minY - 2)),
                ("over-mic", CGPoint(x: mic.midX, y: mic.minY - 2)),
                ("left-end", CGPoint(x: cap.minX - 2, y: cap.midY))]
    }

    /// What a tap did: "row" (the page behind answered: a chat, a pushed page or a group chat
    /// opened), "control" (a bar control answered: a new chat from compose or the mic, another
    /// tab, a sheet), or "nothing".
    private func outcome(_ tab: String) -> String {
        if any("chat.dock").exists {
            let pill = any("chat.titlePill")
            return pill.exists && pill.label.contains("New chat") ? "control:new-chat" : "row:chat"
        }
        if any("page.back").exists { return "row:page" }
        if any("group.back").exists { return "row:group" }
        let slot = any("tab.\(tab)")
        if !slot.exists || !slot.isHittable { return "row:covered" }
        if !slot.isSelected { return "control:tab" }
        if app.buttons["Cancel"].exists { return "control:sheet" }
        return "nothing"
    }

    /// Taps each point on its own, from the page at rest (`setUp` launches and places it; it runs
    /// again after any tap that changed something). Returns each point's outcome.
    private func probe(_ tab: String, _ points: () -> [(String, CGPoint)], rows: () -> XCUIElementQuery, setUp: () -> Void) -> [String: String] {
        var result: [String: String] = [:]
        setUp()
        let (cap, mic, new) = barShapes()
        print("GAP-SHAPES \(tab) capsule \(cap) mic \(mic) compose \(new) window \(app.frame.size)")
        for (name, p) in points() {
            let behind = rows().allElementsBoundByIndex.contains { $0.exists && $0.frame.contains(p) }
            at(p).tap(); pause(1.5)
            let o = outcome(tab)
            result[name] = o
            print("GAP-TAP \(tab) \(name) at (\(Int(p.x)), \(Int(p.y))) row-behind=\(behind) -> \(o)")
            if o != "nothing" { shot("\(tab)-\(name)-\(o)"); setUp() }
        }
        return result
    }

    func testTabBarGapsSwallowTaps() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        // Group chats on Bots, enough of them to put one under the bar.
        for i in 1...6 { mock(url, "/api/_mock/rooms", ["name": "Gap room \(i)", "handles": ["default", "work"]]) }
        let notBar = NSPredicate(format: "NOT (identifier BEGINSWITH 'tab.') AND NOT (identifier BEGINSWITH 'chats.')")

        // Chats: the list runs under the bar at rest. Beside the bar, 8 pt in from the screen's
        // edge (inside the 21 pt side margin, outside the touch margin), the row must still answer:
        // the bar takes its shapes, not a strip.
        var chats: [String: String] = [:]
        chats = probe("chats", { self.gapPoints() + [("beside", CGPoint(x: 8, y: self.barShapes().capsule.midY))] }, rows: { app.buttons.matching(notBar) }) {
            if app != nil, app.state == .runningForeground { app.terminate() }
            launch(url: url, token: token, tab: "chats")
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch.waitForExistence(timeout: 40), "no chat rows")
            pause(2)
        }

        // Bots: a group chat card brought under the bar and held there.
        let bots = probe("bots", { self.gapPoints() }, rows: { app.buttons.matching(NSPredicate(format: "label CONTAINS 'Gap room'")) }) {
            if app != nil, app.state == .runningForeground { app.terminate() }
            launch(url: url, token: token, tab: "bots")
            XCTAssertTrue(any("bots.newBot").waitForExistence(timeout: 15), "no Bots page")
            pause(2)
            let room = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Gap room 3'")).firstMatch
            for _ in 0..<8 where !(room.exists && room.frame.minY > 0 && room.frame.maxY < app.frame.maxY) { app.swipeUp(velocity: .slow); pause(0.8) }
            XCTAssertTrue(room.exists, "no group chat on Bots")
            let delta = barShapes().capsule.midY - room.frame.midY
            let start = CGPoint(x: app.frame.midX, y: delta > 0 ? room.frame.midY : app.frame.midY)
            at(start).press(forDuration: 0.1, thenDragTo: at(CGPoint(x: start.x, y: start.y + delta)), withVelocity: .slow, thenHoldForDuration: 0.6)
            pause(1.5)
        }

        // Home: whatever its cards are.
        let home = probe("dashboard", { self.gapPoints() }, rows: { app.buttons.matching(notBar) }) {
            if app != nil, app.state == .runningForeground { app.terminate() }
            launch(url: url, token: token, tab: "dashboard")
            XCTAssertTrue(any("tab.dashboard").waitForExistence(timeout: 15), "no Home tab")
            pause(3)
        }

        for (tab, r) in [("Chats", chats), ("Bots", bots), ("Home", home)] {
            for (name, o) in r where name != "beside" {
                XCTAssertFalse(o.hasPrefix("row"), "a tap on the bar's \(name) on \(tab) reached the page behind it (\(o))")
            }
        }
        XCTAssertTrue(chats["beside"]?.hasPrefix("row") == true, "a tap beside the bar no longer reaches the list (\(chats["beside"] ?? "none")): the bar took a strip")
    }

    /// The elements lying on the bar, in tree order (the order a VoiceOver swipe takes), from one
    /// snapshot of the app.
    private func barTree(_ bar: CGRect) throws -> [String] {
        var out: [String] = []
        func walk(_ s: XCUIElementSnapshot) {
            if s.frame.width > 0, bar.contains(s.frame) {
                out.append("type \(s.elementType.rawValue) id '\(s.identifier)' label '\(s.label)' frame \(s.frame)")
            }
            for c in s.children { walk(c) }
        }
        walk(try app.snapshot())
        return out
    }

    /// The bar's touch margin is not something VoiceOver meets: an accessibility audit flags
    /// nothing lying on the bar, on Chats, Bots, Home and Settings. The hit-only capsule behind
    /// the bar's shapes read as an element with no description the size of the bar (1.5 (20)).
    func testTabBarAuditClean() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "chats")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch.waitForExistence(timeout: 40), "no chat rows")
        pause(2)
        for tab in ["chats", "bots", "dashboard", "settings"] {
            if tab != "chats" { any("tab.\(tab)").tap(); pause(2) }
            // The bar's shapes and their touch margin, a little over. Down the Duo's strip: its
            // buttons' frames, the capsule's inset around them and the margin.
            let parts = ["tab.dashboard", "tab.chats", "tab.bots", "tab.settings", "chats.voice", "chats.new"].map { any($0) }.filter { $0.exists }
            let vertical = abs(any("tab.chats").frame.midX - any("tab.settings").frame.midX) < 2
            let bar: CGRect
            if vertical {
                bar = parts.dropFirst().reduce(parts[0].frame) { $0.union($1.frame) }.insetBy(dx: -16, dy: -16)
            } else {
                let (cap, mic, new) = barShapes()
                bar = cap.union(mic).union(new).insetBy(dx: -8, dy: -8)
            }
            print("TAB-BAR \(tab) \(bar) window \(app.frame.size)")
            for line in try barTree(bar) { print("TAB-TREE \(tab) \(line)") }
            var flagged: [String] = []
            try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
                guard let el = issue.element else { print("TAB-AUDIT \(tab) '\(issue.compactDescription)' no element"); return true }
                let line = "'\(issue.compactDescription)' type \(el.elementType.rawValue) id '\(el.identifier)' label '\(el.label)' frame \(el.frame)"
                print("TAB-AUDIT \(tab) \(line)")
                // On the bar: lying within it. A row running under the bar is wider than it.
                if bar.contains(el.frame) { flagged.append(line) }
                return true
            }
            XCTAssertTrue(flagged.isEmpty, "\(tab): the audit flags the bar: \(flagged)")
        }
    }
}
