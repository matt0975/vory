import XCTest

/// The speech recognition prompt the system shows reads as Matt approved it on the device it's on (#500): "this iPad" on
/// an iPad (`NSSpeechRecognitionUsageDescription~ipad`), "this iPhone" on an iPhone. The prompt is raised by a DEBUG
/// launch argument (`-vory-ask-speech-permission`), on the demo copy freshly installed so it hasn't been answered
/// (HERMES_E2E_BUNDLE); a still of it, then Don't Allow.
final class PermissionPromptUITests: XCTestCase {
    func testTheSpeechPromptNamesTheDeviceItIsOn() throws {
        guard let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty else { throw XCTSkip("HERMES_E2E_BUNDLE not set (a fresh demo copy)") }
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-companionPromptShown", "YES", "-vory-ask-speech-permission"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "no speech recognition prompt")
        // The system's own paragraph comes first; the app's follows it, anywhere in the alert.
        let words = alert.descendants(matching: .any).allElementsBoundByIndex.map { $0.label }.filter { !$0.isEmpty }.joined(separator: " | ")
        print("SPEECH-PROMPT \(words)")
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        XCTAssertTrue(words.contains("Turn what you say into text on this \(device). When your gateway has its own speech provider and Speech is set to Automatic or Gateway, your audio goes to the gateway instead."),
                      "the prompt reads: \(words)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "500-speech-prompt-\(device)"; shot.lifetime = .keepAlways; add(shot)
        if let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty {
            let d = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: d.appendingPathComponent("500-speech-prompt-\(device).png"))
        }
        let deny = alert.buttons.element(boundBy: 0)
        if deny.exists { deny.tap() }
    }
}
