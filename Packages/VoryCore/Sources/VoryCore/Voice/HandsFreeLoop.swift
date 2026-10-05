import Foundation

// MARK: The hands-free turn loop
//
// Listen → the person stops talking → words → sent → the bot thinks → its reply is spoken as
// it streams → listen again. The loop here is the rules only: what happened comes in as an
// event, what to do next goes out as effects, and the platform (the phone's audio session and
// engine, the Mac's) carries them out. Approvals are never taken by voice: a card turns the
// loop to "needs approval", says so once, and waits for the screen.

public enum HandsFreePhase: String, Sendable, Equatable {
    /// The microphone is open, waiting for the person (or hearing them).
    case listening
    /// The person stopped; the recording is being turned into words.
    case transcribing
    /// The prompt is with the bot; nothing to say yet.
    case thinking
    /// The bot's reply is playing.
    case speaking
    /// A card waits on the screen; the loop waits with it.
    case needsApproval
    /// Stopped by the person or an interruption, ready to resume.
    case paused
    case ended
}

public enum HandsFreeEvent: Equatable, Sendable {
    case start
    /// The detector heard the person begin / stop (after the end-of-turn pause).
    case speechStarted, speechEnded
    /// The recording became words; empty when nothing was heard.
    case transcript(String)
    case transcriptFailed(String)
    case sent
    case sendFailed(String)
    case replyDelta(String)
    /// The reply is complete; its text, for a reply that came whole without deltas.
    case replyCompleted(String)
    case turnEnded(error: String?)
    case cardArrived(summary: String)
    case cardsCleared
    /// The reply's audio began / ended (ended also when it had nothing to say).
    case audioStarted, audioFinished
    case audioFailed(String)
    /// The person spoke over the bot.
    case bargeIn
    case mute, unmute, pause, resume, end
    case interruptionBegan
    case interruptionEnded(resume: Bool)
}

public enum HandsFreeEffect: Equatable, Sendable {
    case openMic, closeMic
    /// Start recording the utterance / stop and transcribe it / drop it.
    case captureStart, captureStop, captureCancel
    case send(String)
    /// The reply's speech: opened on the first delta, fed each one, closed when the reply is complete.
    case beginReplySpeech, feedReply(String), finishReplySpeech
    /// A reply that arrived whole (no deltas) is spoken in one go.
    case speakWhole(String)
    /// A line of the loop's own, spoken after whatever is playing.
    case announce(String)
    case stopSpeaking
}

/// The recent spoken exchange, newest last, as the gateway's `voice_context` wants it: what the
/// person said and what the bot said back, so a "yes" or a "the other one" is understood.
public struct SpokenExchange: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public var isPerson: Bool
        public var text: String
    }
    public private(set) var lines: [Line] = []
    /// Only the last few turns travel; older ones are in the chat anyway.
    public static let keep = 8

    public init() {}

    public mutating func said(_ text: String) { add(Line(isPerson: true, text: text)) }
    public mutating func heard(_ text: String) { add(Line(isPerson: false, text: text)) }

    private mutating func add(_ line: Line) {
        let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lines.append(Line(isPerson: line.isPerson, text: t))
        if lines.count > Self.keep { lines.removeFirst(lines.count - Self.keep) }
    }

    /// "User: …\nAssistant: …", within the gateway's limit (the oldest lines go first).
    public var context: String {
        var out = lines.map { ($0.isPerson ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n")
        while out.count > VoiceTurn.contextLimit, let cut = out.firstIndex(of: "\n") { out = String(out[out.index(after: cut)...]) }
        return out.count > VoiceTurn.contextLimit ? String(out.suffix(VoiceTurn.contextLimit)) : out
    }
}

/// One thing said in voice mode, for the screen: the person's words or the bot's, growing while
/// it is still being heard or said.
public struct VoiceLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var isPerson: Bool
    public var text: String
    /// Still growing: the person's words as they are heard, the reply as it streams.
    public var isFinal: Bool
    public init(id: UUID = UUID(), isPerson: Bool, text: String, isFinal: Bool = true) {
        self.id = id; self.isPerson = isPerson; self.text = text; self.isFinal = isFinal
    }
}

/// Everything said this session, both ways, oldest first, for the screen to scroll: the whole
/// of each reply, never a tail of it. A line is written by its id as it grows and closed when
/// its turn is over; a line closed with nothing in it goes.
public struct VoiceTranscript: Equatable, Sendable {
    public private(set) var lines: [VoiceLine] = []
    /// Older lines than this are dropped; the chat has them all.
    public static let keep = 80

    public init() {}

    /// Writes the line with this id (wherever it is) or adds it at the end.
    public mutating func write(_ id: UUID, isPerson: Bool, text: String, final: Bool = false) {
        if let i = lines.firstIndex(where: { $0.id == id }) {
            lines[i].text = text
            lines[i].isFinal = final
        } else {
            lines.append(VoiceLine(id: id, isPerson: isPerson, text: text, isFinal: final))
            if lines.count > Self.keep { lines.removeFirst(lines.count - Self.keep) }
        }
        if final { prune(id) }
    }

    /// Closes the line: it will not grow any more; empty, it is removed.
    public mutating func finish(_ id: UUID) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[i].isFinal = true
        prune(id)
    }

    /// Closes every open line.
    public mutating func finishAll() {
        for line in lines where !line.isFinal { finish(line.id) }
    }

    public var last: VoiceLine? { lines.last }

    private mutating func prune(_ id: UUID) {
        if let i = lines.firstIndex(where: { $0.id == id }), lines[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.remove(at: i) }
    }
}

public struct HandsFreeState: Equatable, Sendable {
    public var phase: HandsFreePhase = .listening
    public var isMuted = false
    /// Speech is being heard right now.
    public var hearing = false
    /// A recording of the person is open.
    public var capturing = false
    /// The bot's turn is still running on the gateway.
    public var turnRunning = false
    /// A reply's speech was started and has not finished playing.
    public var replyPending = false
    /// This turn's reply (so far) is being fed to speech; later deltas join it.
    public var replySpoken = false
    public var cardsPending = false
    public enum PauseCause: Sendable, Equatable { case person, interruption }
    public var pausedBy: PauseCause?
    /// The last words heard, or the line for the person: an error, "Nothing heard".
    public var caption: String?
    public var note: String?
    /// How many prompts the loop has sent.
    public var sent = 0

    public init() {}

    public static let approvalLine = "Approval needed: %@. Approve on screen."

    /// Applies one event and returns what to do about it.
    public mutating func handle(_ event: HandsFreeEvent) -> [HandsFreeEffect] {
        if phase == .ended { return [] }
        switch event {
        case .start:
            phase = cardsPending ? .needsApproval : (turnRunning ? .thinking : .listening)
            return isMuted ? [] : [.openMic]

        case .speechStarted:
            guard phase == .listening, !isMuted else { return [] }
            hearing = true
            note = nil
            if capturing { return [] }
            capturing = true
            return [.captureStart]

        case .speechEnded:
            guard phase == .listening, capturing else { hearing = false; return [] }
            hearing = false
            capturing = false
            phase = .transcribing
            return [.captureStop]

        case .transcript(let text):
            guard phase == .transcribing else { return [] }
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if words.isEmpty { phase = .listening; note = "Nothing heard"; return [] }
            caption = words
            phase = .thinking
            sent += 1
            return [.send(words)]

        case .transcriptFailed(let error):
            guard phase == .transcribing else { return [] }
            phase = .listening
            note = error
            return []

        case .sent:
            if phase == .thinking { turnRunning = true; replySpoken = false }
            return []

        case .sendFailed(let error):
            guard phase == .thinking else { return [] }
            phase = cardsPending ? .needsApproval : .listening
            note = error
            return []

        case .replyDelta(let delta):
            guard phase == .thinking || phase == .speaking || phase == .needsApproval else { return [] }
            var effects: [HandsFreeEffect] = []
            if !replySpoken { replySpoken = true; replyPending = true; effects.append(.beginReplySpeech) }
            effects.append(.feedReply(delta))
            return effects

        case .replyCompleted(let text):
            guard phase == .thinking || phase == .speaking || phase == .needsApproval else { return [] }
            if replySpoken { return [.finishReplySpeech] }
            replySpoken = true
            replyPending = true
            return [.speakWhole(text)]

        case .turnEnded(let error):
            turnRunning = false
            replySpoken = false
            if let error, !error.isEmpty { note = error }
            if phase == .thinking, !replyPending { phase = cardsPending ? .needsApproval : .listening }
            return []

        case .cardArrived(let summary):
            cardsPending = true
            guard phase == .thinking || phase == .speaking || phase == .listening else { return [] }
            phase = .needsApproval
            hearing = false
            var effects: [HandsFreeEffect] = [.announce(String(format: Self.approvalLine, summary))]
            if capturing { capturing = false; effects.insert(.captureCancel, at: 0) }
            return effects

        case .cardsCleared:
            cardsPending = false
            guard phase == .needsApproval else { return [] }
            phase = replyPending ? .speaking : (turnRunning ? .thinking : .listening)
            return []

        case .audioStarted:
            if phase == .thinking { phase = .speaking }
            return []

        case .audioFinished, .audioFailed:
            if case .audioFailed(let error) = event { note = error }
            replyPending = false
            if phase == .speaking || phase == .thinking { phase = cardsPending ? .needsApproval : (turnRunning ? .thinking : .listening) }
            return []

        case .bargeIn:
            guard phase == .speaking, !isMuted else { return [] }
            phase = .listening
            hearing = true
            capturing = true
            replyPending = false
            return [.stopSpeaking, .captureStart]

        case .mute:
            guard !isMuted else { return [] }
            isMuted = true
            hearing = false
            var effects: [HandsFreeEffect] = [.closeMic]
            if capturing { capturing = false; effects.insert(.captureCancel, at: 0) }
            if phase == .transcribing { phase = .listening }
            return effects

        case .unmute:
            guard isMuted else { return [] }
            isMuted = false
            return phase == .paused ? [] : [.openMic]

        case .pause, .interruptionBegan:
            guard phase != .paused else { return [] }
            pausedBy = event == .pause ? .person : .interruption
            phase = .paused
            hearing = false
            replyPending = false
            var effects: [HandsFreeEffect] = [.stopSpeaking, .closeMic]
            if capturing { capturing = false; effects.insert(.captureCancel, at: 0) }
            return effects

        case .resume:
            guard phase == .paused else { return [] }
            pausedBy = nil
            phase = cardsPending ? .needsApproval : (turnRunning ? .thinking : .listening)
            return isMuted ? [] : [.openMic]

        case .interruptionEnded(let resume):
            guard phase == .paused, pausedBy == .interruption else { return [] }
            if resume { return handle(.resume) }
            note = "Audio was interrupted. Tap Resume to continue."
            return []

        case .end:
            phase = .ended
            hearing = false
            replyPending = false
            var effects: [HandsFreeEffect] = [.stopSpeaking, .closeMic]
            if capturing { capturing = false; effects.insert(.captureCancel, at: 0) }
            return effects
        }
    }

    /// Whether the thinking cue (a soft tick now and then) applies: the bot is at work and
    /// nothing is being said.
    public var wantsThinkingCue: Bool { phase == .thinking && !replyPending }

    /// The line under the bot.
    public var title: String {
        switch phase {
        case .listening: return isMuted ? "Muted" : (hearing ? "Listening" : "Listening…")
        case .transcribing: return "Got it…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        case .needsApproval: return "Approval needed"
        case .paused: return "Paused"
        case .ended: return "Ended"
        }
    }
}
