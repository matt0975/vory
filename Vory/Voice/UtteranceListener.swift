import AVFAudio
import Foundation
import os
import VoryCore
#if os(iOS) || os(macOS)
import Speech
#endif

/// Hears the person in the hands-free loop. The engine's input buffers come in on the audio
/// thread; the start of speech and the end of the turn come out on the main actor: Apple's
/// SpeechDetector says what is speech when it will run, a loudness gate otherwise, and the
/// end of a turn is a pause after speech as long as Settings › Voice says. Each utterance is
/// recorded (with a little lead-in from before the detector spoke up) to an m4a for the
/// transcriber.
@MainActor
@Observable
final class UtteranceListener {
    /// Called when the person starts talking / stops (with the recording, nil if it was dropped).
    var onSpeechStarted: () -> Void = {}
    var onSpeechEnded: (URL?) -> Void = { _ in }
    /// Loudness samples for the waveform, newest last.
    private(set) var levels: [Float] = []
    private(set) var hearing = false
    private(set) var isOpen = false
    /// Which detector is at work, for Settings and the log.
    private(set) var method = "loudness"
    var endOfTurnPause: TimeInterval = 1.0
    /// Speech shorter than this is noise.
    static let minimumSpeech: TimeInterval = 0.25
    static let maximumUtterance: TimeInterval = 90
    nonisolated static let waveformSamples = 48

    /// The words Apple's transcriber has heard since the mic opened or the last turn ended:
    /// the live caption, and the transcript itself when speech is handled on this device.
    private(set) var finalWords = ""
    private(set) var volatileWords = ""
    var liveText: String { (finalWords + " " + volatileWords).trimmingCharacters(in: .whitespaces) }

    private let pipe = InputPipe()
    private var tick: Timer?
    private var speechStartedAt: Date?
    private var lastSpeechAt: Date?
    private var captureURL: URL?
    #if os(iOS) || os(macOS)
    private var analyzer: SpeechAnalyzer?
    private var analyzerTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var wordsTask: Task<Void, Never>?
    #endif

    /// The audio thread's entry: every buffer the microphone (or a stand-in) delivers.
    nonisolated var ingest: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        let pipe = self.pipe
        return { buffer, _ in pipe.ingest(buffer) }
    }

    /// Opens the ears: from now on buffers count, and the detector runs.
    func start() {
        guard !isOpen else { return }
        isOpen = true
        hearing = false
        speechStartedAt = nil
        lastSpeechAt = nil
        finalWords = ""; volatileWords = ""
        pipe.reset()
        startDetector()
        tick = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// Closes them: a capture in progress is dropped.
    func stop() {
        guard isOpen else { return }
        isOpen = false
        tick?.invalidate(); tick = nil
        cancelCapture()
        hearing = false
        stopDetector()
    }

    /// Drops the recording in progress without reporting it, and the words heard with it.
    func cancelCapture() {
        if let url = pipe.stopCapture() { try? FileManager.default.removeItem(at: url) }
        captureURL = nil
        speechStartedAt = nil
        hearing = false
        finalWords = ""; volatileWords = ""
    }

    /// The words heard for the turn that just ended, and a clean slate for the next.
    func takeWords() -> String {
        defer { finalWords = ""; volatileWords = "" }
        return liveText
    }

    // MARK: The clock

    private func poll() {
        guard isOpen else { return }
        let now = Date()
        let snapshot = pipe.snapshot(detectorActive: detectorRunning)
        levels = snapshot.levels
        if snapshot.speechNow { lastSpeechAt = now }
        if !hearing {
            // Speech has to hold for a moment before it counts: a cough is not a turn.
            if snapshot.speechNow {
                if speechStartedAt == nil { speechStartedAt = now; beginCapture() }
                else if let s = speechStartedAt, now.timeIntervalSince(s) >= Self.minimumSpeech {
                    hearing = true
                    onSpeechStarted()
                }
            } else if speechStartedAt != nil, let last = lastSpeechAt, now.timeIntervalSince(last) > 0.3 {
                // Too short to be words: dropped, the lead-in kept rolling.
                cancelCapture()
            }
        } else if let last = lastSpeechAt, let started = speechStartedAt {
            let quiet = now.timeIntervalSince(last)
            if quiet >= endOfTurnPause || now.timeIntervalSince(started) >= Self.maximumUtterance {
                hearing = false
                speechStartedAt = nil
                let url = pipe.stopCapture()
                captureURL = nil
                onSpeechEnded(url)
            }
        }
    }

    private func beginCapture() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utterance-\(UUID().uuidString).m4a")
        captureURL = url
        pipe.startCapture(to: url)
    }

    // MARK: Apple's detector

    private var detectorRunning: Bool {
        #if os(iOS) || os(macOS)
        return analyzer != nil
        #else
        return false
        #endif
    }

    private func startDetector() {
        #if os(iOS) || os(macOS)
        let pipe = self.pipe
        analyzerTask = Task { @MainActor [weak self] in
            do {
                // The detector cannot run by itself (the framework traps on a detector-only
                // analyzer): it rides along with a transcriber, whose words make the live
                // caption and, when speech is handled here, the transcript without a second
                // pass over the recording. Until the detector has spoken (the assets may be
                // downloading) the loudness gate decides.
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { throw DeviceTranscriber.Failure.unsupportedLocale(.current) }
                let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber, detector]) { try await request.downloadAndInstall() }
                guard let self, self.isOpen, !Task.isCancelled else { return }
                let analyzer = SpeechAnalyzer(modules: [transcriber, detector])
                self.analyzer = analyzer
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber, detector])
                let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                pipe.setAnalyzer(format: format, continuation: continuation)
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: stream)
                self.method = "SpeechDetector"
                self.resultsTask = Task { @MainActor [weak self] in
                    do {
                        for try await result in detector.results { self?.pipe.noteDetector(speech: result.speechDetected) }
                    } catch {
                        self?.pipe.setAnalyzer(format: nil, continuation: nil)
                        self?.analyzer = nil
                        self?.method = "loudness"
                    }
                }
                self.wordsTask = Task { @MainActor [weak self] in
                    do {
                        for try await result in transcriber.results {
                            guard let self else { return }
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                            if result.isFinal {
                                if !text.isEmpty { self.finalWords += (self.finalWords.isEmpty ? "" : " ") + text }
                                self.volatileWords = ""
                            } else {
                                self.volatileWords = text
                            }
                        }
                    } catch {}
                }
            } catch {
                // No detector here (assets, locale, a simulator): the loudness gate carries on.
                pipe.setAnalyzer(format: nil, continuation: nil)
                self?.analyzer = nil
                self?.method = "loudness"
                Self.log.notice("SpeechDetector unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
    }

    private func stopDetector() {
        #if os(iOS) || os(macOS)
        pipe.setAnalyzer(format: nil, continuation: nil)
        analyzerTask?.cancel(); analyzerTask = nil
        resultsTask?.cancel(); resultsTask = nil
        wordsTask?.cancel(); wordsTask = nil
        if let a = analyzer { Task { try? await a.finalizeAndFinishThroughEndOfInput() } }
        analyzer = nil
        #endif
    }

    static let log = Logger(subsystem: "dev.vory", category: "voice")
}

/// What the audio thread touches, behind one lock: the loudness gate, the lead-in ring, the
/// recording, and the detector's input. The main actor reads a snapshot fifty times a second.
final class InputPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var levels: [Float] = []
    private var noiseFloor: Float = -60
    private var lastLoudAt: TimeInterval = 0
    private var detectorSpeechUntil: TimeInterval = 0
    private var detectorSeen = false
    private var ring: [AVAudioPCMBuffer] = []
    private var ringSeconds: Double = 0
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var analyzerFormat: AVAudioFormat?
    private var analyzerIn: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerConverter: AVAudioConverter?
    private var fileConverter: AVAudioConverter?
    static let leadIn: Double = 0.6

    struct Snapshot {
        var levels: [Float]
        var speechNow: Bool
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        levels = []; noiseFloor = -60; lastLoudAt = 0; detectorSpeechUntil = 0; detectorSeen = false
        ring = []; ringSeconds = 0
    }

    func snapshot(detectorActive: Bool) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSinceReferenceDate
        // The detector decides once it has spoken at all; until then (or without it) loudness does.
        let speech = detectorActive && detectorSeen ? now < detectorSpeechUntil : now - lastLoudAt < 0.2
        return Snapshot(levels: levels, speechNow: speech)
    }

    func noteDetector(speech: Bool) {
        lock.lock(); defer { lock.unlock() }
        detectorSeen = true
        if speech { detectorSpeechUntil = Date().timeIntervalSinceReferenceDate + 0.35 }
    }

    func setAnalyzer(format: AVAudioFormat?, continuation: AsyncStream<AnalyzerInput>.Continuation?) {
        lock.lock(); defer { lock.unlock() }
        analyzerIn?.finish()
        analyzerFormat = format
        analyzerIn = continuation
        analyzerConverter = nil
        if format == nil { detectorSeen = false }
    }

    func startCapture(to url: URL) {
        lock.lock(); defer { lock.unlock() }
        guard file == nil, let format = ring.last?.format else { fileURL = url; return }
        do {
            let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: format.sampleRate,
                                           AVNumberOfChannelsKey: Int(format.channelCount), AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
            let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            fileConverter = nil
            for b in ring { write(b, to: f) }
            file = f
            fileURL = url
        } catch {
            file = nil; fileURL = nil
        }
    }

    /// Writes a buffer in the file's own format: the engine's tap keeps one format, but a route
    /// change (or a stand-in input) can hand over another, and the file asserts on a mismatch.
    private func write(_ buffer: AVAudioPCMBuffer, to f: AVAudioFile) {
        if buffer.format == f.processingFormat { try? f.write(from: buffer); return }
        if let converted = convert(buffer, to: f.processingFormat, using: &fileConverter) { try? f.write(from: converted) }
    }

    /// Closes the recording and returns it, nil when none was open.
    func stopCapture() -> URL? {
        lock.lock(); defer { lock.unlock() }
        let url = file == nil ? nil : fileURL
        file = nil; fileURL = nil
        return url
    }

    /// Audio thread.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let db = Self.decibels(buffer)
        lock.lock()
        // Loudness: against a floor that follows the room slowly, and never counted below -45 dB.
        noiseFloor = min(db, noiseFloor + 0.02)
        if db > max(noiseFloor + 12, -45) { lastLoudAt = Date().timeIntervalSinceReferenceDate }
        levels.append(min(1, max(0, (db + 50) / 50)))
        if levels.count > UtteranceListener.waveformSamples { levels.removeFirst(levels.count - UtteranceListener.waveformSamples) }
        if let f = file {
            write(buffer, to: f)
        } else if let copy = Self.copy(buffer) {
            ring.append(copy)
            ringSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            while ringSeconds > Self.leadIn, let first = ring.first {
                ringSeconds -= Double(first.frameLength) / first.format.sampleRate
                ring.removeFirst()
            }
        }
        if let format = analyzerFormat, let input = analyzerIn {
            if let converted = convert(buffer, to: format, using: &analyzerConverter) { input.yield(AnalyzerInput(buffer: converted)) }
        }
        lock.unlock()
    }

    /// The buffer in another format (a copy when it is already there), through a converter kept
    /// for as long as the formats hold.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, using cache: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        if buffer.format == format { return Self.copy(buffer) }
        if cache == nil || cache?.inputFormat != buffer.format || cache?.outputFormat != format { cache = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter = cache else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else { return nil }
        var handed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if handed { status.pointee = .noDataNow; return nil }
            handed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let src = buffer.audioBufferList
        let dst = out.mutableAudioBufferList
        for i in 0..<Int(src.pointee.mNumberBuffers) {
            let s = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: src))[i]
            let d = UnsafeMutableAudioBufferListPointer(dst)[i]
            if let sd = s.mData, let dd = d.mData { memcpy(dd, sd, Int(min(s.mDataByteSize, d.mDataByteSize))) }
        }
        return out
    }

    /// The buffer's loudness in dBFS (average power).
    static func decibels(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -160 }
        var sum: Float = 0
        if let data = buffer.floatChannelData {
            let ch = data[0]
            for i in 0..<frames { sum += ch[i] * ch[i] }
        } else if let data = buffer.int16ChannelData {
            let ch = data[0]
            for i in 0..<frames { let v = Float(ch[i]) / 32768; sum += v * v }
        } else { return -160 }
        let rms = (sum / Float(frames)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }
}
