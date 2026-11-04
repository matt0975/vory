import Foundation
import Testing
@testable import VoryCore
@testable import Vory

extension DemoNoTraceTests {
    /// What the demo showed outside the app (#632): its cards and notifications. Every launch takes what a demo ended with
    /// the app left, a demo in use or not; and another gateway picked while the demo runs leaves it as Leave demo does.
    /// Inside DemoNoTraceTests, whose tests run one at a time, since these drive the app's own model through the demo too.
    @MainActor
    @Suite struct Leftovers {
        private static let demo = GatewayConnection.demoID.uuidString

        /// The app model's first moment runs the sweep (this host's launch made one), and it runs with the demo in use:
        /// the demo lives in memory, so nothing of the demo's at a launch is this process's, even under `-vory-demo`.
        @Test func theLaunchSweepRanAtThisLaunchAndRunsUnderARunningDemo() async {
            let model = AppModel.shared
            #expect(DemoLeftovers.sweepsForTests >= 1, "the app model was made without the launch sweep")
            #expect(DemoLeftovers.launchedAt <= Date())
            await model.startDemo()
            #expect(model.isInDemo)
            let before = DemoLeftovers.sweepsForTests
            DemoLeftovers.sweepAtLaunch()
            #expect(DemoLeftovers.sweepsForTests == before + 1, "the sweep held back for a demo in use")
            // Out of the demo with no runtime after it: a used host's saved gateway would otherwise connect.
            AppModel.activateStandInForTests = { _ in }
            defer { AppModel.activateStandInForTests = nil }
            await model.endDemo()
            #expect(!model.isInDemo && model.runtime == nil)
        }

        /// The demo's own, by its gateway id: delivered before this launch, or waiting. Not one delivered since, nor another
        /// gateway's, nor one with no gateway at all.
        @Test func onlyTheDemosNotificationsFromBeforeThisLaunchAreTaken() {
            let launch = Date(timeIntervalSince1970: 2_000_000_000)
            let other = UUID().uuidString
            let delivered = [
                DemoLeftovers.Entry(id: "demo-before", connection: Self.demo, date: launch.addingTimeInterval(-60)),
                DemoLeftovers.Entry(id: "demo-since", connection: Self.demo, date: launch.addingTimeInterval(1)),
                DemoLeftovers.Entry(id: "other-before", connection: other, date: launch.addingTimeInterval(-60)),
                DemoLeftovers.Entry(id: "none-before", connection: nil, date: launch.addingTimeInterval(-60)),
            ]
            #expect(DemoLeftovers.notifications(delivered, of: Self.demo, before: launch) == ["demo-before"])
            // Leave demo's: all of the demo's, whenever they came.
            #expect(DemoLeftovers.notifications(delivered, of: Self.demo, before: nil) == ["demo-before", "demo-since"])
            let waiting = [
                DemoLeftovers.Entry(id: "demo-waiting", connection: Self.demo, date: nil),
                DemoLeftovers.Entry(id: "other-waiting", connection: other, date: nil),
            ]
            #expect(DemoLeftovers.notifications(waiting, of: Self.demo, before: nil) == ["demo-waiting"])
        }

        /// The demo's cards only: not another gateway's, nor one from before cards carried their gateway (empty id).
        @Test func onlyTheDemosCardsAreEnded() {
            let cards = [(id: "a", connection: Self.demo), (id: "b", connection: UUID().uuidString), (id: "c", connection: "")]
            #expect(DemoLeftovers.cards(cards, of: Self.demo) == ["a"])
        }

        /// Another gateway picked in the demo (Settings › Gateways, the chat list's Switch gateway, and any other path to
        /// `activate`) goes through Leave demo's clean-up, then to that gateway; outside the demo the same pick doesn't.
        /// The runtime past the guard is the stand-in's: nothing connects, nothing is saved.
        @Test func anotherGatewayPickedInTheDemoLeavesItAsLeaveDemoDoes() async throws {
            let model = AppModel.shared
            let other = GatewayConnection(name: "other", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
            var handed: [UUID] = []
            let witness = "dev.vory.tests.632." + Self.demo
            defer {
                AppModel.activateStandInForTests = nil
                UserDefaults.standard.removeObject(forKey: witness)
            }
            await model.startDemo()
            try #require(model.isInDemo && ChatListPrefs.shared.inDemo)
            // A key naming the demo, as an older build left them: Leave demo's sweep takes it.
            UserDefaults.standard.set(1, forKey: witness)
            let takenBefore = DemoLeftovers.takenAwayForTests
            AppModel.activateStandInForTests = { handed.append($0.id) }

            await model.activate(other)
            #expect(DemoLeftovers.takenAwayForTests == takenBefore + 1, "the demo's cards and notifications were left")
            #expect(UserDefaults.standard.object(forKey: witness) == nil, "the demo's traces were left")
            #expect(!model.isInDemo && model.store.demo == nil, "the demo is still the gateway in use")
            #expect(!ChatListPrefs.shared.inDemo, "the chat list kept the demo's filters")
            #expect(model.runtime == nil, "the demo's runtime still runs")
            #expect(handed == [other.id], "the picked gateway didn't come after the demo: \(handed)")

            // The control: the same pick outside the demo goes straight to the gateway.
            await model.activate(other)
            #expect(DemoLeftovers.takenAwayForTests == takenBefore + 1, "a pick outside the demo ran the demo's clean-up")
            #expect(handed == [other.id, other.id])
        }
    }
}
