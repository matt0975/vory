import AVFAudio
import Foundation
import os
import SwiftUI
import VoryCore

/// Hands-free: one conversation at a time, run by the loop's rules
/// (`HandsFreeState`) with the device's ears and voice (the phone's full screen, the Mac's floating window). The listener hears the person and
/// records each turn, the engine turns it into words and the reply into audio, the player
/// plays through the same engine the microphone is on (so the bot's voice is cancelled out of
/// what it hears), and the chat itself carries the messages: everything said lands in the
/// transcript like a typed turn. Approvals are never taken by voice; the card shows on the
/// hands-free screen and the loop waits for a tap.
@MainActor
@Observable
final class HandsFreeSession {
    static let shared = HandsFreeSession()

    private(set) var chat: ChatSession?
    private(set) var state = HandsFreeState()
    /// The reply as it is being said, for the caption.
    private(set) var spoken = ""
    /// Everything said this session, for the screen to scroll (#235).
    private(set) var transcript = VoiceTranscript()
    /// The reply being spoken, in the transcript (Standard).
    private var replyLine: UUID?
    /// The words the device's transcriber heard, shown while the turn is being transcribed.
    private var heardWords = ""
    private static let hearingLineID = UUID()
    /// Where a turn's time goes, one line in the log per turn (#233).
    private var clock = TurnClock()
    /// The last reply spoken or seen, so a snapshot after an outage does not repeat it.
    private var lastReplyHeard: String?
    /// The full-screen view is away while the loop goes on (the chat shows a pill to come back).
    var minimized = false
    private(set) var lastError: String?
    let listener = UtteranceListener()
    private let player = VoicePlayer()
    private var engine: VoiceEngine? { chat?.runtime.voice }

    private var currentReply: SpeechStream?
    /// A reply's stream (open from its first delta), a line of the loop's own (synthesized only
    /// when its turn comes so it does not get ahead of what is being said), or the thinking cue.
    private enum SpeechItem { case reply(SpeechStream), line(String), cue }
    private var queue: [SpeechItem] = []
    private var speechTask: Task<Void, Never>?
    private var cueTask: Task<Void, Never>?
    /// What was said both ways this session, for the gateway's `voice_context`.
    private var exchange = SpokenExchange()
    /// The person spoke over the bot: the next turn says so (`interrupted`).
    private var interruptedLast = false
    private var observers: [Any] = []
    private var watchTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var wasRunning = false
    private var hadCards = false
    private var fakeTask: Task<Void, Never>?

    var isActive: Bool { chat != nil && state.phase != .ended }
    func isActive(for chat: ChatSession) -> Bool { isActive && self.chat === chat }

    // MARK: Live mode

    /// In Live mode a full-duplex voice model (Gemini, the person's key) owns the microphone
    /// and the speaker; the loop's state follows its events instead of the reducer, and every
    /// real request reaches the bot through the model's one tool.
    private(set) var live: GeminiLive.Session?
    var isLive: Bool { live != nil }
    /// What the live provider is called, for the screen ("Live · Gemini").
    private(set) var liveLabel: String?
    private let liveMic = LiveMic()
    private var liveLevels: [Float] = []
    private var liveHeard = ""
    private var liveSaid = ""
    private var livePlayback: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    private var livePlayTask: Task<Void, Never>?
    private var liveTimer: Timer?
    private var liveHearingUntil = Date.distantPast
    private var liveReplyWaiters: [(id: UUID, c: CheckedContinuation<String, Never>)] = []
    private var liveToolsPending = 0
    private var livePausedMute = false
    /// The person's and the model's lines in the transcript while they grow (Live).
    private var livePersonLine: UUID?
    private var liveBotLine: UUID?

    /// The waveform and the live caption, whichever engine is at work.
    var levels: [Float] { isLive ? liveLevels : listener.levels }
    var liveText: String { isLive ? liveHeard : listener.liveText }

    /// The transcript for the screen: what has been said, plus (Standard) the words being heard
    /// right now and the ones waiting on their transcript, which are not in it yet.
    var transcriptLines: [VoiceLine] {
        var lines = transcript.lines
        if !isLive {
            if state.hearing, !listener.liveText.isEmpty { lines.append(VoiceLine(id: Self.hearingLineID, isPerson: true, text: listener.liveText, isFinal: false)) }
            else if state.phase == .transcribing, !heardWords.isEmpty { lines.append(VoiceLine(id: Self.hearingLineID, isPerson: true, text: heardWords, isFinal: false)) }
        }
        return lines
    }

    /// Where the loop goes when nothing is playing: to the card if one waits, to the bot's
    /// pending work, else to the person.
    private var liveIdlePhase: HandsFreePhase { state.cardsPending ? .needsApproval : (liveToolsPending > 0 ? .thinking : .listening) }

    /// Whether the next conversation is Live, and with what; nil means Standard (with a note
    /// when Live was asked for and cannot run).
    static func liveChoice(botName: String) -> (config: GeminiLive.Session.Config?, note: String?) {
        #if DEBUG
        // `-vory-gemini-live-url ws://127.0.0.1:9121`: the stand-in server (Tools/fake-gemini-live), no key needed.
        let args = ProcessInfo.processInfo.arguments
        if GeminiLive.overrideURL == nil, let i = args.firstIndex(of: "-vory-gemini-live-url"), i + 1 < args.count, let u = URL(string: args[i + 1]) { GeminiLive.overrideURL = u }
        #endif
        switch VoiceSettings.conversation {
        case .standard:
            return (nil, nil)
        case .live, .automatic:
            let forced = VoiceSettings.conversation == .live
            switch VoiceSettings.liveProvider {
            case .gemini:
                guard let key = GeminiLive.Key.value ?? (GeminiLive.overrideURL != nil ? "stand-in" : nil) else {
                    return (nil, forced ? "Live needs your Gemini key in Settings › Voice." : nil)
                }
                // The Barge-in and Pause settings reach the live model too (#234).
                return (GeminiLive.Session.Config(voice: VoiceSettings.geminiVoice, systemInstruction: LivePersona.instruction(botName: botName), key: key,
                                                  bargeIn: VoiceSettings.bargeIn, silenceMs: Int(VoiceSettings.endOfTurn.rawValue * 1000)), nil)
            case .openai:
                return (nil, forced ? "OpenAI Live through the gateway comes in a later build." : nil)
            }
        }
    }

    /// DEBUG: `-vory-voice-fake-input` speaks a canned line into the loop with the device's own
    /// voice instead of listening to the microphone, so the whole loop runs on a simulator.
    static let fakeInput: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-vory-voice-fake-input")
        #else
        return false
        #endif
    }()

    // MARK: Start and end

    func start(chat: ChatSession) {
        if isActive { end() }
        self.chat = chat
        state = HandsFreeState()
        state.turnRunning = chat.isRunning
        state.cardsPending = !chat.cards.isEmpty
        wasRunning = chat.isRunning
        hadCards = !chat.cards.isEmpty
        spoken = ""
        lastError = nil
        minimized = false
        exchange = SpokenExchange()
        interruptedLast = false
        transcript = VoiceTranscript()
        replyLine = nil; heardWords = ""
        lastReplyHeard = VoiceCoordinator.lastReply(in: chat.items)
        livePersonLine = nil; liveBotLine = nil
        clock = TurnClock()
        // The system's microphone prompt may be up for a while (on a Mac that has never been
        // asked, until the person answers it): the screen says so rather than "Listening…".
        state.note = "Waiting for microphone access…"
        Task { [weak self] in
            guard await AVAudioApplication.requestRecordPermission() else {
                #if os(macOS)
                let why = "Microphone access denied. Allow it in System Settings › Privacy & Security › Microphone."
                #else
                let why = "Microphone access denied. Allow it in Settings › Vory."
                #endif
                // Said in the chat: the voice screen never shows for a session that could not start.
                self?.lastError = why
                self?.chat?.banner = why
                self?.chat = nil
                return
            }
            self?.state.note = nil
            self?.open()
        }
    }

    private func open() {
        guard let chat else { return }
        let botName = chat.runtime.profiles.first { $0.name == chat.profileName }?.label ?? chat.profileName
        let choice = Self.liveChoice(botName: botName)
        UtteranceListener.log.notice("voice mode: \(choice.config == nil ? "standard" : "live", privacy: .public) (conversation \(VoiceSettings.conversation.rawValue, privacy: .public), provider \(VoiceSettings.liveProvider.rawValue, privacy: .public), key \(GeminiLive.Key.isPresent ? "present" : "none", privacy: .public), override \(GeminiLive.overrideURL != nil ? "set" : "none", privacy: .public))\(choice.note.map { "; " + $0 } ?? "", privacy: .public)")
        if let note = choice.note { state.note = note }
        let onInput = choice.config == nil ? listener.ingest : liveMic.ingest
        do {
            try player.beginHandsFree(tap: !Self.fakeInput, onInput: onInput)
        } catch {
            lastError = error.localizedDescription
            chat.banner = "Voice mode could not start: \(error.localizedDescription)"
            self.chat = nil
            return
        }
        // The chat's own bot speaks and listens, whatever the list has selected meanwhile.
        engine?.profile = chat.profileName
        VoiceCoordinator.shared.stop()
        watch(chat)
        observeNotifications(chat)
        // Quick answers: this chat thinks less and answers fast while voice runs (#238).
        Task { await chat.beginQuickAnswers() }
        if let config = choice.config {
            openLive(config)
            return
        }
        listener.endOfTurnPause = VoiceSettings.endOfTurn.rawValue
        listener.onSpeechStarted = { [weak self] in self?.heardStart() }
        listener.onSpeechEnded = { [weak self] url in self?.heardEnd(url) }
        Task { await engine?.lease(true) }
        run(state.handle(.start))
    }

    func end() {
        guard chat != nil else { return }
        if isLive { closeLive() }
        run(state.handle(.end))
        listener.stop()
        player.endHandsFree()
        watchTask?.cancel(); watchTask = nil
        transcribeTask?.cancel(); transcribeTask = nil
        cueTask?.cancel(); cueTask = nil
        fakeTask?.cancel(); fakeTask = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        // Taken now, not when the task runs: by then the chat is nil and the lease stayed held.
        let engine = engine
        engine?.profile = nil
        Task { await engine?.lease(false) }
        if let chat { Task { await chat.endQuickAnswers() } }
        chat = nil
        minimized = false
    }

    /// For the timing lines: whether the turn ran with quick answers.
    private var quickTag: String { chat?.quickAnswersOn == true ? " (quick answers on)" : "" }

    func mute() { isLive ? liveMute(true) : run(state.handle(.mute)) }
    func unmute() { isLive ? liveMute(false) : run(state.handle(.unmute)) }
    func pause() { isLive ? livePause(true) : run(state.handle(.pause)) }
    func resume() { player.restartAfterChange(); isLive ? livePause(false) : run(state.handle(.resume)) }
    func toggleMute() { state.isMuted ? unmute() : mute() }
    func togglePause() { state.phase == .paused ? resume() : pause() }

    // MARK: Live mode, driven by the model's events

    private func openLive(_ config: GeminiLive.Session.Config) {
        let session = GeminiLive.Session(config: config)
        live = session
        liveLabel = "Gemini"
        liveMic.reset()
        liveMic.muted = false
        liveHeard = ""; liveSaid = ""; liveToolsPending = 0
        liveMic.onChunk = { [weak self] pcm in Task { @MainActor in self?.live?.send(pcm16k: pcm) } }
        session.onEvent = { [weak self] e in self?.liveEvent(e) }
        session.ask = { [weak self] request, context in await self?.liveAsk(request, context) ?? "" }
        setLivePhase(.thinking)
        state.note = nil
        liveTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.liveLevels = self.liveMic.levels
                if self.state.hearing, Date() > self.liveHearingUntil { self.state.hearing = false }
            }
        }
        Task { [weak self] in
            do { try await session.start() } catch { self?.liveFailed(GeminiLive.redact(error.localizedDescription)) }
        }
        syncSurface()
    }

    private func closeLive() {
        live?.stop(); live = nil
        liveTimer?.invalidate(); liveTimer = nil
        livePlayback?.finish(); livePlayback = nil
        livePlayTask?.cancel(); livePlayTask = nil
        player.stop()
        for w in liveReplyWaiters { w.c.resume(returning: "The conversation ended.") }
        liveReplyWaiters = []
        liveLabel = nil
    }

    /// Live could not run or stopped: the Standard loop takes the conversation over in place.
    private func liveFailed(_ reason: String) {
        guard isLive else { return }
        UtteranceListener.log.notice("live ended: \(reason, privacy: .public); continuing in Standard")
        closeLive()
        // Google's prose becomes one sentence (a free-tier limit, a refused key, no network).
        let plain = GeminiLive.Trouble.plain(reason, what: "live sessions")
        state.note = "Live ended: \(plain.headline) Continuing in Standard."
        player.endHandsFree()
        do { try player.beginHandsFree(tap: !Self.fakeInput, onInput: listener.ingest) } catch { lastError = error.localizedDescription; end(); return }
        listener.endOfTurnPause = VoiceSettings.endOfTurn.rawValue
        listener.onSpeechStarted = { [weak self] in self?.heardStart() }
        listener.onSpeechEnded = { [weak self] url in self?.heardEnd(url) }
        Task { await engine?.lease(true) }
        run(state.handle(.start))
    }

    private func setLivePhase(_ phase: HandsFreePhase) {
        guard state.phase != .ended, state.phase != .paused || phase == .listening else { return }
        state.phase = phase
        if phase != .listening { state.hearing = false }
        syncSurface()
        if Self.fakeInput { fakeInputIfListening() }
    }

    private func liveEvent(_ event: LiveEvent) {
        switch event {
        case .ready:
            if state.phase == .thinking, liveToolsPending == 0 { setLivePhase(.listening) }
        case .inputTranscript(let t):
            liveHeard = liveHeard.isEmpty ? t : (t.hasPrefix(" ") || liveHeard.hasSuffix(" ") ? liveHeard + t : liveHeard + " " + t)
            state.caption = liveHeard
            state.hearing = true
            liveHearingUntil = Date().addingTimeInterval(1.2)
            if livePersonLine == nil { livePersonLine = UUID(); clock.start("heard") }
            if let line = livePersonLine { transcript.write(line, isPerson: true, text: liveHeard) }
        case .outputTranscript(let t):
            liveSaid += t
            spoken = liveSaid
            // The model answering closes the person's line; its own grows with each piece.
            if let p = livePersonLine { transcript.finish(p); livePersonLine = nil }
            if liveBotLine == nil { liveBotLine = UUID() }
            if let line = liveBotLine { transcript.write(line, isPerson: false, text: liveSaid) }
        case .audio(let chunk):
            if state.phase != .speaking, state.phase != .paused { setLivePhase(.speaking) }
            pushLiveAudio(chunk)
        case .interrupted:
            cutLivePlayback()
            interruptedLast = true
            liveSaid = ""
            if let b = liveBotLine { transcript.finish(b); liveBotLine = nil }
            // Cut off while a card waits: the card still waits (the Mac's window went back to
            // Listening… over an open approval).
            if state.phase == .speaking { setLivePhase(state.cardsPending ? .needsApproval : .listening) }
            state.hearing = true
            liveHearingUntil = Date().addingTimeInterval(1.2)
        case .turnComplete:
            if !liveHeard.isEmpty { state.caption = liveHeard; liveHeard = "" }
            if let p = livePersonLine { transcript.finish(p); livePersonLine = nil }
            if let b = liveBotLine { transcript.finish(b); liveBotLine = nil }
            liveSaid = ""
            finishLivePlayback()
        case .toolCall:
            liveToolsPending += 1
            clock.mark("tool")
            if let p = livePersonLine { transcript.finish(p); livePersonLine = nil }
            if state.phase == .listening { setLivePhase(.thinking) }
        case .toolCallsCancelled:
            break
        case .goAway:
            state.note = "Reconnecting…"
        case .resumption:
            break
        case .closed(let error):
            liveFailed(error ?? "the connection closed")
        }
    }

    /// Each model turn plays through its own stream; when it has sounded, the loop listens again.
    /// A turn whose end never comes (no `turnComplete` after the last audio) is closed after a
    /// quiet moment, so the screen cannot stay on Speaking.
    private var liveAudioWatchdog: Task<Void, Never>?
    private func pushLiveAudio(_ chunk: AudioChunk) {
        liveAudioWatchdog?.cancel()
        liveAudioWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled, self.livePlayback != nil else { return }
            self.finishLivePlayback()
        }
        if livePlayback == nil {
            let (stream, continuation) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
            livePlayback = continuation
            livePlayTask = Task { [weak self] in
                do { try await self?.player.play(stream) }
                catch { UtteranceListener.log.error("live playback failed: \(error.localizedDescription, privacy: .public)") }
                guard let self, !Task.isCancelled else { return }
                self.livePlayback = nil
                self.livePlayTask = nil
                if self.state.phase == .speaking { self.setLivePhase(self.liveIdlePhase) }
            }
            clock.mark("audio")
            if let line = clock.report() { UtteranceListener.log.notice("live turn: \(line, privacy: .public)\(self.quickTag, privacy: .public)") }
        }
        livePlayback?.yield(chunk)
    }

    private func finishLivePlayback() {
        liveAudioWatchdog?.cancel(); liveAudioWatchdog = nil
        livePlayback?.finish()
        livePlayback = nil
        if livePlayTask == nil, state.phase == .speaking || state.phase == .thinking { setLivePhase(liveIdlePhase) }
    }

    private func cutLivePlayback() {
        liveAudioWatchdog?.cancel(); liveAudioWatchdog = nil
        player.stop()
        livePlayback?.finish(); livePlayback = nil
        livePlayTask?.cancel(); livePlayTask = nil
    }

    /// The model's `ask_bot`: the request goes to the chat as a spoken turn and the bot's reply
    /// comes back as the tool's result, which the model then says in its own words.
    private func liveAsk(_ request: String, _ context: String) async -> String {
        guard let chat else { return "No chat is open." }
        let joined = [exchange.context, context].filter { !$0.isEmpty }.joined(separator: "\n")
        let voice = VoiceTurn(context: joined, interrupted: interruptedLast)
        exchange.said(request)
        interruptedLast = false
        let problem = await chat.send(request, voice: voice)
        clock.mark("sent")
        if let problem {
            liveToolsPending = max(0, liveToolsPending - 1)
            return "The bot could not take that: \(problem)"
        }
        let id = UUID()
        let reply: String = await withCheckedContinuation { c in
            liveReplyWaiters.append((id, c))
            // A bot that never answers must not hold the model's tool forever.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(240))
                guard let self, let i = self.liveReplyWaiters.firstIndex(where: { $0.id == id }) else { return }
                let waiter = self.liveReplyWaiters.remove(at: i)
                waiter.c.resume(returning: "The bot is taking too long. Tell the user it is still working and to check the chat.")
            }
        }
        liveToolsPending = max(0, liveToolsPending - 1)
        if state.phase == .thinking { setLivePhase(liveIdlePhase) }
        return reply
    }

    private func liveReplyArrived(_ text: String) {
        // One reply answers one request, the oldest waiting: with two asks in flight, both
        // used to get the first answer.
        guard !liveReplyWaiters.isEmpty else { return }
        let waiter = liveReplyWaiters.removeFirst()
        clock.mark("reply")
        let spoken = SpokenText.forSpeech(text)
        waiter.c.resume(returning: spoken.isEmpty ? "The bot answered with nothing to say aloud; it is in the chat." : String(spoken.prefix(4000)))
    }

    private func liveMute(_ on: Bool) {
        guard state.phase != .ended else { return }
        state.isMuted = on
        liveMic.muted = on || state.phase == .paused
        if on {
            state.hearing = false
            // The server is told the microphone went quiet on purpose, so a half-heard sound
            // (the tap itself) is not left open as the start of a turn (#234).
            live?.endAudioStream()
        }
        syncSurface()
    }

    private func livePause(_ on: Bool) {
        guard state.phase != .ended else { return }
        if on {
            guard state.phase != .paused else { return }
            livePausedMute = state.isMuted
            state.pausedBy = .person
            state.phase = .paused
            state.hearing = false
            liveMic.muted = true
            cutLivePlayback()
        } else {
            guard state.phase == .paused else { return }
            state.pausedBy = nil
            state.phase = liveIdlePhase
            liveMic.muted = livePausedMute
        }
        syncSurface()
    }

    /// The Live Activity (and the Mac's menu bar) follow the state line.
    private func syncSurface() {
        let line = state.phase == .ended ? nil : state.title
        if line != activityLine { activityLine = line; chat?.noteVoiceMode(line) }
    }

    // MARK: The ears

    private func heardStart() {
        if state.phase == .speaking {
            if VoiceSettings.bargeIn, !Self.fakeInput { interruptedLast = true; run(state.handle(.bargeIn)) }
            else { listener.cancelCapture() }
            return
        }
        guard state.phase == .listening else { listener.cancelCapture(); return }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        run(state.handle(.speechStarted))
    }

    private func heardEnd(_ url: URL?) {
        if state.phase == .listening, state.capturing { clock.start("heard") }
        pendingRecording = url
        let effects = state.handle(.speechEnded)
        if !effects.contains(.captureStop), let url { try? FileManager.default.removeItem(at: url); pendingRecording = nil }
        run(effects)
    }
    private var pendingRecording: URL?

    // MARK: The chat

    /// Follows the chat's turn and its cards.
    private func watch(_ chat: ChatSession) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = chat.isRunning
                        _ = chat.cards.count
                    } onChange: {
                        c.resume()
                    }
                }
                guard !Task.isCancelled, let self, self.chat === chat else { return }
                self.chatChanged(chat)
            }
        }
    }

    private func chatChanged(_ chat: ChatSession) {
        if chat.isRunning != wasRunning {
            wasRunning = chat.isRunning
            if isLive {
                // A turn that ended without a reply still answers the model's tool.
                if !chat.isRunning, !liveReplyWaiters.isEmpty { liveReplyArrived("The bot finished without a spoken answer; the result is in the chat.") }
            } else {
                if !chat.isRunning, state.phase == .thinking, !state.replySpoken,
                   let text = VoiceCoordinator.lastReply(in: chat.items), text != lastReplyHeard {
                    // The reply finished while the socket was down: no completion came, the
                    // snapshot shows it done. It is spoken from the transcript instead of lost.
                    lastReplyHeard = text
                    exchange.heard(SpokenText.forSpeech(text))
                    run(state.handle(.replyCompleted(text)))
                }
                run(state.handle(chat.isRunning ? .sent : .turnEnded(error: nil)))
                // A turn with nothing to say still reports where its time went.
                if !chat.isRunning, !state.replyPending, let line = clock.report() { UtteranceListener.log.notice("turn: \(line, privacy: .public)\(self.quickTag, privacy: .public)") }
            }
        }
        let cards = !chat.cards.isEmpty
        if cards != hadCards {
            hadCards = cards
            if isLive {
                // The model says it in its own words; nothing is ever answered by voice.
                state.cardsPending = cards
                if cards, let card = chat.cards.first {
                    live?.send(text: "System note: an approval is needed on the screen before the bot can go on: \(Self.summary(of: card)). Tell the user briefly to approve it on their screen; the answer comes after.")
                    setLivePhase(.needsApproval)
                } else if state.phase == .needsApproval {
                    setLivePhase(liveIdlePhase)
                }
                return
            }
            if cards, let card = chat.cards.first {
                run(state.handle(.cardArrived(summary: Self.summary(of: card))))
            } else {
                run(state.handle(.cardsCleared))
            }
        }
    }

    /// What is said about a card: the approval's description, else what kind of answer it wants.
    static func summary(of card: PendingCard) -> String {
        if let a = card.approval {
            let text = (a.description ?? a.command ?? a.toolName ?? "an action").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.count > 120 ? String(text.prefix(119)) + "…" : text
        }
        if card.clarify != nil { return "the bot has a question" }
        if card.method == "sudo" { return "a sudo password" }
        return "your input"
    }

    private func observeNotifications(_ chat: ChatSession) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .hermesStreamDelta, object: nil, queue: .main) { [weak self] n in
            guard let id = n.userInfo?["storedID"] as? String, let text = n.userInfo?["text"] as? String else { return }
            Task { @MainActor in
                guard let self, self.chat?.storedID == id, !self.isLive else { return }
                if !self.state.replySpoken { self.clock.mark("delta") }
                self.run(self.state.handle(.replyDelta(text)))
            }
        })
        observers.append(center.addObserver(forName: .hermesReplyCompleted, object: nil, queue: .main) { [weak self] n in
            guard let id = n.userInfo?["storedID"] as? String, let text = n.userInfo?["text"] as? String else { return }
            Task { @MainActor in
                guard let self, self.chat?.storedID == id else { return }
                self.clock.mark("reply")
                self.lastReplyHeard = text
                self.exchange.heard(SpokenText.forSpeech(text))
                if self.isLive { self.liveReplyArrived(text) } else { self.run(self.state.handle(.replyCompleted(text))) }
            }
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            Task { @MainActor in
                guard let self else { return }
                switch type {
                case .began: self.run(self.state.handle(.interruptionBegan))
                case .ended:
                    if options.contains(.shouldResume) { self.player.restartAfterChange() }
                    self.run(self.state.handle(.interruptionEnded(resume: options.contains(.shouldResume))))
                @unknown default: break
                }
            }
        })
        #endif
    }

    // MARK: Effects

    private func run(_ effects: [HandsFreeEffect]) {
        for e in effects { perform(e) }
        updateCue()
        // The Live Activity carries the state (and End) to the Lock Screen and the Island.
        syncSurface()
        if Self.fakeInput { fakeInputIfListening() }
    }
    private var activityLine: String?

    /// A soft tick every few seconds while the bot works in silence, so a tool-heavy turn
    /// never feels like a hang.
    private func updateCue() {
        if state.wantsThinkingCue {
            guard cueTask == nil else { return }
            cueTask = Task { [weak self] in
                while let self, !Task.isCancelled, self.state.wantsThinkingCue {
                    try? await Task.sleep(for: .seconds(3.5))
                    guard !Task.isCancelled, self.state.wantsThinkingCue, self.queue.isEmpty, self.speechTask == nil else { continue }
                    self.enqueue(.cue)
                }
                self?.cueTask = nil
            }
        } else {
            cueTask?.cancel(); cueTask = nil
        }
    }

    /// Two short soft notes, 24 kHz mono.
    nonisolated static let cueChunk: AudioChunk = {
        let rate = 24000.0
        let notes: [(Double, Double)] = [(523.25, 0.07), (659.25, 0.09)]
        var samples: [Int16] = []
        for (freq, seconds) in notes {
            let n = Int(rate * seconds)
            for i in 0..<n {
                let t = Double(i) / rate
                let fade = min(1, t / 0.01, (seconds - t) / 0.03)
                samples.append(Int16(0.12 * fade * sin(2 * .pi * freq * t) * 32767))
            }
        }
        return samples.withUnsafeBytes { AudioChunk(sampleRate: rate, channels: 1, isFloat32: false, data: Data($0)) }
    }()

    private func perform(_ effect: HandsFreeEffect) {
        switch effect {
        case .openMic:
            listener.start()
        case .closeMic:
            listener.stop()
        case .captureStart:
            break   // the listener records from the first sound on its own
        case .captureCancel:
            listener.cancelCapture()
            if let url = pendingRecording { try? FileManager.default.removeItem(at: url); pendingRecording = nil }
        case .captureStop:
            let words = listener.takeWords()
            heardWords = words
            guard let url = pendingRecording else { run(state.handle(.transcript(words))); return }
            pendingRecording = nil
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            #endif
            if !words.isEmpty, engine?.route(for: .transcribe) == .device {
                // Apple's transcriber already heard it: no second pass over the recording.
                try? FileManager.default.removeItem(at: url)
                run(state.handle(.transcript(words)))
            } else {
                transcribe(url)
            }
        case .send(let text):
            guard let chat else { return }
            // The exchange so far goes with the words (not the words themselves, which are the
            // prompt), and whether the bot's last reply was cut off.
            let voice = VoiceTurn(context: exchange.context, interrupted: interruptedLast)
            exchange.said(text)
            interruptedLast = false
            heardWords = ""
            transcript.write(UUID(), isPerson: true, text: text, final: true)
            clock.mark("words")
            Task { [weak self] in
                let problem = await chat.send(text, voice: voice)
                self?.clock.mark("sent")
                if let problem { self?.run(self?.state.handle(.sendFailed(problem)) ?? []) }
                else { self?.run(self?.state.handle(.sent) ?? []) }
            }
        case .beginReplySpeech:
            guard let engine else { return }
            let stream = engine.speakStreaming()
            currentReply = stream
            spoken = ""
            replyLine = UUID()
            enqueue(.reply(stream))
        case .feedReply(let delta):
            currentReply?.send(delta: delta)
            spoken = currentReply?.text ?? spoken
            if let line = replyLine { transcript.write(line, isPerson: false, text: spoken) }
        case .finishReplySpeech:
            currentReply?.finish()
            spoken = currentReply?.text ?? spoken
            currentReply = nil
            if let line = replyLine { transcript.write(line, isPerson: false, text: spoken, final: true); replyLine = nil }
        case .speakWhole(let text):
            guard let engine else { return }
            let stream = engine.speakStreaming()
            stream.send(delta: text)
            stream.finish()
            spoken = stream.text
            transcript.write(UUID(), isPerson: false, text: spoken, final: true)
            enqueue(.reply(stream))
        case .announce(let line):
            enqueue(.line(line))
        case .stopSpeaking:
            currentReply?.stop(); currentReply = nil
            if let line = replyLine { transcript.finish(line); replyLine = nil }
            queue = []
            speechTask?.cancel(); speechTask = nil
            engine?.stop()
            player.stop()
        }
    }

    private func transcribe(_ url: URL) {
        transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: url) }
            guard let engine = self?.engine else { self?.run(self?.state.handle(.transcriptFailed("Connect a gateway first.")) ?? []); return }
            do {
                let text = try await engine.transcribe(file: url)
                guard !Task.isCancelled else { return }
                self?.run(self?.state.handle(.transcript(text)) ?? [])
            } catch {
                guard !Task.isCancelled else { return }
                self?.run(self?.state.handle(.transcriptFailed(error.localizedDescription)) ?? [])
            }
        }
    }

    // MARK: Speaking, one thing after another

    private func enqueue(_ item: SpeechItem) {
        queue.append(item)
        guard speechTask == nil else { return }
        speechTask = Task { [weak self] in
            while let self, !self.queue.isEmpty, !Task.isCancelled {
                let item = self.queue.removeFirst()
                switch item {
                case .reply(let stream):
                    do {
                        try await self.player.play(self.announcingStart(stream.chunks))
                        if !Task.isCancelled { self.run(self.state.handle(.audioFinished)) }
                    } catch {
                        if !Task.isCancelled { self.run(self.state.handle(.audioFailed(error.localizedDescription))) }
                    }
                case .line(let text):
                    guard let engine = self.engine else { continue }
                    try? await self.player.play(engine.speak(text))
                case .cue:
                    let chunk = Self.cueChunk
                    try? await self.player.play(AsyncThrowingStream { c in c.yield(chunk); c.finish() })
                }
            }
            self?.speechTask = nil
        }
    }

    /// The same chunks, with `audioStarted` sent when the first one arrives.
    private func announcingStart(_ chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                var first = true
                do {
                    for try await c in chunks {
                        if first {
                            first = false
                            self?.clock.mark("audio")
                            if let line = self?.clock.report() { UtteranceListener.log.notice("turn: \(line, privacy: .public)\(self?.quickTag ?? "", privacy: .public)") }
                            self?.run(self?.state.handle(.audioStarted) ?? [])
                        }
                        continuation.yield(c)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: Where the time goes

    /// One mark per stage of a turn, reported as one line when the reply sounds: "heard → words
    /// +310 ms → sent +40 ms → delta +1900 ms → audio +450 ms; 2700 ms in all". A mark made
    /// twice (a second delta) is kept as the first.
    struct TurnClock {
        private var marks: [(name: String, at: Date)] = []
        mutating func start(_ name: String) { marks = [(name, Date())] }
        mutating func mark(_ name: String) {
            guard !marks.isEmpty, !marks.contains(where: { $0.name == name }) else { return }
            marks.append((name, Date()))
        }
        mutating func report() -> String? {
            defer { marks = [] }
            guard marks.count > 1 else { return nil }
            var parts = [marks[0].name]
            for i in 1..<marks.count { parts.append("\(marks[i].name) +\(Self.ms(marks[i].at.timeIntervalSince(marks[i - 1].at)))") }
            return parts.joined(separator: " → ") + "; \(Self.ms(marks[marks.count - 1].at.timeIntervalSince(marks[0].at))) in all"
        }
        private static func ms(_ s: TimeInterval) -> String { "\(Int((s * 1000).rounded())) ms" }
    }

    // MARK: A stand-in for the microphone (DEBUG)

    private var fakeTurns = 0
    static let fakeLines = ["What is filling up the disk on that host?", "Yes, go ahead and clean it up."]

    /// Says the next canned line into the loop as soon as it listens, the way a person would.
    func fakeInputIfListening() {
        guard state.phase == .listening, !state.isMuted, !state.hearing, fakeTask == nil, fakeTurns < Self.fakeLines.count else { return }
        let line = Self.fakeLines[fakeTurns]
        fakeTurns += 1
        let ingest = isLive ? liveMic.ingest : listener.ingest
        UtteranceListener.log.notice("fake input: line \(self.fakeTurns) into the \(self.isLive ? "live" : "standard", privacy: .public) mic in 1.5 s")
        fakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            let voice = DeviceSpeaker.voice(identifier: nil)
            var fed = 0
            for await chunk in DeviceSpeaker.render(line, voice: voice) {
                guard !Task.isCancelled, let buffer = chunk.pcmBuffer() else { break }
                ingest(buffer, AVAudioTime(hostTime: mach_absolute_time()))
                fed += 1
                try? await Task.sleep(for: .seconds(chunk.seconds))
            }
            UtteranceListener.log.notice("fake input: fed \(fed) chunks (\(voice?.name ?? "no voice", privacy: .public)); levels now \(self?.levels.suffix(4).description ?? "-", privacy: .public)")
            // Then quiet, at the mic's pace, until the loop calls the turn over.
            if let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22050, channels: 1, interleaved: true),
               let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2205) {
                silence.frameLength = 2205
                for _ in 0..<40 where !Task.isCancelled {
                    ingest(silence, AVAudioTime(hostTime: mach_absolute_time()))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            self?.fakeTask = nil
        }
    }
}
