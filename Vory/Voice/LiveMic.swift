import AVFAudio
import Foundation
import VoryCore

/// The microphone for Live mode: the engine's input buffers (on the audio thread) become 16 kHz
/// int16 mono PCM in pieces of about 100 ms for the live model, plus loudness samples for the
/// waveform. Muted, it keeps the waveform and sends nothing.
final class LiveMic: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var levelsStorage: [Float] = []
    private var mutedStorage = false
    /// Called on the audio thread with each piece; dispatch before touching the main actor.
    var onChunk: @Sendable (Data) -> Void = { _ in }
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: GeminiLive.inputRate, channels: 1, interleaved: true)!
    static let chunkBytes = Int(GeminiLive.inputRate * GeminiLive.sendChunkSeconds) * 2

    var levels: [Float] { lock.lock(); defer { lock.unlock() }; return levelsStorage }
    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return mutedStorage }
        set { lock.lock(); mutedStorage = newValue; if newValue { pending = Data() }; lock.unlock() }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending = Data(); levelsStorage = []; converter = nil
    }

    /// The audio thread's entry.
    nonisolated var ingest: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { [self] buffer, _ in self.take(buffer) }
    }

    private func take(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let db = InputPipe.decibels(buffer)
        lock.lock()
        levelsStorage.append(min(1, max(0, (db + 50) / 50)))
        if levelsStorage.count > UtteranceListener.waveformSamples { levelsStorage.removeFirst(levelsStorage.count - UtteranceListener.waveformSamples) }
        if mutedStorage { lock.unlock(); return }
        if let out = convert(buffer) {
            out.withUnsafeBytes { pending.append(contentsOf: $0) }
        }
        var ready: [Data] = []
        while pending.count >= Self.chunkBytes {
            ready.append(pending.prefix(Self.chunkBytes))
            pending.removeFirst(Self.chunkBytes)
        }
        lock.unlock()
        for piece in ready { onChunk(piece) }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let format = Self.format
        let out: AVAudioPCMBuffer
        if buffer.format == format {
            out = buffer
        } else {
            if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
            guard let converter else { return nil }
            let ratio = format.sampleRate / buffer.format.sampleRate
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else { return nil }
            var handed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if handed { status.pointee = .noDataNow; return nil }
                handed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, converted.frameLength > 0 else { return nil }
            out = converted
        }
        guard let base = out.int16ChannelData?[0] else { return nil }
        return Data(bytes: base, count: Int(out.frameLength) * 2)
    }
}
