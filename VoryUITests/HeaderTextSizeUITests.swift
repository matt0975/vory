import XCTest

/// The chat headers at an accessibility text size: the back circle keeps its place at the
/// leading edge, and the plate between the circles ends its lines in "…" rather than growing
/// past them. (A plate that kept its full width pushed the row wider than the screen, and Back
/// slid off the left edge with larger text or long names.) Checked on a group chat with a long
/// name and four bots, made on the mock, and on a single chat with a long title.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=com.vorantx.vory.demo
/// drives the demo copy (Tools/dev/make-demo-app-sim.sh). HERMES_E2E_SHOTS names a folder for
/// the screenshots.
@MainActor
final class HeaderTextSizeUITests: XCTestCase {
    private var app: XCUIApplication!
    private let roomName = "Release planning for the spring launch"
    private let chatTitle = "Rewrite the nightly export job"

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

    /// One call to the mock's own controls, answered as JSON.
    private func mock(_ gateway: String, _ method: String, _ path: String, _ body: [String: Any]) -> [String: Any]? {
        guard let url = URL(string: gateway + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
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

    private func launch(url: String, token: String) {
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES"]
        } else {
            app = XCUIApplication()
        }
        // The third accessibility size (AX2), well past the largest of the usual sizes.
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
    }

    /// The copy on screen: every tab page is mounted, so the first match can be another one.
    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = query.allElementsBoundByIndex.first(where: { $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    /// Scrolls the page until the element is on screen.
    private func scrolledTo(_ query: XCUIElementQuery, swipes: Int = 8) -> XCUIElement? {
        var e = hittable(query, timeout: 3)
        var n = 0
        while e == nil, n < swipes {
            app.swipeUp(velocity: .slow)
            n += 1
            e = hittable(query, timeout: 2)
        }
        return e
    }

    private func label(_ text: String) -> NSPredicate { NSPredicate(format: "label == %@", text) }

    /// The element with this identifier, once it is there. (A single chat's header circles are
    /// not hittable to XCUITest even where they are on screen, so frames are compared instead.)
    private func element(_ identifier: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let e = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        return e.waitForExistence(timeout: timeout) ? e : nil
    }

    /// The header's row fits the screen: Back at its inset from the leading edge, the plate
    /// after it, and the circle on the far side (when there is one) inside the trailing edge.
    private func checkRow(back: XCUIElement, plate: XCUIElement, trailing: XCUIElement?, _ page: String) {
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(back.frame.minX, screen.minX + 12, "\(page): Back moved toward or past the leading edge: \(back.frame) on \(screen)")
        XCTAssertGreaterThan(back.frame.width, 0, "\(page): Back has no size")
        XCTAssertGreaterThanOrEqual(plate.frame.minX, back.frame.maxX, "\(page): the plate runs over Back: \(plate.frame), \(back.frame)")
        XCTAssertLessThanOrEqual(plate.frame.maxX, screen.maxX - 12, "\(page): the plate runs past the trailing edge: \(plate.frame) on \(screen)")
        if let trailing {
            XCTAssertLessThanOrEqual(trailing.frame.maxX, screen.maxX - 12, "\(page): the trailing circle moved toward or past the edge: \(trailing.frame) on \(screen)")
        }
    }

    func testBackStaysOnScreenAtAnAccessibilityTextSize() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        // Four bots and a name past the header's own cap: the longest header the app draws.
        let made = mock(url, "POST", "/api/_mock/rooms", ["name": roomName, "handles": ["default", "work", "research", "writer"]])
        guard made?["room"] != nil else { throw XCTSkip("this mock cannot make a group chat (update Tools/mock-gateway/mock_gateway.py)") }
        launch(url: url, token: token)

        // The group chat, from Bots.
        // The first tap can land while the app is still settling on its first page, and a list
        // read before the gateway answered has no group chats: tap again, pull to refresh.
        var card: XCUIElement?
        for _ in 0..<3 where card == nil {
            try XCTUnwrap(hittable(app.buttons.matching(identifier: "tab.bots"), timeout: 60), "no Bots tab").tap()
            card = scrolledTo(app.staticTexts.matching(label(roomName)))
            if card == nil { for _ in 0..<4 { app.swipeDown(velocity: .fast) } }
        }
        guard let card else {
            shot("header-ax-0-no-room")
            print(app.debugDescription)
            return XCTFail("the group chat is not listed on Bots")
        }
        card.tap()
        guard let plate = element("group.header", timeout: 20) else { shot("header-ax-0-no-group"); return XCTFail("the group chat did not open") }
        sleep(2)
        shot("header-ax-1-group")
        let back = try XCTUnwrap(element("group.back"), "the group chat has no Back")
        checkRow(back: back, plate: plate, trailing: nil, "group chat")
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotNil(hittable(app.staticTexts.matching(label(roomName)), timeout: 10), "Back did not leave the group chat")

        // A single chat with a long title, from Chats: idle, its title is the line under the bot.
        try XCTUnwrap(hittable(app.buttons.matching(identifier: "tab.chats")), "no Chats tab").tap()
        try XCTUnwrap(scrolledTo(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", chatTitle))), "no chat with a long title").tap()
        guard let pill = element("chat.titlePill", timeout: 20) else { shot("header-ax-2-no-chat"); return XCTFail("the chat did not open") }
        // Past "Syncing…", so the title is the line shown.
        sleep(4)
        shot("header-ax-2-chat")
        let chatBack = try XCTUnwrap(element("chat.back"), "the chat has no Back")
        let more = try XCTUnwrap(element("chat.more"), "the chat has no … circle")
        checkRow(back: chatBack, plate: pill, trailing: more, "single chat")
        chatBack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotNil(hittable(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", chatTitle)), timeout: 10), "Back did not leave the chat")
    }
}
