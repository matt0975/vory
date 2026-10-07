import XCTest

/// "Remember sign-in on this device" (#256), end to end against the mock gateway with its
/// username/password sign-in turned on: the switch is on the password form and off until turned
/// on; with it on, a session the gateway ends is signed in again by itself after Face ID (the
/// demo copy's stand-in answers yes); forgotten in Settings › Gateways, the same expiry asks the
/// person again. Skipped unless HERMES_E2E_URL is the mock (HERMES_E2E_TOKEN mock-token) and
/// HERMES_E2E_BUNDLE is the demo copy, which keeps its credentials in memory.
final class RememberSignInUITests: XCTestCase {
    private var app: XCUIApplication!
    private var gatewayURL = ""
    private let username = "demo-user"
    private let password = "demo-pass-1"

    override func tearDown() {
        // The mock's auth gate goes off again, for the tests that sign in with a session token.
        if !gatewayURL.isEmpty { _ = mock("POST", "/api/_mock/password-auth", ["enabled": false]) }
        super.tearDown()
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"].flatMap { $0.isEmpty ? nil : $0 }
        let d = folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-chat-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
        print("CHAT-SHOT \(d.appendingPathComponent("\(name).png").path)")
    }

    /// One call to the mock's own controls, answered as JSON.
    private func mock(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> [String: Any]? {
        guard let url = URL(string: gatewayURL + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 10
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let done = DispatchSemaphore(value: 0)
        let answer = Answer()
        URLSession.shared.dataTask(with: req) { data, _, _ in
            answer.json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 12)
        return answer.json
    }

    /// The mock's answer, handed from URLSession's queue to the test (the semaphore orders them).
    private final class Answer: @unchecked Sendable { var json: [String: Any]? }

    private var authLog: [String] { mock("GET", "/api/_mock/auth-log")?["log"] as? [String] ?? [] }

    /// Waits for the mock's log to end the way `suffix` says.
    private func waitForLog(endingWith suffix: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if authLog.suffix(suffix.count) == ArraySlice(suffix) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    /// The copy on screen: every tab page is mounted, so the first match can be another one.
    /// Not one under the software keyboard either (a simulator without a hardware keyboard):
    /// XCUITest calls that hittable, and a tap there lands on a key. iOS's Save Password
    /// prompt is answered on the way.
    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            declineSavePassword()
            let keyboard = app.keyboards.firstMatch
            let covered = keyboard.exists ? keyboard.frame : .null
            if let e = query.allElementsBoundByIndex.first(where: { $0.isHittable && !$0.frame.intersects(covered) }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    /// iOS's own "Save Password?" (Password AutoFill) comes up over the app when the form goes
    /// away with the software keyboard still on the password field, and covers the tab bar.
    /// Not Now, as someone who keeps the sign-in in Vory would answer.
    private func declineSavePassword() {
        let prompt = app.sheets.matching(NSPredicate(format: "label CONTAINS 'Save Password'")).firstMatch
        guard prompt.exists else { return }
        let notNow = prompt.buttons["Not Now"]
        if notNow.exists { notNow.tap() }
    }

    /// Scrolls the form until the element is on screen.
    private func scrolledTo(_ query: XCUIElementQuery, swipes: Int = 6) -> XCUIElement? {
        var e = hittable(query, timeout: 2)
        var n = 0
        while e == nil, n < swipes {
            app.swipeUp(velocity: .slow)
            n += 1
            e = hittable(query, timeout: 2)
        }
        return e
    }

    func testTheSwitchRemembersAndAnExpiredSessionSignsInAgain() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HERMES_E2E_URL"], !url.isEmpty, env["HERMES_E2E_TOKEN"] == "mock-token",
              let bundle = env["HERMES_E2E_BUNDLE"], bundle.hasSuffix(".demo") else {
            throw XCTSkip("needs the mock gateway (HERMES_E2E_URL, HERMES_E2E_TOKEN=mock-token) and the demo copy (HERMES_E2E_BUNDLE)")
        }
        continueAfterFailure = false
        gatewayURL = url
        let on = mock("POST", "/api/_mock/password-auth", ["enabled": true, "username": username, "password": password])
        guard on?["enabled"] as? Bool == true else { throw XCTSkip("this mock has no password sign-in (update Tools/mock-gateway/mock_gateway.py)") }

        // A fresh demo copy: no gateway yet, so the first screen leads to the form.
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo-biometry", "yes", "-companionPromptShown", "YES"]
        app.launch()
        try XCTUnwrap(hittable(app.buttons.matching(identifier: "onboarding.getStarted"), timeout: 30), "no first screen").tap()
        try XCTUnwrap(hittable(app.buttons.matching(identifier: "onboarding.skip")), "no Skip").tap()
        try XCTUnwrap(hittable(app.buttons.matching(identifier: "onboarding.addGateway")), "no Connect your gateway").tap()

        let name = try XCTUnwrap(hittable(app.textFields.matching(identifier: "gateway.name")), "no form")
        name.tap(); name.typeText("Workshop")
        let address = try XCTUnwrap(hittable(app.textFields.matching(identifier: "gateway.url")))
        address.tap(); address.typeText(url)

        // Username & password, from the method menu.
        let method = try XCTUnwrap(scrolledTo(app.descendants(matching: .any).matching(identifier: "gateway.authMethod")), "no method picker")
        method.tap()
        let option = hittable(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Username & password'")), timeout: 5)
        if option == nil { print("MENU-TREE \(app.debugDescription)"); shot("remember-no-menu") }
        try XCTUnwrap(option, "no password method in the menu").tap()

        let user = try XCTUnwrap(scrolledTo(app.textFields.matching(identifier: "gateway.username")), "no username field")
        user.tap(); user.typeText(username)
        let secret = try XCTUnwrap(scrolledTo(app.secureTextFields.matching(identifier: "gateway.password")), "no password field")
        secret.tap(); secret.typeText(password)
        XCTAssertEqual((secret.value as? String)?.count, password.count, "the password did not go in")

        // The switch: there, and off until turned on.
        let remember = try XCTUnwrap(scrolledTo(app.switches.matching(identifier: "gateway.rememberSignIn")), "no Remember switch on the password form")
        XCTAssertEqual(remember.value as? String, "0", "Remember sign-in must start off")
        shot("remember-switch-off")
        // The switch itself, not the row's label (a tap there does nothing). Tapped again if it
        // went in while the form was still moving (the keyboard going down scrolls it).
        let turnedOn = NSPredicate(format: "value == '1'")
        for _ in 0..<3 where remember.value as? String != "1" {
            let knob = remember.switches.firstMatch
            if knob.exists { knob.tap() } else { remember.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
            if XCTWaiter.wait(for: [expectation(for: turnedOn, evaluatedWith: remember)], timeout: 5) == .completed { break }
        }
        if remember.value as? String != "1" {
            print("SWITCH-TREE \(app.debugDescription)")
            shot("remember-switch-stuck")
            XCTFail("the Remember switch did not turn on")
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Keychain' AND label CONTAINS 'Never synced'")).firstMatch.exists,
                      "the switch does not say where the sign-in is kept")
        shot("remember-switch-on")

        try XCTUnwrap(scrolledTo(app.buttons.matching(identifier: "gateway.test")), "no Test Connection").tap()
        let save = app.buttons["gateway.save"].firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: save)], timeout: 40)
        save.tap()
        XCTAssertTrue(waitForLog(endingWith: ["password-login"], timeout: 20), "never signed in: \(authLog)")

        // Settings › Gateways lists the remembered sign-in.
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40), "the app did not open after Save")
        // With the software keyboard up at Save, iOS asks to save the password over the chat
        // list, and the tab bar is under it until it is answered (`hittable` does).
        guard let settingsTab = hittable(app.buttons.matching(identifier: "tab.settings"), timeout: 20) else {
            print("NO-SETTINGS-TREE \(app.debugDescription)")
            shot("remember-no-settings-tab")
            XCTFail("no Settings tab")
            return
        }
        settingsTab.tap()
        guard let gateways = hittable(app.buttons.matching(identifier: "settings.row.gateways")) else {
            // Seen once on a busy run, after two system password prompts: what was on screen.
            print("NO-GATEWAYS-TREE \(app.debugDescription)")
            shot("remember-no-gateways-row")
            return XCTFail("no Gateways row")
        }
        gateways.tap()
        let forget = try XCTUnwrap(hittable(app.buttons.matching(identifier: "gateway.forgetSignIn")), "no Forget row for the remembered sign-in")
        shot("remembered-in-settings")

        // The gateway ends every session: the next call is refused, the renewal too, and the
        // remembered sign-in signs in again by itself.
        XCTAssertNotNil(mock("POST", "/api/_mock/expire-sessions", [:]))
        try XCTUnwrap(hittable(app.buttons.matching(NSPredicate(format: "label == 'Reconnect'"))), "no Reconnect").tap()
        XCTAssertTrue(waitForLog(endingWith: ["refresh expired", "password-login"], timeout: 30), "no silent sign-in after the session ended: \(authLog)")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == 'Sign in again'")).firstMatch.exists, "asked to sign in although the sign-in is remembered")
        shot("signed-in-again")

        // Forgotten: the same expiry goes back to asking.
        forget.tap()
        XCTAssertTrue(forget.waitForNonExistence(timeout: 5), "Forget left the row")
        XCTAssertNotNil(mock("POST", "/api/_mock/expire-sessions", [:]))
        try XCTUnwrap(hittable(app.buttons.matching(NSPredicate(format: "label == 'Reconnect'"))), "no Reconnect").tap()
        let signInAgain = app.buttons.matching(NSPredicate(format: "label == 'Sign in again'")).firstMatch
        XCTAssertTrue(signInAgain.waitForExistence(timeout: 30), "a forgotten sign-in did not fall back to asking: \(authLog)")
        XCTAssertEqual(authLog.last, "refresh expired", "signed in again after the sign-in was forgotten: \(authLog)")
        shot("forgotten-asks-again")
    }
}
