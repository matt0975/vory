import Foundation
import AVFAudio

/// Speech in and out for the app, by the Speech setting: a recording to text, and text to
/// audio chunks. It owns no audio session and plays nothing; whoever asked plays the chunks
/// (on the phone VoicePlayer, on the Mac its voice-processing engine) so the engine that
/// records is the one that plays, and echo cancellation can do its work.
@MainActor
@Observable
public final class VoiceEngine {
    public private(set) weak var runtime: GatewayRuntime?
    /// What was used last, for Settings › Voice.
    public private(set) var lastSTT: String? = UserDefaults.standard.string(forKey: VoiceSettings.lastSTTKey)
    public private(set) var lastTTS: String? = UserDefaults.standard.string(forKey: VoiceSettings.lastTTSKey)
    /// The gateway said it has no STT / TTS provider; not asked again until then.
    public private(set) var gatewaySTTUnableUntil: Date?
    public private(set) var gatewayTTSUnableUntil: Date?
    public private(set) var lastError: String?
    /// The speak-stream sessions open right now, so a stop can reach them. More than one can
    /// be open: a reply still being spoken and a line queued behind it, or the next reply.
    private var streams: [SpeakStreamClient] = []

    public init() {}
    public func attach(_ runtime: GatewayRuntime) { self.runtime = runtime }

    private var gatewayConnected: Bool { runtime?.socketState.isOpen == true }
    private var gatewayVoice: GatewayVoiceAPI? { runtime.map { GatewayVoiceAPI(api: $0.api, profile: $0.selectedProfile) } }

    public func route(for job: VoiceJob) -> VoiceRoute {
        VoiceRouting.route(for: VoiceSettings.speech, gatewayConnected: gatewayConnected,
                           gatewayUnableUntil: job == .transcribe ? gatewaySTTUnableUntil : gatewayTTSUnableUntil)
    }
    public enum VoiceJob { case transcribe, speak }

    // MARK: Speech to text

    /// A recording (m4a) to words. Automatic tries the gateway first and remembers a refusal.
    public func transcribe(file url: URL) async throws -> String {
        let route = route(for: .transcribe)
        if route == .gateway, let gv = gatewayVoice {
            do {
                let data = try Data(contentsOf: url)
                let t = try await gv.transcribe(data, mimeType: "audio/m4a")
                noteSTT(VoiceRouting.label(route: .gateway, provider: t.provider))
                return t.transcript
            } catch {
                if VoiceSettings.speech == .automatic, VoiceRouting.isNoProvider(error) {
                    gatewaySTTUnableUntil = Date().addingTimeInterval(VoiceRouting.retryAfter)
                } else {
                    lastError = error.localizedDescription
                    throw error
                }
            }
        }
        #if os(iOS) || os(macOS)
        let text = try await DeviceTranscriber.transcribe(file: url)
        noteSTT(VoiceRouting.label(route: .device, provider: nil))
        return text
        #else
        throw HermesAPIError.transport("Dictation on this device is not available here.")
        #endif
    }

    // MARK: Text to speech

    /// Text to audio, as chunks to play in order. On the gateway the speak-stream carries the
    /// whole text in one go (its sentence cutter still starts early); on this device each
    /// sentence is rendered as the last one is handed out. `stop()` ends either.
    public func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error> {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    guard !spoken.isEmpty else { continuation.finish(); return }
                    var done = false
                    if route(for: .speak) == .gateway {
                        done = try await speakOnGateway(spoken, into: continuation)
                    }
                    if !done {
                        try await speakOnDevice(spoken, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    lastError = error.localizedDescription
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Streams the text through the gateway's speak-stream. False when the gateway could not
    /// (no provider, or no audio came) and the device should speak instead; throws on a plain
    /// failure with the Gateway setting, where falling back would hide the problem.
    private func speakOnGateway(_ text: String, into continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation) async throws -> Bool {
        guard let runtime else { return false }
        let client = SpeakStreamClient()
        streams.append(client)
        defer { streams.removeAll { $0 === client } }
        do {
            try await client.open(runtime: runtime, profile: runtime.selectedProfile)
        } catch {
            if VoiceSettings.speech == .gateway { throw error }
            return false
        }
        client.send(delta: text)
        client.finish()
        var rate = 24000
        var channels = 1
        var produced = false
        var provider: String? = nil
        for await frame in client.frames {
            if Task.isCancelled { client.stop(); return true }
            switch frame {
            case .start(let sr, let ch): rate = sr; channels = ch
            case .pcm(let data):
                produced = true
                continuation.yield(AudioChunk(sampleRate: Double(rate), channels: channels, isFloat32: false, data: data))
            case .end: break
            case .fallback:
                // No audio from sentence synthesis: the one-shot route, then the device.
                if let gv = gatewayVoice, let speech = try? await gv.speak(text), let audio = speech.audio,
                   let chunks = try? AudioDecoding.chunks(from: audio, mimeType: speech.mimeType), !chunks.isEmpty {
                    provider = speech.provider
                    for c in chunks { continuation.yield(c) }
                    produced = true
                }
            }
        }
        if produced { noteTTS(VoiceRouting.label(route: .gateway, provider: provider)) }
        else if client.wasStopped { return true }   // cut short on purpose: nothing to fall back to
        else if VoiceSettings.speech == .automatic { gatewayTTSUnableUntil = Date().addingTimeInterval(VoiceRouting.retryAfter) }
        else if VoiceSettings.speech == .gateway { throw HermesAPIError.transport("The gateway made no speech. Check its TTS provider.") }
        return produced
    }

    private func speakOnDevice(_ text: String, into continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation) async throws {
        let voice = DeviceSpeaker.voice(identifier: VoiceSettings.deviceVoice)
        for sentence in SpokenText.sentences(text) {
            if Task.isCancelled { return }
            for await chunk in DeviceSpeaker.render(sentence, voice: voice) {
                if Task.isCancelled { return }
                continuation.yield(chunk)
            }
        }
        noteTTS(VoiceRouting.label(route: .device, provider: nil))
    }

    // MARK: Speech as a reply streams

    /// Speech for a reply as it is written: deltas go in as they arrive, audio comes out as
    /// sentences finish, so the bot starts talking before it has finished writing. Markdown is
    /// filtered on the way (the same filter as `SpokenText.forSpeech`). On the gateway the words
    /// are forwarded to the speak-stream; on this device each sentence is rendered as it completes.
    public func speakStreaming() -> SpeechStream {
        let speech = SpeechStream()
        let route = route(for: .speak)
        speech.task = Task { @MainActor [weak self] in
            guard let self else { speech.finishOutput(); return }
            do {
                var spoken = false
                if route == .gateway { spoken = try await self.streamOnGateway(speech) }
                if !spoken, !Task.isCancelled { try await self.streamOnDevice(speech) }
                speech.finishOutput()
            } catch {
                self.lastError = error.localizedDescription
                speech.finishOutput(throwing: error)
            }
        }
        return speech
    }

    /// Forwards the words to the gateway's speak-stream as they are released. False when the
    /// gateway could not (no provider, no audio) and the device should speak instead.
    private func streamOnGateway(_ speech: SpeechStream) async throws -> Bool {
        guard let runtime else { return false }
        let client = SpeakStreamClient()
        streams.append(client)
        speech.client = client
        defer { streams.removeAll { $0 === client } }
        do {
            try await client.open(runtime: runtime, profile: runtime.selectedProfile)
        } catch {
            if VoiceSettings.speech == .gateway { throw error }
            return false
        }
        var rate = 24000
        var channels = 1
        var produced = false
        var fellBack = false
        var provider: String? = nil
        // The words go up apart from the audio coming down: each piece as the filter releases
        // it, `done` once the reply is complete.
        let pump = Task { @MainActor in
            for await piece in speech.pieces { client.send(delta: piece + " ") }
            client.finish()
        }
        for await frame in client.frames {
            if Task.isCancelled { client.stop(); pump.cancel(); return true }
            switch frame {
            case .start(let sr, let ch): rate = sr; channels = ch
            case .pcm(let data):
                produced = true
                speech.yield(AudioChunk(sampleRate: Double(rate), channels: channels, isFloat32: false, data: data))
            case .end: break
            case .fallback: fellBack = true
            }
        }
        // Whatever the socket did, every piece is read (into `text`) before any other route speaks.
        await pump.value
        if Task.isCancelled { return true }
        if fellBack, !produced, let gv = gatewayVoice, !speech.text.isEmpty {
            // Sentence synthesis made nothing: the one-shot route with the whole reply.
            if let s = try? await gv.speak(speech.text), let audio = s.audio,
               let chunks = try? AudioDecoding.chunks(from: audio, mimeType: s.mimeType), !chunks.isEmpty {
                provider = s.provider
                for c in chunks { speech.yield(c) }
                produced = true
            }
        }
        if produced { noteTTS(VoiceRouting.label(route: .gateway, provider: provider)) }
        else if client.wasStopped { return true }   // cut short on purpose: nothing to fall back to
        else if VoiceSettings.speech == .automatic { gatewayTTSUnableUntil = Date().addingTimeInterval(VoiceRouting.retryAfter) }
        else if VoiceSettings.speech == .gateway { throw HermesAPIError.transport("The gateway made no speech. Check its TTS provider.") }
        // Nothing came of it: the device speaks what has been released, then the rest.
        speech.piecesConsumed = true
        return produced
    }

    /// Renders sentences on this device as they complete; the last one waits for its end or
    /// the end of the reply.
    private func streamOnDevice(_ speech: SpeechStream) async throws {
        let voice = DeviceSpeaker.voice(identifier: VoiceSettings.deviceVoice)
        var pending = ""
        var spoke = false
        func render(_ sentence: String) async {
            for await chunk in DeviceSpeaker.render(sentence, voice: voice) {
                if Task.isCancelled { return }
                spoke = true
                speech.yield(chunk)
            }
        }
        func flush(final: Bool) async {
            var sentences = SpokenText.sentences(pending)
            var held = ""
            if !final, let last = sentences.last, !SpokenText.endsSentence(last) { held = sentences.removeLast() }
            pending = held
            for s in sentences {
                if Task.isCancelled { return }
                await render(s)
            }
        }
        if speech.piecesConsumed {
            pending = speech.text
        } else {
            for await piece in speech.pieces {
                if Task.isCancelled { return }
                pending += (pending.isEmpty ? "" : " ") + piece
                await flush(final: false)
            }
        }
        await flush(final: true)
        if spoke { noteTTS(VoiceRouting.label(route: .device, provider: nil)) }
    }

    /// Barge-in or a tap on stop: whatever is being synthesized stops.
    public func stop() {
        for s in streams { s.stop() }
        streams = []
    }

    /// Hands-free is starting (true) or over (false): the gateway's TTS provider is warmed for
    /// the conversation, or released. Nothing to do when speech is handled here.
    public func lease(_ active: Bool) async {
        guard route(for: .speak) == .gateway, let gv = gatewayVoice else { return }
        await gv.lease(active)
    }

    private func noteSTT(_ s: String) { lastSTT = s; UserDefaults.standard.set(s, forKey: VoiceSettings.lastSTTKey) }
    private func noteTTS(_ s: String) { lastTTS = s; UserDefaults.standard.set(s, forKey: VoiceSettings.lastTTSKey) }
}

/// One reply being spoken as it streams: `send(delta:)` the words as they come, `finish()`
/// when the reply is complete, and play `chunks` as they arrive. `stop()` is the barge-in.
@MainActor
public final class SpeechStream {
    public let chunks: AsyncThrowingStream<AudioChunk, Error>
    private let output: AsyncThrowingStream<AudioChunk, Error>.Continuation
    /// The speakable pieces of the reply, in order, once the filter releases them.
    let pieces: AsyncStream<String>
    private let piecesIn: AsyncStream<String>.Continuation
    private var filter = SpokenText.Incremental()
    /// Everything released so far, as one text, for a route that speaks in one go.
    public private(set) var text = ""
    public private(set) var isFinished = false
    /// The gateway route read every piece (into `text`) before giving up.
    var piecesConsumed = false
    var task: Task<Void, Never>?
    var client: SpeakStreamClient?

    init() {
        var out: AsyncThrowingStream<AudioChunk, Error>.Continuation!
        chunks = AsyncThrowingStream { out = $0 }
        output = out
        var pin: AsyncStream<String>.Continuation!
        pieces = AsyncStream { pin = $0 }
        piecesIn = pin
    }

    public func send(delta: String) {
        guard !isFinished else { return }
        for piece in filter.feed(delta) { release(piece) }
    }

    /// The reply is complete: what is held is released and the audio runs to its end.
    public func finish() {
        guard !isFinished else { return }
        isFinished = true
        for piece in filter.finish() { release(piece) }
        piecesIn.finish()
    }

    /// Stops the words and the audio now.
    public func stop() {
        isFinished = true
        piecesIn.finish()
        task?.cancel()
        client?.stop()
        output.finish()
    }

    private func release(_ piece: String) {
        text += (text.isEmpty ? "" : " ") + piece
        piecesIn.yield(piece)
    }

    func yield(_ chunk: AudioChunk) { output.yield(chunk) }
    func finishOutput(throwing error: Error? = nil) {
        if let error { output.finish(throwing: error) } else { output.finish() }
    }
}
