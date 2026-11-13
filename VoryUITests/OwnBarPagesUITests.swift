import XCTest

/// J (feedback on 1.5 (18): "the formatting is off in the add a gateway"): a pushed page with its own
/// Cancel, Done or Save keeps the system bar (its items, its title, and the system back where it
/// has no leading item) and the morph bar steps aside while it is up: no Back circle over its
/// Cancel ("<ancel"), nothing of the bar over its items. Each page is pushed and popped; its push
/// must still be animated with a coordinator (the push's start is where 1.5 (18)'s regression
/// was), and the bar must come back on the pop. Add Gateway, a sheet, is checked too.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=com.vorantx.vory.demo
/// drives the demo copy. Wants the mock with --extra-sessions 60 --extra-bots 12.
@MainActor
final class OwnBarPagesUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func launch(url: String, token: String, tab: String) {
        // As the smoothness tests launch: with all bots listed, a bot card's "Chats" opens the bot's
        // page (without, it switched to the Chats tab).
        let args = ["-companionPromptShown", "YES", "-launchTab", tab, "-colorSchemePreference", "light", "-vory-geometry-probe",
                    "-chat.showBots", "YES", "-chats.allBots", "YES"]
            + (ProcessInfo.processInfo.environment["HERMES_E2E_ARGS"] ?? "").split(separator: " ").map(String.init)
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
    private func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)) }

    /// The probe's last push, from the geometry banner.
    private var pushRecord: String {
        let r = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'probe push '")).firstMatch
        return r.exists ? r.label : "none"
    }

    /// The page in front keeps its own bar: its push was animated with a coordinator, the bar's
    /// Back is not there, and nothing of the bar lies over the page's own items.
    private func assertOwnBar(_ page: String, items: [String], depth: Int) {
        let record = pushRecord
        print("OWN-BAR \(page) \(record)")
        XCTAssertTrue(record.contains("push animated=true coordinator=true depth=\(depth)"), "\(page): the push was not animated with a coordinator: \(record)")
        XCTAssertFalse(any("page.back").exists, "\(page): the bar's Back is over the page")
        let bar = any("morph.bar")
        print("OWN-BAR \(page) morph.bar exists=\(bar.exists) type \(bar.exists ? bar.elementType.rawValue : 0) frame \(bar.exists ? bar.frame : .zero)")
        dumpBar(page)
        assertTitleCopies(page, 0)
        // What a touch on the page's items would reach instead: the bar's hittable elements.
        let barControls = bar.exists ? bar.descendants(matching: .any).allElementsBoundByIndex.filter { $0.exists && $0.frame.width > 0 && $0.isHittable } : []
        for name in items {
            let item = app.navigationBars.buttons[name].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5) && item.isHittable, "\(page): its own \(name) is not there to tap")
            let overEls = barControls.filter { $0.frame.intersects(item.frame) }
            for e in overEls { print("OWN-BAR \(page) over \(name): type \(e.elementType.rawValue) id '\(e.identifier)' label '\(e.label)' frame \(e.frame)") }
            let over = overEls.map { $0.identifier.isEmpty ? $0.label : $0.identifier }
            print("OWN-BAR \(page) \(name) at \(item.frame) bar controls over it: \(over)")
            XCTAssertTrue(over.isEmpty, "\(page): the bar's \(over) lie over its \(name)")
        }
    }

    /// How many "Settings" texts the bar holds: the seen title on Settings itself, none on a page
    /// pushed from it. The bar's measuring copy of the title (laid out for its frame, never seen)
    /// read as a second "Settings" on Settings and stayed in the tree on every pushed page.
    private func assertTitleCopies(_ page: String, _ expected: Int) {
        let bar = any("morph.bar")
        guard bar.exists else { return }
        let copies = bar.staticTexts.matching(NSPredicate(format: "label == 'Settings'")).count
        XCTAssertEqual(copies, expected, "\(page): the bar holds \(copies) 'Settings' texts")
    }

    /// Everything the bar holds in the accessibility tree, with whether a tap would reach it.
    private func dumpBar(_ page: String) {
        let bar = any("morph.bar")
        guard bar.exists else { print("OWN-BAR-DUMP \(page) no bar"); return }
        for e in bar.descendants(matching: .any).allElementsBoundByIndex where e.exists {
            print("OWN-BAR-DUMP \(page) type \(e.elementType.rawValue) id '\(e.identifier)' label '\(e.label)' frame \(e.frame) hittable \(e.isHittable)")
        }
    }

    /// Settings › Gateways (the bar's Back) › Edit Gateway (its own Cancel and Save, the bar aside),
    /// Cancel back to Gateways (the bar's Back again), Back to Settings.
    func testEditGatewayKeepsOwnBar() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "settings")
        let gateway = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Workshop'")).firstMatch
        XCTAssertTrue(gateway.waitForExistence(timeout: 15), "no gateway row on Settings")
        pause(2)
        dumpBar("Settings"); assertTitleCopies("Settings", 1)
        print("OWN-BAR-AT push gateways"); gateway.tap(); pause(1.5)
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "Gateways has no bar Back")
        XCTAssertTrue(pushRecord.contains("push animated=true coordinator=true depth=2 ownbar=false"), "Gateways: \(pushRecord)")
        shot("gateways"); dumpBar("Gateways"); assertTitleCopies("Gateways", 0)
        // The row's edit link is the chevron at its trailing end.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Workshop'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no gateway row on Gateways")
        print("OWN-BAR-AT push edit"); at(app.frame.width - 40, row.frame.midY).tap(); pause(1.5)
        shot("edit-gateway")
        assertOwnBar("Edit Gateway", items: ["Cancel", "Save"], depth: 3)
        print("OWN-BAR-AT pop edit"); app.navigationBars.buttons["Cancel"].firstMatch.tap(); pause(1.5)
        shot("back-on-gateways")
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "the bar's Back did not come back on Gateways")
        print("OWN-BAR-AT pop gateways"); any("page.back").tap(); pause(1.5)
        XCTAssertFalse(any("page.back").exists, "Back did not reach Settings")
        XCTAssertTrue(any("morph.title").exists, "the bar's title is not back on Settings")
        assertTitleCopies("Settings again", 1)
    }

    /// Settings › Status › Sign-in (Edit Gateway again, from another way in), Cancel back to Status.
    func testStatusSignInKeepsOwnBar() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "settings")
        let status = any("settings.row.status")
        XCTAssertTrue(any("settings.row.profile").waitForExistence(timeout: 15), "no Settings rows")
        pause(2)
        // Far down a lazy list: in the tree only once scrolled near.
        for _ in 0..<8 where !(status.exists && status.isHittable) { app.swipeUp(velocity: .slow); pause(0.6) }
        XCTAssertTrue(status.exists, "no Status row")
        status.tap(); pause(1.5)
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "Status has no bar Back")
        let signIn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sign-in'")).firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 5), "no Sign-in row on Status")
        signIn.tap(); pause(1.5)
        shot("status-sign-in")
        assertOwnBar("Status › Sign-in", items: ["Cancel", "Save"], depth: 3)
        app.navigationBars.buttons["Cancel"].firstMatch.tap(); pause(1.5)
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "the bar's Back did not come back on Status")
    }

    /// Settings › Scheduled Tasks › a job (Save on the right, the system back on the left), back.
    func testTaskDetailKeepsOwnBar() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "settings")
        let tasks = any("settings.row.cron")
        XCTAssertTrue(any("settings.row.profile").waitForExistence(timeout: 15), "no Settings rows")
        pause(2)
        // Far down a lazy list: in the tree only once scrolled near.
        for _ in 0..<8 where !(tasks.exists && tasks.isHittable) { app.swipeUp(velocity: .slow); pause(0.6) }
        XCTAssertTrue(tasks.exists, "no Scheduled Tasks row")
        tasks.tap(); pause(2)
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "Scheduled Tasks has no bar Back")
        // The first job in the list (a row that pushes, below the page's heading).
        let job = app.buttons.matching(NSPredicate(format: "NOT (identifier BEGINSWITH 'tab.') AND NOT (identifier BEGINSWITH 'page.') AND NOT (identifier BEGINSWITH 'chats.') AND label != '' AND label != 'Back'")).allElementsBoundByIndex
            .first { $0.isHittable && $0.frame.minY > 160 && $0.frame.maxY < app.frame.height - 120 }
        XCTAssertNotNil(job, "no job on Scheduled Tasks")
        print("OWN-BAR task row \(job?.label ?? "")")
        job?.tap(); pause(1.5)
        shot("task-detail")
        assertOwnBar("Task detail", items: ["Save"], depth: 3)
        let systemBack = app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch
        XCTAssertTrue(systemBack.exists && systemBack.isHittable, "the task page has no system back")
        systemBack.tap(); pause(1.5)
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "the bar's Back did not come back on Scheduled Tasks")
    }

    /// Bots › a bot's page › Profile › Instructions (SOUL.md): the editor's own check mark on the
    /// right, the system back on the left, the bar aside; back to the Profile page with the bar's Back.
    func testSoulEditorKeepsOwnBar() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "bots")
        XCTAssertTrue(any("bots.newBot").waitForExistence(timeout: 15), "no Bots page")
        pause(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.26, dy: 0.30)).press(forDuration: 1.2)
        let chats = app.buttons.matching(NSPredicate(format: "label == 'Chats' AND identifier != 'tab.chats'")).firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 5), "no card menu")
        chats.tap()
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "the bot's page has no bar Back")
        pause(1.5); shot("soul-1-bot-page")
        // The page's own Profile row at its top (another "Profile" text further down matched first,
        // and the tap there opened a chat).
        XCTAssertTrue(app.staticTexts["Profile"].firstMatch.waitForExistence(timeout: 5), "no Profile row on the bot's page")
        let profile = try XCTUnwrap(app.staticTexts.matching(NSPredicate(format: "label == 'Profile'")).allElementsBoundByIndex
            .filter { $0.isHittable }.min { $0.frame.minY < $1.frame.minY }, "no Profile row to tap")
        print("OWN-BAR SOUL profile at \(profile.frame)")
        profile.tap(); pause(1.5); shot("soul-2-profile")
        // The SOUL.md row is on the page's Instructions tab.
        let instructions = app.buttons.matching(NSPredicate(format: "label == 'Instructions'")).firstMatch
        if instructions.waitForExistence(timeout: 3) { instructions.tap() } else { app.staticTexts["Instructions"].firstMatch.tap() }
        pause(1)
        let soul = app.buttons.matching(NSPredicate(format: "label CONTAINS 'SOUL.md'")).firstMatch
        for _ in 0..<5 where !(soul.exists && soul.isHittable) { app.swipeUp(velocity: .slow); pause(0.6) }
        XCTAssertTrue(soul.exists && soul.isHittable, "no Instructions (SOUL.md) row")
        soul.tap(); pause(2)
        shot("soul-editor")
        let record = pushRecord
        print("OWN-BAR SOUL.md \(record)")
        XCTAssertTrue(record.contains("push animated=true coordinator=true depth=4"), "SOUL.md: the push was not animated with a coordinator: \(record)")
        XCTAssertFalse(any("page.back").exists, "SOUL.md: the bar's Back is over the page")
        let systemBack = app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch
        XCTAssertTrue(systemBack.exists && systemBack.isHittable, "the SOUL.md page has no system back")
        systemBack.tap(); pause(1.5)
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "the bar's Back did not come back on the Profile page")
    }

    /// Add Gateway is a sheet over Gateways: nothing of the bar may be over its Cancel.
    func testAddGatewaySheetClear() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "settings")
        let gateway = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Workshop'")).firstMatch
        XCTAssertTrue(gateway.waitForExistence(timeout: 15), "no gateway row on Settings")
        pause(2)
        gateway.tap(); pause(1.5)
        let add = any("settings.addGateway")
        XCTAssertTrue(add.waitForExistence(timeout: 5), "no Add Gateway on Gateways")
        add.tap(); pause(1.5)
        shot("add-gateway")
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5) && cancel.isHittable, "Add Gateway's Cancel is not there to tap")
        let back = any("page.back")
        print("OWN-BAR add-gateway cancel \(cancel.frame) bar back exists=\(back.exists) hittable=\(back.exists && back.isHittable) at \(back.exists ? back.frame : .zero)")
        XCTAssertFalse(back.exists && back.isHittable && back.frame.intersects(cancel.frame), "the bar's Back is over Add Gateway's Cancel")
        cancel.tap(); pause(1)
    }
}
