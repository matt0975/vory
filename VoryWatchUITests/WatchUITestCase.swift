import XCTest

/// The Watch's UI tests and screenshot gate (#387). Each test launches the Watch app against the
/// mock gateway and reaches its screen by taps; `shot` keeps a screenshot as an attachment and,
/// with HERMES_E2E_SHOTS set, as `<name>.png` in that folder on the host.
///
/// The host sets the run up (the harness does it for every size and mode):
/// - TEST_RUNNER_HERMES_E2E_URL / TEST_RUNNER_HERMES_E2E_TOKEN: the mock. The app takes them
///   through its DEBUG gateway seeding (VORY_E2E_URL / VORY_E2E_TOKEN): the Watch talks to the
///   mock itself, unpaired. Without them the tests skip.
/// - TEST_RUNNER_HERMES_E2E_SHOTS: where the screenshots go.
/// - TEST_RUNNER_HERMES_E2E_CONTENT_SIZE: a text size for the app (a UIContentSizeCategory raw
///   value, such as UICTContentSizeCategoryAccessibilityXXXL), passed as a launch argument: the
///   watchOS simulator takes no system text size from `simctl ui`.
/// - Increase Contrast is the simulator's own setting (the harness writes the accessibility
///   default), so the app runs as it would on a Watch set that way.
/// - TEST_RUNNER_HERMES_E2E_DIMMED=1: the app drawn as with the wrist down (the DEBUG launch
///   argument -vory-test-dimmed, the one test hook in the Watch app, since the simulator cannot be
///   put in the always-on state).
@MainActor
class WatchUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The Watch app, connected to the mock, on its start screen.
    func launch(arguments: [String] = [], environment: [String: String] = [:]) throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        app = XCUIApplication()
        app.launchEnvironment = ["VORY_E2E_URL": url, "VORY_E2E_TOKEN": token].merging(environment) { $1 }
        var args = arguments
        if let size = e["HERMES_E2E_CONTENT_SIZE"], !size.isEmpty { args += ["-UIPreferredContentSizeCategoryName", size] }
        if e["HERMES_E2E_DIMMED"] == "1" { args += ["-vory-test-dimmed", "YES"] }
        app.launchArguments = args
        app.launch()
    }

    /// An element by its accessibility identifier, of any type.
    func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    /// A button by its label.
    func button(_ label: String) -> XCUIElement { app.buttons[label].firstMatch }

    /// The screen as it is, kept as an attachment and written to HERMES_E2E_SHOTS.
    func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        guard let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty else { return }
        let d = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
    }

    /// One line in the test log for the harness ("W387 <time> <what>").
    func mark(_ what: String) { print(String(format: "W387 %.2f %@", Date().timeIntervalSince1970, what)) }
}
