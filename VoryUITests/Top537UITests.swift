import XCTest

/// #537: on the open iPhone Duo on its side, with Chats in two columns, the top of the list column can come back out of
/// place after the app was left and reopened (the bot face and the title further right, the search field gone, the list
/// lower), and a relaunch puts it right. This test only reads: it asserts nothing about a fix.
///
/// One leg per launch, in the demo (`-vory-demo`). It reads the top of the Chats list once the list has loaded (BEFORE),
/// leaves the app and comes back several times, reading after each return (AFTER), then quits, launches again and reads
/// once more (RELAUNCH). Nothing in the app is tapped at any point, so the demo is as it starts.
///
/// Every read is one snapshot of the app's elements, so its frames belong to one moment. From it, in window points:
/// - the app and its window;
/// - every navigation bar, left to right (each tab keeps its own), and which of them is the list column's (listBar);
/// - everything in that bar that has a label or an identifier, left to right (item1, item2, ...), with the bot face
///   ("Profile: ...") and the title ("Chats") named apart, the count of titles and of "Refreshing" elements;
/// - the search field (there or not, and its frame) and how many there are;
/// - the Scheduled row, the first project header and how many project headers there are;
/// - the list itself and its first three cells;
/// - the empty detail ("chats.noChat"), the proof of two columns.
///
/// Lines, all starting `T537`:
/// - `T537 <PHASE> trip=<n> <key> (x,y,w,h)` and `T537 <PHASE> trip=<n> counts ...`: a read as it was taken.
/// - `T537 AWAY ...` and `T537 BACK ...`: the app's state while away and on return, and when the first read came.
/// - `T537 SAME trip=<n> way=<way> wait=<s>` or `T537 MOVED trip=<n> way=<way> wait=<s> | <what moved, with numbers>`:
///   the read after a return beside BEFORE, 0.5 pt allowed. The first three cells are printed and noted (`T537 ROWS`),
///   not judged: the demo's own chats can change their rows.
/// - `T537 UNSETTLED trip=<n> ...`: two reads a second apart were still not equal 5 s after the return. Its last read is
///   judged like any other and the line says so; it is a finding of its own, never SAME.
/// - `T537 LATE trip=<n> ...`: the first read after the return was not the settled one.
/// - `T537 RELAUNCH SAME` or `T537 RELAUNCH MOVED | ...`: the read after a relaunch beside BEFORE.
/// - `T537 SETUP ...`: the taps made before BEFORE for a leg that starts from another state (see T537_SETUP), or none.
/// - `T537 STEP trip=<n> ...`: the read after a return beside the read before it (BEFORE for the first trip), so a page
///   that changes again, or back, at a later return is read and not assumed.
/// - `T537 PULL ...`: one drag down on the list after the last trip, only if the search field is gone then: how far,
///   from what, and whether the field is there after it. A read of its own (`T537 AFTERPULL` frames), never judged.
/// - `T537 BAR <PHASE> trip=<n> ...`: every element inside the list column's bar as the snapshot holds it, drawn or not,
///   in its own order: depth, type, label, identifier, frame, enabled. Printed with each read, never judged.
/// - `T537 HIT <PHASE> trip=<n> ...`: for BEFORE, the first return and after the pull, whether each element wholly left
///   of the face in its row can be hit, asked of the live elements after the read. Never judged.
/// - `T537 RESULT MOVED <k> of <n>` or `T537 RESULT SAME <n> of <n>`, with the UNSETTLED count.
/// - `T537 VOID <why>`: the leg could not get to its question. It fails the test; it is not a reading. A trip on which
///   the app never left the front is VOID (`AWAY ... left=false`), and no RESULT line follows it.
///
/// The script names the leg: T537_WAY is `home` (the Home button, a wait, the app again), `app` (Settings in front, a
/// wait, the app again) or `fold` (the app stays in front while the Duo is closed and opened again from outside; the
/// test and the script take turns by files in T537_DIR, and the closed pose is read apart as `T537 CLOSED`, compared
/// with nothing; AFTER is read once the Duo is open again). T537_WAITS is the waits in
/// seconds ("2,10,45") and T537_TRIPS the trips per wait. T537_SETUP names the state the leg starts from: none (the
/// demo as it starts, no tap at all), `filter` (the list narrowed to one of the demo's projects) or `chat` (a chat open
/// in the detail column), `sidebar` (the list column hidden and shown again with the split view's button) or
/// `refresh`; a setup's taps come before BEFORE and none after. `refresh` alone touches after BEFORE, and reads it apart:
/// BEFORE at rest, then one full pull on the list, then `T537 PRE` (one read at once, which must show the refresh
/// running, with the app's own hold on the spinner as a launch argument), then the trip; AFTER is judged against
/// BEFORE as always and also printed beside PRE (`T537 FROMPRE`). One pull and one trip a launch. Skipped unless
/// HERMES_E2E_BUNDLE is set. T537_COLUMNS=one (a phone, the closed Duo) drops the two-columns rules and asks only for
/// the list. T537_SCROLL=1 adds one scroll of the list before the relaunch, read apart (`T537 SCROLL`, frames as
/// `T537 SCROLLED`): whether the search field stays under the bar while the list is scrolled. T537_STRICT=1 makes the
/// reader a gate (`T537 STRICT PASS`, `STRICT KNOWN` or `STRICT FAIL`): a judged MOVED fails it and, in two columns, so
/// does a BEFORE or a read after a return without the search field, or a field that scrolled away. In two columns on
/// the open Duo (HERMES_E2E_POSE=side) a trip whose only differences are the two known moves (`T537 KNOWN trip=<n>`: another tab's bar 54 higher; the Chats
/// title, its bar item and the Refreshing marker up to 1 pt in x; no row moved) does not fail it: with such trips and
/// no other fault the line is `STRICT KNOWN` and names both. An extra leading item in the list column's bar (elements
/// wholly left of the face in its row: the `leading` count, with `barElements` the bar's whole count) is said per trip
/// as `T537 LEADING trip=<n>`, is never KNOWN and fails the gate in two columns. The fold leg and the plain app
/// leg, on any device, end with a read under a refresh: the list column's bar in two columns, the app's own top bar in one (`T537 REFRESHREAD`, frames as `T537 REFRESHING`): a READ, no verdict. `STRICT PASS` stays no difference at all. T537_SCHEDULED=1 opens the
/// Scheduled section for the leg by its saved default as a launch argument (no tap), so the list is longer.
@MainActor
final class Top537UITests: XCTestCase {
    private var app: XCUIApplication!
    private var shots: URL?
    private var way = "home"
    private let tolerance: CGFloat = 0.5

    private struct Reading {
        var frames: [(key: String, frame: CGRect)] = []
        var counts: [(key: String, n: Int)] = []
        func frame(_ key: String) -> CGRect? { frames.first { $0.key == key }?.frame }
        func count(_ key: String) -> Int { counts.first { $0.key == key }?.n ?? 0 }
        /// Every element inside the list column's bar as the snapshot holds it, in its own order: not judged.
        var bar: [String] = []
    }

    // MARK: Small things

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func f(_ r: CGRect) -> String { String(format: "(%.1f,%.1f,%.1f,%.1f)", r.minX, r.minY, r.width, r.height) }
    private func n(_ v: CGFloat) -> String { String(format: "%+.1f", v) }
    private func say(_ s: String) { print("T537 \(s)") }
    private func stateName(_ s: XCUIApplication.State) -> String {
        switch s {
        case .unknown: return "unknown"
        case .notRunning: return "notRunning"
        case .runningBackgroundSuspended: return "suspended"
        case .runningBackground: return "background"
        case .runningForeground: return "foreground"
        @unknown default: return "other(\(s.rawValue))"
        }
    }

    /// A still of the open display, taken from outside: neither the main screen nor the app's own screenshot is that
    /// display on a Duo on its side (both gave one unchanging image). The test asks by writing `shot-<name>.req` into
    /// T537_DIR and waits up to 8 s for `shot-<name>.done`, which the script writes once it has shot the display. With
    /// no T537_DIR, or no answer, there is no still, and that is said once.
    private func still(_ name: String) {
        guard shots != nil, let dir = ProcessInfo.processInfo.environment["T537_DIR"], !dir.isEmpty else { return }
        let base = URL(fileURLWithPath: dir).appendingPathComponent("shot-\(name)")
        FileManager.default.createFile(atPath: base.appendingPathExtension("req").path, contents: Data())
        let done = base.appendingPathExtension("done").path
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: done), Date() < deadline { pause(0.25) }
        if !FileManager.default.fileExists(atPath: done), !stillMissed { stillMissed = true; say("STILL \(name): not taken in 8 s (no more is said of later ones)") }
    }
    private var stillMissed = false
    /// One column (T537_COLUMNS=one): the two-columns rules are not asked. Strict (T537_STRICT=1): the test fails on a
    /// judged MOVED and, in two columns, on any read without the search field.
    private var oneColumn = false
    private var strict = false
    /// The open Duo on its side (HERMES_E2E_POSE=side), the only pose where a trip can be KNOWN: on the iPad and in
    /// one column the two known moves were not read, and a MOVED there fails the strict gate as before.
    private var openDuo = false

    // MARK: Reading

    private func all(_ s: any XCUIElementSnapshot, into out: inout [any XCUIElementSnapshot]) {
        out.append(s)
        for c in s.children { all(c, into: &out) }
    }

    /// One line for an element and each of its descendants, whatever their size, label or identifier: for `T537 BAR`.
    private func everything(in s: any XCUIElementSnapshot, depth: Int, into out: inout [String]) {
        out.append("depth=\(depth) type=\(s.elementType.rawValue) label='\(String(s.label.prefix(40)))' id='\(String(s.identifier.prefix(40)))' \(f(s.frame)) enabled=\(s.isEnabled)")
        for c in s.children { everything(in: c, depth: depth + 1, into: &out) }
    }

    /// One snapshot of the app, read into frames and counts. Nil when the snapshot could not be taken.
    private func read() -> Reading? {
        guard let root = try? app.snapshot() else { return nil }
        var nodes: [any XCUIElementSnapshot] = []
        all(root, into: &nodes)
        var r = Reading()
        r.frames.append(("app", root.frame))
        // The app's own frame can read in the device's upright space on a Duo on its side; the window's is the layout's.
        let window = nodes.first(where: { $0.elementType == .window })?.frame ?? root.frame
        r.frames.append(("window", window))

        // Every tab keeps its stack, so there is a bar per tab at the same place. The list column's is the one that
        // holds the bot face; failing that the leftmost one narrower than the window; failing that the first. The rule
        // that chose is in the key, so a change of rule between two reads shows as a difference.
        let bars = nodes.filter { $0.elementType == .navigationBar && $0.frame.width > 0 }
            .sorted { $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
        r.counts.append(("bars", bars.count))
        var chosen: (index: Int, rule: String)?
        for (i, b) in bars.enumerated() {
            r.frames.append(("bar\(i + 1)", b.frame))
            var inside: [any XCUIElementSnapshot] = []
            all(b, into: &inside)
            if chosen == nil, inside.contains(where: { $0.label.hasPrefix("Profile:") }) { chosen = (i, "face") }
        }
        if chosen == nil, let i = bars.firstIndex(where: { $0.frame.width < window.width - 1 }) { chosen = (i, "narrow") }
        if chosen == nil, !bars.isEmpty { chosen = (0, "first") }
        let listBar = chosen.map { bars[$0.index] }
        if let chosen, let listBar { r.frames.append(("listBar[bar\(chosen.index + 1) by \(chosen.rule)]", listBar.frame)) }

        var titles = 0, refreshing = 0, items = 0, leading = 0
        if let bar = listBar {
            var inBar: [any XCUIElementSnapshot] = []
            all(bar, into: &inBar)
            everything(in: bar, depth: 0, into: &r.bar)
            let named = inBar.dropFirst().filter { !($0.label.isEmpty && $0.identifier.isEmpty) && $0.frame.width > 0 }
                .sorted { $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
            for e in named {
                items += 1
                let name = String((e.identifier.isEmpty ? e.label : e.identifier).prefix(40))
                r.frames.append(("item\(items)[type \(e.elementType.rawValue): \(name)]", e.frame))
                if e.elementType == .staticText, e.label == "Chats" { titles += 1; if titles == 1 { r.frames.append(("title", e.frame)) } }
            }
            if let face = named.first(where: { $0.label.hasPrefix("Profile:") }) { r.frames.append(("face", face.frame)) }
            // Each one is printed too, whatever its size: a wheel at rest can be there with no width.
            let wheels = inBar.filter { $0.label == "Refreshing" || $0.elementType == .activityIndicator || $0.elementType == .progressIndicator }
            refreshing = wheels.count
            for (i, e) in wheels.enumerated() { r.frames.append(("refreshing\(i + 1)[type \(e.elementType.rawValue): \(String(e.label.prefix(40)))]", e.frame)) }
            // The elements of the bar that lie wholly left of the face, in the face's row, drawn or not: none on a
            // sound page. An extra leading item (the second half of #537) shows here and pushes the face right.
            if let face = named.first(where: { $0.label.hasPrefix("Profile:") })?.frame {
                leading = inBar.dropFirst().filter { $0.frame.maxX <= face.minX + 0.5 && $0.frame.minY < face.maxY && $0.frame.maxY > face.minY }.count
            }
        }
        r.counts.append(("barItems", items))
        r.counts.append(("titles", titles))
        r.counts.append(("refreshing", refreshing))

        // The list column ends where its bar ends (the window's middle if no bar was found).
        let columnEnd = listBar?.frame.maxX ?? window.midX
        let fields = nodes.filter { $0.elementType == .searchField }
        r.counts.append(("searchFields", fields.count))
        if let s = fields.first(where: { $0.frame.midX < columnEnd }) ?? fields.first { r.frames.append(("search", s.frame)) }

        if let s = nodes.first(where: { $0.identifier == "chats.scheduled" }) { r.frames.append(("scheduled", s.frame)) }
        let projects = nodes.filter { $0.identifier.hasPrefix("chats.project.") }.sorted { $0.frame.minY < $1.frame.minY }
        r.counts.append(("projectHeaders", projects.count))
        if let p = projects.first { r.frames.append(("project1", p.frame)) }

        // The Chats list is the scrolling list that holds the Scheduled row; failing that the first one that starts in
        // the list column. Its cells are its own, never another tab's.
        var cells: [any XCUIElementSnapshot] = []
        var lists: [(node: any XCUIElementSnapshot, inside: [any XCUIElementSnapshot])] = []
        for l in nodes where (l.elementType == .collectionView || l.elementType == .table) && l.frame.height > 0 {
            var inside: [any XCUIElementSnapshot] = []
            all(l, into: &inside)
            lists.append((l, inside))
        }
        if let list = lists.first(where: { $0.inside.contains(where: { $0.identifier == "chats.scheduled" }) })
            ?? lists.first(where: { $0.node.frame.minX < columnEnd && $0.node.frame.width < window.width - 1 })
            ?? lists.first(where: { $0.node.frame.minX < columnEnd }) {
            r.frames.append(("list", list.node.frame))
            cells = list.inside.filter { $0.elementType == .cell && $0.frame.height > 0 }.sorted { $0.frame.minY < $1.frame.minY }
        }
        r.counts.append(("cells", cells.count))
        // Last, so the counts line starts as it always did: every element of the list column's bar, and those left
        // of the face. Both are judged like any count.
        r.counts.append(("barElements", r.bar.count))
        r.counts.append(("leading", leading))
        for (i, c) in cells.prefix(3).enumerated() { r.frames.append(("cell\(i + 1)", c.frame)) }

        if let d = nodes.first(where: { $0.identifier == "chats.noChat" }) { r.frames.append(("noChat", d.frame)) }
        // The project filter's own row in the list (its "Show all" button), an open chat's composer, and the detail
        // column's bar (the leftmost bar that starts at or right of the list column's end).
        if let s = nodes.first(where: { $0.elementType == .button && $0.label == "Show all" && $0.frame.midX < columnEnd && $0.frame.width > 0 }) {
            r.frames.append(("showAll", s.frame))
        }
        if let c = nodes.first(where: { $0.identifier == "composer.text" && $0.frame.width > 0 }) { r.frames.append(("composer", c.frame)) }
        if let b = bars.first(where: { $0.frame.minX >= columnEnd - 1 }) { r.frames.append(("detailBar", b.frame)) }
        return r
    }

    private func show(_ phase: String, _ trip: Int, _ r: Reading) {
        for e in r.frames { say("\(phase) trip=\(trip) \(e.key) \(f(e.frame))") }
        say("\(phase) trip=\(trip) counts " + r.counts.map { "\($0.key)=\($0.n)" }.joined(separator: " ")
            + " search=\(r.frame("search") == nil ? "gone" : "there") projectHeader=\(r.frame("project1") == nil ? "none" : "there")"
            + " filterRow=\(r.frame("showAll") == nil ? "none" : "there") composer=\(r.frame("composer") == nil ? "none" : "there")")
        // Every element of the list column's bar, drawn or not: read with the rest, printed apart, never judged.
        say("BAR \(phase) trip=\(trip) count=\(r.bar.count)")
        for (i, line) in r.bar.enumerated() { say("BAR \(phase) trip=\(trip) #\(i) \(line)") }
    }

    /// Whether each element of the list column's bar that lies wholly left of the face, in the face's row, can be hit. A
    /// snapshot does not carry that, so it is asked of the live elements, after the read and apart from it: `T537 HIT`
    /// lines, not judged. Asked for BEFORE, the first return and after the pull only, since each ask is a query.
    private func showHits(_ phase: String, _ trip: Int, _ r: Reading) {
        guard let face = r.frame("face") else { say("HIT \(phase) trip=\(trip) not asked: no face in the read"); return }
        let bar = app.navigationBars.containing(NSPredicate(format: "label BEGINSWITH 'Profile:'")).firstMatch
        guard bar.exists else { say("HIT \(phase) trip=\(trip) not asked: the bar with the face was not found"); return }
        let inside = bar.descendants(matching: .any).allElementsBoundByIndex
        var asked = 0
        for e in inside.prefix(60) where e.exists {
            let fr = e.frame
            guard fr.maxX <= face.minX + 0.5, fr.minY < face.maxY, fr.maxY > face.minY else { continue }
            asked += 1
            say("HIT \(phase) trip=\(trip) type=\(e.elementType.rawValue) label='\(String(e.label.prefix(40)))' id='\(String(e.identifier.prefix(40)))' \(f(fr)) hittable=\(e.isHittable)")
        }
        say("HIT \(phase) trip=\(trip) asked=\(asked): the elements wholly left of the face in its row, of \(inside.count) in the bar")
    }

    /// Whether a key is one of the first three cells, which are noted and not judged.
    private func isRow(_ key: String) -> Bool { key.hasPrefix("cell") }

    /// Whether everything that differs between two reads is one of the two known moves of a return in two columns on
    /// the open Duo (on build 54 too, and outside #537's first half), and at least one thing differs:
    /// 1. a bar that is not the list column's own, 54 higher and otherwise where it was;
    /// 2. the Chats title, its bar item and the Refreshing marker, up to 1 pt in x and otherwise as they were.
    /// Anything else is not known: the list column's bar, the search field, the face, any other bar item, a button, a
    /// count, something gone or new, or a row (the first three cells and the cell count, which are noted apart).
    /// The title's slot is not in a read's frames (it is in the `BAR` lines, never judged), so it is not asked here.
    private func onlyKnownMoves(_ a: Reading, _ b: Reading) -> Bool {
        guard let listKey = a.frames.map(\.key).first(where: { $0.hasPrefix("listBar[") }),
              b.frames.contains(where: { $0.key == listKey }) else { return false }
        // "listBar[bar3 by face]" names the list column's own bar: "bar3".
        let ownBar = String(listKey.dropFirst("listBar[".count).prefix { $0 != " " })
        guard a.frames.map(\.key) == b.frames.map(\.key) else { return false }
        // An extra leading item is never known (its counts differ too; said here so it does not rest on that alone).
        guard b.count("leading") <= a.count("leading"), b.count("barElements") == a.count("barElements") else { return false }
        for c in a.counts where b.count(c.key) != c.n { return false }
        let titleItem = "[type \(XCUIElement.ElementType.staticText.rawValue): Chats]"
        var seen = 0
        for e in a.frames {
            guard let y = b.frame(e.key) else { return false }
            let x = e.frame
            let dx = y.minX - x.minX, dy = y.minY - x.minY, dw = y.width - x.width, dh = y.height - x.height
            if abs(dx) <= tolerance, abs(dy) <= tolerance, abs(dw) <= tolerance, abs(dh) <= tolerance { continue }
            let k = e.key
            if k.hasPrefix("bar"), Int(k.dropFirst(3)) != nil, k != ownBar {
                guard abs(dx) <= tolerance, abs(dy) <= tolerance, abs(dw) <= tolerance, abs(dh - 54) <= tolerance else { return false }
            } else if k == "title" || (k.hasPrefix("item") && k.hasSuffix(titleItem)) || k.hasPrefix("refreshing") {
                guard abs(dx) <= 1, abs(dy) <= tolerance, abs(dw) <= tolerance, abs(dh) <= tolerance else { return false }
            } else {
                return false
            }
            seen += 1
        }
        return seen > 0
    }

    /// What differs between two reads, as words with numbers: the judged ones, and the rows apart.
    private func differences(_ a: Reading, _ b: Reading) -> (judged: [String], rows: [String]) {
        var judged: [String] = [], rows: [String] = []
        var keys = a.frames.map(\.key)
        for k in b.frames.map(\.key) where !keys.contains(k) { keys.append(k) }
        for k in keys {
            var d: String?
            switch (a.frame(k), b.frame(k)) {
            case let (x?, y?):
                let dx = y.minX - x.minX, dy = y.minY - x.minY, dw = y.width - x.width, dh = y.height - x.height
                if abs(dx) > tolerance || abs(dy) > tolerance || abs(dw) > tolerance || abs(dh) > tolerance {
                    d = "\(k) dx=\(n(dx)) dy=\(n(dy)) dw=\(n(dw)) dh=\(n(dh))"
                }
            case (_?, nil): d = "\(k) gone"
            case (nil, _?): d = "\(k) new"
            default: break
            }
            if let d { if isRow(k) { rows.append(d) } else { judged.append(d) } }
        }
        for c in a.counts where c.key != "cells" && b.count(c.key) != c.n { judged.append("\(c.key) \(c.n)->\(b.count(c.key))") }
        if a.count("cells") != b.count("cells") { rows.append("cells \(a.count("cells"))->\(b.count("cells"))") }
        return (judged, rows)
    }

    /// Reads until two reads about a second apart are equal in what is judged, `limit` seconds at most. The first read, the last one,
    /// when the first came (seconds after `since`), whether it settled, and how many reads it took.
    private func settledRead(since: Date, limit: Double) -> (first: Reading?, last: Reading?, firstAt: Double, settled: Bool, reads: Int) {
        guard let first = read() else { return (nil, nil, Date().timeIntervalSince(since), false, 0) }
        let firstAt = Date().timeIntervalSince(since)
        var last = first, reads = 1
        let deadline = Date().addingTimeInterval(limit)
        while true {
            pause(1)
            guard let next = read() else { return (first, last, firstAt, false, reads) }
            reads += 1
            // Settled on what is judged; the rows may still be changing (the demo's own chats), which is noted.
            let d = differences(last, next)
            if d.judged.isEmpty {
                if !d.rows.isEmpty { say("ROWS settling | " + d.rows.joined(separator: "; ")) }
                return (first, next, firstAt, true, reads)
            }
            last = next
            if Date() >= deadline { return (first, last, firstAt, false, reads) }
        }
    }

    // MARK: The app

    private func launch() throws {
        guard let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty else {
            throw XCTSkip("HERMES_E2E_BUNDLE not set")
        }
        app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-vory-demo", "-companionPromptShown", "YES", "-launchTab", "chats"] + launchExtras
        app.launch()
    }
    /// Launch arguments a leg adds for every launch of its own (the refresh leg's hold on the spinner).
    private var launchExtras: [String] = []

    /// The refresh leg's touch between BEFORE and the trip, read apart: one full pull on the Chats list (a slow drag of
    /// `refreshDistance` points down from the middle of the Scheduled row), then PRE, one read at once and not waited to
    /// settle. PRE must show the refresh running: a "Refreshing" element of the bar with a width, or more of them than
    /// BEFORE had. Nil with the VOID said if it does not, since the trip would then not leave under a refresh.
    private let refreshDistance: CGFloat = 220
    private func pullToRefresh(trip: Int, before: Reading) -> Reading? {
        let row = app.descendants(matching: .any).matching(identifier: "chats.scheduled").firstMatch
        guard row.exists, row.isHittable else { say("VOID trip=\(trip): no Scheduled row to start the refresh pull from"); return nil }
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: refreshDistance)), withVelocity: .slow, thenHoldForDuration: 0.2)
        guard let pre = read() else { say("VOID trip=\(trip): no snapshot after the refresh pull"); return nil }
        show("PRE", trip, pre)
        let wheels = pre.frames.filter { $0.key.hasPrefix("refreshing") }
        let running = wheels.contains { $0.frame.width > 0.5 } || pre.count("refreshing") > before.count("refreshing")
        say("PRE trip=\(trip) pull=\(Int(refreshDistance)) pt down from the Scheduled row | refresh \(running ? "running" : "not running") (refreshing \(before.count("refreshing"))->\(pre.count("refreshing")), widths \(wheels.map { String(format: "%.1f", $0.frame.width) }.joined(separator: ",")))")
        guard running else { say("VOID trip=\(trip): the refresh was not in flight when the app was to leave"); return nil }
        return pre
    }

    /// The last READ of the fold leg and the plain app leg in two columns (the open Duo, the iPad), after the strict line and before the relaunch: one full pull on the Chats list (as
    /// `pullToRefresh`, but `refreshReadDistance` points), then three reads of the list column's bar about half a second apart while the refresh is held
    /// open (`-vory-refresh-hold`, DEBUG). Each prints `T537 REFRESHREAD read=<i>`: when it was taken, every refresh
    /// mark's frame and whether it lies left or right of the face and is wide (`wideWheel` points or more), the
    /// `leading` count and the bar's count. The first read's frames follow as `T537 REFRESHING`. No verdict, not part
    /// of STRICT, and the relaunch after it starts the app afresh. The last line says one of three in capitals: the
    /// title's wheel was seen open (a wide mark right of the face); it was not seen though the refresh ran (a wide mark
    /// left of the face only); or the read cannot tell (no wide mark: a refresh with no wheel, or no refresh).
    private let refreshReadHold: Double = 8
    /// The read's own pull, longer than the refresh leg's 220: the pull arms at 104 pt past the top, which takes about
    /// 215 pt of finger on a 17 Pro, so 220 is on the edge and never showed a refresh. 300 leaves some 85 pt over, and
    /// from the Scheduled row's middle on the open Duo (y 162 with no filter, y 249 with one) it ends at y 462 or 549,
    /// inside the 669 pt window. The same 300 fits the others, from each one's Scheduled row as today's logs read it:
    /// the closed Duo (window 466 by 678, the row's middle at y 89, ending at 389), the 17 Pro (402 by 874, y 196,
    /// ending at 496) and the iPad upright (820 by 1180, y 166 at text size large, ending at 466).
    private let refreshReadDistance: CGFloat = 300
    private let wideWheel: CGFloat = 10
    private var refreshReadAsked = false
    private func refreshRead() {
        if oneColumn { refreshReadOneColumn(); return }
        let row = app.descendants(matching: .any).matching(identifier: "chats.scheduled").firstMatch
        guard row.exists, row.isHittable else { say("REFRESHREAD not made: no Scheduled row to pull from"); return }
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: refreshReadDistance)), withVelocity: .slow, thenHoldForDuration: 0.2)
        let released = Date()
        var wide = 0, taken = 0, titleWide = 0, strayWide = 0
        for i in 1...3 {
            guard let r = read() else { say("REFRESHREAD read=\(i) no snapshot"); pause(0.5); continue }
            let at = Date().timeIntervalSince(released)
            taken += 1
            let face = r.frame("face")
            let marks = r.frames.filter { $0.key.hasPrefix("refreshing") }
            if marks.contains(where: { $0.frame.width >= wideWheel }) { wide += 1 }
            if let face, marks.contains(where: { $0.frame.width >= wideWheel && $0.frame.midX >= face.minX }) { titleWide += 1 }
            if let face, marks.contains(where: { $0.frame.width >= wideWheel && $0.frame.midX < face.minX }) { strayWide += 1 }
            let words = marks.map { m in "\(f(m.frame)) \(face.map { m.frame.midX < $0.minX ? "left of the face" : "right of the face" } ?? "no face in the read")\(m.frame.width >= wideWheel ? ", wide" : "")" }
            if i == 1 { show("REFRESHING", 0, r); still("refreshing") }
            say("REFRESHREAD read=\(i) \(String(format: "%.2f", at)) s after the pull was let go | marks \(marks.count)\(words.isEmpty ? "" : ": " + words.joined(separator: "; ")); leading \(r.count("leading")); bar elements \(r.count("barElements")); face \(face.map { f($0) } ?? "none"); search \(r.frame("search").map { "there \(f($0))" } ?? "gone")")
            pause(0.5)
        }
        // Said plainly, one of three: the title's wheel seen open; a wheel seen open but not the title's; or not told.
        let verdict: String
        if titleWide > 0 { verdict = "THE TITLE'S WHEEL WAS SEEN OPEN during the pull (a wide mark right of the face in \(titleWide) of \(taken) reads)\(strayWide > 0 ? "; a wide mark left of the face too, in \(strayWide)" : "")" }
        else if strayWide > 0 { verdict = "THE TITLE'S WHEEL WAS NOT SEEN, and the refresh ran: a wide mark left of the face only (the list's own item), in \(strayWide) of \(taken) reads" }
        else if wide > 0 { verdict = "A WHEEL WAS SEEN OPEN but with no face in the read to place it, in \(wide) of \(taken) reads" }
        else { verdict = "THIS READ CANNOT TELL: no wide mark in \(taken) reads, which is a refresh with no wheel or no refresh at all" }
        say("REFRESHREAD pull=\(Int(refreshReadDistance)) pt down from the Scheduled row, the refresh held \(Int(refreshReadHold)) s, wide is \(Int(wideWheel)) pt or more | \(verdict)")
    }

    /// The same READ in one column (a phone, the closed Duo), where no navigation bar holds the wheel: it is in the
    /// app's own top bar, with the title. The title's element is the first one with identifier "morph.title"; it can
    /// be the title's whole capsule and not the bare word, and the capsule grows for the wheel, so the wheel may lie
    /// inside its frame. First one read at rest (`T537 REFRESHREAD rest`): that element's type and frame, and the
    /// frame of a static text for the word itself if one is found inside it or carrying the identifier. Then the same
    /// pull and three reads of the whole snapshot about half a second apart. A refresh mark is any element labelled
    /// "Refreshing" or any activity or progress indicator, wherever it is; wide is `wideWheel` points or more. A wide
    /// mark whose middle is within the title element's row (4 pt of slack) is "inside the title's element" if its
    /// leading edge is at or after the element's leading edge (2 pt of slack) and its middle before the element's
    /// trailing edge, and "after the title's element" if its middle is past that edge and its leading edge within
    /// `besideTitle` points of it; any other is "elsewhere". Each read prints `T537 REFRESHREAD read=<i>`; the last
    /// line says one of four in capitals. The word's frame is printed and never judged. No verdict.
    private let besideTitle: CGFloat = 40
    private func oneColumnTitle(_ nodes: [any XCUIElementSnapshot]) -> (element: (any XCUIElementSnapshot)?, word: (any XCUIElementSnapshot)?) {
        guard let e = nodes.first(where: { $0.identifier == "morph.title" }) else { return (nil, nil) }
        let word = nodes.first(where: { $0.elementType == .staticText && !$0.label.isEmpty && $0.frame.width > 0
            && ($0.identifier == "morph.title" || e.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))) })
        return (e, word)
    }
    private func refreshReadOneColumn() {
        let row = app.descendants(matching: .any).matching(identifier: "chats.scheduled").firstMatch
        guard row.exists, row.isHittable else { say("REFRESHREAD not made: no Scheduled row to pull from"); return }
        // At rest, before the pull: the title's element and the word, so the capsule's growth is on file.
        var restWidth: CGFloat?
        if let root = try? app.snapshot() {
            var nodes: [any XCUIElementSnapshot] = []
            all(root, into: &nodes)
            let t = oneColumnTitle(nodes)
            restWidth = t.element?.frame.width
            say("REFRESHREAD rest | one column, before the pull: the title's element \(t.element.map { "type \($0.elementType.rawValue) \(f($0.frame))" } ?? "none (no 'morph.title')"); the word \(t.word.map { "'\(String($0.label.prefix(40)))' type \($0.elementType.rawValue) \(f($0.frame))" } ?? "none found as a static text")")
        } else { say("REFRESHREAD rest | no snapshot before the pull") }
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: refreshReadDistance)), withVelocity: .slow, thenHoldForDuration: 0.2)
        let released = Date()
        var taken = 0, wide = 0, insideWide = 0, afterWide = 0, noTitle = 0
        var underWidth: CGFloat?
        for i in 1...3 {
            guard let root = try? app.snapshot() else { say("REFRESHREAD read=\(i) no snapshot"); pause(0.5); continue }
            let at = Date().timeIntervalSince(released)
            taken += 1
            var nodes: [any XCUIElementSnapshot] = []
            all(root, into: &nodes)
            let t = oneColumnTitle(nodes)
            let title = t.element?.frame
            if title == nil { noTitle += 1 } else if underWidth == nil { underWidth = title?.width }
            let marks = nodes.filter { $0.label == "Refreshing" || $0.elementType == .activityIndicator || $0.elementType == .progressIndicator }
            var words: [String] = [], anyWide = false, anyInside = false, anyAfter = false
            for m in marks {
                let fr = m.frame
                let isWide = fr.width >= wideWheel
                var place = ""
                if let title {
                    let inRow = fr.midY > title.minY - 4 && fr.midY < title.maxY + 4
                    if inRow, fr.minX >= title.minX - 2, fr.midX <= title.maxX { place = ", inside the title's element"; if isWide { anyInside = true } }
                    else if inRow, fr.midX > title.maxX, fr.minX <= title.maxX + besideTitle { place = ", after the title's element"; if isWide { anyAfter = true } }
                    else { place = ", elsewhere" }
                }
                if isWide { anyWide = true }
                words.append("type \(m.elementType.rawValue) \(f(fr))\(isWide ? ", wide" : "")\(place)")
            }
            if anyWide { wide += 1 }
            if anyInside { insideWide += 1 }
            if anyAfter { afterWide += 1 }
            if i == 1 { if let r = read() { show("REFRESHING", 0, r) }; still("refreshing") }
            say("REFRESHREAD read=\(i) \(String(format: "%.2f", at)) s after the pull was let go | one column, the app's top bar: the title's element \(t.element.map { "type \($0.elementType.rawValue) \(f($0.frame))" } ?? "none (no 'morph.title')"); the word \(t.word.map { f($0.frame) } ?? "none found"); marks \(marks.count)\(words.isEmpty ? "" : ": " + words.joined(separator: "; "))")
            pause(0.5)
        }
        let grew = "the title's element \(restWidth.map { String(format: "%.1f", $0) } ?? "unread") pt wide at rest, \(underWidth.map { String(format: "%.1f", $0) } ?? "unread") under the refresh"
        let verdict: String
        if insideWide > 0 { verdict = "THE WHEEL WAS SEEN OPEN IN THE APP'S TOP BAR, INSIDE THE TITLE'S ELEMENT (a wide mark in its row, within its frame, in \(insideWide) of \(taken) reads\(afterWide > 0 ? "; one after it too, in \(afterWide)" : ""))" }
        else if afterWide > 0 { verdict = "THE WHEEL WAS SEEN OPEN IN THE APP'S TOP BAR, AFTER THE TITLE'S ELEMENT (a wide mark in its row, within \(Int(besideTitle)) pt of its trailing edge, in \(afterWide) of \(taken) reads)" }
        else if wide > 0 { verdict = "A WHEEL WAS SEEN OPEN ELSEWHERE, NOT WITH THE TITLE, in \(wide) of \(taken) reads\(noTitle > 0 ? " ('morph.title' not in \(noTitle) of them)" : ""): its frames are in the lines above" }
        else { verdict = "THIS READ CANNOT TELL: no wide mark anywhere in \(taken) reads, which is a refresh with no wheel or no refresh at all" }
        say("REFRESHREAD pull=\(Int(refreshReadDistance)) pt down from the Scheduled row, the refresh held \(Int(refreshReadHold)) s, wide is \(Int(wideWheel)) pt or more, one column, \(grew) | \(verdict)")
    }

    /// The list loaded: the Scheduled row or a cell in the list column, within `timeout` seconds.
    private func loaded(timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = read(), r.frame("scheduled") != nil || r.count("cells") > 0 { return true }
            pause(1)
        }
        return false
    }

    /// The state a leg starts from, reached by taps made before BEFORE and never after it. "filter": the View button in
    /// the list column's bar, its Filters menu, then the demo's first project ("Home lab"), so the list is narrowed to a
    /// project and its row with "Show all" stands at the list's top. "chat": the demo's first chat row, so a chat is open
    /// in the detail column. Anything else: no tap. False with the reason said (VOID) if the state was not reached.
    private func setUpState(_ setup: String) -> Bool {
        switch setup {
        case "filter":
            let view = app.buttons["chats.view"].firstMatch
            guard view.waitForExistence(timeout: 20) else { say("VOID SETUP filter: no View button in the list column's bar"); return false }
            // The menu's own item, never a button of that name already on the page: the ones there before the menu
            // opened are counted, and the item is the last of those found after it.
            let named = app.buttons.matching(NSPredicate(format: "label == 'Home lab'"))
            let already = named.count
            pause(2); view.tap(); pause(1)
            let filters = app.buttons["chats.filters"].firstMatch
            guard filters.waitForExistence(timeout: 5) else { say("VOID SETUP filter: no Filters in the View menu"); return false }
            pause(0.5); filters.tap()
            let deadline = Date().addingTimeInterval(5)
            while named.count <= already, Date() < deadline { pause(0.5) }
            let found = named.count
            guard found > already else { say("VOID SETUP filter: no project 'Home lab' in Filters (\(already) such buttons before the menu, \(found) with it)"); return false }
            named.element(boundBy: found - 1).tap()
            guard app.buttons["Show all"].firstMatch.waitForExistence(timeout: 10) else { say("VOID SETUP filter: no filter row with Show all after the project was picked"); return false }
            say("SETUP filter: the list is narrowed to the demo's project 'Home lab' (three taps, before BEFORE)")
        case "chat":
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Packing list' AND NOT (identifier BEGINSWITH 'chat.')")).firstMatch
            guard row.waitForExistence(timeout: 30) else { say("VOID SETUP chat: the demo's first chat row is not there"); return false }
            row.tap()
            guard app.descendants(matching: .any).matching(identifier: "composer.text").firstMatch.waitForExistence(timeout: 20) else {
                say("VOID SETUP chat: no composer after the row was tapped"); return false
            }
            say("SETUP chat: a chat is open in the detail column (one tap, before BEFORE)")
        case "sidebar":
            // The list column hidden and shown again with the split view's own button: two taps, before BEFORE.
            let hide = app.buttons["Hide Sidebar"].firstMatch
            guard hide.waitForExistence(timeout: 20), hide.isHittable else { say("VOID SETUP sidebar: no Hide Sidebar in the list column's bar"); return false }
            hide.tap()
            let show = app.buttons["Show Sidebar"].firstMatch
            guard show.waitForExistence(timeout: 10) else { say("VOID SETUP sidebar: no Show Sidebar after the list column was hidden"); return false }
            pause(2)
            guard show.isHittable else { say("VOID SETUP sidebar: Show Sidebar is there and cannot be hit"); return false }
            show.tap()
            let face = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Profile:'")).firstMatch
            let deadline = Date().addingTimeInterval(10)
            while !(app.buttons["Hide Sidebar"].firstMatch.exists && face.exists && face.isHittable), Date() < deadline { pause(0.5) }
            guard app.buttons["Hide Sidebar"].firstMatch.exists, face.exists else { say("VOID SETUP sidebar: the list column did not come back with its face and Hide Sidebar"); return false }
            say("SETUP sidebar: the list column was hidden and shown again (two taps, before BEFORE)")
        case "refresh":
            say("SETUP refresh: no tap before BEFORE; one pull after it and before the trip, read apart as PRE")
        default:
            say("SETUP none: no tap before BEFORE")
        }
        pause(2)
        return true
    }

    /// The read at rest after a launch: the list loaded, two columns, and settled. Nil with the reason said (VOID).
    /// `setup` names the state BEFORE must show ("filter": the filter's row; "chat": a composer and no empty detail);
    /// the read after the relaunch passes none, since a relaunch of the demo starts without either.
    private func atRest(_ phase: String, setup: String = "") -> Reading? {
        guard app.wait(for: .runningForeground, timeout: 30) else { say("VOID \(phase): the app is not in front 30 s after launch (\(stateName(app.state)))"); return nil }
        guard loaded(timeout: 40) else { say("VOID \(phase): the demo's list did not load in 40 s"); return nil }
        pause(3)
        if phase == "BEFORE", !setUpState(setup) { return nil }
        let s = settledRead(since: Date(), limit: 8)
        guard let r = s.last else { say("VOID \(phase): no snapshot"); return nil }
        show(phase, 0, r)
        if phase == "BEFORE" { showHits(phase, 0, r) }
        guard s.settled else { say("VOID \(phase): not settled after \(s.reads) reads"); return nil }
        // Two columns: the list column's bar narrower than the window, and a detail beside it (the empty one or an
        // open chat's composer). The window need not be wider than tall: an upright iPad is wide enough for both.
        // In one column (a phone, the closed Duo; T537_COLUMNS=one) none of that is asked: only that the list is there.
        if oneColumn {
            guard r.frame("list") != nil || r.count("cells") > 0 else { say("VOID \(phase): no list in the read (one column)"); return nil }
            return r
        }
        let bar = r.frames.first(where: { $0.key.hasPrefix("listBar[") })?.frame
        guard r.frame("noChat") != nil || r.frame("composer") != nil, let bar, let w = r.frame("window"), bar.width < w.width - 1 else {
            say("VOID \(phase): not two columns (noChat \(r.frame("noChat") == nil ? "none" : "there"), composer \(r.frame("composer") == nil ? "none" : "there"), bars \(r.count("bars")), listBar \(bar.map { f($0) } ?? "none"), window \(r.frame("window").map { f($0) } ?? "none"))")
            return nil
        }
        if setup == "filter", r.frame("showAll") == nil { say("VOID \(phase): the filter leg's BEFORE has no filter row (no Show all)"); return nil }
        if setup == "sidebar", r.frame("face") == nil || r.count("barItems") == 0 { say("VOID \(phase): the sidebar leg's BEFORE has no face or no bar items after the hide and show"); return nil }
        if setup == "chat", r.frame("composer") == nil || r.frame("noChat") != nil {
            say("VOID \(phase): the chat leg's BEFORE has no open chat (composer \(r.frame("composer") == nil ? "none" : "there"), empty detail \(r.frame("noChat") == nil ? "gone" : "there"))")
            return nil
        }
        return r
    }

    /// Leaves the app by this leg's way, stays away `wait` seconds, and comes back. False (VOID said) if it could not.
    private func awayAndBack(trip: Int, wait: Double, dir: URL?) -> Bool {
        // The fold leg never leaves the app: the Duo is closed and opened from outside with the app in front.
        if way == "fold" { return foldAndBack(trip: trip, wait: wait, dir: dir) }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        switch way {
        case "home":
            XCUIDevice.shared.press(.home)
        case "app":
            settings.activate()
            guard settings.wait(for: .runningForeground, timeout: 15) else { say("VOID trip=\(trip): Settings did not come to the front (\(stateName(settings.state)))"); return false }
        default:
            say("VOID trip=\(trip): no way '\(way)'"); return false
        }
        var left = app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended
        var by = way == "home" ? "the Home button" : "Settings in front"
        // On the open Duo on its side the Home button can leave the app in front. The Home screen brought to the front
        // is then the second way home; which of the two took the app away is said.
        if !left, way == "home" {
            say("AWAY trip=\(trip) way=home app=\(stateName(app.state)) after the Home button: still in front, the Home screen is brought to the front")
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
            left = app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended
            by = "the Home screen brought to the front"
        }
        say("AWAY trip=\(trip) way=\(way) app=\(stateName(app.state)) left=\(left) by=\(by)")
        // A trip on which the app never left the front is no trip: nothing can come back out of place.
        guard left else { say("VOID trip=\(trip): the app did not leave the front (\(stateName(app.state)))"); return false }
        pause(wait)
        say("AWAY trip=\(trip) way=\(way) wait=\(Int(wait)) app=\(stateName(app.state)) before the return")
        app.activate()
        return true
    }

    /// The fold leg's trip: the app stays in front while the Duo is closed and opened again from outside. The test and
    /// the script take turns by files in T537_DIR: `ready-<n>` (the test: BEFORE or the trip before is read, press
    /// closed), `closed-<n>` (the script: closed and read back closed), `shut-<n>` (the test: the closed pose is read),
    /// `moved-<n>` (the script: open again and read back on its side). The read in the closed pose is printed as
    /// `T537 CLOSED` and compared with nothing: the layout there is one column. False (VOID said) if a turn did not come.
    private func foldAndBack(trip: Int, wait: Double, dir: URL?) -> Bool {
        guard let dir else { say("VOID trip=\(trip): T537_DIR not set for the fold leg"); return false }
        func mark(_ name: String) { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data()) }
        func turn(_ name: String, within limit: Double) -> Bool {
            let path = dir.appendingPathComponent(name).path
            let deadline = Date().addingTimeInterval(limit)
            while !FileManager.default.fileExists(atPath: path), Date() < deadline { pause(1) }
            return FileManager.default.fileExists(atPath: path)
        }
        mark("ready-\(trip)")
        guard turn("closed-\(trip)", within: 300) else { say("VOID trip=\(trip): no closed-\(trip) in 300 s (the Duo was not closed)"); return false }
        pause(3)
        say("AWAY trip=\(trip) way=fold app=\(stateName(app.state)) by=the Duo closed with the app in front")
        if let c = read() { show("CLOSED", trip, c) } else { say("CLOSED trip=\(trip) no snapshot in the closed pose") }
        mark("shut-\(trip)")
        guard turn("moved-\(trip)", within: 300) else { say("VOID trip=\(trip): no moved-\(trip) in 300 s (the Duo was not opened again)"); return false }
        pause(wait)
        say("AWAY trip=\(trip) way=fold wait=\(Int(wait)) app=\(stateName(app.state)) after the Duo was opened again")
        return true
    }

    /// One slow drag down on the Chats list, `pullDistance` points, from the middle of a row of the list, then one read.
    /// Only when `last` has no search field. Prints `T537 PULL ...`: how far, from what, and whether the search field is
    /// there after it and where the list's first row stands; the read's frames follow as `T537 AFTERPULL`.
    private let pullDistance: CGFloat = 80
    private func pullOnce(after last: Reading) {
        guard last.frame("search") == nil else { say("PULL not made: the last read has the search field"); return }
        let candidates: [(what: String, element: XCUIElement)] = [
            ("the Scheduled row", app.descendants(matching: .any).matching(identifier: "chats.scheduled").firstMatch),
            ("the filter's row", app.buttons["Show all"].firstMatch),
            ("the first chat row", app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Packing list' AND NOT (identifier BEGINSWITH 'chat.')")).firstMatch),
        ]
        guard let from = candidates.first(where: { $0.element.exists && $0.element.isHittable }) else { say("PULL not made: no row of the list to start the drag from"); return }
        let start = from.element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: pullDistance))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        pause(2)
        guard let r = read() else { say("PULL drag=\(Int(pullDistance)) pt down from \(from.what) | no snapshot after it"); return }
        show("AFTERPULL", 0, r)
        showHits("AFTERPULL", 0, r)
        let d = differences(last, r)
        say("PULL drag=\(Int(pullDistance)) pt down from \(from.what) | search \(r.frame("search").map { "there \(f($0))" } ?? "gone"); first row \(r.frame("cell1").map { f($0) } ?? "none") (was \(last.frame("cell1").map { f($0) } ?? "none")); listBar \(r.frames.first(where: { $0.key.hasPrefix("listBar[") }).map { f($0.frame) } ?? "none"); changed from the last read: \(d.judged.isEmpty ? "nothing judged" : d.judged.joined(separator: "; "))")
        still("after-pull")
    }

    /// One slow drag up the Chats list, `scrollDistance` points, from the middle of a row of the list, then one read:
    /// `T537 SCROLL ...` says how far, from what, whether the first row moved (the list did scroll), and whether the
    /// search field is still at its place; the read's frames follow as `T537 SCROLLED`. `read` is whether the list scrolled;
    /// `away` whether the field, there before, is gone or moved or shrunk after. A list too short to scroll is no reading.
    private let scrollDistance: CGFloat = 200
    private func scrollOnce() -> (read: Bool, away: Bool) {
        guard let r0 = read() else { say("SCROLL not made: no snapshot before it"); return (false, false) }
        let candidates: [(what: String, element: XCUIElement)] = [
            ("the Scheduled row", app.descendants(matching: .any).matching(identifier: "chats.scheduled").firstMatch),
            ("the filter's row", app.buttons["Show all"].firstMatch),
            ("the first chat row", app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Packing list' AND NOT (identifier BEGINSWITH 'chat.')")).firstMatch),
        ]
        guard let from = candidates.first(where: { $0.element.exists && $0.element.isHittable }) else { say("SCROLL not made: no row of the list to start the drag from"); return (false, false) }
        let start = from.element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -scrollDistance)), withVelocity: .slow, thenHoldForDuration: 0.3)
        pause(2)
        guard let r1 = read() else { say("SCROLL drag=\(Int(scrollDistance)) pt up from \(from.what) | no snapshot after it"); return (false, false) }
        show("SCROLLED", 0, r1)
        let rowMoved = r0.frame("cell1").flatMap { a in r1.frame("cell1").map { abs($0.minY - a.minY) > tolerance } } ?? (r0.count("cells") != r1.count("cells"))
        let was = r0.frame("search"), now = r1.frame("search")
        say("SCROLL drag=\(Int(scrollDistance)) pt up from \(from.what) | the list \(rowMoved ? "scrolled" : "did not scroll (too short, or the drag did not take): no reading"); first row \(r1.frame("cell1").map { f($0) } ?? "none") (was \(r0.frame("cell1").map { f($0) } ?? "none")); search \(now.map { "there \(f($0))" } ?? "gone") (was \(was.map { "there \(f($0))" } ?? "gone")); listBar \(r1.frames.first(where: { $0.key.hasPrefix("listBar[") }).map { f($0.frame) } ?? "none")")
        still("scrolled")
        // Away: the field was there and is gone, or is no longer at its place or its size.
        let away = was.map { a in now.map { abs($0.minX - a.minX) > tolerance || abs($0.minY - a.minY) > tolerance || abs($0.width - a.width) > tolerance || abs($0.height - a.height) > tolerance } ?? true } ?? false
        return (rowMoved, rowMoved && away)
    }

    // MARK: The leg

    func testReturn() throws {
        let env = ProcessInfo.processInfo.environment
        way = env["T537_WAY"] ?? "home"
        let waits = (env["T537_WAITS"] ?? "2,10,45").split(separator: ",").compactMap { Double($0) }
        let trips = Int(env["T537_TRIPS"] ?? "3") ?? 3
        let dir = env["T537_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        shots = env["HERMES_E2E_SHOTS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        continueAfterFailure = true

        let setup = env["T537_SETUP"] ?? ""
        oneColumn = env["T537_COLUMNS"] == "one"
        strict = env["T537_STRICT"] == "1"
        openDuo = env["HERMES_E2E_POSE"] == "side"
        // The refresh leg keeps the spinner up long enough to leave under it (the app's own test hold, DEBUG builds).
        // The fold leg and the plain app leg (no setup, no scroll), on any device, end with one read under a refresh
        // (the list column's bar in two columns, the app's own top bar in one), and hold that refresh open for it
        // (8 s); no refresh runs in those legs before it.
        refreshReadAsked = env["T537_SCROLL"] != "1" && (way == "fold" || (way == "app" && setup.isEmpty))
        launchExtras = setup == "refresh" ? ["-vory-refresh-hold", "20"] : (refreshReadAsked ? ["-vory-refresh-hold", "\(Int(refreshReadHold))"] : [])
        // The Scheduled section open for the leg (T537_SCHEDULED=1), so the list is longer: by the section's own saved
        // default given as a launch argument, for the launch alone. No tap, and nothing is saved.
        let scheduledOpen = env["T537_SCHEDULED"] == "1"
        if scheduledOpen { launchExtras += ["-chats.scheduled.open", "YES"] }
        try launch()
        say("LEG way=\(way) setup=\(setup.isEmpty ? "none" : setup) scheduled=\(scheduledOpen ? "open" : "as saved") columns=\(oneColumn ? "one" : "two") strict=\(strict) scroll=\(env["T537_SCROLL"] == "1") waits=\(waits.map { String(Int($0)) }.joined(separator: ",")) trips=\(trips) pose=\(env["HERMES_E2E_POSE"] ?? "unknown")")
        guard var before = atRest("BEFORE", setup: setup) else { XCTFail("VOID: no BEFORE read"); return }
        still("before")

        var total = 0, moved = 0, unsettled = 0, noField = 0, known = 0, extraLeading = 0
        var previous = before
        // No trips asked (T537_TRIPS=0, the scroll part): none is made, whatever the waits read.
        for wait in (trips > 0 ? waits : []) {
            for _ in 0..<trips {
                total += 1
                let trip = total
                var pre: Reading?
                if setup == "refresh" {
                    // One pull and one trip a launch: a second pull would start from a changed page. So every trip
                    // after the first starts from a new launch and its own BEFORE, and is judged against that one.
                    if trip > 1 {
                        app.terminate(); pause(2)
                        try launch()
                        say("BEFORE again for trip=\(trip): a new launch, since the trip before it pulled and left")
                        guard let again = atRest("BEFORE", setup: setup) else { XCTFail("VOID: no BEFORE read for trip \(trip)"); return }
                        before = again; previous = again
                    }
                    // The pull, then PRE: one read at once, not waited to settle, which must show the refresh running.
                    guard let p = pullToRefresh(trip: trip, before: before) else { XCTFail("VOID: trip \(trip) had no refresh in flight"); return }
                    pre = p
                }
                guard awayAndBack(trip: trip, wait: wait, dir: dir) else { XCTFail("VOID: trip \(trip) could not be made"); return }
                let back = Date()
                let stateAtReturn = app.state
                let front = app.wait(for: .runningForeground, timeout: 15)
                say("BACK trip=\(trip) state at the return=\(stateName(stateAtReturn)) foreground=\(front) after \(String(format: "%.2f", Date().timeIntervalSince(back))) s")
                guard front else { say("VOID trip=\(trip): the app did not come to the front in 15 s"); XCTFail("VOID: trip \(trip) did not return"); return }
                let s = settledRead(since: back, limit: 5)
                guard let first = s.first, let last = s.last else { say("VOID trip=\(trip): no snapshot after the return"); XCTFail("VOID: no AFTER read"); return }
                say("BACK trip=\(trip) first read \(String(format: "%.2f", s.firstAt)) s after the return, \(s.reads) reads, settled=\(s.settled)")
                show("AFTER", trip, last)
                if trip == 1 { showHits("AFTER", trip, last) }
                let early = differences(first, last)
                if !early.judged.isEmpty { say("LATE trip=\(trip) the first read differed from the last | " + early.judged.joined(separator: "; ")) }
                let d = differences(before, last)
                if !d.rows.isEmpty { say("ROWS trip=\(trip) | " + d.rows.joined(separator: "; ")) }
                // Beside PRE too, where there is one, so what the refresh itself did is not read as the trip's doing.
                if let pre {
                    let fromPre = differences(pre, last)
                    say(fromPre.judged.isEmpty ? "FROMPRE trip=\(trip) as PRE" : "FROMPRE trip=\(trip) changed from PRE | " + fromPre.judged.joined(separator: "; "))
                }
                let search = last.frame("search") == nil ? "gone" : "there"
                if last.frame("search") == nil { noField += 1 }
                // An extra leading item in the list column's bar, said in its own line whatever else moved.
                if last.count("leading") > before.count("leading") {
                    extraLeading += 1
                    let fx = before.frame("face").flatMap { a in last.frame("face").map { n($0.minX - a.minX) } } ?? "unread"
                    say("LEADING trip=\(trip): an extra leading item: \(last.count("leading")) elements left of the face (BEFORE \(before.count("leading"))); bar elements \(before.count("barElements"))->\(last.count("barElements")); face dx=\(fx)")
                }
                if !s.settled {
                    unsettled += 1
                    say("UNSETTLED trip=\(trip) way=\(way) wait=\(Int(wait)) | not equal over a second, 5 s after the return; the last read is judged below")
                }
                if d.judged.isEmpty {
                    say("SAME trip=\(trip) way=\(way) wait=\(Int(wait))")
                } else {
                    moved += 1
                    say("MOVED trip=\(trip) way=\(way) wait=\(Int(wait)) | " + d.judged.joined(separator: "; ") + "; search \(search)")
                    // In two columns on the open Duo only: a trip moved by the two known moves alone is said so, and the
                    // strict gate lets it by.
                    if !oneColumn, openDuo, onlyKnownMoves(before, last) {
                        known += 1
                        say("KNOWN trip=\(trip): only the two known moves (another tab's bar +54; the Chats title up to 1 pt in x), no row moved")
                    }
                }
                // Beside the trip before too (BEFORE for the first), so a page that changes again or back is read.
                let step = differences(previous, last)
                say(step.judged.isEmpty ? "STEP trip=\(trip) as the read before it" : "STEP trip=\(trip) changed from the read before it | " + step.judged.joined(separator: "; "))
                previous = last
                // Three stills a leg, so the trips' timing is not stretched: BEFORE, the first return, and after the pull.
                if trip == 1 { still("after-\(trip)") }
            }
        }

        // One pull on the list, a read of its own: after the last trip's read and before the relaunch, and only if that
        // read has no search field. It tells a field tucked under the bar from one that is gone. Not judged, not counted.
        pullOnce(after: previous)

        // One scroll of the list, a read of its own (T537_SCROLL=1): whether the search field stays under the bar
        // while the list is scrolled. In two columns it scrolls away where the drawer is automatic and stays where it
        // is always shown.
        let scrollAsked = env["T537_SCROLL"] == "1"
        var scroll = (read: false, away: false)
        if scrollAsked { scroll = scrollOnce() }

        // The strict mode (T537_STRICT=1), in two columns: the field in every read and no judged MOVED but by the two
        // known moves alone (the open Duo only), or the test fails. In one column and on the iPad any judged MOVED
        // fails it (no trip is KNOWN there).
        // Without the flag the test reads and fails on a VOID alone.
        if strict {
            var faults: [String] = []
            if moved > known { faults.append(known == 0 ? "\(moved) of \(total) trips MOVED" : "\(moved - known) of \(total) trips MOVED by more than the two known moves (\(known) by those alone)") }
            if !oneColumn {
                if before.frame("search") == nil { faults.append("BEFORE has no search field") }
                if noField > 0 { faults.append("\(noField) of \(total) reads after a return have no search field") }
                if extraLeading > 0 { faults.append("\(extraLeading) of \(total) reads after a return have an extra leading item left of the face") }
                if scrollAsked, !scroll.read { faults.append("the scroll gave no reading (the list did not scroll)") }
                if scrollAsked, scroll.away { faults.append("the search field moved or scrolled away with the list") }
            }
            if faults.isEmpty, known > 0 { say("STRICT KNOWN: \(total) trips (\(known) with only known moves, \(total - known) SAME), the search field in every read, the list column unmoved, no extra leading item; only the two known moves (the other tabs' bars +54; the Chats title up to 1 pt in x)\(scrollAsked ? "; the list scrolled and the field stayed at its place" : ""), unsettled \(unsettled)") }
            else if faults.isEmpty { say("STRICT PASS: \(total) trips\(total == 0 ? " (none made: a scroll read only, no proof about trips)" : " SAME")\(oneColumn ? " (one column)" : ", the search field in every read, no extra leading item")\(scrollAsked ? ", the list scrolled and the field stayed at its place" : ""), unsettled \(unsettled)") }
            else { say("STRICT FAIL (unsettled \(unsettled)) | " + faults.joined(separator: "; ")); XCTFail("STRICT: " + faults.joined(separator: "; ")) }
        }

        // The fold leg and the plain app leg: one read under a refresh, after the verdict and before the relaunch.
        if refreshReadAsked { refreshRead() }

        app.terminate()
        pause(2)
        try launch()
        if let again = atRest("RELAUNCH") {
            let d = differences(before, again)
            if !d.rows.isEmpty { say("ROWS relaunch | " + d.rows.joined(separator: "; ")) }
            say(d.judged.isEmpty ? "RELAUNCH SAME" : "RELAUNCH MOVED | " + d.judged.joined(separator: "; "))
            if !setup.isEmpty { say("RELAUNCH NOTE setup=\(setup): a relaunch of the demo starts with no project filter and is read with no tap, so the filter's row or the open chat gone is the setup's, not a finding") }
        } else {
            XCTFail("VOID: no RELAUNCH read")
        }
        say(total == 0 ? "RESULT no trips made (a scroll read only)" : (moved > 0 ? "RESULT MOVED \(moved) of \(total) (unsettled \(unsettled))" : "RESULT SAME \(total) of \(total) (unsettled \(unsettled))"))
    }
}
