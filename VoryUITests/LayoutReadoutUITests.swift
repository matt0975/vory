import XCTest

/// Settings › Troubleshooting › Screen layout (#516) against the DEBUG geometry probe (`-vory-geometry-probe`), in whatever
/// pose Device Hub has the simulator in: the window, the safe area and every reported area (its kind, whether it's active,
/// its frame) equal the probe's within 0.5 pt (the probe prints whole points, the readout tenths: at most 0.5 apart), and
/// the top bar's room is the probe's. A status corner the readout found is one of the reported areas. Every value on both
/// sides is printed (READOUT). Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock gateway).
@MainActor
final class LayoutReadoutUITests: XCTestCase {
    private var app: XCUIApplication!
    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func text(_ e: XCUIElement) -> String { (e.label.isEmpty ? (e.value as? String) : e.label) ?? "" }

    /// The numbers in a string, in order ("x 535 pt, y 0 pt, 134 by 82 pt" gives 535, 0, 134, 82).
    static func numbers(_ s: String) -> [Double] {
        let r = try! NSRegularExpression(pattern: "-?[0-9]+(\\.[0-9]+)?")
        return r.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).flatMap { Double(s[$0]) } }
    }

    /// Slow drags by the window's own coordinates (the app's swipes act on the Duo's closed display) until `e` stands
    /// whole on screen above the tab bar; then a tap at its centre.
    private func reachAndTap(_ e: XCUIElement, _ what: String) {
        reach(e, what)
        e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        pause(1.5)
    }

    /// The drags alone: `e` whole on screen above the tab bar (a lazy list leaves rows off the screen out of the tree).
    private func reach(_ e: XCUIElement, _ what: String) {
        let w = app.windows.firstMatch
        let bar = element("tab.settings")
        func clear() -> Bool {
            guard e.exists, e.isHittable else { return false }
            // The tab bar covers the row only where it runs along the bottom across the row's width; down a side strip
            // (the closed Duo, the open Duo on its side) it stands beside the list.
            let alongBottom = bar.exists && bar.frame.minY > w.frame.midY && bar.frame.minX < e.frame.maxX && bar.frame.maxX > e.frame.minX
            let barTop = alongBottom ? bar.frame.minY : w.frame.maxY
            return e.frame.minY > w.frame.minY + 110 && e.frame.maxY < barTop - 12
        }
        // Up to 30 slow drags of 0.45 of the window each: the row at Troubleshooting's foot is about 2,600 pt down, and
        // the closed Duo's and the open Duo on its side's windows are only about 670 pt tall.
        for _ in 0..<30 where !clear() {
            let up = e.exists && e.frame.minY <= w.frame.minY + 110
            w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.3 : 0.75)).press(forDuration: 0.05,
                thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.75 : 0.3)), withVelocity: .slow, thenHoldForDuration: 0.3)
            pause(0.8)
        }
        XCTAssertTrue(clear(), "\(what) wasn't reached (\(e.exists ? "\(e.frame)" : "not in the tree"))")
    }

    /// The page in front's title: the floating bar's heading on a narrow window, the navigation bar's on a wide one (where
    /// the bar steps aside). Hittable only: XCTest's tree keeps the hidden tabs' bars.
    static func firstScreen(_ app: XCUIApplication) -> String {
        let heading = app.descendants(matching: .any).matching(identifier: "morph.title").firstMatch
        if heading.exists { return heading.label }
        let bar = app.navigationBars["Settings"]
        return bar.exists && bar.isHittable ? "Settings" : "-"
    }

    private func near(_ a: [Double], _ b: [Double]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= 0.5 + 1e-6 } }

    func testTheReadoutMatchesTheProbe() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "settings",
                               "-colorSchemePreference", "light", "-vory-geometry-probe"]
        app.launch()
        XCTAssertTrue(element("tab.settings").waitForExistence(timeout: 40), "no Settings tab")
        pause(2)
        // The first screen must be Settings (a relaunch can restore the last open chat): anything else is VOID, not a pass.
        let first = Self.firstScreen(app)
        print("READOUT first screen '\(first)'")
        guard first == "Settings" else { throw XCTSkip("VOID: the first screen is '\(first)', not Settings") }
        let probeWindow = element("geometry.window"), probeRegions = element("geometry.regions")
        XCTAssertTrue(probeWindow.waitForExistence(timeout: 10), "no geometry probe")
        // Fail closed: with the regions probe missing and the readout empty, the areas' comparison would compare nothing.
        XCTAssertTrue(probeRegions.waitForExistence(timeout: 10), "no regions probe")

        reachAndTap(element("settings.row.troubleshooting"), "Settings › Troubleshooting")
        reachAndTap(element("troubleshooting.screenLayout"), "Screen layout")
        XCTAssertTrue(element("layout.window").waitForExistence(timeout: 10), "Screen layout didn't open")
        pause(1)

        // The probe, read with the readout on screen (the same pose and room).
        let g = text(probeWindow)
        print("READOUT probe window \(g)")
        let tokens = g.split(separator: " ")
        let probeSize = tokens.first.map { Self.numbers(String($0).replacingOccurrences(of: "x", with: " ")) } ?? []
        let probeSafe = ["t", "l", "b", "r"].compactMap { k in tokens.first { $0.hasPrefix(k) && Double($0.dropFirst()) != nil }.flatMap { Double($0.dropFirst()) } }
        let probeRoom = g.range(of: "room ").map { Self.numbers(String(g[$0.upperBound...])).first ?? -99 } ?? -99
        // "fold ON x0 y455 w669 h40 m20/0/20/0": its kind, whether it's active, its frame.
        let probeAreas: [(fold: Bool, active: Bool, frame: [Double])] = probeRegions.exists
            ? text(probeRegions).split(separator: "\n").filter { $0.hasPrefix("fold ") || $0.hasPrefix("occl ") }.map { line in
                let parts = line.split(separator: " ")
                return (line.hasPrefix("fold"), parts.count > 1 && parts[1] == "ON", Array(Self.numbers(parts.dropFirst(2).prefix(4).joined(separator: " ")).prefix(4)))
            } : []
        for a in probeAreas { print("READOUT probe area \(a.fold ? "fold" : "occl") \(a.active ? "on" : "off") \(a.frame)") }

        // The readout.
        func value(_ id: String) -> String { (element(id).value as? String) ?? "" }
        let size = Self.numbers(value("layout.window")), safe = Self.numbers(value("layout.safeArea")), room = value("layout.room")
        print("READOUT readout window \(value("layout.window")) | safe \(value("layout.safeArea")) | room \(room) | status \(value("layout.status")) | fold \(value("layout.fold")) | posture \(value("layout.posture")) | strip \(value("layout.strip"))")
        XCTAssertTrue(near(size, probeSize), "the window: readout \(size), probe \(probeSize)")
        XCTAssertTrue(near(safe, probeSafe), "the safe area: readout \(safe), probe \(probeSafe)")
        // The readout's room is the front tab's, with any root that differs named after it; the probe's is the last any
        // root applied. One number each, the same: every root applies the same room in this pose.
        if probeRoom < 0 { XCTAssertEqual(room, "Not applied yet", "the room: the probe has none applied") }
        else { XCTAssertTrue(near(Self.numbers(room), [probeRoom]), "the room: readout \(room), probe \(probeRoom) (a second number is a root that differs)") }

        // The status, read while it's on screen; then down to the device's first line (iOS), so the areas just above it
        // are in the tree: on the short windows (the closed Duo, the open Duo on its side) they start below the fold.
        let status = value("layout.status")
        reach(element("layout.ios"), "the device's lines")
        var areas: [(fold: Bool, active: Bool, frame: [Double])] = []
        for i in 0..<20 {
            let el = element("layout.area.\(i)")
            guard el.exists else { break }
            areas.append((el.label.hasPrefix("Fold"), !el.label.hasSuffix("inactive"), Self.numbers(value("layout.area.\(i)"))))
            print("READOUT readout area \(el.label) \(value("layout.area.\(i)"))")
        }
        // Every pose reports the status, so an empty list on either side means a reader failed.
        XCTAssertFalse(probeAreas.isEmpty, "the probe reported no area")
        XCTAssertFalse(areas.isEmpty, "the readout reported no area")
        XCTAssertEqual(areas.count, probeAreas.count, "how many areas: readout \(areas.count), probe \(probeAreas.count)")
        for (i, (a, p)) in zip(areas, probeAreas).enumerated() {
            XCTAssertEqual(a.fold, p.fold, "area \(i)'s kind")
            XCTAssertEqual(a.active, p.active, "area \(i): active")
            XCTAssertTrue(near(a.frame, p.frame), "area \(i)'s frame: readout \(a.frame), probe \(p.frame)")
        }
        // A corner the status reader found is one of the reported areas.
        if status.hasPrefix("Top right corner") {
            let corner = Self.numbers(status)
            XCTAssertTrue(probeAreas.contains { !$0.fold && $0.active && near($0.frame, corner) }, "the status corner \(corner) isn't a reported area")
        }
    }
}
