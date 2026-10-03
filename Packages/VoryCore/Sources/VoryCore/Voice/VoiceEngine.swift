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
    /// The speak-stream session open right now, so a stop can reach it.
    private var stream: SpeakStreamClient?

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
        stream?.stop()
        stream = client
        defer { if stream === client { stream = nil } }
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

    /// Barge-in or a tap on stop: whatever is being synthesized stops.
    public func stop() {
        stream?.stop(); stream = nil
    }

    private func noteSTT(_ s: String) { lastSTT = s; UserDefaults.standard.set(s, forKey: VoiceSettings.lastSTTKey) }
    private func noteTTS(_ s: String) { lastTTS = s; UserDefaults.standard.set(s, forKey: VoiceSettings.lastTTSKey) }
}
