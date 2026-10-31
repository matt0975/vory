import XCTest

/// A pushed page has one Back, the top bar's, even after something walks its whole accessibility tree, as VoiceOver,
/// Voice Control and Full Keyboard Access do. On the closed iPhone Duo such a walk made the system's own Back show in the
/// side strip beside the bar's. Runs on the closed Duo and the iPhone; a still of each page after the walk. Skipped unless
/// HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
final class PushedPageBackUITests: XCTestCase {
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

    private func launch(tab: String) throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        let args = ["-companionPromptShown", "YES", "-launchTab", tab, "-colorSchemePreference", "light"]
        if let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
    }

    /// Settings' API Keys row, scrolled clear of the tab bar (it was "hittable" behind it, and the tap went to Home).
    private func openAPIKeys() {
        XCTAssertTrue(any("settings.row.profile").waitForExistence(timeout: 30), "no Settings rows")
        let row = any("settings.row.env")
        let limit = app.windows.firstMatch.frame.maxY - 150
        for _ in 0..<12 where !(row.exists && row.isHittable && row.frame.maxY < limit) { app.swipeUp(velocity: .slow); pause(0.8) }
        XCTAssertTrue(row.exists && row.isHittable, "no API Keys row")
        row.tap()
    }

    /// The whole tree read, element by element, as an assistive technology reads it.
    private func walkTheTree() {
        for element in app.descendants(matching: .any).allElementsBoundByIndex where element.exists { _ = element.frame; _ = element.label }
        pause(1.5)
    }

    /// One Back, the bar's (`backID`): no system Back anywhere in the tree (UIKit's `BackButton`, which the strip drew),
    /// and nothing else that reads as Back outside the bar's own (its chevron is part of it).
    private func checkOneBack(_ backID: String, _ page: String) {
        let bar = any(backID)
        XCTAssertTrue(bar.exists, "\(page): no Back of the bar's")
        let barFrame = bar.frame
        let backs = app.descendants(matching: .any).allElementsBoundByIndex.filter {
            $0.exists && ($0.label == "Back" || $0.identifier == "BackButton")
        }
        for b in backs { print("PAGE-BACK \(page) type \(b.elementType.rawValue) '\(b.label)' id '\(b.identifier)' \(b.frame) hittable \(b.isHittable)") }
        let system = backs.filter { $0.identifier == "BackButton" }
        XCTAssertTrue(system.isEmpty, "\(page): the system's own Back is there too: \(system.map { "\($0.frame)" })")
        let others = backs.filter { !barFrame.insetBy(dx: -1, dy: -1).contains($0.frame) }
        XCTAssertTrue(others.isEmpty, "\(page): another Back outside the bar's: \(others.map { "'\($0.identifier)' \($0.frame)" })")
    }

    func testASettingsPageHasOneBackAfterAWalk() throws {
        try launch(tab: "settings")
        if app.windows.firstMatch.frame.width > 700 { throw XCTSkip("the bar is the narrow window's (the wide one's test covers it)") }
        openAPIKeys()
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 10), "no Back on API Keys")
        pause(2)
        walkTheTree()
        shot("pushed-back-env")
        checkOneBack("page.back", "API Keys")
    }

    /// The pages with a search field always shown (Config, API Keys, Skills, Sessions): SwiftUI put the page's own Back
    /// back when something walked the tree, under the bar's, for VoiceOver to find (#481). The pages without one never
    /// had it.
    func testPagesWithASearchFieldHaveOneBackAfterAWalk() throws {
        for id in ["config", "env", "skills", "sessions"] {
            try launch(tab: "settings")
            if app.windows.firstMatch.frame.width > 700 { throw XCTSkip("the bar is the narrow window's") }
            XCTAssertTrue(any("settings.row.profile").waitForExistence(timeout: 30), "no Settings rows")
            let row = any("settings.row.\(id)")
            let limit = app.windows.firstMatch.frame.maxY - 150
            for _ in 0..<14 where !(row.exists && row.isHittable && row.frame.maxY < limit) { app.swipeUp(velocity: .slow); pause(0.8) }
            guard row.exists && row.isHittable else { XCTFail("no \(id) row"); continue }
            row.tap()
            guard any("page.back").waitForExistence(timeout: 10) else { XCTFail("\(id): no Back"); continue }
            pause(2)
            walkTheTree()
            shot("pushed-back-search-\(id)")
            checkOneBack("page.back", id)
        }
    }

    func testAChatHasOneBackAfterAWalk() throws {
        try launch(tab: "chats")
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup' AND identifier != 'chat.titlePill'")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 30), "no chat row")
        chat.tap()
        XCTAssertTrue(any("chat.back").waitForExistence(timeout: 10), "no Back on the chat")
        pause(3)
        walkTheTree()
        shot("pushed-back-chat")
        checkOneBack("chat.back", "a chat")
    }

    /// The edge swipe still goes back where the page under has the bar's hidden back item (a back item's visibility has
    /// been tied to the interactive pop before): Settings › API Keys and a chat, a swipe let go past the middle goes back,
    /// one let go early leaves the page where it was. The narrow window's: the bar's Back is there.
    func testAnEdgeSwipeStillGoesBack() throws {
        try launch(tab: "settings")
        if app.windows.firstMatch.frame.width > 700 { throw XCTSkip("the bar is the narrow window's") }
        func swipe(to dx: CGFloat) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
            pause(1.5)
        }
        openAPIKeys()
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 10), "no Back on API Keys")
        pause(1.5)
        swipe(to: 0.2)
        XCTAssertTrue(any("page.back").exists, "API Keys: a swipe let go early went back")
        swipe(to: 0.8)
        XCTAssertFalse(any("page.back").exists, "API Keys: the swipe did not go back")
        XCTAssertTrue(any("settings.row.profile").waitForExistence(timeout: 5), "API Keys: not back on Settings")
        shot("pushed-back-swipe-env")

        try launch(tab: "chats")
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup' AND identifier != 'chat.titlePill'")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 30), "no chat row")
        chat.tap()
        XCTAssertTrue(any("chat.back").waitForExistence(timeout: 10), "no Back on the chat")
        pause(2)
        swipe(to: 0.2)
        XCTAssertTrue(any("chat.back").exists, "a chat: a swipe let go early went back")
        swipe(to: 0.8)
        XCTAssertFalse(any("chat.back").exists, "a chat: the swipe did not go back")
        XCTAssertTrue(chat.waitForExistence(timeout: 5), "a chat: not back on the list")
        shot("pushed-back-swipe-chat")
    }

    /// The pages with a search field always shown hide their Back SwiftUI's way (#481), which in a navigation stack can
    /// switch off the swipe back: each still goes back on a swipe let go past the middle, and stays on one let go early.
    func testTheSearchPagesStillSwipeBack() throws {
        for id in ["config", "env", "skills", "sessions"] {
            try launch(tab: "settings")
            if app.windows.firstMatch.frame.width > 700 { throw XCTSkip("the bar is the narrow window's") }
            XCTAssertTrue(any("settings.row.profile").waitForExistence(timeout: 30), "no Settings rows")
            let row = any("settings.row.\(id)")
            let limit = app.windows.firstMatch.frame.maxY - 150
            for _ in 0..<14 where !(row.exists && row.isHittable && row.frame.maxY < limit) { app.swipeUp(velocity: .slow); pause(0.8) }
            guard row.exists && row.isHittable else { XCTFail("no \(id) row"); continue }
            row.tap()
            guard any("page.back").waitForExistence(timeout: 10) else { XCTFail("\(id): no Back"); continue }
            pause(1.5)
            for (dx, back) in [(0.2, false), (0.8, true)] {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
                pause(1.5)
                XCTAssertEqual(!any("page.back").exists, back, "\(id): a swipe let go at \(Int(dx * 100))% \(back ? "did not go back" : "went back")")
            }
        }
    }

    /// Where the bar gives the system's Back back: on a wide window (the iPad's two columns) a pushed page has exactly
    /// one Back, the system's, and none of the bar's.
    func testAWideWindowsPageHasTheSystemsBackOnly() throws {
        try launch(tab: "settings")
        guard app.windows.firstMatch.frame.width > 700 else { throw XCTSkip("a wide window's") }
        openAPIKeys(); pause(2)
        walkTheTree()
        shot("pushed-back-wide-env")
        let system = app.descendants(matching: .any).matching(identifier: "BackButton").allElementsBoundByIndex.filter { $0.exists }
        for b in system { print("PAGE-BACK wide '\(b.label)' id '\(b.identifier)' \(b.frame) hittable \(b.isHittable)") }
        XCTAssertEqual(system.count, 1, "a wide window's page has \(system.count) system Backs")
        XCTAssertTrue(system.first?.isHittable == true, "the system's Back can't be reached")
        XCTAssertFalse(any("page.back").exists, "the bar's Back is on a wide window's page")
    }

    /// Where the bar steps aside: Settings › Gateways has the bar's Back alone; Edit Gateway, which keeps its own bar,
    /// shows no Back of the bar's and no second one of the system's; back on Gateways, the bar's Back alone again.
    func testAPageWithItsOwnBarAndBackAgain() throws {
        try launch(tab: "settings")
        if app.windows.firstMatch.frame.width > 700 { throw XCTSkip("the bar is the narrow window's") }
        let gateway = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Workshop'")).firstMatch
        XCTAssertTrue(gateway.waitForExistence(timeout: 20), "no gateway row on Settings")
        pause(1.5); gateway.tap(); pause(1.5)
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "Gateways has no bar Back")
        walkTheTree()
        checkOneBack("page.back", "Gateways")
        // The row's edit link, by its name (on the closed Duo the window's trailing edge is the side strip's).
        let edit = app.buttons["Edit Workshop"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "no edit link on Gateways")
        edit.tap()
        XCTAssertTrue(app.navigationBars.buttons["Cancel"].firstMatch.waitForExistence(timeout: 5), "Edit Gateway didn't open with its own bar")
        pause(1.5)
        walkTheTree()
        shot("pushed-back-ownbar")
        let backs = app.descendants(matching: .any).allElementsBoundByIndex.filter { $0.exists && ($0.label == "Back" || $0.identifier == "BackButton") }
        for b in backs { print("PAGE-BACK own bar '\(b.label)' id '\(b.identifier)' \(b.frame) hittable \(b.isHittable)") }
        XCTAssertFalse(any("page.back").exists, "the bar's Back is over a page with its own bar")
        XCTAssertLessThanOrEqual(backs.count, 1, "Edit Gateway has \(backs.count) Backs")
        app.navigationBars.buttons["Cancel"].firstMatch.tap(); pause(1.5)
        XCTAssertTrue(any("page.back").waitForExistence(timeout: 5), "the bar's Back did not come back on Gateways")
        walkTheTree()
        shot("pushed-back-gateways-again")
        checkOneBack("page.back", "Gateways again")
    }
}

