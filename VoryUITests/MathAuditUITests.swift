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
    private func collectStops(in region: CGRect) {
        // Only the page's own stops, those reaching in between the bars: the tab bar's and the top bar's are on every
        // screen, and first seen on the first one they would stand between the page's stops. Overlapping, not wholly
        // inside: at the largest size one paragraph can be taller than the space between the bars.
        let now = voiceOverStops().filter { !$0.label.isEmpty && $0.frame.maxY > region.minY && $0.frame.minY < region.maxY }
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

    /// One audit finding as read on its screen.
    private struct Finding {
        var screen: Int, type: String, id: String, label: String, frame: CGRect, kind: XCUIElement.ElementType, text: String
    }

    /// This screen's audit, every finding kept for the test to judge.
    private func audit(_ screen: Int) throws -> [Finding] {
        var out: [Finding] = []
        try app.performAccessibilityAudit(for: [.contrast, .sufficientElementDescription, .hitRegion, .elementDetection]) { issue in
            let el = issue.element
            out.append(Finding(screen: screen, type: "\(issue.auditType)", id: el?.identifier ?? "", label: el?.label ?? "",
                               frame: el?.frame ?? .zero, kind: el?.elementType ?? .any, text: issue.compactDescription))
            return true
        }
        return out
    }

    /// What is in sight between the top bar's bottom and the bottom chrome's top (the elements named), on this screen;
    /// the window's edge where none of them is found. Noted with the elements that set it, so a bar not found shows.
    private func region(_ screen: Int, top: [String], bottom: [String]) -> CGRect {
        let win = app.windows.firstMatch.frame
        let find = { (id: String) -> XCUIElement in
            let byId = self.app.descendants(matching: .any).matching(identifier: id).firstMatch
            return byId.exists ? byId : self.app.buttons[id].firstMatch
        }
        let tops = top.map { ($0, find($0)) }.filter { $0.1.exists }.map { ($0.0, $0.1.frame.maxY) }
        let bottoms = bottom.map { ($0, find($0)) }.filter { $0.1.exists }.map { ($0.0, $0.1.frame.minY) }
        let t = tops.max { $0.1 < $1.1 } ?? ("window", win.minY)
        let b = bottoms.min { $0.1 < $1.1 } ?? ("window", win.maxY)
        Self.note("REGION screen \(screen) top \(Int(t.1)) (\(t.0)) bottom \(Int(b.1)) (\(b.0))")
        return CGRect(x: win.minX, y: t.1, width: win.width, height: max(0, b.1 - t.1))
    }

    /// Judges the findings. One wholly in sight that `ours` claims FAILS, except a contrast that only "nearly passed"
    /// (the stock secondary label colour), which is noted; the rest are noted, "under the bars" when not wholly in sight.
    private func judge(_ findings: [Finding], regions: [Int: CGRect], ours: (Finding) -> Bool) -> [String] {
        var fails: [String] = []
        for f in findings {
            let line = "\(f.type) '\(f.id)' '\(f.label.prefix(80))' \(f.frame) \(f.text)"
            guard let r = regions[f.screen], r.contains(f.frame) else { Self.note("AUDIT screen \(f.screen) noted (under the bars) \(line)"); continue }
            guard ours(f) else { Self.note("AUDIT screen \(f.screen) noted \(line)"); continue }
            if f.text.lowercased().contains("nearly passed") { Self.note("AUDIT screen \(f.screen) noted (nearly passed, ours) \(line)"); continue }
            Self.note("AUDIT screen \(f.screen) FAIL \(line)")
            fails.append("AUDIT screen \(f.screen) FAIL \(line)")
        }
        return fails
    }

    /// A still of the screen, kept with the run's results.
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
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
        // At the largest size a tap on Send once sent nothing (the mock saw no turn). What the box holds, and Send's state
        // and a still before the tap, and the user's own bubble after it, tell the test's fault from the app's.
        let held = (composer.value as? String) ?? ""
        Self.note("the box holds '\(held)'")
        guard held.contains("math") else { shot("box-not-math"); return XCTFail("the box doesn't hold 'math' ('\(held)')") }
        let send = app.buttons["composer.send"].firstMatch
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send)], timeout: 10)
        let state = "Send enabled \(send.isEnabled), hittable \(send.isHittable), frame \(send.frame)"
        Self.note("before the tap: \(state)")
        shot("before-send")
        send.tap()
        // The user's own bubble, a text equal to the word in the thread: a box that empties (queued, cleared) proves nothing.
        let bubble = app.staticTexts.matching(NSPredicate(format: "label == %@", "math")).firstMatch
        guard bubble.waitForExistence(timeout: 10) else {
            shot("send-nothing")
            return XCTFail("FINDING (send at this size): one tap on Send sent nothing; box '\(composer.value as? String ?? "")', \(state)")
        }
        let last = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "That is the whole derivation")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 90), "the reply never finished")
        keyboardDown()
        // To the reply's top, then down a screen at a time to its last line.
        let heading = app.staticTexts.matching(NSPredicate(format: "label == %@", "Sizing the log volume")).firstMatch
        for _ in 0..<10 where !(heading.exists && heading.isHittable) { app.windows.firstMatch.swipeDown(velocity: .slow); pause(0.5) }
        XCTAssertTrue(heading.isHittable, "the reply's heading never came into sight")
        let win = app.windows.firstMatch.frame
        var cards: [String: CGRect] = [:]
        var findings: [Finding] = [], regions: [Int: CGRect] = [:], cardsOn: [Int: [CGRect]] = [:]
        for screen in 1...12 {
            pause(1)
            regions[screen] = region(screen, top: ["chat.back", "chat.titlePill"], bottom: ["chat.dock"])
            collectStops(in: regions[screen]!)
            let views = app.webViews.allElementsBoundByIndex.filter { $0.exists && $0.frame.intersects(win) }
            for v in views {
                let words = v.descendants(matching: .any).allElementsBoundByIndex.map { $0.label }.filter { !$0.isEmpty }.joined(separator: " ")
                let key = words.isEmpty ? "card at \(Int(v.frame.minY))" : words
                if cards[key] == nil { cards[key] = v.frame; Self.note("CARD \(v.frame): what VoiceOver gets: '\(words.prefix(200))'") }
            }
            cardsOn[screen] = views.map { $0.frame }
            findings += try audit(screen)
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
        // The audit: ours is a card (its web view, or anything wholly inside it) or a card's Copy button (level with it,
        // to its right).
        let fails = judge(findings, regions: regions) { f in
            let on = cardsOn[f.screen] ?? []
            if f.kind == .webView || on.contains(where: { $0.contains(f.frame) }) { return true }
            let copy = (f.label + " " + f.id).lowercased().contains("copy")
            return copy && on.contains { f.frame.minY >= $0.minY - 4 && f.frame.maxY <= $0.maxY + 4 && f.frame.minX >= $0.maxX - 2 }
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
        // Up to 24 swipes: at the largest accessibility size the rows are many screens long.
        var swipes = 0
        while !(about.exists && about.isHittable), swipes < 24 { app.swipeUp(velocity: .slow); pause(0.4); swipes += 1 }
        Self.note("the About row after \(swipes) swipes")
        XCTAssertTrue(about.isHittable, "no About row")
        about.tap()
        let row = app.descendants(matching: .any).matching(identifier: "about.acknowledgements").firstMatch
        swipes = 0
        while !(row.exists && row.isHittable), swipes < 24 { app.swipeUp(velocity: .slow); pause(0.4); swipes += 1 }
        Self.note("the Acknowledgements row after \(swipes) swipes")
        XCTAssertTrue(row.isHittable, "no Acknowledgements row on About")
        row.tap()
        let header = app.staticTexts.matching(NSPredicate(format: "label == %@", "Acknowledgements")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "the Acknowledgements page didn't open")
        let end = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", Self.entries[1].last)).firstMatch
        let win = app.windows.firstMatch.frame
        var findings: [Finding] = [], regions: [Int: CGRect] = [:]
        // Up to 80 screens: at the largest size the 28 paragraphs took more than 30. A pushed page's top bar is its Back.
        var used = 0
        for screen in 1...80 {
            used = screen
            pause(0.8)
            regions[screen] = region(screen, top: ["morph.title", "Back"], bottom: ["tab.chats", "tab.settings", "chats.voice", "chats.new"])
            collectStops(in: regions[screen]!)
            findings += try audit(screen)
            if end.exists && end.isHittable && end.frame.maxY <= win.maxY { break }
            app.swipeUp(velocity: .slow)
        }
        Self.note("the Acknowledgements page read in \(used) screens")
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
        // The audit, judged now that the page's own stops are known: its header, its links and its paragraphs (VoiceOver's
        // stops from the header to the last paragraph, so a hidden tab's rows, which the audit also walks, aren't ours).
        let page = Set(labels[h..<min(i, labels.count)])
        for f in judge(findings, regions: regions, ours: { page.contains($0.label) }) { XCTFail(f) }
    }
}
