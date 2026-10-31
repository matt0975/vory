import XCTest

/// #533: turning the device, or closing or opening the Duo, keeps every tab where it was. Settings stays in front at its
/// depth (Settings › Troubleshooting › Screen layout), and on the Chats tab the open chat keeps its draft and its place
/// in the thread.
///
/// The moves come from outside the test: the Duo's posture is set from the Mac between steps. For each move the test
/// writes `ready-<n>` into ROT_DIR, then waits for `moved-<n>`. ROT_MOVES names the moves in order (e.g.
/// "side,closed,upright"); ROT_PRE names moves made before any scene is set, with Chats at its list and nothing read
/// (the focus test's cycle). With ROT_TURN=1 (the iPad) the test turns the device itself, to landscape and back. A move
/// "home" (#537) is made in the test with no posture change: Home, 2 s, then the app again. After
/// each move the state is read (ROTREAD lines) and judged KEPT, or LOST with the parts named:
/// - tab: the same tab in front (Settings);
/// - page: the same page in front at the same depth (Screen layout, two pushes from Settings);
/// - chat: the chat still open on the Chats tab;
/// - draft: its draft text equal;
/// - place: the thread isn't at its end (the last row's bottom isn't within 1 pt of the dock's top, nor of where it
///   stood when the chat opened at its end), and the row that stood at the thread's top before the move (its kind and
///   first words) is still in the thread's room after it; no row in the room is LOST too. Every move changes the window's
///   width, so rows reflow and no offset can be compared across one: the top row's offset from the thread's top is
///   printed before and after, for the record, and not judged. The thread is dragged up from its end before each move,
///   since a rebuild opens a chat at its end.
/// Two scenes go through every move (the open Duo's bar slides away while a chat is open, so a chat can't stay open
/// on Chats with another tab in front there): Settings › Troubleshooting › Screen layout in front (tab, page, depth), then
/// Chats in front with the chat open (tab, chat, draft, place). Each is read before and after a move the same way, with
/// no taps. The iPad, whose bar stays, adds one turn of the cross-tab case: the chat open on Chats with Screen layout
/// pushed in front, read through the same tab switch before and after. A scene whose setup doesn't take (Settings not
/// at Screen layout, the chat not set, the thread at its end before a move) makes the run VOID (ROTVOID), not a reading.
/// A LOST part fails the test only with ROT_STRICT=1. Without it the test reads the state and judges nothing (the
/// reading before a fix). Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (a mock with a long working chat:
/// MOCK_DIGEST); HERMES_E2E_BUNDLE=com.vorantx.vory.demo drives the demo copy.
@MainActor
final class RotationKeepsStackUITests: XCTestCase {
    private var app: XCUIApplication!
    private let draft = "A draft kept through a turn"
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private struct Place: Equatable {
        var row: String
        var top: Double
    }

    private struct State {
        var tab = "-"
        var page = "-"
        var depth = -1
        var chatOpen = false
        var draft = ""
        var place: Place?
        /// The bottom-most row's bottom, from the dock's top (window points): at the end it equals `endGap`.
        var lastGap: Double?
        /// The row that stood at the top before the move is in the thread's room now.
        var anchorShown = false
    }
    /// The gap between the last row's bottom and the dock's top with the chat at its end, measured as it opens.
    private var endGap: Double?

    // MARK: Reading

    /// The tab in front: the bar's selected button.
    private func frontTab() -> String {
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).allElementsBoundByIndex
        return tabs.first { $0.exists && $0.isSelected }?.identifier ?? "-"
    }

    /// Settings' page in front and its depth: Screen layout (2), Troubleshooting (1), Settings itself (0). Hittable only:
    /// XCTest's tree keeps the hidden tabs' pages.
    private func settingsPage() -> (String, Int) {
        let shown = { (id: String) -> Bool in let e = self.element(id); return e.exists && e.isHittable }
        if shown("layout.window") { return ("Screen layout", 2) }
        if shown("troubleshooting.replayTour") || shown("troubleshooting.screenLayout") || shown("troubleshooting.buildCheck") { return ("Troubleshooting", 1) }
        if shown("settings.row.troubleshooting") || app.navigationBars["Settings"].isHittable { return ("Settings", 0) }
        return ("-", -1)
    }

    /// The thread's top: under the chat's header (its bottom edge), or the window's top when there's none.
    private func threadTop() -> Double {
        let header = element("chat.header")
        return header.exists ? Double(header.frame.maxY) : Double(app.windows.firstMatch.frame.minY)
    }

    /// The thread's room's bottom: the dock's top, or the window's bottom when there's none.
    private func roomBottom() -> Double {
        let dock = element("chat.dock")
        return dock.exists ? Double(dock.frame.minY) : Double(app.windows.firstMatch.frame.maxY)
    }

    /// The rows in XCTest's tree (a lazy list keeps only those near the screen), top to bottom.
    private func rows() -> [XCUIElement] {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'thread.row.'")).allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 0 }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    /// A row's kind and its first words.
    private func name(_ row: XCUIElement) -> String {
        let words = row.staticTexts.allElementsBoundByIndex.lazy.map(\.label).first { !$0.isEmpty } ?? ""
        return "\(row.identifier) '\(words.prefix(48))'"
    }

    /// The first row whose top is at or under the thread's top, and above the room's bottom: its name, and its top's
    /// distance from the thread's top.
    private func place() -> Place? {
        let top = threadTop(), bottom = roomBottom()
        guard let first = rows().first(where: { Double($0.frame.minY) >= top - 0.5 && Double($0.frame.minY) < bottom }) else { return nil }
        return Place(row: name(first), top: (Double(first.frame.minY) - top).rounded(toPlaces: 1))
    }

    /// The bottom-most row's bottom from the room's bottom.
    private func lastGap() -> Double? {
        rows().last.map { (roomBottom() - Double($0.frame.maxY)).rounded(toPlaces: 1) }
    }

    /// Whether a row of that name is in the thread's room (between the thread's top and the room's bottom).
    private func shown(_ placeRow: String) -> Bool {
        let top = threadTop(), bottom = roomBottom()
        return rows().contains { name($0) == placeRow && Double($0.frame.maxY) > top && Double($0.frame.minY) < bottom }
    }

    private func readChat(into s: inout State, anchor: String? = nil) {
        let composer = app.textViews["composer.text"].firstMatch
        s.chatOpen = composer.exists && composer.isHittable
        s.draft = s.chatOpen ? ((composer.value as? String) ?? "") : ""
        s.place = s.chatOpen ? place() : nil
        s.lastGap = s.chatOpen ? lastGap() : nil
        s.anchorShown = s.chatOpen && anchor.map(shown) == true
    }

    private func line(_ tag: String, _ s: State) -> String {
        "tab \(s.tab) page '\(s.page)' depth \(s.depth) chat \(s.chatOpen ? "open" : "closed") draft '\(s.draft)' place \(s.place.map { "\($0.row) at \($0.top)" } ?? "-") last row's gap \(s.lastGap.map { "\($0)" } ?? "-") (at the end \(endGap.map { "\($0)" } ?? "-"))"
    }

    // MARK: Moving about

    /// Slow drags by the window's own coordinates (a swipe on the app's element can land on the Duo's other display) until
    /// `e` stands whole on screen, clear of the header and of a bar along the bottom.
    @discardableResult private func reach(_ e: XCUIElement, column: XCUIElement? = nil) -> Bool {
        let w = app.windows.firstMatch, bar = element("tab.settings")
        // Along the target's own column: its middle, or a shown element of the same list's (an iPad's Settings list is a
        // column of its own at the window's leading side; a drag at the window's middle moved the page beside it).
        func dx() -> CGFloat {
            let x = e.exists ? e.frame.midX : (column.flatMap { $0.exists && $0.isHittable ? $0.frame.midX : nil } ?? w.frame.midX)
            return max(0.05, min(0.95, (x - w.frame.minX) / max(1, w.frame.width)))
        }
        func clear() -> Bool {
            guard e.exists, e.isHittable else { return false }
            let alongBottom = bar.exists && bar.frame.minY > w.frame.midY && bar.frame.minX < e.frame.maxX && bar.frame.maxX > e.frame.minX
            return e.frame.minY > w.frame.minY + 110 && e.frame.maxY < (alongBottom ? bar.frame.minY : w.frame.maxY) - 12
        }
        for _ in 0..<30 where !clear() {
            let up = e.exists && e.frame.minY <= w.frame.minY + 110
            let x = dx()
            w.coordinate(withNormalizedOffset: CGVector(dx: x, dy: up ? 0.3 : 0.75)).press(forDuration: 0.05,
                thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: x, dy: up ? 0.75 : 0.3)), withVelocity: .slow, thenHoldForDuration: 0.3)
            pause(0.8)
        }
        return clear()
    }

    private func tapTab(_ name: String) {
        element("tab.\(name)").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        pause(1.5)
    }

    /// Settings › Troubleshooting › Screen layout, from wherever Settings stands.
    private func pushScreenLayout() {
        tapTab("settings")
        if settingsPage().1 == 2 { return }
        for _ in 0..<3 where settingsPage().1 > 0 {
            let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Back' OR identifier == 'BackButton'")).allElementsBoundByIndex.first { $0.isHittable }
            back?.tap(); pause(1)
        }
        let settingsRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings.row.'")).firstMatch
        XCTAssertTrue(reach(element("settings.row.troubleshooting"), column: settingsRow), "Troubleshooting not reached")
        element("settings.row.troubleshooting").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5)
        let troubleRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'troubleshooting.'")).firstMatch
        XCTAssertTrue(reach(element("troubleshooting.screenLayout"), column: troubleRow), "the Screen layout row not reached")
        element("troubleshooting.screenLayout").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5)
        XCTAssertTrue(element("layout.window").waitForExistence(timeout: 10), "Screen layout didn't open")
    }

    /// The chat open on the Chats tab with the draft typed, and the thread moved up from its end, so a rebuild (which
    /// opens a chat at its end) shows.
    private func setUpChat() throws {
        let composer = app.textViews["composer.text"].firstMatch
        // The chat already open and in front is kept: on the wide split (the Duo on its side) it stands in the detail column
        // beside the list, and a tap on the Chats tab there took it away. Otherwise Chats in front, and the chat's row.
        let pill = element("chat.titlePill")
        let open = composer.exists && composer.isHittable && pill.exists && pill.label.localizedCaseInsensitiveContains("Disk cleanup")
        if !open { tapTab("chats") }
        if !(composer.exists && composer.isHittable) {
            // The chat's row, as a button (the phone's list, the closed Duo) or as a cell or its text (the split's list
            // column): the first one that can be tapped. The header's own title is not a row.
            let words = NSPredicate(format: "label CONTAINS[c] 'Disk cleanup' AND identifier != 'chat.titlePill'")
            let rows = app.buttons.matching(words).allElementsBoundByIndex + app.cells.matching(words).allElementsBoundByIndex
                + app.staticTexts.matching(words).allElementsBoundByIndex
            guard let row = rows.first(where: { $0.exists && $0.isHittable }) else {
                // A still of the window's display (the script's) and the tree: what stood there instead of the row.
                print("ROTHOLD set-miss"); pause(2)
                print("ROTTREE begin\n\(app.debugDescription)\nROTTREE end")
                try require(false, "chat: no Disk cleanup row to open (open \(open), tab \(frontTab()))")
                return
            }
            row.tap()
            XCTAssertTrue(composer.waitForExistence(timeout: 20), "no composer")
            pause(2)
            // A chat opens at its end: where its last row's bottom stands then, before the keyboard or a drag moves it.
            if endGap == nil { endGap = lastGap(); print("ROTREAD the end: last row's gap \(endGap.map { "\($0)" } ?? "-")") }
        }
        if ((composer.value as? String) ?? "") != draft {
            // The keyboard comes up with focus; a tap while the chat still settles can miss it. Up to 3 taps 2 s apart, each
            // waiting for the keyboard; if none takes, a hold for the script's still and the element tree, and the scene is
            // void.
            var focused = false
            for attempt in 1...3 where !focused {
                composer.tap()
                focused = app.keyboards.firstMatch.waitForExistence(timeout: 3) || (composer.value(forKey: "hasKeyboardFocus") as? Bool ?? false)
                print("ROTFOCUS tap \(attempt): keyboard \(app.keyboards.count) focus \(composer.value(forKey: "hasKeyboardFocus") as? Bool ?? false) "
                      + "hittable \(composer.isHittable) frame \(composer.frame) value '\((composer.value as? String) ?? "")'")
                if !focused { pause(2) }
            }
            if !focused {
                // The still is the script's, of the window's own display: on the Duo XCUIScreen.main is the closed cover
                // display, dark while it's open (the night's composer-no-focus.png was that). Then the whole tree.
                print("ROTHOLD focus-miss"); pause(2)
                print("ROTTREE begin\n\(app.debugDescription)\nROTTREE end")
                try require(false, "chat: the composer never took the keyboard")
            }
            if let old = composer.value as? String, !old.isEmpty, old != draft { composer.press(forDuration: 1.2); app.menuItems["Select All"].tap(); app.keys["delete"].tap() }
            composer.typeText(draft)
        }
        // Two slow drags down the thread (the content moves down, older rows come in); the first also puts the keyboard
        // away. Each inside the thread's room, measured before it (from a fifth of the way down to nine tenths), in the
        // composer's column. By the window's height (0.35 to 0.7) the iPad's set in landscape, the keyboard up, pressed at
        // 287 pt, 28 pt over the composer, moved nothing, and the thread read at its end (VOID on both arms).
        let w = app.windows.firstMatch
        for _ in 0..<2 {
            let top = threadTop(), bottom = roomBottom(), f = w.frame
            let x = composer.exists ? max(0.05, min(0.95, (composer.frame.midX - f.minX) / max(1, f.width))) : 0.5
            let from = (top + (bottom - top) * 0.2 - f.minY) / max(1, f.height), to = (top + (bottom - top) * 0.9 - f.minY) / max(1, f.height)
            let kb = app.keyboards.firstMatch
            print("ROTREAD the room \(top) to \(bottom) (keyboard \(kb.exists ? "\(kb.frame)" : "none")): a drag at x \(x) from \(from) to \(to) of the window")
            w.coordinate(withNormalizedOffset: CGVector(dx: x, dy: from)).press(forDuration: 0.05,
                thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: x, dy: to)), withVelocity: .slow, thenHoldForDuration: 0.3)
            pause(1)
        }
        pause(1)
    }

    /// At the thread's end: the last row's bottom within 1 pt of the dock's top, or of where it stood when the chat opened
    /// at its end (the same rule when that gap is 0). No last row counts as the end.
    private func atEnd(_ s: State) -> Bool {
        guard let g = s.lastGap else { return true }
        return abs(g) <= 1 || endGap.map { abs(g - $0) <= 1 } == true
    }

    /// A posture move made from the Mac: `ready-<k>` written (the move's name), then `moved-<k>` waited for, 180 s at most.
    private func handOff(_ move: String, _ k: Int, _ what: String, dir: URL) throws {
        try "\(move)\n".write(to: dir.appendingPathComponent("ready-\(k)"), atomically: true, encoding: .utf8)
        print("ROTREADY \(k) \(what) \(move)")
        let moved = dir.appendingPathComponent("moved-\(k)")
        let deadline = Date().addingTimeInterval(180)
        while !FileManager.default.fileExists(atPath: moved.path) && Date() < deadline { pause(0.5) }
        try require(FileManager.default.fileExists(atPath: moved.path), "move \(k) (\(move)) never came")
    }

    /// A setup that didn't take: the run is void, not a reading.
    private func require(_ ok: Bool, _ why: String) throws {
        guard ok else { print("ROTVOID \(why)"); throw XCTSkip("VOID: \(why)") }
    }

    // MARK: The test

    /// The two scenes, each taken through every move, since on the open Duo the tab bar slides away while a chat is open
    /// and a chat can't stay open on Chats while another tab is in front:
    /// - settings: Settings › Troubleshooting › Screen layout in front (Chats at its list); its tab, page and depth;
    /// - chat: Chats in front with the chat open, its draft typed and its thread dragged up from the end; its tab, the
    ///   chat, the draft and the place.
    /// Each is read before and after a move the same way, with no taps: the scene's own parts as they stand in front.
    /// - cross (the iPad only, where the bar stays with a chat open; one turn): the chat open on Chats, then Settings ›
    ///   Troubleshooting › Screen layout pushed in front: a background tab's stack, the case #533 was filed for. Read
    ///   through the same tab switch before and after: Settings first with no taps, then Chats tapped and the chat read.
    private enum Scene: String { case settings, chat, cross }

    private func setUp(_ scene: Scene) throws -> State {
        var s = State()
        switch scene {
        case .settings:
            // A chat left open (from a restored launch) hides the bar: back to the list first.
            let back = element("chat.back")
            if back.exists && back.isHittable { back.tap(); pause(1.5) }
            pushScreenLayout()
            s.tab = frontTab(); (s.page, s.depth) = settingsPage()
            print("ROTREAD \(scene) set \(line("set", s))")
            try require(s.depth == 2, "settings: not at Screen layout (\(line("set", s)))")
        case .chat:
            try setUpChat()
            s.tab = frontTab()
            readChat(into: &s)
            print("ROTREAD \(scene) set \(line("set", s))")
            try require(s.chatOpen && s.draft == draft && s.place != nil, "chat: the chat isn't set (\(line("set", s)))")
            try require(endGap != nil, "the end's gap wasn't measured")
            try require(!atEnd(s), "chat: the thread is at its end before the move")
        case .cross:
            try setUpChat()
            pushScreenLayout()
            // The control: the same tab switch as after the turn (Chats tapped, the chat read), then Settings again.
            tapTab("chats")
            readChat(into: &s)
            tapTab("settings")
            s.tab = frontTab(); (s.page, s.depth) = settingsPage()
            print("ROTREAD \(scene) set \(line("set", s))")
            try require(s.depth == 2, "cross: not at Screen layout (\(line("set", s)))")
            try require(s.chatOpen && s.draft == draft && s.place != nil, "cross: the chat isn't set (\(line("set", s)))")
            try require(!atEnd(s), "cross: the thread is at its end before the turn")
        }
        return s
    }

    /// The scene's parts after a move, read as they stand, with no taps.
    private func read(_ scene: Scene, before: State) -> (State, [String]) {
        var a = State(), parts: [String] = []
        a.tab = frontTab()
        if a.tab != before.tab { parts.append("tab") }
        switch scene {
        case .settings, .cross:
            (a.page, a.depth) = settingsPage()
            if a.page != before.page || a.depth != before.depth { parts.append("page") }
        case .chat:
            break
        }
        if scene == .cross { tapTab("chats") }
        if scene != .settings {
            readChat(into: &a, anchor: before.place?.row)
            if !a.chatOpen { parts.append("chat") }
            if a.draft != before.draft { parts.append("draft") }
            // Place: (a) not at the end, (b) the row that stood at the top still in the room. Offsets printed, not judged.
            var place: [String] = []
            if a.place == nil { place.append("no row in the room") }
            if atEnd(a) { place.append("at the end") }
            if !a.anchorShown { place.append("the top row gone") }
            if !place.isEmpty { parts.append("place (\(place.joined(separator: ", ")))") }
            print("ROTREAD chat top row before \(before.place.map { "\($0.row) at \($0.top)" } ?? "-"), after \(a.place.map { "\($0.row) at \($0.top)" } ?? "-")")
        }
        return (a, parts)
    }

    func testATurnKeepsEveryTabWhereItWas() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        let turn = e["ROT_TURN"] == "1", strict = e["ROT_STRICT"] == "1"
        let moves = turn ? ["landscape", "portrait"] : (e["ROT_MOVES"] ?? "").split(separator: ",").map(String.init)
        guard !moves.isEmpty else { throw XCTSkip("no moves (ROT_MOVES, or ROT_TURN=1)") }
        let dir = e["ROT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard turn || dir != nil else { throw XCTSkip("ROT_DIR not set") }

        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats",
                               "-colorSchemePreference", "light"]
        app.launch()
        XCTAssertTrue(element("tab.chats").waitForExistence(timeout: 40), "no tab bar")
        pause(2)
        if turn { XCUIDevice.shared.orientation = .portrait; pause(2) }

        // Every scene through every move; the moves are numbered across the scenes (ready-<k>, moved-<k>). The iPad also
        // takes the cross-tab scene through one turn, then is turned back unread.
        var lost = 0, k = 0
        // ROT_PRE (the like-for-like focus test): posture moves made first, with Chats at its list in front, nothing set
        // and nothing read; numbered with the rest.
        for move in (e["ROT_PRE"] ?? "").split(separator: ",").map(String.init) {
            guard let dir, !turn else { break }
            let w0 = app.windows.firstMatch.frame
            try handOff(move, k, "pre", dir: dir)
            for _ in 0..<20 where app.windows.firstMatch.frame == w0 { pause(0.5) }
            pause(3)
            print("ROTPRE \(k) \(move) window \(w0.size.width)x\(w0.size.height) -> \(app.windows.firstMatch.frame.size.width)x\(app.windows.firstMatch.frame.size.height)")
            k += 1
        }
        let only = Set((e["ROT_SCENES"] ?? "").split(separator: ",").compactMap { Scene(rawValue: String($0)) })
        for scene in (turn ? [Scene.settings, .chat, .cross] : [.settings, .chat]) where only.isEmpty || only.contains(scene) {
            var before = try setUp(scene)
            let sceneMoves = scene == .cross ? ["landscape"] : moves
            for move in sceneMoves {
                let w0 = app.windows.firstMatch.frame
                if move == "home" {
                    // #537: leaving the app and coming back (no posture change): Home, 2 s, then the app again.
                    XCUIDevice.shared.press(.home)
                    pause(2)
                    app.activate()
                } else if turn {
                    XCUIDevice.shared.orientation = move == "landscape" ? .landscapeLeft : .portrait
                } else if let dir {
                    try handOff(move, k, scene.rawValue, dir: dir)
                }
                // The window takes its new size, then settles (leaving and coming back keeps it: the wait ends at once).
                for _ in 0..<20 where move != "home" && app.windows.firstMatch.frame == w0 { pause(0.5) }
                pause(3)
                let (after, parts) = read(scene, before: before)
                print("ROTREAD \(k) \(scene) \(move) window \(w0.size.width)x\(w0.size.height) -> \(app.windows.firstMatch.frame.size.width)x\(app.windows.firstMatch.frame.size.height): \(line("after", after))")
                print("ROTVERDICT \(k) \(scene) \(move) \(parts.isEmpty ? "KEPT" : "LOST " + parts.joined(separator: ","))")
                if !parts.isEmpty { lost += 1 }
                if strict { XCTAssertTrue(parts.isEmpty, "move \(k) (\(scene), \(move)) lost \(parts.joined(separator: ", "))") }
                k += 1
                // Back to the scene's start for the next move, each read on its own.
                if scene == .cross { XCUIDevice.shared.orientation = .portrait; pause(2) } else { before = try setUp(scene) }
            }
        }
        print("ROTDONE \(k) moves, \(lost) lost")
        app.terminate()
    }
}

private extension Double {
    func rounded(toPlaces p: Int) -> Double { let m = pow(10, Double(p)); return (self * m).rounded() / m }
}
