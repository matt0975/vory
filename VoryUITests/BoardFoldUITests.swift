import XCTest

/// Duo stage 4: the Board's column chips either side of a fold up the window (`KanbanChips`). Runs in whatever pose the
/// simulator is in; the fold comes off the app's own regions readout (`-vory-geometry-probe`, `geometry.regions`), active
/// or not, so a flat Duo on its side counts too. HERMES_E2E_EXPECT says what this pose must show:
/// - "split": in each row, the chips before the fold end at its leading edge and the rest start at its far edge (±0.5 pt),
///   the chips on each side equal in width (±0.5 pt), none under 70 pt;
/// - "even" (or unset): every row's chips equal in width (±0.5 pt), as on a phone.
/// Either way every chip is hittable and a tap opens its column. Every frame is printed (BOARD-FOLD), so two builds'
/// runs compare line by line. HERMES_E2E_POSE_NAME names the pose in the lines. Skipped unless HERMES_E2E_URL /
/// HERMES_E2E_TOKEN are set (the mock, with the Board's plugin).
@MainActor
final class BoardFoldUITests: XCTestCase {
    private var app: XCUIApplication!
    private static let titles = ["Triage", "To do", "Scheduled", "Ready", "Running", "Blocked", "Review", "Done"]

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    /// The division running up the window in the readout, active or not: "fold ON|off x.. y.. w.. h.." lines.
    static func upFold(in readout: String, window: CGRect) -> CGRect? {
        readout.split(separator: "\n").compactMap { line -> CGRect? in
            guard line.hasPrefix("fold") else { return nil }
            var v: [String: Double] = [:]
            for part in line.split(separator: " ") {
                guard let k = part.first, "xywh".contains(k), let n = Double(part.dropFirst()) else { continue }
                v[String(k)] = n
            }
            guard let x = v["x"], let y = v["y"], let w = v["w"], let h = v["h"] else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }.first { $0.height >= $0.width && $0.intersects(window) }
    }

    private func chip(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title),")).firstMatch
    }

    func testTheChipsStandEitherSideOfTheFold() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        continueAfterFailure = true
        let expect = e["HERMES_E2E_EXPECT"] ?? "even"
        let pose = e["HERMES_E2E_POSE_NAME"] ?? "any"
        var args = ["-companionPromptShown", "YES", "-launchTab", "kanban", "-tabLayout", "chats,kanban,bots,settings",
                    "-colorSchemePreference", "light", "-vory-geometry-probe"]
        // HERMES_E2E_ARGS="largest": the largest accessibility text size, where the chips go two to a row.
        let largest = (e["HERMES_E2E_ARGS"] ?? "").contains("largest")
        if largest { args += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        let bundle = e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 }
        func launchBoard(_ launchArgs: [String]) {
            if let bundle {
                app = XCUIApplication(bundleIdentifier: bundle)
                app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + launchArgs
            } else {
                app = XCUIApplication()
                app.launchArguments = launchArgs
            }
            app.launch()
            // The Board's page is hidden until the plugin's probe answers, and the launch tab can fall back to Chats
            // before it does (as BoardEditUITests finds): then its tab on the bar.
            if !chip("Ready").waitForExistence(timeout: 12) {
                let tab = app.buttons.matching(identifier: "tab.kanban").firstMatch
                if tab.waitForExistence(timeout: 10), tab.isHittable { tab.tap() }
            }
            XCTAssertTrue(chip("Ready").waitForExistence(timeout: 30), "no Ready chip: the Board isn't in front")
            pause(1.5)
        }
        launchBoard(args)
        let window = app.windows.firstMatch.frame
        let readout = app.staticTexts["geometry.regions"].firstMatch
        let fold = readout.waitForExistence(timeout: 5) ? Self.upFold(in: readout.label, window: window) : nil
        print("BOARD-FOLD \(pose) window \(window) fold \(fold.map { "\($0)" } ?? "none") expect \(expect) largest \(largest)")
        print("BOARD-FOLD state \(pose) at \(String(format: "%.1f", Date().timeIntervalSince1970))")
        pause(2.5)

        // The DEBUG readouts drawn over the page (accessibility elements that take no touches), and which chips they
        // lie over: XCUITest's isHittable reads a chip under one as not hittable.
        let overlays = ["geometry.window", "geometry.regions"].map { ($0, app.staticTexts[$0].firstMatch) }.filter { $0.1.exists }.map { ($0.0, $0.1.frame) }
        for (id, f) in overlays { print("BOARD-FOLD \(pose) readout \(id) frame \(f)") }
        var chips = Self.titles.map { ($0, chip($0)) }
        var probeFrames: [String: CGRect] = [:]
        var notHittable: Set<String> = [], under: Set<String> = []
        for (t, c) in chips {
            XCTAssertTrue(c.exists, "no \(t) chip")
            let f = c.frame; probeFrames[t] = f
            let over = overlays.filter { $0.1.intersects(f) }.map(\.0)
            if !over.isEmpty { under.insert(t) }
            let hit = c.isHittable; if !hit { notHittable.insert(t) }
            print("BOARD-FOLD \(pose) chip \(t) frame \(f) hittable \(hit) under \(over)")
        }
        // HERMES_E2E_RELAUNCH=1: the hittable and tap checks on a launch without the DEBUG readouts, which XCUITest's
        // isHittable reads over some chips at the largest text (shown by a launch with no probe: all 8 hittable, every
        // frame equal). The fold and the split are read on this launch; the chips' frames there must match it within
        // 0.5 pt, so it's the same layout. What lies under the readouts is still logged.
        if e["HERMES_E2E_RELAUNCH"] == "1" {
            print("BOARD-FOLD \(pose) probe launch: not hittable \(notHittable.sorted()) under a readout \(under.sorted()); relaunching without the probe")
            app.terminate()
            launchBoard(args.filter { $0 != "-vory-geometry-probe" })
            chips = Self.titles.map { ($0, chip($0)) }
            for (t, c) in chips {
                let f = c.frame, p = probeFrames[t] ?? .null
                let same = abs(f.minX - p.minX) <= 0.5 && abs(f.minY - p.minY) <= 0.5 && abs(f.width - p.width) <= 0.5 && abs(f.height - p.height) <= 0.5
                print("BOARD-FOLD \(pose) relaunch chip \(t) frame \(f) same \(same) hittable \(c.isHittable)")
                XCTAssertTrue(same, "\(pose): \(t) moved without the readouts: \(f) vs \(p)")
                XCTAssertTrue(c.isHittable, "\(t) isn't hittable without the readouts")
            }
        } else {
            for (t, c) in chips { XCTAssertTrue(c.isHittable, "\(t) isn't hittable") }
        }
        // Rows by their top, each left to right.
        let framed = chips.filter { $0.1.exists }.map { (title: $0.0, frame: $0.1.frame) }
        let rows = Dictionary(grouping: framed) { Int($0.frame.minY.rounded()) }.sorted { $0.key < $1.key }.map { $0.value.sorted { $0.frame.minX < $1.frame.minX } }
        for row in rows {
            let widths = row.map(\.frame.width)
            if expect == "split" {
                guard let fold else { XCTFail("\(pose): no fold up the window to split at"); continue }
                let before = row.filter { $0.frame.midX < fold.midX }, after = row.filter { $0.frame.midX > fold.midX }
                XCTAssertEqual(before.count, after.count, "\(pose): \(before.count) chips before the fold, \(after.count) after")
                if let last = before.last { XCTAssertLessThanOrEqual(last.frame.maxX, fold.minX + 0.5, "\(pose): \(last.title) ends at \(last.frame.maxX), past the fold's leading edge \(fold.minX)") }
                if let first = after.first { XCTAssertGreaterThanOrEqual(first.frame.minX, fold.maxX - 0.5, "\(pose): \(first.title) starts at \(first.frame.minX), before the fold's far edge \(fold.maxX)") }
                for side in [before, after] where side.count > 1 {
                    let w = side.map(\.frame.width)
                    XCTAssertLessThanOrEqual((w.max() ?? 0) - (w.min() ?? 0), 0.5, "\(pose): a side's chips differ in width: \(w)")
                }
                for c in row { XCTAssertGreaterThanOrEqual(c.frame.width, 70 - 0.5, "\(pose): \(c.title) is \(c.frame.width) wide, under 70") }
                print("BOARD-FOLD \(pose) row \(row.map(\.title)) gap before \(before.last.map { fold.minX - $0.frame.maxX } ?? .nan) after \(after.first.map { $0.frame.minX - fold.maxX } ?? .nan)")
            } else {
                XCTAssertLessThanOrEqual((widths.max() ?? 0) - (widths.min() ?? 0), 0.5, "\(pose): the row's chips differ in width: \(widths)")
                print("BOARD-FOLD \(pose) row \(row.map(\.title)) widths \(widths)")
            }
        }
        // A tap opens its column.
        let running = chip("Running")
        if running.isHittable {
            running.tap(); pause(1)
            XCTAssertTrue(chip("Running").isSelected, "a tap on Running didn't open its column")
            print("BOARD-FOLD \(pose) tap Running selected \(chip("Running").isSelected)")
        }
    }
}
