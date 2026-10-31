import XCTest

/// Duo stage 4: voice mode on a window folded across (the Duo half open like a laptop): the top row and the bot with its
/// title, state lines and waveform above the fold; the conversation, any waiting card and Mute / End / Pause below it
/// (`VoiceSplit`). Runs in whatever pose the simulator is in; the column, the fold and the frames come off the voice
/// screen's DEBUG readout (`-vory-voice-frames`, `voice.frames`). Driven by HERMES_E2E_VOICE_CASE:
/// - "frames": voice mode open; with HERMES_E2E_EXPECT=split, the top row and the bot wholly above the fold, the controls
///   wholly below it; with "one", one column. Every frame is printed (VOICE-HALF) for a compare.
/// - "card": the same, with an approval waiting (the mock asks one at the end of its turn): the card between the fold and
///   the controls, its start (what's asked) in view and Allow once and Deny at hand, at rest.
/// - "posture": Pause, then the posture changed from outside (HERMES_E2E_SIGNAL_DIR: this test writes ready-N and waits
///   for posed-N): the session kept (End there, the same Pause and Mute words, the same transcript), only the frames moved.
/// - "oracle": paused and settled, what VoiceOver stops on in voice mode (`-vory-ax-oracle`), printed in order for a compare
///   between poses and builds.
/// - "audit": paused and settled, performAccessibilityAudit on voice mode, every type: every issue printed, for the run's
///   compare with the release head's in the same pose (none, or only issues it has today; the DEBUG readout's left out).
/// - "worst": the bot's block in a state's tallest form (HERMES_E2E_WORST thinking | paused | error, `-vory-voice-worst`)
///   with the motion engine off: its content's height and the top half's printed (`VoiceSplit.minTop`). With
///   HERMES_E2E_EXPECT=measure, measuring only; with "split" (the gate, at a size the table splits), checked as "frames".
/// HERMES_E2E_SIZE sets the text size (L, XL, XXL, XXXL); HERMES_E2E_BASE=1 is the release head's copy, which has no readout.
/// A launch that can't reach the Chats list fails as "setup", which the legs count as void, never as a pass.
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock).
@MainActor
final class VoiceHalfOpenUITests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var isBase: Bool { env["HERMES_E2E_BASE"] == "1" }
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func hittable(_ q: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if let e = q.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            pause(0.3)
        } while Date() < end
        return nil
    }

    /// The readout: "row x y w h;bot …;controls …;card …|none;column …;fold …|none;split yes|no".
    private struct Readout {
        var row = CGRect.null, bot = CGRect.null, controls = CGRect.null, card: CGRect?, column = CGRect.null, fold: CGRect?
        var split = false
    }
    private func readout() -> Readout? {
        let r = any("voice.frames")
        guard r.waitForExistence(timeout: 5) else { return nil }
        var out = Readout()
        for part in r.label.split(separator: ";") {
            let w = part.split(separator: " ")
            guard let key = w.first else { continue }
            let n = w.dropFirst().compactMap { Double($0) }
            let rect = n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
            switch key {
            case "row": out.row = rect ?? .null
            case "bot": out.bot = rect ?? .null
            case "controls": out.controls = rect ?? .null
            case "card": out.card = rect
            case "column": out.column = rect ?? .null
            case "fold": out.fold = rect
            case "split": out.split = w.last == "yes"
            default: break
            }
        }
        return out
    }

    private func signal(_ name: String) {
        guard let dir = env["HERMES_E2E_SIGNAL_DIR"], !dir.isEmpty else { return }
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent(name), contents: Data())
        print("VOICE-HALF signal \(name)")
    }
    private func waitFor(_ name: String, timeout: TimeInterval = 90) -> Bool {
        guard let dir = env["HERMES_E2E_SIGNAL_DIR"], !dir.isEmpty else { return false }
        let path = (dir as NSString).appendingPathComponent(name), end = Date().addingTimeInterval(timeout)
        while Date() < end { if FileManager.default.fileExists(atPath: path) { return true }; pause(0.5) }
        return false
    }

    private func controls() -> [XCUIElement] {
        [app.buttons["End voice mode"].firstMatch,
         app.buttons.matching(NSPredicate(format: "label == 'Mute' OR label == 'Unmute'")).firstMatch,
         app.buttons.matching(NSPredicate(format: "label == 'Pause' OR label == 'Resume'")).firstMatch]
    }

    /// The Chats list in front, where the mic is. A relaunch can restore a chat left open (the voice session's), so Back
    /// is tapped until the list shows, 4 times at most. Prints the screen the launch started on.
    private func toChatsList() -> XCUIElement? {
        let mic = app.buttons.matching(identifier: "chats.voice"), back = app.buttons["chat.back"].firstMatch
        var started = "unknown"
        let end = Date().addingTimeInterval(30)
        repeat {
            if hittable(mic, timeout: 0.5) != nil { started = "chats"; break }
            if back.exists { started = "chat"; break }
        } while Date() < end
        print("VOICE-HALF launch screen \(started)")
        for _ in 0..<4 where hittable(mic, timeout: 2) == nil {
            // Back can take a moment to become hittable after a relaunch (5 s at most, the wait printed); never is a
            // setup failure, with no tap at its coordinate in its place.
            let start = Date()
            let ok = back.exists && hittable(app.buttons.matching(identifier: "chat.back"), timeout: 5) != nil
            print(String(format: "VOICE-HALF setup: Back %@ after %.1f s", ok ? "hittable" : "not hittable", Date().timeIntervalSince(start)))
            printWhatStands(at: back)
            guard ok else { break }
            back.tap(); pause(1.5)
        }
        if let m = hittable(mic, timeout: 15) { return m }
        XCTFail("setup: no Chats list (the launch started on \(started))")
        return nil
    }

    /// For the record at Back's check: every element whose frame holds Back's middle, from one snapshot of the tree,
    /// outermost first, so what stands over it is named (on the closed Duo, Back read not hittable after a relaunch into a chat).
    private func printWhatStands(at e: XCUIElement) {
        guard e.exists, let snap = try? app.snapshot() else { return }
        let mid = CGPoint(x: e.frame.midX, y: e.frame.midY)
        let dock = app.otherElements["chat.dock"].firstMatch
        print("VOICE-HALF at-back middle \(mid) of \(e.frame); the dock \(dock.exists ? "\(dock.frame)" : "none")")
        // Where the transcript stands: its rows (the first and the last) show how far it is scrolled.
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'thread.row.'")).allElementsBoundByIndex
        print("VOICE-HALF at-back rows \(rows.count); first \(rows.first.map { "'\($0.identifier)' \($0.frame)" } ?? "none"); last \(rows.last.map { "'\($0.identifier)' \($0.frame)" } ?? "none")")
        func walk(_ s: XCUIElementSnapshot, _ depth: Int) {
            if s.frame.contains(mid) {
                print("VOICE-HALF at-back \(depth) type \(s.elementType.rawValue) id '\(s.identifier)' label '\(s.label.prefix(50))' frame \(s.frame)")
            }
            for c in s.children { walk(c, depth + 1) }
        }
        walk(snap, 0)
    }

    private func checkSplit(_ state: String, cardIDs: Bool = false) {
        guard let r = readout() else { return XCTFail("\(state): no voice.frames readout") }
        print("VOICE-HALF \(state) row \(r.row) bot \(r.bot) controls \(r.controls) card \(r.card.map { "\($0)" } ?? "none") column \(r.column) fold \(r.fold.map { "\($0)" } ?? "none") split \(r.split)")
        guard let fold = r.fold else { return XCTFail("\(state): no fold across the window") }
        XCTAssertTrue(r.split, "\(state): one column under a fold across")
        // Above the fold: the top row, then the bot below it; neither spills up out of the column or down onto the fold.
        let hide = app.buttons["Hide voice mode"].firstMatch
        XCTAssertTrue(hide.exists, "\(state): no Hide button")
        if hide.exists {
            print("VOICE-HALF \(state) hide \(hide.frame)")
            XCTAssertGreaterThanOrEqual(hide.frame.minY, r.column.minY - 0.5, "\(state): the top row runs out of the column (\(hide.frame) vs \(r.column))")
            XCTAssertLessThanOrEqual(hide.frame.maxY, r.bot.minY + 0.5, "\(state): the bot runs up into the top row (\(r.bot) vs \(hide.frame))")
        }
        XCTAssertLessThanOrEqual(r.bot.maxY, fold.minY + 0.5, "\(state): the bot reaches the fold (\(r.bot) vs \(fold))")
        XCTAssertGreaterThanOrEqual(r.controls.minY, fold.maxY - 0.5, "\(state): the controls reach the fold (\(r.controls) vs \(fold))")
        for c in controls() {
            XCTAssertTrue(c.exists, "\(state): a control is missing (End, Mute or Pause)")
            guard c.exists else { continue }
            print("VOICE-HALF \(state) control '\(c.label)' frame \(c.frame) hittable \(c.isHittable)")
            XCTAssertGreaterThanOrEqual(c.frame.minY, fold.maxY - 0.5, "\(state): '\(c.label)' is above the fold's foot")
            XCTAssertTrue(c.isHittable, "\(state): '\(c.label)' isn't hittable")
        }
        guard cardIDs else { return }
        guard let card = r.card else { return XCTFail("\(state): no card below the fold") }
        XCTAssertGreaterThanOrEqual(card.minY, fold.maxY - 0.5, "\(state): the card reaches the fold (\(card) vs \(fold))")
        XCTAssertLessThanOrEqual(card.maxY, r.controls.minY + 0.5, "\(state): the card runs under the controls (\(card) vs \(r.controls))")
        // At rest, with nothing scrolled: the card's start (what's asked) in view, and Allow once and Deny at hand.
        let asked = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Delete '")).firstMatch
        print("VOICE-HALF \(state) card asked \(asked.exists ? "\(asked.frame) hittable \(asked.isHittable)" : "none")")
        XCTAssertTrue(asked.exists && asked.isHittable && asked.frame.minY >= card.minY - 0.5, "\(state): the card's start isn't in view at rest")
        var atRest = true
        for label in ["Allow once", "Deny"] {
            let b = app.buttons[label].firstMatch
            print("VOICE-HALF \(state) card button '\(label)' frame \(b.exists ? "\(b.frame)" : "none") hittable \(b.exists && b.isHittable)")
            let ok = b.exists && b.isHittable && b.frame.minY >= card.minY - 0.5 && b.frame.maxY <= card.maxY + 0.5
            XCTAssertTrue(ok, "\(state): '\(label)' isn't at hand at rest")
            atRest = atRest && ok
        }
        if !atRest {
            // The fallback, for the record only: are the choices there after one scroll of the card's words?
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: card.midX, dy: card.midY)).press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: card.midX, dy: card.minY + 10)))
            pause(1)
            for label in ["Allow once", "Deny"] { print("VOICE-HALF \(state) card after one scroll '\(label)' hittable \(app.buttons[label].firstMatch.isHittable)") }
        }
    }

    /// The conversation's lines, by their labels ("You said: …", "Bot said: …"). Not every text in a scroll view: a waiting
    /// card's words scroll in the split and not in one column, so that count changes with the pose while the session doesn't.
    private func conversation() -> [String] {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'You said: ' OR label BEGINSWITH 'Bot said: '"))
            .allElementsBoundByIndex.filter { $0.exists }.map(\.label)
    }

    /// What the session shows now: End there, the Pause and Mute words, and the conversation's lines (their count and last).
    private func sessionState() -> String {
        let lines = conversation()
        let words = controls().dropFirst().map { $0.exists ? $0.label : "none" }
        return "end \(controls()[0].exists) mute \(words[0]) pause \(words[1]) lines \(lines.count) last '\(lines.last?.prefix(40) ?? "")'"
    }

    /// The waiting card, by its words: what it asks ("Delete …"), the command after it, and Allow once; "card none" without
    /// one. Printed beside it, for the record: the card's texts (heading, ask, command, tool, scope) and how many of them
    /// stand in a scroll view, beside every text in one (the count the posture case once compared as the conversation's).
    private func cardState(_ when: String) -> String {
        let texts = app.staticTexts.allElementsBoundByIndex.filter { $0.exists }.map(\.label)
        guard let i = texts.firstIndex(where: { $0.hasPrefix("Delete ") }), i + 1 < texts.count else { return "card none" }
        let own = NSPredicate(format: "label == 'Approval needed' OR label == %@ OR label == %@ OR label BEGINSWITH 'Tool: ' OR label BEGINSWITH 'Allow once: this command only.'", texts[i], texts[i + 1])
        print("VOICE-HALF posture \(when) texts in scroll views \(app.scrollViews.staticTexts.count), the card's \(app.staticTexts.matching(own).count), of them in scroll views \(app.scrollViews.staticTexts.matching(own).count)")
        return "card asked '\(texts[i].prefix(40))' command '\(texts[i + 1].prefix(40))' allow \(app.buttons["Allow once"].firstMatch.exists)"
    }

    /// One of the posture case's reads: the session and the card, printed. None of the conversation, or no card, fails:
    /// none would compare equal to none.
    private func postureRead(_ when: String, _ session: String) -> String {
        print("VOICE-HALF posture \(when) \(session)")
        let card = cardState(when)
        print("VOICE-HALF posture \(when) \(card)")
        XCTAssertFalse(conversation().isEmpty, "\(when): no conversation lines")
        XCTAssertNotEqual(card, "card none", "\(when): no waiting card")
        return card
    }

    /// Pause, then the session once it holds still (the same two reads 2 s apart, within 20 s): a line the fake input
    /// was saying may still land, and a compare between poses needs the conversation settled first.
    private func pauseAndSettle() -> String {
        let pauseButton = app.buttons.matching(NSPredicate(format: "label == 'Pause'")).firstMatch
        if pauseButton.waitForExistence(timeout: 20) { pauseButton.tap() }
        var last = sessionState()
        let end = Date().addingTimeInterval(20)
        repeat {
            pause(2)
            let now = sessionState()
            if now == last { return now }
            last = now
        } while Date() < end
        print("VOICE-HALF settle: still changing after 20 s (\(last))")
        return last
    }

    /// One column, as expected: the release head's copy has no readout and is taken at its word.
    private func checkOne(_ state: String) {
        guard !isBase else { return }
        guard let r = readout() else { return XCTFail("\(state): no voice.frames readout") }
        print("VOICE-HALF \(state) one column row \(r.row) bot \(r.bot) controls \(r.controls) column \(r.column) fold \(r.fold.map { "\($0)" } ?? "none") split \(r.split)")
        XCTAssertFalse(r.split, "\(state): split without a fold across")
    }

    func testVoiceModeAtTheFold() throws {
        guard let url = env["HERMES_E2E_URL"], let token = env["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        continueAfterFailure = true
        let voiceCase = env["HERMES_E2E_VOICE_CASE"] ?? "frames"
        let expect = env["HERMES_E2E_EXPECT"] ?? "split"
        let size = env["HERMES_E2E_SIZE"] ?? "L"
        // `-restore.openChat none`: the last open chat isn't reopened (its saved record reads as nothing for this launch,
        // the argument domain only), so every launch starts on the Chats list, in both copies.
        var args = ["-companionPromptShown", "YES", "-launchTab", "chats", "-restore.openChat", "none", "-tabBar.showVoice", "YES",
                    "-vory-voice-fake-input", "-vory-voice-frames", "-colorSchemePreference", env["HERMES_E2E_SCHEME"] ?? "dark",
                    "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategory\(size)"]
        if voiceCase == "oracle" { args.append("-vory-ax-oracle") }
        if voiceCase == "worst" { args += ["-vory-voice-worst", env["HERMES_E2E_WORST"] ?? "thinking", "-vory-motion-engine", "<false/>"] }
        if let bundle = env["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication(); app.launchArguments = args
        }
        app.launch()
        guard let mic = toChatsList() else { return }
        mic.tap()
        XCTAssertTrue(app.buttons["End voice mode"].firstMatch.waitForExistence(timeout: 30), "the voice screen did not open")
        pause(3)
        print("VOICE-HALF state \(voiceCase) at \(String(format: "%.1f", Date().timeIntervalSince1970))")

        switch voiceCase {
        case "card":
            // The fake input asks the mock's default turn, which ends on an approval.
            XCTAssertTrue(app.buttons["Allow once"].firstMatch.waitForExistence(timeout: 90), "no approval card in voice mode")
            pause(1.5)
            print("VOICE-HALF state card-up at \(String(format: "%.1f", Date().timeIntervalSince1970))")
            if expect == "split" { checkSplit("card", cardIDs: true) } else { checkOne("card") }
        case "posture":
            // Paused, so the conversation holds still while the posture changes. The same session in every read: the
            // controls' words, the conversation's lines and the waiting card.
            let s1 = pauseAndSettle(); checkSplit("posture-laptop-1")
            let c1 = postureRead("before", s1)
            signal("ready-1")
            XCTAssertTrue(waitFor("posed-1"), "no flat pose in time")
            pause(2)
            let s2 = sessionState()
            let c2 = postureRead("flat", s2)
            checkOne("posture-flat")
            signal("ready-2")
            XCTAssertTrue(waitFor("posed-2"), "no laptop pose in time")
            pause(2)
            let s3 = sessionState(); checkSplit("posture-laptop-2")
            let c3 = postureRead("after", s3)
            XCTAssertEqual(s1, s2, "the session changed going flat")
            XCTAssertEqual(s1, s3, "the session changed coming back")
            XCTAssertEqual(c1, c2, "the card changed going flat")
            XCTAssertEqual(c1, c3, "the card changed coming back")
        case "oracle":
            // Paused and settled, so the stops are the same screen's in every pose.
            print("VOICE-HALF oracle at \(pauseAndSettle())")
            let o = any("debug.voiceover")
            XCTAssertTrue(o.waitForExistence(timeout: 5), "no oracle")
            // The DEBUG readout is a stop in A's build only, its words the pose's: left out of the compared stops by its
            // identifier (its label read either side of the walk, the same both times), and the count left out printed.
            let readout = any("voice.frames"), before = readout.exists ? readout.label : nil
            let stops = ((o.value as? String) ?? "").split(separator: "\n").map { String($0.split(separator: "|").first ?? "") }
            let after = readout.exists ? readout.label : nil
            XCTAssertEqual(before, after, "the readout changed during the walk")
            let compared = stops.filter { before == nil || $0 != before }
            print("VOICE-HALF oracle \(stops.count) stops: \(stops.joined(separator: " / "))")
            print("VOICE-HALF oracle readout left out \(stops.count - compared.count)")
            print("VOICE-HALF oracle compared \(compared.count) stops: \(compared.joined(separator: " / "))")
        case "audit":
            print("VOICE-HALF audit at \(pauseAndSettle())")
            var count = 0
            try app.performAccessibilityAudit { issue in
                let el = issue.element
                print("VOICE-HALF audit issue '\(issue.compactDescription)' type \(el?.elementType.rawValue ?? 0) id '\(el?.identifier ?? "")' label '\(el?.label.prefix(60) ?? "")' frame \(el?.frame ?? .zero)")
                count += 1
                return true
            }
            print("VOICE-HALF audit \(count) issues")
        case "worst":
            // Measuring only: the top half's worst content, never a pass or fail on the split.
            guard let r = readout() else { return XCTFail("worst: no voice.frames readout") }
            let top = r.fold.map { $0.minY - r.column.minY } ?? -1
            print(String(format: "VOICE-HALF worst %@ size %@ row %.1f bot %.1f content %.1f top %.1f controls %.1f column %.1f-%.1f split %@",
                         env["HERMES_E2E_WORST"] ?? "thinking", size, r.row.height, r.bot.height, r.row.height + 12 + r.bot.height, top,
                         r.controls.height, r.column.minY, r.column.maxY, r.split ? "yes" : "no"))
            // In the gate (HERMES_E2E_EXPECT=split, at a size the table splits): the worst state at its own height fits its
            // half, no line lost to a squeeze, nothing on the fold.
            if expect == "split" {
                XCTAssertLessThanOrEqual(r.row.height + 12 + r.bot.height, top + 0.5, "worst: the content outgrows the top half")
                checkSplit("worst-\(env["HERMES_E2E_WORST"] ?? "thinking")")
            }
        default:
            // The controls and the title first, at the same moment in every build (the release head has no readout, and
            // waits for it), for the compare with it.
            for c in controls() where c.exists { print("VOICE-HALF frames control '\(c.label)' frame \(c.frame)") }
            // The title by its word, any of HandsFreeState's, and the one centred over End (centred in the column, which
            // the window isn't on the closed Duo, its strip at a side): a waiting card's heading also reads "Approval
            // needed", at the card's leading edge. Its top and height are compared, the word only printed (A and the release
            // head can be a beat apart in the session); none found prints "none", a void compare.
            let words = ["Muted", "Listening", "Listening…", "Got it…", "Thinking…", "Speaking", "Approval needed", "Paused", "Ended"]
            let end = controls()[0], midX = end.exists ? end.frame.midX : -1
            let title = app.staticTexts.matching(NSPredicate(format: "label IN %@", words)).allElementsBoundByIndex
                .first { $0.exists && abs($0.frame.midX - midX) <= 2 }
            print(title.map { "VOICE-HALF frames title '\($0.label)' frame \($0.frame)" } ?? "VOICE-HALF frames title none")
            if expect == "split" { checkSplit("frames") } else if expect == "one" { checkOne("frames") }
            if !isBase, let r = readout() { print(String(format: "VOICE-HALF frames size %@ controls height %.1f", size, r.controls.height)) }
        }
        app.buttons["End voice mode"].firstMatch.tap()
    }
}
