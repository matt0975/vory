import XCTest

/// #516: on the open iPhone Duo upright (flat, or half open like a laptop) the floating top bar stands up in the status
/// band, clear of the status (`TopBarRoom.barUp`). Checked by the capsules as drawn (`-vory-morph-frames`):
/// - on every root tab and on a pushed Settings page, every capsule inside the band's row (y 26 to 70, 1 pt either way)
///   and ending at x 443 or before; a search field starts under the row; each tab's first content top is printed against
///   the safe area's top, for the record;
/// - at the bar's largest type (XXXL) the title capsule grows to 50 pt, downward from the same top: the row's top still
///   at 26, every capsule's bottom inside the band (78: the band's 82 less 4), none overlapping, all ending by 443, each
///   title inside its capsule (the 26 to 70 row is the default size's);
/// - the controls in the band take taps: with the page scrolled down from its top, Sort and Filters open their menus,
///   New bot opens its page, Back pops, and the page keeps its scroll (a tap the status bar took would scroll it to the
///   top instead).
/// Every frame is printed (BARUP). Run where the bar is up (HERMES_E2E_BARUP=1: the Duo upright, flat or laptop);
/// skipped elsewhere, where the frames A/B holds the bar unmoved. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are
/// set (a mock with a long chat list: --extra-sessions).
/// #542: a chat's bar on the Duo like Messages, in the pose the script names (HERMES_E2E_POSE: upright, laptop, closed,
/// side, book), and nothing travelling between the list and a chat in the bar's own frame log.
@MainActor
final class BarUpUITests: XCTestCase {
    private var app: XCUIApplication!
    /// The row in the band and its trailing limit (`TopBarRoom.bandRowTop`, `bandRowHeight`, the 669 pt window less
    /// `statusReserve`), with 1 pt either way for rounding.
    static let rowTop: CGFloat = 26, rowBottom: CGFloat = 70, trailingLimit: CGFloat = 443, slack: CGFloat = 1
    /// At the bar's largest type: the band's bottom (the safe area's top, 82) less 4.
    static let bandBottom: CGFloat = 78
    /// The open Duo's top safe area (Matt's readouts and the simulator agree).
    static let safeTop: CGFloat = 82

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func launch(_ tab: String, _ extra: [String] = []) throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        guard e["HERMES_E2E_BARUP"] == "1" else { throw XCTSkip("the bar isn't up in this pose (HERMES_E2E_BARUP=1)") }
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", tab,
                               "-colorSchemePreference", "light", "-vory-morph-frames"] + extra
        app.launch()
        XCTAssertTrue(element("tab.\(tab)").waitForExistence(timeout: 40), "no tab \(tab)")
        pause(2)
    }

    /// The bar's capsules as drawn ("lead x y w h;mid …;trail …").
    private func caps() -> [String: CGRect] {
        let r = element("debug.morphframes")
        return r.exists ? Duo516UITests.capsules(in: (r.value as? String) ?? "") : [:]
    }

    /// Every capsule in the band's row and ending by the trailing limit; the row's bottom. At the bar's largest type
    /// (`largest`) the row's top stays at 26 and every capsule's bottom is inside the band (78) instead.
    @discardableResult private func checkRow(_ what: String, largest: Bool = false) -> CGFloat {
        let c = caps()
        print("BARUP \(what) capsules \(c.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        XCTAssertFalse(c.isEmpty, "\(what): no capsules")
        if largest, let top = c.values.map(\.minY).min() {
            XCTAssertEqual(top, Self.rowTop, accuracy: Self.slack, "\(what): the row's top \(top), not \(Self.rowTop)")
        }
        for (slot, f) in c {
            XCTAssertGreaterThanOrEqual(f.minY, Self.rowTop - Self.slack, "\(what): \(slot) \(f) above the band's row")
            XCTAssertLessThanOrEqual(f.maxY, largest ? Self.bandBottom : Self.rowBottom + Self.slack,
                                     "\(what): \(slot) \(f) below the \(largest ? "band" : "band's row")")
            XCTAssertLessThanOrEqual(f.maxX, Self.trailingLimit + Self.slack, "\(what): \(slot) \(f) reaches the status")
        }
        return c.values.map(\.maxY).max() ?? 0
    }

    /// The first content under the band: the search field if there is one (it must start under the row), else the top
    /// of the first hittable text below the safe area's top. Printed against the safe top, not judged.
    private func firstContent(_ what: String, rowBottom: CGFloat) {
        let search = app.searchFields.firstMatch
        if search.exists, search.isHittable {
            print("BARUP \(what) first content: search field \(search.frame), \(search.frame.minY - Self.safeTop) pt under the safe top")
            XCTAssertGreaterThanOrEqual(search.frame.minY, rowBottom, "\(what): the search field \(search.frame) starts above the row's bottom \(rowBottom)")
            return
        }
        let top = app.staticTexts.allElementsBoundByIndex.lazy.filter { $0.exists && $0.isHittable && $0.frame.minY >= Self.safeTop }
            .min { $0.frame.minY < $1.frame.minY }
        print("BARUP \(what) first content: \(top.map { "'\($0.label.prefix(30))' \($0.frame), \($0.frame.minY - Self.safeTop) pt under the safe top" } ?? "none")")
    }

    func testTheRowStandsInTheBandOnEveryPage() throws {
        try launch("dashboard")
        for tab in ["dashboard", "chats", "bots", "files", "kanban", "settings"] {
            let t = element("tab.\(tab)")
            guard t.exists else { print("BARUP \(tab): no tab"); continue }
            t.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5)
            let bottom = checkRow(tab)
            firstContent(tab, rowBottom: bottom)
        }
        // A pushed page: Settings › Troubleshooting, its Back in the band.
        let row = element("settings.row.troubleshooting")
        for _ in 0..<12 where !(row.exists && row.isHittable) {
            let w = app.windows.firstMatch
            w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 0.05,
                thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)), withVelocity: .slow, thenHoldForDuration: 0.3)
            pause(0.8)
        }
        XCTAssertTrue(row.isHittable, "Troubleshooting not reached")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5)
        checkRow("troubleshooting")
        app.terminate()
    }

    func testTheRowFitsAtTheBarsLargestType() throws {
        // The bar's own type stops at XXXL (MorphTopBar's dynamicTypeSize cap): the largest it draws.
        try launch("chats", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
        for tab in ["chats", "bots", "files", "kanban", "settings"] {
            let t = element("tab.\(tab)")
            guard t.exists else { continue }
            t.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5)
            checkRow("xxxl \(tab)", largest: true)
            // Chats held for the script's still of the open display (Matt's package).
            if tab == "chats" { print("BARUP HOLD xxxl-chats"); pause(3) }
            let c = caps()
            if let lead = c["lead"], let mid = c["mid"] { XCTAssertLessThanOrEqual(lead.maxX, mid.minX + 0.5, "xxxl \(tab): the circle meets the title") }
            if let mid = c["mid"], let trail = c["trail"] { XCTAssertLessThanOrEqual(mid.maxX, trail.minX + 0.5, "xxxl \(tab): the title meets the actions") }
            // The title's words inside its capsule (truncated there if long), never past it.
            if let mid = c["mid"], let title = app.staticTexts.allElementsBoundByIndex.first(where: { $0.exists && mid.insetBy(dx: -1, dy: -1).contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }) {
                print("BARUP xxxl \(tab) title '\(title.label)' \(title.frame) in \(mid)")
                XCTAssertLessThanOrEqual(title.frame.maxX, mid.maxX + 1, "xxxl \(tab): the title's words run past its capsule")
            }
        }
        app.terminate()
    }

    /// Scrolls the page down from its top, then a text under the band to hold the page's place by: one whose label
    /// nothing else on screen carries (an open menu can list the same words).
    private func scrolledAnchor(_ what: String) -> (label: String, x: CGFloat, y: CGFloat)? {
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(forDuration: 0.05,
            thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)), withVelocity: .slow, thenHoldForDuration: 0.3)
        pause(1.2)
        let texts = app.staticTexts.allElementsBoundByIndex.filter { $0.exists && !$0.label.isEmpty }
        let counts = Dictionary(texts.map { ($0.label, 1) }, uniquingKeysWith: +)
        let a = texts.filter { $0.isHittable && $0.frame.minY > 200 && counts[$0.label] == 1 }.min { $0.frame.minY < $1.frame.minY }
        print("BARUP \(what) anchor \(a.map { "'\($0.label.prefix(30))' \($0.frame)" } ?? "none") (a label shown once)")
        return a.map { ($0.label, $0.frame.minX, $0.frame.minY) }
    }

    /// The page kept its place: the anchor's text (by its label and its x within 1 pt) still where it was, within 1 pt.
    /// Held for the script's still of the open display first (BARUP HOLD <what>).
    private func keptPlace(_ what: String, _ a: (label: String, x: CGFloat, y: CGFloat)?) {
        print("BARUP HOLD taps-\(what.replacingOccurrences(of: " ", with: "-").lowercased())"); pause(2)
        guard let a else { XCTFail("\(what): VOID: no unique anchor under the band to read the place by"); return }
        let now = app.staticTexts.matching(NSPredicate(format: "label == %@", a.label)).allElementsBoundByIndex
            .first { $0.exists && abs($0.frame.minX - a.x) <= 1 }
        print("BARUP \(what) anchor after '\(a.label.prefix(30))' \(now.map { "\($0.frame)" } ?? "gone")")
        XCTAssertNotNil(now, "\(what): the anchor is gone")
        if let now { XCTAssertEqual(now.frame.minY, a.y, accuracy: 1, "\(what): the page moved (scrolled to its top?)") }
    }

    /// An item of an open menu, as ArchivedFilterUITests reads it: a toggle shows as a button or a switch.
    private func menuItem(_ label: String) -> XCUIElement {
        let button = app.buttons[label].firstMatch
        return button.exists ? button : app.switches[label].firstMatch
    }

    /// Where a menu is closed, with one tap: in the chat list's leading margin (its cards start at x 8), under the band.
    private static let closeX: CGFloat = 4, closeY: CGFloat = 0.6

    /// Closes the open menu with one tap at a neutral point (iOS 27 shows these menus no dismiss region): never its
    /// control again (the menu opens over it), never the band (the status bar's tap could scroll the page). The point is
    /// checked first, from one snapshot, and fails closed: inside any cell, button, switch, text field or tab on screen,
    /// or above the band's bottom, is VOID. The open menu's elements are printed once (information only). A still right
    /// after the tap (BARUP HOLD); the menu's own item (`item`) gone within 2 s, else VOID.
    private func closeMenu(_ item: String, _ what: String) -> Bool {
        let window = app.windows.firstMatch.frame
        let point = CGPoint(x: window.minX + Self.closeX, y: window.minY + window.height * Self.closeY)
        guard let root = try? app.snapshot() else { XCTFail("\(what): VOID: no snapshot to check the close point by"); return false }
        var controls: [(name: String, frame: CGRect)] = [], cellsMinX = CGFloat.infinity, menu: XCUIElementSnapshot?
        func name(_ s: XCUIElementSnapshot) -> String { "\(s.elementType.rawValue) '\(s.identifier)' '\(s.label.prefix(30))'" }
        func walk(_ s: XCUIElementSnapshot, _ path: [XCUIElementSnapshot]) {
            let f = s.frame
            if f.width > 0, f.height > 0, f.intersects(window) {
                switch s.elementType {
                case .cell, .button, .switch, .toggle, .textField, .searchField, .secureTextField, .tab:
                    controls.append((name(s), f))
                    if s.elementType == .cell { cellsMinX = min(cellsMinX, f.minX) }
                default: break
                }
            }
            // The menu: the outermost ancestor of its own item that isn't the whole window.
            if menu == nil, s.label == item, s.elementType == .button || s.elementType == .switch || s.elementType == .cell {
                menu = path.first { $0.frame.width < window.width || $0.frame.height < window.height } ?? s
            }
            for c in s.children { walk(c, path + [s]) }
        }
        walk(root, [])
        if let menu {
            var lines: [String] = []
            func list(_ s: XCUIElementSnapshot) { if lines.count < 40 { lines.append("\(name(s)) \(s.frame)") }; s.children.forEach(list) }
            list(menu)
            print("BARUP \(what) menu elements (\(lines.count)\(lines.count == 40 ? ", the first 40" : "")): \(lines.joined(separator: "; "))")
        } else {
            print("BARUP \(what) menu elements: '\(item)' not found in the snapshot")
        }
        print("BARUP \(what) close point \(point); the list cells' least x \(cellsMinX == .infinity ? "-" : "\(cellsMinX)")")
        let under = controls.filter { $0.frame.contains(point) }
        guard under.isEmpty, point.y > Self.rowBottom else {
            let why = point.y > Self.rowBottom ? under.map { "\($0.name) \($0.frame)" }.joined(separator: ", ") : "above the band's bottom"
            print("BARUP \(what) close point not neutral: \(why)")
            XCTFail("\(what): VOID: close point not neutral (\(why))"); return false
        }
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - window.minX, dy: point.y - window.minY)).tap()
        print("BARUP HOLD taps-\(what.replacingOccurrences(of: " ", with: "-").lowercased())-close")
        let end = Date().addingTimeInterval(2)
        var open = menuItem(item).exists
        while open && Date() < end { pause(0.2); open = menuItem(item).exists }
        pause(1)
        print("BARUP \(what) menu closed by a tap at the close point: \(open ? "STILL OPEN after 2 s" : "closed")")
        // A menu left open makes the place's reading meaningless: that check is void, not passed.
        if open { XCTFail("\(what): VOID: the menu stayed open after the tap at the close point") }
        return !open
    }

    /// The bar's motion between the band and a chat's row (the chat's row stays where it was): Chats, a chat opened and
    /// closed with Back, then Settings › Troubleshooting pushed and popped, each held so the motion can be seen, every step
    /// marked on the wall clock (BARUP MARK) for a recording of the open display. Only with HERMES_E2E_MOTION=1.
    func testTheBarsMotionToAChatAndAPage() throws {
        guard ProcessInfo.processInfo.environment["HERMES_E2E_MOTION"] == "1" else { throw XCTSkip("HERMES_E2E_MOTION not set") }
        try launch("chats")
        func mark(_ what: String) { print("BARUP MARK \(what) wall \(String(format: "%.3f", Date().timeIntervalSince1970))") }
        pause(2); mark("chats")
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup' AND identifier != 'chat.titlePill'")).allElementsBoundByIndex
        let row = try XCTUnwrap(rows.first { $0.exists && $0.isHittable }, "no Disk cleanup row")
        mark("open chat"); row.tap(); pause(3)
        let back = element("chat.back")
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the chat didn't open")
        // The chat's row stays under the band (its seated face needs the room above the pill): printed, not held.
        print("BARUP chat capsules \(caps().sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        mark("chat back"); back.tap(); pause(3)
        XCTAssertTrue(element("tab.chats").isHittable, "Back didn't close the chat")
        element("tab.settings").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(2); mark("settings")
        let t = element("settings.row.troubleshooting")
        for _ in 0..<12 where !(t.exists && t.isHittable) {
            let w = app.windows.firstMatch
            w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 0.05,
                thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)), withVelocity: .slow, thenHoldForDuration: 0.3)
            pause(0.8)
        }
        mark("push troubleshooting"); t.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(3)
        let pageBack = element("page.back")
        XCTAssertTrue(pageBack.waitForExistence(timeout: 10), "Troubleshooting didn't open")
        mark("page back"); pageBack.tap(); pause(3)
        mark("end")
        app.terminate()
    }

    func testTheBandsControlsTakeTaps() throws {
        try launch("chats")
        // Chats: Sort and Filters open their menus.
        for (id, item, own) in [("chats.sort", "Sort", "Recent"), ("chats.filters", "Filters", "Pinned only")] {
            let a = scrolledAnchor(item)
            let b = element(id)
            XCTAssertTrue(b.exists && b.isHittable, "\(item) isn't hittable")
            // The menu's own item mustn't be on the page before it opens, or "open" would read nothing.
            if menuItem(own).exists { XCTFail("\(item): VOID: '\(own)' is on the page before the menu opens"); continue }
            print("BARUP tap \(item) at \(b.frame)")
            b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.2)
            // Open: the menu's own item shown (not any collection view: the chat list is one).
            let opened = app.buttons[own].firstMatch.waitForExistence(timeout: 3) || app.switches[own].firstMatch.exists
            print("BARUP \(item) menu \(opened ? "open: '\(own)' shown" : "not open: no '\(own)'")")
            XCTAssertTrue(opened, "\(item): no menu opened ('\(own)' not shown)")
            guard opened else { continue }
            // The place is read with the menu closed again (its own items can carry a row's words). A menu that won't
            // close leaves the next control nothing fair to read: a still, then a fresh launch for it.
            if closeMenu(own, item) { keptPlace(item, a) } else {
                print("BARUP HOLD taps-\(item.lowercased())"); pause(2)
                app.terminate(); try launch("chats")
            }
        }
        // Bots: New bot opens its page.
        element("tab.bots").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5)
        let a = scrolledAnchor("New bot")
        let newBot = app.buttons["New bot"].firstMatch
        XCTAssertTrue(newBot.exists && newBot.isHittable, "New bot isn't hittable")
        print("BARUP tap New bot at \(newBot.frame)")
        newBot.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5)
        // Its page opens (with Cancel) and Cancel closes it.
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "New bot: its page didn't open (no Cancel)")
        if cancel.exists {
            cancel.tap(); pause(1.2)
            XCTAssertTrue(!cancel.exists && newBot.isHittable, "New bot: Cancel didn't close its page")
        }
        keptPlace("New bot", a)
        // Settings › Troubleshooting: Back pops to Settings.
        element("tab.settings").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5)
        let row = element("settings.row.troubleshooting")
        for _ in 0..<12 where !(row.exists && row.isHittable) {
            let w = app.windows.firstMatch
            w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 0.05,
                thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)), withVelocity: .slow, thenHoldForDuration: 0.3)
            pause(0.8)
        }
        // Back's anchor: the Troubleshooting row itself, where Settings had it.
        let rowY = row.frame.minY
        print("BARUP Back anchor 'settings.row.troubleshooting' \(row.frame)")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5)
        let back = element("page.back")
        XCTAssertTrue(back.exists && back.isHittable, "Back isn't hittable")
        print("BARUP tap Back at \(back.frame)")
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); pause(1.5)
        XCTAssertTrue(row.waitForExistence(timeout: 5) && row.isHittable, "Back didn't pop to Settings")
        print("BARUP Back anchor after \(row.exists ? "\(row.frame)" : "gone")")
        if row.exists { XCTAssertEqual(row.frame.minY, rowY, accuracy: 1, "Back: Settings moved (scrolled to its top?)") }
        app.terminate()
    }

    // MARK: A chat's bar on the Duo, like Messages (#542)

    /// The Duo's pose for the chat tests (HERMES_E2E_POSE): upright and laptop (the bar up in the band), closed (the status
    /// column at the window's side), side and book (the split, the status column at its side).
    private enum Pose: String { case upright, laptop, closed, side, book }
    /// The status column (`TopBarRoom.statusColumnTops`, `VoryTabBar.stripCentreFromEdge`): 44 pt items centred 48 pt from
    /// the window's edge, their tops at these.
    static let columnTops: [String: [CGFloat]] = ["closed": [176, 236], "side": [126], "book": [126]]
    static let columnCentreFromEdge: CGFloat = 48
    /// On its side, the name and the face centred on the status's middle.
    static let sideRowMiddle: CGFloat = 48
    /// Like Messages (Matt, 2026-10-28): the gap between the face and the name, and how far the band's opaque part reaches
    /// under the face, each a quarter of the face's 44 pt (`ChatNameLines.faceGap`, `ChatBand.below`); the band's soft
    /// foot past that (`ChatBand.foot`).
    static let faceNameGap: CGFloat = 11, bandBelow: CGFloat = 11, bandFoot: CGFloat = 4

    /// Opens the chat the script names (HERMES_E2E_CHAT, a words-in-its-row match) from the Chats list, with the frames
    /// readout, VoiceOver's oracle and any extra arguments; in the scheme and text size the script asks for
    /// (HERMES_E2E_SCHEME, HERMES_E2E_SIZE=XXXL). Returns the wall time just before the row's tap.
    @discardableResult private func openChat(_ extra: [String] = []) throws -> TimeInterval {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats",
                               "-colorSchemePreference", e["HERMES_E2E_SCHEME"] ?? "light", "-vory-morph-frames", "-vory-ax-oracle"]
            + (e["HERMES_E2E_SIZE"] == "XXXL" ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"] : []) + extra
        app.launch()
        XCTAssertTrue(element("tab.chats").waitForExistence(timeout: 40), "no tab bar")
        pause(2)
        // HERMES_E2E_ORIENT=landscape (an off-Duo A/B): turned before the chat opens; the frames print the window as it is.
        if e["HERMES_E2E_ORIENT"] == "landscape" { XCUIDevice.shared.orientation = .landscapeLeft; pause(2.5) }
        let words = e["HERMES_E2E_CHAT"].flatMap { $0.isEmpty ? nil : $0 } ?? "Disk cleanup"
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND identifier != 'chat.titlePill'", words)).allElementsBoundByIndex
        let row = try XCTUnwrap(rows.first { $0.exists && $0.isHittable }, "no row with '\(words)'")
        let tapped = Date().timeIntervalSince1970
        row.tap()
        // Open once Chat info is there: beside the list on the Duo's side there's no Back.
        XCTAssertTrue(element("chat.titlePill").waitForExistence(timeout: 20), "the chat didn't open")
        pause(3)
        return tapped
    }

    /// VoiceOver's stops, in order (the oracle's walk, `-vory-ax-oracle`): label and frame.
    private func voiceOverStops() -> [(label: String, frame: CGRect)]? {
        let oracle = element("debug.voiceover")
        guard oracle.waitForExistence(timeout: 5) else { return nil }
        return ((oracle.value as? String) ?? "").split(separator: "\n").compactMap { line in
            guard let bar = line.lastIndex(of: "|") else { return nil }
            let n = line[line.index(after: bar)...].split(separator: ",").compactMap { Double($0) }
            guard n.count == 4 else { return nil }
            return (String(line[..<bar]), CGRect(x: n[0], y: n[1], width: n[2], height: n[3]))
        }
    }

    /// The chat's bar on the Duo like Messages (Matt, 2026-10-28), in the pose the script names (HERMES_E2E_POSE); with
    /// HERMES_E2E_LISTHIDDEN=1 (side or book), after the split's list column is hidden. In every pose:
    /// - Chat info (the face and the name, one button) 44 pt tall (the name alone at XXXL keeps it so), and Back and More
    ///   44 pt or more;
    /// - like Messages (the frames readout's face, name and band): the name 11 pt from the face and centred on it, and the
    ///   band's opaque part reaching 11 pt under the face, each within 1 pt;
    /// - VoiceOver's order Back, Chat info, More, wherever each is;
    /// - the thread, scrolled to its start, beginning under the band (its soft foot included).
    /// Up in the band (upright, laptop): Back, the face's slot and More in the band's row (26 to 70, 1 pt either way; at
    /// XXXL bottoms by 78), ending by 443; Chat info between Back and More, 4 pt clear of each.
    /// Closed: Chat info at the top left; Back and More in the status column (their middles 48 pt from the window's edge,
    /// their tops at 176 and 236). On its side and as a book: Chat info at the pane's top left, centred on y 48; More in the
    /// column (top 126); no Back while the list is beside the chat, and with the list hidden Back at the top left, which
    /// pops the chat. Elsewhere it only prints. Always printed: the frames (CHATFRAMES) and the stops (CHATAX); with
    /// HERMES_E2E_AUDIT=1 the chat screen's audit (AUDIT lines); a hold for a still (BARUP HOLD chat).
    func testTheChatsBarIsLikeMessages() throws {
        let e = ProcessInfo.processInfo.environment
        let pose = Pose(rawValue: e["HERMES_E2E_POSE"] ?? ""), largest = e["HERMES_E2E_SIZE"] == "XXXL"
        let listHidden = e["HERMES_E2E_LISTHIDDEN"] == "1" && (pose == .side || pose == .book)
        try openChat()
        if listHidden {
            let hide = app.buttons["Hide Sidebar"].firstMatch
            try XCTUnwrap(hide.exists ? hide : nil, "no Hide Sidebar on the split").tap()
            pause(2)
        }
        let window = app.windows.firstMatch.frame
        let c = caps()
        let back = element("chat.back"), more = element("chat.more"), info = element("chat.titlePill")
        let frame = { (el: XCUIElement) in el.exists ? el.frame : .zero }
        print("CHATFRAMES \(pose?.rawValue ?? "elsewhere")\(listHidden ? " list hidden" : "") window \(window) capsules "
              + c.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("CHATFRAMES elements back \(frame(back)) info \(frame(info)) more \(frame(more))")
        if let pose {
            XCTAssertEqual(info.frame.height, 44, accuracy: 1, "Chat info \(info.frame) isn't one 44 pt row")
            XCTAssertGreaterThanOrEqual(info.frame.width, 44, "Chat info \(info.frame) under 44 pt")
            XCTAssertTrue(more.exists, "no More")
            // Like Messages (Matt, 2026-10-28): a quarter of the face between it and the name, the name centred on it, and
            // the band reaching a quarter of the face under it.
            if let face = c["face"], let name = c["name"], let band = c["band"] {
                print("CHATFRAMES spacing face \(face) name \(name) band \(band): gap \(name.minX - face.maxX), name middle off \(name.midY - face.midY), band under the face \(band.maxY - face.maxY)")
                XCTAssertEqual(name.minX - face.maxX, Self.faceNameGap, accuracy: 1, "the gap from the face \(face) to the name \(name)")
                XCTAssertEqual(name.midY, face.midY, accuracy: 1, "the name \(name) isn't centred on the face \(face)")
                XCTAssertEqual(band.maxY - face.maxY, Self.bandBelow, accuracy: 1, "the band \(band) isn't a quarter of the face under it \(face)")
            } else { XCTFail("the readout lacks the face, the name or the band: \(c.keys.sorted())") }
            // To the thousandth of a point: a 44 pt circle at x 511.667 reads 43.99999999999994 wide (floating point).
            let side = { (f: CGRect) in (min(f.width, f.height) * 1000).rounded() / 1000 }
            for (name, el) in [("Back", back), ("More", more)] where el.exists {
                XCTAssertGreaterThanOrEqual(side(el.frame), 44, "\(name) \(el.frame) under 44 pt")
            }
            let fromEdge = { (f: CGRect) in min(abs(window.maxX - f.midX), abs(f.midX - window.minX)) }
            switch pose {
            case .upright, .laptop:
                guard let lead = c["lead"], let mid = c["mid"], let trail = c["trail"], let face = c["face"] else {
                    XCTFail("capsules or the face missing: \(c.keys.sorted())"); break
                }
                for (name, f) in [("Back", lead), ("the face's slot", mid), ("More", trail), ("the face", face)] {
                    XCTAssertGreaterThanOrEqual(f.minY, Self.rowTop - Self.slack, "\(name) \(f) above the band's row")
                    XCTAssertLessThanOrEqual(f.maxY, largest ? Self.bandBottom : Self.rowBottom + Self.slack, "\(name) \(f) below the row")
                    XCTAssertLessThanOrEqual(f.maxX, Self.trailingLimit + Self.slack, "\(name) \(f) reaches the status")
                }
                XCTAssertTrue(back.exists, "no Back")
                XCTAssertGreaterThanOrEqual(info.frame.minX - back.frame.maxX, 4, "Chat info \(info.frame) within 4 pt of Back \(back.frame)")
                XCTAssertGreaterThanOrEqual(more.frame.minX - info.frame.maxX, 4, "More \(more.frame) within 4 pt of Chat info \(info.frame)")
            case .closed, .side, .book:
                let tops = Self.columnTops[pose.rawValue] ?? []
                let column = pose == .closed ? [("Back", back), ("More", more)] : [("More", more)]
                for ((name, el), top) in zip(column, tops) {
                    XCTAssertTrue(el.exists, "no \(name) in the status column")
                    XCTAssertEqual(fromEdge(el.frame), Self.columnCentreFromEdge, accuracy: 1, "\(name) \(el.frame) not in the status column")
                    XCTAssertEqual(el.frame.minY, top, accuracy: 1, "\(name) \(el.frame) not under the status at \(top)")
                }
                // Chat info stays clear of the column.
                XCTAssertFalse(info.frame.intersects(more.frame), "Chat info \(info.frame) runs into More \(more.frame)")
                // #549: nothing of the band hangs below More in the column. Its column part, where there is one, ends by
                // More's own bottom, its soft foot and all (the readout's bandColumn).
                let bandColumn = c["bandColumn"]
                print("CHATFRAMES column band \(bandColumn.map { "\($0)" } ?? "none") More \(more.frame)")
                if let bandColumn {
                    XCTAssertLessThanOrEqual(bandColumn.maxY, more.frame.maxY + 0.5, "the column's band \(bandColumn) hangs below More \(more.frame)")
                }
                if pose != .closed {
                    XCTAssertEqual(info.frame.midY, Self.sideRowMiddle, accuracy: 1, "Chat info \(info.frame) not on the status's middle")
                    XCTAssertEqual(back.exists, listHidden, listHidden ? "no Back with the list hidden" : "Back beside the list")
                    if listHidden, back.exists {
                        XCTAssertGreaterThanOrEqual(info.frame.minX - back.frame.maxX, 4, "Chat info \(info.frame) within 4 pt of Back \(back.frame)")
                    }
                    // Every element named Chat info, so a second one can't stand behind `firstMatch`.
                    let infos = app.descendants(matching: .any).matching(identifier: "chat.titlePill").allElementsBoundByIndex.filter(\.exists)
                    print("CHATFRAMES titlePill matches \(infos.count): \(infos.map { "\($0.elementType.rawValue) \($0.frame)" }.joined(separator: ", "))")
                    XCTAssertEqual(infos.count, 1, "Chat info named \(infos.count) times")
                    // The header is one surface: a tap on its empty part, short of the column, opens nothing (no Bot info,
                    // nothing over the chat) and never reaches the thread under the band.
                    let empty = CGVector(dx: more.frame.minX - 74, dy: Self.sideRowMiddle)
                    // The thread's row under the tap's point (or, with none there, the topmost row on screen), read the same way
                    // before and after: a tap that reached the thread (a tool card opening) moves or resizes it. The ids repeat
                    // (every user row is "thread.row.user"), so the row is found by its place, not its id.
                    let tapPoint = CGPoint(x: empty.dx, y: empty.dy)
                    let rowAt = { () -> (how: String, frame: CGRect)? in
                        let rows = self.app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'thread.row.'")).allElementsBoundByIndex
                            .filter { $0.exists && $0.frame.height > 0 }
                        if let r = rows.first(where: { $0.frame.contains(tapPoint) }) { return ("under the tap, \(r.identifier)", r.frame) }
                        return rows.filter { $0.frame.maxY > 0 }.min { $0.frame.minY < $1.frame.minY }.map { ("topmost on screen, \($0.identifier)", $0.frame) }
                    }
                    let rowBefore = rowAt()
                    app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(empty).tap(); pause(1.5)
                    let rowAfter = rowAt()
                    print("CHATFRAMES header tap at \(empty): Bot info \(element("profile.header").exists ? "open" : "closed"), Chat info hittable \(info.isHittable), thread row \(rowBefore.map { "\($0.how) \($0.frame)" } ?? "none") after \(rowAfter.map { "\($0.how) \($0.frame)" } ?? "none")")
                    XCTAssertFalse(element("profile.header").exists, "a tap on the header's empty part opened Bot info")
                    XCTAssertTrue(info.isHittable && more.isHittable, "a tap on the header's empty part covered the chat")
                    if let b = rowBefore {
                        let a = try XCTUnwrap(rowAfter, "no thread row to read after the header tap")
                        XCTAssertEqual(a.how, b.how, "a tap on the header's empty part changed the row read: \(b.how) to \(a.how)")
                        XCTAssertTrue(abs(a.frame.minY - b.frame.minY) <= 0.5 && abs(a.frame.height - b.frame.height) <= 0.5,
                                      "a tap on the header's empty part moved the thread: \(b.frame) to \(a.frame)")
                    } else { XCTFail("no thread row to read before the header tap") }
                }
            }
        }
        // VoiceOver: Back, Chat info, More, in that order wherever they stand.
        if let stops = voiceOverStops() {
            let order = ["Back", "Chat info", "Chat options"].compactMap { name in
                stops.firstIndex { $0.label == name || $0.label.hasPrefix(name + ":") }.map { (name, $0) }
            }
            print("CHATAX \(stops.count) stops: \(stops.map(\.label).joined(separator: " ⟩ "))")
            print("CHATAX header order: \(order.map { "\($0.0) \($0.1)" }.joined(separator: ", "))")
            if pose != nil { XCTAssertEqual(order.map(\.1), order.map(\.1).sorted(), "VoiceOver's order: \(order)") }
        } else { print("CHATAX no oracle") }
        print("BARUP HOLD chat"); pause(3)
        if e["HERMES_E2E_AUDIT"] == "1" {
            var issues = 0
            try app.performAccessibilityAudit { issue in
                issues += 1
                let el = issue.element
                print("AUDIT duo-\(pose?.rawValue ?? "elsewhere") chat \(issue.auditType) '\(el?.identifier ?? "")' '\(el?.label ?? "")' \(el.map { "\($0.frame)" } ?? "-") \(issue.compactDescription)")
                // Printed, not failed here: the gate holds the fix's issues against the base's (as the desk's audit).
                return true
            }
            print("AUDIT duo-\(pose?.rawValue ?? "elsewhere") chat done, \(issues) issues so far")
        }
        if pose != nil {
            // The thread at its start begins under the row (Chat info's bottom; the column beside it runs on down).
            let w = app.windows.firstMatch
            for _ in 0..<12 {
                w.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.35)).press(forDuration: 0.05,
                    thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.9)), withVelocity: .fast, thenHoldForDuration: 0)
                pause(0.6)
            }
            pause(1)
            // Under the band, its soft foot included, where the readout has it; else under the row.
            let rowBottom = c["band"].map { $0.maxY + Self.bandFoot }
                ?? max(info.frame.maxY, back.exists && (pose == .upright || pose == .laptop || listHidden) ? back.frame.maxY : 0)
            let first = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'thread.row.'")).allElementsBoundByIndex
                .filter { $0.exists && $0.frame.height > 0 }.min { $0.frame.minY < $1.frame.minY }
            print("CHATFRAMES thread start \(first.map { "\($0.identifier) \($0.frame)" } ?? "none") row bottom \(rowBottom)")
            if let first { XCTAssertGreaterThanOrEqual(first.frame.minY, rowBottom - 1, "the thread's start \(first.frame) under the band (bottom \(rowBottom))") }
        }
        // With the list hidden, Back pops the chat (the split's empty detail).
        if listHidden, back.exists {
            back.tap(); pause(2)
            XCTAssertTrue(element("chats.noChat").waitForExistence(timeout: 5), "Back didn't pop the chat")
            XCTAssertFalse(info.exists, "Chat info still there after Back")
        }
        app.terminate()
    }

    /// NO TRAVEL between the list and a chat, in the app's own frame log (`-vory-morph-log`: every drawn change of each
    /// capsule and of the face between this test's wall marks, a zero frame where one goes): a chat opened, then Back.
    /// - Up in the band (HERMES_E2E_POSE upright or laptop), strict: Back's circle, the face's slot, More and the face
    ///   keep their vertical middle within 1 pt in every frame.
    /// - Closed: a slot in both states keeps its vertical middle within 1 pt; a slot in one state (it logs a zero frame
    ///   as it goes or before it comes) may appear or go, but never moves: its middle within 1 pt both ways.
    /// Fewer than 10 frames of the slot that changes on every push and pop (the title capsule's up in the band; Back's
    /// in the status column, closed, where the title capsule only goes) didn't sample the motion: VOID, not a pass.
    /// Printed per slot: frames, the middle's least and most (NOTRAVEL); for a slot that moves, its every frame logged
    /// (NOTRAVEL RAW, seconds from the tap). On its side and as a book the list stays beside the chat and nothing morphs
    /// between them: skipped.
    func testNothingTravelsBetweenTheListAndAChat() throws {
        let pose = Pose(rawValue: ProcessInfo.processInfo.environment["HERMES_E2E_POSE"] ?? "")
        guard let pose else { throw XCTSkip("no Duo pose (HERMES_E2E_POSE)") }
        if pose == .side || pose == .book { throw XCTSkip("the split: the list stays beside the chat") }
        let strict = pose == .upright || pose == .laptop
        let t0 = try openChat(["-vory-morph-log"])
        let back = element("chat.back")
        XCTAssertTrue(back.exists, "no Back")
        back.tap(); pause(3)
        let t1 = Date().timeIntervalSince1970
        let log = element("debug.morphlog")
        XCTAssertTrue(log.waitForExistence(timeout: 5), "no frame log")
        var frames: [String: [CGRect]] = [:], times: [String: [Double]] = [:]
        for line in ((log.value as? String) ?? "").split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count == 6, let t = Double(f[0]), t >= t0, t <= t1, let x = Double(f[2]), let y = Double(f[3]),
                  let w = Double(f[4]), let h = Double(f[5]) else { continue }
            frames[String(f[1]), default: []].append(CGRect(x: x, y: y, width: w, height: h))
            times[String(f[1]), default: []].append(t - t0)
        }
        let sampled = strict ? "mid" : "columnBack"
        let slots = strict ? ["lead", "mid", "trail", "face"] : frames.keys.sorted()
        for slot in slots {
            let all = frames[slot] ?? [], drawn = all.filter { $0.width > 0 }
            let ys = drawn.map(\.midY), xs = drawn.map(\.midX)
            let oneState = all.count > drawn.count
            print("NOTRAVEL \(slot): \(all.count) frames (\(all.count - drawn.count) gone), middle y \(ys.min().map { String(format: "%.1f", $0) } ?? "-") to \(ys.max().map { String(format: "%.1f", $0) } ?? "-"), x \(xs.min().map { String(format: "%.1f", $0) } ?? "-") to \(xs.max().map { String(format: "%.1f", $0) } ?? "-")")
            if slot == sampled && all.count < 10 { print("NOTRAVEL VOID \(slot): \(all.count) frames"); XCTFail("VOID: \(slot): only \(all.count) frames logged") }
            let travel = (ys.max() ?? 0) - (ys.min() ?? 0), sideways = !strict && oneState ? (xs.max() ?? 0) - (xs.min() ?? 0) : 0
            XCTAssertLessThanOrEqual(travel, 1, "\(slot): its middle travelled \(ys.min() ?? 0) to \(ys.max() ?? 0)")
            XCTAssertLessThanOrEqual(sideways, 1, "\(slot): a slot in one state moved sideways \(xs.min() ?? 0) to \(xs.max() ?? 0)")
            if travel > 1 || sideways > 1 {
                for (t, f) in zip(times[slot] ?? [], all).prefix(40) {
                    print(String(format: "NOTRAVEL RAW %@ %.3f %.1f %.1f %.1f %.1f", slot, t, f.minX, f.minY, f.width, f.height))
                }
            }
        }
        app.terminate()
    }
}
