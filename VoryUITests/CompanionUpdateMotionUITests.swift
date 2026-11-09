import XCTest

/// #635: Settings › Software Update keeps its place through a companion update. From Install Now to "Your gateway is up
/// to date." the card and the version rows under it ease from one size and place to the next, on screen: no drawn step
/// is a jump. A jump is one step of 30 pt or more, or 25% or more of its phase's whole change when that change is 20 pt
/// or more (8 pt for the console's content, a line being about 14); a phase is a run of samples less than 0.25 s apart,
/// its change counted from the value before it. Judged on what is drawn, the probe's presentation samples: the card's
/// list cell's height ("card-p"), the first version row's cell's top ("row-p") and the console's content's top
/// ("log-p"), from the update's start on. The layout samples ("card", "row", "log", where a list row lands on its final
/// height in one pass while the drawing eases) are printed beside them, not judged. Read from the app's DEBUG probe
/// (`-vory-update-probe`, `UpdateMotionProbe`), which also marks the update's own steps (its start, Update Complete, the
/// closing ease, `updating` going false), printed with their times. The probe's self-check ("selfcheck-p", a view of its
/// own eased 100 pt over 0.5 s at the start) must read as an eased run of many samples; if it doesn't, the presentation
/// sampler can't see motion, and the test is skipped as VOID (UPDATE-CONTROL VOID), never judged. The probe numbers
/// each view it draws from (its instance) and times the drawn samples by their display frames: a judged series holding
/// more than one instance is two views under one key, and the test is skipped as VOID too (UPDATE-SERIES VOID). Each
/// instance on screen at once is its own series ("card-p", then "card#2-p"), printed with its instances.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set: the mock started with `--companion 1.0.39` (an older
/// companion on the gateway, its update served). HERMES_E2E_BUNDLE=com.vorantx.vory.demo drives the demo copy.
@MainActor
final class CompanionUpdateMotionUITests: XCTestCase {
    private var app: XCUIApplication!

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = query.allElementsBoundByIndex.first(where: { $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    /// A list row below the fold does not exist to the test until it is scrolled to.
    private func scrolledTo(_ query: XCUIElementQuery, swipes: Int = 8) -> XCUIElement? {
        var found = hittable(query, timeout: 5)
        var n = 0
        while found == nil, n < swipes {
            app.swipeUp(velocity: .slow)
            n += 1
            found = hittable(query, timeout: 2)
        }
        return found
    }

    /// The probe's samples by key: (seconds from its first sample, top, height, the drawing view's instance or 0). Marks
    /// are under "mark:<what>".
    private func probe() -> [String: [(t: Double, top: Double, height: Double, inst: Int)]] {
        let e = app.descendants(matching: .any).matching(identifier: "debug.updatemotion").firstMatch
        guard e.waitForExistence(timeout: 5), let v = e.value as? String else { return [:] }
        var out: [String: [(t: Double, top: Double, height: Double, inst: Int)]] = [:]
        for s in v.split(separator: ";") {
            let f = s.split(separator: ",").map(String.init)
            guard f.count == 5, let t = Double(f[1]), let top = Double(f[2]), let h = Double(f[3]), let n = Int(f[4]) else { continue }
            out[f[0], default: []].append((t, top, h, n))
        }
        return out
    }

    /// The jumps in one series by the rule above, from `t0` on (the last sample before it is the value it starts from).
    private func jumps(_ name: String, _ all: [(t: Double, v: Double)], from t0: Double, floor: Double = 20) -> [String] {
        let s = (all.last(where: { $0.t < t0 }).map { [$0] } ?? []) + all.filter { $0.t >= t0 }
        var out: [String] = []
        var i = 1
        while i < s.count {
            var j = i
            while j + 1 < s.count, s[j + 1].t - s[j].t < 0.25 { j += 1 }
            let change = abs(s[j].v - s[i - 1].v)
            for k in i...j {
                let step = abs(s[k].v - s[k - 1].v)
                if step >= 30 || (change >= floor && step >= 0.25 * change) {
                    out.append(String(format: "%@ at %.3f s: %.1f pt in one step (%.3f s after the sample before) of a %.1f pt change",
                                      name, s[k].t, step, s[k].t - s[k - 1].t, change))
                }
            }
            i = j + 1
        }
        return out
    }

    func testAnUpdateMovesNothingInOneStep() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set (the mock with --companion 1.0.39)")
        }
        continueAfterFailure = true
        let args = ["-companionPromptShown", "YES", "-launchTab", "settings", "-vory-update-probe"]
        if let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
        if hittable(app.buttons.matching(identifier: "settings.row.companion"), timeout: 5) == nil,
           let tab = hittable(app.buttons.matching(identifier: "tab.settings"), timeout: 20) {
            tab.tap()
        }
        guard let companion = scrolledTo(app.buttons.matching(identifier: "settings.row.companion")) else { return XCTFail("no Companion row in Settings") }
        companion.tap()
        guard let page = scrolledTo(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Software Update'"))) else { return XCTFail("no Software Update row on the Companion page") }
        page.tap()
        guard let install = hittable(app.buttons.matching(NSPredicate(format: "label == 'Install Now'")), timeout: 30) else {
            return XCTFail("no Install Now on Software Update: is the mock started with --companion 1.0.39?")
        }
        install.tap()
        let done = app.staticTexts.matching(NSPredicate(format: "label == 'Your gateway is up to date.'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 90), "the update did not end at \"Your gateway is up to date.\"")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        let p = probe()
        for (key, s) in p.sorted(by: { $0.key < $1.key }) {
            if key.hasPrefix("mark:") {
                print("UPDATE-MARK \(key.dropFirst(5)): \(s.map { String(format: "%.3f", $0.t) }.joined(separator: " "))")
            } else {
                let insts = Set(s.map(\.inst)).sorted().map(String.init).joined(separator: ",")
                print("UPDATE-MOTION \(key) [instances \(insts)]: \(s.map { String(format: "%.3f:%.1f/%.1f", $0.t, $0.top, $0.height) }.joined(separator: " "))")
            }
        }
        guard let start = p["mark:start"]?.first?.t else { return XCTFail("the probe marked no start of the update") }
        // The control first: the self-check's 100 pt over 0.5 s must be drawn as an eased run, at least 10 samples with no
        // step over 25 pt, from about 200 to about 300. Otherwise nothing below can be judged.
        let check = (p["selfcheck-p"] ?? []).map(\.top)
        let checkSteps = zip(check, check.dropFirst()).map { abs($1 - $0) }
        let eased = check.count >= 10 && (checkSteps.max() ?? 100) <= 25 && abs((check.last ?? 0) - (check.first ?? 0) - 100) <= 2
        print("UPDATE-CONTROL \(eased ? "ok" : "VOID"): selfcheck-p \(check.count) samples, \(String(format: "%.1f", check.first ?? 0)) to \(String(format: "%.1f", check.last ?? 0)), largest step \(String(format: "%.1f", checkSteps.max() ?? 0)) pt")
        guard eased else { throw XCTSkip("VOID: the presentation sampler didn't see the self-check's eased move (\(check.count) samples)") }
        // Step 1c: a judged series holding more than one instance is two views under one key, never judged.
        for key in ["card-p", "row-p", "log-p"] {
            let insts = Set((p[key] ?? []).map(\.inst)).sorted()
            if insts.count > 1 {
                print("UPDATE-SERIES VOID: \(key) holds \(insts.count) instances (\(insts.map(String.init).joined(separator: ",")))")
                throw XCTSkip("VOID: \(key) holds more than one instance (two views under one key)")
            }
        }
        XCTAssertNotNil(p["card-p"], "the probe drew no card")
        XCTAssertNotNil(p["row-p"], "the probe drew no version row")
        // The layout's own steps, printed for the read (a list row's layout lands in one pass), not judged.
        for j in jumps("the card's layout height", (p["card"] ?? []).map { ($0.t, $0.height) }, from: start - 0.05)
            + jumps("the first version row's layout top", (p["row"] ?? []).map { ($0.t, $0.top) }, from: start - 0.05) {
            print("UPDATE-LAYOUT-STEP \(j)")
        }
        let found = jumps("the card's drawn height", (p["card-p"] ?? []).map { ($0.t, $0.height) }, from: start - 0.05)
            + jumps("the first version row's drawn top", (p["row-p"] ?? []).map { ($0.t, $0.top) }, from: start - 0.05)
            + jumps("the console's drawn content top", (p["log-p"] ?? []).map { ($0.t, $0.top) }, from: start - 0.05, floor: 8)
        for j in found { print("UPDATE-JUMP \(j)") }
        XCTAssertTrue(found.isEmpty, "\(found.count) one-step jumps: \(found.prefix(4).joined(separator: "; "))")
    }
}
