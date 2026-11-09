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

        /// Leave demo ends a voice session in a demo chat (#392): left running, its scripted loop went on over a runtime
        /// that had stopped, the Mac's voice window stayed up, and its state changes could raise a new card. The app's
        /// own session on the app's own demo, with the scripted voice (no microphone) and a reporter that shows nothing.
        @Test func leavingTheDemoEndsItsVoiceSession() async throws {
            let model = AppModel.shared, voice = HandsFreeSession.shared
            let timing = voice.demoTiming
            defer {
                if voice.isActive { voice.end() }
                voice.demoTiming = timing
                AppModel.activateStandInForTests = nil
            }
            await model.startDemo()
            let rt = try #require(model.runtime)
            try #require(rt.isEphemeral && model.isInDemo)
            rt.activityReporterFactory = { DemoVoiceTests.Lines() }
            let chat = try await rt.newChat(profile: "default")
            voice.demoTiming = DemoVoice.Timing(scale: 0.25)
            voice.start(chat: chat)
            try #require(voice.isActive(for: chat), "the demo's voice session didn't start")

            // Out of the demo with no runtime after it: a used host's saved gateway would otherwise connect.
            AppModel.activateStandInForTests = { _ in }
            await model.endDemo()
            #expect(!model.isInDemo)
            #expect(!voice.isActive, "Leave demo left the demo's voice session up (\(voice.state.title), its chat \(voice.chat?.runtime.connection.name ?? "none"))")
        }

        /// Settings' Notifications toggle in the demo (#392) reaches no relay and saves nothing: off asked the relay to
        /// forget this device, minting its credentials in the Keychain first when there were none, and on registered with
        /// it. With a relay set, so a request to it would be seen; the Keychain's credentials put back as they were.
        @Test func theNotificationsToggleInTheDemoReachesNoRelayAndSavesNothing() async throws {
            let model = AppModel.shared, push = model.push
            let account = PushRelay.credentialsAccount
            let before = Keychain.get(account: account), relayAt = push.relayRegisteredAt
            PushRelay.testURL = URL(string: "https://relay.test.invalid")
            SharedSessionWatch.reset()
            URLProtocol.registerClass(SharedSessionWatch.self)
            defer {
                URLProtocol.unregisterClass(SharedSessionWatch.self)
                PushRelay.testURL = nil
                if let before { try? Keychain.set(before, account: account) } else { Keychain.delete(account: account) }
                push.relayRegisteredAt = relayAt
                AppModel.activateStandInForTests = nil
            }
            try #require(PushRelay.isConfigured, "no relay: a request to it could not be seen")
            await model.startDemo()
            try #require(model.isInDemo)
            await push.notificationsTurned(on: false, runtime: model.runtime)
            await push.notificationsTurned(on: true, runtime: model.runtime)
            try? await Task.sleep(for: .milliseconds(500))
            #expect(SharedSessionWatch.seen.isEmpty, "the Notifications toggle in the demo sent: \(SharedSessionWatch.seen)")
            #expect(Keychain.get(account: account) == before, "the Notifications toggle in the demo changed the relay's credentials")
            AppModel.activateStandInForTests = { _ in }
            await model.endDemo()
        }

        /// What the demo says is the device's voice (#392), whatever Settings › Voice › Speech says: on the gateway's route
        /// its replies opened a socket of the network's own, to an address that is nowhere. The demo's own runtime, under
        /// this host's setting (read, never written: it syncs).
        @Test func spokenRepliesInTheDemoUseTheDeviceVoice() async throws {
            let store = ConnectionStore(defaults: UserDefaults(suiteName: "dev.vory.tests.demospeech." + UUID().uuidString)!, connections: [])
            let rt = GatewayRuntime(connection: .demo, store: store, transport: .demo(DemoGateway(pace: .quick)))
            await rt.start()
            let engine = VoiceEngine()
            engine.attach(rt)
            #expect(engine.route(for: .speak) == .device, "the demo's speech went the gateway's way (Speech: \(VoiceSettings.speech.rawValue), the socket \(rt.socketState.label))")
            await rt.stop()
        }

        /// The route under every setting (#392): the demo's speech is the device's under each one; its words to text, and
        /// a gateway of the person's own, go as before.
        @Test func theDemosSpeechIsTheDevicesUnderEverySetting() {
            for setting in SpeechSource.allCases {
                #expect(VoiceEngine.route(for: .speak, inDemo: true, setting: setting, gatewayConnected: true, gatewayUnableUntil: nil) == .device,
                        "the demo's speech under \(setting.rawValue) went the gateway's way")
                #expect(VoiceEngine.route(for: .speak, inDemo: false, setting: setting, gatewayConnected: true, gatewayUnableUntil: nil)
                        == VoiceRouting.route(for: setting, gatewayConnected: true, gatewayUnableUntil: nil), "a gateway's own speech changed under \(setting.rawValue)")
                #expect(VoiceEngine.route(for: .transcribe, inDemo: true, setting: setting, gatewayConnected: true, gatewayUnableUntil: nil)
                        == VoiceRouting.route(for: setting, gatewayConnected: true, gatewayUnableUntil: nil), "the demo's words to text changed under \(setting.rawValue)")
            }
        }

        /// The gateway's speech socket is never opened for the demo (#392): a try is turned down and counted with the
        /// requests the demo's sessions refuse, so a page that reaches for it shows in the no-trace counts.
        @Test func theDemoOpensNoGatewaySpeechSocketAndCountsTheTry() async throws {
            let store = ConnectionStore(defaults: UserDefaults(suiteName: "dev.vory.tests.demospeech." + UUID().uuidString)!, connections: [])
            let rt = GatewayRuntime(connection: .demo, store: store, transport: .demo(DemoGateway(pace: .quick)))
            await rt.start()
            let before = DemoURLProtocol.refused
            let client = SpeakStreamClient()
            await #expect(throws: (any Error).self) { try await client.open(runtime: rt, profile: nil) }
            #expect(!client.isOpen, "the speech socket opened for the demo")
            #expect(DemoURLProtocol.refused == before + 1, "the try wasn't counted (\(DemoURLProtocol.refused - before))")
            await rt.stop()
        }
    }
}
