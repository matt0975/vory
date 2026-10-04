import Foundation

// MARK: Live conversation mode
//
// A full-duplex voice model owns the microphone and the speaker: natural turn-taking, instant
// interruption, lifelike voices. It delegates every real request to the bot through one
// function tool, so the person's chosen model, tools and memory still do the work and the
// transcript stays the chat's. Two providers, both the person's own: Gemini with their key
// (over the Live API's WebSocket, see GeminiLive.swift) and OpenAI through their gateway
// (GPT-Live, WebRTC; later). Vory never pays for or proxies anyone's voice.

/// Settings › Voice › Conversation.
public enum ConversationMode: String, CaseIterable, Sendable, Identifiable {
    /// Live when the chosen provider is ready, otherwise Standard.
    case automatic
    case live
    /// The chained loop: listen, transcribe, send, speak the reply.
    case standard

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .live: return "Live"
        case .standard: return "Standard"
        }
    }
}

/// Settings › Voice › Live provider.
public enum LiveProvider: String, CaseIterable, Sendable, Identifiable {
    /// The person's own Gemini key, kept in their Keychain.
    case gemini
    /// GPT-Live through the person's gateway, which holds the OpenAI key.
    case openai

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .gemini: return "Gemini (your key)"
        case .openai: return "OpenAI (your gateway)"
        }
    }
}

/// What a live voice model tells the app, provider-neutral.
public enum LiveEvent: Equatable, Sendable {
    /// The session is set up; audio may flow.
    case ready
    /// A piece of the model's voice to play.
    case audio(AudioChunk)
    /// The person spoke over the model: stop playing what is queued.
    case interrupted
    /// The model's turn is over (it stopped talking and listens).
    case turnComplete
    /// Words heard from the person / said by the model (as the provider transcribes them).
    case inputTranscript(String)
    case outputTranscript(String)
    /// The model wants the bot's help: `ask_bot(request, context)`.
    case toolCall(id: String, name: String, args: [String: JSONValue])
    case toolCallsCancelled([String])
    /// The server will close the connection in this many seconds; reconnect with the handle.
    case goAway(seconds: Double?)
    /// A handle to resume this conversation on a new connection.
    case resumption(handle: String?, resumable: Bool)
    /// The connection ended (nil: cleanly).
    case closed(String?)
}

extension AudioChunk: Equatable {
    public static func == (a: AudioChunk, b: AudioChunk) -> Bool {
        a.sampleRate == b.sampleRate && a.channels == b.channels && a.isFloat32 == b.isFloat32 && a.data == b.data
    }
}

/// One connection to a live voice provider: text frames both ways. The WebSocket one is in
/// GeminiLive.swift; tests use one that is a pair of arrays.
@MainActor
public protocol LiveTransport: AnyObject {
    func connect() async throws
    func send(_ text: String) async throws
    /// Frames from the server, until it closes (nil) or fails (throws).
    var incoming: AsyncThrowingStream<String, Error> { get }
    func close()
}

/// The persona and delegation policy for a live voice model, modelled on the gateway's own
/// (tools/voice_live.py LIVE_PERSONA): speak naturally, delegate real work, never guess a
/// result, say that you are checking. Approvals are not its business: it has no tool for them.
public enum LivePersona {
    public static func instruction(botName: String) -> String {
        """
        You are \(botName)'s voice. Speak naturally at an unhurried pace. Be clear and direct, not overly cheerful. \
        If the user is frustrated, acknowledge it briefly and focus on the next helpful step. \
        Use moderate backchannels; acknowledge without competing with the main response. \
        Stop speaking when the user interrupts, and listen.

        Delegation policy. You have one tool, ask_bot: it reaches \(botName), a full AI agent with tools that can run commands, \
        read and edit files, browse the web, search, remember things across sessions, schedule tasks and reason carefully. \
        It is the one who does work and knows facts. Call ask_bot when the user asks a question that needs facts, current \
        information or careful reasoning; when the user asks you to do, check, find, make, fix, run or remember anything; \
        and when a correction changes work already requested. Do not call it for greetings, small talk, or to repeat a \
        result already given, and ask a brief clarifying question first when you need one. Call ask_bot before giving any \
        answer that depends on its work; never guess the result while waiting. Say briefly that you are checking, then \
        wait for the result and say it in a few plain sentences. If the result says an approval is needed, tell the user \
        to approve it on the screen and wait; you cannot approve anything yourself.
        """
    }

    public static let toolName = "ask_bot"
    public static let toolDescription = "Hand a request to the bot (a full agent with tools and memory) and get its answer. Use it for anything that needs facts, work or memory."
}
