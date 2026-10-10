import XCTest

/// Settings › Scheduled Tasks › a task › Run now, pressed twice in quick succession: the button
/// reads Running… at once and is off while the gateway runs the task, the gateway is asked for
/// one run, not two, and a confirmation follows; pressed while the task already runs, the
/// gateway's refusal reads as plain words. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN
/// point at the mock gateway, which holds a Run now for a few seconds the way a real task does
/// and lists every one it gets at /api/_mock/cron-triggers. HERMES_E2E_BUNDLE=com.vorantx.vory.demo
/// drives the demo copy, pointed at the gateway by launch argument.
final class CronRunNowUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
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

    private func launch(url: String, token: String) {
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "settings"]
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-launchTab", "settings"]
        }
        app.launch()
    }

    /// The one on screen: every tab page is mounted, so the first match can be another copy.
    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = query.allElementsBoundByIndex.first(where: { $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    /// A list row below the fold does not exist to the test until it is scrolled to.
    private func scrolledTo(_ query: XCUIElementQuery, swipes: Int = 6) -> XCUIElement? {
        var found = hittable(query, timeout: 5)
        var n = 0
        while found == nil, n < swipes {
            app.swipeUp(velocity: .slow)
            n += 1
            found = hittable(query, timeout: 2)
        }
        return found
    }

    /// How many Run nows the mock gateway has had for this task.
    private func triggers(_ base: String, job: String) throws -> Int {
        let url = try XCTUnwrap(URL(string: base + "/api/_mock/cron-triggers"))
        var request = URLRequest(url: url); request.timeoutInterval = 5
        let done = expectation(description: "triggers")
        var count: Int?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = obj["triggers"] as? [[String: Any]] {
                count = list.filter { $0["job_id"] as? String == job }.count
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 8)
        return try XCTUnwrap(count, "the mock gateway did not say how many runs it was asked for")
    }

    func testRunNowPressedTwiceShowsRunningAndAsksForOneRun() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        launch(url: url, token: token)

        if hittable(app.buttons.matching(identifier: "settings.row.cron"), timeout: 8) == nil,
           let tab = hittable(app.buttons.matching(identifier: "tab.settings"), timeout: 20) {
            tab.tap()
        }
        // The Hermes rows are off until the gateway is connected.
        let rowQuery = app.buttons.matching(identifier: "settings.row.cron")
        guard let row = scrolledTo(rowQuery) else { shot("cron-no-row"); return XCTFail("no Scheduled Tasks row") }
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: row)], timeout: 60)
        row.tap()

        guard let task = hittable(app.staticTexts.matching(NSPredicate(format: "label == 'Morning brief'")), timeout: 30) else {
            shot("cron-no-task"); return XCTFail("the mock's task is not listed")
        }
        task.tap()
        guard let runNow = scrolledTo(app.buttons.matching(identifier: "cron.runNow")) else {
            shot("cron-no-run-now"); return XCTFail("no Run now button")
        }
        // To the end of the page, so the button and the line under it sit above the tab bar.
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(runNow.label, "Run now")
        let before = try triggers(url, job: "morning-brief")

        // Two quick presses, the way a tester pressed again when nothing seemed to happen.
        runNow.doubleTap()
        XCTAssertTrue(runNow.label.contains("Running…"), "the button did not say Running… (it says \(runNow.label))")
        XCTAssertFalse(runNow.isEnabled, "the button can still be pressed while the run is out")
        shot("cron-run-now-running")

        let confirmed = expectation(for: NSPredicate(format: "label == 'Finished' OR label == 'Started'"), evaluatedWith: runNow)
        wait(for: [confirmed], timeout: 30)
        shot("cron-run-now-finished")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == 'Last result: ok.'")).firstMatch.waitForExistence(timeout: 5), "no result under the button")
        XCTAssertEqual(try triggers(url, job: "morning-brief") - before, 1, "Run now pressed twice asked the gateway for more than one run")
        // The task reloaded with its new run, and nothing was edited: Save stays off.
        let save = try XCTUnwrap(hittable(app.buttons.matching(NSPredicate(format: "label == 'Save'")), timeout: 5), "no Save button")
        XCTAssertFalse(save.isEnabled, "Save lit up after a run though nothing was edited")

        // The confirmation gives way to Run now, ready for another run.
        let ready = expectation(for: NSPredicate(format: "label == 'Run now' AND isEnabled == true"), evaluatedWith: runNow)
        wait(for: [ready], timeout: 15)
        XCTAssertEqual(try triggers(url, job: "morning-brief") - before, 1)

        // Started from elsewhere (another device, or its schedule) and pressed here meanwhile: the
        // gateway's 409 reads as plain words, and the button is ready again.
        var other = URLRequest(url: try XCTUnwrap(URL(string: url + "/api/cron/jobs/morning-brief/trigger")))
        other.httpMethod = "POST"; other.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: other).resume()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        runNow.tap()
        let busy = app.staticTexts.matching(NSPredicate(format: "label == 'It is already running. Wait for it to finish, then try again.'")).firstMatch
        XCTAssertTrue(busy.waitForExistence(timeout: 10), "the gateway's 409 is not in plain words")
        XCTAssertEqual(runNow.label, "Run now")
        shot("cron-run-now-already-running")
    }
}
