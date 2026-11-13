import XCTest

/// #637 under the DEBUG-only stand-in (`ColumnStandIn`): on the closed iPhone Duo, where a chat's Back and More stand
/// against the keyboard when the system's marker for Back stands lower than the simulator ever puts it.
///
/// One case a run, named by the script (HERMES_E2E_CASE) with the stand-in's launch arguments (HERMES_E2E_STANDIN, the
/// arguments separated by spaces). Three launches against the mock gateway, each with the chat opened anew, so what one
/// does to the chat's page (Back leaves it) is not under the next one's reads:
///   the reads, with `-vory-geometry-probe` and `-vory-standin-readout`: the frames with the keyboard down, rising, up,
///   leaving and down again;
///   the still, without either (their readouts would be in the picture): the chat with the keyboard up, at rest; then,
///   merged, Back from More's menu;
///   the swipe, without either: merged with the keyboard up, one swipe from the leading edge.
/// The baseline (no stand-in argument at all) is not this test's: it is DuoColumnKeyboardUITests, unchanged, on the same build.
///
/// Lines. `K637 <case> <state> t=<s> | <frames>`: Back ("chat.back"), More ("chat.more"), the dock ("chat.dock"), the
/// stand-in's status block ("standin.status"), and both keyboard numbers: `kbtop`, the app's own (the window's height
/// less the bottom safe inset less the probe's "kb"), which every verdict uses, and `kbelement`, the keyboard element's
/// frame as XCUITest gives it. `K637C`: every element in the side column at least 20 by 20, from one snapshot (type,
/// identifier, frame; no label or value). `K637R`: the app's own readout of the column ("standin.column").
/// `K637N`: notes. `K637M`: with More's menu asked for, merged, every labeled button and menu item on the page (type,
/// identifier, label, frame). `K637W`: with the menu open, every button over 100 pt wide in Back's column, labeled or not
/// (type, identifier, label, frame, and how far its middle is from More's). `K637V <case> <rule> GREEN|RED|VOID | detail`:
/// the verdicts.
///
/// The rules, each judged on the reads named:
///   K1 with the keyboard up, at rest and in every read while it rises: no control of the two on the page ends lower
///      than 8 pt above the app's keyboard top (VOID with neither on the page at rest; its GREEN line says which were).
///   K2 at rest with the keyboard up: neither control meets the dock or the other.
///   K3 at rest, keyboard down and up: neither control meets "standin.status" (VOID with no block).
///   K4 at rest with the keyboard up: each control on the page takes a tap.
///   K5 with the keyboard down again: both frames are the ones before it came up.
///   K4M merged (Back not on the page with the keyboard up, #637): with More's menu open, Back is the first item at the end
///      the menu opens from; it is in sight; it takes a tap as the menu opens (no scroll is made); and no other item of
///      the menu stands between it and that end. VOID where the two are not merged. How each is read, from the buttons on
///      the page with the menu open:
///        the menu's items: buttons with a label, as wide as Back's item (within a point) and in its column. The
///          keyboard's keys are narrower and stand elsewhere; a button with no label is not an item.
///        in sight: inside the window, and above the keyboard's own top while a keyboard is up.
///        the end the menu opens from: the end of its list that is in sight as it opens, by the list's first and last
///          items' frames (the other end runs out of sight where the list is longer than the room). With both ends in
///          sight Back's own end is taken; with neither there is no such end and the verdict is RED.
///        first there, and none between: Back's place in the list counted from that end is 0.
///      The line also prints how many items stand nearer More's middle than Back does: a number, not judged (the system
///      places the menu, and it may lie over More).
///   K4H merged, with More's menu open: the column is as it was at rest before the menu: no Back on the page and More
///      where it stood. VOID where the two are not merged.
///   K6 the column stands as the rule gives it for the case's marker and the keyboard's top: the pair on its markers
///      where More's bottom is on or above the line, else one More and no Back.
///   K4N merged, at rest with the keyboard up: nothing of Back is in the column, of any size: no element with the
///      identifier "chat.back" or "chevron.left" in one snapshot of the app. VOID where not merged. (Whether a glyph is
///      drawn is for the still and an eye; this is the tree.)
///   K4L on the second launch, merged: Back from More's menu leaves the chat: the chat's More is gone and the chat's row
///      is on the page again. VOID where not merged.
///   K4S on the third launch, merged with the keyboard up: one swipe from the leading edge leaves the chat, read the
///      same way. VOID where not merged.
/// A read with no verdict: merged, with More's menu open, how many keyboards are on the page and the app's keyboard
/// overlap (`K637N ... with More's menu open`).
/// Tapped: the chat's row, the message field and, where the two are merged, More (its menu put away by a tap up the
/// thread, and on the second launch its Back); the keyboard leaves by a drag down the thread; on the third launch,
/// merged, one drag from the leading edge. Nothing else in a menu is chosen and nothing is typed or sent.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. The script names the pose (HERMES_E2E_POSE).
@MainActor
final class DuoColumnStandInUITests: XCTestCase {
    private var app: XCUIApplication!
    private var caseName = "unnamed"
    private var began = Date()
    private var shots: URL?
    private static let chatTitle = "Disk cleanup on the log host"
    private static let gap: CGFloat = 8

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func byID(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func f(_ r: CGRect) -> String { String(format: "(%.3f,%.3f,%.3f,%.3f)", r.minX, r.minY, r.width, r.height) }
    private func n(_ v: CGFloat) -> String { String(format: "%.3f", v) }
    private func note(_ s: String) { print("K637N \(caseName) \(s)") }
    private func verdict(_ rule: String, _ v: String, _ detail: String) { print("K637V \(caseName) \(rule) \(v) | \(detail)") }
    /// An element's frame, read only while it is there.
    private func frame(_ e: XCUIElement) -> CGRect? { e.exists ? e.frame : nil }
    private func show(_ r: CGRect?) -> String { r.map { f($0) } ?? "none" }
    private func text(_ id: String) -> String? {
        let e = byID(id)
        guard e.exists else { return nil }
        return (e.label.isEmpty ? (e.value as? String) : e.label) ?? ""
    }

    /// One read of the page.
    private struct Read {
        var state: String
        var back: CGRect?, more: CGRect?, dock: CGRect?, status: CGRect?, keyboardElement: CGRect?
        /// The app's own keyboard top, nil with the keyboard down or no probe.
        var keyboardTop: CGFloat?
        var overlap: CGFloat?
    }

    /// The app's keyboard overlap, from the regions readout's last line ("win WxH kb N").
    private func overlap() -> CGFloat? {
        guard let t = text("geometry.regions"), let r = t.range(of: " kb ", options: .backwards) else { return nil }
        return Double(t[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)).map { CGFloat($0) }
    }
    /// The bottom safe inset, from the window readout ("... safe tT lL bB rR ...").
    private func safeBottom() -> CGFloat? {
        guard let t = text("geometry.window") else { return nil }
        for part in t.split(separator: " ") where part.hasPrefix("b") {
            if let v = Double(part.dropFirst()) { return CGFloat(v) }
        }
        return nil
    }

    private func read(_ state: String, bottom: CGFloat?) -> Read {
        let t = Date().timeIntervalSince(began)
        var r = Read(state: state)
        r.back = frame(byID("chat.back")); r.more = frame(byID("chat.more")); r.dock = frame(byID("chat.dock"))
        r.status = frame(byID("standin.status"))
        let kbs = app.keyboards
        r.keyboardElement = kbs.count > 0 ? frame(kbs.firstMatch) : nil
        r.overlap = overlap()
        if let o = r.overlap, o > 0, let bottom { r.keyboardTop = app.windows.firstMatch.frame.height - bottom - o }
        print("K637 \(caseName) \(state) t=\(String(format: "%.2f", t)) | back \(show(r.back)) more \(show(r.more)) dock \(show(r.dock)) status block \(show(r.status)) kb \(r.overlap.map { n($0) } ?? "none") kbtop \(r.keyboardTop.map { n($0) } ?? "none") kbelement \(show(r.keyboardElement))")
        return r
    }

    /// Reads in a loop for that many seconds.
    private func reads(_ state: String, seconds: Double, bottom: CGFloat?) -> [Read] {
        let until = Date().addingTimeInterval(seconds)
        var all: [Read] = []
        repeat { all.append(read(state, bottom: bottom)) } while Date() < until
        note("\(state): \(all.count) reads in \(String(format: "%.1f", seconds)) s")
        return all
    }

    private func all(_ s: any XCUIElementSnapshot, into out: inout [any XCUIElementSnapshot]) {
        out.append(s)
        for c in s.children { all(c, into: &out) }
    }

    /// Every element in the side column at least 20 by 20, from one snapshot of the app (type, identifier, frame; no
    /// label or value), and the app's own readout of the column. Whether Back and More take a tap is read apart.
    private func column(_ state: String) {
        guard let root = try? app.snapshot() else { note("\(state): no snapshot; no column lines"); return }
        var nodes: [any XCUIElementSnapshot] = []
        all(root, into: &nodes)
        let w = nodes.first(where: { $0.elementType == .window })?.frame ?? root.frame
        // The strip is the trailing 84 pt closed; the readout says the window's own numbers beside it.
        let from = w.maxX - 84
        var count = 0
        for e in nodes {
            let r = e.frame
            guard r.midX > from, r.midX < w.maxX, r.width >= 20, r.height >= 20, r.width < w.width else { continue }
            count += 1
            print("K637C \(caseName) \(state) | type \(e.elementType.rawValue) id '\(e.identifier)' frame \(f(r))")
        }
        note("\(state): \(count) elements in the column of \(nodes.count) in the snapshot")
        print("K637R \(caseName) \(state) | \(text("standin.column")?.replacingOccurrences(of: "\n", with: " | ") ?? "no readout")")
    }

    /// What of Back is in the side column, of any size, from one snapshot of the app: every element whose identifier is
    /// "chat.back" or "chevron.left" (type, identifier, frame). Nil with no snapshot.
    private func backInColumn() -> [String]? {
        guard let root = try? app.snapshot() else { return nil }
        var nodes: [any XCUIElementSnapshot] = []
        all(root, into: &nodes)
        let w = nodes.first(where: { $0.elementType == .window })?.frame ?? root.frame
        let from = w.maxX - 84
        return nodes.filter { ["chat.back", "chevron.left"].contains($0.identifier) && $0.frame.midX > from && $0.frame.midX < w.maxX }
            .map { "type \($0.elementType.rawValue) id '\($0.identifier)' frame \(f($0.frame))" }
    }

    /// Whether the chat's page is left: its More is gone (or takes no tap) and the chat's row is on the page again.
    private func chatLeft() -> (left: Bool, said: String) {
        let more = byID("chat.more")
        let moreGone = !more.exists || !more.isHittable
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (identifier BEGINSWITH 'chats.')", Self.chatTitle)).firstMatch
        let rowBack = row.exists && row.isHittable
        return (moreGone && rowBack, "the chat's More \(moreGone ? "gone" : "still on the page"), the chat's row \(rowBack ? "on the page again" : "not on the page"), keyboards on the page \(app.keyboards.count)")
    }

    /// The menu's own Back: a button labeled "Back" as wide as a menu's item (over 100 pt). The page's Back ("chat.back") and
    /// the chevron inside it carry the same label and are 48 and 44 pt wide; a menu's item here is 250.
    private func menuBack() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == 'Back'")).allElementsBoundByIndex.first(where: { $0.exists && $0.frame.width > 100 })
            ?? app.buttons["vory.no-such-menu-item"].firstMatch
    }

    /// With More's menu asked for: every button, menu and menu item with a label, from one snapshot of the app (type,
    /// identifier, label, frame), keys of the keyboard left out; and whether a known item of the chat's menu is there.
    private func menuLines(_ state: String) {
        guard let root = try? app.snapshot() else { note("\(state): no snapshot; no menu lines"); return }
        var nodes: [any XCUIElementSnapshot] = []
        all(root, into: &nodes)
        let kinds: [XCUIElement.ElementType] = [.button, .menu, .menuItem, .menuButton, .popUpButton]
        var count = 0
        for e in nodes where kinds.contains(e.elementType) && !e.label.isEmpty {
            count += 1
            print("K637M \(caseName) \(state) | type \(e.elementType.rawValue) id '\(e.identifier)' label '\(e.label.prefix(40))' frame \(f(e.frame))")
        }
        let backs = nodes.filter { $0.label == "Back" }.map { "type \($0.elementType.rawValue) id '\($0.identifier)' frame \(f($0.frame))" }
        note("\(state): \(count) labeled buttons and menu items of \(nodes.count) in the snapshot; \"Rename chat\" \(app.buttons["Rename chat"].firstMatch.exists ? "there" : "not there"); labeled Back: \(backs.isEmpty ? "none" : backs.joined(separator: "; "))")
    }

    private func launch(probe: Bool, standIn: [String], url: String, token: String, bundle: String) -> XCUIElement? {
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats",
                               "-colorSchemePreference", "light", "-restore.openChat", "none"] + (probe ? ["-vory-geometry-probe", "-vory-standin-readout"] : []) + standIn
        app.launch()
        began = Date()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (identifier BEGINSWITH 'chats.')", Self.chatTitle)).firstMatch
        return row.waitForExistence(timeout: 40) ? row : nil
    }


    func testTheColumnUnderTheStandIn() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        continueAfterFailure = true
        caseName = e["HERMES_E2E_CASE"].flatMap { $0.isEmpty ? nil : $0 } ?? "unnamed"
        let standIn = (e["HERMES_E2E_STANDIN"] ?? "").split(separator: " ").map(String.init)
        let bundle = e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo"
        shots = e["HERMES_E2E_SHOTS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        note("pose \(e["HERMES_E2E_POSE"] ?? "unknown"); stand-in arguments: \(standIn.isEmpty ? "none" : standIn.joined(separator: " "))")

        // 1. The reads, with the probe.
        guard let row = launch(probe: true, standIn: standIn, url: url, token: token, bundle: bundle) else {
            verdict("LAUNCH", "VOID", "no chat row 40 s after launch"); return
        }
        pause(2)
        let bottom = safeBottom()
        note("window \(f(app.windows.firstMatch.frame)); geometry \(text("geometry.window") ?? "none"); bottom inset read \(bottom.map { n($0) } ?? "none")")
        row.tap()
        guard byID("chat.back").waitForExistence(timeout: 10) || byID("chat.more").waitForExistence(timeout: 2) else {
            verdict("CHAT", "VOID", "neither Back nor More 10 s after the tap on the chat's row"); return
        }
        pause(2)
        let down = read("keyboard down", bottom: bottom)
        column("keyboard down")
        let field = app.textViews["composer.text"].firstMatch
        guard field.waitForExistence(timeout: 10), field.isHittable else { verdict("FIELD", "VOID", "the message field is not there or takes no tap"); return }
        field.tap()
        let rising = reads("keyboard rising", seconds: 2.5, bottom: bottom)
        pause(1)
        let up = read("keyboard up, at rest", bottom: bottom)
        column("keyboard up, at rest")
        let backTaps = byID("chat.back").exists ? byID("chat.back").isHittable : nil
        let moreTaps = byID("chat.more").exists ? byID("chat.more").isHittable : nil
        note("keyboard up, at rest: back takes a tap \(backTaps.map { "\($0)" } ?? "not on the page"); more takes a tap \(moreTaps.map { "\($0)" } ?? "not on the page")")
        // Merged (#637): Back is not on the page; it must be the first item of More's menu. The menu is opened and put
        // away by a tap up the thread; nothing in it is chosen here.
        var backInMenu: (there: Bool, taps: Bool, inside: Bool, end: String, firstThere: String, between: Int, items: Int, nearer: Int)?
        var menuRead: Read?
        // What of Back is in the column at rest, of any size, before anything is tapped (K4N).
        let strays = backInColumn()
        note("keyboard up, at rest: of Back in the column, any size: \(strays.map { $0.isEmpty ? "nothing" : $0.joined(separator: "; ") } ?? "no snapshot")")
        if backTaps == nil, moreTaps == true {
            byID("chat.more").tap()
            pause(1.2)
            note("merged: with More's menu open: keyboards on the page \(app.keyboards.count), kb \(overlap().map { n($0) } ?? "none")")
            // The column and the keyboard as they read with the menu asked for, and what the menu holds (K637M).
            menuRead = read("merged, More's menu open", bottom: bottom)
            menuLines("merged, More's menu open")
            let item = menuBack()
            if item.exists {
                let fr = item.frame
                let win = app.windows.firstMatch.frame
                // The menu's items: buttons as wide as an item, in Back's own column of the page. How many stand nearer More.
                let moreMid = up.more?.midY ?? fr.midY
                let nearer = app.buttons.allElementsBoundByIndex.filter { $0.exists && $0.frame.width > 100 && $0.frame.midX > fr.minX && $0.frame.midX < fr.maxX && abs($0.frame.midY - moreMid) < abs(fr.midY - moreMid) - 0.5 }.count
                // The menu's items (K4M): buttons with a label, as wide as Back's item and in its column, top to bottom.
                let items = app.buttons.allElementsBoundByIndex
                    .filter { $0.exists && !$0.label.isEmpty && abs($0.frame.width - fr.width) < 1 && abs($0.frame.midX - fr.midX) < 1 }
                    .map { (label: String($0.label.prefix(40)), frame: $0.frame) }
                    .sorted { $0.frame.midY < $1.frame.midY }
                // In sight: the window, down to the keyboard's own top while a keyboard is up.
                let sightBottom = app.keyboards.count > 0 ? min(win.maxY, app.keyboards.firstMatch.frame.minY) : win.maxY
                let inside = fr.minY >= win.minY - 0.5 && fr.maxY <= sightBottom + 0.5
                let topIn = items.first.map { $0.frame.minY >= win.minY - 0.5 } ?? false
                let bottomIn = items.last.map { $0.frame.maxY <= sightBottom + 0.5 } ?? false
                let place = items.firstIndex { $0.frame == fr }
                // The end the menu opens from: the end of its list that is in sight; Back's own end with both in sight.
                var end = "neither end in sight", firstThere = "none", between = -1
                if let place {
                    let fromTop = place, fromBottom = items.count - 1 - place
                    if topIn && !bottomIn { end = "top"; between = fromTop }
                    else if bottomIn && !topIn { end = "bottom"; between = fromBottom }
                    else if topIn && bottomIn { end = fromTop <= fromBottom ? "top (both ends in sight)" : "bottom (both ends in sight)"; between = min(fromTop, fromBottom) }
                    if end.hasPrefix("top"), let i = items.first { firstThere = "'\(i.label)' \(f(i.frame))" }
                    if end.hasPrefix("bottom"), let i = items.last { firstThere = "'\(i.label)' \(f(i.frame))" }
                }
                note("merged: the menu's items: \(items.count), from y \(items.first.map { n($0.frame.minY) } ?? "none") to \(items.last.map { n($0.frame.maxY) } ?? "none"); in sight down to \(n(sightBottom)); top in sight \(topIn), bottom in sight \(bottomIn); Back's place from the top \(place.map { "\($0)" } ?? "not among them")")
                // Every button as wide as a menu's item in Back's column, labeled or not, as K4M's count meets them (K637W).
                for e in app.buttons.allElementsBoundByIndex where e.exists && e.frame.width > 100 && e.frame.midX > fr.minX && e.frame.midX < fr.maxX {
                    let d = abs(e.frame.midY - moreMid)
                    print("K637W \(caseName) merged, More's menu open | type \(e.elementType.rawValue) id '\(e.identifier)' label '\(e.label.prefix(40))' frame \(f(e.frame)) | middle \(n(d)) from More's; Back's \(n(abs(fr.midY - moreMid)))")
                }
                backInMenu = (true, item.isHittable, inside, end, firstThere, between, items.count, nearer)
                note("merged: More's menu has Back at \(f(fr)), takes a tap \(item.isHittable), in sight \(inside); the menu opens from its \(end); items between Back and that end \(between); nearer More by distance \(nearer)")
            } else {
                backInMenu = (false, false, false, "no Back", "none", -1, 0, 0)
                note("merged: More's menu has no Back")
            }
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.12)).tap()
            pause(1)
            note("merged: after the tap up the thread, Back in a menu \(menuBack().exists ? "still there" : "gone"); keyboards on the page \(app.keyboards.count)")
        }
        // The keyboard leaves: a drag down the thread, from above the message field.
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.30)).press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.80)))
        _ = reads("keyboard leaving", seconds: 2.5, bottom: bottom)
        pause(1)
        let after = read("keyboard down again", bottom: bottom)
        column("keyboard down again")
        note("keyboards on the page after the drag: \(app.keyboards.count)")

        // 2. The verdicts.
        let onPage = [up.back != nil ? "back" : nil, up.more != nil ? "more" : nil].compactMap { $0 }
        if onPage.isEmpty {
            verdict("K1", "VOID", "neither Back nor More on the page with the keyboard up, at rest")
        } else if let top = up.keyboardTop {
            let limit = top - Self.gap
            var low: [String] = []
            for r in rising + [up] {
                guard let t = r.keyboardTop else { continue }
                for (what, fr) in [("back", r.back), ("more", r.more)] {
                    if let fr, fr.maxY > t - Self.gap + 0.5 { low.append("\(r.state) \(what) bottom \(n(fr.maxY)) against \(n(t - Self.gap))") }
                }
            }
            verdict("K1", low.isEmpty ? "GREEN" : "RED", low.isEmpty
                    ? "on the page at rest: \(onPage.joined(separator: " and ")); back bottom \(up.back.map { n($0.maxY) } ?? "none") more bottom \(up.more.map { n($0.maxY) } ?? "none"), limit \(n(limit)) (kbtop \(n(top)) less \(n(Self.gap))); \(rising.count) rising reads"
                    : "\(low.count) reads too low; first: \(low[0]); last: \(low[low.count - 1]); limit at rest \(n(limit))")
        } else {
            verdict("K1", "VOID", "no keyboard top from the probe with the keyboard up (kb \(up.overlap.map { n($0) } ?? "none"), bottom inset \(bottom.map { n($0) } ?? "none"))")
        }
        var meets: [String] = []
        if let b = up.back, let m = up.more, b.intersects(m) { meets.append("back and more") }
        if let d = up.dock {
            if let b = up.back, b.intersects(d) { meets.append("back and the dock") }
            if let m = up.more, m.intersects(d) { meets.append("more and the dock") }
        }
        verdict("K2", up.dock == nil ? "VOID" : (meets.isEmpty ? "GREEN" : "RED"), up.dock == nil ? "no dock on the page" : (meets.isEmpty ? "none meet; dock \(show(up.dock))" : meets.joined(separator: "; ")))
        if down.status == nil && up.status == nil {
            verdict("K3", "VOID", "no status block (no -vory-standin-status)")
        } else {
            var over: [String] = []
            for r in [down, up] {
                guard let s = r.status else { continue }
                for (what, fr) in [("back", r.back), ("more", r.more)] {
                    if let fr, fr.intersects(s) { over.append("\(r.state) \(what) \(f(fr)) over the block ending \(n(s.maxY))") }
                }
            }
            verdict("K3", over.isEmpty ? "GREEN" : "RED", over.isEmpty ? "block \(show(up.status)); back top \(up.back.map { n($0.minY) } ?? "none") more top \(up.more.map { n($0.minY) } ?? "none")" : over.joined(separator: "; "))
        }
        let noTap = [("back", backTaps), ("more", moreTaps)].filter { $0.1 == false }.map { $0.0 }
        verdict("K4", backTaps == nil && moreTaps == nil ? "VOID" : (noTap.isEmpty ? "GREEN" : "RED"),
                noTap.isEmpty ? "back \(backTaps.map { "\($0)" } ?? "not on the page") more \(moreTaps.map { "\($0)" } ?? "not on the page")" : "no tap: \(noTap.joined(separator: ", "))")
        let back5 = down.back == after.back && down.more == after.more
        verdict("K5", back5 ? "GREEN" : "RED", "before back \(show(down.back)) more \(show(down.more)); after back \(show(after.back)) more \(show(after.more))")
        // K4M and K6 (#637): merged, Back is in More's menu, first; and the column stands as the rule gives it for this
        // case's marker and the keyboard's top, with the app's own readout saying the same state.
        if let b = backInMenu {
            verdict("K4M", b.there && b.taps && b.inside && b.between == 0 ? "GREEN" : "RED", "Back in More's menu \(b.there ? "there" : "not there"); the menu (\(b.items) items) opens from its \(b.end); first there \(b.firstThere); Back takes a tap \(b.taps), in sight \(b.inside), items between Back and that end \(b.between); nearer More by distance, not judged: \(b.nearer)")
        } else {
            verdict("K4M", "VOID", "not merged with the keyboard up (Back on the page, or More takes no tap)")
        }
        // K4H: merged before the menu means merged with the menu open. The keyboard reads shorter while a menu is open
        // over it; the column must not follow that.
        if let mr = menuRead {
            let held = mr.back == nil && mr.more != nil && mr.more == up.more
            verdict("K4H", held ? "GREEN" : "RED", "with More's menu open: back \(show(mr.back)) more \(show(mr.more)) kb \(mr.overlap.map { n($0) } ?? "none"); at rest before it: back \(show(up.back)) more \(show(up.more)) kb \(up.overlap.map { n($0) } ?? "none")")
        } else {
            verdict("K4H", "VOID", "not merged with the keyboard up (the menu was not asked for)")
        }
        // K4N: where the rule gives one More, nothing of Back is in the column, of any size.
        var ruleMarker: CGFloat? = down.back?.midY
        if let i = standIn.firstIndex(of: "-vory-standin-marker"), standIn.indices.contains(i + 1), let v = Double(standIn[i + 1]) { ruleMarker = CGFloat(v) }
        var mergedByRule: Bool?
        if let m = ruleMarker, let top = up.keyboardTop { mergedByRule = m + 60 + 24 > top - Self.gap }
        if mergedByRule == true {
            if let strays { verdict("K4N", strays.isEmpty ? "GREEN" : "RED", strays.isEmpty ? "nothing of Back in the column" : "in the column: \(strays.joined(separator: "; "))") }
            else { verdict("K4N", "VOID", "no snapshot at rest") }
        } else {
            verdict("K4N", "VOID", mergedByRule == nil ? "no marker for this case or no keyboard top from the probe" : "the rule gives the pair here")
        }
        let marker = standIn.firstIndex(of: "-vory-standin-marker").flatMap { standIn.indices.contains($0 + 1) ? Double(standIn[$0 + 1]) : nil }.map { CGFloat($0) }
        let said = text("standin.column") ?? ""
        if let m = marker ?? down.back.map({ $0.midY }), let top = up.keyboardTop {
            let limit = top - Self.gap
            let pair = m + 60 + 24 <= limit
            let wantMore = pair ? m + 60 : min(m, limit - 24)
            let stands = pair ? (up.back.map { abs($0.midY - m) <= 0.5 } ?? false) && (up.more.map { abs($0.midY - wantMore) <= 0.5 } ?? false)
                              : up.back == nil && (up.more.map { abs($0.midY - wantMore) <= 0.5 } ?? false)
            verdict("K6", stands ? "GREEN" : "RED", "marker \(n(m)) limit \(n(limit)): the rule gives \(pair ? "the pair, back \(n(m)) more \(n(wantMore))" : "one More at \(n(wantMore))"); on the page back \(up.back.map { n($0.midY) } ?? "none") more \(up.more.map { n($0.midY) } ?? "none")")
        } else {
            verdict("K6", "VOID", "no marker for this case or no keyboard top from the probe")
        }
        note("the readout with the keyboard down again: \(said.replacingOccurrences(of: "\n", with: " | "))")
        app.terminate()

        // 3. The still, without the probe: the chat with the keyboard up, at rest.
        guard let row2 = launch(probe: false, standIn: standIn, url: url, token: token, bundle: bundle) else {
            verdict("STILL", "VOID", "no chat row 40 s after the second launch"); return
        }
        pause(1)
        row2.tap()
        let field2 = app.textViews["composer.text"].firstMatch
        guard field2.waitForExistence(timeout: 10), field2.isHittable else { verdict("STILL", "VOID", "the message field is not there on the second launch"); return }
        pause(1.5)
        field2.tap()
        pause(3)
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = "standin-\(caseName)"; a.lifetime = .keepAlways; add(a)
        if let shots {
            try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: shots.appendingPathComponent("standin-\(caseName).png"))
            note("still standin-\(caseName).png, keyboards on the page \(app.keyboards.count)")
        } else {
            note("no shots folder given: the still is the result bundle's only")
        }
        // Merged (#637): Back from More's menu leaves the chat. Last, since it ends the chat's page.
        if !byID("chat.back").exists, byID("chat.more").exists, byID("chat.more").isHittable {
            byID("chat.more").tap()
            pause(1.2)
            // The open menu, a still of its own (no probe on this launch, so no readout is in the picture).
            let ms = XCUIScreen.main.screenshot()
            let ma = XCTAttachment(screenshot: ms); ma.name = "standin-\(caseName)-menu"; ma.lifetime = .keepAlways; add(ma)
            if let shots {
                try? ms.pngRepresentation.write(to: shots.appendingPathComponent("standin-\(caseName)-menu.png"))
                note("still standin-\(caseName)-menu.png, keyboards on the page \(app.keyboards.count)")
            }
            menuLines("second launch, More's menu open")
            let item = menuBack()
            if item.exists, item.isHittable {
                item.tap()
                pause(2.5)
                let l = chatLeft()
                verdict("K4L", l.left ? "GREEN" : "RED", "after Back from More's menu: \(l.said)")
            } else {
                verdict("K4L", "RED", "merged, but More's menu has no Back that takes a tap")
            }
        } else {
            verdict("K4L", "VOID", "not merged on the second launch (Back on the page, or no More)")
        }
        app.terminate()

        // 4. The swipe, on a launch of its own: merged with the keyboard up, one swipe from the leading edge (#637: the
        // other way back when Back is not on the page). Last, since it ends the chat's page.
        guard let row3 = launch(probe: false, standIn: standIn, url: url, token: token, bundle: bundle) else {
            verdict("K4S", "VOID", "no chat row 40 s after the third launch"); return
        }
        pause(1)
        row3.tap()
        let field3 = app.textViews["composer.text"].firstMatch
        guard field3.waitForExistence(timeout: 10), field3.isHittable else { verdict("K4S", "VOID", "the message field is not there on the third launch"); return }
        pause(1.5)
        field3.tap()
        pause(3)
        if !byID("chat.back").exists, byID("chat.more").exists, app.keyboards.count > 0 {
            // From 2 pt inside the window's leading edge, a third of the way down (over the thread, above the keyboard),
            // across three quarters of the window, fast.
            let w3 = app.windows.firstMatch
            let from = w3.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.30)).withOffset(CGVector(dx: 2, dy: 0))
            from.press(forDuration: 0.05, thenDragTo: w3.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.30)), withVelocity: .fast, thenHoldForDuration: 0)
            pause(2.5)
            let l = chatLeft()
            verdict("K4S", l.left ? "GREEN" : "RED", "after one swipe from the leading edge with the keyboard up: \(l.said)")
        } else {
            verdict("K4S", "VOID", "not merged with the keyboard up on the third launch (Back on the page, no More, or no keyboard)")
        }
        app.terminate()
    }
}
