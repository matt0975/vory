import XCTest

/// Hitches in the moments that have to be smooth (1.5, Matt: "absolutely smooth"): the push
/// into a chat and the pop back, the + panel, the bot card, the model chip, the list's View
/// menu, a settings sheet, a long thread's scroll and a whole turn. Each flow is measured with
/// XCTest's os_signpost hitch metrics (hitch time per second, the hitch count and the frame
/// rate) over the app's `Smooth` animation intervals, or the system's navigation and scroll
/// intervals. The numbers are the table for review; the simulator's are a rough guide,
/// the device's are the bar. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
final class SmoothnessPerfUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func launch(url: String, token: String, tab: String = "chats", extra: [String] = []) {
        // HERMES_E2E_ARGS: extra launch arguments, space-separated (the measurement switches).
        let args = ["-companionPromptShown", "YES", "-launchTab", tab, "-colorSchemePreference", "light", "-chat.showBots", "YES", "-chats.allBots", "YES"] + extra
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

    private func smooth(_ name: String) -> XCTOSSignpostMetric {
        XCTOSSignpostMetric(subsystem: "Vory", category: "Smooth", name: name)
    }

    /// Ten rounds for the quick flows (a single hitch in five rounds is noise; a mean and a worst
    /// should mean something), five for the long ones (a fling is 2.4 s each).
    private func rounds(_ n: Int) -> XCTMeasureOptions {
        let o = XCTMeasureOptions()
        o.iterationCount = n
        o.invocationOptions = [.manuallyStop]
        return o
    }
    private var options: XCTMeasureOptions { rounds(10) }
    private var longOptions: XCTMeasureOptions { rounds(5) }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    /// A system permission alert left over the app (the phone put up "add to your photo library"
    /// once between runs and every tap went to it): answered, so the flow goes on.
    private func clearSystemAlert() {
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for name in ["Allow", "OK", "Don’t Allow"] {
            let b = board.buttons[name]
            if b.waitForExistence(timeout: 1) { b.tap(); pause(0.5); return }
        }
    }

    private func openFirstChat() {
        clearSystemAlert()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "no chat row")
        row.tap()
        XCTAssertTrue(any("chat.dock").waitForExistence(timeout: 20), "the chat did not open")
    }

    private func back() {
        // The header's own Back circle, or the system back button when the chat shows the
        // real navigation bar (the morph prototype, `-vory-morph-header`).
        var b = any("chat.back")
        if !b.waitForExistence(timeout: 3) { b = app.navigationBars.buttons.firstMatch }
        XCTAssertTrue(b.waitForExistence(timeout: 10), "no Back")
        // A touch at its centre, not the element tap: on the device the element tap activates
        // through accessibility and a glass-hosted button did not answer it.
        b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch.waitForExistence(timeout: 10), "the list did not come back")
    }

    /// list → chat → back: the system's navigation transition intervals.
    func testListToChatAndBack() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch.waitForExistence(timeout: 40))
        pause(2)
        measure(metrics: [XCTOSSignpostMetric.navigationTransitionMetric], options: options) {
            openFirstChat(); pause(1)
            back(); pause(1)
            stopMeasuring()
        }
    }

    /// Diagnostic, not a measurement: one back swipe and one button Back, for the order of
    /// the app's "pop:" notes in the log (when the path empties against the transition's end).
    func testSwipeBackOrder() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        openFirstChat(); pause(1.5)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch.waitForExistence(timeout: 10), "the swipe did not go back")
        pause(1.5)
        openFirstChat(); pause(1.5)
        back(); pause(1.5)
    }

    /// A chat this device has never opened (no transcript or settings cache), pushed and popped:
    /// for a frame check of what the page shows before its history lands.
    func testColdOpen() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        // A fresh install on the phone asks about the local network first; the list waits on it.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        waitForList()
        pause(2.5)
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Weekly dependency audit'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "no audit chat")
        let row = try XCTUnwrap(rows.allElementsBoundByIndex.min { $0.frame.minY < $1.frame.minY }, "no audit chat on screen")
        row.tap()
        XCTAssertTrue(any("chat.dock").waitForExistence(timeout: 20), "the chat did not open")
        pause(3)
        back(); pause(1.5)
    }

    /// A fast back swipe out of a chat, for a frame check of the bar and the list's top coming
    /// back (Matt, 2026-10-12: "swiping back fast the nav bar pops up kinda choppy").
    func testFastSwipeBack() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        openFirstChat(); pause(2)
        for _ in 0..<3 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)), withVelocity: .fast, thenHoldForDuration: 0)
            // The list's first row on screen, not the hidden copy the Chats tab leaves in the
            // accessibility tree (#326): a cancelled flick passed this check before.
            let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'"))
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "the swipe did not go back")
            XCTAssertTrue(rows.allElementsBoundByIndex.contains { $0.isHittable }, "the list is not on screen")
            pause(1.5)
            openFirstChat(); pause(2)
        }
        back(); pause(1.5)
    }

    /// Pull to refresh with the search drawer hidden, then reveal the drawer and pull again,
    /// for a frame check that the refresh spinner does not draw inside the search field (the
    /// 2026-10-10 bug the old pinned field caused; Matt, 2026-10-12 moved to the native drawer).
    func testSearchDrawerAndRefresh() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        // Drawer hidden: a slow pull from the top refreshes (and flashes the drawer on the way).
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .slow, thenHoldForDuration: 0.1)
        pause(2.5)
        // Reveal the drawer and leave it shown: a short pull.
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)), withVelocity: .slow, thenHoldForDuration: 0.2)
        pause(1.5)
        // Drawer shown: pull to refresh again.
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .slow, thenHoldForDuration: 0.1)
        pause(2.5)
    }

    /// Every root page's heading and its pull-to-refresh (Home, Files, Settings, then Chats): a
    /// screenshot at rest and one mid-refresh each, for a look at the wheel beside the title.
    func testPageHeadings() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        let slots = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).allElementsBoundByIndex
        let tabs = slots.map { String($0.identifier.dropFirst(4)) }.filter { $0 != "chats" } + ["chats"]
        for tab in tabs {
            let slot = app.descendants(matching: .any).matching(identifier: "tab.\(tab)").firstMatch
            if slot.waitForExistence(timeout: 5) { slot.tap(); pause(1.5) }
            shot("\(tab)-rest")
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .slow, thenHoldForDuration: 0.1)
            // The wheel's spinner is the one accessible part of the pull ("Refreshing"): its
            // presence after the release is the page's verdict, not a screenshot's timing.
            let spinning = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Refreshing'")).firstMatch.waitForExistence(timeout: 1.5)
            print("PULL-WHEEL \(tab) \(spinning ? "spinning" : "none")")
            shot("\(tab)-refreshing")
            pause(1.5)
        }
    }

    /// The list keeps its place through a chat and back (Matt, 2026-10-12: "the chats list
    /// jumps, so it'll almost reload everything when going back"): scrolled a screen down, a
    /// row's frame before the chat opens equals its frame after the swipe back.
    func testListKeepsPlaceAfterBack() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        app.swipeUp(velocity: .slow); pause(1.5)
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Standup notes' OR label CONTAINS[c] 'Backup verification'"))
        guard let row = rows.allElementsBoundByIndex.first(where: { $0.isHittable }) else { shot("list-no-row"); return XCTFail("no row to track after the scroll") }
        let before = row.frame; shot("list-before")
        print("LIST-PLACE before \(before)")
        row.tap(); pause(2.5)
        XCTAssertTrue(any("chat.dock").waitForExistence(timeout: 10), "the chat did not open")
        shot("chat-open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
        pause(0.2); shot("list-back-early"); pause(1.5); shot("list-back")
        let after = rows.allElementsBoundByIndex.first(where: { $0.label == row.label })?.frame ?? .zero
        print("LIST-PLACE after \(after)")
        XCTAssertEqual(before.minY, after.minY, accuracy: 2, "the list moved after the swipe back: \(before) → \(after)")
    }

    /// Step D before-pictures: the states that meet the Duo's fold, each held HERMES_E2E_STEP
    /// seconds (default 7) while the displays are recorded from outside: the composer with the
    /// keyboard, the + panel, the "/" list, then the Bots grid. Prints "STEPD <state> <time>".
    func testStepDStates() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        let hold = Double(ProcessInfo.processInfo.environment["HERMES_E2E_STEP"] ?? "7") ?? 7
        func mark(_ s: String) { print("STEPD \(s) \(Date().timeIntervalSince1970)") }
        launch(url: url, token: token)
        waitForList()
        openFirstChat(); pause(2)
        let field = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no composer field")
        field.tap(); pause(0.5); field.typeText("Draft kept across the fold"); pause(1)
        mark("composer-keyboard"); pause(hold)
        if let plus = app.buttons.matching(NSPredicate(format: "label == 'Attach'")).allElementsBoundByIndex.first(where: { $0.isHittable }) {
            plus.tap(); pause(1.5); mark("plus-panel"); pause(hold)
            if let close = app.buttons.matching(NSPredicate(format: "label == 'Close attach panel'")).allElementsBoundByIndex.first(where: { $0.isHittable }) { close.tap() } else { plus.tap() }
            pause(1)
        } else { mark("plus-panel-missing") }
        // The "/" list opens on a "/" at the start of the text: the draft goes first.
        field.tap(); pause(0.5)
        for _ in 0..<26 { field.typeText(XCUIKeyboardKey.delete.rawValue) }
        pause(0.5); field.typeText("/"); pause(1.5); mark("slash-list"); pause(hold)
        field.typeText(XCUIKeyboardKey.delete.rawValue); pause(1)
        // The tab bar is away inside a chat: Back to the list first.
        back(); pause(2)
        let bots = app.descendants(matching: .any).matching(identifier: "tab.bots").firstMatch
        if bots.waitForExistence(timeout: 3) { bots.tap(); pause(2); mark("bots-grid"); pause(hold) } else { mark("bots-grid-missing") }
        mark("done")
    }

    /// A chat opened in landscape, then turned upright: where the bar's Back and pill are for
    /// accessibility, and whether Back's tap leaves the chat (BarAfterRotationUITests fails
    /// there; the probe shows the bar active with the chat adopted).
    func testBackFrameAfterTurn() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        XCUIDevice.shared.orientation = .landscapeLeft; pause(2.5)
        openFirstChat(); pause(1.5)
        let back = app.buttons["chat.back"].firstMatch, pill = app.buttons["chat.titlePill"].firstMatch, more = app.buttons["chat.more"].firstMatch
        print("BACK-FRAME landscape back \(back.frame) pill \(pill.frame) more \(more.frame) window \(app.windows.firstMatch.frame)")
        XCUIDevice.shared.orientation = .portrait; pause(2.5)
        print("BACK-FRAME portrait back \(back.frame) hittable \(back.isHittable) pill \(pill.frame) more \(more.frame) window \(app.windows.firstMatch.frame)")
        back.tap(); pause(1.5)
        print("BACK-FRAME after-tap dock \(any("chat.dock").exists) profile.close \(app.buttons["profile.close"].firstMatch.exists) rows \(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).count)")
        XCUIDevice.shared.orientation = .portrait
    }

    /// Severity of the keyboard-up turn (BarAfterRotation's failing part): a chat opened in
    /// landscape with the composer focused, turned upright; does Back exist and is it hittable,
    /// and does the edge swipe still leave the chat?
    func testKeyboardTurnSwipeBack() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        XCUIDevice.shared.orientation = .landscapeLeft; pause(2.5)
        openFirstChat(); pause(1.5)
        let field = app.textViews["composer.text"].firstMatch
        if field.waitForExistence(timeout: 5) { field.tap(); pause(1) }
        XCUIDevice.shared.orientation = .portrait; pause(2.5)
        let back = app.buttons["chat.back"].firstMatch
        print("KB-TURN back exists \(back.exists) hittable \(back.exists ? back.isHittable : false) frame \(back.exists ? back.frame : .zero) keyboard \(app.keyboards.count)")
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        shot("kb-turn-portrait")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
        pause(2)
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'"))
        let out = rows.allElementsBoundByIndex.contains { $0.isHittable }
        print("KB-TURN swipe-back left the chat: \(out) dock \(any("chat.dock").exists)")
        shot("kb-turn-after-swipe")
        XCUIDevice.shared.orientation = .portrait
    }

    /// Away to the Home screen and back, three times: how long until the list answers, and a
    /// recording for the frames of the return (Matt, 2026-10-12: "opening task switcher and
    /// then back to Vory app still has that weird lag time").
    func testAppSwitchReturn() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'"))
        for i in 1...3 {
            XCUIDevice.shared.press(.home); pause(1.5)
            let t0 = Date()
            app.activate()
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, !(rows.firstMatch.exists && rows.firstMatch.isHittable) { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            print("APP-SWITCH return \(i): list answered after \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            pause(2)
        }
    }

    /// A page pushed on a tab other than Chats (a Settings row), then the edge swipe back: the
    /// bar's capsules must not stand over the pushed page, nor come back before the page has
    /// gone (Matt, 2026-10-12: "swiping back on other pages is broken"), and the title capsule
    /// must be back and live once the page is at its root.
    func testPushedPageSwipeBack() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "settings")
        pause(4)
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        // A Settings row pushes its page; the bar's title capsule is `morph.title`. Not the word:
        // the tab bar's selected tab carries "Settings" too, under the gear, and stays over a
        // pushed page (the first match was the bar's unseen measuring copy until it left the tree).
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no settings row")
        let title = any("morph.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5) && title.isHittable, "no Settings title capsule at the root")
        func openRow() { for _ in 0..<3 { row.tap(); if any("page.back").firstMatch.waitForExistence(timeout: 3) { break } }; pause(1.5) }
        openRow(); shot("settings-pushed")
        XCTAssertTrue(any("page.back").firstMatch.exists, "the pushed page has no Back capsule")
        XCTAssertFalse(title.exists && title.isHittable, "the Settings title capsule stands over the pushed page")
        // A slow edge swipe, let go past the middle.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
        pause(1.5); shot("settings-back")
        XCTAssertTrue(title.waitForExistence(timeout: 5) && title.isHittable, "the Settings title capsule is not back")
        // A cancelled swipe: the pushed page stays, where it was, and the capsule stays away.
        openRow()
        // The pushed page's own header (the first row is Gateways): it must not move.
        let header = app.staticTexts["Gateways"].firstMatch
        let headerTop = header.waitForExistence(timeout: 3) ? header.frame.minY : nil
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
        pause(1.5); shot("settings-cancelled")
        XCTAssertTrue(any("page.back").firstMatch.exists, "the cancelled swipe lost the pushed page")
        XCTAssertFalse(title.exists && title.isHittable, "the Settings title capsule came back over the pushed page after a cancelled swipe")
        if let headerTop {
            print("CANCEL-HEADER before \(headerTop) after \(header.frame.minY)")
            XCTAssertEqual(header.frame.minY, headerTop, accuracy: 1, "the pushed page's content moved after a cancelled swipe (its bar collapsed?)")
        }
        any("page.back").firstMatch.tap(); pause(1.5)
        XCTAssertTrue(title.waitForExistence(timeout: 5) && title.isHittable, "the Settings title capsule is not back after Back")
        // A fast flick from the edge (to 0.9, as testSwipeBackKinds; a shorter one never popped
        // the page). The system decides whether it pops (on the phone it sometimes cancels a
        // synthesized flick from 80% across), and the bar must match what it chose: the root's
        // row on screen again means it popped.
        openRow()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)), withVelocity: .fast, thenHoldForDuration: 0)
        pause(1.5); shot("settings-flicked")
        let popped = row.exists && row.isHittable
        print("FLICK \(popped ? "popped" : "cancelled")")
        if popped {
            XCTAssertTrue(title.waitForExistence(timeout: 5) && title.isHittable, "the Settings title capsule is not back after a flick")
            XCTAssertFalse(any("page.back").exists, "the Back circle stayed after a flick popped the page")
        } else {
            XCTAssertTrue(any("page.back").exists, "a cancelled flick lost the Back circle")
            XCTAssertFalse(title.exists && title.isHittable, "the Settings title capsule came back over the page after a cancelled flick")
        }
    }

    /// A bot's shape changed in its card (Look, then a shape), then the list and the Bots page,
    /// and the Bots page again after a relaunch (Matt on 1.5 (17): changing a bot from Cloud to
    /// Circle broke its look): stills to hold the changed bot against the others.
    /// The bot starts as HERMES_E2E_SHAPE_FROM (Cloud; set, then a relaunch, so the Bots page is
    /// first drawn with it, as Matt's was) and becomes HERMES_E2E_SHAPE (Circle).
    func testShapeChange() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        let e = ProcessInfo.processInfo.environment
        let from = e["HERMES_E2E_SHAPE_FROM"] ?? "Cloud", target = e["HERMES_E2E_SHAPE"] ?? "Circle"
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        func changeShape(to shape: String) {
            openFirstChat(); pause(1.5)
            let pill = any("chat.titlePill")
            XCTAssertTrue(pill.waitForExistence(timeout: 5), "no title pill")
            pill.tap(); pause(1.5)
            let look = app.buttons["Look"].firstMatch
            XCTAssertTrue(look.waitForExistence(timeout: 5), "no Look tab in the bot's card")
            look.tap(); pause(1)
            let tile = app.buttons[shape].firstMatch
            for _ in 0..<4 where !tile.isHittable { app.swipeUp(velocity: .slow); pause(0.5) }
            XCTAssertTrue(tile.waitForExistence(timeout: 5), "no \(shape) tile")
            tile.tap(); pause(1.5); shot("studio-\(shape)")
            if app.buttons["Done"].exists { app.buttons["Done"].tap() } else if app.buttons["Close"].exists { app.buttons["Close"].tap() }
            pause(1); shot("chat-\(shape)")
            back(); pause(1.5)
        }
        launch(url: url, token: token)
        waitForList()
        changeShape(to: from)
        launch(url: url, token: token)
        waitForList()
        any("tab.bots").tap(); pause(2); shot("bots-before")
        any("tab.chats").tap(); pause(1.5)
        changeShape(to: target); shot("list-after")
        any("tab.bots").tap(); pause(2); shot("bots-after")
        launch(url: url, token: token, tab: "bots")
        pause(4); shot("bots-relaunch")
    }

    /// Every root's title capsule on the same line (Matt on 1.5 (17): "the title headings like bot
    /// and settings they should all be on the exact same spot"): the same centre line on every
    /// tab, and the same leading edge on the tabs without a round control before it (Chats' bot,
    /// Files' Home).
    func testHeadingSpotEveryRoot() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        let slots = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).allElementsBoundByIndex
        let tabs = slots.map { String($0.identifier.dropFirst(4)) }
        var frames: [(tab: String, frame: CGRect, lead: Bool)] = []
        for tab in tabs {
            let slot = any("tab.\(tab)")
            if slot.waitForExistence(timeout: 5) { slot.tap(); pause(1.2) }
            let title = any("morph.title")
            XCTAssertTrue(title.waitForExistence(timeout: 5), "\(tab): no title capsule")
            let lead = any("chats.profile").exists || any("files.home").exists
            print("HEADING \(tab) \(title.frame) lead=\(lead)")
            frames.append((tab, title.frame, lead))
        }
        // XCTest reports either the title's text or its whole capsule, from one tab to the next
        // (on the 17 Pro: the text on Chats and Bots, the capsule on the others), so the line is
        // the centre, and a text's leading edge is taken back to its capsule's by the capsule's
        // padding (12 pt).
        guard let first = frames.first else { return XCTFail("no tabs") }
        for f in frames {
            XCTAssertEqual(f.frame.midY, first.frame.midY, accuracy: 0.5, "\(f.tab)'s title is not on \(first.tab)'s line")
        }
        func capsuleLeading(_ r: CGRect) -> CGFloat { r.height > 30 ? r.minX : r.minX - 12 }
        let bare = frames.filter { !$0.lead }
        for f in bare.dropFirst() {
            XCTAssertEqual(capsuleLeading(f.frame), capsuleLeading(bare[0].frame), accuracy: 0.5, "\(f.tab)'s title does not start where \(bare[0].tab)'s does")
        }
    }

    /// A chat composed from a page pushed on Settings, then closed: the app goes back to Settings
    /// with the page still pushed, and the bar is that page's (its Back), not Settings' title
    /// capsule (the bar kept the closing chat's state through the switch back).
    func testComposeFromPushedPage() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "settings")
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no settings row")
        pause(2)
        for _ in 0..<3 where !any("page.back").exists && row.exists { row.tap(); _ = any("page.back").waitForExistence(timeout: 5) }
        XCTAssertTrue(any("page.back").exists, "the pushed page has no Back capsule")
        let compose = any("chats.new")
        XCTAssertTrue(compose.waitForExistence(timeout: 5), "no compose button")
        compose.tap(); pause(2); shot("composed")
        let chatBack = any("chat.back")
        XCTAssertTrue(chatBack.waitForExistence(timeout: 8), "the new chat did not open")
        chatBack.tap(); pause(2); shot("returned")
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "back on Settings, the pushed page has no Back capsule")
        XCTAssertFalse(any("morph.title").exists && any("morph.title").isHittable, "Settings' title capsule stands over the pushed page")
        XCTAssertFalse(any("chat.back").exists, "the chat's Back stayed after the chat closed")
    }

    /// A page pushed from a pushed page (Bots › a bot's page › Profile, depth 3): it slides in,
    /// shows no system back button of its own beside the bar's Back (1.5 (18) hid it before the
    /// push; the probe has to hear pushes past the root), and Back pops one page at a time. The
    /// bot's page comes through its card's menu ("Chats"): a tap on a card lands on its face.
    func testPushedPageDepthThree() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "bots", extra: ["-vory-geometry-probe"])
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        let plus = any("bots.newBot")
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "no + on the Bots page")
        pause(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.26, dy: 0.30)).press(forDuration: 1.2)
        let chats = app.buttons.matching(NSPredicate(format: "label == 'Chats' AND identifier != 'tab.chats'")).firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 5), "no card menu")
        chats.tap()
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "the bot's page has no Back capsule")
        pause(1.5)
        let profile = app.staticTexts["Profile"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 5), "no Profile row on the bot's page")
        profile.tap()
        pause(1.5); shot("depth3")
        XCTAssertFalse(profile.exists && profile.isHittable, "the bot's Profile page did not come in")
        let record = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'probe push '")).firstMatch
        print("PUSH-RECORD depth3 \(record.exists ? record.label : "none")")
        XCTAssertTrue(record.exists && record.label.contains("push animated=true coordinator=true depth=3"), "the depth-3 push was not animated: \(record.exists ? record.label : "no record")")
        let systemBack = app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch
        XCTAssertFalse(systemBack.exists && systemBack.isHittable, "the depth-3 page shows the system's back button")
        XCTAssertTrue(any("page.back").exists, "the depth-3 page has no Back capsule")
        any("page.back").tap(); pause(1.5)
        // One page back: the bot's page, still a pushed page (the bar's Back, no Bots +).
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "Back went past the bot's page")
        XCTAssertFalse(plus.exists && plus.isHittable, "Back went past the bot's page")
        any("page.back").tap(); pause(1.5)
        XCTAssertTrue(plus.waitForExistence(timeout: 5) && plus.isHittable, "Back did not go to the Bots page")
    }

    /// A swipe back from a page three deep (a bot's Profile) to the one under it (the bot's page)
    /// leaves the bar's Back circle: the bar follows only a swipe to the root (it went to the root's
    /// title and stayed there). The next swipe, to the root, still morphs the bar to the root.
    func testSwipeBackFromDepthThree() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "bots")
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        func swipeBack() {
            let y = app.frame.height * 0.55
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: y))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.85, dy: y)), withVelocity: .default, thenHoldForDuration: 0)
            pause(1.5)
        }
        let plus = any("bots.newBot")
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "no + on the Bots page")
        pause(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.26, dy: 0.30)).press(forDuration: 1.2)
        let chats = app.buttons.matching(NSPredicate(format: "label == 'Chats' AND identifier != 'tab.chats'")).firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 5), "no card menu")
        chats.tap()
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "the bot's page has no Back capsule")
        pause(1.5)
        let profile = try XCTUnwrap(app.staticTexts.matching(NSPredicate(format: "label == 'Profile'")).allElementsBoundByIndex
            .filter { $0.isHittable }.min { $0.frame.minY < $1.frame.minY }, "no Profile row")
        profile.tap(); pause(1.5)
        XCTAssertTrue(any("page.back").exists, "the Profile page has no Back capsule")
        // Depth 3 back to 2 by a swipe: the Back circle stays.
        swipeBack(); shot("depth3-swiped-to-2")
        XCTAssertTrue(any("page.back").exists && any("page.back").isHittable, "a swipe from depth 3 took the bar's Back away")
        XCTAssertFalse(plus.exists && plus.isHittable, "the swipe from depth 3 went past the bot's page")
        // Depth 2 back to the root by a swipe: the bar is the root's again.
        swipeBack(); shot("depth2-swiped-to-root")
        XCTAssertTrue(plus.waitForExistence(timeout: 5) && plus.isHittable, "the swipe to the root did not bring the Bots + back")
        XCTAssertFalse(any("page.back").exists, "the Back circle stayed at the root")
    }

    /// A sheet from a root and back (Bots' and Projects' +, then Cancel): the probes take the
    /// presentation for no push, so the bar stays at the root (its +, no Back) and nothing is recorded.
    /// No root presents a full-screen cover; these sheets are the roots' only presentations.
    func testRootSheetKeepsBar() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "bots", extra: ["-vory-geometry-probe"])
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        let pushRecord = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'probe push '")).firstMatch
        for (tab, id) in [("bots", "bots.newBot"), ("projects", "projects.new")] {
            let slot = any("tab.\(tab)")
            guard slot.waitForExistence(timeout: 3) else { print("ROOT-SHEET no \(tab) tab"); continue }
            slot.tap(); pause(1.5)
            let plus = any(id)
            XCTAssertTrue(plus.waitForExistence(timeout: 10), "no + on \(tab)")
            plus.tap()
            XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "\(tab)'s sheet did not open")
            pause(0.5); app.buttons["Cancel"].tap(); pause(1.5); shot("\(tab)-after-sheet")
            XCTAssertFalse(any("page.back").exists, "\(tab) shows a Back after its sheet closed")
            XCTAssertTrue(plus.exists && plus.isHittable, "\(tab)'s + is gone after its sheet closed")
            XCTAssertFalse(pushRecord.exists, "\(tab)'s sheet was taken for a push: \(pushRecord.exists ? pushRecord.label : "")")
        }
    }

    /// A page pushed on Settings, then Chats and back: the pushed page's Back belongs to its tab
    /// (Chats shows its own title and no Back), and it is there again back on Settings.
    func testPushedPageTabSwitch() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "settings")
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no settings row")
        pause(2)
        for _ in 0..<3 where !any("page.back").exists && row.exists { row.tap(); _ = any("page.back").waitForExistence(timeout: 5) }
        XCTAssertTrue(any("page.back").exists, "the pushed page has no Back capsule")
        any("tab.chats").tap(); pause(1.6); shot("pushed-then-chats")
        XCTAssertFalse(any("page.back").exists, "Settings' Back stands on Chats")
        any("tab.settings").tap(); pause(1.6); shot("chats-then-settings")
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "the pushed page lost its Back after a tab switch")
    }

    /// Holds the Bots page at rest for HERMES_E2E_HOLD seconds (default 14): the cards' faces
    /// blink by picture swap; with `-bots.glassAll YES` in HERMES_E2E_ARGS they are glass bots.
    func testHoldBots() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "bots")
        pause(3)
        pause(Double(ProcessInfo.processInfo.environment["HERMES_E2E_HOLD"] ?? "14") ?? 14)
    }

    /// Holds a page pushed on Settings (its first row) at rest for HERMES_E2E_HOLD seconds
    /// (default 14), for an idle CPU reading from outside: nothing may run per frame under a
    /// pushed page (the battery rule, #248).
    func testHoldPushedPage() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "settings")
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no settings row")
        pause(2)
        let id = row.identifier
        // A tap that pushed takes the row away with the root: tap again only while it is there.
        for _ in 0..<3 where !any("page.back").exists && row.exists { row.tap(); _ = any("page.back").waitForExistence(timeout: 5) }
        XCTAssertTrue(any("page.back").exists, "the pushed page has no Back capsule")
        let hold = Double(ProcessInfo.processInfo.environment["HERMES_E2E_HOLD"] ?? "14") ?? 14
        print("HOLD-PUSHED start \(id) \(hold)s")
        pause(hold)
    }

    /// A turn running while the list shows: the first chat is sent "tools" (the mock's long turn
    /// of tool calls, no approval), then the list holds for HERMES_E2E_HOLD seconds (default 18)
    /// while that row's face works and then spins as it finishes. For a recording: a small row
    /// face keeps its cached still under the live view, and the still's outline must never show
    /// behind the moving face (the Mac's question; its row faces don't move).
    func testRowFaceDuringTurn() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        // Rows show their bots only with All bots on (the launch argument arrives as a string,
        // which the list's setting does not read): on through the chip's menu.
        let chip = any("chats.profile")
        if chip.waitForExistence(timeout: 5) {
            chip.tap(); pause(1)
            let all = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'All bots'")).firstMatch
            if all.waitForExistence(timeout: 3) { all.tap(); pause(1.5) }
        }
        openFirstChat(); pause(1.5)
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")
        composer.tap(); pause(0.5)
        composer.typeText("tools")
        let send = app.buttons.matching(identifier: "composer.send").firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no send button")
        send.tap(); pause(1.5)
        back(); pause(1)
        let hold = Double(ProcessInfo.processInfo.environment["HERMES_E2E_HOLD"] ?? "18") ?? 18
        print("ROW-FACE hold \(hold)s")
        pause(hold)
    }

    /// Holds the Chats list at rest for HERMES_E2E_HOLD seconds (default 14): the recording
    /// shows whether a row's face changes beyond a blink.
    func testHoldList() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        pause(Double(ProcessInfo.processInfo.environment["HERMES_E2E_HOLD"] ?? "14") ?? 14)
    }

    /// Holds the app in a chat with a draft for HERMES_E2E_HOLD seconds (default 600) while the
    /// Duo's hinge is driven from outside (Device Hub), for screen recordings and stills.
    func testHoldChatWithDraft() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        openFirstChat(); pause(2)
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        if field.waitForExistence(timeout: 5) { field.tap(); pause(0.5); field.typeText("Draft kept across the fold"); pause(0.5) }
        let hold = Double(ProcessInfo.processInfo.environment["HERMES_E2E_HOLD"] ?? "600") ?? 600
        print("HOLD start \(hold)s")
        pause(hold)
    }

    /// Hidden tab pages stay out of the accessibility tree (#326): on Chats, each chat row is
    /// found once (Home lists the recent chats too), and none of Home's activity blocks show.
    func testHiddenPagesOutOfTheTree() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "dashboard")
        pause(3)
        let home = app.descendants(matching: .any).matching(identifier: "tab.chats").firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 10)); home.tap(); pause(2)
        waitForList()
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).count
        let blocks = app.otherElements.matching(NSPredicate(format: "label CONTAINS ' sessions'")).count
        print("AX-TREE chats rows=\(rows) home-blocks=\(blocks)")
        XCTAssertEqual(rows, 1, "the chat row is in the tree \(rows) times")
        XCTAssertEqual(blocks, 0, "Home's activity blocks are in the Chats tree")
    }

    /// The pull-to-refresh wheel on every root that can refresh (Matt, 2026-10-12: "the pull to
    /// refresh wheel doesn't appear on some of the pages"): the bar is relaunched with each group
    /// of four tabs, every page pulled, and the wheel's "Refreshing" looked for after the release.
    func testPullWheelEveryRoot() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        // Four slots on the bar, Chats and Settings always among them: two pages per launch.
        let groups = [["dashboard", "bots"], ["files", "projects"], ["kanban", "sessions"], ["cron", "status"], ["approvals", "system", "settings"]]
        let canRefresh: Set<String> = ["chats", "dashboard", "bots", "files", "projects", "kanban", "sessions", "cron", "status"]
        var missing: [String] = []
        for group in groups {
            // The once-per-phone Home-first write would replace the layout: mark it done.
            launch(url: url, token: token, extra: ["-tabLayout", (["chats"] + group).joined(separator: ","), "-tabLayout.homeFirstApplied", "YES"])
            waitForList()
            for tab in group + ["chats"] {
                let slot = app.descendants(matching: .any).matching(identifier: "tab.\(tab)").firstMatch
                // A page the gateway cannot show (the Board without its plugin) has no slot.
                guard slot.waitForExistence(timeout: 5) else { print("PULL-WHEEL \(tab) no-slot"); continue }
                slot.tap(); pause(1.5)
                let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)), withVelocity: .slow, thenHoldForDuration: 0.1)
                let wheel = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Refreshing'")).firstMatch
                let spinning = wheel.waitForExistence(timeout: 1.5)
                print("PULL-WHEEL \(tab) \(spinning ? "spinning at \(wheel.frame.origin)" : "none")")
                shot("\(tab)-refreshing")
                if canRefresh.contains(tab), !spinning { missing.append(tab) }
                pause(1.5)
            }
            app.terminate()
        }
        XCTAssertTrue(missing.isEmpty, "no pull wheel on: \(missing.joined(separator: ", "))")
    }

    /// Every way back out of a chat, for a clip and a hitch trace: a slow swipe let go past the
    /// middle, a fast flick, a swipe let go early (cancelled), and the Back button.
    func testSwipeBackKinds() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        func edge(_ y: CGFloat = 0.5) -> XCUICoordinate { app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: y)) }
        func at(_ x: CGFloat) -> XCUICoordinate { app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)) }
        func listBack() {
            let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'"))
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10) && rows.allElementsBoundByIndex.contains { $0.isHittable }, "the list is not back")
            pause(1.5)
        }
        openFirstChat(); pause(2)
        // 1. A slow swipe, let go past the middle.
        edge().press(forDuration: 0.1, thenDragTo: at(0.7), withVelocity: .slow, thenHoldForDuration: 0.3)
        listBack()
        openFirstChat(); pause(2)
        // 2. A fast flick (to 0.9: at 0.8 the device sometimes decided a cancel).
        edge().press(forDuration: 0.05, thenDragTo: at(0.9), withVelocity: .fast, thenHoldForDuration: 0)
        listBack()
        openFirstChat(); pause(2)
        // 3. A swipe let go early: cancelled, the chat stays.
        edge().press(forDuration: 0.1, thenDragTo: at(0.22), withVelocity: .slow, thenHoldForDuration: 0.3)
        pause(1.5)
        XCTAssertTrue(any("chat.dock").exists, "the cancelled swipe left the chat")
        // 4. The Back button.
        back(); pause(1.5)
    }


    /// Diagnostic for the morph prototype's Back on the device: where the Back element is, whether
    /// it is hittable, and what is on screen after the tap.
    func testMorphBackDiag() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        openFirstChat(); pause(2)
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        let backs = app.descendants(matching: .any).matching(identifier: "chat.back").allElementsBoundByIndex
        var lines = ["chat.back count=\(backs.count)"]
        for (i, b) in backs.enumerated() { lines.append("[\(i)] frame=\(b.frame) hittable=\(b.isHittable) type=\(b.elementType.rawValue) label=\(b.label)") }
        lines.append("navBars=\(app.navigationBars.count)")
        let t = XCTAttachment(string: lines.joined(separator: "\n")); t.name = "back-diag"; t.lifetime = .keepAlways; add(t)
        shot("before-tap")
        if let b = backs.first { b.tap() }
        pause(1.5)
        shot("after-tap")
        let dockStill = any("chat.dock").exists
        let t2 = XCTAttachment(string: "dock still there after tap: \(dockStill)"); t2.name = "back-diag-2"; t2.lifetime = .keepAlways; add(t2)
        if dockStill, let b = backs.first { b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5); shot("after-coord-tap") }
    }

    /// Diagnostic: a cancelled swipe, then Back (the morph prototype's Back died after a cancel).
    func testMorphCancelThenBack() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        openFirstChat(); pause(2)
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        func note(_ name: String, _ s: String) { let a = XCTAttachment(string: s); a.name = name; a.lifetime = .keepAlways; add(a) }
        func backState() -> String {
            let b = any("chat.back")
            return "exists=\(b.exists) hittable=\(b.exists ? b.isHittable : false) frame=\(b.exists ? b.frame : .zero) dock=\(any("chat.dock").exists)"
        }
        note("before-cancel", backState())
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
        pause(1.5)
        note("after-cancel", backState())
        shot("after-cancel")
        any("chat.back").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        pause(1.5)
        note("after-back", backState())
        shot("after-back")
        // If the element's centre missed, a touch on the circle itself (its place at rest).
        if any("chat.dock").exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 38.0 / 402.0, dy: 89.0 / 874.0)).tap()
            pause(1.5)
            note("after-circle-tap", backState())
            shot("after-circle-tap")
        }
    }

    /// The morph prototype's controls, each activated through accessibility (the element tap,
    /// which is VoiceOver's path), not by a touch at its coordinates: a glass-hosted control
    /// on the device answered a touch but not that path until it was given an explicit action.
    func testMorphControlsActivate() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList(); clearSystemAlert()
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        func dismissMenu() { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap(); pause(0.8) }
        func menu(_ id: String, shows item: String) {
            let c = any(id)
            XCTAssertTrue(c.waitForExistence(timeout: 5), "\(id) is not there")
            c.tap(); pause(1)
            let found = app.buttons[item].waitForExistence(timeout: 3) || app.staticTexts[item].exists || app.switches[item].exists
            if !found { shot("\(id)-after-tap") }
            XCTAssertTrue(found, "\(id): '\(item)' did not appear after an accessibility tap")
            dismissMenu()
        }
        // The list's controls.
        menu("chats.profile", shows: "All bots")
        menu("chats.sort", shows: "Recent")
        menu("chats.filters", shows: "Pinned only")
        let newBot = any("chats.newBot")
        XCTAssertTrue(newBot.waitForExistence(timeout: 5), "no + button")
        newBot.tap(); pause(1.2)
        shot("after-new-bot")
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "the New Bot sheet did not open from an accessibility tap")
        cancel.tap(); pause(1)
        // The chat's controls.
        openFirstChat(); pause(2)
        menu("chat.more", shows: "Rename chat")
        let pill = any("chat.titlePill")
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "no title pill")
        pill.tap(); pause(1.5)
        shot("after-pill")
        // The bot's card: a sheet over the chat with a Done or a close control.
        let closed = app.buttons["Done"].waitForExistence(timeout: 3) || app.buttons["Close"].exists
        XCTAssertTrue(closed, "the bot card did not open from an accessibility tap on the pill")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() } else { app.buttons["Close"].tap() }
        pause(1)
        back(); pause(1.5)
        // The other roots' controls, where the tab is in the bar.
        func onTab(_ tab: String, _ body: () -> Void) {
            let slot = app.descendants(matching: .any).matching(identifier: "tab.\(tab)").firstMatch
            guard slot.waitForExistence(timeout: 3) else { return }
            slot.tap(); pause(1.5); body()
        }
        onTab("bots") {
            let b = any("bots.newBot"); XCTAssertTrue(b.waitForExistence(timeout: 5), "no Bots +")
            b.tap(); pause(1.2)
            if !app.buttons["Cancel"].waitForExistence(timeout: 3) {
                shot("bots-after-plus")
                let t = XCTAttachment(string: "bots.newBot frame=\(b.frame) hittable=\(b.isHittable) sheets=\(app.sheets.count) buttons=\(app.buttons.allElementsBoundByIndex.prefix(12).map { $0.label })"); t.name = "bots-plus-diag"; t.lifetime = .keepAlways; add(t)
                // A touch at the same spot: tells the accessibility path from the plumbing.
                b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.2)
                let t2 = XCTAttachment(string: "after coordinate tap: cancel=\(app.buttons["Cancel"].exists)"); t2.name = "bots-plus-diag-2"; t2.lifetime = .keepAlways; add(t2)
                if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap(); pause(1) }
                XCTFail("the New Bot sheet did not open from the bar's +")
            }
            app.buttons["Cancel"].tap(); pause(1)
        }
        onTab("projects") {
            let b = any("projects.new"); XCTAssertTrue(b.waitForExistence(timeout: 5), "no Projects +")
            b.tap(); pause(1.2)
            XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3), "the New Project sheet did not open from the bar's +")
            app.buttons["Cancel"].tap(); pause(1)
        }
        onTab("files") {
            let h = any("files.hidden"); XCTAssertTrue(h.waitForExistence(timeout: 5), "no Files hidden switch")
            let before = h.label; h.tap(); pause(1)
            XCTAssertNotEqual(any("files.hidden").label, before, "the hidden-files switch did not flip from the bar")
        }
        onTab("chats") {}
    }

    /// A long reply streamed at the usual pace (the mock's `long`), the chat open over the list:
    /// what each token costs while a reply streams, for the hitch and Time Profiler recordings
    /// and the DEBUG body counters (`HERMES_E2E_ROW` sets the seconds, 30 by default).
    func testStreamLongReply() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        let secs = Int(ProcessInfo.processInfo.environment["HERMES_E2E_ROW"] ?? "") ?? 30
        launch(url: url, token: token)
        waitForList(); clearSystemAlert()
        openFirstChat(); pause(1.5)
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")
        composer.tap(); pause(0.5)
        composer.typeText("long \(secs)")
        let send = app.buttons.matching(identifier: "composer.send").firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no send button")
        send.tap()
        if app.keyboards.buttons["Hide keyboard"].firstMatch.waitForExistence(timeout: 1) { app.keyboards.buttons["Hide keyboard"].firstMatch.tap() }
        print("STREAM-AT start")
        pause(Double(secs) + 4)
        print("STREAM-AT end")
    }

    /// I: the bar's controls answer a touch (Matt on (18): "at touching indication on the top right
    /// icons"). On the Chats +, sort and filter: a press held for a second then lifted, and a press
    /// that slides off before it lifts, for the phone's frames (the log's Press lines are the
    /// moments). Whatever opened is closed again; the slide-off must not open the New Bot sheet.
    func testPressedStyle() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList(); clearSystemAlert()
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        // Closes what a press opened: the New Bot sheet, or a menu (tapped outside only when one is
        // showing; with nothing open, that tap opened the chat row under it).
        func closeAnything() {
            if app.buttons["Cancel"].waitForExistence(timeout: 1) { app.buttons["Cancel"].tap() }
            else if app.buttons["Recent"].exists || app.buttons["Pinned only"].exists || app.switches["Pinned only"].exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
            }
            pause(1)
        }
        let away = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        for id in ["chats.newBot", "chats.sort", "chats.filters"] {
            let c = any(id)
            XCTAssertTrue(c.waitForExistence(timeout: 5), "\(id) is not there")
            let centre = c.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            print("PRESS-AT \(id) hold")
            centre.press(forDuration: 1.0)
            pause(1); shot("\(id)-after-hold"); closeAnything()
            print("PRESS-AT \(id) slide-off")
            centre.press(forDuration: 0.6, thenDragTo: away)
            pause(1); shot("\(id)-after-slide-off")
            if id == "chats.newBot" {
                XCTAssertFalse(app.buttons["Cancel"].exists, "sliding off the + still opened the New Bot sheet")
            }
            closeAnything()
        }
    }

    /// Tab switches by a tap, Chats → Bots → Files → Settings → Chats, for a frame check of the
    /// morph prototype's bar morphing one page's set into the next.
    func testTabTapSwitch() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList(); clearSystemAlert()
        for tab in ["bots", "files", "settings", "chats", "bots", "chats"] {
            let slot = app.descendants(matching: .any).matching(identifier: "tab.\(tab)").firstMatch
            if slot.waitForExistence(timeout: 5) { slot.tap() }
            pause(1.6)
        }
    }

    /// Diagnostic at the accessibility sizes: can a finger reach the list's first row with the
    /// search drawer tucked and shown? Frames of the row and the field, hittability, a shot
    /// each, then a touch at the row's centre.
    func testAXRowReach() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList(); clearSystemAlert(); pause(1)
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        func note(_ name: String, _ text: String) { let a = XCTAttachment(string: text); a.name = name; a.lifetime = .keepAlways; add(a) }
        func state() -> String {
            let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).allElementsBoundByIndex
            let row = rows.min { $0.frame.minY < $1.frame.minY }
            let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
            return "row=\(row.map { "\($0.frame) hittable=\($0.isHittable)" } ?? "none") field=\(field.exists ? "\(field.frame)" : "none") window=\(app.frame)"
        }
        note("tucked", state()); shot("tucked")
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)), withVelocity: .slow, thenHoldForDuration: 0.2)
        pause(1.5)
        note("shown", state()); shot("shown")
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).allElementsBoundByIndex
        if let row = rows.min(by: { $0.frame.minY < $1.frame.minY }) {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5)
            note("after-row-touch", "dock=\(any("chat.dock").exists)"); shot("after-row-touch")
        }
    }

    /// Diagnostic for a window changing width with a chat open (the Duo rotating): a draft typed,
    /// then upright → landscape → upright, with the Back elements counted, the draft read back
    /// and a screenshot per pose.
    func testRotateWithChatOpen() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        openFirstChat(); pause(2)
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        func note(_ name: String, _ text: String) { let a = XCTAttachment(string: text); a.name = name; a.lifetime = .keepAlways; add(a) }
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no composer")
        field.tap(); pause(0.8); field.typeText("draft kept?"); pause(0.5)
        func state(_ pose: String) {
            let backs = app.descendants(matching: .any).matching(identifier: "chat.back").count
            let draft = (app.textViews.firstMatch.value as? String) ?? ""
            note(pose, "window=\(app.frame) backs=\(backs) dock=\(any("chat.dock").exists) draft='\(draft)'")
            shot(pose)
        }
        state("upright")
        XCUIDevice.shared.orientation = .landscapeLeft; pause(2.5); state("landscape")
        XCUIDevice.shared.orientation = .portrait; pause(2.5); state("upright-again")
    }

    /// A page pushed on another tab (Settings → a row) with the morph bar on: the bar steps aside
    /// and the pushed page keeps the system's title and Back; then Back to the root.
    func testMorphPushedPage() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        // The geometry probe's banner (at 150 pt, clear of the rows) carries the probe's record of
        // the push: whether UIKit was asked to animate it and had a coordinator for it.
        launch(url: url, token: token, tab: "settings", extra: ["-vory-geometry-probe"])
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        pause(2); shot("settings-root")
        // HERMES_E2E_ROW picks the row (settings.row.profile); the first row otherwise.
        let rowID = ProcessInfo.processInfo.environment["HERMES_E2E_ROW"] ?? ""
        let row = rowID.isEmpty ? app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings.row.'")).firstMatch : any(rowID)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no settings row")
        row.tap(); pause(1.5); shot("settings-pushed")
        let back = any("page.back")
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the pushed page has no Back capsule")
        // 1.5 (18) pushed every page without its slide (Matt: "there's no longer an animation when
        // clicking into panes"); the pop still slid.
        let record = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'probe push '")).firstMatch
        print("PUSH-RECORD \(record.exists ? record.label : "none")")
        XCTAssertTrue(record.exists && record.label.contains("push animated=true coordinator=true"), "the push was not animated: \(record.exists ? record.label : "no record")")
        XCTAssertFalse(app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch.exists, "the system's back button still shows on the pushed page")
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5); shot("settings-root-again")
        XCTAssertTrue(any("morph.title").waitForExistence(timeout: 5), "the Settings title capsule is not back")
    }

    /// A bot's page pushed from the Bots grid (Matt on 1.5 (17): "the back button leave behind a
    /// trail button once in the new window", and "Bot name also disappears when it should show"):
    /// the + is gone as the Back forms, and the page keeps its title. Pushed through the card's
    /// menu ("Chats"): an XCTest tap on a card lands on its face, which keeps the tap.
    func testMorphPushedBotPage() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "bots")
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        let plus = any("bots.newBot")
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "no + on the Bots page")
        pause(2); shot("bots-root")
        // The first card's name pill, left column.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.26, dy: 0.30)).press(forDuration: 1.2)
        let chats = app.buttons.matching(NSPredicate(format: "label == 'Chats' AND identifier != 'tab.chats'")).firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 5), "no card menu")
        chats.tap()
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "the bot's page has no Back capsule")
        pause(1.5); shot("bot-pushed")
        XCTAssertFalse(plus.exists && plus.isHittable, "the Bots + stays over the bot's page")
        let title = app.navigationBars.staticTexts.firstMatch
        print("BOT-PAGE title '\(title.exists ? title.label : "none")'")
        XCTAssertTrue(title.exists && !title.label.isEmpty, "the bot's page has no title")
        any("page.back").tap(); pause(1.5); shot("bots-again")
        XCTAssertTrue(plus.waitForExistence(timeout: 5) && plus.isHittable, "the + is not back on the Bots page")
    }

    /// Pulls to refresh, measured with the scroll-dragging hitch metric: the title capsule opens
    /// with the finger, frame for frame, and the bar's hitch time must stay at 0 ms/s, as for the
    /// fling. HERMES_E2E_TAB picks the page (chats; dashboard is Home), HERMES_E2E_PULL the speed
    /// (slow: to the trigger and past it; fast: a quick flick down).
    func testPullHitches() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        let e = ProcessInfo.processInfo.environment
        let tab = e["HERMES_E2E_TAB"] ?? "chats", fast = e["HERMES_E2E_PULL"] == "fast"
        launch(url: url, token: token, tab: tab)
        pause(3)
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        print("PULL-HITCHES \(tab) \(fast ? "fast" : "slow")")
        measure(metrics: [XCTOSSignpostMetric.scrollDraggingMetric], options: longOptions) {
            if fast {
                top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)), withVelocity: .fast, thenHoldForDuration: 0)
            } else {
                top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78)), withVelocity: .slow, thenHoldForDuration: 0.1)
            }
            pause(2)
            stopMeasuring()
        }
    }

    /// A page pushed while a pull's refresh still runs (held 3 s by `-vory-refresh-hold`): the
    /// page's Back stays a 44 pt circle. The wheel's room in the title capsule went over to the
    /// Back and stretched it into an oval until the refresh ended. (Chats takes its pull away as
    /// a chat opens, so a page on Settings is the case.)
    func testRefreshThenPushPage() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "settings", extra: ["-vory-refresh-hold", "3"])
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no settings row")
        pause(2)
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78)), withVelocity: .slow, thenHoldForDuration: 0.1)
        let spinner = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Refreshing'")).firstMatch
        XCTAssertTrue(spinner.waitForExistence(timeout: 1.5), "the pull did not start a refresh")
        // Past the usual 0.6 s: the hold is in force, so the refresh is still running as the page comes in.
        pause(1.0)
        print("REFRESH-HOLD spinner after 1 s: \(spinner.exists)")
        XCTAssertTrue(spinner.exists, "the refresh did not hold (-vory-refresh-hold)")
        for _ in 0..<3 where !any("page.back").exists && row.exists { row.tap(); _ = any("page.back").waitForExistence(timeout: 3) }
        pause(0.6)
        let back = any("page.back")
        XCTAssertTrue(back.exists, "the pushed page has no Back capsule")
        let during = back.frame
        shot("back-refreshing")
        pause(3)
        let after = back.frame
        shot("back-after")
        print("REFRESH-BACK during \(during) after \(after)")
        XCTAssertEqual(during.width, 44, accuracy: 1, "the Back circle was stretched while the refresh ran")
        XCTAssertEqual(after.width, 44, accuracy: 1, "the Back circle is not 44 pt")
    }

    /// The "/" list out of the field and back (type "/", then delete it).
    func testSlashMenu() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        openFirstChat(); pause(1.5)
        let field = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no composer field")
        field.tap(); pause(1.5)
        measure(metrics: [smooth("slashMenu")], options: options) {
            field.typeText("/"); pause(1.2)
            field.typeText(XCUIKeyboardKey.delete.rawValue); pause(1.2)
            stopMeasuring()
        }
        // The + panel with the keyboard up (it stays up), once, for the recording.
        let plus = app.buttons["composer.attach"].firstMatch
        if plus.waitForExistence(timeout: 5) { plus.tap(); pause(1.5); plus.tap(); pause(1.5) }
    }

    /// Settings › Appearance flung down to the bot rows and back (Matt, 2026-10-11: "lags so
    /// hard" as the bots come in).
    func testAppearanceScroll() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "settings")
        // The row is further down the Settings root; rows off screen are not in the tree yet.
        XCTAssertTrue(any("settings.row.gateways").waitForExistence(timeout: 40), "no settings")
        var row = any("settings.row.appearance")
        for _ in 0..<5 where !row.exists { app.swipeUp(velocity: .slow); pause(0.6); row = any("settings.row.appearance") }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Appearance row")
        row.tap(); pause(2)
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: longOptions) {
            for _ in 0..<4 { app.swipeUp(velocity: .fast); pause(0.9) }
            for _ in 0..<4 { app.swipeDown(velocity: .fast); pause(0.9) }
            stopMeasuring()
        }
    }

    /// A "Background process finished" note opened and closed (the mock's nightly-export chat).
    func testInjectedNote() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        // The list re-sorts as the sessions load; a row tapped before it settles is tapped where
        // it was (its reported frame lags). Let it settle, then find the row afresh.
        pause(2.5)
        // Two buttons carry this title (a hidden page's row is in the tree too, lower down);
        // the one on screen is the list's.
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rewrite the nightly export job'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "no nightly export chat")
        let row = rows.allElementsBoundByIndex.min { $0.frame.minY < $1.frame.minY }!
        row.tap()
        XCTAssertTrue(any("chat.dock").waitForExistence(timeout: 20), "the chat did not open")
        pause(1.5)
        // The note sits above the end of the thread; scroll up until it is on screen.
        var note = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Background process'")).firstMatch
        for _ in 0..<6 where !note.exists { app.swipeDown(velocity: .slow); pause(0.8); note = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Background process'")).firstMatch }
        XCTAssertTrue(note.waitForExistence(timeout: 5), "no background process note")
        pause(1)
        // The swipes leave the pill up under the bar, where a tap lands on the bar and the open
        // note's title ends up off screen: drag the thread down until the pill sits mid-screen.
        func findNote() -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Background process'")).firstMatch }
        func settle() {
            for _ in 0..<4 where note.frame.minY < 160 {
                let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 250)), withVelocity: .slow, thenHoldForDuration: 0.2)
                pause(0.8); note = findNote()
            }
        }
        settle()
        XCTAssertGreaterThan(note.frame.minY, 100, "the note stayed under the bar")
        // When and where each tap landed, for a frame check of a screen recording.
        func mark(_ what: String) { try? "\(Date().timeIntervalSince1970) \(what) \(note.frame)\n".appendLine(to: "/tmp/vory-note-taps.txt") }
        measure(metrics: [smooth("touch")], options: options) {
            settle()
            // The open note's element is the whole row: tap its title, 15 pt under the top edge.
            func tapTitle() { note.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 15)).tap() }
            mark("open"); tapTitle(); pause(1.2)
            note = findNote()
            mark("close"); tapTitle(); pause(1.2)
            stopMeasuring()
        }
    }

    /// The + panel out of the + button and back.
    func testPlusPanel() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        openFirstChat(); pause(1.5)
        let plus = app.buttons["composer.attach"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        measure(metrics: [smooth("plusPanel")], options: options) {
            plus.tap(); pause(1.2)
            plus.tap(); pause(1.2)
            stopMeasuring()
        }
    }

    /// The bot card (a sheet at full height) and its close.
    func testBotCard() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        openFirstChat(); pause(1.5)
        // The phone's header pill (the bot sits on it); "chat.bot" is the Mac toolbar's.
        let bot = app.buttons["chat.titlePill"].firstMatch
        XCTAssertTrue(bot.waitForExistence(timeout: 10), "no title pill")
        measure(metrics: [smooth("botCard")], options: options) {
            bot.tap()
            let close = any("profile.close")
            XCTAssertTrue(close.waitForExistence(timeout: 10), "the card did not open")
            pause(1)
            close.tap(); pause(1.2)
            stopMeasuring()
        }
    }

    /// The model chip's menu.
    func testModelChip() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        openFirstChat(); pause(1.5)
        let chip = any("composer.modelChip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        // A Menu swallows the tap before any gesture of ours sees it, so the interval comes
        // from the window's touch-down signpost ("touch"), which every control gets.
        measure(metrics: [smooth("touch")], options: options) {
            chip.tap(); pause(1.2)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap(); pause(1)
            stopMeasuring()
        }
    }

    /// The list's View menu (filters on a phone, the merged menu in a strip or a column).
    func testViewMenu() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch.waitForExistence(timeout: 40))
        pause(1.5)
        // The merged View menu in a strip or a column; the Filters menu on a phone. On a device
        // the toolbar menu answers to its label rather than the identifier, so both are tried.
        let candidates = [any("chats.view"), any("chats.filters"), app.buttons["Filters"].firstMatch, app.buttons["Filters (on)"].firstMatch, app.buttons["View"].firstMatch]
        _ = candidates[0].waitForExistence(timeout: 5)
        guard let view = candidates.first(where: { $0.exists }) else { return XCTFail("no View menu") }
        measure(metrics: [smooth("touch")], options: options) {
            view.tap(); pause(1.2)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap(); pause(1)
            stopMeasuring()
        }
    }

    /// Settings › Gateway › Add Gateway, a form sheet, opened and dismissed.
    func testSettingsSheet() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token, tab: "settings")
        // Add Gateway lives on the Gateways page, behind the gateway's row on the Settings root.
        let gateway = any("settings.row.gateways")
        XCTAssertTrue(gateway.waitForExistence(timeout: 40), "no gateway row")
        gateway.tap()
        let add = app.buttons["settings.addGateway"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20), "no Add Gateway")
        pause(1.5)
        measure(metrics: [smooth("gatewaySheet")], options: options) {
            add.tap(); pause(1.2)
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.waitForExistence(timeout: 3) { cancel.tap() } else { app.swipeDown(velocity: .fast) }
            pause(1.2)
            stopMeasuring()
        }
    }

    /// A long thread flung up and down: the system's scroll deceleration intervals.
    func testThreadScroll() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        openFirstChat(); pause(1)
        // One long turn first, so there is something to scroll.
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("marathon 30")
        app.buttons["composer.send"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Everything else looked healthy'")).firstMatch.waitForExistence(timeout: 90), "the turn did not finish")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        pause(1.5)
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: longOptions) {
            for _ in 0..<3 { app.swipeDown(velocity: .fast); pause(0.9) }
            for _ in 0..<3 { app.swipeUp(velocity: .fast); pause(0.9) }
            stopMeasuring()
        }
    }

    /// The keyboard up and down in a chat (Matt: "bringing up the keyboard and bringing it down
    /// is very laggy and choppy"): the dock and the thread ride with it.
    func testKeyboard() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        openFirstChat(); pause(1.5)
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        measure(metrics: [smooth("touch")], options: options) {
            field.tap(); pause(1.5)
            // Down: a tap on the thread dismisses the keyboard.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap(); pause(1.5)
            stopMeasuring()
        }
    }

    /// The keyboard dragged down over the thread (interactive dismiss), the drag slow enough for
    /// the keyboard to track the finger (handoff item 2: 60 to 79 ms frames inside the tracking).
    func testKeyboardDrag() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        openFirstChat(); pause(1.5)
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        measure(metrics: [smooth("touch")], options: options) {
            field.tap(); pause(1.5)
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
            pause(1.5)
            stopMeasuring()
        }
    }

    /// The tab bar's lens held on Chats and dragged slowly across to Settings and back (Matt:
    /// "holding the nav bar selector and then dragging it across to change views is a bit laggy").
    func testTabLensDrag() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        let chats = app.descendants(matching: .any).matching(identifier: "tab.chats").firstMatch
        let settings = app.descendants(matching: .any).matching(identifier: "tab.settings").firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 10) && settings.exists, "no tab bar slots")
        let from = chats.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        measure(metrics: [smooth("touch")], options: options) {
            from.press(forDuration: 0.5, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
            pause(1.2)
            to.press(forDuration: 0.5, thenDragTo: from, withVelocity: .slow, thenHoldForDuration: 0.3)
            pause(1.2)
            stopMeasuring()
        }
    }

    // MARK: The heavy list (Matt: with lots of chats and bots "that is where it gets sluggish").
    // These want the mock with --extra-sessions 60 --extra-bots 12 (14 bots, 112 chats).

    private func waitForList() {
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup'")).firstMatch.waitForExistence(timeout: 40), "no chat rows")
        pause(2)
    }

    /// The long chat list flung down and back up: the system's scroll deceleration intervals.
    func testChatListScroll() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: longOptions) {
            for _ in 0..<4 { app.swipeUp(velocity: .fast); pause(0.9) }
            for _ in 0..<4 { app.swipeDown(velocity: .fast); pause(0.9) }
            stopMeasuring()
        }
    }

    /// A chat deep in the list opened and closed: the push and the pop with a long list behind.
    func testDeepRowAndBack() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        for _ in 0..<3 { app.swipeUp(velocity: .fast); pause(0.8) }
        pause(1)
        measure(metrics: [XCTOSSignpostMetric.navigationTransitionMetric], options: options) {
            // Whatever row sits in the middle of the screen after the flings.
            let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'workshop' OR label CONTAINS[c] 'ago' OR label CONTAINS[c] 'yesterday'"))
            // The row nearest the middle of the screen, judged by its frame: asking an
            // off-screen row whether it is hittable throws on a device.
            let window = app.windows.firstMatch.frame
            let mid = window.midY
            let row = rows.allElementsBoundByIndex
                .filter { $0.frame.minY > window.minY + 120 && $0.frame.maxY < window.maxY - 160 }
                .min { abs($0.frame.midY - mid) < abs($1.frame.midY - mid) }
            XCTAssertNotNil(row, "no row in the middle of the screen")
            guard let row else { stopMeasuring(); return }
            print("DEEP-ROW \(row.label.prefix(60)) \(row.frame)")
            // By coordinate: the row's own tap landed beside it on a device once.
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: row.frame.midX, dy: row.frame.midY)).tap()
            XCTAssertTrue(any("chat.dock").waitForExistence(timeout: 20), "the chat did not open: \(row.label.prefix(60))")
            pause(1)
            let b = any("chat.back")
            XCTAssertTrue(b.waitForExistence(timeout: 10)); b.tap()
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
            pause(1)
            stopMeasuring()
        }
    }

    /// The All bots switch in the list's bot menu, off to on and back: the list rebuilds with
    /// every bot's chats and their faces.
    func testAllBotsSwitch() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        let args = ["-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "light", "-chat.showBots", "YES", "-chats.allBots", "NO"]
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle); app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else { app = XCUIApplication(); app.launchArguments = args }
        app.launch()
        waitForList()
        let menu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Profile:'")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no bot menu")
        measure(metrics: [smooth("touch")], options: options) {
            for _ in 0..<2 {
                menu.tap()
                let all = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'All bots'")).firstMatch
                XCTAssertTrue(all.waitForExistence(timeout: 8), "no All bots switch")
                all.tap(); pause(2.5)
            }
            stopMeasuring()
        }
    }

    /// The Bots page with fourteen bots: the tab switch, then a fling of its grid.
    func testBotsPage() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        waitForList()
        let bots = any("tab.bots"), chats = any("tab.chats")
        XCTAssertTrue(bots.waitForExistence(timeout: 10), "no Bots tab")
        measure(metrics: [smooth("touch"), XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            bots.tap(); pause(1.5)
            app.swipeUp(velocity: .fast); pause(1)
            app.swipeDown(velocity: .fast); pause(1)
            chats.tap(); pause(1.2)
            stopMeasuring()
        }
    }

    /// A whole default turn with the bot animating (orb, bubbles, toolbox, the approval, rest).
    func testFullTurn() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        launch(url: url, token: token)
        openFirstChat(); pause(1)
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let o = XCTMeasureOptions(); o.iterationCount = 1; o.invocationOptions = [.manuallyStop]
        measure(metrics: [smooth("turn")], options: o) {
            field.tap(); field.typeText("think it through")
            let send = app.buttons["composer.send"].firstMatch
            send.tap()
            // While the turn runs the send button is the stop button; with the field empty
            // again it gives way to the mic, so the turn is over when it is gone.
            pause(3)
            let gone = NSPredicate(format: "exists == false")
            _ = XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: send)], timeout: 120)
            pause(2)
            stopMeasuring()
        }
    }
}

private extension String {
    /// Appends the line to a file (made if missing); the frame checks read it.
    func appendLine(to path: String) throws {
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(utf8)); h.closeFile() }
        else { try write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
