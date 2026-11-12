import XCTest

/// #637 under the DEBUG-only stand-in (`ColumnStandIn`): on the closed iPhone Duo, where a chat's Back and More stand
/// against the keyboard when the system's marker for Back stands lower than the simulator ever puts it.
///
/// One case a run, named by the script (HERMES_E2E_CASE) with the stand-in's launch arguments (HERMES_E2E_STANDIN, the
/// arguments separated by spaces). Two launches against the mock gateway:
///   the reads, with `-vory-geometry-probe` and `-vory-standin-readout`: the frames with the keyboard down, rising, up,
///   leaving and down again;
///   the still, without either (their readouts would be in the picture): the chat with the keyboard up, at rest.
/// The baseline (no stand-in argument at all) is not this test's: it is DuoColumnKeyboardUITests, unchanged, on the same build.
///
/// Lines. `K637 <case> <state> t=<s> | <frames>`: Back ("chat.back"), More ("chat.more"), the dock ("chat.dock"), the
/// stand-in's status block ("standin.status"), and both keyboard numbers: `kbtop`, the app's own (the window's height
/// less the bottom safe inset less the probe's "kb"), which every verdict uses, and `kbelement`, the keyboard element's
/// frame as XCUITest gives it. `K637C`: every element in the side column at least 20 by 20, from one snapshot (type,
/// identifier, frame; no label or value). `K637R`: the app's own readout of the column ("standin.column").
/// `K637N`: notes. `K637V <case> <rule> GREEN|RED|VOID | detail`: the verdicts.
///
/// The rules, each judged on the reads named:
///   K1 with the keyboard up, at rest and in every read while it rises: no control of the two on the page ends lower
///      than 8 pt above the app's keyboard top (VOID with neither on the page at rest; its GREEN line says which were).
///   K2 at rest with the keyboard up: neither control meets the dock or the other.
///   K3 at rest, keyboard down and up: neither control meets "standin.status" (VOID with no block).
///   K4 at rest with the keyboard up: each control on the page takes a tap.
///   K5 with the keyboard down again: both frames are the ones before it came up.
/// Nothing is tapped but the chat's row, the message field and, at the end, Back; the keyboard leaves by a drag down the
/// thread. No menu is opened and nothing is typed or sent.
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
        app.terminate()
    }
}
