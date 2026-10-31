import UIKit
import XCTest

/// Pictures of the card composer (#320) for review: empty, several lines typed,
/// "/" open, two attachments staged, a running turn. Light and dark. Not an assertion of looks.
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set.
final class ComposerCardShotsUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        let folder = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"].flatMap { $0.isEmpty ? nil : $0 }
        let d = folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hermes-chat-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: d.appendingPathComponent("\(name).png"))
        print("CHAT-SHOT \(d.appendingPathComponent("\(name).png").path)")
    }

    private func launch(url: String, token: String, scheme: String) {
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES", "-colorSchemePreference", scheme, "-launchTab", "chats"]
        } else {
            app = XCUIApplication()
            app.launchArguments = ["-colorSchemePreference", scheme, "-launchTab", "chats"]
        }
        app.launch()
    }

    private func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// Empties the field: deletes in short runs until its value is the placeholder or nothing.
    private func clear(_ composer: XCUIElement) {
        for _ in 0..<12 {
            let v = composer.value as? String ?? ""
            if v.isEmpty || v == "Type / for commands" { break }
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: min(40, max(1, v.count))))
            settle(0.2)
        }
    }

    /// A small picture on the pasteboard, for the + panel's Paste row.
    private func putImageOnPasteboard(_ color: UIColor) {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160))
        let img = r.image { ctx in color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 160)) }
        UIPasteboard.general.image = img
    }

    func testCardPictures() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        for scheme in ["light", "dark"] {
            launch(url: url, token: token, scheme: scheme)
            let newChat = app.buttons["chats.new"].firstMatch
            XCTAssertTrue(newChat.waitForExistence(timeout: 40))
            wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
            newChat.tap()
            let composer = app.textViews["composer.text"].firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 30))
            settle(1.5)
            shot("card-\(scheme)-1-empty")
            composer.tap()
            composer.typeText("Here is a longer message that runs over several lines so the card grows upward as I type it.\nA second paragraph after a return.\nAnd a third one, with a list:\n- one\n- two\n- three")
            settle(0.8)
            shot("card-\(scheme)-2-several-lines")
            clear(composer)
            composer.typeText("/")
            // The dock rides up with the keyboard on a slow spring: a beat more before the frame.
            settle(2.5)
            shot("card-\(scheme)-3-slash")
            clear(composer)
            // Two pictures pasted through the + panel.
            for color in [UIColor.systemTeal, UIColor.systemOrange] {
                putImageOnPasteboard(color)
                let plus = app.buttons["composer.attach"].firstMatch
                XCTAssertTrue(plus.waitForExistence(timeout: 5), "no + button")
                plus.tap()
                let paste = app.buttons.matching(NSPredicate(format: "label == 'Paste'")).firstMatch
                XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste row")
                paste.tap()
                // iOS asks before another app's pasteboard is read: the system's alert, allowed.
                let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                let allow = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow'")).firstMatch
                if allow.waitForExistence(timeout: 3) { allow.tap() }
                settle(1.5)
            }
            composer.tap()
            composer.typeText("Two pictures attached")
            settle(1)
            shot("card-\(scheme)-4-two-attachments")
            // A running turn: the mock thinks for a while on "think".
            let remove = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Remove'")).allElementsBoundByIndex
            for b in remove.reversed() where b.exists && b.isHittable { b.tap(); settle(0.4) }
            clear(composer)
            composer.typeText("think it over")
            if let send = app.buttons.matching(identifier: "composer.send").allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { send.tap() }
            settle(2)
            shot("card-\(scheme)-5-running")
            app.terminate()
        }
    }
}
