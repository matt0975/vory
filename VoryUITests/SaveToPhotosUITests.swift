import XCTest

/// Save to Photos in the picture viewer: the permission answered, the button says Saved and the
/// app is still running a few seconds on (it used to stop the app on every device: Photos ran the
/// change and its answer on its own queue, the closures had taken the viewer's main-actor
/// isolation, and Swift's runtime check trapped). Skipped unless HERMES_E2E_URL /
/// HERMES_E2E_TOKEN are set (the mock gateway's Disk cleanup chat has a picture in its reply).
/// HERMES_E2E_BUNDLE=com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch
/// argument. The Photos permission must be unanswered so its prompt shows: reset it before the
/// run (xcrun simctl privacy <udid> reset all <bundle id>).
final class SaveToPhotosUITests: XCTestCase {
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
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES"]
        } else {
            app = XCUIApplication()
        }
        app.launch()
    }

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = query.allElementsBoundByIndex.first(where: { $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    /// The buttons that let the app add to Photos, by the words the prompt has used: the add-only
    /// prompt and the full-library one differ between versions.
    private static let allowLabels = ["Allow", "Allow Full Access", "Allow Access to All Photos", "OK"]

    /// Answers the Photos prompt with an allow, wherever it is drawn (it belongs to the system,
    /// not the app). False when no prompt came.
    private func allowPhotos(timeout: TimeInterval) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for owner in [springboard, app!] {
                let alert = owner.alerts.firstMatch
                guard alert.exists else { continue }
                shot("photos-prompt")
                if let allow = Self.allowLabels.lazy.map({ alert.buttons[$0] }).first(where: { $0.exists }) {
                    allow.tap()
                    return true
                }
            }
            if app.state != .runningForeground || app.buttons["Saved"].exists { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    func testSaveToPhotosSavesAndTheAppKeepsRunning() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        // The prompt's fallback: a prompt the loop below does not see is answered the next time
        // the test touches the app.
        addUIInterruptionMonitor(withDescription: "Photos permission") { alert in
            guard let allow = Self.allowLabels.lazy.map({ alert.buttons[$0] }).first(where: { $0.exists }) else { return false }
            allow.tap()
            return true
        }
        launch(url: url, token: token)

        // The seeded chat whose reply ends with a picture. Every tab page is mounted: the row to
        // tap is the one on screen.
        guard let row = hittable(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Disk cleanup'")), timeout: 40) else {
            shot("photos-no-chat"); return XCTFail("no Disk cleanup chat")
        }
        row.tap()
        XCTAssertTrue(app.textViews["composer.text"].firstMatch.waitForExistence(timeout: 30), "the chat did not open")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "disk use before and after")).firstMatch
            .waitForExistence(timeout: 30), "the reply with the picture is not there")

        // The picture's thumbnail, opened full screen. The thread opens at its end, where the
        // picture is; a drag up brings it out from under the composer if it sits there.
        let thumbs = app.buttons.matching(NSPredicate(format: "label == 'Image disk-before-after.png'"))
        var thumb = hittable(thumbs, timeout: 20)
        for _ in 0..<3 where thumb == nil {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            thumb = hittable(thumbs, timeout: 3)
        }
        guard let thumb else { shot("photos-no-thumb"); return XCTFail("the picture is not in the reply") }
        thumb.tap()

        // The viewer's Save to Photos shows once the picture has loaded.
        let save = app.buttons["Save to Photos"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 30), "the viewer has no Save to Photos")
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: save)], timeout: 10)
        shot("photos-viewer")
        save.tap()

        // Photos runs the change block on its own queue as soon as it is handed over (the old
        // code stopped the app right there, before the prompt showed), asks for the permission,
        // allowed here, and answers on its own queue too.
        // Saved before the prompt is answered would be a bug of its own (allowPhotos stops at it),
        // so the prompt must come first: the run resets the permission before launch.
        var prompted = allowPhotos(timeout: 20)
        let saved = app.buttons["Saved"].firstMatch
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, app.state == .runningForeground, !saved.exists {
            // A prompt that came late is still answered.
            if !prompted { prompted = allowPhotos(timeout: 1) } else { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        }
        XCTAssertEqual(app.state, .runningForeground, "the app stopped after Save to Photos")
        shot("photos-saved")
        XCTAssertTrue(prompted, "no Photos prompt came before Saved (reset the permission before the run)")
        XCTAssertTrue(saved.exists, "the button never said Saved")
        XCTAssertFalse(saved.isEnabled, "Saved can be tapped again")

        // Still running a little later, once Photos has nothing more to answer.
        sleep(4)
        XCTAssertEqual(app.state, .runningForeground, "the app stopped after the picture was saved")
        XCTAssertTrue(app.buttons["Saved"].firstMatch.exists, "the viewer lost its Saved")
    }
}
