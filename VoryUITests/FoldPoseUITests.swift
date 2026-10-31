import XCTest

/// Duo stage 2: on a half-open iPhone Duo, no control of the chat's chrome stands on the fold. The fold is read off the
/// app's own readout of the window's reserved regions (`-vory-geometry-probe`, `geometry.regions`), so the test runs in
/// whatever pose Device Hub has the simulator in, and skips with no active fold. In a chat, with the keyboard down and
/// up, nothing open, the + panel open, the "/" list open and the "@" list open: the header's controls (Back, the title,
/// More), the dock's (+, the field, Send, the model chip) and every row of the open list keep clear of the fold's frame.
/// Every frame and its distance from the fold is printed (FOLD-POSE) and each state's screen kept (HERMES_E2E_SHOTS).
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
@MainActor
final class FoldPoseUITests: XCTestCase {
    private var app: XCUIApplication!

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    /// Marks a state for the screenshots taken from outside (`simctl io --display=primary-1`: XCUITest's own screenshot
    /// is of the closed display, black while the Duo is open) and holds it long enough for one.
    private func shot(_ name: String) {
        print("FOLD-POSE state \(name) at \(String(format: "%.1f", Date().timeIntervalSince1970))")
        pause(2.5)
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"], !folder.isEmpty {
            let d = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
        }
    }

    /// The active folds in the readout: "fold ON x.. y.. w.. h.. m…" lines.
    static func activeFolds(in readout: String) -> [CGRect] {
        readout.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("fold ON") else { return nil }
            var v: [String: Double] = [:]
            for part in line.split(separator: " ") {
                guard let k = part.first, "xywh".contains(k), let n = Double(part.dropFirst()) else { continue }
                v[String(k)] = n
            }
            guard let x = v["x"], let y = v["y"], let w = v["w"], let h = v["h"] else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    private var checked = 0
    /// Each element's frame against the fold: printed, and a failure when they overlap.
    /// `rows`: a list's rows, checked only where they can be hit; a capped list's rows past its scrolled edge report
    /// frames where they would be, and the composer's tap-catcher answers the hit test over the + panel. Those are
    /// printed, not judged: the state's screenshot shows the list. The chrome is always judged.
    private func check(_ what: String, _ elements: [XCUIElement], fold: CGRect, state: String, rows: Bool = false) {
        for e in elements where e.exists {
            let f = e.frame
            guard f.width > 0, f.height > 0 else { continue }
            if rows, !e.isHittable { print("FOLD-POSE \(state) \(what) id '\(e.identifier)' frame \(f) not hittable: not judged"); continue }
            checked += 1
            let gap = fold.isNull ? 0 : fold.width > fold.height ? max(fold.minY - f.maxY, f.minY - fold.maxY) : max(fold.minX - f.maxX, f.minX - fold.maxX)
            print("FOLD-POSE \(state) \(what) id '\(e.identifier)' label '\(e.label)' frame \(f) gap \(Int(gap))")
            XCTAssertFalse(f.intersects(fold), "\(state): \(what) '\(e.identifier.isEmpty ? e.label : e.identifier)' \(f) stands on the fold \(fold)")
        }
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func chrome() -> [XCUIElement] {
        ["chat.back", "chat.titlePill", "chat.more", "composer.attach", "composer.text", "composer.send", "composer.modelChip"].map(element)
    }

    func testNoControlOfTheChatStandsOnTheFold() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let token = e["HERMES_E2E_TOKEN"], !url.isEmpty, !token.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        continueAfterFailure = true
        let args = ["-companionPromptShown", "YES", "-launchTab", "chats", "-colorSchemePreference", "light", "-vory-geometry-probe"]
        if let bundle = e["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop"] + args
        } else {
            app = XCUIApplication()
            app.launchArguments = args
        }
        app.launch()
        // HERMES_E2E_ANY_POSE=1: no fold needed (a phone, an iPad, a flat Duo, or a build before the readout had its
        // identifier): every frame is printed for a before-and-after, and nothing can stand on a fold that isn't there.
        let anyPose = e["HERMES_E2E_ANY_POSE"] == "1"
        let readout = app.staticTexts["geometry.regions"].firstMatch
        let hasReadout = readout.waitForExistence(timeout: anyPose ? 8 : 20)
        if !anyPose { XCTAssertTrue(hasReadout, "no regions readout (a Debug build with -vory-geometry-probe)") }
        pause(1)
        if hasReadout { print("FOLD-POSE readout \(readout.label.replacingOccurrences(of: "\n", with: " | "))") }
        let window = app.staticTexts["geometry.window"].firstMatch
        if window.exists { print("FOLD-POSE window \(window.label)") }
        let fold: CGRect
        if let f = hasReadout ? Self.activeFolds(in: readout.label).first : nil { fold = f }
        else if anyPose { fold = .null }
        else { throw XCTSkip("no active fold: put the Duo in a half-open pose in Device Hub first") }
        let pose = fold.isNull ? (e["HERMES_E2E_POSE_NAME"] ?? "any") : fold.width > fold.height ? "laptop" : "book"
        print("FOLD-POSE \(pose) fold \(fold)")

        // A chat.
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Disk cleanup' AND identifier != 'chat.titlePill'"))
        let row = rows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "no Disk cleanup row")
        row.tap()
        let field = element("composer.text")
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no composer")
        pause(1.5)
        shot("\(pose)-1-chat")
        check("chrome", chrome(), fold: fold, state: "\(pose) keyboard down")

        // The + panel, the keyboard down.
        element("composer.attach").tap(); pause(1.2)
        shot("\(pose)-2-plus")
        check("+ row", app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'attach.'")).allElementsBoundByIndex, fold: fold, state: "\(pose) + panel, keyboard down", rows: true)
        check("chrome", chrome(), fold: fold, state: "\(pose) + panel, keyboard down")
        element("composer.attach").tap(); pause(1)

        // The keyboard up, nothing open.
        field.tap(); pause(1.5)
        let keyboard = app.keyboards.firstMatch
        print("FOLD-POSE \(pose) keyboard \(keyboard.exists ? "\(keyboard.frame)" : "none (a hardware keyboard?)") readout \(hasReadout ? readout.label.replacingOccurrences(of: "\n", with: " | ") : "none")")
        shot("\(pose)-3-keyboard")
        check("chrome", chrome(), fold: fold, state: "\(pose) keyboard up")

        // The + panel with the keyboard up.
        element("composer.attach").tap(); pause(1.2)
        shot("\(pose)-4-plus-keyboard")
        check("+ row", app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'attach.'")).allElementsBoundByIndex, fold: fold, state: "\(pose) + panel, keyboard up", rows: true)
        check("chrome", chrome(), fold: fold, state: "\(pose) + panel, keyboard up")
        element("composer.attach").tap(); pause(1)

        // The "/" list.
        field.tap(); field.typeText("/"); pause(1.5)
        shot("\(pose)-5-slash")
        check("/ row", app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'composer.command.'")).allElementsBoundByIndex, fold: fold, state: "\(pose) / list", rows: true)
        check("chrome", chrome(), fold: fold, state: "\(pose) / list")
        field.typeText(XCUIKeyboardKey.delete.rawValue); pause(1)

        // The "@" list.
        field.typeText("@"); pause(1.5)
        shot("\(pose)-6-mention")
        check("@ row", app.buttons.matching(NSPredicate(format: "label BEGINSWITH '@'")).allElementsBoundByIndex, fold: fold, state: "\(pose) @ list", rows: true)
        check("chrome", chrome(), fold: fold, state: "\(pose) @ list")
        field.typeText(XCUIKeyboardKey.delete.rawValue); pause(1)

        XCTAssertGreaterThan(checked, 10, "too few frames checked (\(checked)): the identifiers may have moved")
    }
}
