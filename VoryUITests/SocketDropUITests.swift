import XCTest

/// The gateway's socket dropped and restored, on a real mock (#392's transport seam: the socket's frames moved
/// behind a pipe, which must change nothing): a message answered; the mock's sockets aborted under it (the app
/// reconnects), a message answered; the mock gone for six seconds and back on the same port (the retry loop), a
/// message answered. The host stops and starts the mock when the test asks (a file each way in the shots folder,
/// which the simulator's processes share with the host).
///
/// Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN are set. HERMES_E2E_BUNDLE=com.vorantx.vory.demo drives the
/// demo copy, pointed at the mock by launch argument; HERMES_E2E_SHOTS is the shared folder.
final class SocketDropUITests: XCTestCase {
    private var app: XCUIApplication!

    private var env: (String, String)? {
        let e = ProcessInfo.processInfo.environment
        guard let u = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !u.isEmpty, !t.isEmpty else { return nil }
        return (u, t)
    }

    private var folder: URL {
        let given = ProcessInfo.processInfo.environment["HERMES_E2E_SHOTS"].flatMap { $0.isEmpty ? nil : $0 }
        let d = given.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("socket-drop", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func mark(_ s: String) { print(String(format: "SOCKETDROP %.2f %@", Date().timeIntervalSince1970, s)) }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        try? s.pngRepresentation.write(to: folder.appendingPathComponent("socketdrop-\(name).png"))
    }

    /// Asks the host to do something (stop or start the mock) and waits until it says it did.
    private func askHost(_ request: String, timeout: TimeInterval = 60) -> Bool {
        let done = folder.appendingPathComponent("socketdrop-done-\(request)")
        try? FileManager.default.removeItem(at: done)
        try? request.write(to: folder.appendingPathComponent("socketdrop-ask-\(request)"), atomically: true, encoding: .utf8)
        mark("asked host: \(request)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: done.path) { mark("host did: \(request)"); return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    private func dropSockets(_ base: String) {
        guard let u = URL(string: base + "/mock/drop-sockets") else { return }
        let done = expectation(description: "drop")
        URLSession.shared.dataTask(with: u) { data, _, _ in
            self.mark("mock drop: \(data.map { String(decoding: $0, as: UTF8.self) } ?? "no answer")")
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
    }

    private func text(_ fragment: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
    }

    private func hittable(_ query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.last(where: { $0.exists && $0.isHittable }) { return e }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    /// The mock's ordinary turn: a reply that starts with these words, then a request to delete files, which is
    /// denied so the turn ends and the composer comes back.
    private let replyWords = "filling the disk on that host"

    /// Denies every approval card on screen until none is left (one still open on the gateway comes back with a
    /// reconnect's resume), so the composer is there again.
    private func clearApprovals() {
        for _ in 0..<5 {
            guard let deny = hittable(app.buttons.matching(NSPredicate(format: "label == 'Deny'")), timeout: 2) else { return }
            deny.tap()
            mark("denied an approval")
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }
    }

    /// Sends `words` and waits for the mock's answer to them: true once a new reply is in.
    private func sendAndAwaitReply(_ words: String, timeout: TimeInterval) -> Bool {
        clearApprovals()
        let before = text(replyWords).count
        guard let composer = hittable(app.textViews.matching(identifier: "composer.text"), timeout: 20) else {
            mark("no composer for \"\(words)\""); return false
        }
        composer.tap()
        composer.typeText(words)
        // Sent again while the words are still in the composer: a tap that lands while the app is still reconnecting
        // after a drop leaves them there (as LongTurnReturnUITests does for a chat not yet ready).
        var sentAt = Date()
        for attempt in 0..<4 {
            guard let send = hittable(app.buttons.matching(identifier: "composer.send"), timeout: 10) else {
                mark("no send button for \"\(words)\""); return false
            }
            sentAt = Date()
            send.tap()
            let until = Date().addingTimeInterval(4)
            while Date() < until, (composer.value as? String ?? "").contains(words) { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
            if !(composer.value as? String ?? "").contains(words) { break }
            mark("\"\(words)\" still in the composer after send \(attempt + 1); sending again")
        }
        var answered = false
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !answered, text(replyWords).count > before {
                answered = true
                mark(String(format: "reply to \"%@\" after %.1f s", words, Date().timeIntervalSince(sentAt)))
            }
            if let deny = app.buttons.matching(NSPredicate(format: "label == 'Deny'")).allElementsBoundByIndex.last(where: { $0.exists && $0.isHittable }) {
                // The mock's ordinary turn asks for its approval only after the reply has streamed: the answer is in.
                // (Counting reply texts is not enough after a restart: the chat is re-read from a mock with less history.)
                if !answered {
                    answered = true
                    mark(String(format: "reply to \"%@\" after %.1f s (its approval came)", words, Date().timeIntervalSince(sentAt)))
                }
                deny.tap()
                mark("denied the mock's approval")
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        // The turn ends with the denial; the composer comes back.
        clearApprovals()
        _ = hittable(app.textViews.matching(identifier: "composer.text"), timeout: 20)
        return answered
    }

    func testTheSocketDroppedAndRestoredKeepsTheChatWorking() throws {
        guard let (url, token) = env else { throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set") }
        continueAfterFailure = true
        if let bundle = ProcessInfo.processInfo.environment["HERMES_E2E_BUNDLE"], !bundle.isEmpty {
            app = XCUIApplication(bundleIdentifier: bundle)
            app.launchArguments = ["-vory-demo-gateway", url, token, "Workshop", "-companionPromptShown", "YES"]
        } else {
            app = XCUIApplication()
        }
        app.launch()
        mark("launched")

        let row = text("Rewrite the nightly export job").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "the chat list did not load")
        row.tap()
        XCTAssertTrue(sendAndAwaitReply("before the drop", timeout: 40), "no reply before the drop")
        shot("1-before")

        dropSockets(url)
        sleep(2)
        XCTAssertTrue(sendAndAwaitReply("after the drop", timeout: 60), "no reply after the sockets were dropped")
        shot("2-after-drop")

        XCTAssertTrue(askHost("stop"), "the host did not stop the mock")
        sleep(6)
        shot("3-down")
        XCTAssertTrue(askHost("start"), "the host did not start the mock")
        XCTAssertTrue(sendAndAwaitReply("after the restart", timeout: 90), "no reply after the mock came back")
        shot("4-after-restart")
        mark("done")
    }
}
