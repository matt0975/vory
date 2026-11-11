import XCTest

/// #693: on the closed iPhone Duo the Chats list's rows end left of the side column, as every other tab's rows do, and
/// the page is one surface there. The open Duo, a standard iPhone and the iPad keep the list as it was.
///
/// Each test is one leg in one launch against the mock gateway. A leg asserts nothing about the rules itself: it prints
/// what it read and one verdict line per rule and subject, `S693 <leg> pose=<pose> <rule> <subject> GREEN|RED|VOID|READ |
/// <what was read>`, and the script that runs it reads those lines. VOID is a leg that could not get to its question; it
/// is never a pass. READ is a number kept to set beside another build's, with no verdict of its own. Notes are `S693N`,
/// accessibility findings `S693A`.
///
/// The script names the pose (HERMES_E2E_POSE: closed, open, phone, pad). The tabs, the look and the Scheduled section
/// (closed) are set for the launch alone, from the argument domain: nothing is saved. Skipped unless HERMES_E2E_URL /
/// HERMES_E2E_TOKEN are set.
///
/// The rules. E1 (closed, Chats, light and dark): the first chat cell's right edge is at or left of the side column's
/// left edge. The column's edge is the leftmost tab's slot less 4 pt, the room the tab capsule keeps around its slots.
/// E2 (closed; Files, Settings, Projects, Sessions): the first cell's right edge against the same edge. E3 (closed,
/// Chats): the first chat cell's left edge, a READ. C (any other pose): the first chat cell's whole frame, a READ.
/// W1 (closed, Chats): a swipe to the left on the first chat row shows Delete, which takes a tap, and a tap elsewhere
/// puts it away; a swipe to the right shows Archive, the same. Neither is tapped. W2 (closed, Chats): hold the first
/// row and pick Select: the title reads "1 Selected" and Done is there and takes a tap; a tap on the second row reads
/// "2 Selected" and opens no chat; Done ends it, and a tap on the first row then opens the chat.
///
/// A chat row is proven before anything is read from it or done to it. It is the one hittable cell that holds the
/// middle of the row button whose label has one of the mock's own chat titles, that button never one whose identifier
/// starts "chats."; the cell does not hold the middle of the Scheduled section's row ("chats.scheduled") nor of a
/// scheduled chat's row. The Scheduled section is read at each leg's start and end and is never tapped; a leg that
/// does not find it closed at its start is VOID. Every press, drag and tap is made at a point of the window worked out
/// from frames read just before it, by title, so a row that has moved is found where it is now.
@MainActor
final class ChatsEdgeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var leg = ""
    private var pose = "unknown"
    private var shots: URL?

    private static let layoutA = ["-tabLayout", "chats,bots,files,settings", "-tabLayout.homeFirstApplied", "YES"]
    private static let layoutB = ["-tabLayout", "chats,projects,sessions,settings", "-tabLayout.homeFirstApplied", "YES"]
    /// The mock's own chats that stand in the list at rest (its scheduled one is in a section of its own).
    private static let chatTitles = ["Rewrite the nightly export job", "Disk cleanup on the log host"]
    /// The mock's scheduled chat, whose row stands in the Scheduled section while it is open.
    private static let scheduledTitles = ["Weekly dependency audit"]
    /// The room the tab capsule keeps around its slots.
    private static let capsuleInset: CGFloat = 4

    /// A proven chat row: its title, its cell's frame and its button's frame, as read at the pick.
    private struct Row {
        let title: String
        let cell: CGRect
        let button: CGRect
    }

    // MARK: Reading

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func ids(_ id: String) -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: id) }
    private func byID(_ id: String) -> XCUIElement { ids(id).firstMatch }
    private func f(_ r: CGRect) -> String { String(format: "(%.3f,%.3f,%.3f,%.3f)", r.minX, r.minY, r.width, r.height) }
    private func f(_ r: CGRect?) -> String { r.map { f($0) } ?? "none" }
    private func f(_ e: XCUIElement?) -> String { e.map { f($0.frame) } ?? "none" }
    private func n(_ v: CGFloat) -> String { String(format: "%.3f", v) }
    private func p(_ pt: CGPoint) -> String { String(format: "(%.1f,%.1f)", pt.x, pt.y) }
    private func mid(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    private func say(_ rule: String, _ subject: String, _ verdict: String, _ detail: String) {
        print("S693 \(leg) pose=\(pose) \(rule) \(subject) \(verdict) | \(detail)")
    }
    private func note(_ s: String) { print("S693N \(leg) \(s)") }

    private func hittable(_ query: XCUIElementQuery, timeout: Double = 4) -> XCUIElement? {
        let until = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            pause(0.25)
        } while Date() < until
        return nil
    }
    private func gone(_ query: XCUIElementQuery, timeout: Double = 4) -> Bool {
        let until = Date().addingTimeInterval(timeout)
        repeat {
            if !query.allElementsBoundByIndex.contains(where: { $0.exists && $0.isHittable }) { return true }
            pause(0.25)
        } while Date() < until
        return false
    }
    private func named(_ label: String) -> XCUIElementQuery { app.buttons.matching(NSPredicate(format: "label == %@", label)) }

    /// A point of the window, in the screen's points.
    private func at(_ pt: CGPoint) -> XCUICoordinate {
        let w = app.windows.firstMatch
        let o = w.frame.origin
        return w.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: pt.x - o.x, dy: pt.y - o.y))
    }

    /// The side column's left edge: the leftmost tab's slot, less the capsule's own room.
    private func columnEdge() -> CGFloat? {
        var xs: [CGFloat] = []
        for t in ["chats", "bots", "files", "projects", "sessions", "settings", "dashboard"] {
            let e = byID("tab.\(t)")
            if e.exists { xs.append(e.frame.minX) }
        }
        return xs.min().map { $0 - Self.capsuleInset }
    }

    /// How many cells by index one read looks at, so a leg stays inside its time. A read that leaves cells unread says
    /// so in a note ("first K of N"), every time.
    private static let cellCap = 40
    /// The list's cells that take a tap, from the top down. With `count`, a note says what the read saw: the cells by
    /// index, how many of them were read, and how many of those exist and take a tap.
    private func cells(count what: String? = nil) -> [XCUIElement] {
        let all = app.cells.allElementsBoundByIndex
        let read = Array(all.prefix(Self.cellCap))
        let there = read.filter { $0.exists }
        let kept = there.filter { $0.isHittable }
        if all.count > read.count { note("cells: first \(read.count) of \(all.count) by index read") }
        if let what { note("\(what) cells by index \(all.count): read first \(read.count) of \(all.count); exist \(there.count); hittable \(kept.count)") }
        return kept.sorted { $0.frame.minY < $1.frame.minY }
    }
    /// The frames of the list's cells that take a tap, from the top down, as they are now.
    private func cellFrames(count what: String? = nil) -> [CGRect] { cells(count: what).map { $0.frame } }
    /// Printed only, when a title's button lies in none of the cells a read kept: every cell by index that exists, none
    /// left unread, whose frame holds the button's middle, with its place by index and whether it takes a tap.
    private func printHolders(_ what: String, _ title: String, _ button: CGRect) {
        let all = app.cells.allElementsBoundByIndex
        var there = 0, found = 0
        for (i, c) in all.enumerated() where c.exists {
            there += 1
            let cf = c.frame
            guard cf.contains(mid(button)) else { continue }
            found += 1
            note("\(what) pick '\(title)': the cell at index \(i) of \(all.count), frame \(f(cf)), holds the middle of its button \(f(button)); holds its whole frame \(cf.contains(button)); hittable \(c.isHittable)")
        }
        if found == 0 { note("\(what) pick '\(title)': none of the \(there) cells that exist (of \(all.count) by index) holds the middle of its button \(f(button))") }
    }

    /// A list row's own button by words in its label, never an element whose identifier starts "chats.".
    private func titled(_ words: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (identifier BEGINSWITH 'chats.')", words))
    }
    /// The frames of the scheduled chats' rows that are in the list now.
    private func scheduledRowFrames() -> [CGRect] {
        Self.scheduledTitles.flatMap { t in titled(t).allElementsBoundByIndex.filter { $0.exists }.map { $0.frame } }
    }

    /// The Scheduled section as it stands: "closed" (its row there, none of its chats' rows), "open" or "absent".
    /// Read only: nothing is tapped.
    private func scheduledState(_ when: String) -> String {
        let row = byID("chats.scheduled")
        guard row.exists else {
            note("scheduled at the leg's \(when): absent (no chats.scheduled on the page)")
            return "absent"
        }
        let inside = scheduledRowFrames()
        let state = inside.isEmpty ? "closed" : "open"
        note("scheduled at the leg's \(when): \(state); its row \(f(row.frame)) label '\(row.label)'; its chats' rows \(inside.count) [\(inside.map { f($0) }.joined(separator: " "))]")
        return state
    }
    /// The same at a leg's end, back on the Chats list first if the leg ended in a chat or on another tab.
    private func scheduledAtEnd() {
        if chatOpen() {
            let back = byID("chat.back")
            if back.exists && back.isHittable { back.tap(); pause(1.5); note("the leg's end: back from the open chat") }
        }
        if !byID("chats.scheduled").exists {
            let tab = byID("tab.chats")
            if tab.exists && tab.isHittable { tab.tap(); pause(1.5); note("the leg's end: the Chats tab tapped to read the section") }
        }
        _ = scheduledState("end")
    }

    /// The Chats list's proven chat rows, from the top down, each printed with its title and frames. A title is left
    /// out, with the reason printed, unless its buttons that take a tap have their middles in one hittable cell and
    /// that cell holds neither the Scheduled row's middle nor a scheduled chat's row's.
    private func chatRows(_ what: String) -> [Row] {
        let all = cellFrames()
        let sched = byID("chats.scheduled")
        let schedFrame: CGRect? = sched.exists ? sched.frame : nil
        let schedRows = scheduledRowFrames()
        var rows: [Row] = []
        for t in Self.chatTitles {
            let hits = titled(t).allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map { $0.frame }
            guard let b = hits.first else { note("\(what) pick '\(t)': no button that takes a tap holds the title; not picked"); continue }
            var holders: [CGRect] = []
            for h in hits { for c in all where c.contains(mid(h)) && !holders.contains(c) { holders.append(c) } }
            guard holders.count == 1, let c = holders.first else {
                note("\(what) pick '\(t)': its \(hits.count) button(s) [\(hits.map { f($0) }.joined(separator: " "))] lie in \(holders.count) cells [\(holders.map { f($0) }.joined(separator: " "))], one is wanted; not picked")
                if holders.isEmpty { for h in hits { printHolders(what, t, h) } }
                continue
            }
            if let s = schedFrame, c.contains(mid(s)) {
                note("\(what) pick '\(t)': its cell \(f(c)) holds the Scheduled row \(f(s)); not picked")
                continue
            }
            if let s = schedRows.first(where: { c.contains(mid($0)) }) {
                note("\(what) pick '\(t)': its cell \(f(c)) holds a scheduled chat's row \(f(s)); not picked")
                continue
            }
            if let other = rows.first(where: { $0.cell == c }) {
                note("\(what) pick '\(t)': its cell \(f(c)) is the cell of '\(other.title)'; not picked")
                continue
            }
            rows.append(Row(title: t, cell: c, button: b))
        }
        rows.sort { $0.cell.minY < $1.cell.minY }
        note("\(what) picked \(rows.count): \(rows.map { "'\($0.title)' cell \(f($0.cell)) button \(f($0.button))" }.joined(separator: "; ")); Scheduled row \(f(schedFrame)); scheduled chats' rows \(schedRows.count)")
        return rows
    }
    /// The proven row of that title as it is now, if it is still one.
    private func rowNow(_ title: String, _ what: String) -> Row? { chatRows(what).first { $0.title == title } }

    /// What the earlier revision's pick matched, printed only: for each hittable cell and each title, the first
    /// descendant of the cell whose label holds the title, and whether that element lies in the cell. Nothing is
    /// picked from it.
    private func oldQuery(_ what: String) {
        for c in cells() {
            let cf = c.frame
            for t in Self.chatTitles {
                let m = c.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", t)).firstMatch
                guard m.exists else {
                    note("\(what) old query: cell \(f(cf)) id '\(c.identifier)' label '\(c.label)': '\(t)' no match")
                    continue
                }
                let mf = m.frame
                note("\(what) old query: cell \(f(cf)) id '\(c.identifier)' label '\(c.label)': '\(t)' matched type \(m.elementType.rawValue) id '\(m.identifier)' frame \(f(mf)) in the cell \(cf.contains(mid(mf)))")
            }
        }
    }

    private func chatOpen() -> Bool { byID("chat.header").exists || byID("chat.back").exists }
    private func title() -> String {
        let t = app.staticTexts["morph.title"].firstMatch
        return t.exists ? t.label : "none"
    }

    private func shot(_ name: String) {
        guard pose == "closed" else { return }
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        guard let shots else { return }
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: shots.appendingPathComponent("\(name).png"))
        note("still \(name).png")
    }

    private func audit(_ name: String) {
        let leg = self.leg
        var issues = 0
        do {
            try app.performAccessibilityAudit { issue in
                issues += 1
                let el = issue.element
                print("S693A \(leg) \(name) \(issue.auditType) '\(el?.identifier ?? "")' '\(el?.label ?? "")' \(issue.compactDescription)")
                return true
            }
            print("S693A \(leg) \(name) issues=\(issues)")
        } catch {
            print("S693A \(leg) \(name) ERROR \(error)")
        }
    }

    private func launch(_ leg: String, look: String, layout: [String]) throws -> Bool {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        self.leg = leg
        continueAfterFailure = true
        pose = e["HERMES_E2E_POSE"].flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        shots = e["HERMES_E2E_SHOTS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats",
                               "-colorSchemePreference", look, "-chats.scheduled.open", "NO"] + layout
        app.launch()
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", Self.chatTitles[0])).firstMatch
        guard first.waitForExistence(timeout: 40) else {
            say("LAUNCH", "chats", "VOID", "no chat row 40 s after launch")
            return false
        }
        pause(2.5)
        var tabs: [String] = []
        for t in ["chats", "bots", "files", "projects", "sessions", "settings", "dashboard"] where byID("tab.\(t)").exists {
            tabs.append("\(t)\(f(byID("tab.\(t)").frame))")
        }
        note("launch look=\(look) window \(f(app.windows.firstMatch.frame)) tabs \(tabs.joined(separator: " "))")
        if pose == "closed" {
            let want = layout.count > 1 ? layout[1].split(separator: ",").map(String.init) : []
            let missing = want.filter { !byID("tab.\($0)").exists }
            if !missing.isEmpty {
                say("LAUNCH", "chats", "VOID", "the layout's tabs not on the bar: \(missing.joined(separator: ","))")
                return false
            }
        }
        return true
    }

    private func printCells(_ what: String, _ list: [CGRect]) {
        note("\(what) cells \(list.count): \(list.prefix(6).map { f($0) }.joined(separator: " "))")
    }

    // MARK: The edge

    /// E1 and E3 on the Chats list as it stands.
    private func chatsEdge(_ look: String, section: String) {
        printCells("chats-\(look) all", cellFrames(count: "chats-\(look)"))
        oldQuery("chats-\(look)")
        guard section == "closed" else {
            say("E1", "chats-\(look)", "VOID", "the Scheduled section is \(section) at the leg's start, closed is wanted")
            say("E3", "chats-\(look)", "VOID", "the Scheduled section is \(section) at the leg's start, closed is wanted")
            return
        }
        let chats = chatRows("chats-\(look)")
        guard let c = chats.first, let edge = columnEdge() else {
            say("E1", "chats-\(look)", "VOID", "first chat cell \(f(chats.first?.cell)) column edge \(columnEdge().map { n($0) } ?? "none"); no proven chat row or no edge")
            say("E3", "chats-\(look)", "VOID", "first chat cell \(f(chats.first?.cell)); no proven chat row or no edge")
            return
        }
        let r = c.cell
        say("E1", "chats-\(look)", r.maxX <= edge ? "GREEN" : "RED", "maxX \(n(r.maxX)) edge \(n(edge)) cell \(f(r))")
        say("E3", "chats-\(look)", "READ", "minX \(n(r.minX)) cell \(f(r))")
    }

    /// E2 on another tab's root.
    private func otherEdge(_ tab: String) {
        let t = byID("tab.\(tab)")
        guard t.exists else { say("E2", tab, "VOID", "no tab.\(tab)"); return }
        t.tap(); pause(2.5)
        let all = cells(count: tab)
        printCells(tab, all.map { $0.frame })
        guard let c = all.first, let edge = columnEdge() else {
            say("E2", tab, "VOID", "first cell \(f(all.first)) column edge \(columnEdge().map { n($0) } ?? "none")")
            return
        }
        let r = c.frame
        say("E2", tab, r.maxX <= edge ? "GREEN" : "RED", "maxX \(n(r.maxX)) edge \(n(edge)) cell \(f(r))")
    }

    private func edge(_ name: String, look: String) throws {
        guard try launch(name, look: look, layout: Self.layoutA) else { return }
        let section = scheduledState("start")
        defer { scheduledAtEnd() }
        guard pose == "closed" else { say("E1", "chats-\(look)", "VOID", "the pose is \(pose), not closed"); return }
        chatsEdge(look, section: section)
        shot("chats-\(look)")
        audit("chats-\(look)")
        if look == "light" { otherEdge("files") }
        otherEdge("settings")
        shot("settings-\(look)")
    }

    func testEdgeLight() throws { try edge("EdgeLight", look: "light") }
    func testEdgeDark() throws { try edge("EdgeDark", look: "dark") }

    func testEdgeB() throws {
        guard try launch("EdgeB", look: "light", layout: Self.layoutB) else { return }
        _ = scheduledState("start")
        defer { scheduledAtEnd() }
        guard pose == "closed" else { say("E2", "projects", "VOID", "the pose is \(pose), not closed"); return }
        otherEdge("projects")
        otherEdge("sessions")
    }

    /// C: the first chat cell's frame where the strip is not closed, and the audit there.
    func testCell() throws {
        guard try launch("Cell", look: "light", layout: []) else { return }
        let section = scheduledState("start")
        defer { scheduledAtEnd() }
        guard pose != "closed" else { say("C", "chats", "VOID", "the pose is closed"); return }
        printCells("chats all", cellFrames(count: "chats"))
        oldQuery("chats")
        guard section == "closed" else { say("C", "chats", "VOID", "the Scheduled section is \(section) at the leg's start, closed is wanted"); return }
        let chats = chatRows("chats")
        if let c = chats.first { say("C", "chats", "READ", "cell \(f(c.cell))") } else { say("C", "chats", "VOID", "no chat cell; no proven chat row") }
        audit("chats-\(pose)")
    }

    // MARK: Swipe and selection

    /// A tap that is on the list and on no row's action: under the last row if the page has room there, else on the
    /// second proven chat row, found again by its title just before the tap. It says where the tap was made and which
    /// cells held that point then.
    private func tapElsewhere(_ what: String) -> String {
        let w = app.windows.firstMatch.frame
        let low = cellFrames().last?.maxY ?? w.maxY
        var pt: CGPoint?
        var place = ""
        if low + 60 < w.maxY - 90 {
            pt = CGPoint(x: 120, y: low + 40)
            place = "under the last row"
        } else {
            let rows = chatRows(what)
            if rows.count > 1 {
                let c = rows[1].cell
                pt = CGPoint(x: c.minX + c.width * 0.3, y: c.midY)
                place = "on the second chat row '\(rows[1].title)' cell \(f(c))"
            }
        }
        guard let pt else { return "nowhere (no room under the rows and no second proven chat row)" }
        let under = cellFrames().filter { $0.contains(pt) }
        let sched = byID("chats.scheduled")
        let onSched = sched.exists && sched.frame.contains(pt)
        guard !onSched else { return "nowhere (the point \(p(pt)) \(place) is on the Scheduled row \(f(sched.frame)); no tap made)" }
        at(pt).tap()
        return "\(place) at \(p(pt)); cells holding the point then \(under.count) [\(under.map { f($0) }.joined(separator: " "))]; on the Scheduled row \(onSched)"
    }

    /// A short press and a sideways drag across a proven row's cell, at its middle height.
    private func swipe(_ c: CGRect, left: Bool) {
        let a = CGPoint(x: c.minX + c.width * (left ? 0.55 : 0.15), y: c.midY)
        let b = CGPoint(x: c.minX + c.width * (left ? 0.15 : 0.55), y: c.midY)
        note("swipe to the \(left ? "left" : "right") from \(p(a)) to \(p(b)) in the cell \(f(c))")
        at(a).press(forDuration: 0.05, thenDragTo: at(b))
    }

    func testSwipe() throws {
        guard try launch("Swipe", look: "light", layout: Self.layoutA) else { return }
        let section = scheduledState("start")
        defer { scheduledAtEnd() }
        guard pose == "closed" else { say("W1", "chats", "VOID", "the pose is \(pose), not closed"); return }
        guard section == "closed" else { say("W1", "chats", "VOID", "the Scheduled section is \(section) at the leg's start, closed is wanted"); return }
        let chats = chatRows("before the swipe to the left")
        guard let c = chats.first else { say("W1", "chats", "VOID", "no chat cell; no proven chat row"); return }
        swipe(c.cell, left: true); pause(1)
        let del = hittable(named("Delete"), timeout: 3)
        let delFrame = f(del)
        let away1 = tapElsewhere("for the tap after the swipe to the left"); pause(1)
        let delGone = gone(named("Delete"), timeout: 3)
        let opened1 = chatOpen()
        note("after the swipe to the left: Delete \(delFrame); the tap \(away1); Delete away \(delGone); a chat open \(opened1); section \(scheduledState("middle"))")
        guard !away1.hasPrefix("nowhere") else { say("W1", "chats", "VOID", "no tap elsewhere could be made after the swipe to the left: \(away1); Delete \(delFrame)"); return }
        guard !opened1 else { say("W1", "chats", "RED", "a chat opened at the tap elsewhere after the swipe to the left; Delete \(delFrame)"); return }
        guard let again = rowNow(c.title, "before the swipe to the right") else {
            say("W1", "chats", "VOID", "the first chat row '\(c.title)' is not proven again before the swipe to the right; Delete \(delFrame) away \(delGone)")
            return
        }
        swipe(again.cell, left: false); pause(1)
        let arc = hittable(named("Archive"), timeout: 3)
        let arcFrame = f(arc)
        let others = app.buttons.allElementsBoundByIndex.filter { $0.exists && $0.isHittable && ["Pin", "Unpin", "Unarchive"].contains($0.label) }
            .map { "\($0.label)\(f($0.frame))" }.joined(separator: " ")
        let away2 = tapElsewhere("for the tap after the swipe to the right"); pause(1)
        let arcGone = gone(named("Archive"), timeout: 3)
        let opened2 = chatOpen()
        guard !away2.hasPrefix("nowhere") else { say("W1", "chats", "VOID", "no tap elsewhere could be made after the swipe to the right: \(away2); Delete \(delFrame) away \(delGone); Archive \(arcFrame)"); return }
        let ok = del != nil && delGone && arc != nil && arcGone && !opened2
        say("W1", "chats", ok ? "GREEN" : "RED",
            "Delete \(delFrame) away \(delGone) (tap \(away1)); Archive \(arcFrame) away \(arcGone) (tap \(away2)); beside it [\(others)]; a chat open \(opened2); row \(f(again.cell))")
        shot("chats-swipe-end")
    }

    func testSelect() throws {
        guard try launch("Select", look: "light", layout: Self.layoutA) else { return }
        let section = scheduledState("start")
        defer { scheduledAtEnd() }
        guard pose == "closed" else { say("W2", "chats", "VOID", "the pose is \(pose), not closed"); return }
        guard section == "closed" else { say("W2", "chats", "VOID", "the Scheduled section is \(section) at the leg's start, closed is wanted"); return }
        let chats = chatRows("before the hold")
        guard chats.count > 1 else { say("W2", "chats", "VOID", "\(chats.count) chat cell(s); two proven chat rows are wanted"); return }
        note("hold at \(p(mid(chats[0].cell))) on '\(chats[0].title)' cell \(f(chats[0].cell))")
        at(mid(chats[0].cell)).press(forDuration: 1.0)
        let select = app.buttons["Select"].firstMatch
        guard select.waitForExistence(timeout: 5) else {
            // The menu is put away by a tap on the page's top left corner, clear of the menu and its preview.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.02)).tap()
            say("W2", "chats", "VOID", "no Select in the first row's menu")
            return
        }
        select.tap(); pause(1.5)
        let doneQ = ids("chats.select.done")
        let done = hittable(doneQ, timeout: 5)
        let doneFrame = f(done)
        let t1 = title()
        shot("chats-select-one")
        // The rows may have moved as selecting began: proven again, by title.
        let now = chatRows("while selecting")
        var t2 = "not read", opened = false, ended = false, opens = false
        if now.count > 1 {
            note("tap at \(p(mid(now[1].cell))) on '\(now[1].title)' cell \(f(now[1].cell))")
            at(mid(now[1].cell)).tap(); pause(1)
            t2 = title(); opened = chatOpen()
        }
        if let d = hittable(doneQ, timeout: 2) {
            d.tap(); pause(1.5)
            ended = gone(doneQ, timeout: 3)
        }
        if ended, let first = chatRows("after Done").first {
            note("tap at \(p(mid(first.cell))) on '\(first.title)' cell \(f(first.cell))")
            at(mid(first.cell)).tap(); pause(2)
            opens = chatOpen()
        }
        if now.count <= 1 && done != nil && t1 == "1 Selected" {
            say("W2", "chats", "VOID", "\(now.count) chat cell(s) while selecting, two proven chat rows are wanted; done \(doneFrame) title '\(t1)'; ended \(ended)")
            return
        }
        let ok = done != nil && t1 == "1 Selected" && t2 == "2 Selected" && !opened && ended && opens
        say("W2", "chats", ok ? "GREEN" : "RED",
            "done \(doneFrame) title '\(t1)' then '\(t2)'; a chat open while selecting \(opened); ended \(ended); the first row opens its chat after \(opens)")
    }
}
