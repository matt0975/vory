import XCTest

/// #637, a read and no verdict: on the closed iPhone Duo, where a chat's Back and More stand in the side column while
/// the keyboard comes up, stands and goes away, and whether a working chat's Live Activity is drawn in that column.
///
/// One launch against the mock gateway. Every line is a READ, `K637 <state> t=<seconds> | <frames>`, for a rule to be
/// written from; `K637N` lines are notes. A step that cannot get to its question prints `K637 VOID <what>` and the
/// test goes on where it can. Nothing is asserted about the app.
///
/// The frames: Back ("chat.back"), More ("chat.more"), the message field ("composer.text"), the dock ("chat.dock"),
/// the keyboard, and the bottom of the status the window reports on the bar's side (the regions readout of
/// `-vory-geometry-probe`, as DuoRailUITests reads it). Frames are read in a loop, as fast as the test can read them:
/// a move that begins and ends between two reads is not seen.
///
/// The working chat: the message "marathon 300" is typed and sent, which the mock answers with a long turn of tool
/// calls. The app starts a Live Activity for a working chat itself; the status's bottom is read before the send, while
/// the turn runs and after it, so a Live Activity drawn in the column shows as a taller status.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. The script names the pose (HERMES_E2E_POSE).
@MainActor
final class DuoColumnKeyboardUITests: XCTestCase {
    private var app: XCUIApplication!
    private var pose = "unknown"
    private var began = Date()
    /// The mock's own chat the leg opens.
    private static let chatTitle = "Disk cleanup on the log host"

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func byID(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func f(_ r: CGRect) -> String { String(format: "(%.3f,%.3f,%.3f,%.3f)", r.minX, r.minY, r.width, r.height) }
    private func n(_ v: CGFloat) -> String { String(format: "%.3f", v) }
    private func note(_ s: String) { print("K637N \(s)") }
    /// An element's frame, read only while it is there.
    private func frame(_ e: XCUIElement) -> CGRect? { e.exists ? e.frame : nil }
    private func show(_ r: CGRect?) -> String { r.map { f($0) } ?? "none" }

    /// "occl ON x.. y.. w.. h.." lines of the regions readout.
    private static func occlusions(in readout: String) -> [CGRect] {
        readout.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("occl ON") else { return nil }
            var v: [Character: Double] = [:]
            for part in line.split(separator: " ") {
                guard let k = part.first, "xywh".contains(k), let num = Double(part.dropFirst()) else { continue }
                v[k] = num
            }
            guard let x = v["x"], let y = v["y"], let w = v["w"], let h = v["h"] else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    /// The bottom of the status on the bar's side, from the regions readout as it is now: the lowest edge of the
    /// occlusions that touch the window's top on the trailing half. Nil with no readout.
    private func statusBottom() -> (bottom: CGFloat, raw: String)? {
        let readout = byID("geometry.regions")
        guard readout.exists else { return nil }
        let text = (readout.label.isEmpty ? (readout.value as? String) : readout.label) ?? ""
        let w = app.windows.firstMatch.frame
        let top = Self.occlusions(in: text).filter { $0.minY <= 0.5 && $0.midX > w.midX }
        return (top.map(\.maxY).max() ?? 0, text.replacingOccurrences(of: "\n", with: " | "))
    }

    /// One read of every frame, as one line.
    private func read(_ state: String) {
        let t = Date().timeIntervalSince(began)
        let back = byID("chat.back"), more = byID("chat.more")
        let b = frame(back), m = frame(more)
        let field = frame(app.textViews["composer.text"].firstMatch)
        let dock = frame(byID("chat.dock"))
        let kbs = app.keyboards
        let kb: CGRect? = kbs.count > 0 ? frame(kbs.firstMatch) : nil
        let status = statusBottom()
        var facts: [String] = []
        if let b, let m { facts.append("more top less back bottom \(n(m.minY - b.maxY))") }
        if let m, let kb { facts.append("keyboard top less more bottom \(n(kb.minY - m.maxY))") }
        if let b, let kb { facts.append("keyboard top less back bottom \(n(kb.minY - b.maxY))") }
        if let b, let s = status { facts.append("back top less status bottom \(n(b.minY - s.bottom))") }
        if let b, let m { facts.append("back and more intersect \(b.intersects(m))") }
        if let m, let kb { facts.append("more and keyboard intersect \(m.intersects(kb))") }
        if let b, let kb { facts.append("back and keyboard intersect \(b.intersects(kb))") }
        if let b, let field { facts.append("back and field intersect \(b.intersects(field))") }
        if let m, let field { facts.append("more and field intersect \(m.intersects(field))") }
        print("K637 \(state) t=\(String(format: "%.2f", t)) | back \(show(b)) more \(show(m)) field \(show(field)) dock \(show(dock)) keyboard \(show(kb)) status bottom \(status.map { n($0.bottom) } ?? "none"); \(facts.joined(separator: "; "))")
    }

    /// Reads in a loop for that many seconds, then says how many reads it made.
    private func reads(_ state: String, seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        var count = 0
        repeat { read(state); count += 1 } while Date() < until
        note("\(state): \(count) reads in \(String(format: "%.1f", seconds)) s")
    }

    /// Whether each of Back and More takes a tap now, read at rest only.
    private func taps(_ state: String) {
        let back = byID("chat.back"), more = byID("chat.more")
        note("\(state): back takes a tap \(back.exists && back.isHittable); more takes a tap \(more.exists && more.isHittable)")
    }

    func testReadBackMoreAndTheKeyboard() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        continueAfterFailure = true
        pose = e["HERMES_E2E_POSE"].flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "chats",
                               "-colorSchemePreference", "light", "-restore.openChat", "none", "-vory-geometry-probe"]
        app.launch()
        began = Date()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (identifier BEGINSWITH 'chats.')", Self.chatTitle)).firstMatch
        guard row.waitForExistence(timeout: 40) else { print("K637 VOID no chat row 40 s after launch"); return }
        pause(2)
        let geometry = byID("geometry.window")
        let g = geometry.exists ? ((geometry.label.isEmpty ? (geometry.value as? String) : geometry.label) ?? "") : "none"
        note("pose \(pose); window \(f(app.windows.firstMatch.frame)); geometry \(g)")
        note("regions on the list: \(statusBottom().map { "\($0.raw); status bottom \(n($0.bottom))" } ?? "none")")

        // The chat, keyboard down.
        row.tap()
        guard byID("chat.back").waitForExistence(timeout: 10) else { print("K637 VOID no Back 10 s after the tap on the chat's row"); return }
        pause(2)
        read("chat, keyboard down")
        taps("chat, keyboard down")
        note("regions in the chat: \(statusBottom().map { "\($0.raw); status bottom \(n($0.bottom))" } ?? "none")")

        // The keyboard comes up: a tap in the message field, then reads while it rises and at rest.
        let field = app.textViews["composer.text"].firstMatch
        guard field.waitForExistence(timeout: 10), field.isHittable else { print("K637 VOID the message field is not there or takes no tap"); return }
        field.tap()
        reads("keyboard rising", seconds: 2.5)
        pause(1)
        note("keyboards on the page: \(app.keyboards.count)")
        read("keyboard up, at rest")
        taps("keyboard up, at rest")

        // A working chat: the mock's long turn. The status's bottom before the send, while the turn runs and after it.
        if app.keyboards.count > 0 {
            field.typeText("marathon 300")
            pause(0.5)
            read("typed, before the send")
            let send = app.buttons["composer.send"].firstMatch
            if send.waitForExistence(timeout: 5), send.isHittable {
                send.tap()
                reads("turn running", seconds: 12)
                taps("turn running")
                note("regions with the turn running: \(statusBottom().map { "\($0.raw); status bottom \(n($0.bottom))" } ?? "none"); keyboards \(app.keyboards.count)")
            } else {
                print("K637 VOID no send button that takes a tap; the working chat was not started")
            }
        } else {
            print("K637 VOID no keyboard after the tap in the message field; nothing typed, no working chat")
        }

        // The keyboard goes away: a drag down the thread, by the test, from above the message field.
        let w = app.windows.firstMatch
        let from = w.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.30))
        let to = w.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.80))
        from.press(forDuration: 0.05, thenDragTo: to)
        reads("keyboard leaving", seconds: 2.5)
        pause(1)
        note("keyboards on the page after the drag: \(app.keyboards.count)")
        read("after the drag, at rest")
        taps("after the drag, at rest")

        // The turn's end, and the status after it.
        reads("turn ending", seconds: 6)
        pause(20)
        read("after the turn")
        note("regions after the turn: \(statusBottom().map { "\($0.raw); status bottom \(n($0.bottom))" } ?? "none")")

        // Back to the list.
        let back = byID("chat.back")
        if back.exists && back.isHittable { back.tap(); pause(1.5) }
        note("the leg's end: a chat's Back on the page \(byID("chat.back").exists)")
    }
}
