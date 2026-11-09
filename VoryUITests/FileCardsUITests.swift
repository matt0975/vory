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

    /// Every hittable button as "identifier|label", for a failure's message.
    private func buttonList() -> String {
        app.buttons.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map { "\($0.identifier)|\($0.label)" }.joined(separator: "; ")
    }

    /// The card scrolled until it sits clear of the composer and the top bar, then tapped where it is: a card under the
    /// composer's dock takes no tap, the composer does. The band is the transcript between the top bar and the composer
    /// (the keyboard may stay up, and the composer with it). Each drag starts inside the band, in the card's own column,
    /// and moves the card's middle toward the band's, at most the band's height less 16, so it never starts on the
    /// composer or the top bar; it rests at its end before lifting, so the transcript doesn't coast past; at most eight.
    private func bringIntoView(_ card: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        let composer = app.textViews["composer.text"].firstMatch
        var band = ""
        for _ in 0..<8 {
            let w = window.frame, f = card.frame
            let top = w.minY + 120, bottom = composer.exists ? composer.frame.minY - 24 : w.maxY - 120
            band = "band \(top)...\(bottom), window \(w)"
            if card.exists && card.isHittable && f.minY >= top && f.maxY <= bottom { return }
            let room = bottom - top - 16
            guard room > 0 else { break }
            let step = max(-room, min(room, (top + bottom) / 2 - f.midY))
            let from = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX - w.minX, dy: (step > 0 ? top + 8 : bottom - 8) - w.minY))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: step)), withVelocity: .slow, thenHoldForDuration: 0.5)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        XCTFail("the card never came clear of the composer: \(card.label) at \(card.frame), \(band)", file: file, line: line)
    }

    /// The preview's own close control, if one is up and hittable: Quick Look's X on iOS 27 (identifier
    /// QLOverlayDoneButtonAccessibilityIdentifier, label "close", on 27.1 and 27.2 alike), or Done on an older system,
    /// read in a navigation bar only (the keyboard's toolbar has a Done too).
    private func closeControl() -> XCUIElement? {
        let close = app.buttons.matching(NSPredicate(format: "label ==[c] 'close' OR identifier BEGINSWITH 'QLOverlayDoneButton'"))
        let done = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Done' OR identifier == 'Done'"))
        return (close.allElementsBoundByIndex + done.allElementsBoundByIndex).first { $0.exists && $0.isHittable }
    }

    /// Why the preview of <name> isn't shown, or nil when it is: its close control is up, and a navigation bar names the
    /// file (Quick Look on iOS 27 titles it without the extension, "notes-code"; older systems with the whole name).
    /// Only navigation bars are read: the file's card and the reply's words name it too, and they are not in one.
    private func previewProblem(_ name: String, timeout: TimeInterval) -> String? {
        let stem = (name as NSString).deletingPathExtension
        let naming = NSPredicate(format: "label CONTAINS %@ OR identifier CONTAINS %@ OR label CONTAINS %@ OR identifier CONTAINS %@", name, name, stem, stem)
        let deadline = Date().addingTimeInterval(timeout)
        var closeSeen = false
        repeat {
            if closeControl() != nil {
                closeSeen = true
                if app.navigationBars.matching(naming).firstMatch.exists
                    || app.navigationBars.descendants(matching: .any).matching(naming).firstMatch.exists {
                    logBarsOnce()
                    return nil
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        logBarsOnce()
        return closeSeen ? "a preview opened, which file unconfirmed: \(name)"
            : "the preview of \(name) did not open (no close control seen; buttons: \(buttonList()))"
    }

    /// The navigation bars' tree, once a run, in the test's log: Quick Look's title and close as this system names them.
    private var barsLogged = false
    private func logBarsOnce() {
        guard !barsLogged else { return }
        barsLogged = true
        print("PREVIEW-BARS " + app.navigationBars.debugDescription.replacingOccurrences(of: "\n", with: " ¦ "))
    }

    /// The preview closed by its own control, then checked gone, with the composer back in reach.
    private func closePreview(file: StaticString = #filePath, line: UInt = #line) {
        var found = closeControl()
        let look = Date().addingTimeInterval(5)
        while found == nil && Date() < look { RunLoop.current.run(until: Date().addingTimeInterval(0.2)); found = closeControl() }
        guard let close = found else { XCTFail("no close control in the preview: \(buttonList())", file: file, line: line); return }
        print("PREVIEW-CLOSE label=\(close.label) id=\(close.identifier)")
        close.tap()
        let gone = Date().addingTimeInterval(5)
        repeat {
            if !close.exists && closeControl() == nil && app.textViews["composer.text"].firstMatch.isHittable { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < gone
        XCTFail("the preview didn't close: \(buttonList())", file: file, line: line)
    }

    /// The card shows the file's size: it came.
    private func cardShowsSize(_ cards: XCUIElementQuery, _ name: String, timeout: TimeInterval) -> Bool {
        cards.matching(NSPredicate(format: "label CONTAINS %@ AND (label CONTAINS 'bytes' OR label CONTAINS 'KB')", name)).firstMatch.waitForExistence(timeout: timeout)
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
        // The preview names the file, not the cache's hash.
        if let problem = previewProblem("report.pdf", timeout: 20) { XCTFail(problem) }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("file-preview")
        closePreview()
        // Back in the chat, the card now shows the size.
        XCTAssertTrue(cardShowsSize(cards, "report.pdf", timeout: 10), "the card does not show the size after the download: \(cards.allElementsBoundByIndex.map(\.label))")
    }

    /// Files a reply names in a sentence, in inline code and on a line of their own (#638): the mock's "files inline"
    /// turn names a note, a PDF and a picture each way, a session store the gateway won't share, and words that only
    /// start with a slash. One card per file, a thumbnail per picture, none for the look-alikes; a note and a PDF open
    /// in the preview; the session store says plainly that it can't be shared. HERMES_E2E_NO_DOWNLOAD=1: the mock was
    /// started without its download route (MOCK_NO_DOWNLOAD=1), and the PDF still opens, through the picture routes.
    func testFilesNamedInSentencesAndInlineCodeAreCards() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        let noDownload = ProcessInfo.processInfo.environment["HERMES_E2E_NO_DOWNLOAD"] == "1"
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
        composer.typeText("files inline please")
        for _ in 0..<3 {
            guard let send = hittable(app.buttons.matching(identifier: "composer.send"), timeout: 5),
                  (composer.value as? String)?.contains("files inline") == true else { break }
            send.tap()
            if text("Everything for the review").firstMatch.waitForExistence(timeout: 10) { break }
        }
        XCTAssertTrue(text("That is all").firstMatch.waitForExistence(timeout: 30), "the reply did not arrive")
        if let done = hittable(app.buttons.matching(NSPredicate(format: "label == 'Hide keyboard' OR label == 'Done'")), timeout: 1) { done.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        // One card per file, wherever the reply named it; none for the look-alikes.
        let cards = app.buttons.matching(identifier: "file.card")
        let names = ["notes-sentence.md", "summary-sentence.pdf", "notes-code.md", "summary-code.pdf", "notes-line.md", "summary-line.pdf", "s1.jsonl"]
        XCTAssertEqual(cards.count, names.count, "expected \(names.count) file cards, got \(cards.allElementsBoundByIndex.map(\.label))")
        let labels = cards.allElementsBoundByIndex.map(\.label)
        for name in names { XCTAssertTrue(labels.contains { $0.contains(name) }, "no card for \(name): \(labels)") }
        // A card's label is "File <name>, <line>", and the line may read "Tap to download": the names are matched.
        for word in ["guide.pdf", "download", "help", "log"] { XCTAssertFalse(labels.contains { $0.hasPrefix("File \(word),") }, "a card for \(word): \(labels)") }
        // A thumbnail per picture; the sentence keeps its path in the words.
        let pictures = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Image chart-'"))
        XCTAssertEqual(pictures.count, 3, "expected three pictures, got \(pictures.allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(text("The notes are in /home/hermes/out/notes-sentence.md").firstMatch.exists, "the sentence lost its path")
        shot(noDownload ? "file-cards-inline-nodownload" : "file-cards-inline")

        // Each kind opens in its own preview, named for the file, and closes before the next; its card then shows the size.
        for name in noDownload ? ["summary-sentence.pdf"] : ["notes-code.md", "summary-sentence.pdf"] {
            let card = try XCTUnwrap(cards.allElementsBoundByIndex.first { $0.label.contains(name) })
            bringIntoView(card)
            card.tap()
            if let problem = previewProblem(name, timeout: 20) { XCTFail(problem) }
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            shot("file-preview-" + name)
            closePreview()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            XCTAssertTrue(cardShowsSize(cards, name, timeout: 10), "\(name)'s card shows no size after its preview: \(cards.allElementsBoundByIndex.map(\.label))")
        }

        // The session store: refused, said plainly, no code.
        guard !noDownload else { return }
        let store = try XCTUnwrap(cards.allElementsBoundByIndex.first { $0.label.contains("s1.jsonl") })
        bringIntoView(store)
        store.tap()
        let refused = NSPredicate(format: "label CONTAINS %@", "This file can't be shared from the gateway")
        XCTAssertTrue(cards.matching(refused).firstMatch.waitForExistence(timeout: 20), "the refused card does not say so: \(cards.allElementsBoundByIndex.map(\.label))")
        XCTAssertFalse(cards.allElementsBoundByIndex.contains { $0.label.contains("403") }, "the refusal shows a code")
        shot("file-card-refused")
    }
}
