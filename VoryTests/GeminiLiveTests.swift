import Foundation
import Testing
@testable import VoryCore

/// The Live API's frames, both ways.
@Suite struct GeminiLiveFramingTests {
    private func json(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    @Test func theSetupNamesTheModelVoiceToolAndTranscriptsAndCarriesAHandle() {
        let s = json(GeminiLive.Framing.setup(voice: "Kore", systemInstruction: "Be brief.", resumptionHandle: "h-1"))["setup"]!
        #expect(s["model"]?.stringValue == "models/gemini-3.8-live")
        #expect(s["generationConfig"]?["responseModalities"]?.arrayValue?.first?.stringValue == "AUDIO")
        #expect(s["generationConfig"]?["speechConfig"]?["voiceConfig"]?["prebuiltVoiceConfig"]?["voiceName"]?.stringValue == "Kore")
        #expect(s["systemInstruction"]?["parts"]?.arrayValue?.first?["text"]?.stringValue == "Be brief.")
        let tool = s["tools"]?.arrayValue?.first?["functionDeclarations"]?.arrayValue?.first
        #expect(tool?["name"]?.stringValue == "ask_bot" && tool?["behavior"]?.stringValue == "NON_BLOCKING")
        #expect(tool?["parameters"]?["required"]?.arrayValue?.first?.stringValue == "request")
        #expect(s["inputAudioTranscription"] != nil && s["outputAudioTranscription"] != nil)
        #expect(s["sessionResumption"]?["handle"]?.stringValue == "h-1")
        #expect(s["contextWindowCompression"]?["slidingWindow"] != nil)
        let fresh = json(GeminiLive.Framing.setup(voice: "Puck", systemInstruction: "x", resumptionHandle: nil))["setup"]!
        #expect(fresh["sessionResumption"]?["handle"] == nil && fresh["sessionResumption"] != nil)
    }

    @Test func audioTextAndToolResponsesAreTheApisShape() {
        let pcm = Data([1, 0, 2, 0])
        let a = json(GeminiLive.Framing.realtimeAudio(pcm))["realtimeInput"]!["audio"]!
        #expect(a["mimeType"]?.stringValue == "audio/pcm;rate=16000" && a["data"]?.stringValue == pcm.base64EncodedString())
        #expect(json(GeminiLive.Framing.audioStreamEnd)["realtimeInput"]?["audioStreamEnd"]?.boolValue == true)
        let t = json(GeminiLive.Framing.clientText("hello"))["clientContent"]!
        #expect(t["turnComplete"]?.boolValue == true && t["turns"]?.arrayValue?.first?["parts"]?.arrayValue?.first?["text"]?.stringValue == "hello")
        let r = json(GeminiLive.Framing.toolResponse(id: "c1", result: "4.2 GB"))["toolResponse"]!["functionResponses"]!.arrayValue!.first!
        #expect(r["id"]?.stringValue == "c1" && r["name"]?.stringValue == "ask_bot")
        #expect(r["response"]?["result"]?.stringValue == "4.2 GB" && r["response"]?["scheduling"]?.stringValue == "INTERRUPT")
    }

    @Test func serverFramesBecomeEvents() {
        #expect(GeminiLive.Framing.parse(#"{"setupComplete": {}}"#) == [.ready])
        let pcm = Data([0, 1, 0, 2, 0, 3, 0, 4])
        let audio = GeminiLive.Framing.parse(#"{"serverContent": {"modelTurn": {"parts": [{"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": "\#(pcm.base64EncodedString())"}}]}, "outputTranscription": {"text": "Hi."}}}"#)
        #expect(audio == [.audio(AudioChunk(sampleRate: 24000, channels: 1, isFloat32: false, data: pcm)), .outputTranscript("Hi.")])
        #expect(GeminiLive.Framing.parse(#"{"serverContent": {"interrupted": true}}"#) == [.interrupted])
        #expect(GeminiLive.Framing.parse(#"{"serverContent": {"turnComplete": true, "inputTranscription": {"text": "what"}}}"#) == [.inputTranscript("what"), .turnComplete])
        #expect(GeminiLive.Framing.parse(#"{"toolCall": {"functionCalls": [{"id": "c1", "name": "ask_bot", "args": {"request": "disk?", "context": ""}}]}}"#)
                == [.toolCall(id: "c1", name: "ask_bot", args: ["request": .string("disk?"), "context": .string("")])])
        #expect(GeminiLive.Framing.parse(#"{"toolCallCancellation": {"ids": ["c1", "c2"]}}"#) == [.toolCallsCancelled(["c1", "c2"])])
        #expect(GeminiLive.Framing.parse(#"{"goAway": {"timeLeft": "30s"}}"#) == [.goAway(seconds: 30)])
        #expect(GeminiLive.Framing.parse(#"{"sessionResumptionUpdate": {"newHandle": "h2", "resumable": true}}"#) == [.resumption(handle: "h2", resumable: true)])
        #expect(GeminiLive.Framing.parse("not json").isEmpty && GeminiLive.Framing.parse(#"{"usageMetadata": {}}"#).isEmpty)
    }

    @Test func theKeyNeverShowsInAMessageAndTheEndpointCarriesIt() {
        #expect(GeminiLive.redact("Could not connect to wss://x/y?key=AIzaSyAbc123&x=1: refused") == "Could not connect to wss://x/y?key=…&x=1: refused")
        #expect(GeminiLive.redact("at ?key=abc\" more") == "at ?key=…\" more")
        let url = GeminiLive.endpoint(key: "k")
        #expect(url.host == GeminiLive.host && url.query == "key=k" && url.path.hasSuffix("BidiGenerateContent"))
        #expect(GeminiLive.voices.count == 30 && GeminiLive.voices.contains { $0.name == GeminiLive.defaultVoice })
    }
}

/// A transport that is two arrays: what the session sent, and what the test pushes back.
@MainActor
final class FakeLiveTransport: LiveTransport {
    var sent: [String] = []
    var connected = 0
    var closed = 0
    let incoming: AsyncThrowingStream<String, Error>
    private let push: AsyncThrowingStream<String, Error>.Continuation
    init() {
        var c: AsyncThrowingStream<String, Error>.Continuation!
        incoming = AsyncThrowingStream { c = $0 }
        push = c
    }
    func connect() async throws { connected += 1 }
    func send(_ text: String) async throws { sent.append(text) }
    func close() { closed += 1; push.finish() }
    func server(_ json: String) { push.yield(json) }
    func fail(_ message: String) { push.finish(throwing: GeminiLive.Failure(message: message)) }
    func sentObjects() -> [JSONValue] { sent.compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } }
}

/// The conversation: setup, audio, the tool bridge, resumption.
@MainActor
@Suite struct GeminiLiveSessionTests {
    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    @Test func setupGoesFirstAudioWaitsForReadyAndTheToolIsBridgedToTheBot() async throws {
        let transport = FakeLiveTransport()
        var events: [LiveEvent] = []
        let session = GeminiLive.Session(config: .init(voice: "Kore", systemInstruction: "Be brief.", key: "k"), makeTransport: { _ in transport })
        session.onEvent = { events.append($0) }
        var asked: [(String, String)] = []
        session.ask = { request, context in asked.append((request, context)); return "Rotated logs, 4.2 GB." }
        try await session.start()
        #expect(transport.connected == 1)
        #expect(transport.sentObjects().first?["setup"]?["model"]?.stringValue == "models/gemini-3.8-live")
        // Audio before the server is ready is held, then sent once it is.
        session.send(pcm16k: Data([1, 0]))
        await settle()
        #expect(transport.sent.count == 1)
        transport.server(#"{"setupComplete": {}}"#)
        await settle()
        #expect(session.isReady && events.first == .ready)
        #expect(transport.sentObjects().last?["realtimeInput"]?["audio"]?["data"]?.stringValue == Data([1, 0]).base64EncodedString())
        session.send(pcm16k: Data([2, 0]))
        await settle()
        #expect(transport.sent.count == 3)

        transport.server(#"{"toolCall": {"functionCalls": [{"id": "c1", "name": "ask_bot", "args": {"request": "disk?", "context": "earlier"}}]}}"#)
        await settle()
        #expect(asked.count == 1 && asked[0].0 == "disk?" && asked[0].1 == "earlier")
        let response = transport.sentObjects().last?["toolResponse"]?["functionResponses"]?.arrayValue?.first
        #expect(response?["id"]?.stringValue == "c1" && response?["response"]?["result"]?.stringValue == "Rotated logs, 4.2 GB.")
        #expect(events.contains(.toolCall(id: "c1", name: "ask_bot", args: ["request": .string("disk?"), "context": .string("earlier")])))

        transport.server(#"{"serverContent": {"interrupted": true}}"#)
        await settle()
        #expect(events.last == .interrupted)
        session.stop()
        #expect(transport.closed == 1)
    }

    @Test func aHandleIsKeptAndGoAwayReconnectsWithIt() async throws {
        var transports: [FakeLiveTransport] = []
        let session = GeminiLive.Session(config: .init(voice: "Kore", systemInstruction: "x", key: "k"), makeTransport: { _ in
            let t = FakeLiveTransport(); transports.append(t); return t
        })
        var events: [LiveEvent] = []
        session.onEvent = { events.append($0) }
        try await session.start()
        transports[0].server(#"{"setupComplete": {}}"#)
        transports[0].server(#"{"sessionResumptionUpdate": {"newHandle": "h-9", "resumable": true}}"#)
        await settle()
        #expect(session.resumptionHandle == "h-9")
        transports[0].server(#"{"goAway": {"timeLeft": "5s"}}"#)
        await settle()
        #expect(transports.count == 2 && transports[0].closed == 1 && session.reconnects == 1)
        #expect(transports[1].sentObjects().first?["setup"]?["sessionResumption"]?["handle"]?.stringValue == "h-9")
        #expect(!session.isReady)
        transports[1].server(#"{"setupComplete": {}}"#)
        await settle()
        #expect(session.isReady && events.contains(.goAway(seconds: 5)))
        // A dropped connection with a handle comes back too; without one it is reported.
        transports[1].fail("socket closed")
        await settle()
        try? await Task.sleep(for: .seconds(1.7))
        await settle()
        #expect(transports.count == 3 && session.reconnects == 2)
        session.stop()

        let lone = FakeLiveTransport()
        let plain = GeminiLive.Session(config: .init(voice: "Kore", systemInstruction: "x", key: "k"), makeTransport: { _ in lone })
        var closed: LiveEvent?
        plain.onEvent = { if case .closed = $0 { closed = $0 } }
        try await plain.start()
        lone.fail("gone key=secret")
        await settle()
        #expect(closed == .closed("gone key=…"))
    }
}
