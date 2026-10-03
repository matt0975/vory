#if os(iOS)
import AVFAudio
import VoryCore

/// Plays the voice engine's audio chunks on the phone through an AVAudioEngine of its own:
/// a player node, each chunk converted to the standard float format at its own rate (the
/// mixer resamples to the hardware), scheduled in order, with `stop()` cutting it short.
/// Keeping playback in an engine of ours is what lets voice processing cancel the bot's own
/// voice when the microphone is open at the same time (hands-free, later).
@MainActor
@Observable
final class VoicePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?
    private(set) var isPlaying = false
    private var pending = 0
    private var ended = false
    private var finish: CheckedContinuation<Void, Never>?

    init() { engine.attach(node) }

    /// Plays every chunk of the stream in order and returns once the last one has sounded
    /// (or the stream failed, or `stop()` was called).
    func play(_ chunks: AsyncThrowingStream<AudioChunk, Error>) async throws {
        try beginSession()
        isPlaying = true
        pending = 0; ended = false
        defer { isPlaying = false; endSession() }
        do {
            for try await chunk in chunks {
                guard isPlaying else { break }
                guard let buffer = Self.standardBuffer(from: chunk) else { continue }
                try connect(for: buffer.format)
                pending += 1
                node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in self?.played() }
                }
                if !node.isPlaying { node.play() }
            }
        } catch {
            stop()
            throw error
        }
        ended = true
        if pending > 0, isPlaying {
            await withCheckedContinuation { c in finish = c }
        }
    }

    private func played() {
        pending = max(0, pending - 1)
        if ended, pending == 0, let c = finish { finish = nil; c.resume() }
    }

    /// Cuts playback short.
    func stop() {
        guard isPlaying || node.isPlaying else { return }
        isPlaying = false
        node.stop()
        if let c = finish { finish = nil; c.resume() }
    }

    private func beginSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        // The engine starts in `connect(for:)`, once the player node is wired to the mixer:
        // starting it with no connections raises (not throws) inside AVAudioEngine.
    }

    private func endSession() {
        node.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func connect(for format: AVAudioFormat) throws {
        if let f = connectedFormat, f.sampleRate == format.sampleRate, f.channelCount == format.channelCount { return }
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        node.stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        connectedFormat = format
        engine.prepare()
        try engine.start()
    }

    /// The chunk as a non-interleaved Float32 buffer at its own rate, the one format a player
    /// node takes for sure.
    nonisolated static func standardBuffer(from chunk: AudioChunk) -> AVAudioPCMBuffer? {
        let frames = chunk.frameCount
        guard frames > 0, let format = AVAudioFormat(standardFormatWithSampleRate: chunk.sampleRate, channels: AVAudioChannelCount(chunk.channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let out = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = chunk.channels
        chunk.data.withUnsafeBytes { raw in
            if chunk.isFloat32 {
                let src = raw.bindMemory(to: Float.self)
                for f in 0..<frames { for c in 0..<channels { out[c][f] = src[f * channels + c] } }
            } else {
                let src = raw.bindMemory(to: Int16.self)
                for f in 0..<frames { for c in 0..<channels { out[c][f] = Float(src[f * channels + c]) / 32768 } }
            }
        }
        return buffer
    }
}
#endif
