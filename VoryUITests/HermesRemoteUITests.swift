import XCTest

/// Drives the real UI against a gateway. Needs HERMES_E2E_URL / HERMES_E2E_TOKEN in the runner's
/// environment (e.g. `xcrun simctl spawn <udid> launchctl setenv …` or TEST_RUNNER_ variables).
/// Screenshots are written to the runner's tmp directory (path printed) and attached to the result bundle.
final class VoryUITests: XCTestCase {
    private var app: XCUIApplication!
    private lazy var shotDir: URL = {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-ui-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// Screenshot plus the accessibility hierarchy, both kept in the result bundle so a failure can be read
    /// from the Xcode test result without reaching into the simulator's tmp directory.
    private func attachDiagnostics(_ name: String) {
        let s = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
        let h = XCTAttachment(string: app.debugDescription); h.name = "\(name)-hierarchy"; h.lifetime = .keepAlways; add(h)
    }

    /// Opens a Settings row (`settings.row.<id>`) without letting the floating tab bar eat the tap.
    /// XCUITest taps the centre of an element; a row scrolled under the bar is "hittable" yet the tap lands on
    /// the bar and switches tab. So scroll until the whole row is above the bar, tap, and check Settings is still
    /// the selected tab afterwards.
    private func openSettingsRow(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.descendants(matching: .any)["settings.row.\(id)"].firstMatch
        let tab = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND label == 'Settings'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "settings.row.\(id) missing. \(hittableSummary())", file: file, line: line)
        let window = app.windows.firstMatch.frame
        func drag(from y0: CGFloat, to y1: CGFloat) {
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y0))
            a.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y1)))
        }
        var clear = false
        for _ in 0..<10 {
            let f = row.frame
            let barTop = tab.exists ? tab.frame.minY : window.maxY
            // Whole row above the bar (with a margin) and below the status/navigation area.
            if f.maxY < barTop - 12 && f.minY > window.minY + 110 { clear = true; break }
            if f.minY <= window.minY + 110 { drag(from: 0.3, to: 0.6) }   // row too high: scroll down
            else { drag(from: 0.6, to: 0.3) }                              // row under the bar: scroll up
        }
        XCTAssertTrue(clear, "settings.row.\(id) could not be scrolled clear of the tab bar (row \(row.frame), bar top \(tab.frame.minY)). \(hittableSummary())", file: file, line: line)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // The tap must not have been taken by the tab bar.
        if tab.exists, !tab.isSelected {
            XCTFail("tap intercepted by tab bar: Settings is no longer the selected tab after tapping settings.row.\(id). \(hittableSummary())", file: file, line: line)
        }
    }

    /// A freshly saved gateway can open the first-run push setup ("Allow notifications, then tap Register"),
    /// which covers the app until it is exited. Leave it if it shows.
    private func dismissSetupIfPresent() {
        let exit = app.buttons["setup.exit"].firstMatch
        if exit.waitForExistence(timeout: 8), exit.isHittable { exit.tap(); sleep(1) }
    }

    /// Back from a pushed Settings page. The app keeps every tab's navigation bar in the tree, so tap the back
    /// button of the bar that is actually on screen, not `navigationBars.buttons[0]`.
    private func goBack() {
        for bar in app.navigationBars.allElementsBoundByIndex where bar.isHittable {
            if let b = bar.buttons.allElementsBoundByIndex.first(where: { $0.isHittable }) { b.tap(); return }
        }
        XCTFail("no visible back button. \(hittableSummary())")
    }

    /// The tab bar must not hide the last row of a long list: Settings, scrolled to the very end, keeps its
    /// last row above the floating bar. Needs a saved gateway (the previous test leaves one) so the app is past onboarding.
    func testLastSettingsRowClearsTheTabBar() throws {
        let settingsTab = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND label == 'Settings'")).firstMatch
        try XCTSkipUnless(settingsTab.waitForExistence(timeout: 45), "no tab bar: app is on onboarding, no saved gateway")
        for _ in 0..<2 where !settingsTab.isSelected {
            settingsTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: settingsTab)], timeout: 5)
        }
        XCTAssertTrue(settingsTab.isSelected, "Settings did not become the selected tab")
        let last = app.descendants(matching: .any)["settings.row.about"].firstMatch
        // A SwiftUI List renders lazily: the last row does not exist until it is scrolled near.
        for _ in 0..<14 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        }
        sleep(1)
        XCTAssertTrue(last.waitForExistence(timeout: 15), "settings.row.about missing after scrolling to the end. \(hittableSummary())")
        shot("11-settings-end")
        let bar = settingsTab.frame
        XCTAssertLessThan(last.frame.maxY, bar.minY, "last Settings row (\(last.frame)) ends under the tab bar (top \(bar.minY))")
    }

    /// Only what is on screen and touchable: views the app keeps alive behind the current page are not
    /// hittable, so they drop out and what is left is the active screen.
    private func hittableSummary() -> String {
        // Scan every element (not a prefix: the active page can sit late in the tree behind kept-alive tabs),
        // keep the touchable ones, and report the last 40 so a page that is on top is not cut off.
        var items: [String] = []
        for q in [app.buttons, app.staticTexts, app.switches, app.cells] {
            for e in q.allElementsBoundByIndex.prefix(400) where e.isHittable {
                let n = e.identifier.isEmpty ? String(e.label.prefix(30)) : e.identifier
                if !n.isEmpty { items.append(n) }
            }
        }
        return "hittable (\(items.count) total, last 40): [" + items.suffix(40).joined(separator: " | ") + "]"
    }

    /// Identifiers and labels of what is on screen, trimmed, so the failure message itself says where the UI is.
    private func screenSummary() -> String {
        func names(_ q: XCUIElementQuery) -> String {
            q.allElementsBoundByIndex.prefix(25).map { $0.identifier.isEmpty ? $0.label : $0.identifier }.filter { !$0.isEmpty }.joined(separator: " | ")
        }
        return "buttons: [\(names(app.buttons))] texts: [\(String(names(app.staticTexts).prefix(400)))] textFields: [\(names(app.textFields))] textViews: [\(names(app.textViews))] alerts: [\(names(app.alerts))] navBars: [\(names(app.navigationBars))] switches: [\(names(app.switches))] cells: \(app.cells.count)"
    }

    override func tearDownWithError() throws {
        if let run = testRun, run.failureCount > 0 || run.unexpectedExceptionCount > 0 { attachDiagnostics("failure-state") }
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        try? s.pngRepresentation.write(to: shotDir.appendingPathComponent("\(name).png"))
        print("UI-SHOT \(shotDir.appendingPathComponent("\(name).png").path)")
    }

    /// URL plus either a session token or a username/password. Read from HERMES_E2E_* in the environment,
    /// then from KEY=VALUE lines in $HERMES_E2E_ENV_FILE or ~/.config/vory/e2e.env (real home, found by uid).
    /// Values are typed into the form and never printed or attached.
    private var envPaths: [String] {
        let e = ProcessInfo.processInfo.environment
        if let p = e["HERMES_E2E_ENV_FILE"], !p.isEmpty { return [p] }
        var homes: [String] = []
        if let h = e["SIMULATOR_HOST_HOME"], !h.isEmpty { homes.append(h) }
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { homes.append(String(cString: dir)) }
        homes.append("/Users/andrea")
        var seen = Set<String>()
        return homes.filter { seen.insert($0).inserted }.map { $0 + "/.config/vory/e2e.env" }
    }

    /// Paths tried and keys found (names only, never values), for the skip message.
    private var envDiagnosis: String {
        let tried = envPaths.map { "\($0) [exists=\(FileManager.default.fileExists(atPath: $0)) readable=\(FileManager.default.isReadableFile(atPath: $0))]" }
        return "tried " + tried.joined(separator: ", ")
    }

    private var env: (url: String, token: String?, user: String?, password: String?)? {
        var v = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("HERMES_E2E_") && !$0.value.isEmpty }
        if let text = envPaths.lazy.compactMap({ try? String(contentsOfFile: $0, encoding: .utf8) }).first {
            for raw in text.split(whereSeparator: \.isNewline) {
                var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                var val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if val.count >= 2, let f = val.first, f == val.last, f == "\"" || f == "'" { val = String(val.dropFirst().dropLast()) }
                if !val.isEmpty, v[key] == nil { v[key] = val }
            }
        }
        guard let u = v["HERMES_E2E_URL"] else { return nil }
        let t = v["HERMES_E2E_TOKEN"], user = v["HERMES_E2E_USER"], pw = v["HERMES_E2E_PASSWORD"]
        guard t != nil || (user != nil && pw != nil) else { return nil }
        return (u, t, user, pw)
    }

    func testOnboardingConnectChatAndSettings() throws {
        guard let cfg = env else { throw XCTSkip("HERMES_E2E settings not found: \(envDiagnosis)") }
        shot("01-onboarding")
        let add = app.buttons["onboarding.addGateway"].firstMatch
        // A cold simulator can take well over 10 s to show onboarding. Wait for either onboarding or the
        // Chats screen (gateway already saved) instead of guessing after 10 s and taking the wrong branch.
        let chatsNewButton = app.buttons["chats.new"].firstMatch
        let skipOnboarding = app.buttons["onboarding.skip"].firstMatch
        let startDeadline = Date().addingTimeInterval(45)
        while !add.exists && !skipOnboarding.exists && !chatsNewButton.exists && Date() < startDeadline { usleep(500_000) }
        // A fresh install opens the onboarding pages first; Skip leads to the Add Gateway button.
        if skipOnboarding.exists { skipOnboarding.tap(); _ = add.waitForExistence(timeout: 10) }
        if add.exists {
            add.tap()
            let name = app.textFields["gateway.name"].firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 10))
            name.tap(); name.typeText("Local")
            let urlField = app.textFields["gateway.url"].firstMatch
            urlField.tap(); urlField.typeText(cfg.url)
            if let token = cfg.token {
                let tokenField = app.secureTextFields["gateway.sessionToken"].firstMatch
                XCTAssertTrue(tokenField.waitForExistence(timeout: 5))
                tokenField.tap(); tokenField.typeText(token)
            } else if let user = cfg.user, let password = cfg.password {
                let method = app.buttons["gateway.authMethod"].firstMatch
                XCTAssertTrue(method.waitForExistence(timeout: 5))
                method.tap()
                let option = app.buttons["Username & password"].firstMatch
                XCTAssertTrue(option.waitForExistence(timeout: 5))
                option.tap()
                let userField = app.textFields["gateway.username"].firstMatch
                XCTAssertTrue(userField.waitForExistence(timeout: 10))
                userField.tap(); userField.typeText(user)
                let passField = app.secureTextFields["gateway.password"].firstMatch
                XCTAssertTrue(passField.waitForExistence(timeout: 5))
                passField.tap(); passField.typeText(password)
            }
            shot("02-form-filled")
            let test = app.buttons["gateway.test"].firstMatch
            XCTAssertTrue(test.waitForExistence(timeout: 5))
            test.tap()
            let save = app.buttons["gateway.save"].firstMatch
            let exp = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: save)
            wait(for: [exp], timeout: 60)
            shot("03-test-passed")
            save.tap()
        } else {
            print("UI-NOTE gateway already saved in the Keychain; continuing from the Chats tab")
        }

        // Chats list
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "chats.new missing (onboarding or another screen?). \(screenSummary())")
        let newChatEnabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)
        wait(for: [newChatEnabled], timeout: 60)
        sleep(2)
        dismissSetupIfPresent()
        shot("04-chats")
        newChat.tap()
        attachDiagnostics("04b-after-new-chat")
        // On a gateway with several bots, New Message opens a "Choose a bot first" sheet; the composer
        // only appears after one is picked. Pick the maya bot (its row label starts with "maya,").
        let bot = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'maya,'")).firstMatch
        if bot.waitForExistence(timeout: 10) { bot.tap() }
        let composer = app.descendants(matching: .any).matching(identifier: "newchat.text").firstMatch
        let composerFound = composer.waitForExistence(timeout: 30)
        XCTAssertTrue(composerFound, "newchat.text missing. \(screenSummary())")
        composer.tap(); composer.typeText("vory-e2e: reply with exactly the single word: pong")
        shot("05-composer")
        // Sending from the New Message sheet creates the chat and submits the first message.
        let send = app.buttons["newchat.send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5), "newchat.send missing. \(screenSummary())")
        send.tap()
        // Wait for either a streamed reply or the gateway's error surface.
        // The user's own prompt also contains "pong", so match the reply exactly rather than by substring.
        let reply = app.staticTexts.matching(NSPredicate(format: "label =[c] 'pong' OR label CONTAINS[c] 'provider' OR label CONTAINS[c] 'failed'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 120), "no reply or error surfaced in the transcript. \(screenSummary())")
        sleep(1)
        shot("06-conversation")

        // Back out of the chat: the tab bar is hidden while a conversation is open.
        let back = app.buttons["chat.back"].firstMatch
        if back.waitForExistence(timeout: 5) { back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }

        // Settings
        // The tab bar is our own overlay; each slot is tagged tab.<name> and carries the selected trait.
        // Tap by identifier and prove the tab is selected before looking at its page.
        let settingsTab = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND label == 'Settings'")).firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15), "tab.settings missing. \(screenSummary())")
        let selected = NSPredicate(format: "isSelected == true")
        for _ in 0..<2 where !settingsTab.isSelected {
            settingsTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = XCTWaiter().wait(for: [expectation(for: selected, evaluatedWith: settingsTab)], timeout: 5)
        }
        XCTAssertTrue(settingsTab.isSelected, "Settings tab (\(settingsTab.identifier)) did not become selected. \(screenSummary())")
        shot("07-settings")
        openSettingsRow("tools")
        // Tools lists toolsets as Toggle rows, each tagged tool.toggle.<name> (some may be off). SwiftUI can merge
        // a custom row into one element, so wait on the identifier rather than the navigation bar or app.switches.
        let anyToggle = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tool.toggle.'")).firstMatch
        XCTAssertTrue(anyToggle.waitForExistence(timeout: 30), "Tools page has no tool.toggle.* rows. \(hittableSummary())")
        shot("08-tools")
        goBack()
        openSettingsRow("config")
        // "general" is the first category; approvals.* is further down and off-screen on a long list.
        // The Config page lists the schema's categories and humanised field names ("General", "Command Allowlist", ...);
        // there is no row literally called "model". Wait for the first category heading, on screen.
        let general = app.staticTexts["General"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 45) && general.isHittable, "Config page shows no 'General' category. \(hittableSummary())")
        shot("09-config")
        goBack()
        openSettingsRow("env")
        sleep(3)
        shot("10-env")
    }
}
