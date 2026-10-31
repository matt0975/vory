import XCTest

/// #550's iPhone gates, on a plain iPhone simulator (a Duo's audit reads its closed cover), on the demo copy and the mock,
/// in the scheme and text size the script names (HERMES_E2E_SCHEME; HERMES_E2E_SIZE, a content size category: run at
/// the default and at the largest accessibility size). Each page is read a screen at a time, top to bottom.
/// - The mock's `math` reply: each screen's audit (contrast, element descriptions, hit regions, element detection); a
///   finding on a math card (a web view) or its Copy button FAILS, the rest are noted. Each display card measured past
///   its 48 pt default (the size it has until its page is measured). What VoiceOver gets in each card: its web
///   content's labels, some text and no raw TeX. VoiceOver's order through the reply (`-vory-ax-oracle`): the inline
///   maths as Unicode, and after each card the reply's next text, with nothing between but the card's own stops.
/// - Settings › About › Acknowledgements: each screen's audit, a finding on the page's header, a link or a paragraph
///   FAILS; VoiceOver's order: the header, then KaTeX's link and its 5 paragraphs, then the fonts' link and their 23.
/// Notes are XCTContext activities. Skipped unless HERMES_E2E_URL and HERMES_E2E_TOKEN are set.
@MainActor
final class MathAuditUITests: XCTestCase {
    private var app: XCUIApplication!
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    nonisolated private static func note(_ line: String) { XCTContext.runActivity(named: line) { _ in } }
    private static let tex = try! NSRegularExpression(pattern: #"\\[A-Za-z]+"#)
    private static func hasTeX(_ s: String) -> Bool { tex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    private func launch(tab: String) throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        var args = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", tab,
                    "-restore.openChat", "none", "-colorSchemePreference", e["HERMES_E2E_SCHEME"] ?? "light", "-vory-ax-oracle"]
        if let size = e["HERMES_E2E_SIZE"], !size.isEmpty { args += ["-UIPreferredContentSizeCategoryName", size] }
        app.launchArguments = args
        app.launch()
        Self.note("launched: \(tab), scheme \(e["HERMES_E2E_SCHEME"] ?? "light"), size \(e["HERMES_E2E_SIZE"] ?? "default")")
    }

    /// What VoiceOver stops on now, in order (the oracle's walk): label and frame.
    private func voiceOverStops() -> [(label: String, frame: CGRect)] {
        let oracle = app.descendants(matching: .any).matching(identifier: "debug.voiceover").firstMatch
        guard oracle.waitForExistence(timeout: 5) else { return [] }
        return ((oracle.value as? String) ?? "").split(separator: "\n").compactMap { line in
            guard let bar = line.lastIndex(of: "|") else { return nil }
            let n = line[line.index(after: bar)...].split(separator: ",").compactMap { Double($0) }
            guard n.count == 4 else { return nil }
            return (String(line[..<bar]), CGRect(x: n[0], y: n[1], width: n[2], height: n[3]))
        }
    }

    /// The page's stops across screens, each kept once, in the order first seen, with its frame in the page's own
    /// coordinates (the screen frame moved by how far the page has scrolled since the first screen) and the stretch of
    /// screens it belongs to: a new stretch starts after a screen that shared no stop with the one before, where the
    /// scroll between them can't be told.
    private var order: [(label: String, frame: CGRect, stretch: Int)] = []
    private var lastScreen: [String: CGFloat] = [:]
    private var offset: CGFloat = 0
    private var stretch = 0
    private var screens = 0
    private func collectStops() {
        let now = voiceOverStops().filter { !$0.label.isEmpty }
        screens += 1
        let once = Dictionary(grouping: now, by: { $0.label }).filter { $0.value.count == 1 }
        if screens > 1 {
            // Each stop seen once on this screen and once on the last says how far the page moved between them; the
            // bar's and the tabs' stops don't move at all, so a delta of 0 is left out and the rest's median is taken.
            let deltas = once.compactMap { label, s in lastScreen[label].map { $0 - s[0].frame.minY } }
            if deltas.isEmpty {
                stretch += 1
                Self.note("offset unknown after screen \(screens - 1): no stop seen once on both screens")
            } else {
                let moved = deltas.filter { abs($0) > 0.5 }.sorted()
                let d = moved.isEmpty ? 0 : moved[moved.count / 2]
                offset += d
                Self.note("offset +\(Int(d)) from \(moved.count) anchors after screen \(screens - 1)")
            }
        }
        lastScreen = once.mapValues { $0[0].frame.minY }
        for s in now where !order.contains(where: { $0.label == s.label }) {
            order.append((s.label, s.frame.offsetBy(dx: 0, dy: offset), stretch))
        }
    }

    /// This screen's audit: a finding `own` says is #550's FAILS (returned), the rest are noted.
    private func audit(_ screen: Int, own: @escaping (XCUIElement?) -> Bool) throws -> [String] {
        var fails: [String] = []
        try app.performAccessibilityAudit(for: [.contrast, .sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            let mine = own(issue.element)
            let line = "AUDIT screen \(screen) \(mine ? "FAIL" : "noted") \(issue.auditType) '\(issue.element?.identifier ?? "")' '\(issue.element?.label ?? "")' \(issue.element.map { "\($0.frame)" } ?? "-") \(issue.compactDescription)"
            Self.note(line)
            if mine { fails.append(line) }
            return true
        }
        return fails
    }

    private func keyboardDown() {
        guard app.keyboards.count > 0 else { return }
        let win = app.windows.firstMatch.frame
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 10, dy: win.height * 0.4)).tap()
        pause(0.6)
        if app.keyboards.count > 0 { app.windows.firstMatch.swipeDown(velocity: .slow); pause(0.6) }
        Self.note("keyboard \(app.keyboards.count > 0 ? "STILL UP" : "down")")
    }

    func testTheMathReplyPassesTheAudit() throws {
        try launch(tab: "chats")
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40), "no New Chat")
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "no composer")
        composer.tap()
        composer.typeText("math")
        app.buttons["composer.send"].firstMatch.tap()
        let last = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "That is the whole derivation")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 60), "the reply never finished")
        keyboardDown()
        // To the reply's top, then down a screen at a time to its last line.
        let heading = app.staticTexts.matching(NSPredicate(format: "label == %@", "Sizing the log volume")).firstMatch
        for _ in 0..<10 where !(heading.exists && heading.isHittable) { app.windows.firstMatch.swipeDown(velocity: .slow); pause(0.5) }
        XCTAssertTrue(heading.isHittable, "the reply's heading never came into sight")
        let win = app.windows.firstMatch.frame
        var cards: [String: CGRect] = [:]
        var fails: [String] = []
        for screen in 1...12 {
            pause(1)
            collectStops()
            let views = app.webViews.allElementsBoundByIndex.filter { $0.exists && $0.frame.intersects(win) }
            for v in views {
                let words = v.descendants(matching: .any).allElementsBoundByIndex.map { $0.label }.filter { !$0.isEmpty }.joined(separator: " ")
                let key = words.isEmpty ? "card at \(Int(v.frame.minY))" : words
                if cards[key] == nil { cards[key] = v.frame; Self.note("CARD \(v.frame): what VoiceOver gets: '\(words.prefix(200))'") }
            }
            let cardFrames = views.map { $0.frame }
            fails += try audit(screen) { el in
                guard let el else { return false }
                if el.elementType == .webView { return true }
                // A card's own stops, and its Copy button (level with it, to its right).
                return cardFrames.contains { $0.insetBy(dx: -60, dy: 0).contains(CGPoint(x: el.frame.midX, y: el.frame.midY)) }
            }
            if last.exists && last.isHittable && last.frame.maxY <= win.maxY { break }
            app.windows.firstMatch.swipeUp(velocity: .slow)
        }
        // The cards.
        XCTAssertEqual(cards.count, 3, "\(cards.count) cards, not 3")
        for (words, frame) in cards {
            XCTAssertGreaterThan(frame.height, 48.5, "a card is \(frame.height) pt tall: its measurement didn't run")
            XCTAssertFalse(words.hasPrefix("card at"), "FINDING (what VoiceOver gets): a card has no text for VoiceOver")
            XCTAssertFalse(Self.hasTeX(words), "FINDING (what VoiceOver gets): a card exposes raw TeX: '\(words.prefix(80))'")
        }
        // VoiceOver's order through the reply.
        let labels = order.map { $0.label }
        Self.note("ORDER \(labels.count) stops: \(labels.map { String($0.prefix(40)) }.joined(separator: " / "))")
        func at(_ text: String) -> Int? { labels.firstIndex { $0.contains(text) } }
        XCTAssertNotNil(at("α + β = γ"), "the inline Greek isn't spoken as Unicode")
        XCTAssertNotNil(at("$5 more a month"), "the price isn't there as text")
        for t in labels where Self.hasTeX(t) { XCTFail("raw TeX in a stop: '\(t.prefix(80))'") }
        for (before, after) in [("The total over a month is", "and the share each host takes is"),
                                ("and the share each host takes is", "The two rules side by side"),
                                ("The two rules side by side", "Host")] {
            guard let b = at(before), let a = at(after) else { XCTFail("no stop for '\(before)' or '\(after)'"); continue }
            XCTAssertLessThan(b, a, "'\(after)' comes before '\(before)'")
            // Nothing between them but the card's own stops (its maths and its Copy button), all in the band between,
            // in the page's own coordinates; not checked across a stretch where the scroll couldn't be told.
            guard b < a, Set(order[b...a].map { $0.stretch }).count == 1 else {
                Self.note("band between '\(before)' and '\(after)' not checked: they span an unknown scroll")
                continue
            }
            let band = CGRect(x: 0, y: order[b].frame.maxY - 1, width: win.width, height: max(0, order[a].frame.minY - order[b].frame.maxY + 2))
            for s in order[(b + 1)..<max(b + 1, a)] where !band.intersects(s.frame) {
                XCTFail("FINDING (what VoiceOver gets): between '\(before)' and '\(after)' comes '\(s.label.prefix(60))' \(s.frame)")
            }
        }
        for f in fails { XCTFail(f) }
    }

    /// The first and last paragraph of each entry, as the page shows them (each paragraph's lines joined).
    nonisolated private static let entries: [(link: String, count: Int, first: String, last: String)] = [
        ("KaTeX 0.16.11, MIT License", 5, "The MIT License (MIT)", "THE SOFTWARE IS PROVIDED \"AS IS\""),
        ("KaTeX fonts 0.16.11, SIL Open Font License 1.1", 23, "Copyright (c) 2009-2010, Design Science, Inc.", "THE FONT SOFTWARE IS PROVIDED \"AS IS\""),
    ]

    func testTheAcknowledgementsPassTheAudit() throws {
        try launch(tab: "settings")
        let about = app.buttons.matching(identifier: "settings.row.about").firstMatch
        for _ in 0..<8 where !(about.exists && about.isHittable) { app.swipeUp(velocity: .slow); pause(0.4) }
        XCTAssertTrue(about.isHittable, "no About row")
        about.tap()
        let row = app.descendants(matching: .any).matching(identifier: "about.acknowledgements").firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow); pause(0.4) }
        XCTAssertTrue(row.isHittable, "no Acknowledgements row on About")
        row.tap()
        let header = app.staticTexts.matching(NSPredicate(format: "label == %@", "Acknowledgements")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "the Acknowledgements page didn't open")
        let end = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", Self.entries[1].last)).firstMatch
        let win = app.windows.firstMatch.frame
        var fails: [String] = []
        let ours = { (label: String) -> Bool in
            label == "Acknowledgements" || Self.entries.contains { label == $0.link } || label.count > 20
        }
        for screen in 1...30 {
            pause(0.8)
            collectStops()
            fails += try audit(screen) { el in ours(el?.label ?? "") }
            if end.exists && end.isHittable && end.frame.maxY <= win.maxY { break }
            app.swipeUp(velocity: .slow)
        }
        let labels = order.map { $0.label }
        Self.note("ORDER \(labels.count) stops: \(labels.map { String($0.prefix(30)) }.joined(separator: " / "))")
        guard let h = labels.firstIndex(of: "Acknowledgements") else { return XCTFail("no 'Acknowledgements' header among the stops") }
        var i = h + 1
        for e in Self.entries {
            guard let l = labels[i...].firstIndex(of: e.link) else { XCTFail("no link '\(e.link)' after the header"); return }
            let paragraphs = Array(labels[(l + 1)...].prefix(e.count))
            XCTAssertEqual(paragraphs.count, e.count, "\(e.link): \(paragraphs.count) paragraphs, not \(e.count)")
            XCTAssertTrue(paragraphs.first?.hasPrefix(e.first) ?? false, "\(e.link): the first paragraph is '\(paragraphs.first?.prefix(40) ?? "")'")
            XCTAssertTrue(paragraphs.last?.hasPrefix(e.last) ?? false, "\(e.link): the last paragraph is '\(paragraphs.last?.prefix(40) ?? "")'")
            i = l + 1 + paragraphs.count
            guard i < labels.count || e.link == Self.entries.last?.link else { XCTFail("the stops end inside '\(e.link)'"); return }
        }
        for f in fails { XCTFail(f) }
    }
}
