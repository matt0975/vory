import XCTest

/// The Watch while its iPhone runs the demo (#502), on a paired Watch. The host runs each test alone, in order, and
/// moves the iPhone between them: its app launched as usual before the first (`testAWatchsOwnGatewayBeforeTheDemo`),
/// in the demo (`-vory-demo`) before the second, and out of it again before the third; before the fourth, in the demo,
/// out of it with no gateway in use, and then closed. The Watch's own gateway is the
/// mock (`WatchUITestCase.launch`): its chat, "Rewrite the nightly export job", is the Watch's own gateway shown, and
/// its first two chats (`mockRows`) are the person's rows. The demo's are its chats' titles and its name, as
/// `DemoContent` and `GatewayConnection.demo` have them.
final class WatchDemoUITests: WatchUITestCase {
    private let demoTitles = ["Packing list for the lake weekend", "Compare three e-readers",
                              "Weekly budget check-in", "Soil for the raised beds",
                              "Morning checks on the home servers", "Why is the NAS slow tonight?",
                              "Newsletter intro, take two", "Colors for the garden sign",
                              "Rename the lake trip photos by date"]
    private let demoName = "Vory demo"
    private var demoMarks: [String] { demoTitles + [demoName] }
    private let ownRow = "Rewrite the nightly export job"
    private let mockRows = ["Disk cleanup on the log host", "Rewrite the nightly export job"]

    private func shows(_ text: String) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
    }
    private func demoShown() -> String? { demoMarks.first { shows($0) } }
    /// The first few words on screen, for the log: which gateway the Watch shows.
    private func labels() -> String {
        app.staticTexts.allElementsBoundByIndex.prefix(8).map(\.label).filter { !$0.isEmpty }.joined(separator: " | ")
    }

    /// From the app's launch through 15 s, a look every half second (or as fast as a look of the tree allows) for the
    /// demo's name or chats, each sight marked with its seconds since the launch, and the count marked at the end. A
    /// name the Watch still holds from a demo that ended shows here, before the own row's wait and the looks below.
    private func demoFromLaunch(_ stage: String, since start: Date) -> [String] {
        var sights: [String] = []
        var looks = 0
        while Date().timeIntervalSince(start) < 15 {
            looks += 1
            if let seen = demoShown() {
                let at = String(format: "%.1f", Date().timeIntervalSince(start))
                sights.append("\(seen) +\(at) s")
                mark("W502 launch \(stage) +\(at) s: \(seen); labels: \(labels())")
            }
            usleep(500_000)
        }
        let first = sights.first.map { ", first \($0)" } ?? ""
        mark("W502 launch \(stage): \(looks) looks in 15 s, \(sights.count) sights\(first)")
        return sights
    }

    /// Whether the Watch's own gateway's chat shows: on any element (its row is a button), within `wait` seconds,
    /// then, if not, after a bounded Crown search, since the list is lazy and a row below the screen isn't in it: up to
    /// 8 turns of 0.4 down, then up to 8 back up, about 1 s apart, each look marked.
    private func ownRowShows(within wait: TimeInterval, _ stage: String) -> Bool {
        let until = Date().addingTimeInterval(wait)
        while Date() < until {
            if shows(ownRow) { return true }
            sleep(2)
        }
        let turns: [Double] = Array(repeating: 0.4, count: 8) + Array(repeating: -0.4, count: 8)
        for (i, delta) in turns.enumerated() {
            XCUIDevice.shared.rotateDigitalCrown(delta: delta)
            sleep(1)
            let seen = shows(ownRow)
            let way = delta > 0 ? "down" : "up"
            mark("W502 \(stage) crown \(i + 1) \(way): own \(seen ? "yes" : "no"); labels: \(labels())")
            if seen { return true }
        }
        return false
    }

    /// Before the demo: the Watch shows its own gateway (`ownRowShows`). The host stops the run here if it doesn't (the
    /// iPhone then has a gateway of its own in use, which the third test can't expect). Then five looks, 3 s apart,
    /// each with that chat and nothing of the demo, its name included: the demo isn't running, and a name left from an
    /// earlier one (a context that still names it) is the Watch showing a demo that ended.
    func testAWatchsOwnGatewayBeforeTheDemo() throws {
        let start = Date()
        try launch()
        // From the launch: marked only. A name here is left from the run before, not this run's phone.
        _ = demoFromLaunch("a", since: start)
        XCTAssertTrue(button("Settings").waitForExistence(timeout: 40), "no start screen")
        let found = ownRowShows(within: 120, "own before")
        mark("W502 own before: \(found ? "shown" : "not shown in 120 s and the Crown search"); labels: \(labels())")
        shot("w502-own-before")
        XCTAssertTrue(found,
                      "the Watch's own gateway's chat didn't show in 120 s and the Crown search before the demo")
        for look in 1...5 {
            let own = shows(ownRow), demo = demoShown()
            let seen = "own \(own ? "yes" : "no"), demo \(demo ?? "none")"
            mark("W502 before look \(look): \(seen); labels: \(labels())")
            XCTAssertTrue(own, "before look \(look): the Watch's own gateway's chat isn't shown")
            XCTAssertNil(demo, "before look \(look): the demo's \"\(demo ?? "")\" is shown before the demo")
            if look < 5 { sleep(3) }
        }
    }

    /// The iPhone in the demo: within 90 s the Watch shows one of the demo's chats (its name alone doesn't count), then
    /// for 15 s (six looks, 3 s apart) a demo chat and neither of the person's rows. Whether the demo's name stood over
    /// the person's rows before its chats came is marked, with each look's seconds since the launch.
    func testBWatchShowsThePhonesDemo() throws {
        let start = Date()
        try launch()
        XCTAssertTrue(button("Settings").waitForExistence(timeout: 40), "no start screen")
        func secs() -> String { String(format: "%.1f", Date().timeIntervalSince(start)) }
        var title: String?
        var mixed = false
        let until = Date().addingTimeInterval(90)
        while title == nil, Date() < until {
            title = demoTitles.first(where: { shows($0) })
            if title == nil {
                if !mixed, shows(demoName), let row = mockRows.first(where: { shows($0) }) {
                    mixed = true
                    mark("W502 demo +\(secs()) s: mixed, \"\(demoName)\" over \"\(row)\"; labels: \(labels())")
                }
                sleep(2)
            }
        }
        let before = mixed ? "yes" : "no"
        mark("W502 demo +\(secs()) s: \(title ?? "no demo chat in 90 s"); mixed before: \(before); labels: \(labels())")
        shot("w502-demo")
        XCTAssertNotNil(title, "the Watch showed nothing of the demo (no demo chat) in 90 s")
        for look in 1...6 {
            let demo = demoTitles.first(where: { shows($0) })
            let own = mockRows.first(where: { shows($0) })
            let seen = "demo \(demo ?? "none"), person's \(own ?? "none")"
            mark("W502 demo look \(look) +\(secs()) s: \(seen); labels: \(labels())")
            XCTAssertNotNil(demo, "demo look \(look): no demo chat is shown")
            XCTAssertNil(own, "demo look \(look): the person's \"\(own ?? "")\" is shown in the demo")
            if look < 6 { sleep(3) }
        }
        shot("w502-demo-held")
    }

    /// The iPhone out of the demo: the Watch, launched afresh, shows its own gateway's chat again, and for 15 s after
    /// (six looks, 3 s apart) that chat and nothing of the demo.
    func testCWatchIsBackOnItsGatewayAfterTheDemo() throws {
        let start = Date()
        try launch()
        let sights = demoFromLaunch("c", since: start)
        XCTAssertTrue(sights.isEmpty, "the demo's \(sights.first ?? "") shown after launch, the phone out of it")
        XCTAssertTrue(button("Settings").waitForExistence(timeout: 40), "no start screen")
        let found = ownRowShows(within: 120, "own after")
        mark("W502 own after: \(found ? "shown" : "not shown in 120 s and the Crown search"); labels: \(labels())")
        XCTAssertTrue(found, "the Watch's own gateway's chat didn't show in 120 s and the Crown search after the demo")
        for look in 1...6 {
            let own = shows(ownRow), demo = demoShown()
            mark("W502 look \(look): own \(own ? "yes" : "no"), demo \(demo ?? "none"); labels: \(labels())")
            XCTAssertTrue(own, "look \(look): the Watch's own gateway's chat isn't shown")
            XCTAssertNil(demo, "look \(look): the demo's \"\(demo ?? "")\" is shown")
            if look < 6 { sleep(3) }
        }
        shot("w502-own-after")
    }

    /// The iPhone was in the demo, left it with no gateway in use, and its app is closed: the Watch, launched afresh,
    /// shows its own gateway's chat and, for 15 s (six looks, 3 s apart), nothing of the demo, its name included. With
    /// no fresh context from the phone, the Watch would take the old one's demo flag again, with no phone to say it's
    /// over.
    func testDWatchShowsNoDemoAfterThePhoneLeftIt() throws {
        let start = Date()
        try launch()
        let sights = demoFromLaunch("d", since: start)
        XCTAssertTrue(sights.isEmpty,
                      "the demo's \(sights.first ?? "") shown after launch, the phone out of it and closed")
        XCTAssertTrue(button("Settings").waitForExistence(timeout: 40), "no start screen")
        func secs() -> String { String(format: "%.1f", Date().timeIntervalSince(start)) }
        let found = ownRowShows(within: 120, "own closed")
        let state = found ? "shown" : "not shown in 120 s and the Crown search"
        mark("W502 own closed +\(secs()) s: \(state); labels: \(labels())")
        shot("w502-own-closed")
        XCTAssertTrue(found,
                      "the Watch's own gateway's chat didn't show in 120 s and the Crown search, the phone closed")
        for look in 1...6 {
            let own = shows(ownRow), demo = demoShown()
            let seen = "own \(own ? "yes" : "no"), demo \(demo ?? "none")"
            mark("W502 closed look \(look) +\(secs()) s: \(seen); labels: \(labels())")
            XCTAssertNil(demo, "closed look \(look): the demo's \"\(demo ?? "")\" is shown, the phone out of it")
            XCTAssertTrue(own, "closed look \(look): the Watch's own gateway's chat isn't shown")
            if look < 6 { sleep(3) }
        }
        shot("w502-own-closed-held")
    }
}
