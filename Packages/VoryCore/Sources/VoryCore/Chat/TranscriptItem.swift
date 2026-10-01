import Foundation

public struct ToolActivity: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable { case running, done, failed }
    public var id: String
    public var name: String
    public var context: String?
    public var argsText: String?
    public var status: Status = .running
    public var summary: String?
    public var resultText: String?
    public var durationSeconds: Double?
    public var risk: String?
    /// Set when this call carried a message to another bot: the row reads "Messaged X" instead
    /// of a terminal transcript.
    public var delivery: BotDelivery?

    public var displayName: String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    /// The other bot's answer, when the quiet run brought one back: the result without its
    /// session bookkeeping lines, unwrapped from a JSON {"output": …} if the terminal wrapped it,
    /// and without a "Message from X:" prefix the recipient may have echoed.
    public var deliveryReply: String? {
        guard delivery != nil, var raw = resultText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("{"), let data = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let out = obj["output"] as? String { raw = out }
        let body = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("session_id:") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return nil }
        return AgentMessage.parse(body)?.body ?? body
    }

    public init(id: String, name: String, context: String? = nil, argsText: String? = nil, status: Status = .running, summary: String? = nil, resultText: String? = nil, durationSeconds: Double? = nil, risk: String? = nil) {
        self.id = id
        self.name = name
        self.context = context
        self.argsText = argsText
        self.status = status
        self.summary = summary
        self.resultText = resultText
        self.durationSeconds = durationSeconds
        self.risk = risk
        self.delivery = BotDelivery.parse(name: name, context: context, argsText: argsText)
    }
}

/// A message one bot sent another. The Bot Mode convention is a quiet run of the other bot:
/// `hermes -p <bot> chat … -q "Message from 🤖 <sender>: …"` through the terminal tool; newer
/// gateways have a `message_agent` tool with a target. Either way the user-facing truth is
/// "Messaged X", not a shell transcript.
public struct BotDelivery: Hashable, Sendable {
    public var target: String
    public var message: String?

    public init(target: String, message: String? = nil) { self.target = target; self.message = message }

    public static func parse(name: String, context: String?, argsText: String?) -> BotDelivery? {
        // The preview the gateway sends is cut short; the full command is in the args.
        var command = context ?? ""
        if let a = argsText, let m = a.firstMatch(of: /"command"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            command = String(m.1).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
        }
        // The Bot Mode DM runner wraps the CLI: `python bot_mode_dm.py --run-delivery [--author …]
        // <mode> <file> [--profile-home …] hermes -p <bot> chat …`, or `… hermes -p <me> peer dm
        // <peer>/<bot>`. The peer form carries the sender's own -p, so it is read first.
        if let m = command.firstMatch(of: /\bpeer\s+dm\s+("?)([A-Za-z0-9][A-Za-z0-9_\/.-]{0,80})\1/) {
            return BotDelivery(target: Self.key(String(m.2)), message: nil)
        }
        if command.contains("--run-delivery"),
           let m = command.firstMatch(of: /(?:^|[\s;&|])-p[\s=]+("?)([a-z0-9][a-z0-9_-]{0,63})\1(?=\s|$)/.ignoresCase()) {
            return BotDelivery(target: String(m.2).lowercased(), message: nil)
        }
        // A quiet run of another bot's CLI is the delivery, however the binary is spelled before
        // it (hermes, $HERMES_BIN, an env assignment, a path) and however the words travel:
        // `-q "…"` inline, `-Q --query-file <tmp>` from a file (the Bot Mode DM transport the
        // bot falls back to outside its Bot Chat), or `-c "Bot Chat"` into the other bot's
        // thread. A peer DM, `hermes peer dm <peer>/<bot>`, is one too.
        let quiet = command.firstMatch(of: /(?:^|\s)(?:-q|-Q|--quiet|--query-file)(?:\s|=|$)/) != nil
        let botChat = command.firstMatch(of: /-c\s+["']?Bot Chat/.ignoresCase()) != nil
        if quiet || botChat || command.contains("Message from"),
           command.firstMatch(of: /\bchat\b/) != nil,
           let m = command.firstMatch(of: /(?:^|[\s;&|])(?:-p|--profile)[\s=]+("?)([a-z0-9][a-z0-9_-]{0,63})\1(?=\s|$)/.ignoresCase()) {
            return BotDelivery(target: String(m.2).lowercased(), message: Self.quoted(after: "-q", in: command))
        }
        if name == "message_agent" || name == "send_message_to_agent" {
            let args = argsText ?? ""
            if let t = args.firstMatch(of: /"target"\s*:\s*"([^"]+)"/) { return BotDelivery(target: Self.key(String(t.1)), message: args.firstMatch(of: /"message"\s*:\s*"((?:[^"\\]|\\.)*)"/).map { String($0.1) }) }
            if let c = context, !c.isEmpty { return BotDelivery(target: Self.key(c)) }
        }
        return nil
    }

    /// `@Dr. Foo`, `scribe@laptop`, `peer/scribe` → `dr. foo` / `scribe`: the routing alias.
    public static func key(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("@") { v.removeFirst() }
        if let at = v.lastIndex(of: "@") { v = String(v[..<at]) }
        return (v.split(separator: "/").last.map(String.init) ?? v).lowercased()
    }

    private static func quoted(after flag: String, in command: String) -> String? {
        guard let r = command.range(of: flag + " ") else { return nil }
        let rest = command[r.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let q = rest.first, q == "\"" || q == "'" else { return nil }
        let body = rest.dropFirst()
        guard let end = body.firstIndex(of: q) else { return String(body) }
        let text = String(body[..<end])
        return AgentMessage.parse(text)?.body ?? text
    }
}

/// An inbound row from another bot: "Message from 🤖 Sender (@handle): body" or
/// "[Message from agent 'Sender'] body".
public struct AgentMessage: Hashable, Sendable {
    public var sender: String
    public var handle: String?
    public var body: String

    public static func parse(_ text: String) -> AgentMessage? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = t.firstMatch(of: /^Message from (?:🤖\s*)?([^:\n(]{1,64}?)(?:\s*\(@([a-z0-9][a-z0-9_-]{0,63})(?:@[a-zA-Z0-9][a-zA-Z0-9_-]{0,63})?\))?:\s*([\s\S]*)$/) {
            return AgentMessage(sender: String(m.1).trimmingCharacters(in: .whitespaces), handle: m.2.map(String.init), body: String(m.3))
        }
        if let m = t.firstMatch(of: /^\[Message from agent '([^']{1,64})'\]\s*([\s\S]*)$/) {
            return AgentMessage(sender: String(m.1), handle: nil, body: String(m.2))
        }
        return nil
    }

    /// The routing alias for the sender, the way a delivery target is written.
    public var key: String { BotDelivery.key(handle ?? sender) }
}

public struct AttachmentPreview: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var serverPath: String?
    public var kind: Kind
    public var localURL: URL?
    public var byteCount: Int?
    public enum Kind: String, Hashable, Sendable { case image, pdf, audio, video, file }

    public init(id: String, name: String, serverPath: String? = nil, kind: Kind, localURL: URL? = nil, byteCount: Int? = nil) {
        self.id = id
        self.name = name
        self.serverPath = serverPath
        self.kind = kind
        self.localURL = localURL
        self.byteCount = byteCount
    }
}

/// One row of the conversation transcript.
public struct TranscriptItem: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case user(text: String, attachments: [AttachmentPreview])
        case assistant(text: String, reasoning: String?, streaming: Bool)
        case tool(ToolActivity)
        case system(text: String, symbol: String)
        case error(text: String)
        case subagent(goal: String, status: String)
        /// A message steered into a running turn (queued or delivered), shown as the user's own
        /// bubble but grey.
        case steer(text: String, status: String)
    }
    public var id: String
    public var kind: Kind
    public var timestamp: Date = Date()
    public var rowID: Int?
    /// Filled in on `message.complete` for the trailing assistant bubble of a turn.
    public var stats: TurnStats?

    public static func fromHistory(_ m: TranscriptMessage, index: Int) -> TranscriptItem? {
        let id = "h-\(m.rowId ?? index)-\(index)"
        let ts = m.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
        if m.displayKind == "hidden" { return nil }
        switch m.role {
        case "user":
            return TranscriptItem(id: id, kind: .user(text: m.text ?? "", attachments: []), timestamp: ts, rowID: m.rowId)
        case "assistant":
            guard let t = m.text, !t.isEmpty else { return nil }
            return TranscriptItem(id: id, kind: .assistant(text: t, reasoning: m.reasoning, streaming: false), timestamp: ts, rowID: m.rowId)
        case "tool", "tool_call":
            var act = ToolActivity(id: id, name: m.name ?? "tool", context: m.context, status: .done)
            act.resultText = m.text
            return TranscriptItem(id: id, kind: .tool(act), timestamp: ts, rowID: m.rowId)
        case "system":
            guard let t = m.text, !t.isEmpty else { return nil }
            return TranscriptItem(id: id, kind: .system(text: t, symbol: "info.circle"), timestamp: ts, rowID: m.rowId)
        default:
            guard let t = m.text, !t.isEmpty else { return nil }
            return TranscriptItem(id: id, kind: .assistant(text: t, reasoning: nil, streaming: false), timestamp: ts, rowID: m.rowId)
        }
    }

    public init(id: String, kind: Kind, timestamp: Date = Date(), rowID: Int? = nil, stats: TurnStats? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.rowID = rowID
        self.stats = stats
    }
}

/// Accumulates `message.delta` chunks into the trailing assistant row.
public struct StreamAssembler: Sendable {
    public private(set) var text = ""
    public private(set) var reasoning = ""
    public private(set) var deltaCount = 0
    public private(set) var isStreaming = false

    public mutating func start() { text = ""; reasoning = ""; deltaCount = 0; isStreaming = true }
    public mutating func appendDelta(_ chunk: String) { if !isStreaming { start() }; text += chunk; deltaCount += 1 }
    public mutating func appendReasoning(_ chunk: String) { if !isStreaming { start() }; reasoning += chunk }
    /// `message.complete` carries the authoritative final text when provided.
    public mutating func complete(finalText: String?) -> String {
        if let finalText, !finalText.isEmpty { text = finalText }
        isStreaming = false
        return text
    }
    public mutating func reset() { text = ""; reasoning = ""; deltaCount = 0; isStreaming = false }

    /// `message.complete` carries the whole assistant turn. When tool calls split the stream, the
    /// leading part is already on screen in earlier bubbles; only this remainder belongs in the
    /// trailing one. Returns `full` unchanged when the two have diverged (best effort).
    public static func tail(ofFinalText full: String, alreadySealed sealed: String) -> String {
        guard !sealed.isEmpty else { return full }
        if full.hasPrefix(sealed) { return trimmingLeadingBlankLines(String(full.dropFirst(sealed.count))) }
        // The concatenated deltas and the authoritative final text can differ by whitespace
        // (chunk boundaries, a normalized trailing newline). Re-match ignoring whitespace so a
        // cosmetic difference does not make the whole turn render twice.
        var f = full.startIndex, t = sealed.startIndex
        while f < full.endIndex, t < sealed.endIndex {
            let fc = full[f], tc = sealed[t]
            if fc == tc { f = full.index(after: f); t = sealed.index(after: t); continue }
            if fc.isWhitespace { f = full.index(after: f); continue }
            if tc.isWhitespace { t = sealed.index(after: t); continue }
            return full  // genuine divergence: trust the server's text
        }
        while t < sealed.endIndex, sealed[t].isWhitespace { t = sealed.index(after: t) }
        guard t == sealed.endIndex else { return full }
        return trimmingLeadingBlankLines(String(full[f...]))
    }

    /// The remainder becomes its own bubble, so leading blank lines are never meaningful.
    /// Indentation on the first non-empty line is preserved (it may open a code block).
    private static func trimmingLeadingBlankLines(_ text: String) -> String {
        var out = Substring(text)
        while let first = out.first, first == "\n" || first == "\r" { out = out.dropFirst() }
        return String(out)
    }
}


/// Output tokens, wall time and rate for one agent turn.
public struct TurnStats: Hashable, Sendable {
    public var outputTokens: Int
    public var seconds: Double
    /// True when the token count came from `session.usage` rather than a characters/4 estimate.
    public var exact: Bool

    public var tokensPerSecond: Double? { seconds > 0.5 ? Double(outputTokens) / seconds : nil }

    /// `412 tokens · 38 tok/s · 10.8s`, with `~` in front of estimated counts.
    public var label: String {
        var parts = ["\(exact ? "" : "~")\(outputTokens) tokens"]
        if let tps = tokensPerSecond { parts.append(String(format: "%.0f tok/s", tps)) }
        parts.append(seconds >= 60 ? String(format: "%.1f min", seconds / 60) : String(format: "%.1fs", seconds))
        return parts.joined(separator: " · ")
    }

    /// `usage.output` before and after the turn gives the exact count; when either side is unknown
    /// the streamed text is estimated at four characters per token.
    public static func make(outputBefore: Int?, outputAfter: Int?, streamedCharacters: Int, seconds: Double) -> TurnStats {
        if let b = outputBefore, let a = outputAfter, a > b { return TurnStats(outputTokens: a - b, seconds: seconds, exact: true) }
        return TurnStats(outputTokens: max(1, streamedCharacters / 4), seconds: seconds, exact: false)
    }

    public init(outputTokens: Int, seconds: Double, exact: Bool) {
        self.outputTokens = outputTokens
        self.seconds = seconds
        self.exact = exact
    }
}
