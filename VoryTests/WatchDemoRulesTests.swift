import Foundation
import Testing
@testable import VoryCore
@testable import Vory

/// The Apple Watch while the iPhone runs the demo (#502, `WatchDemoRules`): the phone's context says so, the Watch shows
/// the demo through the phone and keeps nothing of it, and goes back to the person's gateway when the demo ends, at
/// once when an answer from the phone says so before the context lands.
@MainActor
@Suite(.serialized) struct WatchDemoRulesTests {
    private let saved = UUID()

    // MARK: The phone's context

    @Test func thePhonesContextNamesTheDemoWhileItRuns() {
        let word = WatchDemoRules.context(activeID: GatewayConnection.demoID)
        #expect(word.demo, "the context doesn't say the demo is in use")
        #expect(word.active == GatewayConnection.demoID.uuidString, "the context leaves the demo out of \"active\"")
    }

    @Test func thePhonesContextAfterTheDemoIsThePersonsGatewayWithNoFlag() {
        let word = WatchDemoRules.context(activeID: saved)
        #expect(!word.demo)
        #expect(word.active == saved.uuidString)
        let none = WatchDemoRules.context(activeID: nil)
        #expect(none.active == nil && !none.demo)
    }

    /// The looks the phone sends while the demo runs are the demo's, as the phone draws them (`DemoLooks`): never the
    /// person's own looks on the demo's bots, whose folders ("default" among them) are the usual ones.
    @Test func theLooksSentInTheDemoAreTheDemosOwn() {
        let wasOn = DemoLooks.isOn
        DemoLooks.set(on: true)
        defer { if !wasOn { DemoLooks.set(on: false) } }
        let looks = DemoLooks.watchLooks(demo: true)
        for bot in DemoBots.all {
            #expect(looks.avatars[bot.name] == DemoLooks.avatar(for: bot.name), "\(bot.name)'s face isn't the demo's")
            #expect(looks.colors[bot.name] == DemoLooks.color(for: bot.name), "\(bot.name)'s colour isn't the demo's")
        }
        #expect(looks.photos.isEmpty, "a photo went with the demo's looks")
        #expect(looks.gateways == nil && looks.shared == nil)
    }

    /// The demo's looks worn without the demo in use (onboarding's tour, `TourChat`): the context has no demo flag, so the
    /// looks sent are the stored ones. The demo's, sent then, the Watch would save as the person's.
    @Test func theLooksSentWithoutTheDemoFlagAreTheStoredOnesEvenWhileTheDemosAreWorn() {
        let wasOn = DemoLooks.isOn
        DemoLooks.set(on: true)
        defer { if !wasOn { DemoLooks.set(on: false) } }
        let looks = DemoLooks.watchLooks(demo: false)
        var stored = BotLooks.load(); stored.gateways = nil; stored.shared = nil
        #expect(looks.avatars == stored.avatars, "the demo's faces went with no demo flag")
        #expect(looks.colors == stored.colors, "the demo's colours went with no demo flag")
        #expect(looks.photos == stored.photos)
        #expect(looks.gateways == nil && looks.shared == nil)
    }

    // MARK: The Watch

    @Test func theWatchRunsTheDemoWhenTheContextSaysSo() {
        #expect(WatchDemoRules.target(demo: true, active: GatewayConnection.demoID) == .demo)
    }

    @Test func theWatchRunsThePersonsGatewayOtherwise() {
        #expect(WatchDemoRules.target(demo: false, active: saved) == .gateway(saved))
        #expect(WatchDemoRules.target(demo: false, active: nil) == .gateway(nil))
        // An older phone naming the demo without the flag: no gateway of the person's, the Watch keeps its own.
        #expect(WatchDemoRules.target(demo: false, active: GatewayConnection.demoID) == .gateway(nil))
    }

    @Test func theWatchKeepsNothingForTheDemo() throws {
        #expect(!WatchDemoRules.keepsState(for: .demo), "the Watch would keep the demo's list, choice, looks, push or numbers")
        let own = GatewayConnection(name: "Home", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        #expect(WatchDemoRules.keepsState(for: own))
    }

    @Test func aRequestForTheDemoAfterItEndedSaysSo() {
        #expect(WatchDemoRules.demoEnded(requested: GatewayConnection.demoID, phoneInDemo: false))
        #expect(!WatchDemoRules.demoEnded(requested: GatewayConnection.demoID, phoneInDemo: true))
        #expect(!WatchDemoRules.demoEnded(requested: saved, phoneInDemo: false))
        #expect(!WatchDemoRules.demoEnded(requested: nil, phoneInDemo: false))
        #expect(WatchDemoRules.endsDemo([WatchDemoRules.demoEndedKey: true]))
        #expect(!WatchDemoRules.endsDemo(["ok": false, "error": "Your iPhone is using another gateway."]))
    }

    /// The phone's app ended in the demo, which it holds in memory only: launched again outside it, the context it
    /// last sent still names the demo, and is sent afresh. A context with no demo flag, or a phone in the demo, sends
    /// nothing.
    @Test func aContextLeftNamingTheDemoIsSentAgainOutsideIt() {
        #expect(WatchDemoRules.contextIsStale(lastSent: [WatchDemoRules.demoKey: true], phoneInDemo: false))
        #expect(!WatchDemoRules.contextIsStale(lastSent: [WatchDemoRules.demoKey: true], phoneInDemo: true))
        #expect(!WatchDemoRules.contextIsStale(lastSent: ["active": saved.uuidString], phoneInDemo: false))
        #expect(!WatchDemoRules.contextIsStale(lastSent: [:], phoneInDemo: false))
    }

    // MARK: The saved lists

    /// The Watch saves a gateway's chat list under that gateway's id and the bot ("-" for none, "*" for every bot): the
    /// gateway that fetched the rows, so a list landing after a switch is never saved under the next gateway's key.
    @Test func aSavedListsKeyIsTheGatewayThatFetchedItAndItsBot() {
        let id = saved.uuidString
        #expect(WatchDemoRules.listKey(gateway: saved, profile: "default") == "watch.sessions.\(id).default")
        #expect(WatchDemoRules.listKey(gateway: saved, profile: nil) == "watch.sessions.\(id).-")
        #expect(WatchDemoRules.listKey(gateway: saved, profile: "*") == "watch.sessions.\(id).*")
    }

    /// At launch the Watch removes the demo's saved lists, which the race before this rule could fill with the person's
    /// rows: every key under the demo's id, whatever the bot, and nothing else. Keys that merely start like the demo's
    /// (another id differing in its last character, the demo's id with a character more) are left.
    @Test func theLaunchCleanupTakesTheDemosSavedListsOnly() throws {
        let demo = GatewayConnection.demoID.uuidString
        let near = try #require(UUID(uuidString: String(demo.dropLast()) + (demo.hasSuffix("1") ? "2" : "1")))
        let keys = ["watch.sessions.\(demo).-", "watch.sessions.\(demo).default", "watch.sessions.\(saved.uuidString).default",
                    "watch.sessions.\(near.uuidString).default", "watch.sessions.\(demo)0.default", "watch.summaries",
                    "watch.syncedGateways", "kanban.available.\(demo)", "activeConnectionID"]
        let taken = WatchDemoRules.demoListKeys(in: keys)
        #expect(taken == ["watch.sessions.\(demo).-", "watch.sessions.\(demo).default"], "the cleanup took \(taken)")
    }

    /// A real gateway's saved list, under a bot or none, survives the launch cleanup: it only ever touches the demo's key.
    @Test func aRealGatewaysSavedListSurvivesTheLaunchCleanup() {
        let own = [WatchDemoRules.listKey(gateway: saved, profile: "default"), WatchDemoRules.listKey(gateway: saved, profile: nil)]
        #expect(WatchDemoRules.demoListKeys(in: own).isEmpty, "the cleanup would take a real gateway's saved list")
        let demoList = WatchDemoRules.listKey(gateway: GatewayConnection.demoID, profile: nil)
        let taken = WatchDemoRules.demoListKeys(in: own + [demoList])
        #expect(taken == [demoList], "beside the demo's, the cleanup took \(taken)")
    }

    // MARK: One move at a time (`DemoMove`)

    /// Every request the Watch makes while it still runs the demo's runtime is answered "the demo ended": a second such
    /// word, while the move back is under way, starts nothing (each would start the activation again, and the nearly
    /// done one would give way). Once the move back has landed, a new one may start.
    @Test func aSecondWordWhileTheWatchLeavesTheDemoStartsNothing() {
        var move = WatchDemoRules.DemoMove()
        let first = move.begin(.leaving)
        #expect(first)
        let second = move.begin(.leaving)
        #expect(!second, "a second word that the demo ended started the move back again")
        move.landed()
        let afterLanding = move.begin(.leaving)
        #expect(afterLanding, "after the move back landed, a new one couldn't start")
    }

    /// A second context saying the demo began, before the first move into it lands, starts nothing.
    @Test func aSecondContextWhileTheWatchEntersTheDemoStartsNothing() {
        var move = WatchDemoRules.DemoMove()
        let first = move.begin(.entering)
        #expect(first)
        let second = move.begin(.entering)
        #expect(!second, "a second context started the move into the demo again")
        move.landed()
        let afterLanding = move.begin(.entering)
        #expect(afterLanding)
    }

    /// A move the other way takes over from one under way (the phone left the demo and came back), and is then the one
    /// under way: a second word of its kind starts nothing. Once an activation lands, a new move may start.
    @Test func aMoveTheOtherWayTakesOverFromOneUnderWay() {
        var move = WatchDemoRules.DemoMove()
        let leaving = move.begin(.leaving)
        #expect(leaving)
        let entering = move.begin(.entering)
        #expect(entering, "a move into the demo was held back by a move out of it")
        let second = move.begin(.entering)
        #expect(!second, "a second context started the move that took over again")
        move.landed()
        let afterLanding = move.begin(.leaving)
        #expect(afterLanding)
    }

    /// A move into the demo overtaken by an activation that isn't the demo's (the Watch's own pick, a route change) is
    /// over when that one lands: a later context saying the demo began can still start the move in, never stuck.
    @Test func aLandingEndsWhateverMoveWasUnderWay() {
        var move = WatchDemoRules.DemoMove()
        let first = move.begin(.entering)
        #expect(first)
        let second = move.begin(.entering)
        #expect(!second, "a second context started the move into the demo again")
        move.landed()
        let afterLanding = move.begin(.entering)
        #expect(afterLanding, "a move into the demo was left stuck by another activation's landing")
    }

    // MARK: Characterisation (green before and after the fix)

    /// The Watch's runtime for the demo is the demo's connection on an ordinary transport, read through the phone. Every
    /// store the core keeps (the transcript cache, the complications' and widgets' snapshot with its "Needs you" count,
    /// the board, the voice) skips an ephemeral runtime, and this one is: by its connection, whatever its transport.
    @Test func characterisationTheWatchsDemoRuntimeIsEphemeral() async {
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "dev.vory.tests.watchdemo." + UUID().uuidString)!, connections: [])
        let rt = GatewayRuntime(connection: .demo, store: store, transport: .network)
        #expect(rt.isEphemeral)
        #expect(rt.scratchDirectory.path != FileManager.default.temporaryDirectory.path, "the demo's files would go to the shared folder")
        await rt.stop()
    }
}
