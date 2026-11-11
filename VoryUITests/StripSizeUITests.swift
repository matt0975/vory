import XCTest

/// #694: on the closed iPhone Duo the side column's four controls (the tab capsule, the mic, compose and the system's
/// search button) are one size across and stand at equal gaps.
///
/// The size T is 48, the search button's visible glass. The accessibility frame of that button is smaller than its
/// glass (38 on build 53), so the glass's top is taken as the frame's middle less T / 2.
///
/// Each test is one leg in one launch against the mock gateway. A leg asserts nothing itself: it prints what it read,
/// one line per subject, `S694 <leg> pose=<pose> <rule> <subject> GREEN|RED|VOID|READ | <what was read>`, and the
/// script that runs it reads those lines. VOID is a leg that could not get to its question; it is never a pass. READ
/// is a number kept to set beside another, with no verdict of its own. Notes are `S694N`. Frames are (x,y,w,h) at one
/// decimal.
///
/// The script names the pose (HERMES_E2E_POSE: closed, open, phone, pad). The tabs and the look are set for the launch
/// alone, from the argument domain: nothing is saved. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
///
/// The read leg, rule R (closed, Chats at rest, light and dark), every line a READ or a VOID:
///   window   the window's frame.
///   slots    the four tab slots' frames, top down.
///   capsule  the slots' union grown by the 4 pt the capsule keeps around them.
///   mic      chats.voice on the column.
///   compose  chats.new on the column.
///   search   the system's search button: its frame and what it was found by. It is the element labeled Search whose
///            middle is on the column; a button that takes a tap is taken first.
///   holds    how many elements have a frame that holds the search button's middle. Each is printed in a note with its
///            depth, type, identifier, label and frame, and whether it is about 48 by 48 around that middle (each side
///            44 to 52, its own middle within 2 pt).
///   gaps     capsule to mic, mic to compose, compose's bottom to the search frame's top, and the four middles' x.
///   clear    whether the slots, the mic and compose each take a tap, with no keyboard, alert, sheet or open chat
///            over the page: what the still wants. Then the still, read-chats-<look>.png.
///
/// The strip legs (closed, Chats at rest, light and dark) print the R lines above first, then these, with every frame
/// in every line and in every case. W, C and G are VOID if the mic, compose or the search frame is not found.
///   W width     the capsule's width, and the mic's and compose's width and height, each within 0.5 of T.
///   C center    the middles' x of the capsule, the mic, compose and the search frame within 0.5 of each other.
///   G gaps      capsule to mic, mic to compose, and compose's bottom to the glass's top: the three within 0.5 of
///               each other.
///   Then the still, strip-chats-<look>.png, and the audit of the Chats page: `S694A` lines, one per issue, and
///   A chats     a READ with the count, or a VOID if the audit could not run.
///   K1 <tab>    bots, files, settings: after a tap on that tab, the capsule's, the mic's and compose's frames are the
///               Chats tab's frames of this same run, as printed. VOID if the tab takes no tap, a control is not found,
///               or nothing shows the page left Chats (the tab not selected and the Chats row still taking a tap).
///
/// The open leg, rule K2 (the open Duo, Chats at rest, light), every line a READ or a VOID, for setting a build beside
/// build 53 character for character:
///   bar      the window, the tab slots' frames, and whether they stand in one column (vertical).
///   capsule  the slots' union grown 4.
///   mic, compose   chats.voice and chats.new, the one that takes a tap first.
@MainActor
final class StripSizeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var leg = ""
    private var pose = "unknown"
    private var shots: URL?

    /// T, the one size the four controls take: the search button's visible glass. The read leg judges nothing by it.
    private static let stripT: CGFloat = 48
    /// How far a size, a middle or a gap may be off.
    private static let tol: CGFloat = 0.5
    private static let readSubjects = ["window", "slots", "capsule", "mic", "compose", "search", "holds", "gaps", "clear"]
    private static let otherTabs = ["bots", "files", "settings"]

    private static let layoutA = ["-tabLayout", "chats,bots,files,settings", "-tabLayout.homeFirstApplied", "YES"]
    private static let tabs = ["chats", "bots", "files", "settings"]
    private static let allTabs = ["chats", "bots", "files", "projects", "sessions", "settings", "dashboard"]
    private static let chatTitle = "Rewrite the nightly export job"
    /// The room the tab capsule keeps around its slots.
    private static let capsuleInset: CGFloat = 4

    // MARK: Reading

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func ids(_ id: String) -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: id) }
    private func byID(_ id: String) -> XCUIElement { ids(id).firstMatch }
    private func f(_ r: CGRect) -> String { String(format: "(%.1f,%.1f,%.1f,%.1f)", r.minX, r.minY, r.width, r.height) }
    private func f(_ r: CGRect?) -> String { r.map { f($0) } ?? "none" }
    private func n(_ v: CGFloat) -> String { String(format: "%.1f", v) }
    private func n(_ v: CGFloat?) -> String { v.map { n($0) } ?? "none" }
    private func say(_ rule: String, _ subject: String, _ verdict: String, _ detail: String) {
        print("S694 \(leg) pose=\(pose) \(rule) \(subject) \(verdict) | \(detail)")
    }
    private func note(_ s: String) { print("S694N \(leg) \(s)") }
    /// A label on one line, cut at 40 characters.
    private func short(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "'", with: "’")
        return one.count > 40 ? String(one.prefix(40)) + "…" : one
    }
    private func kind(_ t: XCUIElement.ElementType) -> String {
        switch t {
        case .application: return "application"
        case .window: return "window"
        case .other: return "other"
        case .group: return "group"
        case .button: return "button"
        case .image: return "image"
        case .staticText: return "staticText"
        case .cell: return "cell"
        case .scrollView: return "scrollView"
        case .collectionView: return "collectionView"
        case .table: return "table"
        case .tabBar: return "tabBar"
        case .tab: return "tab"
        case .toolbar: return "toolbar"
        case .navigationBar: return "navigationBar"
        case .searchField: return "searchField"
        case .textField: return "textField"
        case .keyboard: return "keyboard"
        case .key: return "key"
        default: return "type\(t.rawValue)"
        }
    }

    /// The side column's left edge: the leftmost tab's slot, less the capsule's own room.
    private func columnEdge() -> CGFloat? {
        var xs: [CGFloat] = []
        for t in Self.allTabs {
            let e = byID("tab.\(t)")
            if e.exists { xs.append(e.frame.minX) }
        }
        return xs.min().map { $0 - Self.capsuleInset }
    }

    /// The element with this identifier whose middle is on the column, and how many carry the identifier at all.
    private func onColumn(_ id: String, edge: CGFloat) -> (XCUIElement?, Int) {
        let all = ids(id).allElementsBoundByIndex.filter { $0.exists }
        let on = all.filter { !$0.frame.isEmpty && $0.frame.midX >= edge }
        return (on.first { $0.isHittable } ?? on.first, all.count)
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        guard let shots else { note("still \(name): no folder given, kept in the result only"); return }
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: shots.appendingPathComponent("\(name).png"))
        note("still \(name).png")
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
                               "-colorSchemePreference", look] + layout
        app.launch()
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", Self.chatTitle)).firstMatch
        guard first.waitForExistence(timeout: 40) else {
            say("LAUNCH", "chats", "VOID", "no chat row 40 s after launch")
            return false
        }
        pause(2.5)
        var tabs: [String] = []
        for t in Self.allTabs where byID("tab.\(t)").exists { tabs.append("\(t)\(f(byID("tab.\(t)").frame))") }
        note("launch look=\(look) T \(n(Self.stripT)) window \(f(app.windows.firstMatch.frame)) tabs \(tabs.joined(separator: " "))")
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

    // MARK: The read leg

    /// The system's search button on the column: a button labeled Search that takes a tap, else any element labeled
    /// Search there. Every element labeled Search is printed first.
    private func searchButton(edge: CGFloat) -> (CGRect, String)? {
        let labeled = app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] 'Search'"))
            .allElementsBoundByIndex.filter { $0.exists }
        var best: (CGRect, String)?
        var rank = 0
        for (i, e) in labeled.enumerated() {
            let r = e.frame, hit = e.isHittable, on = !r.isEmpty && r.midX >= edge
            let what = "\(kind(e.elementType)) '\(e.identifier)' '\(short(e.label))'"
            note("labeled Search \(i + 1) of \(labeled.count): \(what) \(f(r)) hittable \(hit) on the column \(on)")
            guard on else { continue }
            let mine = (e.elementType == .button ? 2 : 0) + (hit ? 1 : 0) + 1
            if mine > rank { rank = mine; best = (r, "\(what) hittable \(hit); labeled Search in all \(labeled.count)") }
        }
        return best
    }

    private func walk(_ s: any XCUIElementSnapshot, _ depth: Int, _ visit: (any XCUIElementSnapshot, Int) -> Void) {
        visit(s, depth)
        for c in s.children { walk(c, depth + 1, visit) }
    }

    /// Every element of the app whose frame holds this point, from one snapshot of the whole tree.
    private func holds(_ look: String, _ mid: CGPoint) {
        let snap: any XCUIElementSnapshot
        do { snap = try app.snapshot() } catch {
            say("R", "holds-\(look)", "VOID", "no snapshot of the app: \(error)")
            return
        }
        var lines: [String] = [], about: [String] = [], all = 0
        walk(snap, 0) { s, depth in
            all += 1
            let r = s.frame
            guard !r.isEmpty, r.contains(mid) else { return }
            let is48 = (44...52).contains(r.width) && (44...52).contains(r.height) && abs(r.midX - mid.x) <= 2 && abs(r.midY - mid.y) <= 2
            if is48 { about.append(f(r)) }
            lines.append("depth \(depth) \(kind(s.elementType)) '\(s.identifier)' '\(short(s.label))' \(f(r)) about-48 \(is48)")
        }
        for (i, l) in lines.enumerated() { note("holds-\(look) \(i + 1) of \(lines.count): \(l)") }
        say("R", "holds-\(look)", "READ",
            "\(lines.count) of \(all) elements hold (\(n(mid.x)),\(n(mid.y))); about 48 by 48: \(about.count) [\(about.joined(separator: " "))]")
    }

    /// What the column's reads gave: nil where a control was not found.
    private struct Column {
        let window: CGRect, capsule: CGRect
        let mic: CGRect?, compose: CGRect?, search: CGRect?
    }

    /// The R lines of the closed column on the page showing, and the frames they read.
    private func column(_ look: String) -> Column {
        let win = app.windows.firstMatch.frame
        say("R", "window-\(look)", "READ", "window \(f(win))")

        let slotEls = Self.tabs.map { byID("tab.\($0)") }
        let slots = slotEls.map { $0.frame }.sorted { $0.minY < $1.minY }
        say("R", "slots-\(look)", "READ", "\(slots.count) slots: \(slots.map { f($0) }.joined(separator: " "))")
        let capsule = slots.dropFirst().reduce(slots[0]) { $0.union($1) }.insetBy(dx: -Self.capsuleInset, dy: -Self.capsuleInset)
        say("R", "capsule-\(look)", "READ", "capsule \(f(capsule)) (the slots' union grown \(n(Self.capsuleInset)))")
        let edge = capsule.minX

        let (mic, micAll) = onColumn("chats.voice", edge: edge)
        let (compose, composeAll) = onColumn("chats.new", edge: edge)
        if let mic { say("R", "mic-\(look)", "READ", "mic \(f(mic.frame)) hittable \(mic.isHittable); chats.voice in all \(micAll)") }
        else { say("R", "mic-\(look)", "VOID", "no chats.voice on the column; chats.voice in all \(micAll)") }
        if let compose { say("R", "compose-\(look)", "READ", "compose \(f(compose.frame)) hittable \(compose.isHittable); chats.new in all \(composeAll)") }
        else { say("R", "compose-\(look)", "VOID", "no chats.new on the column; chats.new in all \(composeAll)") }

        let search = searchButton(edge: edge)
        if let (r, by) = search {
            say("R", "search-\(look)", "READ", "search \(f(r)) middle (\(n(r.midX)),\(n(r.midY))) found by \(by)")
            holds(look, CGPoint(x: r.midX, y: r.midY))
        } else {
            say("R", "search-\(look)", "VOID", "no element labeled Search with its middle on the column (edge \(n(edge)))")
            say("R", "holds-\(look)", "VOID", "no search frame to take a middle from")
        }

        let m = mic?.frame, c = compose?.frame, s = search?.0
        if let m, let c, let s {
            say("R", "gaps-\(look)", "READ",
                "capsule-mic \(n(m.minY - capsule.maxY)) mic-compose \(n(c.minY - m.maxY)) compose-searchframe \(n(s.minY - c.maxY)); "
                + "midX capsule \(n(capsule.midX)) mic \(n(m.midX)) compose \(n(c.midX)) search \(n(s.midX)); "
                + "widths capsule \(n(capsule.width)) mic \(n(m.width)) compose \(n(c.width)) searchframe \(n(s.width))")
        } else {
            say("R", "gaps-\(look)", "VOID", "mic \(f(m)) compose \(f(c)) search \(f(s))")
        }

        // What the still wants: the capsule, the mic and compose whole and with nothing over them.
        let slotHits = slotEls.filter { $0.isHittable }.count
        let inWindow = ([capsule] + [m, c].compactMap { $0 }).allSatisfy { win.contains($0) }
        let keyboard = app.keyboards.firstMatch.exists, alerts = app.alerts.count, sheets = app.sheets.count
        let chatOpen = byID("chat.header").exists || byID("chat.back").exists
        let micHit = mic?.isHittable ?? false, composeHit = compose?.isHittable ?? false
        let clear = slotHits == slots.count && micHit && composeHit && inWindow && !keyboard && alerts == 0 && sheets == 0 && !chatOpen
        say("R", "clear-\(look)", clear ? "READ" : "VOID",
            "slots that take a tap \(slotHits) of \(slots.count), mic \(micHit), compose \(composeHit), all inside the window \(inWindow); "
            + "keyboard \(keyboard), alerts \(alerts), sheets \(sheets), a chat open \(chatOpen)")
        return Column(window: win, capsule: capsule, mic: m, compose: c, search: s)
    }

    private func read(_ name: String, look: String) throws {
        guard try launch(name, look: look, layout: Self.layoutA) else { return }
        guard pose == "closed" else {
            for s in Self.readSubjects { say("R", "\(s)-\(look)", "VOID", "the pose is \(pose), not closed") }
            return
        }
        _ = column(look)
        shot("read-chats-\(look)")
    }

    func testReadLight() throws { try read("ReadLight", look: "light") }
    func testReadDark() throws { try read("ReadDark", look: "dark") }

    // MARK: The strip legs

    /// W, C and G on the closed column. Every frame is printed in every line, a VOID among them.
    private func judge(_ col: Column, _ look: String) {
        let t = Self.stripT, tol = Self.tol
        let frames = "capsule \(f(col.capsule)) mic \(f(col.mic)) compose \(f(col.compose)) search frame \(f(col.search))"
        guard let m = col.mic, let c = col.compose, let s = col.search else {
            for (rule, subject) in [("W", "width"), ("C", "center"), ("G", "gaps")] {
                say(rule, "\(subject)-\(look)", "VOID", "the mic, compose or the search frame was not found; \(frames)")
            }
            return
        }
        let sizes = [col.capsule.width, m.width, m.height, c.width, c.height]
        say("W", "width-\(look)", sizes.allSatisfy { abs($0 - t) <= tol } ? "GREEN" : "RED",
            "T \(n(t)) within \(n(tol)): capsule width \(n(col.capsule.width)), mic \(n(m.width)) by \(n(m.height)), "
            + "compose \(n(c.width)) by \(n(c.height)); \(frames)")
        let xs = [col.capsule.midX, m.midX, c.midX, s.midX]
        let across = (xs.max() ?? 0) - (xs.min() ?? 0)
        say("C", "center-\(look)", across <= tol ? "GREEN" : "RED",
            "middles' x within \(n(tol)): capsule \(n(xs[0])) mic \(n(xs[1])) compose \(n(xs[2])) search \(n(xs[3])), apart \(n(across)); \(frames)")
        let top = s.midY - t / 2
        let gaps = [m.minY - col.capsule.maxY, c.minY - m.maxY, top - c.maxY]
        let apart = (gaps.max() ?? 0) - (gaps.min() ?? 0)
        say("G", "gaps-\(look)", apart <= tol ? "GREEN" : "RED",
            "gaps within \(n(tol)): capsule-mic \(n(gaps[0])) mic-compose \(n(gaps[1])) compose-glass \(n(gaps[2])), apart \(n(apart)) "
            + "(the glass's top \(n(top)): the search frame's middle \(n(s.midY)) less T / 2); \(frames)")
    }

    /// The audit of the page showing: one `S694A` line per issue, then the A line.
    private func audit(_ name: String, _ look: String) {
        var found: [(UInt64, String, String, CGRect?, String)] = []
        var failure: String?
        do {
            try app.performAccessibilityAudit { issue in
                let el = issue.element
                let there = el?.exists ?? false
                found.append((issue.auditType.rawValue, there ? el?.identifier ?? "" : "", there ? el?.label ?? "" : "",
                              there ? el?.frame : nil, issue.compactDescription))
                return true
            }
        } catch {
            failure = "\(error)"
        }
        // One line per issue: the audit's type number, the element's identifier, label and frame, then the description.
        for (type, id, label, frame, text) in found {
            print("S694A \(leg) \(name)-\(look) \(type) '\(short(id))' '\(short(label))' \(f(frame)) \(short(text))")
        }
        if let failure {
            say("A", "\(name)-\(look)", "VOID", "the audit did not run to its end after \(found.count) issues: \(failure)")
        } else {
            say("A", "\(name)-\(look)", "READ", "issues \(found.count)")
        }
    }

    /// K1: after a tap on this tab the capsule, the mic and compose stand where they stood on Chats in this run.
    private func otherTab(_ tab: String, _ look: String, chats: Column) {
        let subject = "\(tab)-\(look)"
        let was = "on chats: capsule \(f(chats.capsule)) mic \(f(chats.mic)) compose \(f(chats.compose))"
        let t = byID("tab.\(tab)")
        guard t.exists, t.isHittable else {
            say("K1", subject, "VOID", "tab.\(tab) takes no tap (exists \(t.exists)); \(was)")
            return
        }
        t.tap()
        pause(1.5)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", Self.chatTitle)).firstMatch
        let rowUp = row.exists && row.isHittable
        let selected = byID("tab.\(tab)").isSelected
        let slots = Self.tabs.map { byID("tab.\($0)") }.filter { $0.exists }.map { $0.frame }.sorted { $0.minY < $1.minY }
        guard slots.count == Self.tabs.count, let first = slots.first else {
            say("K1", subject, "VOID", "\(slots.count) of \(Self.tabs.count) tab slots on \(tab): \(slots.map { f($0) }.joined(separator: " ")); \(was)")
            return
        }
        let capsule = slots.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -Self.capsuleInset, dy: -Self.capsuleInset)
        let (mic, micAll) = onColumn("chats.voice", edge: capsule.minX)
        let (compose, composeAll) = onColumn("chats.new", edge: capsule.minX)
        let now = "on \(tab): capsule \(f(capsule)) mic \(f(mic?.frame)) compose \(f(compose?.frame)) "
            + "(chats.voice in all \(micAll), chats.new in all \(composeAll)); tab selected \(selected), the Chats row takes a tap \(rowUp)"
        guard selected || !rowUp else {
            say("K1", subject, "VOID", "nothing shows the page left Chats; \(now); \(was)")
            return
        }
        guard let mf = mic?.frame, let cf = compose?.frame, let m0 = chats.mic, let c0 = chats.compose else {
            say("K1", subject, "VOID", "the mic or compose was not found; \(now); \(was)")
            return
        }
        let same = f(capsule) == f(chats.capsule) && f(mf) == f(m0) && f(cf) == f(c0)
        say("K1", subject, same ? "GREEN" : "RED", "\(now); \(was)")
    }

    private func strip(_ name: String, look: String) throws {
        guard try launch(name, look: look, layout: Self.layoutA) else { return }
        guard pose == "closed" else {
            for s in Self.readSubjects { say("R", "\(s)-\(look)", "VOID", "the pose is \(pose), not closed") }
            let rest = [("W", "width"), ("C", "center"), ("G", "gaps"), ("A", "chats")] + Self.otherTabs.map { ("K1", $0) }
            for (rule, subject) in rest { say(rule, "\(subject)-\(look)", "VOID", "the pose is \(pose), not closed") }
            return
        }
        let col = column(look)
        judge(col, look)
        shot("strip-chats-\(look)")
        audit("chats", look)
        for tab in Self.otherTabs { otherTab(tab, look, chats: col) }
    }

    func testStripLight() throws { try strip("StripLight", look: "light") }
    func testStripDark() throws { try strip("StripDark", look: "dark") }

    // MARK: The open leg

    /// K2: the open Duo's bar as it stands, for setting a build beside build 53.
    private func openBar(_ name: String, look: String) throws {
        guard try launch(name, look: look, layout: Self.layoutA) else { return }
        let subjects = ["bar", "capsule", "mic", "compose"]
        guard pose == "open" else {
            for s in subjects { say("K2", "\(s)-\(look)", "VOID", "the pose is \(pose), not open") }
            return
        }
        let win = app.windows.firstMatch.frame
        let slotEls = Self.allTabs.map { byID("tab.\($0)") }.filter { $0.exists }
        let slotFrames: [CGRect] = slotEls.map { $0.frame }
        let slots = slotFrames.sorted { (a: CGRect, b: CGRect) -> Bool in
            if a.minY != b.minY { return a.minY < b.minY }
            return a.minX < b.minX
        }
        guard let first = slots.first, slots.count > 1 else {
            for s in subjects { say("K2", "\(s)-\(look)", "VOID", "window \(f(win)); \(slots.count) tab slots found") }
            return
        }
        let vertical = slots.allSatisfy { abs($0.minX - first.minX) <= Self.tol }
        say("K2", "bar-\(look)", "READ",
            "window \(f(win)); \(slots.count) slots: \(slots.map { f($0) }.joined(separator: " ")); vertical \(vertical)")
        let capsule = slots.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -Self.capsuleInset, dy: -Self.capsuleInset)
        say("K2", "capsule-\(look)", "READ", "capsule \(f(capsule)) (the slots' union grown \(n(Self.capsuleInset)))")
        for (subject, id) in [("mic", "chats.voice"), ("compose", "chats.new")] {
            let all = ids(id).allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
            if let e = all.first(where: { $0.isHittable }) ?? all.first {
                say("K2", "\(subject)-\(look)", "READ", "\(subject) \(f(e.frame)) hittable \(e.isHittable); \(id) in all \(all.count)")
            } else {
                say("K2", "\(subject)-\(look)", "VOID", "no \(id) found")
            }
        }
    }

    func testOpenLight() throws { try openBar("OpenLight", look: "light") }
}
