import XCTest

/// The mock's answer, handed from URLSession's queue to the test under a lock.
private final class HeldAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func set(_ d: Data?) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
}

/// A bot's page (Bots, a bot's card) while its chats are still loading: the line "No chats with
/// this bot yet." is true only once the gateway has answered with none, so it must not show
/// before the answer. Skipped unless HERMES_E2E_URL / HERMES_E2E_TOKEN point at the mock gateway,
/// which holds the chat list's answer for a few seconds on request (POST /api/_mock/sessions-hold)
/// and says how many answers it held and when each went out. HERMES_E2E_BUNDLE picks the app
/// (the demo copy by default), pointed at the gateway by launch argument.
///
/// Each leg ends with one line, "BPL <leg> verdict=<GREEN|RED|FAIL|VOID>": RED is the line on show
/// during the hold; VOID is a leg that proved nothing (nothing was held, the page was read after
/// the held answer went out, or a 'Profile' text could be touched before the page was opened);
/// FAIL is anything else that is wrong.
@MainActor
final class BotPageLoadingUITests: XCTestCase {
    private var app: XCUIApplication!
    private var base = ""
    private var token = ""
    /// How long the mock holds the chat list. Under the mock's cap (9 s: its server gives a
    /// request 10 s in all before it cuts the connection).
    private static let seconds = 8.0
    /// How long the page has, once a held answer has gone out, to show what it says.
    private static let settle = 5.0
    private static let emptyLine = "No chats with this bot yet."
    /// A chat's row on the bot's page: the mock's seeded chats, not the open chat's own controls.
    private static let chatRow = "(label CONTAINS[c] 'Disk cleanup' OR label CONTAINS[c] 'Bot Chat') AND NOT (identifier BEGINSWITH 'chat.') AND NOT (identifier BEGINSWITH 'bots.card')"

    private func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    private func stamp(_ d: Date) -> String { String(format: "%.3f", d.timeIntervalSince1970) }
    private func note(_ leg: String, _ what: String) { print("BPL \(leg) | \(what)") }
    private func byID(_ id: String) -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: id) }
    private var emptyLines: XCUIElementQuery { app.staticTexts.matching(NSPredicate(format: "label == %@", Self.emptyLine)) }
    private var chatRows: XCUIElementQuery { app.buttons.matching(NSPredicate(format: Self.chatRow)) }
    private var profileRow: XCUIElementQuery { app.staticTexts.matching(NSPredicate(format: "label == 'Profile'")) }

    /// One look, no waiting: is one of these on screen now? Every tab page is mounted, so only
    /// the ones that can be touched count.
    private func onScreenNow(_ query: XCUIElementQuery) -> Bool {
        query.allElementsBoundByIndex.contains { $0.exists && $0.isHittable }
    }

    private func hittable(_ query: XCUIElementQuery, timeout: Double) -> XCUIElement? {
        let until = Date().addingTimeInterval(timeout)
        repeat {
            if let e = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return e }
            pause(0.25)
        } while Date() < until
        return nil
    }

    private func launch() throws {
        let e = ProcessInfo.processInfo.environment
        guard let url = e["HERMES_E2E_URL"], let t = e["HERMES_E2E_TOKEN"], !url.isEmpty, !t.isEmpty else {
            throw XCTSkip("HERMES_E2E_URL / HERMES_E2E_TOKEN not set")
        }
        base = url; token = t
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: e["HERMES_E2E_BUNDLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.vorantx.vory.demo")
        app.launchArguments = ["-vory-demo-gateway", url, t, "Workshop", "-companionPromptShown", "YES", "-launchTab", "bots"]
        app.launch()
    }

    /// The mock's hold on the chat list: set with a body (seconds 0 clears it), read without one.
    /// Answers how many list answers it has held since it was last set, and when each went out.
    private func hold(_ body: [String: Any]? = nil) throws -> (held: Int, sent: [Double]) {
        let url = try XCTUnwrap(URL(string: base + "/api/_mock/sessions-hold"))
        var request = URLRequest(url: url); request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let done = expectation(description: "hold")
        let answer = HeldAnswer()
        // The handler runs on URLSession's queue: it stores the bytes and nothing else.
        URLSession.shared.dataTask(with: request) { data, _, _ in
            answer.set(data)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 8)
        let obj = answer.get().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let held = obj?["held"] as? Int
        let sent = (obj?["sent"] as? [Double]) ?? []
        return (try XCTUnwrap(held, "the mock gateway did not answer for its hold (it is not this change's mock)"), sent)
    }

    private func verdict(_ leg: String, _ word: String, _ why: String) {
        print("BPL \(leg) verdict=\(word) \(why)")
        if word != "GREEN" { XCTFail("\(leg) \(word): \(why)") }
    }

    /// Legs 1 and 2: the list held, the page opened and read during the hold, then after it.
    private func heldLeg(_ leg: String, empty: Bool) throws {
        try launch()
        // However the leg ends, the list is not left held for the next one.
        defer { _ = try? hold(["seconds": 0]) }
        guard let card = hittable(byID("bots.card.default"), timeout: 40) else { return verdict(leg, "VOID", "no default bot card") }
        // The page's arrival is read from its 'Profile' row: one that can be touched already would be a false arrival.
        if onScreenNow(profileRow) { return verdict(leg, "VOID", "a 'Profile' text can be touched before the bot's page is opened") }
        let set = try hold(["seconds": Self.seconds, "empty": empty])
        note(leg, "hold set seconds=\(Self.seconds) empty=\(empty) held=\(set.held)")
        let tapped = Date()
        card.tap()
        guard hittable(profileRow, timeout: 5) != nil else { return verdict(leg, "VOID", "the bot's page did not open in 5 s") }
        let arrived = Date()
        // During the hold: one look at each, no waiting.
        let lineDuring = emptyLines.count
        let rowDuring = onScreenNow(chatRows)
        let read = Date()
        note(leg, "tapped=\(stamp(tapped)) arrived=\(stamp(arrived)) read=\(stamp(read)) emptyLineDuring=\(lineDuring) rowDuring=\(rowDuring)")
        // After it, and not before the mock says a held answer has gone out: with the line on show
        // at once, a read here would end the leg while the answer is still held, nothing counted.
        let bound = Self.seconds + 10
        let until = Date().addingTimeInterval(bound)
        var end = try hold()
        while end.held < 1, Date() < until {
            pause(0.5)
            end = try hold()
        }
        let firstSent = end.sent.min()
        let counted = Date()
        // Then the rows, or the true empty line.
        var rowAfter = false, lineAfter = false
        if end.held >= 1 {
            if empty {
                lineAfter = hittable(emptyLines, timeout: Self.settle) != nil
                rowAfter = onScreenNow(chatRows)
            } else {
                rowAfter = hittable(chatRows, timeout: Self.settle) != nil
                lineAfter = emptyLines.count > 0
            }
        }
        note(leg, "after: row=\(rowAfter) emptyLine=\(lineAfter) held=\(end.held) firstSent=\(firstSent.map { String(format: "%.3f", $0) } ?? "none") counted=\(stamp(counted)) done=\(stamp(Date()))")
        _ = try hold(["seconds": 0])
        // The rule, in this order: a leg that proved nothing is VOID whatever it saw.
        guard end.held >= 1, let firstSent else { return verdict(leg, "VOID", "the mock held no chat list answer in \(Int(bound)) s") }
        guard read.timeIntervalSince1970 < firstSent else {
            return verdict(leg, "VOID", "the page was read \(String(format: "%.3f", read.timeIntervalSince1970 - firstSent)) s after the first held answer went out")
        }
        if lineDuring > 0 { return verdict(leg, "RED", "the empty line is on the page while its chats are still loading") }
        if rowDuring { return verdict(leg, "FAIL", "a chat's row is on the page before the held answer went out") }
        if empty {
            if !lineAfter { return verdict(leg, "FAIL", "no empty line \(Int(Self.settle)) s after the held answer, though the gateway answered with no chats") }
            if rowAfter { return verdict(leg, "FAIL", "a chat's row is on the page though the gateway answered with none") }
        } else {
            if !rowAfter { return verdict(leg, "FAIL", "no chat's row \(Int(Self.settle)) s after the held answer") }
            if lineAfter { return verdict(leg, "FAIL", "the empty line is on the page beside the chats") }
        }
        verdict(leg, "GREEN", "nothing false during the hold, then \(empty ? "the empty line" : "the chats")")
    }

    func testChatsHeldShowNoEmptyLine() throws { try heldLeg("L1-held", empty: false) }

    func testNoChatsHeldShowTheEmptyLineOnlyAfter() throws { try heldLeg("L2-held-empty", empty: true) }

    /// Leg 3: no hold, the page as it was: the chats, and no empty line beside them.
    func testNoHoldShowsTheChats() throws {
        let leg = "L3-no-hold"
        try launch()
        // However the leg ends, the list is not left held for the next one.
        defer { _ = try? hold(["seconds": 0]) }
        guard let card = hittable(byID("bots.card.default"), timeout: 40) else { return verdict(leg, "VOID", "no default bot card") }
        let set = try hold(["seconds": 0])
        note(leg, "hold cleared held=\(set.held)")
        card.tap()
        let row = hittable(chatRows, timeout: 15) != nil
        let line = emptyLines.count
        let end = try hold()
        note(leg, "row=\(row) emptyLine=\(line) held=\(end.held)")
        if end.held != 0 { return verdict(leg, "VOID", "the mock held \(end.held) answer(s) with no hold set") }
        if !row { return verdict(leg, "FAIL", "no chat's row 15 s on") }
        if line > 0 { return verdict(leg, "FAIL", "the empty line is on the page beside the chats") }
        verdict(leg, "GREEN", "the chats, and no empty line")
    }
}
