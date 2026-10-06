import XCTest

/// The composer's chooser against the mock gateway: "/" lists its commands and skills (not the
/// terminal-only ones), typing narrows the list, a pick puts a skill in the field or runs a bare
/// command; "/model " lists the models and a pick switches the chat. On a hardware keyboard the
/// arrows move the mark and Tab and Return take it. (Escape is not here: a hardware Escape typed
/// by the test never reaches the app in the simulator, nor does a hardware Return; the arrows and
/// Tab do.) Skipped unless
/// HERMES_E2E_URL / HERMES_E2E_TOKEN are set; HERMES_E2E_BUNDLE=com.vorantx.vory.demo drives the
/// demo copy (Tools/dev/make-demo-app-sim.sh), pointed at the gateway by launch argument, and
/// HERMES_E2E_SHOTS names a folder for the screenshots.
final class SlashMenuUITests: XCTestCase {
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

    private func launch(url: String, token: String) {
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES"]
        } else {
            app = XCUIApplication()
        }
        app.launch()
    }

    /// The chooser's row for a command or skill, or for a model; the one on screen (every tab
    /// page is mounted, so the first match can be another copy).
    private func row(_ id: String) -> XCUIElement? {
        app.buttons.matching(identifier: id).allElementsBoundByIndex.first { $0.exists && $0.isHittable }
    }

    private func waitForRow(_ id: String, timeout: TimeInterval = 15) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = row(id) { return r }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        shot("missing-\(id)")
        return nil
    }

    private func waitForNoRows(_ prefix: String, timeout: TimeInterval = 5) -> Bool {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !rows.allElementsBoundByIndex.contains(where: { $0.exists && $0.isHittable }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        shot("still-open-\(prefix)")
        return false
    }

    /// The model rows on screen, top to bottom.
    private func modelRows() -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'composer.model.'")).allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable }.sorted { $0.frame.minY < $1.frame.minY }
    }

    private func text(_ fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
    }

    /// Empties the field. Once hardware keys have been sent a quick run of deletes can drop some,
    /// so it goes round until the field is empty.
    private func clear(_ composer: XCUIElement) {
        for _ in 0..<6 {
            let n = (composer.value as? String)?.count ?? 0
            if n == 0 { return }
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: n))
        }
        XCTAssertEqual((composer.value as? String) ?? "", "", "the field did not empty")
    }

    /// Waits for `id`'s row to be the marked one (Return and Tab take it).
    private func waitForMark(_ id: String, timeout: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if row(id)?.isSelected == true { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }

    private func openNewChat() -> XCUIElement {
        let newChat = app.buttons["chats.new"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 40))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: newChat)], timeout: 60)
        newChat.tap()
        let composer = app.textViews["composer.text"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        // The command list comes from the gateway when the chat opens.
        sleep(2)
        composer.tap()
        return composer
    }

    func testSlashListsCommandsAndSkillsAndModelListsModels() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        launch(url: url, token: token)
        let composer = openNewChat()

        // "/": the commands and the skills, each with its line.
        composer.typeText("/")
        let first = try XCTUnwrap(waitForRow("composer.command.agents"), "the command list did not open")
        sleep(1)
        shot("slash-1-list")
        // The commands come first, A to Z; the skills follow, further down the list.
        first.swipeUp(velocity: .slow)
        XCTAssertNotNil(waitForRow("composer.command.code-review", timeout: 5), "a skill is missing from the list")
        XCTAssertTrue(text("Review a diff").exists, "a row has no description")
        // Terminal-only commands are not offered.
        XCTAssertNil(row("composer.command.cron"))
        sleep(1)
        shot("slash-1b-list-skills")

        // Typing narrows it: "rev" is the skill's second word.
        composer.typeText("rev")
        let skill = try XCTUnwrap(waitForRow("composer.command.code-review"), "the skill is not found by a word of its name")
        XCTAssertTrue(waitForNoRows("composer.command.status"), "the list did not narrow")
        sleep(1)
        shot("slash-2-filtered")

        // A skill goes in the field, ready for its task.
        skill.tap()
        XCTAssertEqual(composer.value as? String, "/code-review ")
        XCTAssertTrue(waitForNoRows("composer.command."), "the list stayed open after the pick")
        shot("slash-3-skill-picked")
        clear(composer)

        // A command that takes nothing runs when picked.
        composer.typeText("/stat")
        try XCTUnwrap(waitForRow("composer.command.status")).tap()
        XCTAssertTrue(text("/status ran on the gateway").waitForExistence(timeout: 20), "the command did not run")
        XCTAssertEqual((composer.value as? String) ?? "", "", "the field kept the command")
        shot("slash-4-command-ran")

        // "/model ": the gateway's models; typing narrows them; a pick switches the chat.
        composer.typeText("/model ")
        let deadline = Date().addingTimeInterval(20)
        while modelRows().isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        XCTAssertGreaterThan(modelRows().count, 1, "the model list did not open")
        sleep(1)
        shot("slash-5-models")
        composer.typeText("mini")
        sleep(1)
        let minis = modelRows()
        XCTAssertFalse(minis.isEmpty, "no model matches \"mini\"")
        XCTAssertTrue(minis.allSatisfy { $0.identifier.lowercased().contains("mini") }, "the model list did not narrow")
        shot("slash-6-models-filtered")
        let picked = String(minis[0].identifier.dropFirst("composer.model.".count))
        minis[0].tap()
        XCTAssertTrue(text("Model set to \(picked)").waitForExistence(timeout: 20), "the model did not switch")
        XCTAssertTrue(waitForNoRows("composer.model."), "the model list stayed open")
        sleep(1)
        shot("slash-7-model-set")
    }

    func testTheKeyboardMovesAndTakesTheMark() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = false
        launch(url: url, token: token)
        let composer = openNewChat()

        // "/co": the command first, then the skill; Down marks the skill and Tab takes it.
        composer.typeText("/co")
        XCTAssertNotNil(waitForRow("composer.command.compress"))
        XCTAssertTrue(waitForMark("composer.command.compress"), "the first row is not marked")
        composer.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(waitForMark("composer.command.code-review"), "Down did not move the mark")
        shot("slash-keys-1-marked")
        composer.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
        XCTAssertEqual(composer.value as? String, "/code-review ", "Tab did not take the marked row")
        clear(composer)

        // A later "/word" is a command's argument: Tab puts the marked row in place of the word.
        composer.typeText("/code-review then /sta")
        XCTAssertTrue(waitForMark("composer.command.status"), "the list for a later word did not open")
        composer.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
        XCTAssertEqual(composer.value as? String, "/code-review then /status ", "the later word was not completed in place")
        shot("slash-keys-2-later-word")
        clear(composer)

        // "/model ", Down, Return: the second model.
        composer.typeText("/model ")
        let deadline = Date().addingTimeInterval(20)
        while modelRows().count < 2, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        XCTAssertGreaterThan(modelRows().count, 1)
        composer.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        sleep(1)
        let marked = try XCTUnwrap(modelRows().first { $0.isSelected }, "no model row is marked")
        XCTAssertEqual(marked.identifier, modelRows()[1].identifier, "Down did not mark the second model")
        let picked = String(marked.identifier.dropFirst("composer.model.".count))
        shot("slash-keys-3-model-marked")
        // The keyboard's Return (a typed hardware Return, like Escape, never reaches the app in
        // the simulator; both Returns call the same pick).
        composer.typeText("\n")
        XCTAssertTrue(text("Model set to \(picked)").waitForExistence(timeout: 20), "Return did not take the marked model")
        XCTAssertEqual((composer.value as? String) ?? "", "", "the field kept the command")
        shot("slash-keys-4-model-set")
    }
}
