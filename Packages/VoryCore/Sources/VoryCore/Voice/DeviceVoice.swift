import Foundation
import AVFAudio
#if os(iOS) || os(macOS)
import Speech
#endif

// MARK: Apple's engines on this device
//
// Transcription with SpeechAnalyzer and SpeechTranscriber (iOS 26 / macOS 26), synthesis
// with AVSpeechSynthesizer rendered to buffers rather than played: the app that owns the
// audio engine plays them, so echo cancellation can cancel the bot's own voice.

/// A piece of audio to play: PCM samples with their format.
public struct AudioChunk: Sendable {
    public var sampleRate: Double
    public var channels: Int
    /// Float32 interleaved when true, int16 interleaved otherwise.
    public var isFloat32: Bool
    public var data: Data
    public init(sampleRate: Double, channels: Int, isFloat32: Bool, data: Data) {
        self.sampleRate = sampleRate; self.channels = channels; self.isFloat32 = isFloat32; self.data = data
    }

    public var frameCount: Int { data.count / (isFloat32 ? 4 : 2) / max(1, channels) }
    public var seconds: Double { Double(frameCount) / sampleRate }

    /// The chunk as a buffer in its own format, for a player node or a converter.
    public func pcmBuffer() -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: isFloat32 ? .pcmFormatFloat32 : .pcmFormatInt16, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { src in
            if let dst = buffer.audioBufferList.pointee.mBuffers.mData, let base = src.baseAddress {
                memcpy(dst, base, min(Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize), data.count))
            }
        }
        return buffer
    }

    /// A buffer the synthesizer or a file produced, as a chunk.
    public init?(buffer: AVAudioPCMBuffer) {
        let format = buffer.format
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        let channels = Int(format.channelCount)
        switch format.commonFormat {
        case .pcmFormatFloat32:
            var out = Data(count: frames * channels * 4)
            out.withUnsafeMutableBytes { dst in
                let d = dst.bindMemory(to: Float.self)
                if format.isInterleaved, let src = buffer.floatChannelData?[0] {
                    for i in 0..<(frames * channels) { d[i] = src[i] }
                } else if let chans = buffer.floatChannelData {
                    for f in 0..<frames { for c in 0..<channels { d[f * channels + c] = chans[c][f] } }
                }
            }
            self.init(sampleRate: format.sampleRate, channels: channels, isFloat32: true, data: out)
        case .pcmFormatInt16:
            var out = Data(count: frames * channels * 2)
            out.withUnsafeMutableBytes { dst in
                let d = dst.bindMemory(to: Int16.self)
                if format.isInterleaved, let src = buffer.int16ChannelData?[0] {
                    for i in 0..<(frames * channels) { d[i] = src[i] }
                } else if let chans = buffer.int16ChannelData {
                    for f in 0..<frames { for c in 0..<channels { d[f * channels + c] = chans[c][f] } }
                }
            }
            self.init(sampleRate: format.sampleRate, channels: channels, isFloat32: false, data: out)
        default:
            return nil
        }
    }
}

#if os(iOS) || os(macOS)
/// Speech to text on this device, from a recording.
public enum DeviceTranscriber {
    public enum Failure: LocalizedError {
        case unsupportedLocale(Locale)
        case assetsMissing
        public var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let l): return "On-device speech recognition does not support \(l.identifier) yet."
            case .assetsMissing: return "The on-device speech model is not installed yet. Try again in a moment, or use the gateway."
            }
        }
    }

    /// The locale the transcriber can serve for the person's, if any.
    public static func supportedLocale(for locale: Locale = .current) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// Transcribes a whole recording. Downloads the model the first time (Apple's assets).
    public static func transcribe(file url: URL, locale: Locale = .current) async throws -> String {
        guard let supported = await supportedLocale(for: locale) else { throw Failure.unsupportedLocale(locale) }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let collect = Task<String, Error> {
            var parts: [String] = []
            for try await result in transcriber.results { parts.append(String(result.text.characters)) }
            return parts.joined(separator: " ").replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collect.value
    }
}

#endif

/// Text to speech on this device, rendered to buffers.
public enum DeviceSpeaker {
    /// The voice to use: the chosen one when it is still installed, else the best for the language.
    public static func voice(identifier: String?, language: String = Locale.current.identifier) -> AVSpeechSynthesisVoice? {
        if let identifier, let v = AVSpeechSynthesisVoice(identifier: identifier) { return v }
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(code) }
        let ranked = candidates.sorted { a, b in
            func rank(_ v: AVSpeechSynthesisVoice) -> Int {
                if v.voiceTraits.contains(.isPersonalVoice) { return 0 }
                switch v.quality { case .premium: return 1; case .enhanced: return 2; default: return 3 }
            }
            return rank(a) < rank(b)
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Every voice for the person's language, best first, for the picker.
    public static func voices(language: String = Locale.current.identifier) -> [AVSpeechSynthesisVoice] {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(code) }.sorted { a, b in
            func rank(_ v: AVSpeechSynthesisVoice) -> Int {
                if v.voiceTraits.contains(.isPersonalVoice) { return 0 }
                switch v.quality { case .premium: return 1; case .enhanced: return 2; default: return 3 }
            }
            return (rank(a), a.name) < (rank(b), b.name)
        }
    }

    /// Renders one piece of text to audio chunks. The synthesizer is kept alive until it has
    /// called back with the last (empty) buffer.
    public static func render(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float = AVSpeechUtteranceDefaultSpeechRate) -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            let synthesizer = AVSpeechSynthesizer()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = rate
            let keepAlive = Holder(synthesizer)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    continuation.finish()
                    _ = keepAlive
                    return
                }
                if let chunk = AudioChunk(buffer: pcm) { continuation.yield(chunk) }
            }
            continuation.onTermination = { _ in (keepAlive.object as? AVSpeechSynthesizer)?.stopSpeaking(at: .immediate) }
        }
    }

    private final class Holder: @unchecked Sendable { let object: AnyObject; init(_ o: AnyObject) { object = o } }
}

/// A compressed recording (the gateway's m4a or mp3) as chunks, decoded here.
public enum AudioDecoding {
    public static func chunks(fromFileAt url: URL, framesPerChunk: AVAudioFrameCount = 8192) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        var out: [AudioChunk] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerChunk) else { break }
            try file.read(into: buffer, frameCount: framesPerChunk)
            if buffer.frameLength == 0 { break }
            if let chunk = AudioChunk(buffer: buffer) { out.append(chunk) }
        }
        return out
    }

    public static func chunks(from data: Data, mimeType: String?) throws -> [AudioChunk] {
        let ext: String
        switch (mimeType ?? "").split(separator: ";").first.map(String.init)?.lowercased() {
        case "audio/wav", "audio/wave", "audio/x-wav": ext = "wav"
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac": ext = "m4a"
        case "audio/ogg": ext = "ogg"
        case "audio/flac": ext = "flac"
        default: ext = "mp3"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speak-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try chunks(fromFileAt: url)
    }
}
