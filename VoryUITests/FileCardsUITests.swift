import XCTest

/// Files a reply hands back show as cards under it (#309): the mock's "files" turn names a PDF
/// on a MEDIA line and a CSV with a space in its name as a link; a tap on the PDF card fetches
/// it and opens the preview. Pictures land where HERMES_E2E_SHOTS says.
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=
/// com.vorantx.vory.demo drives the demo copy, pointed at the gateway by launch argument.
@MainActor
final class FileCardsUITests: XCTestCase {
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

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    private func text(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
    }

    func testFilesInAReplyAreCardsAndOneOpensInThePreview() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES"]
        } else {
            app = XCUIApplication()
        }
        app.launch()
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("files please")
        for _ in 0..<3 {
            guard let send = hittable(app.buttons.matching(identifier: "composer.send"), timeout: 5),
                  (composer.value as? String)?.contains("files") == true else { break }
            send.tap()
            if text("The report is ready").firstMatch.waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(text("That is all").firstMatch.waitForExistence(timeout: 30) || text("Nothing was written").firstMatch.waitForExistence(timeout: 30), "the reply did not arrive")
        if let done = hittable(app.buttons.matching(NSPredicate(format: "label == 'Hide keyboard' OR label == 'Done'")), timeout: 1) { done.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        // Two cards, named by the reply; the path that only looks like one made none.
        let cards = app.buttons.matching(identifier: "file.card")
        XCTAssertEqual(cards.count, 2, "expected two file cards, got \(cards.count)")
        let labels = cards.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains { $0.contains("report.pdf") }, "no card for report.pdf: \(labels)")
        XCTAssertTrue(labels.contains { $0.contains("raw numbers.csv") }, "no card for raw numbers.csv: \(labels)")
        XCTAssertFalse(labels.contains { $0.contains("log") }, "a bare folder became a card")
        // The MEDIA line and the link's path are out of the words; the link's words stay.
        XCTAssertFalse(text("MEDIA:").firstMatch.exists, "the MEDIA line is still in the bubble")
        XCTAssertTrue(text("The numbers behind it: raw numbers").firstMatch.exists, "the link's words are not in the bubble")
        shot("file-cards")

        // A tap fetches the PDF and opens the preview, which names the file.
        let pdf = try XCTUnwrap(cards.allElementsBoundByIndex.first { $0.label.contains("report.pdf") })
        pdf.tap()
        let previewTitle = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'report.pdf'")).firstMatch
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20) || previewTitle.waitForExistence(timeout: 5), "the preview did not open")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("file-preview")
        if let done = hittable(app.buttons.matching(NSPredicate(format: "label == 'Done'")), timeout: 5) { done.tap() }
        // Back in the chat, the card now shows the size.
        XCTAssertTrue(cards.allElementsBoundByIndex.contains { $0.label.contains("report.pdf") && $0.label.contains("bytes") || $0.label.contains("KB") }, "the card does not show the size after the download: \(cards.allElementsBoundByIndex.map(\.label))")
    }
}
