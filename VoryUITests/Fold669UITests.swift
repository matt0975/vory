import XCTest

/// #669: on a half-open iPhone Duo (the laptop pose, the fold across the window), a dock taller than the room under the
/// fold stays where it rests with the keyboard down: not lifted over the top bar and into the status band. The dock is made
/// tall at an accessibility size (HERMES_E2E_TEXT_SIZE, for the app alone) with the mock's approval card in it and the
/// re-attach banner over the card (the mock's ready-held fault, #641). The fold is read off the app's own readout
/// (`-vory-geometry-probe`), so the test runs in whatever pose Device Hub has the simulator in, and skips with no active
/// fold across the window.
///
/// Printed (F669): the fold, the window, the dock's frame at rest with the composer alone, with the card, and with the
/// banner over it, the top bar's bottom, and every button in the dock with its gap from the fold. Asserted with the banner
/// up: the dock's bottom where the composer's dock rested (within 1 pt: not lifted), its top below the top bar's bottom,
/// and the card's choices clear of the fold. What else of the dock crosses the fold is printed and pictured, not judged:
/// a dock taller than either half is its own item. A failure that starts "CASE NOT MADE" means the screen wasn't the case
/// (the dock not taller than the room under the fold, the keyboard up, or the card gone), not that the dock moved.
///
/// The audit gate's three types with the banner up, judged as #641's row was: an issue whose element is in the dock, and
/// an issue with no element beyond the count the same audit found with the card alone (the transcript's text under the
/// glass top bar is legible pixels with no element). "F669 HOLD <name>" lines mark the stills the runner takes from
/// outside: XCUITest's own screenshot is of the closed display, black while the Duo is open.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock); HERMES_E2E_BUNDLE picks the copy;
/// HERMES_E2E_APPEARANCE is light (the default) or dark. HERMES_E2E_FOLD ("x,y,w,h", the fold as the readout gave it in
/// an earlier run in the same pose) runs it without the readout, for stills with nothing over the screen: the app is
/// launched without `-vory-geometry-probe`, that fold is used, and the HOLD names start "clean-". The checks are the same.
@MainActor
final class Fold669UITests: XCTestCase {
    private var app: XCUIApplication!
    private var base = ""

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func log(_ s: String) { print(String(format: "F669 %.1f %@", Date().timeIntervalSince1970, s)) }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    /// Marks a still for the runner and holds the screen long enough for it.
    private func hold(_ name: String) {
        print("F669 HOLD \(name)")
        pause(2.5)
    }

    /// The mock's fault switch (`/mock/fault?mode=…`), as ReconnectFaultUITests' own.
    private func fault(_ mode: String, count: Int? = nil) {
        var s = base + "/mock/fault?mode=" + mode
        if let count { s += "&count=\(count)" }
        guard let u = URL(string: s) else { return }
        let done = expectation(description: "fault \(mode)")
        URLSession.shared.dataTask(with: u) { data, _, _ in
            print("MOCK-FAULT \(data.map { String(decoding: $0, as: UTF8.self) } ?? "no answer")")
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        log("fault \(mode)")
    }

    /// The gap between a frame and the fold across the window: negative where they overlap.
    private func gap(_ f: CGRect, _ fold: CGRect) -> CGFloat { max(fold.minY - f.maxY, f.minY - fold.maxY) }

    /// Every button in the dock's frame, printed with its gap from the fold.
    private func printDockButtons(_ dock: CGRect, fold: CGRect, state: String) {
        for b in app.buttons.allElementsBoundByIndex where b.exists {
            let f = b.frame
            guard f.width > 0, f.height > 0, dock.intersects(f) else { continue }
            print("F669 \(state) button id '\(b.identifier)' label '\(b.label)' frame \(f) gap \(Int(gap(f, fold)))\(f.intersects(fold) ? " ON THE FOLD" : "")")
        }
    }

    /// The gate's three types; each issue printed. With `base`, what's flagged: an issue whose element is in `area`, and
    /// an issue with no element beyond `base`'s count of it. Without, the counts of the issues with no element.
    private func audit(_ tag: String, area: CGRect, base: [String: Int]?) throws -> (flagged: [String], counts: [String: Int]) {
        var flagged: [String] = []
        var counts: [String: Int] = [:]
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            guard let el = issue.element else {
                let key = "\(issue.auditType.rawValue) \(issue.compactDescription)"
                counts[key, default: 0] += 1
                let beyond = base.map { counts[key, default: 0] > $0[key, default: 0] } ?? false
                print("F669-AUDIT \(tag) '\(issue.compactDescription)' no element\(base == nil || !beyond ? "" : " (beyond the card's)")")
                if beyond { flagged.append("'\(issue.compactDescription)' no element") }
                return true
            }
            let entry = "'\(issue.compactDescription)' type \(el.elementType.rawValue) id '\(el.identifier)' label '\(el.label)' frame \(el.frame)"
            print("F669-AUDIT \(tag) \(entry)")
            if base != nil, area.intersects(el.frame) { flagged.append(entry) }
            return true
        }
        return (flagged, counts)
    }

    func testATallDockAtRestStaysWhereItRestsOnTheHalfOpenDuo() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        continueAfterFailure = true
        base = url
        fault("none")
        let look = e["HERMES_E2E_APPEARANCE"] == "dark" ? "dark" : "light"
        // A fold given: no readout over the screen, and the stills named "clean-".
        var given: CGRect?
        if let s = e["HERMES_E2E_FOLD"], !s.isEmpty {
            let v = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count == 4 else { throw XCTSkip("HERMES_E2E_FOLD isn't x,y,w,h: '\(s)'") }
            given = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        let tag = given == nil ? look : "clean-\(look)"
        var args = ["-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", look]
        if given == nil { args.append("-vory-geometry-probe") }
        let size = e["HERMES_E2E_TEXT_SIZE"].flatMap { $0.isEmpty ? nil : $0 } ?? "UICTContentSizeCategoryAccessibilityXXXL"
        args += ["-UIPreferredContentSizeCategoryName", size]
        if let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()

        // The fold, from the readout, or as given.
        let fold: CGRect
        if let given {
            fold = given
            log("fold \(fold) as given (HERMES_E2E_FOLD, no readout), \(look), \(size)")
        } else {
            let readout = app.staticTexts["geometry.regions"].firstMatch
            XCTAssertTrue(readout.waitForExistence(timeout: 20), "no regions readout (a Debug build with -vory-geometry-probe)")
            pause(1)
            log("readout \(readout.label.replacingOccurrences(of: "\n", with: " | "))")
            let window = app.staticTexts["geometry.window"].firstMatch
            if window.exists { log("window \(window.label.replacingOccurrences(of: "\n", with: " | "))") }
            guard let found = FoldPoseUITests.activeFolds(in: readout.label).first(where: { $0.width > $0.height }) else {
                throw XCTSkip("no active fold across the window: put the Duo half open, upright (the laptop pose), in Device Hub first")
            }
            fold = found
            log("fold \(fold), \(look), \(size)")
        }

        // A chat, with any approval left waiting by an earlier run denied, and the keyboard down.
        XCTAssertTrue(any("chats.new").waitForExistence(timeout: 40), "the app did not come up")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup' AND identifier != 'chat.titlePill'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no Disk cleanup row")
        row.tap()
        let composer = app.textViews["composer.text"].firstMatch
        if !composer.waitForExistence(timeout: 8) {
            let deny = app.buttons["Deny"].firstMatch
            if deny.waitForExistence(timeout: 15) { deny.tap(); log("denied a waiting approval first") }
        }
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "no composer")
        pause(1.5)
        let dock = any("chat.dock")
        XCTAssertTrue(dock.exists, "no chat.dock")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "CASE NOT MADE: the keyboard is up as the chat opens")
        let rest = dock.frame
        log("rest: the dock with the composer alone \(rest), its gap from the fold \(Int(gap(rest, fold)))")

        // The card: a turn that ends in the mock's approval.
        composer.tap()
        composer.typeText("A tall dock at rest")
        let send = app.buttons.matching(identifier: "composer.send").firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no send button")
        send.tap()
        let once = app.buttons["Allow once"].firstMatch
        XCTAssertTrue(once.waitForExistence(timeout: 60), "no approval came")
        // The composer leaves the dock with the card, and the keyboard with it.
        let kbEnd = Date().addingTimeInterval(4)
        while app.keyboards.firstMatch.exists, Date() < kbEnd { pause(0.3) }
        XCTAssertFalse(app.keyboards.firstMatch.exists, "CASE NOT MADE: the keyboard stayed up with the card")
        pause(1.5)
        let withCard = dock.frame
        log("card: the dock \(withCard), its gap from the fold \(Int(gap(withCard, fold)))")
        hold("\(tag)-card")
        let cardAudit = try audit("card", area: withCard, base: nil)

        // The banner over the card: the gateway not ready for 150 s, the banner from a minute.
        fault("ready-held", count: 150)
        let tryAgain = any("chat.reattach.tryAgain")
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 80), "no Try again by 80 s")
        pause(1.5)
        let tall = dock.frame
        let roomUnder = rest.maxY - fold.maxY
        let topBar = ["chat.back", "chat.titlePill", "chat.more"].map(any).filter { $0.exists && $0.frame.height > 0 }.map { $0.frame.maxY }.max() ?? 0
        log("tall: the dock \(tall), height \(Int(tall.height)), the room under the fold \(Int(roomUnder)), its bottom \(tall.maxY) against the rest's \(rest.maxY), its top \(tall.minY) against the top bar's bottom \(topBar)")
        printDockButtons(tall, fold: fold, state: "tall")
        hold("\(tag)-tall")

        XCTAssertTrue(once.exists, "CASE NOT MADE: the card was gone with the banner up")
        XCTAssertGreaterThan(tall.height, roomUnder, "CASE NOT MADE: the dock (\(Int(tall.height)) pt) fits under the fold (\(Int(roomUnder)) pt)")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "CASE NOT MADE: the keyboard is up with the banner")
        XCTAssertEqual(tall.maxY, rest.maxY, accuracy: 1, "the tall dock was lifted: its bottom \(tall.maxY), resting at \(rest.maxY)")
        XCTAssertGreaterThanOrEqual(tall.minY, topBar, "the tall dock's top \(tall.minY) is over the top bar (its bottom \(topBar))")
        for label in ["Allow once", "Allow for this chat", "Always allow…", "Deny"] {
            let b = app.buttons[label].firstMatch
            guard b.exists, b.frame.height > 0 else { continue }
            XCTAssertFalse(b.frame.intersects(fold), "the card's '\(label)' \(b.frame) stands on the fold \(fold)")
        }
        let bannerAudit = try audit("tall", area: tall, base: cardAudit.counts)
        XCTAssertTrue(bannerAudit.flagged.isEmpty, "the audit flags the tall dock: \(bannerAudit.flagged)")

        // Leave the mock as found: the fault off, the approval denied.
        fault("none")
        let deny = app.buttons["Deny"].firstMatch
        if deny.waitForExistence(timeout: 60) { deny.tap(); log("denied the approval at the end") }
        pause(2)
    }
}
