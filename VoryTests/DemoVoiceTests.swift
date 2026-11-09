import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Demo mode's voice (#621): voice mode in a demo chat runs the loop with scripted ears and voice. The person's line
/// comes word by word, the bot answers with the demo's one approval card, Allow once or Deny moves the turn on, and the
/// loop listens again. The chat keeps the turn. Nothing reaches the microphone, the player or the voice engine, and a
/// turn ended early is not read aloud after.
@MainActor
@Suite(.serialized) struct DemoVoiceTests {
    private let cleanup = DemoContent.cleanup.approval!

    /// The words under the bot, in order, as the loop tells the Live Activity (or the menu bar) each time they change:
    /// every state the session showed, however short; nil once it ended.
    @MainActor final class Lines: TurnActivityReporting {
        private(set) var lines: [String?] = []
        func start(for chat: ChatSession) {}
        func update(for chat: ChatSession, attention: Bool, detail: String?) {}
        func end(for chat: ChatSession, phase: String) {}
        func voiceMode(for chat: ChatSession, line: String?) { lines.append(line) }
        /// Whether these come in this order, others allowed between.
        func follow(_ wanted: [String]) -> Bool {
            var i = 0
            for l in lines where i < wanted.count && l == wanted[i] { i += 1 }
            return i == wanted.count
        }
    }

    private func runtime(lines: Lines? = nil) async -> GatewayRuntime {
        let name = "dev.vory.tests.demovoice." + UUID().uuidString
        let store = ConnectionStore(defaults: UserDefaults(suiteName: name)!, connections: [])
        let rt = GatewayRuntime(connection: .demo, store: store, transport: .demo(DemoGateway(pace: .quick)))
        if let lines { rt.activityReporterFactory = { lines } }
        await rt.start()
        return rt
    }

    /// Polls often: some states of the loop last only a moment at the tests' pace.
    private func waitUntil(_ seconds: Double = 20, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func replyText(_ chat: ChatSession) -> String {
        chat.items.compactMap { item -> String? in
            if case .assistant(let t, _, _) = item.kind { return t }
            return nil
        }.joined(separator: "\n")
    }

    private func userTexts(_ chat: ChatSession) -> [String] {
        chat.items.compactMap { item -> String? in
            if case .user(let t, _) = item.kind { return t }
            return nil
        }
    }

    private func session() -> HandsFreeSession {
        let voice = HandsFreeSession()
        voice.demoTiming = DemoVoice.Timing(scale: 0.25)
        return voice
    }

    /// Starts a demo session and follows it to its card: the line's words as they came, and the loudest the waveform
    /// went.
    private func toTheCard(_ voice: HandsFreeSession, _ chat: ChatSession) async -> (heard: Set<String>, loudest: Float) {
        voice.start(chat: chat)
        var heard: Set<String> = []
        var loudest: Float = 0
        await waitUntil {
            if voice.state.hearing { heard.insert(voice.liveText) }
            loudest = max(loudest, voice.levels.max() ?? 0)
            return voice.state.phase == .needsApproval && chat.cards.contains { $0.method == "approval" }
        }
        return (heard, loudest)
    }

    @Test func aVoiceTurnAsksForTheApprovalEachTimeAndATypedOneOncePerDemo() async throws {
        let rt = await runtime()
        defer { Task { await rt.stop() } }
        let chat = try await rt.newChat(profile: "default")
        _ = await chat.send(DemoGateway.voiceLine)
        await waitUntil { chat.cards.contains { $0.method == "approval" } }
        let typed = try #require(chat.cards.first { $0.method == "approval" })
        await chat.respond(card: typed, result: .object(["choice": .string("once")]))
        await waitUntil { !chat.isRunning && replyText(chat).contains(cleanup.done) }
        // Said in voice mode, the same words ask again.
        _ = await chat.send(DemoGateway.voiceLine, voice: VoiceTurn())
        await waitUntil { chat.cards.contains { $0.method == "approval" } }
        let spoken = try #require(chat.cards.first { $0.method == "approval" })
        #expect(spoken.approval?.command == cleanup.command)
        await chat.respond(card: spoken, result: .object(["choice": .string("deny")]))
        await waitUntil { !chat.isRunning && replyText(chat).contains(cleanup.denied) }
        #expect(replyText(chat).contains(cleanup.denied))
        // Typed, the next cleanup is answered without asking, as before.
        _ = await chat.send("And clean up the old screenshots too.")
        await waitUntil { !chat.isRunning && replyText(chat).contains("Want me to set a reminder") }
        #expect(replyText(chat).contains("Want me to set a reminder"))
        #expect(chat.cards.isEmpty)
    }

    @Test func aDemoSessionHearsItsLineShowsTheCardAndListensAgainAfterAllowOnce() async throws {
        let lastSession = UserDefaults.standard.string(forKey: VoiceSettings.lastSessionKey)
        let lines = Lines()
        let rt = await runtime(lines: lines)
        defer { Task { await rt.stop() } }
        let chat = try await rt.newChat(profile: "default")
        let voice = session()
        let (heard, loudest) = await toTheCard(voice, chat)
        #expect(voice.isDemo)
        #expect(chat.banner?.localizedCaseInsensitiveContains("microphone") != true, "the chat said \(chat.banner ?? "")")
        // Listening, the line heard as it is said, Got it, thinking, then the card.
        #expect(lines.lines.first == "Listening…")
        #expect(lines.follow(["Listening…", "Listening", "Got it…", "Thinking…", "Approval needed"]), "the words were \(lines.lines)")
        #expect(heard.count > 2, "the line came all at once: \(heard)")
        #expect(heard.contains(DemoGateway.voiceLine))
        #expect(loudest > 0.3, "the waveform stayed at \(loudest)")
        // The words on the screen: the person's line, then the bot's ask; the card is the chat's own.
        #expect(voice.transcriptLines.first?.isPerson == true)
        #expect(voice.transcriptLines.first?.text == DemoGateway.voiceLine)
        #expect(voice.transcriptLines.contains { !$0.isPerson && $0.text.hasPrefix("Your logs folder is the big one") })
        let card = try #require(chat.cards.first { $0.method == "approval" })
        #expect(card.approval?.command == cleanup.command)

        await chat.respond(card: card, result: .object(["choice": .string("once")]))
        await waitUntil { !chat.isRunning && voice.state.phase == .listening && voice.transcriptLines.contains { !$0.isPerson && $0.text == cleanup.done } }
        #expect(voice.state.phase == .listening)
        #expect(voice.transcriptLines.last?.text == cleanup.done)
        // Allowed: the reply said, then listening again.
        #expect(lines.follow(["Approval needed", "Speaking", "Listening…"]), "the words were \(lines.lines)")
        // The chat keeps the turn, as after a real session.
        #expect(userTexts(chat) == [DemoGateway.voiceLine])
        #expect(replyText(chat).contains(cleanup.done))

        // The controls, with the words under the bot as in a real session.
        voice.mute()
        #expect(voice.state.title == "Muted")
        voice.unmute()
        #expect(voice.state.title == "Listening…")
        voice.pause()
        #expect(voice.state.title == "Paused")
        voice.resume()
        #expect(voice.state.title == "Listening…")
        voice.minimized = true
        #expect(voice.isActive)
        voice.minimized = false
        // Said once a session: listening goes on, and nothing more is sent.
        try? await Task.sleep(for: .seconds(1.5))
        #expect(voice.state.phase == .listening)
        #expect(userTexts(chat).count == 1)

        voice.end()
        #expect(!voice.isActive && !voice.isDemo)
        #expect(lines.follow(["Muted", "Listening…", "Paused", "Listening…"]), "the words were \(lines.lines)")
        #expect(lines.lines.last == .some(nil), "the surface wasn't told voice mode ended: \(lines.lines)")
        #expect(voice.audioReached.isEmpty, "the demo reached \(voice.audioReached)")
        #expect(!chat.quickAnswersOn)
        #expect(UserDefaults.standard.string(forKey: VoiceSettings.lastSessionKey) == lastSession)
    }

    @Test func denyGetsTheBotsOneLineThenListeningAndTheChatKeepsTheAnswer() async throws {
        let rt = await runtime()
        defer { Task { await rt.stop() } }
        let chat = try await rt.newChat(profile: "default")
        let voice = session()
        _ = await toTheCard(voice, chat)
        let card = try #require(chat.cards.first { $0.method == "approval" })
        await chat.respond(card: card, result: .object(["choice": .string("deny")]))
        await waitUntil { !chat.isRunning && voice.state.phase == .listening && voice.transcriptLines.contains { !$0.isPerson && $0.text == cleanup.denied } }
        #expect(voice.state.phase == .listening)
        #expect(voice.transcriptLines.last?.text == cleanup.denied)
        #expect(!replyText(chat).contains(cleanup.done))
        #expect(chat.items.contains { if case .system(let t, _) = $0.kind { return t == "Approval: deny" }; return false })
        #expect(voice.audioReached.isEmpty, "the demo reached \(voice.audioReached)")
        // The tripwire itself: the listener read while a demo session runs is noted.
        _ = voice.listener
        #expect(voice.audioReached == ["listener"])
        voice.end()
        #expect(!voice.isActive)
    }

    @Test func aDemoTurnEndedBeforeItsReplyIsNotReadAloudAndATypedOneAfterStillIs() async throws {
        @MainActor final class Said { var reads: [Bool] = [] }
        let rt = await runtime()
        defer { Task { await rt.stop() } }
        let chat = try await rt.newChat(profile: "default")
        let voice = session()
        let said = Said()
        // What "Read replies aloud" decides for each reply that finishes, with the chat in front.
        let observer = NotificationCenter.default.addObserver(forName: .hermesReplyCompleted, object: nil, queue: .main) { n in
            guard let id = n.userInfo?["storedID"] as? String else { return }
            Task { @MainActor in said.reads.append(VoiceCoordinator.readsAloud(id, visible: id, voice: voice)) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        voice.start(chat: chat)
        await waitUntil { voice.state.phase == .thinking }
        voice.end()
        #expect(!voice.isActive)
        // The turn goes on in the chat, card and all.
        await waitUntil { chat.cards.contains { $0.method == "approval" } }
        let card = try #require(chat.cards.first { $0.method == "approval" })
        await chat.respond(card: card, result: .object(["choice": .string("once")]))
        await waitUntil { said.reads.count == 1 }
        #expect(said.reads == [false], "the voice turn's reply would be read aloud")
        #expect(replyText(chat).contains(cleanup.done))
        // A moment after, a typed turn's reply is read as before.
        try? await Task.sleep(for: .seconds(1.5))
        #expect(!voice.keepsQuiet(chat.storedID))
        _ = await chat.send("What should I plan for this weekend?")
        await waitUntil { said.reads.count == 2 }
        #expect(said.reads == [false, true])
    }
}
