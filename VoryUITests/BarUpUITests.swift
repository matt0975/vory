import XCTest

/// #516: on the open iPhone Duo upright (flat, or half open like a laptop) the floating top bar stands up in the status
/// band, clear of the status (`TopBarRoom.barUp`). Checked by the capsules as drawn (`-vory-morph-frames`):
/// - on every root tab and on a pushed Settings page, every capsule inside the band's row (y 26 to 70, 1 pt either way)
///   and ending where UIKit ends its own trailing navigation item (the readout's "system", #554), or by 443 before that
///   has been read; a search field starts under the row; each tab's first content top is printed against the safe
///   area's top, for the record;
/// - at the bar's largest type (XXXL) the title capsule grows to 50 pt, downward from the same top: the row's top still
///   at 26, every capsule's bottom inside the band (78: the band's 82 less 4), none overlapping, all ending by the same, each
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

    /// A tap at the element's centre in the window, where a finger taps. XCTest's own element tap goes to the element's
    /// corner when another element covers its centre in XCTest's snapshot: with #551's taller code block the reply under
    /// the bar covers Back's, and Back's slot takes touches only in its circle, so the corner missed (2026-11-01).
    private func tapCentre(_ e: XCUIElement) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: e.frame.midX, dy: e.frame.midY)).tap()
    }

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

    /// The bar's capsules as drawn ("lead x y w h;mid …;trail …"), without UIKit's own item (`system`).
    private func caps() -> [String: CGRect] {
        var c = readout()
        c.removeValue(forKey: "system")
        return c
    }
    private func readout() -> [String: CGRect] {
        let r = element("debug.morphframes")
        return r.exists ? Duo516UITests.capsules(in: (r.value as? String) ?? "") : [:]
    }
    /// Where UIKit ends its own trailing navigation item, window space (`SystemBarItems`, the readout's "system"): where the
    /// row's last control ends (#554, #555); nil before it has been read.
    private func systemItem() -> CGRect? { readout()["system"] }

    /// Every capsule in the band's row and ending by UIKit's own trailing item, the trailing capsule at it; the row's
    /// bottom. At the bar's largest type (`largest`) the row's top stays at 26 and every capsule's bottom is inside the band
    /// (78) instead.
    @discardableResult private func checkRow(_ what: String, largest: Bool = false) -> CGFloat {
        let c = caps(), system = systemItem()
        let limit = system?.maxX ?? Self.trailingLimit
        print("BARUP \(what) capsules \(c.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) system \(system.map { "\($0)" } ?? "none")")
        if let system, let trail = c["trail"] {
            XCTAssertEqual(trail.maxX, system.maxX, accuracy: Self.slack, "\(what): the trailing capsule \(trail) doesn't end at UIKit's item \(system)")
        }
        XCTAssertFalse(c.isEmpty, "\(what): no capsules")
        if largest, let top = c.values.map(\.minY).min() {
            XCTAssertEqual(top, Self.rowTop, accuracy: Self.slack, "\(what): the row's top \(top), not \(Self.rowTop)")
        }
        for (slot, f) in c {
            XCTAssertGreaterThanOrEqual(f.minY, Self.rowTop - Self.slack, "\(what): \(slot) \(f) above the band's row")
            XCTAssertLessThanOrEqual(f.maxY, largest ? Self.bandBottom : Self.rowBottom + Self.slack,
                                     "\(what): \(slot) \(f) below the \(largest ? "band" : "band's row")")
            XCTAssertLessThanOrEqual(f.maxX, limit + Self.slack, "\(what): \(slot) \(f) reaches the status")
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
        mark("chat back"); tapCentre(back); pause(3)
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
    /// strip at the window's side), side and book (the split, the status strip at its side).
    private enum Pose: String { case upright, laptop, closed, side, book }
    /// The status strip's width, closed and on its side (the safe area's 84 at the window's side): nothing of a chat's in it.
    static let stripWidth: CGFloat = 84
    /// The closed row's top (#558: `TopBarRoom.barPadding`, 11 over the face as the band reaches 11 under it).
    static let closedRowTop: CGFloat = 11
    /// On its side, the name and the face centred on the status's middle.
    static let sideRowMiddle: CGFloat = 48
    /// Like Messages (Matt, 2026-10-28): the gap between the face and the name, and how far the band's opaque part reaches
    /// under the face, each a quarter of the face's 44 pt (`ChatNameLines.faceGap`, `ChatBand.below`); the band's soft
    /// foot past that (`ChatBand.foot`).
    static let faceNameGap: CGFloat = 11, bandBelow: CGFloat = 11, bandFoot: CGFloat = 4

    /// Opens the chat the script names (HERMES_E2E_CHAT, a words-in-its-row match) from the Chats list, with the frames
    /// readout, VoiceOver's oracle and any extra arguments; in the scheme and text size the script asks for
    /// (HERMES_E2E_SCHEME, HERMES_E2E_SIZE=XXXL). Returns the wall time just before the row's tap. With `holdAfterTap`, a
    /// hold for the script's still just after the tap ("BARUP HOLD <name>"); with `voidTag`, a chat that doesn't open is
    /// VOID ("<tag> VOID open: …", a skip) rather than a failure.
    @discardableResult private func openChat(_ extra: [String] = [], holdAfterTap: String? = nil, voidTag: String? = nil) throws -> TimeInterval {
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
        if let holdAfterTap { print("BARUP HOLD \(holdAfterTap)"); pause(1) }
        // Open once Chat info is there: beside the list on the Duo's side there's no Back.
        let opened = element("chat.titlePill").waitForExistence(timeout: 20)
        if !opened, let voidTag { print("\(voidTag) VOID open: the chat didn't open"); throw XCTSkip("VOID: the chat didn't open") }
        XCTAssertTrue(opened, "the chat didn't open")
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
    /// XXXL bottoms by 78), More ending where UIKit ends its own trailing item (the readout's "system", #554); Chat info
    /// between Back and More, 4 pt clear of each.
    /// Closed: the face and the name at the top left, 11 pt from the window's top (#558), clear of the strip; Back over More
    /// in the strip (#555), each centred on the marker the system laid out for it there under the status (the readout's
    /// markerBack and markerMore), nothing of the band below More (#549). On its side and as a book: Chat info at the pane's
    /// top left, centred on y 48; More in the strip on its marker; no Back (and no Back marker) while the list is beside the
    /// chat, and with the list hidden Back in the strip on its own marker over More, which pops the chat. Elsewhere it only prints. Always printed: the frames (CHATFRAMES) and the stops (CHATAX); with
    /// HERMES_E2E_AUDIT=1 the chat screen's audit (AUDIT lines); a hold for a still (BARUP HOLD chat).
    func testTheChatsBarIsLikeMessages() throws {
        let e = ProcessInfo.processInfo.environment
        let pose = Pose(rawValue: e["HERMES_E2E_POSE"] ?? ""), largest = e["HERMES_E2E_SIZE"] == "XXXL"
        let listHidden = e["HERMES_E2E_LISTHIDDEN"] == "1" && (pose == .side || pose == .book)
        try openChat()
        if listHidden {
            let hide = app.buttons["Hide Sidebar"].firstMatch
            try XCTUnwrap(hide.exists ? hide : nil, "no Hide Sidebar beside the list with a chat open").tap()
            pause(2)
        }
        let window = app.windows.firstMatch.frame
        let c = caps(), system = systemItem()
        let back = element("chat.back"), more = element("chat.more"), info = element("chat.titlePill")
        let frame = { (el: XCUIElement) in el.exists ? el.frame : .zero }
        print("CHATFRAMES \(pose?.rawValue ?? "elsewhere")\(listHidden ? " list hidden" : "") window \(window) capsules "
              + c.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("CHATFRAMES elements back \(frame(back)) info \(frame(info)) more \(frame(more)) system \(system.map { "\($0)" } ?? "none")")
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
            let atSystem = { (name: String, f: CGRect) in
                if let system { XCTAssertEqual(f.maxX, system.maxX, accuracy: Self.slack, "\(name) \(f) doesn't end at UIKit's item \(system)") }
                else { XCTFail("VOID: UIKit's item not in the readout") }
            }
            let clearOfStrip = { (name: String, f: CGRect) in
                XCTAssertLessThanOrEqual(f.maxX, window.maxX - Self.stripWidth + Self.slack, "\(name) \(f) in the strip")
            }
            // #555: in the strip, centred on the marker the system laid out for it there (the readout's markerBack or
            // markerMore), under the status and moving down with it as Live Activities arrive.
            let atMarker = { (name: String, f: CGRect, key: String) in
                XCTAssertGreaterThanOrEqual(f.minX, window.maxX - Self.stripWidth - Self.slack, "\(name) \(f) not in the strip")
                if let m = c[key] {
                    XCTAssertEqual(f.midX, m.midX, accuracy: Self.slack, "\(name) \(f) not centred on its marker \(m)")
                    XCTAssertEqual(f.midY, m.midY, accuracy: Self.slack, "\(name) \(f) not centred on its marker \(m)")
                } else { XCTFail("VOID: the readout has no \(key)") }
            }
            // #618: closed, More stands the app's pitch (the readout's stripPitch, its width) under Back's marker, on its own
            // marker's line: closer than the system's two groups stand them, the 44 pt circles clear of each other.
            let atPitch = { (name: String, f: CGRect) in
                guard let mb = c["markerBack"], let mm = c["markerMore"], let p = c["stripPitch"]?.width else {
                    XCTFail("VOID: the readout has no markerBack, markerMore or stripPitch"); return
                }
                XCTAssertTrue(p >= 44 && p < 70, "the pitch \(p) isn't from 44 to under 70")
                XCTAssertEqual(f.midX, mm.midX, accuracy: Self.slack, "\(name) \(f) not on its marker's line \(mm)")
                XCTAssertEqual(f.midY, mb.midY + p, accuracy: Self.slack, "\(name) \(f) not \(p) under Back's marker \(mb)")
            }
            // #555: the markers' own views hidden and out of the hit test, every laid-out one (the readout's stripHide: found,
            // laid out), so the taps reach our Back and More.
            let hiddenCheck = {
                if let h = c["stripHide"] {
                    print("CHATFRAMES stripHide found \(Int(h.minX)) of \(Int(h.minY))")
                    XCTAssertGreaterThan(h.minY, 0, "no marker laid out to hide")
                    XCTAssertEqual(h.minX, h.minY, "only \(Int(h.minX)) of \(Int(h.minY)) markers' views found and hidden")
                } else { XCTFail("VOID: the readout has no stripHide") }
            }
            // #549: nothing of the band hangs below More in the column; its column part, where there is one, ends by More's
            // own bottom, its soft foot and all (the readout's bandColumn).
            let bandColumnCheck = {
                let bandColumn = c["bandColumn"]
                print("CHATFRAMES column band \(bandColumn.map { "\($0)" } ?? "none") More \(more.frame)")
                if let bandColumn {
                    XCTAssertLessThanOrEqual(bandColumn.maxY, more.frame.maxY + 0.5, "the column's band \(bandColumn) hangs below More \(more.frame)")
                }
            }
            switch pose {
            case .upright, .laptop:
                guard let lead = c["lead"], let mid = c["mid"], let trail = c["trail"], let face = c["face"] else {
                    XCTFail("capsules or the face missing: \(c.keys.sorted())"); break
                }
                for (name, f) in [("Back", lead), ("the face's slot", mid), ("More", trail), ("the face", face)] {
                    XCTAssertGreaterThanOrEqual(f.minY, Self.rowTop - Self.slack, "\(name) \(f) above the band's row")
                    XCTAssertLessThanOrEqual(f.maxY, largest ? Self.bandBottom : Self.rowBottom + Self.slack, "\(name) \(f) below the row")
                    XCTAssertLessThanOrEqual(f.maxX, (system?.maxX ?? Self.trailingLimit) + Self.slack, "\(name) \(f) reaches the status")
                }
                atSystem("More", trail)
                XCTAssertTrue(back.exists, "no Back")
                XCTAssertGreaterThanOrEqual(info.frame.minX - back.frame.maxX, 4, "Chat info \(info.frame) within 4 pt of Back \(back.frame)")
                XCTAssertGreaterThanOrEqual(more.frame.minX - info.frame.maxX, 4, "More \(more.frame) within 4 pt of Chat info \(info.frame)")
            case .closed:
                guard let face = c["face"] else { XCTFail("the face missing: \(c.keys.sorted())"); break }
                // #558: 11 over the face, as the band reaches 11 under it (checked above); the face and the name at the top
                // left, clear of the strip.
                XCTAssertEqual(face.minY, Self.closedRowTop, accuracy: Self.slack, "the face \(face) isn't \(Self.closedRowTop) pt from the top")
                clearOfStrip("Chat info", info.frame)
                // #555: Back over More in the strip, Back on its marker; #618: More the app's pitch under it.
                XCTAssertTrue(back.exists, "no Back")
                atMarker("Back", back.frame, "markerBack")
                atPitch("More", more.frame)
                XCTAssertLessThanOrEqual(back.frame.maxY, more.frame.minY, "Back \(back.frame) not over More \(more.frame)")
                bandColumnCheck()
                hiddenCheck()
            case .side, .book:
                // #555: More in the strip, on its marker, under the status; with the list hidden Back over it on its own
                // marker, and beside the list no Back and no Back marker (More stands in Back's place, as the system's does).
                atMarker("More", more.frame, "markerMore")
                XCTAssertFalse(info.frame.intersects(more.frame), "Chat info \(info.frame) runs into More \(more.frame)")
                bandColumnCheck()
                hiddenCheck()
                do {
                    XCTAssertEqual(info.frame.midY, Self.sideRowMiddle, accuracy: 1, "Chat info \(info.frame) not on the status's middle")
                    XCTAssertEqual(back.exists, listHidden, listHidden ? "no Back with the list hidden" : "Back beside the list")
                    if listHidden, back.exists {
                        atMarker("Back", back.frame, "markerBack")
                        XCTAssertLessThanOrEqual(back.frame.maxY, more.frame.minY, "Back \(back.frame) not over More \(more.frame)")
                        if let mb = c["markerBack"], let mm = c["markerMore"] {
                            XCTAssertLessThan(mb.minY, mm.minY, "Back's marker \(mb) not in the first slot, over More's \(mm)")
                        }
                        // The split's sidebar toggle isn't on the chat's page: it drew over the face there.
                        XCTAssertFalse(app.buttons["Show Sidebar"].exists, "the split's Show Sidebar is on the chat's page")
                    } else if !listHidden {
                        XCTAssertNil(c["markerBack"], "a Back marker beside the list: \(c["markerBack"].map { "\($0)" } ?? "")")
                        // The list's own toggle stays beside the chat (#555 takes it off only while the list is hidden).
                        XCTAssertTrue(app.buttons["Hide Sidebar"].exists, "no Hide Sidebar beside the list with a chat open")
                        // And its own width: 380 on its side, so Chat info starts at 396, as before the toggle's move
                        // (once lost to the system's 320, 2026-11-01). As a book the list ends at the fold instead.
                        if pose == .side {
                            XCTAssertEqual(info.frame.minX, 396, accuracy: 1, "Chat info \(info.frame): the list beside it isn't 380 wide")
                        }
                    }
                    // Every element named Chat info, so a second one can't stand behind `firstMatch`.
                    let infos = app.descendants(matching: .any).matching(identifier: "chat.titlePill").allElementsBoundByIndex.filter(\.exists)
                    print("CHATFRAMES titlePill matches \(infos.count): \(infos.map { "\($0.elementType.rawValue) \($0.frame)" }.joined(separator: ", "))")
                    XCTAssertEqual(infos.count, 1, "Chat info named \(infos.count) times")
                    // The header is one surface: a tap on its empty part, short of the column, opens nothing (no Bot info,
                    // nothing over the chat) and never reaches the thread under the band. The empty part is the gap between
                    // Chat info and More, tapped at its middle on the row: not a fixed distance short of More, which (#554)
                    // stands at UIKit's item, nearer the pill, so a long title's pill can run past that distance. A bar
                    // without a 44 pt gap there has no empty part to tap, and fails here by name.
                    let gap = more.frame.minX - info.frame.maxX
                    XCTAssertGreaterThanOrEqual(gap, 44, "no 44 pt of empty header between Chat info \(info.frame) and More \(more.frame)")
                    let empty = CGVector(dx: (info.frame.maxX + more.frame.minX) / 2, dy: Self.sideRowMiddle)
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
                    print("CHATFRAMES header tap at \(empty), gap \(gap): Bot info \(element("profile.header").exists ? "open" : "closed"), Chat info hittable \(info.isHittable), thread row \(rowBefore.map { "\($0.how) \($0.frame)" } ?? "none") after \(rowAfter.map { "\($0.how) \($0.frame)" } ?? "none")")
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
        } else {
            // #555's toggle comes off only on the Duo's side. Off it, which one stands is printed on every run (a phone in
            // landscape included, the base's beside the fix's), and the iPad's split keeps its own.
            let show = app.buttons["Show Sidebar"].exists, hide = app.buttons["Hide Sidebar"].exists
            print("CHATFRAMES toggle: \(show && hide ? "Show and Hide" : show ? "Show" : hide ? "Hide" : "none")")
            if UIDevice.current.userInterfaceIdiom == .pad {
                XCTAssertTrue(show || hide, "the iPad's split lost its sidebar toggle")
                // The list keeps its own width beside the chat: 344 on the 820 pt window, so Back starts at 360 (once lost to
                // the system's 320, 2026-11-01).
                if window.width == 820 {
                    XCTAssertEqual(back.frame.minX, 360, accuracy: 1, "Back \(back.frame): the list beside it isn't 344 wide")
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
        // #555: on its side and as a book, beside the list and with it hidden: More, taken by the catcher over the system's
        // floating bar, opens its menu where the page's More stands (its first item's frame printed, and a still), and
        // Rename from it opens one dialog; a long press on Chat info (no catcher there) opens its own menu, whose Rename
        // opens one dialog too.
        let rename = app.buttons["Rename chat"].firstMatch
        let renameOnce = { (from: String) in
            rename.tap()
            let fields = self.app.textFields.matching(identifier: "rename.name")
            XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 3), "\(from) opened no Rename dialog")
            XCTAssertEqual(fields.count, 1, "\(from) opened \(fields.count) Rename dialogs")
            self.app.buttons["Cancel"].firstMatch.tap()
            XCTAssertTrue(fields.firstMatch.waitForNonExistence(timeout: 3), "\(from)'s Rename dialog didn't close")
            self.pause(1)
        }
        // More's menu open: More's frame while it shows (the press look holds then, closed and on its side alike), the
        // menu's first item and Rename's frames, and a still.
        // More's own side: 44 pt, and the closed column's circle of 48 (#671, `TopBarRoom.columnSide`).
        let moreSide: CGFloat = pose == .closed ? 48 : 44
        let moreMenu = { (how: String) in
            let first = self.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model:'")).firstMatch
            print("CHATFRAMES more menu \(how): More \(more.frame), first item "
                  + (first.exists ? "\(first.label) \(first.frame)" : "not found") + ", Rename chat \(rename.frame)")
            print("BARUP HOLD more-menu"); self.pause(2)
            // No press look while the menu shows, closed and on its side alike: More at its own side, not grown.
            XCTAssertEqual(more.frame.width, moreSide, accuracy: 0.5, "More \(more.frame) grown while its menu shows (\(how))")
        }
        // More after its menu has gone (Rename's dialog and Cancel): at its own side again.
        let moreAfter = { (how: String) in
            print("CHATFRAMES More after its menu: \(more.frame)")
            XCTAssertEqual(more.frame.width, moreSide, accuracy: 0.5, "More \(more.frame) grown after its menu (\(how))")
        }
        if pose == .side || pose == .book, more.exists {
            more.tap()
            if rename.waitForExistence(timeout: 3) {
                moreMenu(listHidden ? "list hidden" : "beside the list")
                renameOnce("More's Rename")
                moreAfter(listHidden ? "list hidden" : "beside the list")
            } else { XCTFail("More didn't open its menu") }
            // Chat info's long press opens its menu (nothing covers Chat info), and a Rename dialog that comes is exactly one.
            // A Rename tap that's lost, the menu staying open with the tap's selection gone ("System gesture gate timed out"
            // in the app's log), happens on 44 too (2026-10-31): it's printed and the menu closed, not failed.
            info.press(forDuration: 0.8)
            if rename.waitForExistence(timeout: 3) {
                rename.tap()
                let fields = app.textFields.matching(identifier: "rename.name")
                if fields.firstMatch.waitForExistence(timeout: 3) {
                    XCTAssertEqual(fields.count, 1, "Chat info's Rename opened \(fields.count) Rename dialogs")
                    app.buttons["Cancel"].firstMatch.tap()
                    XCTAssertTrue(fields.firstMatch.waitForNonExistence(timeout: 3), "Chat info's Rename dialog didn't close")
                    pause(1)
                } else {
                    print("CHATFRAMES pill Rename lost (44 too)")
                    // Away from the menu (it hangs under Chat info at the top left), then Escape if it's still up.
                    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.12)).tap()
                    if !rename.waitForNonExistence(timeout: 2) { app.typeKey(XCUIKeyboardKey.escape, modifierFlags: []) }
                    print("CHATFRAMES pill menu after the lost tap: \(rename.waitForNonExistence(timeout: 2) ? "closed" : "STILL OPEN")")
                    pause(1)
                }
            } else { XCTFail("a long press on Chat info didn't open its menu") }
        }
        // #555: closed, More's menu the same way (MorphBarHost's More, over the stacks), and Rename from it opens one dialog.
        if pose == .closed, more.exists {
            more.tap()
            if rename.waitForExistence(timeout: 3) {
                moreMenu("closed")
                renameOnce("More's Rename")
                moreAfter("closed")
            } else { XCTFail("More didn't open its menu") }
        }
        // With the list hidden, Back pops the chat (the split's empty detail).
        if listHidden, back.exists {
            tapCentre(back); pause(2)
            XCTAssertTrue(element("chats.noChat").waitForExistence(timeout: 5), "Back didn't pop the chat")
            XCTAssertFalse(info.exists, "Chat info still there after Back")
            // #555: the list's own controls answer after the pop: the empty detail's Show Sidebar brings it back.
            let show = app.buttons["Show Sidebar"].firstMatch
            if show.waitForExistence(timeout: 2) {
                show.tap(); pause(1.5)
                XCTAssertTrue(app.buttons["Hide Sidebar"].firstMatch.waitForExistence(timeout: 3), "the list didn't come back after the pop")
            } else { print("CHATFRAMES no Show Sidebar on the empty detail") }
        }
        // #555: closed, after Back pops the chat the list's own bar takes touches again (the markers' bar gave them up while
        // the chat showed): its search takes the tap. With no search field on the list (the closed Duo since #591), the
        // system's Search button at the strip's foot takes it and opens the field.
        if pose == .closed, back.exists {
            back.tap(); pause(2)
            let button = app.buttons.matching(NSPredicate(format: "label ==[c] 'Search'")).firstMatch
            if !app.searchFields.firstMatch.waitForExistence(timeout: 2) {
                XCTAssertTrue(button.waitForExistence(timeout: 5), "no search field and no Search button on the list after Back")
                button.tap(); pause(1)
            }
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5), "no search field on the list after Back")
            if !app.keyboards.firstMatch.exists { search.tap(); pause(1) }
            XCTAssertTrue(app.keyboards.firstMatch.exists, "the list's search didn't take the tap after Back")
        }
        app.terminate()
    }

    /// #554: the Chats list's trailing capsule from the first frame drawn at launch, in the app's own frame log
    /// (`-vory-morph-log`), in the pose the script names (HERMES_E2E_POSE, the bar up in the band or closed): it stands where
    /// it ends, at UIKit's own trailing item (the readout's "system"), remembered from the last launch in the same window
    /// shape, so it never steps sideways once the bar is read. A launch in a shape never read may step (nothing remembered
    /// yet): with HERMES_E2E_LAUNCH_STRICT=1 (the second launch of a pair) the right edge holds within 1 pt in every frame
    /// and ends at UIKit's item. Printed: the frames (LAUNCH, and LAUNCH RAW for every one when it steps); a hold for a still.
    func testTheRowHoldsStillFromLaunch() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        guard let pose = Pose(rawValue: e["HERMES_E2E_POSE"] ?? ""), pose == .upright || pose == .laptop || pose == .closed else {
            throw XCTSkip("no pose with the bar in the band or closed (HERMES_E2E_POSE)")
        }
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats",
                               "-colorSchemePreference", "light", "-vory-morph-frames", "-vory-morph-log"]
        let t0 = Date().timeIntervalSince1970
        app.launch()
        XCTAssertTrue(element("tab.chats").waitForExistence(timeout: 40), "no tab bar")
        pause(3)
        let log = element("debug.morphlog")
        XCTAssertTrue(log.waitForExistence(timeout: 5), "no frame log")
        var trail: [(t: Double, f: CGRect)] = []
        for line in ((log.value as? String) ?? "").split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count >= 6, f[1] == "trail", let t = Double(f[0]), t >= t0, let x = Double(f[2]), let y = Double(f[3]),
                  let w = Double(f[4]), let h = Double(f[5]), w > 0 else { continue }
            trail.append((t - t0, CGRect(x: x, y: y, width: w, height: h)))
        }
        let edges = trail.map(\.f.maxX), system = systemItem()
        let step = (edges.max() ?? 0) - (edges.min() ?? 0)
        print("LAUNCH \(pose.rawValue) trail \(trail.count) frames, right edge \(edges.min().map { String(format: "%.1f", $0) } ?? "-") to \(edges.max().map { String(format: "%.1f", $0) } ?? "-"), last \(edges.last.map { String(format: "%.1f", $0) } ?? "-"), system \(system.map { "\($0)" } ?? "none")")
        if step > 1 { for (t, f) in trail.prefix(40) { print(String(format: "LAUNCH RAW trail %.3f %.1f %.1f %.1f %.1f", t, f.minX, f.minY, f.width, f.height)) } }
        // The launch probe (#554): what the bar placed its row from, UIKit's item as it was read, and the bar's own frame,
        // from launch.
        for line in ((log.value as? String) ?? "").split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2)
            guard f.count == 3, ["barstate", "sysitem", "barhost", "mtrail"].contains(f[1]), let t = Double(f[0]), t >= t0 else { continue }
            print(String(format: "LAUNCH STATE %.3f ", t - t0) + "\(f[1]) \(f[2])")
        }
        if e["HERMES_E2E_LAUNCH_STRICT"] == "1" {
            XCTAssertFalse(trail.isEmpty, "VOID: no trailing capsule logged from launch")
            XCTAssertLessThanOrEqual(step, 1, "the trailing capsule stepped sideways at launch: right edge \(edges.min() ?? 0) to \(edges.max() ?? 0)")
            if let system, let last = edges.last { XCTAssertEqual(last, system.maxX, accuracy: Self.slack, "the trailing capsule ends at \(last), not at UIKit's item \(system)") }
            else { XCTFail("VOID: UIKit's item not in the readout") }
        }
        print("BARUP HOLD launch"); pause(3)
        app.terminate()
    }

    /// NO TRAVEL between the list and a chat, in the app's own frame log (`-vory-morph-log`: every drawn change of each
    /// capsule and of the face between this test's wall marks, a zero frame where one goes): a chat opened, then Back.
    /// - Up in the band (HERMES_E2E_POSE upright or laptop), strict: Back's circle, the face's slot, More and the face
    ///   keep their vertical middle within 1 pt in every frame.
    /// - Closed (#555, as 44 stood them): a slot in both states keeps its vertical middle within 1 pt; a slot in one state
    ///   (it logs a zero frame as it goes or before it comes: the list's title and trailing capsules, a chat's Back and More
    ///   in the status column) may appear or go, but never moves: its middle within 1 pt both ways.
    /// Fewer than 10 frames of the slot that changes on every push and pop (the title capsule's, up in the band) didn't
    /// sample the motion: VOID, not a pass. Closed, Back and More grow and shrink where they stand (a scale, not a frame:
    /// they log only as they come and go), so there the log must hold a drawn frame of both column slots, else VOID.
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
        tapCentre(back); pause(3)
        let t1 = Date().timeIntervalSince1970
        // Back popped the chat: a Back that missed leaves fewer frames than the morph's and could pass as still.
        XCTAssertFalse(element("chat.back").exists || element("chat.titlePill").exists, "Back didn't pop the chat")
        let log = element("debug.morphlog")
        XCTAssertTrue(log.waitForExistence(timeout: 5), "no frame log")
        var frames: [String: [CGRect]] = [:], times: [String: [Double]] = [:]
        for line in ((log.value as? String) ?? "").split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count >= 6, let t = Double(f[0]), t >= t0, t <= t1, let x = Double(f[2]), let y = Double(f[3]),
                  let w = Double(f[4]), let h = Double(f[5]) else { continue }
            frames[String(f[1]), default: []].append(CGRect(x: x, y: y, width: w, height: h))
            times[String(f[1]), default: []].append(t - t0)
        }
        let sampled = strict ? "mid" : nil
        // The capsules and the face only: the log also holds the bar host's frame and the strip's markers, which aren't slots.
        let slots = strict ? ["lead", "mid", "trail", "face"] : ["lead", "mid", "trail", "face", "columnBack", "columnMore"]
        if !strict {
            for slot in ["columnBack", "columnMore"] where !(frames[slot] ?? []).contains(where: { $0.width > 0 }) {
                print("NOTRAVEL VOID \(slot): never drawn"); XCTFail("VOID: \(slot): never drawn in the log")
            }
        }
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

    /// The bar's frame log (`-vory-morph-log`, "debug.morphlog"): each "<wall time> <name> x y w h <scene>" line, in order.
    /// `inFront`: without the lines drawn with the scene in the background (the switcher's picture and other layouts while
    /// the app is away, 2026-11-01); those drawn on the way in or out still count.
    private func frameLog(inFront: Bool = false) -> [(t: Double, name: String, f: CGRect)] {
        let log = element("debug.morphlog")
        guard log.waitForExistence(timeout: 5) else { return [] }
        return ((log.value as? String) ?? "").split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ")
            guard f.count >= 6, let t = Double(f[0]), let x = Double(f[2]), let y = Double(f[3]), let w = Double(f[4]),
                  let h = Double(f[5]), !(inFront && f.count > 6 && f[6] == "background") else { return nil }
            return (t, String(f[1]), CGRect(x: x, y: y, width: w, height: h))
        }
    }

    /// More's menu opens with Rename, whose dialog comes once and goes again (`how`, for the messages).
    private func moreMenuOnce(_ more: XCUIElement, _ how: String) {
        more.tap()
        let rename = app.buttons["Rename chat"].firstMatch
        guard rename.waitForExistence(timeout: 3) else { XCTFail("\(how): More didn't open its menu"); return }
        rename.tap()
        let fields = app.textFields.matching(identifier: "rename.name")
        XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 3), "\(how): More's Rename opened no dialog")
        XCTAssertEqual(fields.count, 1, "\(how): More's Rename opened \(fields.count) dialogs")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(fields.firstMatch.waitForNonExistence(timeout: 3), "\(how): the Rename dialog didn't close")
        pause(1)
    }

    /// A control following the system's own move, from `from` to `to` (the marker's places at rest and with the activity,
    /// window space), in its logged frames. The event is the system's first read at the new place (`reads`, the marker's
    /// reads in the log, its top at `to`'s within 1 pt); the control's first frame off its place comes within 0.5 s of it
    /// and its arrival within 1.1 s (the 250 ms settle, and slack; both printed). It may animate: between the two places
    /// every frame lies between them and only moves toward `to`, at most 0.6 s from its first frame off its place to its
    /// arrival, and once there it stays. A control drawn a fixed distance under the system's place (`shift`: closed More,
    /// the app's pitch under Back's marker, #618) follows that place's reads, that far under it.
    private func followsSystem(_ name: String, _ frames: [(t: Double, name: String, f: CGRect)], reads: [(t: Double, name: String, f: CGRect)],
                               from: CGRect, to: CGRect, _ stage: String, shift: CGFloat = 0) {
        guard let event = reads.first(where: { abs($0.f.minY - to.minY) <= 1 }) else {
            print("LAMID \(stage) \(name): no read of the system's place at \(to.minY): " + reads.map { String(format: "%.0f", $0.f.minY) }.joined(separator: " "))
            XCTFail("\(stage): no read of the system's \(name) at \(to.minY)"); return
        }
        let fromMid = from.midY + shift, toMid = to.midY + shift
        print("LAMID \(stage) \(name): \(frames.count) frames, middles (s from the system's read) "
              + frames.map { String(format: "%.1f@%+.3f", $0.f.midY, $0.t - event.t) }.joined(separator: " "))
        guard let off = frames.firstIndex(where: { abs($0.f.midY - fromMid) > 1 }) else { XCTFail("\(stage): \(name) never left \(fromMid)"); return }
        guard let there = frames.firstIndex(where: { abs($0.f.midY - toMid) <= 1 }) else { XCTFail("\(stage): \(name) never reached \(toMid)"); return }
        let leaves = frames[off].t - event.t, arrives = frames[there].t - event.t
        print(String(format: "LAMID %@ %@: off its place %+.3f s and at the new one %+.3f s after the system's read", stage, name, leaves, arrives))
        XCTAssertGreaterThanOrEqual(leaves, -0.1, "\(stage): \(name) moved \(leaves) s before the system's read")
        XCTAssertLessThanOrEqual(leaves, 0.5, "\(stage): \(name) off its place \(leaves) s after the system's read")
        XCTAssertLessThanOrEqual(arrives, 1.1, "\(stage): \(name) at its new place \(arrives) s after the system's read")
        XCTAssertLessThanOrEqual(frames[there].t - frames[off].t, 0.6, "\(stage): \(name) took \(frames[there].t - frames[off].t) s to move")
        // In between: within the two places, only toward `to` (1 pt of noise), no overshoot.
        let lo = min(fromMid, toMid) - 1, hi = max(fromMid, toMid) + 1
        var gap = abs(fromMid - toMid)
        for f in frames[off...there] {
            let m = f.f.midY, d = abs(m - toMid)
            XCTAssertTrue(m >= lo && m <= hi, "\(stage): \(name) drawn at \(m), outside \(fromMid) to \(toMid)")
            XCTAssertLessThanOrEqual(d, gap + 1, "\(stage): \(name) went back, at \(m)")
            gap = min(gap, d)
        }
        XCTAssertTrue(frames[there...].allSatisfy { abs($0.f.midY - toMid) <= 1 }, "\(stage): \(name) left \(toMid) again")
    }

    /// #555: another app's Live Activity starting and ending while a chat is open, closed or on its side (HERMES_E2E_POSE),
    /// with the bar's frame log. At "BARUP HOLD la-start" the script brings the full app (com.vorantx.vory, its build whose
    /// extension draws one) to the front to start it and quits it; the test waits for it to come and go, then brings the
    /// copy back to the same chat; then the same at "BARUP HOLD la-end" to end it. (The full app launched from the test
    /// itself never asked for one, 2026-11-01.) Read at rest (A0), with the activity (A1) and after it (A2), each once the
    /// system's marker has moved (up to 10 s): the markers lower by the activity's push in A1 and back in A2, Back and More
    /// on them within 1 pt each time (closed, More the app's pitch under Back's marker, #618), and at A1 More's menu opens
    /// and its Rename gives one dialog. From the log, each
    /// control follows the system's own move (`followsSystem`): timed from the system's first read at its new place, it
    /// may animate. The copy's return is printed, for information. The copy not back on the same chat (relaunched, or the
    /// chat gone), or the markers not moved by the activity, is VOID ("LAMID VOID …"), not a failure.
    func testTheStripFollowsALiveActivityMidChat() throws {
        let pose = Pose(rawValue: ProcessInfo.processInfo.environment["HERMES_E2E_POSE"] ?? "")
        guard let pose, pose == .closed || pose == .side else { throw XCTSkip("closed or on its side only (HERMES_E2E_POSE)") }
        // A still just after the row's tap, and a chat that doesn't open is VOID (once seen closed, 2026-11-01).
        try openChat(["-vory-morph-log"], holdAfterTap: "lamid-open", voidTag: "LAMID")
        let back = element("chat.back"), more = element("chat.more"), info = element("chat.titlePill")
        // Closed, the root bar's column; on its side beside the list, the header's More alone.
        let slots: [(name: String, slot: String, marker: String, read: String, el: XCUIElement)] = pose == .closed
            ? [("Back", "columnBack", "markerBack", "markerReadBack", back), ("More", "columnMore", "markerMore", "markerReadMore", more)]
            : [("More", "sideMore", "markerMore", "markerReadMore", more)]
        let read = { (stage: String) -> [String: CGRect] in
            let c = self.caps()
            for s in slots { print("LAMID \(stage) \(s.name) \(s.el.exists ? "\(s.el.frame)" : "none") marker \(c[s.marker].map { "\($0)" } ?? "none")") }
            return c
        }
        // #618: closed, More stands the app's pitch (the readout's stripPitch) under Back's marker, and follows Back's.
        let pitch = caps()["stripPitch"]?.width ?? 0
        if pose == .closed, pitch < 44 { print("LAMID VOID: no stripPitch in the readout"); throw XCTSkip("VOID: no stripPitch") }
        let onMarkers = { (stage: String, c: [String: CGRect]) in
            for s in slots {
                guard let m = c[s.marker], s.el.exists else { XCTFail("\(stage): \(s.name) or its marker missing"); continue }
                XCTAssertEqual(s.el.frame.midX, m.midX, accuracy: 1, "\(stage): \(s.name) \(s.el.frame) not centred on its marker \(m)")
                if pose == .closed, s.name == "More" {
                    guard let mb = c["markerBack"] else { XCTFail("\(stage): Back's marker missing"); continue }
                    XCTAssertEqual(s.el.frame.midY, mb.midY + pitch, accuracy: 1, "\(stage): More \(s.el.frame) not \(pitch) under Back's marker \(mb)")
                } else {
                    XCTAssertEqual(s.el.frame.midY, m.midY, accuracy: 1, "\(stage): \(s.name) \(s.el.frame) not centred on its marker \(m)")
                }
            }
        }
        // Up to 10 s for the first marker to stand where `ok` says, then 1.5 s for the controls to follow; whether it did.
        let waitForSystem = { (ok: (CGRect) -> Bool) -> Bool in
            for _ in 0..<20 {
                if let m = self.caps()[slots[0].marker], ok(m) { self.pause(1.5); return true }
                self.pause(0.5)
            }
            return false
        }
        let a0 = read("A0")
        onMarkers("A0", a0)
        guard let m0 = a0[slots[0].marker] else { print("LAMID VOID A0: no marker"); throw XCTSkip("VOID: no marker at rest") }
        let full = XCUIApplication(bundleIdentifier: "com.vorantx.vory")
        // The script brings the full app to the front to start or end its activity and quits it; once it has come and
        // gone, the copy back. The wall times of the hold, and of the copy's return once `activate` has (for information).
        let viaFullApp = { (what: String) throws -> (launched: Double, back: Double) in
            let launched = Date().timeIntervalSince1970
            print("BARUP HOLD la-\(what)")
            var came = false
            for _ in 0..<60 where !came { self.pause(0.5); came = full.state == .runningForeground }
            guard came else { print("LAMID VOID la-\(what): the full app didn't come"); throw XCTSkip("VOID: the full app didn't come") }
            for _ in 0..<60 where full.state != .notRunning { self.pause(0.5) }
            self.app.activate()
            let back = Date().timeIntervalSince1970
            print(String(format: "LAMID la-%@: the copy back at %.3f", what, back))
            return (launched, back)
        }
        // The same chat, in the same process: its log runs from before the full app came.
        let sameChat = { (stage: String, launched: Double) throws in
            let first = self.frameLog().first?.t ?? .infinity
            guard self.app.state == .runningForeground, info.waitForExistence(timeout: 5), first < launched else {
                print("LAMID VOID \(stage): the copy didn't come back to the same chat (log from \(first), the full app at \(launched))")
                throw XCTSkip("VOID: the copy didn't come back to the same chat")
            }
        }
        let start = try viaFullApp("start")
        try sameChat("A1", start.launched)
        guard waitForSystem({ $0.minY - m0.minY > 20 }) else {
            print("LAMID VOID A1: the markers didn't move in 10 s: \(m0) to \(self.caps()[slots[0].marker].map { "\($0)" } ?? "none")")
            throw XCTSkip("VOID: no activity seen")
        }
        let a1 = read("A1")
        print(String(format: "LAMID push %.1f", (a1[slots[0].marker]?.minY ?? m0.minY) - m0.minY))
        onMarkers("A1", a1)
        moreMenuOnce(more, "A1")
        let end = try viaFullApp("end")
        try sameChat("A2", end.launched)
        XCTAssertTrue(waitForSystem({ abs($0.minY - m0.minY) <= 1 }), "A2: the markers didn't come back in 10 s")
        let a2 = read("A2")
        for s in slots {
            if let x = a0[s.marker], let y = a2[s.marker] { XCTAssertEqual(y.minY, x.minY, accuracy: 1, "A2: \(s.marker) \(y) not back at \(x)") }
        }
        onMarkers("A2", a2)
        // Only what was drawn in front, or on the way in or out: not the background's layouts for the switcher's picture.
        let log = frameLog(inFront: true)
        for s in slots {
            // #618: closed, More follows Back's marker, the pitch under it.
            let underBack = pose == .closed && s.name == "More"
            let marker = underBack ? "markerBack" : s.marker, readName = underBack ? "markerReadBack" : s.read, shift = underBack ? pitch : 0
            guard let from = a0[marker], let to = a1[marker] else { continue }
            let drawn = log.filter { $0.name == s.slot && $0.f.width > 0 }, reads = log.filter { $0.name == readName && $0.f.width > 0 }
            let w1 = { (x: (t: Double, name: String, f: CGRect)) in x.t >= start.launched && x.t < end.launched }
            followsSystem(s.name, drawn.filter(w1), reads: reads.filter(w1), from: from, to: to, "start", shift: shift)
            followsSystem(s.name, drawn.filter { $0.t >= end.launched }, reads: reads.filter { $0.t >= end.launched }, from: to, to: from, "end", shift: shift)
        }
        app.terminate()
    }

    /// #555: on its side to closed with a chat open, with the bar's frame log: the script closes the Duo at the hold
    /// ("BARUP HOLD fold-closed"). The system's places for Back and More after the fold are their last reads in the log
    /// ("markerReadBack", "markerReadMore"): after a pose change it can keep 175 (and 245) rather than pass it on to 238
    /// (and 308) (seen 2026-10-31), and which it did is printed. The column follows the system: after the last read, every
    /// frame centred on the kept place within 1 pt (More the app's pitch under Back's kept place, #618); before it, at most
    /// one step, from where it first stood to the kept
    /// place, nothing between; and where the system passed 175 on to 238, never drawn at the passed place. Then More's menu
    /// opens and its Rename gives one dialog. No fold, the chat not open after it, or no read after it is VOID ("FOLD VOID
    /// …"), not a failure.
    func testTheColumnHoldsThroughAFold() throws {
        let pose = Pose(rawValue: ProcessInfo.processInfo.environment["HERMES_E2E_POSE"] ?? "")
        guard pose == .side else { throw XCTSkip("on its side only (HERMES_E2E_POSE=side)") }
        try openChat(["-vory-morph-log"])
        let more = element("chat.more")
        let folding = Date().timeIntervalSince1970
        print("BARUP HOLD fold-closed")
        var folded = false
        for _ in 0..<60 where !folded { pause(0.5); folded = app.windows.firstMatch.frame.width < 600 }
        guard folded else { print("FOLD VOID: the Duo didn't close"); throw XCTSkip("VOID: no fold") }
        pause(3)
        guard element("chat.titlePill").exists else { print("FOLD VOID: the chat isn't open after the fold"); throw XCTSkip("VOID: no chat after the fold") }
        let log = frameLog().filter { $0.t >= folding }
        // Back and More: the system's reads, its kept place (the last read), and the column's frames against it.
        // #618: closed, More stands the app's pitch (the readout's stripPitch) under Back, so it follows Back's reads, that far
        // under them; More's own reads are printed, for information.
        let pitch = caps()["stripPitch"]?.width ?? 0
        guard pitch >= 44 else { print("FOLD VOID: no stripPitch in the readout"); throw XCTSkip("VOID: no stripPitch") }
        print("FOLD markerReadMore: " + log.filter { $0.name == "markerReadMore" && $0.f.width > 0 }
            .map { String(format: "%+.3f %.0f,%.0f", $0.t - folding, $0.f.minX, $0.f.minY) }.joined(separator: "; "))
        for (name, read, slot, passed, shift) in [("Back", "markerReadBack", "columnBack", CGFloat(175), CGFloat(0)),
                                                  ("More", "markerReadBack", "columnMore", CGFloat(175), pitch)] {
            let reads = log.filter { $0.name == read && $0.f.width > 0 }
            print("FOLD \(read): " + reads.map { String(format: "%+.3f %.0f,%.0f", $0.t - folding, $0.f.minX, $0.f.minY) }.joined(separator: "; "))
            guard let kept = reads.last else { print("FOLD VOID: no \(read) after the fold"); throw XCTSkip("VOID: no read after the fold") }
            let sawPassed = reads.contains { abs($0.f.minY - passed) <= 3 }
            if abs(kept.f.minY - passed) <= 3 { print("FOLD \(name): the system kept \(Int(passed))") }
            else if sawPassed { print("FOLD \(name): the system passed \(Int(passed)) to \(Int(kept.f.minY))") }
            else { print("FOLD \(name): the system kept \(Int(kept.f.minY))") }
            let drawn = log.filter { $0.name == slot && $0.f.width > 0 }
            print("FOLD \(slot): \(drawn.count) frames, middles "
                  + drawn.map { String(format: "%.1f@%+.3f", $0.f.midY, $0.t - folding) }.joined(separator: " "))
            XCTAssertFalse(drawn.isEmpty, "\(slot): never drawn after the fold")
            let mid = kept.f.midY + shift
            // After the last read, once it has settled (250 ms) and the reader's 1 s read again has come: on the kept place.
            for d in drawn where d.t >= kept.t + 1.0 {
                XCTAssertEqual(d.f.midY, mid, accuracy: 1, "\(slot): drawn at middle \(d.f.midY) after the system's last read, not \(mid)")
            }
            // In all: at most one step, ending on the kept place.
            var runs: [CGFloat] = []
            for d in drawn where runs.last.map({ abs($0 - d.f.midY) > 1 }) ?? true { runs.append(d.f.midY) }
            XCTAssertLessThanOrEqual(runs.count, 2, "\(slot): more than one step after the fold: \(runs)")
            if let last = runs.last { XCTAssertEqual(last, mid, accuracy: 1, "\(slot): ended at \(last), not on the kept place \(mid)") }
            // Where the system passed its transient on, never at it.
            if sawPassed && abs(kept.f.minY - passed) > 3 {
                let at = passed + 24 + shift
                XCTAssertFalse(drawn.contains { abs($0.f.midY - at) <= 1 }, "\(slot): drawn at the passed place \(at)")
            }
        }
        moreMenuOnce(more, "after the fold")
        app.terminate()
    }
}
