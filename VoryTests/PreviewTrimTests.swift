import Foundation
import Testing
@testable import VoryCore

/// Gemini's voice previews can end in static after the words, which played at full level (the
/// 20 ms end fade only softened its last 20 ms). The clip is cut after the last spoken words.
@Suite struct PreviewTrimTests {
    static let rate = 24_000.0

    /// A voiced sound: 150 Hz with two harmonics, about -12 dBFS.
    static func voiced(_ seconds: Double) -> [Int16] {
        (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            let x = 0.18 * sin(2 * .pi * 150 * t) + 0.08 * sin(2 * .pi * 300 * t) + 0.04 * sin(2 * .pi * 450 * t)
            return Int16(x * 32767)
        }
    }
    static func silence(_ seconds: Double) -> [Int16] { Array(repeating: 0, count: Int(seconds * rate)) }
    /// Loud white noise, the static (deterministic).
    static func noise(_ seconds: Double) -> [Int16] {
        var x: UInt64 = 0x2545F4914F6CDD1D
        return (0..<Int(seconds * rate)).map { _ in
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            return Int16(truncatingIfNeeded: Int(x >> 48) - 32768) / 2
        }
    }
    static func chunk(_ parts: [[Int16]]) -> AudioChunk {
        let samples = parts.flatMap { $0 }
        return AudioChunk(sampleRate: rate, channels: 1, isFloat32: false, data: samples.withUnsafeBufferPointer { Data(buffer: $0) })
    }
    static func samples(_ c: AudioChunk) -> [Int16] { c.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } }

    @Test func theStaticAfterTheWordsIsCutAndThePauseBetweenThemKept() {
        let words = 0.3 + 0.25 + 1.2
        let clip = Self.chunk([Self.voiced(0.3), Self.silence(0.25), Self.voiced(1.2), Self.silence(0.15), Self.noise(0.5)])
        let trimmed = clip.trimmedTail()
        // The words and the pause between them stay; it ends a short beat after the last word.
        #expect(trimmed.seconds > words + 0.04)
        #expect(trimmed.seconds < words + 0.12)
        // No noise left: the tail after the words is the faded ending, nothing loud.
        let tail = Self.samples(trimmed).suffix(Int(0.05 * Self.rate))
        #expect(tail.map { abs(Int($0)) }.max()! < 9000)
        #expect(abs(Int(Self.samples(trimmed).last!)) <= 21)
        // Twice is the same as once.
        #expect(trimmed.trimmedTail().data == trimmed.data)
    }

    @Test func aCleanClipKeepsItsWordsAndLosesOnlyTheSilenceAfter() {
        let clip = Self.chunk([Self.voiced(0.4), Self.silence(0.2), Self.voiced(0.8), Self.silence(0.5)])
        let trimmed = clip.trimmedTail()
        #expect(trimmed.seconds > 1.4 + 0.04)
        #expect(trimmed.seconds < 1.4 + 0.12)
        // A clip that ends on its words is left as it is.
        let tight = Self.chunk([Self.voiced(0.6)])
        #expect(tight.trimmedTail().data == tight.data)
    }

    @Test func otherFormatsAndTinyClipsAreLeftAlone() {
        let float = AudioChunk(sampleRate: Self.rate, channels: 1, isFloat32: true, data: Data(count: 48_000))
        #expect(float.trimmedTail().data == float.data)
        let stereo = AudioChunk(sampleRate: Self.rate, channels: 2, isFloat32: false, data: Data(count: 48_000))
        #expect(stereo.trimmedTail().data == stereo.data)
        let tiny = Self.chunk([Self.noise(0.05)])
        #expect(tiny.trimmedTail().data == tiny.data)
        let silent = Self.chunk([Self.silence(1)])
        #expect(silent.trimmedTail().data == silent.data)
    }

    @Test func aFetchedPreviewArrivesTrimmed() async throws {
        let clip = Self.chunk([Self.voiced(0.3), Self.silence(0.25), Self.voiced(1.2), Self.noise(0.6)])
        let body: [String: Any] = ["candidates": [["content": ["parts": [["inlineData": ["mimeType": "audio/L16;codec=pcm;rate=24000", "data": clip.data.base64EncodedString()]]]]]]]
        PreviewStub.body = try JSONSerialization.data(withJSONObject: body)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [PreviewStub.self]
        let chunk = try await GeminiLive.Key.preview(voice: "Kore", key: "test-key", session: URLSession(configuration: cfg))
        #expect(chunk.sampleRate == 24_000)
        #expect(chunk.seconds < 1.75 + 0.12)
        #expect(chunk.seconds > 1.75 + 0.04)
    }
}

/// Answers the preview request with a canned generateContent response, offline.
final class PreviewStub: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
