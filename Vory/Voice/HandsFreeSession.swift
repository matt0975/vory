import AVFAudio
import Foundation
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
        Task { [weak self] in
            guard await AVAudioApplication.requestRecordPermission() else {
                self?.lastError = "Microphone access denied. Allow it in Settings › Vory."
                self?.chat = nil
                return
            }
            self?.open()
        }
    }

    private func open() {
        guard let chat else { return }
        do {
            try player.beginHandsFree(tap: !Self.fakeInput, onInput: listener.ingest)
        } catch {
            lastError = error.localizedDescription
            self.chat = nil
            return
        }
        listener.endOfTurnPause = VoiceSettings.endOfTurn.rawValue
        listener.onSpeechStarted = { [weak self] in self?.heardStart() }
        listener.onSpeechEnded = { [weak self] url in self?.heardEnd(url) }
        VoiceCoordinator.shared.stop()
        watch(chat)
        observeNotifications(chat)
        Task { await engine?.lease(true) }
        run(state.handle(.start))
    }

    func end() {
        guard chat != nil else { return }
        run(state.handle(.end))
        listener.stop()
        player.endHandsFree()
        watchTask?.cancel(); watchTask = nil
        transcribeTask?.cancel(); transcribeTask = nil
        cueTask?.cancel(); cueTask = nil
        fakeTask?.cancel(); fakeTask = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        Task { await engine?.lease(false) }
        chat = nil
        minimized = false
    }

    func mute() { run(state.handle(.mute)) }
    func unmute() { run(state.handle(.unmute)) }
    func pause() { run(state.handle(.pause)) }
    func resume() { player.restartAfterChange(); run(state.handle(.resume)) }
    func toggleMute() { state.isMuted ? unmute() : mute() }
    func togglePause() { state.phase == .paused ? resume() : pause() }

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
            run(state.handle(chat.isRunning ? .sent : .turnEnded(error: nil)))
        }
        let cards = !chat.cards.isEmpty
        if cards != hadCards {
            hadCards = cards
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
                guard let self, self.chat?.storedID == id else { return }
                self.run(self.state.handle(.replyDelta(text)))
            }
        })
        observers.append(center.addObserver(forName: .hermesReplyCompleted, object: nil, queue: .main) { [weak self] n in
            guard let id = n.userInfo?["storedID"] as? String, let text = n.userInfo?["text"] as? String else { return }
            Task { @MainActor in
                guard let self, self.chat?.storedID == id else { return }
                self.exchange.heard(SpokenText.forSpeech(text))
                self.run(self.state.handle(.replyCompleted(text)))
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
        let line = state.phase == .ended ? nil : state.title
        if line != activityLine { activityLine = line; chat?.noteVoiceMode(line) }
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
            Task { [weak self] in
                if let problem = await chat.send(text, voice: voice) { self?.run(self?.state.handle(.sendFailed(problem)) ?? []) }
                else { self?.run(self?.state.handle(.sent) ?? []) }
            }
        case .beginReplySpeech:
            guard let engine else { return }
            let stream = engine.speakStreaming()
            currentReply = stream
            spoken = ""
            enqueue(.reply(stream))
        case .feedReply(let delta):
            currentReply?.send(delta: delta)
            spoken = currentReply?.text ?? spoken
        case .finishReplySpeech:
            currentReply?.finish()
            spoken = currentReply?.text ?? spoken
            currentReply = nil
        case .speakWhole(let text):
            guard let engine else { return }
            let stream = engine.speakStreaming()
            stream.send(delta: text)
            stream.finish()
            spoken = stream.text
            enqueue(.reply(stream))
        case .announce(let line):
            enqueue(.line(line))
        case .stopSpeaking:
            currentReply?.stop(); currentReply = nil
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
                        if first { first = false; self?.run(self?.state.handle(.audioStarted) ?? []) }
                        continuation.yield(c)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: A stand-in for the microphone (DEBUG)

    private var fakeTurns = 0
    static let fakeLines = ["What is filling up the disk on that host?", "Yes, go ahead and clean it up."]

    /// Says the next canned line into the loop as soon as it listens, the way a person would.
    private func fakeInputIfListening() {
        guard state.phase == .listening, !state.isMuted, !state.hearing, fakeTask == nil, fakeTurns < Self.fakeLines.count else { return }
        let line = Self.fakeLines[fakeTurns]
        fakeTurns += 1
        let ingest = listener.ingest
        fakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            let voice = DeviceSpeaker.voice(identifier: nil)
            for await chunk in DeviceSpeaker.render(line, voice: voice) {
                guard !Task.isCancelled, let buffer = chunk.pcmBuffer() else { break }
                ingest(buffer, AVAudioTime(hostTime: mach_absolute_time()))
                try? await Task.sleep(for: .seconds(chunk.seconds))
            }
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
