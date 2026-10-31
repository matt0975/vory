import XCTest

/// #516 (Duo stage 3), the side bar clear of the status, by frames in whatever pose Device Hub has the simulator in: where
/// Vory's bar stands down a side strip (the open Duo on its side, and closed), its top is at least `statusAllowance`
/// below the bottom of the status the window reports on that edge (the readout's occlusions, `-vory-geometry-probe`), on
/// every root page, a pushed page (Settings > Gateways) and Chats with a chat open; no other control in the strip overlaps
/// it, and every other control above it in the strip (a pushed page's Back, a page's own items) ends at least `backGap`
/// above its top; it stands at the strip's foot, its bottom within `footGap` above the home indicator's inset. The
/// allowance stands for a real Duo's taller status column (an extra pill in it), which the simulator doesn't draw. Every
/// frame is printed (DUO516 SIDE), and each page is held for a still of the open display (DUO516 SIDE HOLD <page>).
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set (the mock gateway), and where there's no side strip.
@MainActor
final class DuoRailUITests: XCTestCase {
    private var app: XCUIApplication!
    /// A real Duo's status column ran 66 pt further down than the simulator's (186 against 120).
    static let statusAllowance: CGFloat = 66
    /// Clear space between a control above the bar in the strip (Back) and the bar's top.
    static let backGap: CGFloat = 8
    /// The bar's bottom above the home indicator's inset: at the strip's foot, not floating up it (at most the strip's
    /// one group gap, the app's `VoryTabBar.stripGroupGap`, 10 pt).
    static let footGap: ClosedRange<CGFloat> = 0...10

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func launch(_ extra: [String]) throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-launchTab", "dashboard",
                               "-colorSchemePreference", e["HERMES_E2E_APPEARANCE"] ?? "light"] + extra
        app.launch()
        XCTAssertTrue(element("tab.dashboard").waitForExistence(timeout: 40), "no Home tab")
        pause(2)
    }

    private func open(_ tab: String) {
        let t = element("tab.\(tab)")
        XCTAssertTrue(t.waitForExistence(timeout: 10), "no tab \(tab)")
        t.tap()
        pause(1.5)
    }

    /// "occl ON x.. y.. w.. h.." lines of the regions readout, and the window's width ("win WxH").
    static func occlusions(in readout: String) -> [CGRect] {
        readout.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("occl ON") else { return nil }
            var v: [Character: Double] = [:]
            for part in line.split(separator: " ") {
                guard let k = part.first, "xywh".contains(k), let n = Double(part.dropFirst()) else { continue }
                v[k] = n
            }
            guard let x = v["x"], let y = v["y"], let w = v["w"], let h = v["h"] else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    /// The bar's elements: the tabs, the voice circle and the compose circle.
    private func barElements() -> [XCUIElement] {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' OR identifier IN {'chats.voice', 'chats.new'}"))
            .allElementsBoundByIndex.filter { $0.exists && $0.frame.width > 0 && $0.frame.height > 0 }
    }

    private func checkSideBar(_ state: String, window: CGRect, status: CGFloat, safeBottom: CGFloat) {
        let bar = barElements()
        guard let first = bar.first else { XCTFail("\(state): no bar"); return }
        let frame = bar.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let vertical = frame.height > frame.width
        print("DUO516 SIDE \(state) bar \(frame) vertical \(vertical) status bottom \(status) window \(window)")
        guard vertical else { XCTFail("\(state): the bar isn't down a side: \(frame)"); return }
        XCTAssertGreaterThanOrEqual(frame.minY, status + Self.statusAllowance, "\(state): the bar's top \(frame.minY) is within \(Self.statusAllowance) pt of the status's bottom \(status)")
        XCTAssertLessThanOrEqual(frame.maxY, window.maxY - safeBottom + 0.5, "\(state): the bar runs into the home indicator's inset: \(frame)")
        // At the strip's foot: its bottom within `footGap` above the inset.
        let foot = window.maxY - safeBottom - frame.maxY
        print("DUO516 SIDE \(state) foot gap \(foot)")
        XCTAssertTrue(Self.footGap.contains(foot.rounded()), "\(state): the bar's bottom is \(foot) pt above the home indicator's inset, not within \(Self.footGap)")
        // Any other control in the strip (a page's own item there, Bots' +) stays off the bar.
        let strip = CGRect(x: frame.minX - 20, y: window.minY, width: frame.width + 40, height: window.height)
        let others = app.buttons.allElementsBoundByIndex.filter { b in
            b.exists && b.isHittable && strip.contains(CGPoint(x: b.frame.midX, y: b.frame.midY)) && !bar.contains { $0.identifier == b.identifier && !b.identifier.isEmpty }
        }
        for b in others {
            print("DUO516 SIDE \(state) strip item '\(b.identifier)' '\(b.label)' \(b.frame)")
            XCTAssertFalse(b.frame.intersects(frame), "\(state): '\(b.identifier.isEmpty ? b.label : b.identifier)' \(b.frame) overlaps the bar \(frame)")
            // Above the bar (Back on a pushed page): clear space down to the bar's top.
            if b.frame.midY < frame.minY {
                XCTAssertGreaterThanOrEqual(frame.minY - b.frame.maxY, Self.backGap - 0.5,
                    "\(state): '\(b.identifier.isEmpty ? b.label : b.identifier)' \(b.frame) ends \(frame.minY - b.frame.maxY) pt above the bar, under \(Self.backGap)")
            }
        }
    }

    /// Holds the page for the run's still of the open display (the script takes it on this mark).
    private func hold(_ page: String) {
        print("DUO516 SIDE HOLD \(page) wall \(String(format: "%.3f", Date().timeIntervalSince1970))")
        pause(2)
    }

    func testTheSideBarStandsClearOfTheStatus() throws {
        try launch(["-vory-geometry-probe"])
        let window = app.windows.firstMatch.frame
        let readout = element("geometry.regions")
        let geometry = element("geometry.window")
        guard readout.waitForExistence(timeout: 10), geometry.exists else { throw XCTSkip("no regions readout (iOS 27.1 or later)") }
        // "… safe t0 l0 b34 r84 bar trailing …": the bar's edge and the bottom inset.
        let g = (geometry.label.isEmpty ? (geometry.value as? String) : geometry.label) ?? ""
        print("DUO516 geometry \(g)")
        guard g.contains("bar leading") || g.contains("bar trailing") else { throw XCTSkip("no side strip in this pose: \(g)") }
        let safeBottom = g.split(separator: " ").first { $0.hasPrefix("b") && Double($0.dropFirst()) != nil }.flatMap { Double($0.dropFirst()) } ?? 0
        let onTrailing = g.contains("bar trailing")
        let regions = (readout.label.isEmpty ? (readout.value as? String) : readout.label) ?? ""
        // The status on the bar's edge: occlusions touching the top edge on that half of the window.
        let status = Self.occlusions(in: regions).filter { $0.minY <= 0.5 && (onTrailing ? $0.midX > window.midX : $0.midX < window.midX) }
            .map(\.maxY).max() ?? 0
        print("DUO516 regions \(regions.replacingOccurrences(of: "\n", with: " | "))")
        for tab in ["dashboard", "chats", "bots", "settings"] {
            open(tab)
            checkSideBar(tab, window: window, status: status, safeBottom: CGFloat(safeBottom))
            hold(tab)
        }
        // A pushed page: Settings › Gateways (its row is at the top of Settings, the gateway's name first).
        open("settings")
        let gateways = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Workshop'")).firstMatch
        if gateways.waitForExistence(timeout: 10) {
            gateways.tap(); pause(1.5)
            // Back by the system's identifier first: with the bar down a side, a pushed page's Back stands in the strip, out of
            // any navigation bar.
            let back = element("BackButton").exists ? element("BackButton") : app.navigationBars.buttons.firstMatch
            print("DUO516 SIDE settings.gateways back \(back.exists ? "\(back.frame) '\(back.label)'" : "none")")
            XCTAssertTrue(back.exists, "settings.gateways: no Back")
            checkSideBar("settings.gateways", window: window, status: status, safeBottom: CGFloat(safeBottom))
            hold("settings.gateways")
            if back.exists { back.tap(); pause(1) }
        } else { XCTFail("no Gateways row in Settings") }
        // Chats with a chat open (in the split on a wide window).
        open("chats")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Bot Chat' AND NOT (identifier BEGINSWITH 'chat.')")).firstMatch
        if row.waitForExistence(timeout: 20) {
            row.tap(); pause(2)
            checkSideBar("chats.chat", window: window, status: status, safeBottom: CGFloat(safeBottom))
        }
    }
}
