import AVFAudio
import os
import VoryCore

/// Plays the voice engine's audio chunks through an AVAudioEngine of its own (the Mac's output
/// follows the system's chosen device; the phone also takes the audio session):
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
    /// A `play` is in progress (it may be winding down after `stop`); the next waits its turn.
    private var busy = false
    /// Scheduled and not yet heard, oldest first: what a restarted engine plays again.
    private var queued: [AudioChunk] = []
    /// Bumped whenever the schedule is thrown away (stop, a restart), so the callbacks of the
    /// old buffers, which arrive after, are not taken for the new ones.
    private var generation = 0
    private var ended = false
    private var finish: CheckedContinuation<Void, Never>?
    /// The first chunk of a `play` logs the session it plays through (see `sessionLine`).
    private var loggedFirstAudio = false
    private static let log = Logger(subsystem: "dev.vory", category: "audio")
    /// Hands-free holds the session and the engine open for the whole conversation; `play`
    /// then neither takes nor drops them.
    private(set) var handsFree = false
    private var inputTapInstalled = false
    private var configObserver: Any?
    private var routeObserver: Any?

    init() { engine.attach(node) }

    /// Plays every chunk of the stream in order and returns once the last one has sounded
    /// (or the stream failed, or `stop()` was called).
    func play(_ chunks: AsyncThrowingStream<AudioChunk, Error>) async throws {
        // One at a time: a second play while the first still drained threw its queue away and
        // took over its finish (Live's next turn could start over the end of the last).
        while busy { try await Task.sleep(for: .milliseconds(20)) }
        busy = true
        defer { busy = false }
        if !handsFree { try beginSession() }
        isPlaying = true
        queued = []; ended = false; loggedFirstAudio = false
        defer { isPlaying = false; if !handsFree { endSession() } }
        // One chunk is held back so the last one is known when the stream ends: it goes out
        // with a short fade, and the output never stops on a mid-wave sample (a loud crackle
        // at the end of every voice test, as a tester heard).
        var held: AudioChunk?
        do {
            for try await chunk in chunks {
                guard isPlaying else { break }
                if let h = held { try schedule(h) }
                held = chunk
            }
        } catch {
            stop()
            throw error
        }
        if let h = held, isPlaying { try schedule(h.fadedOut(seconds: 0.02)) }
        ended = true
        if !queued.isEmpty, isPlaying {
            await withCheckedContinuation { c in finish = c }
        }
        // The last callback comes as the data reaches the output; a beat before the engine
        // stops lets the hardware finish it. On Bluetooth the output runs well behind, so the
        // beat is its latency: stopping at 80 ms cut a headset's stream mid-sound.
        if isPlaying, !handsFree {
            let settle = min(0.6, max(0.08, engine.outputNode.presentationLatency + 0.05))
            try? await Task.sleep(for: .seconds(settle))
        }
    }

    private func schedule(_ chunk: AudioChunk) throws {
        guard let buffer = Self.standardBuffer(from: chunk) else { return }
        try connect(for: buffer.format)
        if !loggedFirstAudio {
            loggedFirstAudio = true
            let line = Self.sessionLine()
            Self.log.notice("first audio out (\(self.handsFree ? "hands-free" : "speak", privacy: .public), \(Int(chunk.sampleRate)) Hz): \(line, privacy: .public)")
            // Settings › Voice shows the last one, so a tester can read it off the phone.
            if handsFree { UserDefaults.standard.set("\(Int(chunk.sampleRate)) Hz, " + line, forKey: VoiceSettings.lastSessionKey) }
        }
        queued.append(chunk)
        let g = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in self?.played(generation: g) }
        }
        if !node.isPlaying { node.play() }
    }

    private func played(generation g: Int) {
        guard g == generation else { return }
        if !queued.isEmpty { queued.removeFirst() }
        if ended, queued.isEmpty, let c = finish { finish = nil; c.resume() }
    }

    /// Cuts playback short.
    func stop() {
        guard isPlaying || node.isPlaying else { return }
        isPlaying = false
        generation += 1
        queued = []
        node.stop()
        if let c = finish { finish = nil; c.resume() }
    }

    private func beginSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        Self.log.notice("speak session: \(Self.sessionLine(), privacy: .public)")
        #endif
        // The engine starts in `connect(for:)`, once the player node is wired to the mixer:
        // starting it with no connections raises (not throws) inside AVAudioEngine.
    }

    /// The session as it is, for the log: a tester's voice mode made no sound with the iPhone's
    /// switch on silent, and the category, the route and the volume are what decide that.
    nonisolated static func sessionLine() -> String {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        let outs = s.currentRoute.outputs.map { $0.portType.rawValue + "(" + $0.portName + ")" }.joined(separator: "+")
        return "category \(s.category.rawValue), mode \(s.mode.rawValue), options \(s.categoryOptions.rawValue), route \(outs.isEmpty ? "none" : outs), volume \(String(format: "%.2f", s.outputVolume)), other audio \(s.isOtherAudioPlaying)"
        #else
        return "macOS"
        #endif
    }

    #if os(iOS)
    /// Something the person wears or sits in: the sound belongs there, not on the speaker.
    private static func routeHasHeadsetOrCar(_ s: AVAudioSession) -> Bool {
        let worn: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones, .carAudio, .airPlay, .usbAudio, .HDMI, .lineOut]
        return s.currentRoute.outputs.contains { worn.contains($0.portType) }
    }
    #endif

    private func endSession() {
        node.stop()
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func connect(for format: AVAudioFormat) throws {
        if let f = connectedFormat, f.sampleRate == format.sampleRate, f.channelCount == format.channelCount {
            if !engine.isRunning { engine.prepare(); try engine.start() }
            return
        }
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        node.stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        connectedFormat = format
        engine.prepare()
        try engine.start()
    }

    // MARK: Hands-free: the microphone on the same engine

    /// The input node's format while hands-free is on (what the tap delivers).
    var inputFormat: AVAudioFormat? { handsFree ? engine.inputNode.outputFormat(forBus: 0) : nil }

    /// Opens the microphone on this engine with voice processing (so the bot's own voice,
    /// played through the same engine, is cancelled out of what the mic hears) and keeps the
    /// session open: play and record at once, the speaker by default, Bluetooth headsets and
    /// car kits allowed. `onInput` is called on the audio thread with each buffer the mic
    /// delivers; with `tap` false the engine opens but no buffers are read (a stand-in input).
    func beginHandsFree(tap: Bool = true, onInput: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        if handsFree { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
        try session.setActive(true)
        // The speaker, not the earpiece, unless something is worn or plugged in: `defaultToSpeaker`
        // asks for it, the override insists (an earpiece at arm's length sounds like silence).
        if !Self.routeHasHeadsetOrCar(session) { try? session.overrideOutputAudioPort(.speaker) }
        let line = Self.sessionLine()
        Self.log.notice("hands-free session: \(line, privacy: .public)")
        // Settings › Voice shows it from the start, before (or without) any audio out.
        UserDefaults.standard.set("start, " + line, forKey: VoiceSettings.lastSessionKey)
        #endif
        if engine.isRunning { engine.stop() }
        node.stop()
        handsFree = true
        let input = engine.inputNode
        if tap {
            // Echo cancellation is best effort: a simulator or an odd route may refuse it, and
            // the loop then runs without barge-in protection rather than not at all.
            if !input.isVoiceProcessingEnabled { try? input.setVoiceProcessingEnabled(true) }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                handsFree = false
                throw HermesAPIError.transport("No microphone input is available.")
            }
            // `@Sendable`: a plain closure made here would be main-actor isolated (and trap on the
            // audio thread); the tap must run wherever Core Audio calls it.
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, time in onInput(buffer, time) }
            inputTapInstalled = true
        }
        // The player's path exists before the engine starts (starting with no connections raises).
        if connectedFormat == nil, let f = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1) {
            engine.connect(node, to: engine.mainMixerNode, format: f)
            connectedFormat = f
        }
        engine.prepare()
        try engine.start()
        #if os(iOS)
        // Voice processing re-routes as the engine starts: the speaker is asked for again after,
        // and again on every route change while the session runs.
        if !Self.routeHasHeadsetOrCar(session) { try? session.overrideOutputAudioPort(.speaker) }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.handsFree else { return }
                let s = AVAudioSession.sharedInstance()
                if !Self.routeHasHeadsetOrCar(s) { try? s.overrideOutputAudioPort(.speaker) }
                Self.log.notice("route changed: \(Self.sessionLine(), privacy: .public)")
            }
        }
        #endif
        // A route change (headphones in, a car kit) resets the engine: it is started again.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartAfterChange() }
        }
    }

    /// After an interruption or a route change: the engine runs again, and what was scheduled
    /// and not yet heard is scheduled again. A stopped engine drops its player's buffers and
    /// their callbacks never come; without this a reply cut by a headset connecting left the
    /// loop on "Speaking" for good.
    func restartAfterChange() {
        guard handsFree, !engine.isRunning else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)
        if !Self.routeHasHeadsetOrCar(session) { try? session.overrideOutputAudioPort(.speaker) }
        Self.log.notice("hands-free session restarted: \(Self.sessionLine(), privacy: .public)")
        #endif
        engine.prepare()
        try? engine.start()
        guard isPlaying, !queued.isEmpty else { return }
        let again = queued
        generation += 1
        queued = []
        node.stop()
        for chunk in again { try? schedule(chunk) }
        if queued.isEmpty, ended, let c = finish { finish = nil; c.resume() }
    }

    func endHandsFree() {
        guard handsFree else { return }
        stop()
        handsFree = false
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        if let o = routeObserver { NotificationCenter.default.removeObserver(o); routeObserver = nil }
        if inputTapInstalled { engine.inputNode.removeTap(onBus: 0); inputTapInstalled = false }
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
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
