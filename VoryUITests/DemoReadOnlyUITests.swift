import XCTest

/// #392 point 4: in the demo the pages whose changes it can't keep are read-only, under one line saying so
/// (`demo.readonly`): Model, Config, API Keys & Environment, Tools, Skills, MCP Servers, Approvals, Profile, and a bot's
/// SOUL.md. On each the line is there in its set words, nothing adds, changes or removes (no Add, no Create
/// Profile, no Save, no switch enabled), and the page still reads. New bot and Edit bot… are nowhere in the demo. Over the
/// mock (HERMES_E2E_URL / TOKEN / BUNDLE) the same pages have no line and their controls are there.
/// `testTheDemosPagesAudit` opens each page in the demo and prints every audit finding (DEMO-RO-AUDIT) for a compare
/// with the build before; HERMES_E2E_SHOTS keeps a still of each page (DEMO-RO still lines name them).
@MainActor
final class DemoReadOnlyUITests: XCTestCase {
    private var app: XCUIApplication!
    static let words = "This is the demo's sample setup. Connect your own gateway to make changes."
    static let pages = ["model", "config", "env", "tools", "skills", "mcp", "approvals", "profile"]
    /// What would add, change or remove on these pages, by label.
    static let changers = ["Add variable", "Add profile", "Create Profile", "Save instructions", "Clear", "Remove", "Delete", "Delete profile…"]

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private var device: String { app.windows.firstMatch.frame.width > 700 ? "ipad" : "iphone" }

    private func launchDemo(tab: String = "settings") {
        app = XCUIApplication()
        app.launchArguments = ["-vory-demo", "-companionPromptShown", "YES", "-launchTab", tab, "-colorSchemePreference", "light",
                               "-tabLayout", "chats,bots,settings", "-tabLayout.homeFirstApplied", "YES"]
        app.launch()
    }
    private func launchMock() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty,
              let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { throw XCTSkip("needs the mock (HERMES_E2E_URL / TOKEN / BUNDLE)") }
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "settings",
                               "-colorSchemePreference", "light", "-tabLayout", "chats,bots,settings", "-tabLayout.homeFirstApplied", "YES"]
        app.launch()
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty {
            let d = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
            print("DEMO-RO still \(name).png")
        }
    }

    /// One slow drag up or down the window's middle, held at its end so the list doesn't fling.
    private func drag(up: Bool) {
        let w = app.windows.firstMatch
        let (from, to) = up ? (0.75, 0.3) : (0.3, 0.75)
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)), withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    /// A short slow drag, for bringing a row just clear of the header.
    private func nudge(up: Bool) {
        let w = app.windows.firstMatch
        let (from, to) = up ? (0.55, 0.42) : (0.42, 0.55)
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)), withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    /// The bottom of what floats over the top of the page: the front navigation bars and the floating header (morph.bar).
    private var headerBottom: CGFloat {
        let bars = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map(\.frame.maxY)
        let morph = any("morph.bar")
        return (bars + (morph.exists ? [morph.frame.maxY] : [])).max() ?? 0
    }
    private func f(_ r: CGRect) -> String { String(format: "{%.1f,%.1f %.1fx%.1f}", r.minX, r.minY, r.width, r.height) }
    /// Every Settings row's frame, the front navigation bars' and the floating header's, printed before a tap.
    private func printFrames(_ why: String) {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.row.'")).allElementsBoundByIndex.filter(\.exists)
        let navs = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        let morph = any("morph.bar")
        print("DEMO-RO frames \(why): nav \(navs.map { "\($0.identifier) \(f($0.frame))" }.joined(separator: ", ")); morph.bar \(morph.exists ? f(morph.frame) : "none"); header bottom \(String(format: "%.1f", headerBottom))")
        print("DEMO-RO frames \(why): rows \(rows.map { "\($0.identifier.dropFirst(13)) \(f($0.frame))" }.joined(separator: "; "))")
    }
    /// A Settings row, tapped once it sits wholly below the header and above the bottom 150 pt; its frame and the
    /// header's printed first. A first row the list can't bring below the header is reported, with a still.
    private func openSettingsRow(_ id: String) {
        let row = any("settings.row.\(id)")
        XCTAssertTrue(any("settings.row.profile").waitForExistence(timeout: 30), "no Settings rows")
        let limit = app.windows.firstMatch.frame.maxY - 150
        for _ in 0..<12 where !(row.exists && row.isHittable && row.frame.maxY < limit) { drag(up: true); pause(0.5) }
        var lastTop: CGFloat = .nan
        for _ in 0..<8 where row.exists && row.frame.minY <= headerBottom + 4 {
            if row.frame.minY == lastTop { break }   // the list moves no further down: the row is at its top
            lastTop = row.frame.minY
            nudge(up: false); pause(0.5)
        }
        printFrames("before tapping \(id)")
        XCTAssertTrue(row.exists && row.isHittable, "no \(id) row on Settings")
        if row.exists, row.frame.minY <= headerBottom + 4 {
            print("DEMO-RO tap \(id): UNDER THE HEADER, row \(f(row.frame)), header bottom \(String(format: "%.1f", headerBottom))")
            shot("392-\(device)-\(id)-under-header")
            XCTFail("\(id): the row stays under the header (top \(row.frame.minY), header bottom \(headerBottom))")
        }
        row.tap(); pause(2)
    }
    private func back() {
        if any("page.back").exists { any("page.back").tap() }
        else if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.element(boundBy: 0).tap() }
        pause(1.5)
        for _ in 0..<10 where !(any("settings.row.profile").exists && any("settings.row.profile").isHittable) { drag(up: false); pause(0.3) }
    }
    /// An audited element's enabled state, for the allowance file's join (read-392.py): unknown when the audit names no
    /// element, gone when it has left the tree.
    private func state(_ el: XCUIElement?) -> String { el.map { $0.exists ? ($0.isEnabled ? "true" : "false") : "gone" } ?? "unknown" }
    /// A changer by label, offered: there, hittable and enabled.
    private func offered(_ label: String) -> Bool {
        let b = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        return b.exists && b.isHittable && b.isEnabled
    }

    /// What stays enabled in the demo, exactly: the bar's Back and the tab bar (by identifier), Model's Refresh (it only
    /// reads), and Profile's bot rows (choosing which bot Settings shows is the app's own). The search fields are search
    /// fields, not text fields, so no query below catches them. Each allowance is printed as it's used.
    static let allowedIDs: Set<String> = ["page.back", "chat.back", "profile.row"]
    static let allowedLabels: Set<String> = ["Refresh model list", "Asking the providers…"]

    /// Vory's own tab bar (VoryTabBar) is a view of the app's, not a UITabBar, so `app.tabBars` doesn't find it: its
    /// frame is taken from its own tab items (the "tab." buttons), widened along the bar to the window's edge. It is the
    /// app's chrome on every tab, not part of a page: its tabs, and the Voice chat and New Chat beside them, which the
    /// demo keeps working (its chats are live), are left out of a page's controls, as a UITabBar's would be.
    private var voryTabBar: CGRect? {
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).allElementsBoundByIndex.filter(\.exists).map(\.frame)
        guard let first = items.first else { return nil }
        let u = items.dropFirst().reduce(first) { $0.union($1) }
        let w = app.windows.firstMatch.frame
        return u.width >= u.height ? CGRect(x: w.minX, y: u.minY - 4, width: w.width, height: u.height + 8)
                                   : CGRect(x: u.minX - 4, y: w.minY, width: u.width + 8, height: w.height)
    }

    /// The page's controls on screen that could change something: its buttons (menus and pickers draw as buttons), text
    /// fields, secure fields, steppers and switches, less the allowances, the navigation bar's and the tab bar's own
    /// (a UITabBar's, and VoryTabBar's by its frame).
    private func judged(_ page: String) -> [XCUIElement] {
        let bars = (app.navigationBars.allElementsBoundByIndex + app.tabBars.allElementsBoundByIndex).filter(\.exists).map(\.frame)
        let tabBar = voryTabBar
        if let tabBar { print("DEMO-RO \(page): VoryTabBar \(f(tabBar)) left out") }
        var out: [XCUIElement] = []
        let queries = [app.buttons, app.textFields, app.secureTextFields, app.steppers, app.switches]
        for q in queries {
            for e in q.allElementsBoundByIndex where e.exists && e.isHittable {
                let id = e.identifier, label = e.label
                if Self.allowedIDs.contains(id) || id.hasPrefix("tab.") || Self.allowedLabels.contains(label) {
                    print("DEMO-RO \(page): allowance '\(id.isEmpty ? label : id)'"); continue
                }
                if bars.contains(where: { $0.intersects(e.frame) }) { continue }
                if let tabBar, tabBar.contains(CGPoint(x: e.frame.midX, y: e.frame.midY)) { continue }
                out.append(e)
            }
        }
        return out
    }

    /// The page in front, in the demo: the line in its words, no changer, no control enabled but the allowances, and
    /// still read to its end.
    private func checkReadOnly(_ page: String) {
        let note = any("demo.readonly")
        XCTAssertTrue(note.waitForExistence(timeout: 20), "\(page): no read-only line")
        if note.exists { XCTAssertTrue(note.label.contains(Self.words), "\(page): the line reads '\(note.label)'") }
        for c in Self.changers { XCTAssertFalse(offered(c), "\(page): '\(c)' is offered in the demo") }
        // The whole page, not its first screen: the lists draw their cells as they come on screen, so the page is judged
        // at each place from its top to its end (a drag up at a time, until a drag moves nothing). Every control on screen
        // is judged at every place, so two that share an identifier and a label are both judged; only the report is kept
        // once per control (the sets), with what each place added printed.
        var keys = Set<String>(), enabled = Set<String>(), place = 0
        while true {
            let here = judged(page)
            var added = 0
            for c in here {
                let key = "'\(c.label)' (\(c.elementType.rawValue), id '\(c.identifier)')"
                if keys.insert(key).inserted { added += 1 }
                if c.isEnabled { enabled.insert(key) }
            }
            print("DEMO-RO \(page): place \(place), \(here.count) controls on screen, \(added) new")
            let before = cellFrames().map(\.frame.minY)
            drag(up: true); pause(0.5)
            if cellFrames().map(\.frame.minY) == before || place >= 15 { break }
            place += 1
        }
        for e in enabled.sorted() { XCTFail("\(page): \(e) is enabled in the demo") }
        for _ in 0...place { drag(up: false); pause(0.3) }
        print("DEMO-RO \(page): line \(note.exists ? "there" : "MISSING"), \(keys.count) controls over \(place + 1) places, none enabled: \(enabled.isEmpty)")
        // The page still reads: a drag moves it, or it all fits. Read from one snapshot of the tree before the drag and one
        // after (values, not elements: an element bound by index, read again after the drag, can be gone from the tree).
        let before = cellFrames()
        drag(up: true); pause(0.6)
        let after = cellFrames()
        let moved = before.compactMap { b in after.first { $0.label == b.label && !b.label.isEmpty }.map { b.frame.minY - $0.frame.minY } }.sorted()
        print("DEMO-RO \(page): \(before.count) cells; \(moved.isEmpty ? "none to compare" : "they moved \(Int(moved[moved.count / 2])) pt") on a drag up")
        drag(up: false); pause(0.4)
    }
    /// Every cell's label and frame, from one snapshot of the tree.
    private func cellFrames() -> [(label: String, frame: CGRect)] {
        guard let s = try? app.snapshot() else { return [] }
        var out: [(label: String, frame: CGRect)] = []
        func walk(_ n: XCUIElementSnapshot) {
            if n.elementType == .cell { out.append((n.label, n.frame)) }
            for c in n.children { walk(c) }
        }
        walk(s)
        return out
    }

    func testInTheDemoThePagesAreReadOnly() throws {
        continueAfterFailure = true
        launchDemo()
        for page in Self.pages {
            openSettingsRow(page)
            checkReadOnly(page)
            back()
        }
    }

    /// A bot's SOUL.md in the demo: a held press on a bot opens the bot's page, whose Profile row opens its settings,
    /// whose Instructions row opens the page.
    func testInTheDemoABotsInstructionsAreReadOnly() throws {
        continueAfterFailure = true
        launchDemo(tab: "bots")
        let bot = app.cells.firstMatch
        XCTAssertTrue(bot.waitForExistence(timeout: 30), "no bot on the Bots page")
        bot.press(forDuration: 1.2); pause(2)
        let profile = app.buttons.matching(NSPredicate(format: "label == 'Profile'")).allElementsBoundByIndex.first { $0.exists && $0.isHittable }
        XCTAssertNotNil(profile, "no Profile row on the bot's page")
        if let profile { print("DEMO-RO soul: the bot's Profile row \(f(profile.frame))"); profile.tap(); pause(2) }
        let soul = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Instructions (SOUL.md)'")).firstMatch
        XCTAssertTrue(soul.waitForExistence(timeout: 15), "no Instructions (SOUL.md) row in the bot's settings")
        if soul.exists { soul.tap(); pause(2) }
        checkReadOnly("soul")
        XCTAssertFalse(app.textViews.allElementsBoundByIndex.contains { $0.exists && $0.isHittable && $0.isEnabled }, "soul: an editor is offered in the demo")
        // The page is new in the demo (an editor before), so its audit is printed with no base to compare: every finding.
        shot("392-\(device)-soul")
        var n = 0
        try app.performAccessibilityAudit { issue in
            let el = issue.element
            print("DEMO-RO-AUDIT soul '\(issue.compactDescription)' type \(el?.elementType.rawValue ?? 0) id '\(el?.identifier ?? "")' label '\(el?.label.prefix(60) ?? "")' enabled \(self.state(el)) frame \(el.map { self.f($0.frame) } ?? "none")")
            n += 1
            return true
        }
        print("DEMO-RO-AUDIT soul done, \(n) issues")
    }

    /// New bot and Edit bot… are nowhere in the demo: the Bots page, its bar and the chat list's bar.
    func testTheDemoOffersNoNewOrEditBot() throws {
        continueAfterFailure = true
        launchDemo(tab: "bots")
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 30), "no bot on the Bots page")
        for id in ["bots.newBot", "chats.newBot"] { XCTAssertFalse(any(id).exists && any(id).isHittable, "\(id) is offered in the demo") }
        XCTAssertFalse(offered("New bot"), "New bot is offered on the Bots page in the demo")
        // A bot's own menu: no Edit bot… (the press above opens its settings; a context menu is the Mac's and the iPad's).
        app.cells.firstMatch.press(forDuration: 1.2); pause(1.5)
        XCTAssertFalse(offered("Edit bot…"), "Edit bot… is offered in the demo")
        XCTAssertFalse(offered("Delete bot"), "Delete bot is offered in the demo")
        print("DEMO-RO bots: New bot \(offered("New bot") ? "OFFERED" : "none"), Edit bot… \(offered("Edit bot…") ? "OFFERED" : "none")")
    }

    /// Over the mock nothing is read-only: no line, and each page's own controls there.
    func testOverTheMockThePagesCanBeChanged() throws {
        continueAfterFailure = true
        try launchMock()
        for page in Self.pages {
            openSettingsRow(page)
            pause(1)
            XCTAssertFalse(any("demo.readonly").exists, "\(page): the demo's line over the mock")
            let switches = app.switches.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            if let s = switches.first { XCTAssertTrue(s.isEnabled, "\(page): its switch '\(s.label)' isn't enabled over the mock") }
            // Model's and Approvals' first control (a menu, the Mode picker) is enabled over the mock, so the demo's check
            // that every such control is disabled can't pass for want of one.
            if page == "model" || page == "approvals" {
                let first = judged(page).first
                XCTAssertNotNil(first, "\(page): no control found over the mock")
                if let first { XCTAssertTrue(first.isEnabled, "\(page): '\(first.label)' isn't enabled over the mock") }
                print("DEMO-RO mock \(page): first control '\(first?.label ?? "none")' enabled \(first?.isEnabled ?? false)")
            }
            if page == "profile" { XCTAssertTrue(offered("Create Profile") || any("profile.add").exists, "profile: no way to make one over the mock") }
            if page == "env" { XCTAssertTrue(any("env.add").exists || offered("Add variable"), "env: no Add over the mock") }
            print("DEMO-RO mock \(page): line \(any("demo.readonly").exists ? "THERE" : "none"), \(switches.count) switches, first enabled \(switches.first?.isEnabled ?? false)")
            back()
        }
    }

    /// Each page in the demo, audited, every finding printed for the compare with the build before; a still of each.
    func testTheDemosPagesAudit() throws {
        continueAfterFailure = true
        launchDemo()
        for page in Self.pages {
            openSettingsRow(page)
            pause(1)
            shot("392-\(device)-\(page)")
            var n = 0
            try app.performAccessibilityAudit { issue in
                let el = issue.element
                print("DEMO-RO-AUDIT \(page) '\(issue.compactDescription)' type \(el?.elementType.rawValue ?? 0) id '\(el?.identifier ?? "")' label '\(el?.label.prefix(60) ?? "")' enabled \(self.state(el)) frame \(el.map { self.f($0.frame) } ?? "none")")
                n += 1
                return true
            }
            print("DEMO-RO-AUDIT \(page) done, \(n) issues")
            back()
        }
    }
}
