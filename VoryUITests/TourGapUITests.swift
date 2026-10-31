import XCTest

/// Vory's walk through the tour (#489), at the default text size and the largest: a still of every beat, and at each beat
/// VoiceOver reads his line once (the bubble not showing is out of the tree); and back through the side swaps by swipes. Whether he ever meets his bubble is checked
/// on the frames of a screen recording of this walk, by eye with their times: the DEBUG probe (`-vory-tour-gap-probe`,
/// `TourGapProbe`) misread during the main-thread stall as the tour's chat comes up, so its reading is printed only, as
/// an aid. The demo copy with no gateway (HERMES_E2E_BUNDLE).
final class TourGapUITests: XCTestCase {
    private var app: XCUIApplication!

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty {
            let d = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
        }
    }

    /// VoiceOver reads his line, once: the bubble that isn't showing is out of the tree.
    private func checkHisLineIsReadOnce(_ when: String) {
        let vory = any("onboarding.vory")
        XCTAssertTrue(vory.exists, "\(when): no Vory")
        let label = vory.label
        print("TOUR-VORY \(when): \(label)")
        let line = label.hasPrefix("Vory, ") ? String(label.dropFirst("Vory, ".count)) : label
        let half = (line.count - 2) / 2
        let twice = line.count > 2 && (line.count - 2) % 2 == 0 && line.prefix(half) == line.suffix(half)
        XCTAssertTrue(!line.isEmpty && !twice, "\(when): Vory reads as '\(label)'")
    }

    private func walk(_ label: String, _ extra: [String]) throws {
        guard let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { throw XCTSkip("HERMES_E2E_BUNDLE not set") }
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-companionPromptShown", "YES", "-colorSchemePreference", "light", "-vory-tour-gap-probe"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.getStarted"].firstMatch.waitForExistence(timeout: 30), "no tour")
        pause(4); shot("489-\(label)-1"); checkHisLineIsReadOnce("hello")
        app.buttons["onboarding.getStarted"].firstMatch.tap(); pause(4); shot("489-\(label)-2"); checkHisLineIsReadOnce("bots")
        app.buttons["onboarding.continue"].firstMatch.tap()
        XCTAssertTrue(any("onboarding.chatDock").waitForExistence(timeout: 20), "no tour chat")
        pause(3); shot("489-\(label)-3"); checkHisLineIsReadOnce("chat")
        app.buttons["composer.send"].firstMatch.tap()
        let allow = app.buttons["Allow once"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 40), "no card")
        pause(3); allow.tap(); pause(8); shot("489-\(label)-4"); checkHisLineIsReadOnce("approval")
        app.buttons["onboarding.continue"].firstMatch.tap()
        // Beat 5's places, each with its hop.
        pause(20); shot("489-\(label)-5"); checkHisLineIsReadOnce("everywhere")
        app.buttons["onboarding.continue"].firstMatch.tap(); pause(4); shot("489-\(label)-6"); checkHisLineIsReadOnce("connect")
        let probe = any("debug.tourgap")
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "no gap probe")
        // An aid only: the frames of a recording decide.
        print("TOUR-GAP \(label): \(probe.value as? String ?? "")")
        app.terminate()
    }

    /// Back through the side swaps by swipes, chat to bots and bots to hello (the bubbles take the same path backwards): a
    /// still of each and his line read once; a recording of it shows the bubbles on the way back.
    private func walkBack(_ label: String, _ extra: [String]) throws {
        guard let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { throw XCTSkip("HERMES_E2E_BUNDLE not set") }
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-companionPromptShown", "YES", "-colorSchemePreference", "light", "-vory-tour-gap-probe"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.getStarted"].firstMatch.waitForExistence(timeout: 30), "no tour")
        pause(2); app.buttons["onboarding.getStarted"].firstMatch.tap(); pause(3)
        app.buttons["onboarding.continue"].firstMatch.tap()
        XCTAssertTrue(any("onboarding.chatDock").waitForExistence(timeout: 20), "no tour chat")
        pause(3); shot("489-\(label)-back-1")
        swipeBack(); pause(3); shot("489-\(label)-back-2"); checkHisLineIsReadOnce("back to bots")
        swipeBack(); pause(3); shot("489-\(label)-back-3"); checkHisLineIsReadOnce("back to hello")
        XCTAssertTrue(app.buttons["onboarding.getStarted"].firstMatch.isHittable, "the swipes didn't bring the tour back to its first beat")
        app.terminate()
    }

    /// A swipe to the previous page, across Vory's part of the screen (which takes no touches) rather than the chat.
    private func swipeBack() {
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.2)), withVelocity: .default, thenHoldForDuration: 0)
    }

    func testTheWalkAtTheDefaultSize() throws { try walk("default", []) }

    func testTheWalkBackAtTheDefaultSize() throws { try walkBack("default", []) }

    func testTheWalkBackAtTheLargestText() throws {
        try walkBack("largest", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }

    func testTheWalkAtTheLargestText() throws {
        try walk("largest", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }
}
