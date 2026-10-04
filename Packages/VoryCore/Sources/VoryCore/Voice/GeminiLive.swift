import Foundation

// MARK: Gemini Live (ai.google.dev/gemini-api/docs/live-api)
//
// One WebSocket per conversation: `setup` first, then raw 16 kHz int16 PCM up as `realtimeInput`
// and the model's 24 kHz PCM down inside `serverContent.modelTurn`; `toolCall` / `toolResponse`
// for the one function the model may call; `sessionResumptionUpdate` hands out a handle that a
// new connection resumes from, and `goAway` says the current one is about to close. The person's
// key goes in the URL's `key` query item and nowhere else: never in a log, never in an error.

public enum GeminiLive {
    public static let defaultModel = "gemini-3.8-live"
    public static let host = "generativelanguage.googleapis.com"
    public static let inputRate = 16000.0
    public static let outputRate = 24000.0
    /// Audio goes up in pieces about this long.
    public static let sendChunkSeconds = 0.1

    /// The voices the Live models offer (the TTS catalogue), with Google's one-word character.
    public static let voices: [(name: String, character: String)] = [
        ("Puck", "Upbeat"), ("Charon", "Informative"), ("Kore", "Firm"), ("Fenrir", "Excitable"), ("Aoede", "Breezy"),
        ("Leda", "Youthful"), ("Orus", "Firm"), ("Zephyr", "Bright"), ("Callirrhoe", "Easy-going"), ("Autonoe", "Bright"),
        ("Enceladus", "Breathy"), ("Iapetus", "Clear"), ("Umbriel", "Easy-going"), ("Algieba", "Smooth"), ("Despina", "Smooth"),
        ("Erinome", "Clear"), ("Algenib", "Gravelly"), ("Rasalgethi", "Informative"), ("Laomedeia", "Upbeat"), ("Achernar", "Soft"),
        ("Alnilam", "Firm"), ("Schedar", "Even"), ("Gacrux", "Mature"), ("Pulcherrima", "Forward"), ("Achird", "Friendly"),
        ("Zubenelgenubi", "Casual"), ("Vindemiatrix", "Gentle"), ("Sadachbia", "Lively"), ("Sadaltager", "Knowledgeable"), ("Sulafat", "Warm"),
    ]
    public static let defaultVoice = "Kore"

    /// The WebSocket URL for a key. DEBUG builds may point it at a fake server.
    public static func endpoint(key: String) -> URL {
        if let override = overrideURL { return override }
        var c = URLComponents()
        c.scheme = "wss"; c.host = host
        c.path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        c.queryItems = [URLQueryItem(name: "key", value: key)]
        return c.url!
    }
    nonisolated(unsafe) public static var overrideURL: URL?

    /// Any `key=…` in a message (a URL quoted back by a transport error) is blanked.
    public static func redact(_ text: String) -> String {
        text.replacing(/key=[^&\s"']+/) { _ in "key=…" }
    }

    // MARK: What Google's errors mean

    /// Google answers with a paragraph of API prose; the person gets one plain sentence, with
    /// the retry time when there is one, and the prose behind Details.
    public enum Trouble {
        public struct Plain: Equatable, Sendable {
            public var headline: String
            /// Seconds to wait, rounded up, when Google said so.
            public var retryAfter: Int?
            public var raw: String
        }

        public static func plain(_ raw: String, what: String = "voice previews") -> Plain {
            let lower = raw.lowercased()
            let retry = raw.firstMatch(of: /retry in (\d+(?:\.\d+)?)\s*s/.ignoresCase()).flatMap { Double($0.1) }.map { Int($0.rounded(.up)) }
            if lower.contains("quota") || lower.contains("resource_exhausted") || lower.contains("429") || lower.contains("rate limit") {
                let wait = retry.map { " Try again in \($0) second\($0 == 1 ? "" : "s")." } ?? " Try again in a minute."
                return Plain(headline: "Google's free tier allows only a few \(what) a minute.\(wait)", retryAfter: retry, raw: raw)
            }
            if lower.contains("api key not valid") || lower.contains("api_key_invalid") || lower.contains("permission_denied") || lower.contains("401") || lower.contains("403") || lower.contains("unauthenticated") {
                return Plain(headline: "Google did not accept this key.", retryAfter: nil, raw: raw)
            }
            if lower.contains("offline") || lower.contains("network connection") || lower.contains("timed out") || lower.contains("could not connect") {
                return Plain(headline: "Google could not be reached. Check the connection.", retryAfter: nil, raw: raw)
            }
            if lower.contains("not found") || lower.contains("404") {
                return Plain(headline: "Google does not offer that model to this key.", retryAfter: nil, raw: raw)
            }
            return Plain(headline: "Google answered with an error.", retryAfter: nil, raw: raw)
        }
    }

    // MARK: The person's key

    public enum Key {
        static let account = "gemini.apiKey"
        /// Kept in the Keychain, synchronizable: iCloud Keychain carries it to the person's
        /// other devices like the gateways. Never leaves the device for anything but Google.
        public static var value: String? {
            get { Keychain.getSynced(account: account).flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            set {
                let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if v.isEmpty { Keychain.deleteSynced(account: account) } else { try? Keychain.setSynced(Data(v.utf8), account: account) }
            }
        }
        public static var isPresent: Bool { value != nil }
        public static let getURL = URL(string: "https://aistudio.google.com/apikey")!
        public static let termsURL = URL(string: "https://ai.google.dev/gemini-api/terms")!
        /// Google's free tier may use what is sent to improve its products; a paid key does not.
        public static let freeTierNote = "On Google's free tier, what you say may be used to improve Google's products; a paid key is not. See Google's terms."

        /// One cheap call: lists a model. OK, or Google's reason (the key never appears in it).
        public static func check(_ key: String, session: URLSession = HermesAPI.makeSession()) async -> Result<Void, CheckFailure> {
            var c = URLComponents(); c.scheme = "https"; c.host = host; c.path = "/v1beta/models"
            c.queryItems = [URLQueryItem(name: "pageSize", value: "1"), URLQueryItem(name: "key", value: key)]
            guard let url = c.url else { return .failure(.init(message: "Bad request")) }
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return .success(()) }
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                return .failure(.init(message: redact(detail ?? "Google answered \(status).")))
            } catch {
                return .failure(.init(message: redact(error.localizedDescription)))
            }
        }
        public struct CheckFailure: Error, Equatable, Sendable { public var message: String }

        /// The last four characters of the saved key, for "ends in ••3F7A".
        public static var suffix: String? { value.map { String($0.suffix(4)) } }

        /// Previews already fetched, on disk: a voice is heard once for free and replayed from
        /// here, so flicking through the voices does not spend the free tier's few calls.
        static var previewDirectory: URL {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            let d = base.appendingPathComponent("vory-voice-previews", isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        static func previewFile(voice: String, rate: Double) -> URL {
            previewDirectory.appendingPathComponent("\(voice.lowercased())-\(Int(rate)).pcm")
        }
        public static func cachedPreview(voice: String) -> AudioChunk? {
            for rate in [24000.0, 22050.0, 16000.0, 48000.0] {
                let url = previewFile(voice: voice, rate: rate)
                if let data = try? Data(contentsOf: url), !data.isEmpty { return AudioChunk(sampleRate: rate, channels: 1, isFloat32: false, data: data) }
            }
            return nil
        }
        public static func storePreview(_ chunk: AudioChunk, voice: String) {
            guard !chunk.isFloat32, chunk.channels == 1 else { return }
            try? chunk.data.write(to: previewFile(voice: voice, rate: chunk.sampleRate), options: .atomic)
        }

        /// A few words in a voice through the TTS model (one small call), as a chunk to play.
        public static func preview(voice: String, key: String, text: String = "Hi. This is how I sound.", session: URLSession = HermesAPI.makeSession()) async throws -> AudioChunk {
            var c = URLComponents(); c.scheme = "https"; c.host = host; c.path = "/v1beta/models/gemini-3.8-flash-tts:generateContent"
            c.queryItems = [URLQueryItem(name: "key", value: key)]
            guard let url = c.url else { throw Failure(message: "Bad request") }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: JSONValue = .object([
                "contents": .array([.object(["parts": .array([.object(["text": .string(text)])])])]),
                "generationConfig": .object([
                    "responseModalities": .array([.string("AUDIO")]),
                    "speechConfig": .object(["voiceConfig": .object(["prebuiltVoiceConfig": .object(["voiceName": .string(voice)])])]),
                ]),
            ])
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                throw Failure(message: redact(detail ?? "Google answered \(status)."))
            }
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard let inline = value["candidates"]?.arrayValue?.first?["content"]?["parts"]?.arrayValue?.first?["inlineData"],
                  let b64 = inline["data"]?.stringValue, let pcm = Data(base64Encoded: b64), !pcm.isEmpty else { throw Failure(message: "No audio came back.") }
            // "audio/L16;codec=pcm;rate=24000"
            let mime = inline["mimeType"]?.stringValue ?? ""
            let rate = mime.split(separator: ";").compactMap { $0.hasPrefix("rate=") ? Double($0.dropFirst(5)) : nil }.first ?? outputRate
            return AudioChunk(sampleRate: rate, channels: 1, isFloat32: false, data: pcm)
        }
    }

    // MARK: Framing

    /// The messages, both ways, as the Live API spells them.
    public enum Framing {
        public static func setup(model: String = defaultModel, voice: String, systemInstruction: String, resumptionHandle: String?) -> String {
            var setup: [String: JSONValue] = [
                "model": .string("models/" + model),
                "generationConfig": .object([
                    "responseModalities": .array([.string("AUDIO")]),
                    "speechConfig": .object(["voiceConfig": .object(["prebuiltVoiceConfig": .object(["voiceName": .string(voice)])])]),
                ]),
                "systemInstruction": .object(["parts": .array([.object(["text": .string(systemInstruction)])])]),
                "tools": .array([.object(["functionDeclarations": .array([askBotDeclaration])])]),
                "inputAudioTranscription": .object([:]),
                "outputAudioTranscription": .object([:]),
                "contextWindowCompression": .object(["slidingWindow": .object([:])]),
            ]
            var resumption: [String: JSONValue] = [:]
            if let h = resumptionHandle { resumption["handle"] = .string(h) }
            setup["sessionResumption"] = .object(resumption)
            return encode(["setup": .object(setup)])
        }

        /// The one tool: non-blocking, so the model can say it is checking and keep listening.
        static let askBotDeclaration: JSONValue = .object([
            "name": .string(LivePersona.toolName),
            "description": .string(LivePersona.toolDescription),
            "behavior": .string("NON_BLOCKING"),
            "parameters": .object([
                "type": .string("OBJECT"),
                "properties": .object([
                    "request": .object(["type": .string("STRING"), "description": .string("What the user wants, in their words, as one clear request.")]),
                    "context": .object(["type": .string("STRING"), "description": .string("What was said just before that the bot needs to understand the request, if anything.")]),
                ]),
                "required": .array([.string("request")]),
            ]),
        ])

        public static func realtimeAudio(_ pcm16k: Data) -> String {
            encode(["realtimeInput": .object(["audio": .object(["data": .string(pcm16k.base64EncodedString()), "mimeType": .string("audio/pcm;rate=16000")])])])
        }
        public static let audioStreamEnd = encode(["realtimeInput": .object(["audioStreamEnd": .bool(true)])])

        /// A line typed into the conversation (the person's side).
        public static func clientText(_ text: String) -> String {
            encode(["clientContent": .object(["turns": .array([.object(["role": .string("user"), "parts": .array([.object(["text": .string(text)])])])]), "turnComplete": .bool(true)])])
        }

        /// The bot's answer back to the model, to be said as soon as it is here.
        public static func toolResponse(id: String, name: String = LivePersona.toolName, result: String, scheduling: String = "INTERRUPT") -> String {
            encode(["toolResponse": .object(["functionResponses": .array([.object([
                "id": .string(id), "name": .string(name),
                "response": .object(["result": .string(result), "scheduling": .string(scheduling)]),
            ])])])])
        }

        static func encode(_ object: [String: JSONValue]) -> String {
            let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }

        /// One server frame as events (several when a frame carries audio and a transcript).
        public static func parse(_ text: String) -> [LiveEvent] {
            guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
            var out: [LiveEvent] = []
            if value["setupComplete"] != nil { out.append(.ready) }
            if let content = value["serverContent"] {
                if let parts = content["modelTurn"]?["parts"]?.arrayValue {
                    for part in parts {
                        guard let inline = part["inlineData"], let b64 = inline["data"]?.stringValue, let audio = Data(base64Encoded: b64), !audio.isEmpty else { continue }
                        let mime = inline["mimeType"]?.stringValue ?? "audio/pcm;rate=24000"
                        let rate = Double(mime.split(separator: "=").last.map(String.init) ?? "") ?? outputRate
                        out.append(.audio(AudioChunk(sampleRate: rate, channels: 1, isFloat32: false, data: audio)))
                    }
                }
                if let t = content["inputTranscription"]?["text"]?.stringValue, !t.isEmpty { out.append(.inputTranscript(t)) }
                if let t = content["outputTranscription"]?["text"]?.stringValue, !t.isEmpty { out.append(.outputTranscript(t)) }
                if content["interrupted"]?.boolValue == true { out.append(.interrupted) }
                if content["turnComplete"]?.boolValue == true { out.append(.turnComplete) }
            }
            if let calls = value["toolCall"]?["functionCalls"]?.arrayValue {
                for call in calls {
                    guard let id = call["id"]?.stringValue, let name = call["name"]?.stringValue else { continue }
                    out.append(.toolCall(id: id, name: name, args: call["args"]?.objectValue ?? [:]))
                }
            }
            if let ids = value["toolCallCancellation"]?["ids"]?.arrayValue {
                out.append(.toolCallsCancelled(ids.compactMap(\.stringValue)))
            }
            if let away = value["goAway"] {
                let left = away["timeLeft"]?.stringValue.flatMap { Double($0.replacingOccurrences(of: "s", with: "")) }
                out.append(.goAway(seconds: left))
            }
            if let update = value["sessionResumptionUpdate"] {
                out.append(.resumption(handle: update["newHandle"]?.stringValue, resumable: update["resumable"]?.boolValue ?? false))
            }
            return out
        }
    }

    // MARK: The socket

    @MainActor
    public final class WebSocketTransport: LiveTransport {
        private let url: URL
        private var task: URLSessionWebSocketTask?
        private var reader: Task<Void, Never>?
        public let incoming: AsyncThrowingStream<String, Error>
        private let continuation: AsyncThrowingStream<String, Error>.Continuation
        private static let session = HermesAPI.makeSession()

        public init(url: URL) {
            self.url = url
            var c: AsyncThrowingStream<String, Error>.Continuation!
            incoming = AsyncThrowingStream { c = $0 }
            continuation = c
        }

        public func connect() async throws {
            let t = Self.session.webSocketTask(with: url)
            t.maximumMessageSize = 8 * 1024 * 1024
            task = t
            t.resume()
            reader = Task { [weak self] in
                while !Task.isCancelled {
                    guard let task = self?.task else { return }
                    do {
                        let message = try await task.receive()
                        switch message {
                        case .string(let s): self?.continuation.yield(s)
                        case .data(let d): self?.continuation.yield(String(decoding: d, as: UTF8.self))
                        @unknown default: break
                        }
                    } catch {
                        self?.continuation.finish(throwing: Failure(message: redact(error.localizedDescription)))
                        return
                    }
                }
            }
        }

        public func send(_ text: String) async throws {
            guard let task else { throw Failure(message: "Not connected") }
            try await task.send(.string(text))
        }

        public func close() {
            reader?.cancel(); reader = nil
            task?.cancel(with: .normalClosure, reason: nil); task = nil
            continuation.finish()
        }
    }

    public struct Failure: LocalizedError, Equatable, Sendable {
        public var message: String
        public var errorDescription: String? { message }
    }

    // MARK: The conversation

    /// One live conversation: audio up, events down, the model's `ask_bot` calls bridged to the
    /// bot by `ask`, and the connection kept across the server's `goAway` with the resumption
    /// handle. Platform-free: the app feeds it 16 kHz PCM and plays what comes back.
    @MainActor
    public final class Session {
        public struct Config: Sendable {
            public var model = GeminiLive.defaultModel
            public var voice: String
            public var systemInstruction: String
            public var key: String
            public init(voice: String, systemInstruction: String, key: String) {
                self.voice = voice; self.systemInstruction = systemInstruction; self.key = key
            }
        }

        public var onEvent: (LiveEvent) -> Void = { _ in }
        /// The bridge: the model's request (and the context it gave) to the bot's spoken answer.
        public var ask: (String, String) async -> String = { _, _ in "" }
        public private(set) var isReady = false
        public private(set) var resumptionHandle: String?
        public private(set) var reconnects = 0
        public static let maxReconnects = 5

        private let config: Config
        private let makeTransport: @MainActor (URL) -> any LiveTransport
        private var transport: (any LiveTransport)?
        private var reading: Task<Void, Never>?
        private var toolTasks: [String: Task<Void, Never>] = [:]
        private var stopped = false
        /// Audio that arrived before the setup was acknowledged is dropped, not queued forever.
        private var pendingAudio = Data()

        public init(config: Config, makeTransport: @escaping @MainActor (URL) -> any LiveTransport = { WebSocketTransport(url: $0) }) {
            self.config = config
            self.makeTransport = makeTransport
        }

        public func start() async throws {
            stopped = false
            try await open()
        }

        private func open() async throws {
            isReady = false
            let t = makeTransport(GeminiLive.endpoint(key: config.key))
            transport = t
            try await t.connect()
            try await t.send(Framing.setup(model: config.model, voice: config.voice, systemInstruction: config.systemInstruction, resumptionHandle: resumptionHandle))
            reading?.cancel()
            reading = Task { [weak self] in
                do {
                    for try await frame in t.incoming {
                        guard let self, !Task.isCancelled else { return }
                        for event in Framing.parse(frame) { self.handle(event) }
                    }
                    // Only the connection still in use reports its end: one we retired is done with.
                    guard let self, !Task.isCancelled, (self.transport as AnyObject?) === (t as AnyObject) else { return }
                    self.connectionEnded(nil)
                } catch {
                    guard let self, !Task.isCancelled, (self.transport as AnyObject?) === (t as AnyObject) else { return }
                    self.connectionEnded(redact(error.localizedDescription))
                }
            }
        }

        private func handle(_ event: LiveEvent) {
            switch event {
            case .ready:
                isReady = true
                if !pendingAudio.isEmpty { let d = pendingAudio; pendingAudio = Data(); send(pcm16k: d) }
            case .resumption(let handle, let resumable):
                if resumable, let handle { resumptionHandle = handle }
            case .goAway:
                // The server closes soon: a fresh connection picks the conversation up.
                onEvent(event)
                Task { await self.reconnect() }
                return
            case .toolCall(let id, let name, let args):
                guard name == LivePersona.toolName else { respond(id: id, name: name, result: "Unknown tool.") ; return }
                let request = args["request"]?.stringValue ?? ""
                let context = args["context"]?.stringValue ?? ""
                toolTasks[id] = Task { [weak self] in
                    let result = await self?.ask(request, context) ?? ""
                    guard let self, !Task.isCancelled else { return }
                    self.toolTasks[id] = nil
                    self.respond(id: id, name: name, result: result.isEmpty ? "The bot gave no answer." : result)
                }
            case .toolCallsCancelled(let ids):
                for id in ids { toolTasks[id]?.cancel(); toolTasks[id] = nil }
            default:
                break
            }
            onEvent(event)
        }

        private func respond(id: String, name: String, result: String) {
            guard let transport else { return }
            Task { try? await transport.send(Framing.toolResponse(id: id, name: name, result: result)) }
        }

        /// Raw 16 kHz int16 mono PCM, in pieces of about 100 ms.
        public func send(pcm16k: Data) {
            guard !stopped, let transport else { return }
            guard isReady else { pendingAudio.append(pcm16k); if pendingAudio.count > 320_000 { pendingAudio.removeFirst(pendingAudio.count - 320_000) }; return }
            Task { try? await transport.send(Framing.realtimeAudio(pcm16k)) }
        }

        /// A line the person typed or the app wants said to the model (never an approval).
        public func send(text: String) {
            guard !stopped, isReady, let transport else { return }
            Task { try? await transport.send(Framing.clientText(text)) }
        }

        private func connectionEnded(_ error: String?) {
            guard !stopped else { return }
            isReady = false
            if resumptionHandle != nil, reconnects < Self.maxReconnects {
                Task { await self.reconnect(after: error == nil ? 0 : 1.5) }
            } else {
                onEvent(.closed(error))
            }
        }

        private func reconnect(after delay: TimeInterval = 0) async {
            guard !stopped else { return }
            reconnects += 1
            reading?.cancel(); reading = nil
            transport?.close(); transport = nil
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            do { try await open() } catch { onEvent(.closed(redact(error.localizedDescription))) }
        }

        public func stop() {
            stopped = true
            isReady = false
            reading?.cancel(); reading = nil
            for (_, t) in toolTasks { t.cancel() }
            toolTasks = [:]
            transport?.close(); transport = nil
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
