import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Onboarding's own demo (#388, beats 3 and 4). Sprout's look in the tour's chat is the tour's alone: on with no gateway
/// in use, never put on over one, and gone when the tour stops unless Try a demo has started the app's own demo. The
/// chat is real, on the tour's own demo, from the ready-made message to an allowed card, with none of the app's
/// reporters attached, and it leaves nothing behind once the tour moves on. A swipe back and forth while the demo
/// starts or stops ends with the chat the screen shows, or none.
@MainActor
@Suite(.serialized) struct TourChatTests {
    /// What a test changes from inside a closure the tour asks.
    @MainActor final class Flag { var on = false }

    private func waitUntil(_ seconds: Double = 15, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private static var sharedMedia: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("vory-media", isDirectory: true)
    }

    private static func files(in dir: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    // The looks' tests are synchronous on purpose; keep them so. The switch (`DemoLooks`) is one for the whole app, and
    // another suite's tests (DemoLooksTests) run on the main actor whenever one of these waits: an `await` between
    // turning it on and checking it lets those turn it off (or on) in between, and either suite fails now and then.

    @Test func theLooksAreOnWithNoGatewayAndGoWhenTheTourStops() {
        DemoLooks.set(on: false)
        defer { DemoLooks.set(on: false) }
        let tour = TourChat(appHasGateway: { false }, appInDemo: { false })
        tour.wearLooks()
        #expect(DemoLooks.isOn && tour.looksOn)
        let sprout = DemoBots.all.first { $0.name == TourChat.profile }
        #expect(BotAvatarStore.choice(for: TourChat.profile).spec(hex: "").shape == sprout?.shape)
        tour.dropLooks()
        #expect(!DemoLooks.isOn && !tour.looksOn, "the demo's looks outlived the tour")
    }

    @Test func theLooksAreNeverPutOnOverAGatewayInUse() {
        DemoLooks.set(on: false)
        defer { DemoLooks.set(on: false) }
        // A debug launch shows the tour over a gateway in use: its bots keep their own looks.
        let tour = TourChat(appHasGateway: { true }, appInDemo: { false })
        tour.wearLooks()
        #expect(!DemoLooks.isOn && !tour.looksOn)
        tour.dropLooks()
        #expect(!DemoLooks.isOn)
    }

    @Test func tryADemoFromTheTourKeepsTheLooks() {
        DemoLooks.set(on: false)
        defer { DemoLooks.set(on: false) }
        let inDemo = Flag()
        let tour = TourChat(appHasGateway: { false }, appInDemo: { inDemo.on })
        tour.wearLooks()
        // Try a demo: the app's demo is the gateway in use now, and wears the same looks.
        inDemo.on = true
        tour.dropLooks()
        #expect(DemoLooks.isOn, "the tour took the app's demo's looks with it")
        #expect(!tour.looksOn)
        // Looks that were on before a tour (the app's demo) are never that tour's to take off.
        let again = TourChat(appHasGateway: { false }, appInDemo: { false })
        again.wearLooks()
        #expect(!again.looksOn)
        again.dropLooks()
        #expect(DemoLooks.isOn)
    }

    @Test func theToursChatRunsToAnAllowedCardAndLeavesNothingBehind() async throws {
        let defaultsBefore = UserDefaults.standard.dictionaryRepresentation()
        let looksKeys = [BotAvatarStore.storageKey, BotColors.storageKey, BotNames.storageKey]
        let looksBefore = looksKeys.map { UserDefaults.standard.string(forKey: $0) }
        let mirrorBefore = BotLooks.load()
        let snapshotBefore = WidgetSnapshot.load()
        let mediaBefore = Self.files(in: Self.sharedMedia)
        let indexBefore = Keychain.getCodable([GatewayConnection].self, account: "connections.index")

        // A gateway "in use" keeps the looks out of this one: they have their own tests, above.
        let tour = TourChat(pace: .quick, appHasGateway: { true }, appInDemo: { false })
        await tour.start()
        let rt = try #require(tour.runtime)
        let chat = try #require(tour.chat)
        // The tour's own demo, with none of the app's reporters: no push, no Live Activity, no widget hand-off.
        #expect(rt.isEphemeral && rt.connection.isDemo)
        #expect(rt.pushRegistrar == nil)
        #expect(rt.activityReporterFactory() is NoTurnActivity)
        #expect(rt.onSnapshotPublished == nil)
        #expect(chat.profileName == TourChat.profile)
        var tracker = TourChatTracker()
        let atStart = tracker.phase(for: TourChatReading(chat))
        #expect(atStart == .ready)
        let scratch = rt.scratchDirectory

        // Beat 3: the ready-made message, the work, Sprout's ask; beat 4: Allow once, and Sprout's done.
        _ = await chat.send(TourChat.readyMessage)
        await waitUntil { tracker.phase(for: TourChatReading(chat)) == .asked }
        let whenAsked = tracker.phase(for: TourChatReading(chat))
        #expect(whenAsked == .asked)
        let card = try #require(chat.cards.first { $0.method == "approval" })
        // The tour's ask offers two choices, so the real card shows Allow once and Deny (Try a demo keeps four).
        #expect(card.approval?.offeredChoices == TourChat.approvalChoices)
        await chat.respond(card: card, result: .object(["choice": .string("once")]))
        await waitUntil { tracker.phase(for: TourChatReading(chat)) == .answered(allowed: true) }
        let whenDone = tracker.phase(for: TourChatReading(chat))
        #expect(whenDone == .answered(allowed: true))
        let done = try #require(DemoContent.cleanup.approval).done
        #expect(chat.items.contains { if case .assistant(let t, _, _) = $0.kind { return t.contains(done) }; return false })
        let storedID = chat.storedID

        await tour.stop()
        #expect(tour.runtime == nil && tour.chat == nil)

        // Nothing behind. The scratch folder:
        #expect(!FileManager.default.fileExists(atPath: scratch.path), "the tour's scratch folder is still there")
        // The defaults: no key that names the demo's gateway or the chat, and none of the core's.
        let added = UserDefaults.standard.dictionaryRepresentation().filter { defaultsBefore[$0.key] == nil }.map(\.key)
        let ours = added.filter { key in
            [GatewayConnection.demoID.uuidString, storedID].contains { key.contains($0) }
                || ["kanban.", "gateway.", "chat.", "chats.", "transcript", "activeConnectionID"].contains { key.hasPrefix($0) }
        }
        #expect(ours.isEmpty, "the tour wrote defaults: \(ours.sorted())")
        // The address memory, the transcript cache, the widgets' snapshot, the shared media cache.
        #expect(AddressMemory().lastGood(for: GatewayConnection.demoID) == nil)
        #expect(AddressMemory().identity(for: GatewayConnection.demoID) == nil)
        #expect(TranscriptCache.load(connection: GatewayConnection.demoID, storedID: storedID) == nil, "the tour's chat was cached")
        #expect(WidgetSnapshot.load() == snapshotBefore, "the widgets' snapshot changed")
        #expect(Self.files(in: Self.sharedMedia) == mediaBefore, "the shared media cache changed")
        // The bots' looks as stored, and as mirrored for the extensions (the store iCloud syncs from).
        #expect(looksKeys.map { UserDefaults.standard.string(forKey: $0) } == looksBefore, "the stored looks changed")
        let mirror = BotLooks.load()
        #expect(mirror.colors == mirrorBefore.colors && mirror.avatars == mirrorBefore.avatars && mirror.photos == mirrorBefore.photos,
                "the looks' mirror changed")
        // The Keychain: no sign-in for the demo, the saved list as it was.
        #expect(Keychain.getCodable(GatewaySecrets.self, account: "secrets." + GatewayConnection.demoID.uuidString) == nil)
        #expect(Keychain.getCodable([GatewayConnection].self, account: "connections.index") == indexBefore)
    }

    @Test func aSwipeBackAndForthEndsWithTheChatShownOrNone() async throws {
        let tour = TourChat(pace: .quick, appHasGateway: { true }, appInDemo: { false })
        // Onto beat 3, back to beat 1 and in again, quicker than the demo starts: the chat is there.
        let first = Task { await tour.start() }
        let away = Task { await tour.stop() }
        let back = Task { await tour.start() }
        _ = await (first.value, away.value, back.value)
        #expect(tour.runtime != nil && tour.chat != nil, "back on beat 3 with no chat")
        let scratch = try #require(tour.runtime).scratchDirectory
        // In and straight out again (Skip from beat 2): nothing left running.
        let on = Task { await tour.start() }
        let off = Task { await tour.stop() }
        _ = await (on.value, off.value)
        #expect(tour.runtime == nil && tour.chat == nil, "the tour's demo still runs past the chat beats")
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    @Test func anAnswerIsReadFromTheChatsNoteOrTheCommandItRan() {
        var r = TourChatReading()
        r.sent = true; r.running = true; r.tools = 1
        var allowed = TourChatTracker()
        let working = allowed.phase(for: r)
        #expect(working == .working)
        r.asked = true
        let asked = allowed.phase(for: r)
        #expect(asked == .asked)
        var denied = allowed
        // Answered through the approval queue: no note, so the command's own row tells.
        r.asked = false; r.running = false; r.replied = true
        r.tools = 2
        let ranTheCommand = allowed.phase(for: r)
        #expect(ranTheCommand == .answered(allowed: true))
        r.tools = 1
        let ranNothing = denied.phase(for: r)
        #expect(ranNothing == .answered(allowed: false))
        // The chat's note, where it made one, says it outright.
        r.answer = "deny"; r.tools = 2
        let notedDeny = denied.phase(for: r)
        #expect(notedDeny == .answered(allowed: false))
        r.answer = "session"; r.tools = 1
        let notedAllow = denied.phase(for: r)
        #expect(notedAllow == .answered(allowed: true))
        // Another message than the ready-made one, answered with no card: a reply.
        var plain = TourChatTracker()
        var q = TourChatReading()
        let fresh = plain.phase(for: q)
        #expect(fresh == .ready)
        q.sent = true; q.running = true
        let sent = plain.phase(for: q)
        #expect(sent == .working)
        q.running = false; q.replied = true
        let replied = plain.phase(for: q)
        #expect(replied == .replied)
    }

    #if os(iOS)
    @Test func vorysLinesFollowTheChat() {
        var lines = TourLines()
        lines.arrived(at: .chat)
        #expect(lines.text(for: .chat) == "This is a chat with Sprout. Tap Send.")
        lines.advance(on: .chat, demo: true)
        #expect(lines.text(for: .chat) == "This is a chat with Sprout. Tap Send.", "beat 3's line moved on by the clock")
        lines.chatMoved(to: .working)
        #expect(lines.text(for: .chat) == "Sprout\u{2019}s on it. You can watch it work.")
        lines.chatMoved(to: .asked)
        #expect(lines.text(for: .chat) == "That ring fills as the chat uses up its memory.")
        lines.arrived(at: .approval)
        lines.advance(on: .approval, demo: true, asked: true)
        #expect(lines.text(for: .approval) == "It\u{2019}s your call. Tap Allow once to let it go ahead.")
        lines.chatMoved(to: .answered(allowed: true))
        #expect(lines.text(for: .approval) == "Done. Sprout cleared 3.1 GB.")
        // The mention, a moment after the answer: Gizmo, by the folder name the app writes for a pick.
        lines.mentionCame()
        #expect(lines.text(for: .approval) == "Type @ to bring another bot in.")
        #expect(TourChat.mentionBot?.name == "gizmo" && TourChat.mentionBot?.display == "Gizmo")
        #expect(TourChat.profile == "default")
        // A later message's reply leaves beat 4 where it is.
        lines.chatMoved(to: .working)
        lines.chatMoved(to: .answered(allowed: true))
        #expect(lines.text(for: .approval) == "Type @ to bring another bot in.")
        // A fresh chat starts beat 4 again, and a Deny has its own line.
        lines.chatMoved(to: .ready)
        #expect(lines.text(for: .chat) == "This is a chat with Sprout. Tap Send.")
        lines.chatMoved(to: .asked)
        lines.chatMoved(to: .answered(allowed: false))
        #expect(lines.text(for: .approval) == "That\u{2019}s fine too. Nothing happens without your OK.")
        // Beat 4 before the card is up: its second line waits for it.
        var early = TourLines()
        early.arrived(at: .approval)
        early.advance(on: .approval, demo: true, asked: false)
        #expect(early.text(for: .approval) == "Sprout asks before it does anything risky.")
    }
    #endif
}
