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

/// A helper the bot spun up for part of the work. The gateway raises every `subagent.*` event
/// on the parent's session and names the helper by id; this is the one row that follows it
/// from the spawn request to its report (a tester saw only "running" and then nothing).
public struct SubagentActivity: Hashable, Sendable {
    public var id: String
    public var goal: String
    /// `running` until the gateway says `completed`, `failed`… on `subagent.complete`.
    public var status: String
    /// What it is on right now: the tool it is running, or the last line of its thinking.
    public var step: String?
    public var model: String?
    public var toolCount: Int?
    public var durationSeconds: Double?
    /// What it came back with, from `subagent.complete`.
    public var summary: String?
    /// Its place in a batch of helpers started together (0-based, as the gateway counts).
    public var taskIndex: Int?
    public var taskCount: Int?

    public init(id: String, goal: String, status: String = "running", step: String? = nil, model: String? = nil, toolCount: Int? = nil,
                durationSeconds: Double? = nil, summary: String? = nil, taskIndex: Int? = nil, taskCount: Int? = nil) {
        self.id = id; self.goal = goal; self.status = status; self.step = step; self.model = model; self.toolCount = toolCount
        self.durationSeconds = durationSeconds; self.summary = summary; self.taskIndex = taskIndex; self.taskCount = taskCount
    }

    public var isRunning: Bool { status == "running" }
    public var failed: Bool { status == "failed" || status == "error" }

    /// The line under the goal: the step while it runs, the outcome once it is back.
    public var detailLine: String? {
        var parts: [String] = []
        if let i = taskIndex, let n = taskCount, n > 1 { parts.append("\(i + 1) of \(n)") }
        if isRunning {
            parts.append(step ?? "Working…")
        } else {
            var done = failed ? "Failed" : "Done"
            if let s = durationSeconds, s > 0 { done += s < 60 ? " in \(Int(s.rounded()))s" : " in \(Int((s / 60).rounded()))m" }
            parts.append(done)
            if let n = toolCount, n > 0 { parts.append("\(n) tool call\(n == 1 ? "" : "s")") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The transcript row id for the helper a `subagent.*` payload names, if it names one.
    public static func rowID(for p: JSONValue) -> String? {
        let hid = p["subagent_id"]?.stringValue ?? p["child_session_id"]?.stringValue ?? p["delegation_id"]?.stringValue ?? ""
        return hid.isEmpty ? nil : "sub-" + hid
    }

    /// The row after one more `subagent.*` event: made by whichever event comes first and
    /// kept up to date by the rest (the official TUI does the same).
    public static func applying(_ type: String, _ p: JSONValue, to current: SubagentActivity?) -> SubagentActivity {
        var act = current ?? SubagentActivity(id: p["subagent_id"]?.stringValue ?? p["child_session_id"]?.stringValue ?? "", goal: "Subagent")
        if let g = p["goal"]?.stringValue, !g.isEmpty { act.goal = g }
        if let m = p["model"]?.stringValue, !m.isEmpty { act.model = m }
        if let n = p["tool_count"]?.intValue { act.toolCount = n }
        if let i = p["task_index"]?.intValue { act.taskIndex = i }
        if let n = p["task_count"]?.intValue { act.taskCount = n }
        func oneLine(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        switch type {
        case "subagent.tool":
            let name = p["tool_name"]?.stringValue ?? "tool"
            let preview = oneLine(p["tool_preview"]?.stringValue ?? "")
            act.step = preview.isEmpty ? name : "\(name): \(preview.prefix(120))"
        case "subagent.thinking", "subagent.progress":
            if let t = p["text"]?.stringValue.map(oneLine), !t.isEmpty { act.step = String(t.suffix(160)) }
        case "subagent.complete":
            act.status = p["status"]?.stringValue ?? "completed"
            if let s = p["summary"]?.stringValue, !s.isEmpty { act.summary = s }
            if let d = p["duration_seconds"]?.doubleValue { act.durationSeconds = d }
            act.step = nil
        default:
            break   // spawn_requested, start: the row itself is the news
        }
        return act
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
        case subagent(SubagentActivity)
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

/// A note the gateway put in the user's seat: a background process reporting in, a scheduled run's
/// prompt, a system line. Drawn as a quiet folded notice, not as the person's own bubble.
public struct InjectedNote: Hashable, Sendable {
    public var title: String
    public var body: String

    public static func parse(_ text: String) -> InjectedNote? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("[") else { return nil }
        let lower = t.lowercased()
        if lower.hasPrefix("[important: background process") || lower.hasPrefix("[background process") {
            let ok = lower.contains("completed normally") || lower.contains("exit code 0")
            let failed = lower.contains("failed") || lower.contains("non-zero") || lower.contains("exit code") && !ok
            return InjectedNote(title: failed ? "Background process failed" : "Background process finished", body: t)
        }
        if lower.hasPrefix("[cronjob") {
            let name = t.firstMatch(of: /\[Cronjob "([^"]+)"/).map { String($0.1) }
            return InjectedNote(title: name.map { "Scheduled run: \($0)" } ?? "Scheduled run", body: t)
        }
        // A helper's report, filed in the user's seat for the bot to read on: "[ASYNC DELEGATION
        // COMPLETE — id]", "…BATCH COMPLETE…", "…TASK FAILED…". It read as the person's own words.
        if lower.hasPrefix("[async delegation") {
            let head = t.prefix { $0 != "]" }.lowercased()
            let failed = head.contains("fail")
            let batch = head.contains("batch")
            return InjectedNote(title: failed ? "Subagent failed" : batch ? "Subagents reported back" : "Subagent reported back", body: t)
        }
        if lower.hasPrefix("[important:") || lower.hasPrefix("[system") || lower.hasPrefix("[note") {
            return InjectedNote(title: "Note from the gateway", body: t)
        }
        return nil
    }
}

/// The gateway could not start the bot's model: a provider whose CLI or key is missing on the
/// gateway machine. Named so the chat can say what is wrong and offer another model.
public struct StartFailure: Hashable, Sendable {
    public var provider: String?
    public var reason: String

    public static func parse(_ text: String) -> StartFailure? {
        let lower = text.lowercased()
        guard lower.contains("could not start the assistant") || lower.contains("cli command") && lower.contains("could not find") else { return nil }
        let provider = text.firstMatch(of: /[Cc]ould not find the '([^']+)' CLI command/).map { String($0.1) }
            ?? text.firstMatch(of: /provider '([^']+)'/).map { String($0.1) }
        var reason = text
        if let r = text.range(of: "Details:") { reason = String(text[r.upperBound...]) }
        if let r = reason.range(of: "Check the model") { reason = String(reason[..<r.lowerBound]) }
        reason = reason.replacingOccurrences(of: "..", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        return StartFailure(provider: provider, reason: reason)
    }
}
