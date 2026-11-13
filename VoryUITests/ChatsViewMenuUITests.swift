import XCTest

/// #698: what the Chats list's View menu shows for its two submenus where the list is a split view's column (the iPad,
/// the open iPhone Duo): whether the rows are named "Sort" and "Filter" in words, and whether each still opens.
///
/// One launch against the mock gateway. The test taps the View button ("chats.view"), then the row that opens the sort
/// submenu, puts the menu away, opens it again and taps the row that opens the filter submenu. Nothing inside a submenu
/// is tapped, so no order and no filter is chosen. A menu is put away by a tap in the other column.
///
/// Every read is one snapshot of the app. What a menu holds is told from the page behind it by what is new in the
/// snapshot against the read before the menu was opened (the same type, identifier, label and frame is not new).
/// Lines. `M698 <state> | ...`: the window, how many named elements the snapshot holds and how many are new.
/// `M698C <state> | type <n> id '<identifier>' label '<label>' value '<value>' frame`: one per new element, at most
/// 60. `M698N`: notes. `M698V <rule> GREEN|RED|VOID | detail`: the verdicts.
///   M1 with the View menu open, the row that opens the sort submenu is a button labeled exactly "Sort" and the row
///      that opens the filter submenu a button labeled exactly "Filter". A row is found by its identifier
///      ("chats.sort", "chats.filters") or, with none, by a label that begins with "Sort" or "Filter".
///   M2 with the View menu open, each row still carries its symbol: an image whose identifier begins with
///      "arrow.up.arrow.down" lies inside the sort row and one that begins with "line.3.horizontal.decrease" inside
///      the filter row. A menu row's word is no static text of its own even when drawn (a submenu's "Recent" is a
///      button's label), so that the word is drawn is shown by M1 and the still, not by an element. VOID with a row
///      not found.
///   M3 a tap on the sort row shows "Recent"; a tap on the filter row shows "Pinned only": both submenus open.
///      VOID with a row not found.
/// Stills are the script's: the test asks by writing `shot-<name>.req` into M698_DIR and waits up to 8 s for
/// `shot-<name>.done`. With no M698_DIR there is none.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. The script names the pose (HERMES_E2E_POSE).
@MainActor
final class ChatsViewMenuUITests: XCTestCase {
    private var app: XCUIApplication!
    private static let firstChat = "Disk cleanup on the log host"
    private static let button = XCUIElement.ElementType.button.rawValue
    private static let image = XCUIElement.ElementType.image.rawValue

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func f(_ r: CGRect) -> String { String(format: "(%.3f,%.3f,%.3f,%.3f)", r.minX, r.minY, r.width, r.height) }
    private func note(_ s: String) { print("M698N \(s)") }
    private func verdict(_ rule: String, _ v: String, _ detail: String) { print("M698V \(rule) \(v) | \(detail)") }

    /// One named element of a snapshot.
    private struct Node {
        let type: UInt
        let id: String
        let label: String
        let value: String
        let frame: CGRect
        let key: String
    }

    private func all(_ s: any XCUIElementSnapshot, into out: inout [any XCUIElementSnapshot]) {
        out.append(s)
        for c in s.children { all(c, into: &out) }
    }

    /// Every element of one snapshot that has a size and an identifier or a label; nil with no snapshot.
    private func nodes() -> (window: CGRect, nodes: [Node])? {
        guard let root = try? app.snapshot() else { return nil }
        var raw: [any XCUIElementSnapshot] = []
        all(root, into: &raw)
        let window = raw.first(where: { $0.elementType == .window })?.frame ?? root.frame
        let out = raw.filter { $0.frame.width > 0 && $0.frame.height > 0 && !($0.identifier.isEmpty && $0.label.isEmpty) }.map { s in
            Node(type: s.elementType.rawValue, id: s.identifier, label: s.label, value: (s.value as? String) ?? "", frame: s.frame,
                 key: "\(s.elementType.rawValue)|\(s.identifier)|\(s.label)|\(f(s.frame))")
        }
        return (window, out)
    }

    /// One snapshot; prints and returns what is new in it against `known`.
    private func read(_ state: String, known: Set<String>) -> [Node] {
        guard let now = nodes() else { print("M698 \(state) | no snapshot"); return [] }
        let new = now.nodes.filter { !known.contains($0.key) }
        print("M698 \(state) | window \(f(now.window)) named elements \(now.nodes.count) new \(new.count)")
        for n in new.prefix(60) {
            print("M698C \(state) | type \(n.type) id '\(n.id)' label '\(n.label)' value '\(n.value)' frame \(f(n.frame))")
        }
        if new.count > 60 { note("\(state): \(new.count - 60) more new elements not printed") }
        return new
    }

    private func still(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["M698_DIR"], !dir.isEmpty else { note("no M698_DIR: no still \(name)"); return }
        let base = URL(fileURLWithPath: dir).appendingPathComponent("shot-\(name)")
        FileManager.default.createFile(atPath: base.appendingPathExtension("req").path, contents: Data())
        let done = base.appendingPathExtension("done").path
        let until = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: done), Date() < until { pause(0.25) }
        note("still \(name): \(FileManager.default.fileExists(atPath: done) ? "taken by the script" : "not taken in 8 s")")
    }

    private func tap(at r: CGRect) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: r.midX, dy: r.midY)).tap()
    }

    /// Puts any menu away by a tap low in the other column, up to three times; says how it went.
    private func putAway(_ what: String, known: Set<String>, window: CGRect) {
        for n in 1...3 {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.minX + window.width * 0.75, dy: window.minY + window.height * 0.90)).tap()
            pause(1.2)
            let left = nodes()?.nodes.filter { !known.contains($0.key) && $0.type == Self.button }.count ?? -1
            if left == 0 { note("\(what) put away by \(n) tap(s) in the other column; no new button left"); return }
            note("\(what): after tap \(n) in the other column \(left) new button(s) still in the snapshot")
        }
    }

    private func row(_ new: [Node], id: String, begins: String) -> Node? {
        let buttons = new.filter { $0.type == Self.button }
        return buttons.first { $0.id == id } ?? buttons.first { $0.label.hasPrefix(begins) }
    }

    private func say(_ n: Node?) -> String { n.map { "id '\($0.id)' label '\($0.label)' value '\($0.value)' \(f($0.frame))" } ?? "no row" }

    func testTheViewMenuNamesItsRows() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats",
                               "-colorSchemePreference", "light", "-restore.openChat", "none"]
        app.launch()
        note("pose \(e["HERMES_E2E_POSE"] ?? "unknown")")
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (identifier BEGINSWITH 'chats.')", Self.firstChat)).firstMatch
        guard chat.waitForExistence(timeout: 40) else { verdict("LAUNCH", "VOID", "no chat row 40 s after launch"); return }
        pause(3)
        let view = app.buttons["chats.view"].firstMatch
        guard view.exists, view.isHittable else {
            verdict("LAUNCH", "VOID", "no \"chats.view\" button that takes a tap: the list is not a split view's column here (exists \(view.exists))"); return
        }
        guard let closed = nodes() else { verdict("LAUNCH", "VOID", "no snapshot with the menu closed"); return }
        let known = Set(closed.nodes.map(\.key))
        let window = closed.window
        print("M698 closed | window \(f(window)) named elements \(closed.nodes.count); chats.view \(f(view.frame)) label '\(view.label)'; first chat row \(f(chat.frame))")
        still("closed")

        // The View menu open.
        view.tap()
        pause(1.5)
        let open = read("view open", known: known)
        still("view-open")
        let sortRow = row(open, id: "chats.sort", begins: "Sort")
        let filterRow = row(open, id: "chats.filters", begins: "Filter")
        verdict("M1", sortRow?.label == "Sort" && filterRow?.label == "Filter" ? "GREEN" : "RED", "sort row: \(say(sortRow)); filter row: \(say(filterRow))")
        let images = open.filter { $0.type == Self.image }
        func symbol(_ row: Node?, _ begins: String) -> Node? {
            guard let row else { return nil }
            return images.first { $0.id.hasPrefix(begins) && row.frame.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) }
        }
        let sortSymbol = symbol(sortRow, "arrow.up.arrow.down"), filterSymbol = symbol(filterRow, "line.3.horizontal.decrease")
        verdict("M2", sortRow == nil || filterRow == nil ? "VOID" : (sortSymbol != nil && filterSymbol != nil ? "GREEN" : "RED"),
                "sort row's symbol: \(sortSymbol.map { "'\($0.id)' \(f($0.frame))" } ?? "none"); filter row's symbol: \(filterSymbol.map { "'\($0.id)' \(f($0.frame))" } ?? "none"); new images: \(images.map { "'\($0.id)'" }.joined(separator: " "))")

        // The sort submenu, then the filter submenu from the View menu opened afresh. Nothing inside either is tapped.
        var recent: Bool?, pinned: Bool?
        if let sortRow {
            tap(at: sortRow.frame)
            pause(1.5)
            let s = read("sort open", known: known.union(open.map(\.key)))
            recent = s.contains { $0.label == "Recent" }
            still("sort-open")
        }
        putAway("the menu after the sort row", known: known, window: window)
        if filterRow != nil {
            view.tap()
            pause(1.5)
            let again = read("view open again", known: known)
            if let r = row(again, id: "chats.filters", begins: "Filter") {
                tap(at: r.frame)
                pause(1.5)
                let s = read("filter open", known: known.union(again.map(\.key)))
                pinned = s.contains { $0.label == "Pinned only" }
                still("filter-open")
            } else {
                note("the filter row is not in the View menu opened again")
            }
            putAway("the menu after the filter row", known: known, window: window)
        }
        if let recent, let pinned {
            verdict("M3", recent && pinned ? "GREEN" : "RED", "after the sort row \"Recent\" \(recent ? "shown" : "not shown"); after the filter row \"Pinned only\" \(pinned ? "shown" : "not shown")")
        } else {
            verdict("M3", "VOID", "a row was not found: sort row \(say(sortRow)); filter row \(say(filterRow))")
        }
        let end = nodes()
        note("at the end: chats.view \(view.exists ? f(view.frame) : "not there"); new buttons against the closed read: \(end?.nodes.filter { !known.contains($0.key) && $0.type == Self.button }.count ?? -1)")
        app.terminate()
    }
}
