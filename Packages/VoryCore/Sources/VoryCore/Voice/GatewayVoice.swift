import Foundation

// MARK: The gateway's voice routes (hermes_cli/web_routers/audio.py)
//
// POST /api/audio/transcribe {data_url, mime_type?} → {ok, transcript, provider}
// POST /api/audio/speak {text} → {ok, data_url, mime_type, provider}
// POST /api/audio/tts-lease {lease, active} → warms or releases the TTS provider
// WS /api/audio/speak-stream: text deltas in, raw int16 PCM out (see SpeakStreamFrame).
// GET /api/audio/voice-config is never called: it hands the provider keys to the client.

public struct GatewayVoiceAPI: Sendable {
    let api: HermesAPI
    public var profile: String?

    public init(api: HermesAPI, profile: String? = nil) { self.api = api; self.profile = profile }

    public struct Transcription: Decodable, Sendable, Equatable {
        public var ok: Bool?
        public var transcript: String
        public var provider: String?
        /// The gateway heard nothing it would call speech.
        public var isEmpty: Bool { transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public struct Speech: Decodable, Sendable {
        public var ok: Bool?
        public var dataUrl: String
        public var mimeType: String?
        public var provider: String?
        /// The audio bytes out of the data URL.
        public var audio: Data? { Self.decode(dataURL: dataUrl) }
        public static func decode(dataURL: String) -> Data? {
            guard let comma = dataURL.firstIndex(of: ","), dataURL.hasPrefix("data:"), dataURL[..<comma].contains(";base64") else { return nil }
            return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        }
    }

    public static func dataURL(_ data: Data, mimeType: String) -> String { "data:\(mimeType);base64," + data.base64EncodedString() }

    public func transcribe(_ data: Data, mimeType: String = "audio/m4a") async throws -> Transcription {
        try await api.send("POST", "/api/audio/transcribe", profile: profile,
                           json: .object(["data_url": .string(Self.dataURL(data, mimeType: mimeType)), "mime_type": .string(mimeType)]))
    }

    public func speak(_ text: String) async throws -> Speech {
        try await api.send("POST", "/api/audio/speak", profile: profile, json: .object(["text": .string(text)]))
    }

    /// Warms (true) or releases (false) the gateway's TTS provider; failures are its own business.
    public func lease(_ active: Bool, name: String = "vory") async {
        let _: JSONValue? = try? await api.send("POST", "/api/audio/tts-lease", profile: profile, json: .object(["lease": .string(name), "active": .bool(active)]))
    }
}

/// One message from the speak-stream socket.
public enum SpeakStreamFrame: Equatable, Sendable {
    /// Sent once, with the first audio, when the provider's rate is final.
    case start(sampleRate: Int, channels: Int)
    /// Raw int16 PCM, mono unless `start` said otherwise.
    case pcm(Data)
    case end
    /// Sentence synthesis made no audio: speak another way.
    case fallback

    public static func parse(text: String) -> SpeakStreamFrame? {
        guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "start": return .start(sampleRate: (obj["sample_rate"] as? Int) ?? 24000, channels: (obj["channels"] as? Int) ?? 1)
        case "end": return .end
        case "fallback": return .fallback
        default: return nil
        }
    }

    public static func parse(data: Data) -> SpeakStreamFrame { .pcm(data) }

    /// What the client sends.
    public static func clientText(_ delta: String) -> String { #"{"text": \#(Self.jsonString(delta))}"# }
    public static let clientDone = #"{"done": true}"#
    public static let clientStop = #"{"stop": true}"#

    static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let arr = String(decoding: data, as: UTF8.self)
        return String(arr.dropFirst().dropLast())
    }
}

/// A speech session on the gateway: text goes in as it streams from the model, int16 PCM comes
/// back sentence by sentence as the provider finishes each. `stop()` is the barge-in: the
/// server stops synthesizing and the socket closes.
@MainActor
public final class SpeakStreamClient {
    public private(set) var frames: AsyncStream<SpeakStreamFrame>
    private var continuation: AsyncStream<SpeakStreamFrame>.Continuation?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private static let session = HermesAPI.makeSession()
    public private(set) var isOpen = false

    public init() {
        var c: AsyncStream<SpeakStreamFrame>.Continuation?
        frames = AsyncStream { c = $0 }
        continuation = c
    }

    /// Opens the socket, credentialled like the gateway's others.
    func open(runtime: GatewayRuntime, profile: String?) async throws {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let (url, headers) = try await runtime.pluginWebsocketURL(path: "/api/audio/speak-stream", query: query)
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let task = Self.session.webSocketTask(with: request)
        socket = task
        task.resume()
        isOpen = true
        reader = Task { [weak self] in
            while !Task.isCancelled {
                guard let task = self?.socket else { return }
                do {
                    let message = try await task.receive()
                    let frame: SpeakStreamFrame?
                    switch message {
                    case .data(let d): frame = .pcm(d)
                    case .string(let s): frame = SpeakStreamFrame.parse(text: s)
                    @unknown default: frame = nil
                    }
                    if let frame { self?.continuation?.yield(frame) }
                    if frame == .end || frame == .fallback { self?.finishStream(); return }
                } catch {
                    self?.finishStream()
                    return
                }
            }
        }
    }

    public func send(delta: String) {
        guard !delta.isEmpty, let socket else { return }
        socket.send(.string(SpeakStreamFrame.clientText(delta))) { _ in }
    }

    /// The reply is complete: the server speaks what is left and sends `end`.
    public func finish() {
        socket?.send(.string(SpeakStreamFrame.clientDone)) { _ in }
    }

    /// Barge-in: stop synthesizing now.
    public func stop() {
        socket?.send(.string(SpeakStreamFrame.clientStop)) { _ in }
        finishStream()
    }

    private func finishStream() {
        isOpen = false
        reader?.cancel(); reader = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        continuation?.finish(); continuation = nil
    }
}
