import XCTest

/// The tab bar's size (1.5 (26): the iPad's bar the same small size as the iPhone's): along the bottom the bar
/// group (the capsule and its circles) runs at most 398 pt, its length on the widest iPhone held upright, centred, on
/// an iPad and the open Duo upright; on an iPhone held upright it is the window less the two 21 pt margins, as in 1.5.
/// Also pictured for the review (HERMES_E2E_SHOTS): the Chats list, a chat open beside it, and on an iPad a pushed page with its
/// Back, and a tap just beside the capped bar reaching the row behind it.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock, with --extra-sessions 60 for a long list).
/// HERMES_E2E_BUNDLE=com.vorantx.vory.demo drives the demo copy.
@MainActor
final class BarSizeUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private var shotDir: URL {
        let given = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"].flatMap { $0.isEmpty ? nil : $0 }
        let d = given.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bar-size", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        try? s.pngRepresentation.write(to: shotDir.appendingPathComponent("barsize-\(name).png"))
    }

    private func launch(url: String, token: String) {
        let args = ["-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "light",
                    "-tabLayout", "dashboard,chats,bots,settings", "-tabLayout.homeFirstApplied", "YES"]
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

    /// The bar group's frame along the bottom: the capsule's start worked out from its slots (equal, side by side;
    /// a tab's own frame is narrower than its slot) less the 4 pt inset, to the compose circle's end.
    private func group() -> CGRect {
        let centres = ["tab.dashboard", "tab.chats", "tab.bots", "tab.settings"].map { any($0).frame }.filter { $0.width > 0 }.map(\.midX).sorted()
        let compose = any("chats.new").frame
        guard centres.count >= 2 else { return compose }
        let slot = centres[1] - centres[0]
        let start = centres[0] - slot / 2 - 4
        return CGRect(x: start, y: compose.minY, width: compose.maxX - start, height: compose.height)
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// An iPad either way up, a phone upright (the only way it runs): the window less the two margins, up to 398 pt,
    /// centred. Anything wider than tall that is not an iPad (the open Duo on its side) has the vertical strip: not checked.
    private func checkSize(_ label: String) {
        let g = group(), w = app.frame.width
        let left = g.minX, right = w - g.maxX
        print("BAR-SIZE \(label) window \(app.frame.size) group \(g) margins \(left) / \(right)")
        guard isPad || app.frame.height > app.frame.width else { return }
        XCTAssertEqual(g.width, min(w - 42, 398), accuracy: 2, "\(label): the bar group is \(g.width) pt in a \(w) pt window")
        XCTAssertEqual(left, right, accuracy: 2, "\(label): the bar is not centred (\(left) / \(right))")
    }

    func testTheBarKeepsTheIPhonesSize() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        launch(url: url, token: token)
        XCTAssertTrue(any("chats.new").waitForExistence(timeout: 40), "the bar did not come")
        pause(2)
        checkSize("portrait")
        shot("1-portrait-list")

        // A chat open: on a wide window it stands beside the list, the bar still under both.
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Disk cleanup'"))
        if rows.firstMatch.waitForExistence(timeout: 10) { rows.firstMatch.tap(); pause(2.5) }
        shot("2-portrait-chat-open")
        let composer = app.textViews["composer.text"].firstMatch
        if composer.exists, any("chats.new").exists {
            let bar = group()
            XCTAssertFalse(composer.frame.intersects(bar), "the composer and the bar overlap: \(composer.frame) / \(bar)")
            print("BAR-SIZE chat open: composer \(composer.frame) bar \(bar)")
        }

        // The rest is the iPad's: the iPhone app is portrait-only (Info.plist), so a phone has no side to be turned
        // to, and an upright phone's bar leaves no room beside it.
        guard isPad else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(2.5)
        checkSize("landscape")
        shot("3-landscape-chat-open")

        // A pushed page with its Back: a bot's page from the Bots tab.
        any("tab.bots").tap(); pause(2)
        let bot = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'work'")).firstMatch
        if bot.waitForExistence(timeout: 10) { bot.tap(); pause(2) }
        shot("4-landscape-pushed-page")
        let back = app.navigationBars.buttons.firstMatch
        print("BAR-SIZE pushed page: back \(back.exists ? back.label : "none")")

        // Beside the capped bar the row behind it answers (the shield is the bar's shape, not a strip).
        any("tab.chats").tap(); pause(2)
        if app.buttons["chat.back"].exists { app.buttons["chat.back"].tap(); pause(1) }
        XCUIDevice.shared.orientation = .portrait
        pause(2.5)
        let g = group()
        if isPad, g.minX > 60 {
            let list = app.buttons.matching(NSPredicate(format: "label CONTAINS 'nothing else needs a hand' OR label CONTAINS 'Weekly'"))
            for _ in 0..<8 where !(list.allElementsBoundByIndex.contains { $0.frame.minY < g.midY && $0.frame.maxY > g.midY }) {
                app.swipeUp(velocity: .slow); pause(0.8)
            }
            let behind = list.allElementsBoundByIndex.first { $0.frame.minY < g.midY && $0.frame.maxY > g.midY && $0.frame.minX < g.minX - 20 }
            let p = CGPoint(x: g.minX - 30, y: g.midY)
            shot("5-portrait-beside-before")
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y)).tap()
            pause(2)
            shot("6-portrait-beside-after")
            print("BAR-SIZE beside the bar at \(p): row behind \(behind?.label ?? "none"); composer now \(app.textViews["composer.text"].firstMatch.exists)")
            if behind != nil { XCTAssertTrue(app.textViews["composer.text"].firstMatch.waitForExistence(timeout: 5), "a tap beside the bar did not open the row behind it") }
        }
    }
}
