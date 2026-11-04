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
    private func openSettingsRow(_ id: String) {
        let row = any("settings.row.\(id)")
        XCTAssertTrue(any("settings.row.profile").waitForExistence(timeout: 30), "no Settings rows")
        let limit = app.windows.firstMatch.frame.maxY - 150
        for _ in 0..<12 where !(row.exists && row.isHittable && row.frame.maxY < limit) { drag(up: true); pause(0.5) }
        XCTAssertTrue(row.exists && row.isHittable, "no \(id) row on Settings")
        row.tap(); pause(2)
    }
    private func back() {
        if any("page.back").exists { any("page.back").tap() }
        else if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.element(boundBy: 0).tap() }
        pause(1.5)
        for _ in 0..<10 where !(any("settings.row.profile").exists && any("settings.row.profile").isHittable) { drag(up: false); pause(0.3) }
    }
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

    /// The page's controls on screen that could change something: its buttons (menus and pickers draw as buttons), text
    /// fields, secure fields, steppers and switches, less the allowances, the navigation bar's and the tab bar's own.
    private func judged(_ page: String) -> [XCUIElement] {
        let bars = (app.navigationBars.allElementsBoundByIndex + app.tabBars.allElementsBoundByIndex).filter(\.exists).map(\.frame)
        var out: [XCUIElement] = []
        let queries = [app.buttons, app.textFields, app.secureTextFields, app.steppers, app.switches]
        for q in queries {
            for e in q.allElementsBoundByIndex where e.exists && e.isHittable {
                let id = e.identifier, label = e.label
                if Self.allowedIDs.contains(id) || id.hasPrefix("tab.") || Self.allowedLabels.contains(label) {
                    print("DEMO-RO \(page): allowance '\(id.isEmpty ? label : id)'"); continue
                }
                if bars.contains(where: { $0.intersects(e.frame) }) { continue }
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
        let controls = judged(page)
        for c in controls { XCTAssertFalse(c.isEnabled, "\(page): '\(c.label)' (\(c.elementType.rawValue), id '\(c.identifier)') is enabled in the demo") }
        print("DEMO-RO \(page): line \(note.exists ? "there" : "MISSING"), \(controls.count) controls on screen, none enabled: \(controls.allSatisfy { !$0.isEnabled })")
        // The page still reads: a drag moves it, or it all fits (the last cell stays where it was only when nothing is below).
        let cells = app.cells.allElementsBoundByIndex.filter(\.exists)
        let before = cells.last?.frame.minY ?? 0
        drag(up: true); pause(0.6)
        print("DEMO-RO \(page): \(cells.count) cells; the last moved \(Int(before - (cells.last?.frame.minY ?? 0))) pt on a drag up")
        drag(up: false); pause(0.4)
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

    /// A bot's SOUL.md in the demo: held press on a bot opens its settings, whose Instructions row opens the page.
    func testInTheDemoABotsInstructionsAreReadOnly() throws {
        continueAfterFailure = true
        launchDemo(tab: "bots")
        let bot = app.cells.firstMatch
        XCTAssertTrue(bot.waitForExistence(timeout: 30), "no bot on the Bots page")
        bot.press(forDuration: 1.2); pause(2)
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
            print("DEMO-RO-AUDIT soul '\(issue.compactDescription)' type \(el?.elementType.rawValue ?? 0) id '\(el?.identifier ?? "")' label '\(el?.label.prefix(60) ?? "")'")
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
                print("DEMO-RO-AUDIT \(page) '\(issue.compactDescription)' type \(el?.elementType.rawValue ?? 0) id '\(el?.identifier ?? "")' label '\(el?.label.prefix(60) ?? "")'")
                n += 1
                return true
            }
            print("DEMO-RO-AUDIT \(page) done, \(n) issues")
            back()
        }
    }
}
