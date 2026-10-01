import Foundation

// Typed views of the gateway's wire contracts (tui_gateway/contracts + dashboard REST).
// Everything optional on the wire is optional here.

public struct Usage: Codable, Hashable, Sendable {
    public var model: String?
    public var input: Int?
    public var output: Int?
    public var reasoning: Int?
    public var total: Int?
    public var calls: Int?
    public var compressions: Int?
    public var contextUsed: Int?
    public var contextMax: Int?
    public var contextPercent: Int?
    public var contextEstimated: Bool?
    public var cacheHitPct: Int?
    public var avgTps: Double?
    public var costUsd: Double?
    public var costStatus: String?
    public var activeSubagents: Int?

    public init(model: String? = nil, input: Int? = nil, output: Int? = nil, reasoning: Int? = nil, total: Int? = nil, calls: Int? = nil, compressions: Int? = nil, contextUsed: Int? = nil, contextMax: Int? = nil, contextPercent: Int? = nil, contextEstimated: Bool? = nil, cacheHitPct: Int? = nil, avgTps: Double? = nil, costUsd: Double? = nil, costStatus: String? = nil, activeSubagents: Int? = nil) {
        self.model = model
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.total = total
        self.calls = calls
        self.compressions = compressions
        self.contextUsed = contextUsed
        self.contextMax = contextMax
        self.contextPercent = contextPercent
        self.contextEstimated = contextEstimated
        self.cacheHitPct = cacheHitPct
        self.avgTps = avgTps
        self.costUsd = costUsd
        self.costStatus = costStatus
        self.activeSubagents = activeSubagents
    }
}

public struct SessionLiveInfo: Codable, Hashable, Sendable {
    public var model: String?
    public var provider: String?
    public var reasoningEffort: String?
    public var serviceTier: String?
    public var fast: Bool?
    public var yolo: Bool?
    public var approvalMode: String?
    public var cwd: String?
    public var branch: String?
    public var running: Bool?
    public var title: String?
    public var storedSessionId: String?
    public var version: String?
    public var usage: Usage?
    public var profileName: String?
    public var credentialWarning: String?
    public var lazy: Bool?

    public init(model: String? = nil, provider: String? = nil, reasoningEffort: String? = nil, serviceTier: String? = nil, fast: Bool? = nil, yolo: Bool? = nil, approvalMode: String? = nil, cwd: String? = nil, branch: String? = nil, running: Bool? = nil, title: String? = nil, storedSessionId: String? = nil, version: String? = nil, usage: Usage? = nil, profileName: String? = nil, credentialWarning: String? = nil, lazy: Bool? = nil) {
        self.model = model
        self.provider = provider
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.fast = fast
        self.yolo = yolo
        self.approvalMode = approvalMode
        self.cwd = cwd
        self.branch = branch
        self.running = running
        self.title = title
        self.storedSessionId = storedSessionId
        self.version = version
        self.usage = usage
        self.profileName = profileName
        self.credentialWarning = credentialWarning
        self.lazy = lazy
    }
}

public struct TranscriptMessage: Codable, Hashable, Sendable {
    public var role: String
    public var text: String?
    public var timestamp: Double?
    public var rowId: Int?
    public var displayKind: String?
    public var name: String?
    public var context: String?
    public var reasoning: String?

    public init(role: String, text: String? = nil, timestamp: Double? = nil, rowId: Int? = nil, displayKind: String? = nil, name: String? = nil, context: String? = nil, reasoning: String? = nil) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.rowId = rowId
        self.displayKind = displayKind
        self.name = name
        self.context = context
        self.reasoning = reasoning
    }

    // The WebSocket `session.resume` history is pre-flattened (`text`), but the REST
    // `/api/sessions/{id}/messages` page is the raw stored row: `content` as a string or a list
    // of parts, `id` instead of `row_id`, an ISO timestamp and the tool name inside `tool_calls`.
    // The watch and the fast-open prefetch read that page, so both shapes decode here.
    private enum Keys: String, CodingKey {
        case role, text, timestamp, rowId, displayKind, name, context, reasoning, content, id, toolCalls, displayContent
        case rowIdRaw = "row_id", displayKindRaw = "display_kind", toolCallsRaw = "tool_calls", displayContentRaw = "display_content"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? "assistant"
        var t = try? c.decodeIfPresent(String.self, forKey: .text)
        if t == nil, let v = (try? c.decodeIfPresent(JSONValue.self, forKey: .displayContent)) ?? (try? c.decodeIfPresent(JSONValue.self, forKey: .displayContentRaw)) { t = Self.flatten(v) }
        if t == nil, let v = try? c.decodeIfPresent(JSONValue.self, forKey: .content) { t = Self.flatten(v) }
        text = t
        if let d = try? c.decodeIfPresent(Double.self, forKey: .timestamp) { timestamp = d }
        else if let s = try? c.decodeIfPresent(String.self, forKey: .timestamp) { timestamp = Self.parseDate(s) }
        rowId = (try? c.decodeIfPresent(Int.self, forKey: .rowId)) ?? (try? c.decodeIfPresent(Int.self, forKey: .rowIdRaw)) ?? (try? c.decodeIfPresent(Int.self, forKey: .id))
        displayKind = (try? c.decodeIfPresent(String.self, forKey: .displayKind)) ?? (try? c.decodeIfPresent(String.self, forKey: .displayKindRaw))
        var n = try? c.decodeIfPresent(String.self, forKey: .name)
        if n == nil, let tc = (try? c.decodeIfPresent(JSONValue.self, forKey: .toolCalls)) ?? (try? c.decodeIfPresent(JSONValue.self, forKey: .toolCallsRaw)),
           let first = tc.arrayValue?.first { n = first["function"]?["name"]?.stringValue ?? first["name"]?.stringValue }
        name = n
        context = try? c.decodeIfPresent(String.self, forKey: .context)
        reasoning = try? c.decodeIfPresent(String.self, forKey: .reasoning)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(rowId, forKey: .rowId)
        try c.encodeIfPresent(displayKind, forKey: .displayKind)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(context, forKey: .context)
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
    }

    /// OpenAI-style content: a string, or parts like `{type: "text", text: …}`.
    static func flatten(_ v: JSONValue) -> String? {
        if let s = v.stringValue { return s }
        guard let parts = v.arrayValue else { return nil }
        let texts = parts.compactMap { p -> String? in
            if let s = p.stringValue { return s }
            if let t = p["text"]?.stringValue { return t }
            if p["type"]?.stringValue == "image_url" { return "[image]" }
            return nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    static func parseDate(_ s: String) -> Double? {
        if let d = Double(s) { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d.timeIntervalSince1970 }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d.timeIntervalSince1970 }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"] {
            f.dateFormat = fmt
            f.timeZone = s.hasSuffix("Z") || s.contains("+") ? TimeZone(identifier: "UTC") : TimeZone.current
            if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        }
        return nil
    }
}

/// A stored session row from `GET /api/sessions`.
public struct StoredSession: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String?
    public var preview: String?
    public var source: String?
    public var model: String?
    public var startedAt: Double?
    public var endedAt: Double?
    public var lastActive: Double?
    public var messageCount: Int?
    public var isActive: Bool?
    public var archived: Bool?
    public var pinned: Bool?
    public var profile: String?
    public var cwd: String?

    public var displayTitle: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let p = (preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? "New chat" : String(p.prefix(80))
    }
    public var lastDate: Date? { (lastActive ?? startedAt).map { Date(timeIntervalSince1970: $0) } }

    public init(id: String, title: String? = nil, preview: String? = nil, source: String? = nil, model: String? = nil, startedAt: Double? = nil, endedAt: Double? = nil, lastActive: Double? = nil, messageCount: Int? = nil, isActive: Bool? = nil, archived: Bool? = nil, pinned: Bool? = nil, profile: String? = nil, cwd: String? = nil) {
        self.id = id
        self.title = title
        self.preview = preview
        self.source = source
        self.model = model
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastActive = lastActive
        self.messageCount = messageCount
        self.isActive = isActive
        self.archived = archived
        self.pinned = pinned
        self.profile = profile
        self.cwd = cwd
    }
}

public struct SessionListResponse: Codable, Sendable {
    public var sessions: [StoredSession]
    public var total: Int?

    public init(sessions: [StoredSession], total: Int? = nil) {
        self.sessions = sessions
        self.total = total
    }
}

public struct SessionMessagesResponse: Codable, Sendable {
    public var sessionId: String
    public var messages: [TranscriptMessage]

    public init(sessionId: String, messages: [TranscriptMessage]) {
        self.sessionId = sessionId
        self.messages = messages
    }
}

// MARK: Server → client requests

public struct ApprovalRequest: Codable, Hashable, Sendable, Identifiable {
    public var requestId: String
    public var sessionId: String
    public var command: String?
    public var description: String?
    public var choices: [String]?
    public var toolName: String?
    public var smartDenied: Bool?
    /// The rule "Session" and "Always" allow: a command pattern (`rm -rf`, say), a tool (`execute_code`)
    /// or a tool rule (`write_file:<hash>`), never the exact command. Nil on older gateways.
    public var patternKey: String?
    public var id: String { requestId }
    public var offeredChoices: [String] { (choices?.isEmpty == false ? choices! : ["once", "session", "always", "deny"]) }
    /// What "Always" would allow, in words: the rule, then how it is keyed.
    public var alwaysScope: String {
        let key = patternKey?.trimmingCharacters(in: .whitespaces) ?? ""
        if key.isEmpty { return "this kind of command" }
        if key.hasPrefix("tirith:") { return "this finding (session only)" }
        if let colon = key.firstIndex(of: ":") { return "the \(key[..<colon]) tool for this kind of request" }
        if key == toolName || key == "execute_code" { return "the \(key) tool" }
        return "commands matching “\(key)”"
    }

    public init(requestId: String, sessionId: String, command: String? = nil, description: String? = nil, choices: [String]? = nil, toolName: String? = nil, smartDenied: Bool? = nil, patternKey: String? = nil) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.command = command
        self.description = description
        self.choices = choices
        self.toolName = toolName
        self.smartDenied = smartDenied
        self.patternKey = patternKey
    }
}

public struct ClarifyQuestion: Codable, Hashable, Sendable, Identifiable {
    public var qid: String
    public var question: String
    public var choices: [String]?
    public var multiSelect: Bool?
    public var id: String { qid }

    public init(qid: String, question: String, choices: [String]? = nil, multiSelect: Bool? = nil) {
        self.qid = qid
        self.question = question
        self.choices = choices
        self.multiSelect = multiSelect
    }
}

public struct ClarifyRequest: Codable, Hashable, Sendable {
    public var sessionId: String
    public var question: String?
    public var choices: [String]?
    public var multiSelect: Bool?
    public var questions: [ClarifyQuestion]?
    public var answers: [String: String]?

    public init(sessionId: String, question: String? = nil, choices: [String]? = nil, multiSelect: Bool? = nil, questions: [ClarifyQuestion]? = nil, answers: [String: String]? = nil) {
        self.sessionId = sessionId
        self.question = question
        self.choices = choices
        self.multiSelect = multiSelect
        self.questions = questions
        self.answers = answers
    }
}

public struct ValuePromptRequest: Codable, Hashable, Sendable {
    public var sessionId: String
    public var command: String?
    public var envVar: String?
    public var prompt: String?
    public var backend: String?
    public var displayName: String?
    public var origin: String?
    public var site: String?
    public var hint: String?

    public init(sessionId: String, command: String? = nil, envVar: String? = nil, prompt: String? = nil, backend: String? = nil, displayName: String? = nil, origin: String? = nil, site: String? = nil, hint: String? = nil) {
        self.sessionId = sessionId
        self.command = command
        self.envVar = envVar
        self.prompt = prompt
        self.backend = backend
        self.displayName = displayName
        self.origin = origin
        self.site = site
        self.hint = hint
    }
}

// MARK: Models / profiles / auth

public struct ModelCapabilities: Codable, Hashable, Sendable {
    public var fast: Bool?
    public var reasoning: Bool?
    public var canDisableReasoning: Bool?

    public init(fast: Bool? = nil, reasoning: Bool? = nil, canDisableReasoning: Bool? = nil) {
        self.fast = fast
        self.reasoning = reasoning
        self.canDisableReasoning = canDisableReasoning
    }
}

public struct ModelProvider: Codable, Hashable, Sendable, Identifiable {
    public var slug: String
    public var name: String
    public var models: [String]?
    public var isCurrent: Bool?
    public var authenticated: Bool?
    public var featuredModels: [String]?
    public var capabilities: [String: ModelCapabilities]?
    public var warning: String?
    public var id: String { slug }

    public init(slug: String, name: String, models: [String]? = nil, isCurrent: Bool? = nil, authenticated: Bool? = nil, featuredModels: [String]? = nil, capabilities: [String: ModelCapabilities]? = nil, warning: String? = nil) {
        self.slug = slug
        self.name = name
        self.models = models
        self.isCurrent = isCurrent
        self.authenticated = authenticated
        self.featuredModels = featuredModels
        self.capabilities = capabilities
        self.warning = warning
    }
}

public struct ModelOptionsResult: Codable, Hashable, Sendable {
    public var providers: [ModelProvider]
    public var model: String?
    public var provider: String?

    public init(providers: [ModelProvider], model: String? = nil, provider: String? = nil) {
        self.providers = providers
        self.model = model
        self.provider = provider
    }
}

public struct ProfileInfo: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var displayName: String?
    public var botTitle: String?
    public var isDefault: Bool?
    public var model: String?
    public var provider: String?
    public var description: String?
    public var path: String?
    public var skillCount: Int?
    public var id: String { name }
    public var label: String { (displayName?.isEmpty == false) ? displayName! : name }

    public init(name: String, displayName: String? = nil, botTitle: String? = nil, isDefault: Bool? = nil, model: String? = nil, provider: String? = nil, description: String? = nil, path: String? = nil, skillCount: Int? = nil) {
        self.name = name
        self.displayName = displayName
        self.botTitle = botTitle
        self.isDefault = isDefault
        self.model = model
        self.provider = provider
        self.description = description
        self.path = path
        self.skillCount = skillCount
    }
}

public struct ProfilesResponse: Codable, Sendable { public var profiles: [ProfileInfo] }
public struct ActiveProfileResponse: Codable, Sendable { public var active: String?; public var current: String? }

public struct AuthMeResponse: Codable, Sendable {
    public var userId: String?
    public var email: String?
    public var displayName: String?
    public var provider: String?
    public var expiresAt: Double?

    public init(userId: String? = nil, email: String? = nil, displayName: String? = nil, provider: String? = nil, expiresAt: Double? = nil) {
        self.userId = userId
        self.email = email
        self.displayName = displayName
        self.provider = provider
        self.expiresAt = expiresAt
    }
}

public struct AuthProvider: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var displayName: String?
    public var supportsPassword: Bool?
    public var id: String { name }

    public init(name: String, displayName: String? = nil, supportsPassword: Bool? = nil) {
        self.name = name
        self.displayName = displayName
        self.supportsPassword = supportsPassword
    }
}
public struct AuthProvidersResponse: Codable, Sendable { public var providers: [AuthProvider] }

public struct GatewayStatusResponse: Codable, Sendable {
    public var version: String?
    public var authRequired: Bool?
    public var authProviders: [String]?
    public var authFlows: [String]?
    public var activeSessions: Int?
    public var gatewayRunning: Bool?
    public var gatewayState: String?

    public init(version: String? = nil, authRequired: Bool? = nil, authProviders: [String]? = nil, authFlows: [String]? = nil, activeSessions: Int? = nil, gatewayRunning: Bool? = nil, gatewayState: String? = nil) {
        self.version = version
        self.authRequired = authRequired
        self.authProviders = authProviders
        self.authFlows = authFlows
        self.activeSessions = activeSessions
        self.gatewayRunning = gatewayRunning
        self.gatewayState = gatewayState
    }
}

public struct NativeTokenResponse: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var tokenType: String?
    public var expiresAt: Double?
    public var provider: String?
    public var userId: String?

    public init(accessToken: String, refreshToken: String? = nil, tokenType: String? = nil, expiresAt: Double? = nil, provider: String? = nil, userId: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.provider = provider
        self.userId = userId
    }
}

// MARK: Settings

public struct ToolsetInfo: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var label: String?
    public var description: String?
    public var platform: String?
    public var enabled: Bool
    public var configured: Bool?
    public var tools: [String]?
    public var id: String { name }

    public init(name: String, label: String? = nil, description: String? = nil, platform: String? = nil, enabled: Bool, configured: Bool? = nil, tools: [String]? = nil) {
        self.name = name
        self.label = label
        self.description = description
        self.platform = platform
        self.enabled = enabled
        self.configured = configured
        self.tools = tools
    }
}

public struct SkillInfo: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String?
    public var category: String?
    public var enabled: Bool?
    public var usage: Int?
    public var provenance: String?
    public var id: String { name }

    public init(name: String, description: String? = nil, category: String? = nil, enabled: Bool? = nil, usage: Int? = nil, provenance: String? = nil) {
        self.name = name
        self.description = description
        self.category = category
        self.enabled = enabled
        self.usage = usage
        self.provenance = provenance
    }
}

/// One row of `GET /api/env`. The gateway sends `is_set` and `redacted_value` (snake case, so
/// `isSet` / `redactedValue` after the shared decoder); the older names stay for any gateway
/// that still sends them.
public struct EnvVarInfo: Codable, Hashable, Sendable {
    public var isSet: Bool?
    public var redactedValue: String?
    public var set: Bool?
    public var redacted: String?
    public var description: String?
    public var category: String?
    public var docsUrl: String?
    public var url: String?
    public var isPassword: Bool?
    public var provider: String?
    public var providerLabel: String?

    /// Whether the gateway has a value, whichever field it used.
    public var hasValue: Bool { isSet ?? set ?? false }
    /// The preview without the gateway's `«redacted:…»` wrapper.
    public var preview: String? {
        guard var p = redactedValue ?? redacted, !p.isEmpty else { return nil }
        if p.hasPrefix("«redacted:") { p = String(p.dropFirst("«redacted:".count)) }
        if p.hasSuffix("»") { p = String(p.dropLast()) }
        return p
    }

    public init(set: Bool? = nil, redacted: String? = nil, description: String? = nil, category: String? = nil, docsUrl: String? = nil) {
        self.set = set
        self.redacted = redacted
        self.description = description
        self.category = category
        self.docsUrl = docsUrl
    }
}

public struct MCPServerInfo: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var url: String?
    public var command: String?
    public var args: [String]?
    public var enabled: Bool?
    public var transport: String?
    public var id: String { name }

    public init(name: String, url: String? = nil, command: String? = nil, args: [String]? = nil, enabled: Bool? = nil, transport: String? = nil) {
        self.name = name
        self.url = url
        self.command = command
        self.args = args
        self.enabled = enabled
        self.transport = transport
    }
}

public struct CronJob: Codable, Hashable, Sendable, Identifiable {
    public var id: String?
    public var jobId: String?
    public var name: String?
    public var schedule: String?
    public var prompt: String?
    public var promptPreview: String?
    public var deliver: String?
    public var enabled: Bool?
    public var state: String?
    public var nextRunAt: String?
    public var lastRunAt: String?
    public var lastStatus: String?
    public var identity: String { jobId ?? id ?? name ?? UUID().uuidString }

    public init(id: String? = nil, jobId: String? = nil, name: String? = nil, schedule: String? = nil, prompt: String? = nil, promptPreview: String? = nil, deliver: String? = nil, enabled: Bool? = nil, state: String? = nil, nextRunAt: String? = nil, lastRunAt: String? = nil, lastStatus: String? = nil) {
        self.id = id
        self.jobId = jobId
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.promptPreview = promptPreview
        self.deliver = deliver
        self.enabled = enabled
        self.state = state
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
    }
}

public struct ConfigSchemaField: Codable, Hashable, Sendable {
    public var type: String
    public var description: String?
    public var category: String?
    public var options: [String]?
    public var searchable: Bool?
    public var clearable: Bool?

    public init(type: String, description: String? = nil, category: String? = nil, options: [String]? = nil, searchable: Bool? = nil, clearable: Bool? = nil) {
        self.type = type
        self.description = description
        self.category = category
        self.options = options
        self.searchable = searchable
        self.clearable = clearable
    }
}

public struct ConfigSchemaResponse: Codable, Sendable {
    public var fields: [String: ConfigSchemaField]
    public var categoryOrder: [String]?

    public init(fields: [String: ConfigSchemaField], categoryOrder: [String]? = nil) {
        self.fields = fields
        self.categoryOrder = categoryOrder
    }
}

public struct ContextCategory: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var tokens: Int
    public var color: String?

    public init(id: String, label: String, tokens: Int, color: String? = nil) {
        self.id = id
        self.label = label
        self.tokens = tokens
        self.color = color
    }
}

public struct ContextBreakdown: Codable, Hashable, Sendable {
    public var categories: [ContextCategory]
    public var contextMax: Int
    public var contextPercent: Int
    public var contextUsed: Int
    public var estimatedTotal: Int?
    public var model: String?

    public init(categories: [ContextCategory], contextMax: Int, contextPercent: Int, contextUsed: Int, estimatedTotal: Int? = nil, model: String? = nil) {
        self.categories = categories
        self.contextMax = contextMax
        self.contextPercent = contextPercent
        self.contextUsed = contextUsed
        self.estimatedTotal = estimatedTotal
        self.model = model
    }
}

public struct FileEntry: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int?
    public var modifiedAt: Double?
    public var mimeType: String?
    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool, size: Int? = nil, modifiedAt: Double? = nil, mimeType: String? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.mimeType = mimeType
    }
}

public struct FilesListing: Codable, Sendable {
    public var path: String
    public var parent: String?
    public var entries: [FileEntry]
    public var root: String?
    public var lockedRoot: String?

    public init(path: String, parent: String? = nil, entries: [FileEntry], root: String? = nil, lockedRoot: String? = nil) {
        self.path = path
        self.parent = parent
        self.entries = entries
        self.root = root
        self.lockedRoot = lockedRoot
    }
}

public struct ManagedUploadResult: Codable, Sendable {
    public var ok: Bool?
    public var path: String

    public init(ok: Bool? = nil, path: String) {
        self.ok = ok
        self.path = path
    }
}

// MARK: Bot Mode (hosted rooms)

public struct RoomMember: Codable, Hashable, Sendable {
    public var memberId: String?
    public var profile: String?
    public var handle: String?
    public var displayName: String?

    public init(memberId: String? = nil, profile: String? = nil, handle: String? = nil, displayName: String? = nil) {
        self.memberId = memberId
        self.profile = profile
        self.handle = handle
        self.displayName = displayName
    }
}

public struct RoomActor: Codable, Hashable, Sendable { public var kind: String; public var id: String }

public struct RoomEvent: Codable, Hashable, Sendable, Identifiable {
    public var roomId: String
    public var seq: Int
    public var eventId: String
    public var kind: String
    public var actor: RoomActor
    public var payload: JSONValue
    public var createdAt: Double
    public var id: String { eventId }

    public init(roomId: String, seq: Int, eventId: String, kind: String, actor: RoomActor, payload: JSONValue, createdAt: Double) {
        self.roomId = roomId
        self.seq = seq
        self.eventId = eventId
        self.kind = kind
        self.actor = actor
        self.payload = payload
        self.createdAt = createdAt
    }
}

public struct Room: Codable, Hashable, Sendable, Identifiable {
    public var roomId: String
    public var name: String
    public var members: [RoomMember]
    public var updatedAt: Double
    public var disbandedAt: Double?
    public var latestSeq: Int?
    public var id: String { roomId }

    public init(roomId: String, name: String, members: [RoomMember], updatedAt: Double, disbandedAt: Double? = nil, latestSeq: Int? = nil) {
        self.roomId = roomId
        self.name = name
        self.members = members
        self.updatedAt = updatedAt
        self.disbandedAt = disbandedAt
        self.latestSeq = latestSeq
    }
}

public struct GroupsListResult: Codable, Sendable { public var rooms: [Room] }
public struct GroupsLogResult: Codable, Sendable { public var events: [RoomEvent]; public var cursor: Int; public var latestSeq: Int; public var hasMore: Bool }
public struct GroupsCapabilities: Codable, Sendable { public var driver: Bool?; public var features: [String]?; public var methods: [String]? }

// MARK: Commands

public struct CommandCategory: Codable, Hashable, Sendable { public var name: String; public var pairs: [[String]]? }
public struct CommandsCatalog: Codable, Hashable, Sendable {
    /// Per command ("/name"): how it takes arguments and whether a non-terminal client may run
    /// it (`desktop` nil = yes, "hidden" = yes but not listed, anything else = the reason not).
    public struct Meta: Codable, Hashable, Sendable {
        public var argumentMode: String?
        public var desktop: String?
    }
    public var pairs: [[String]]?
    public var categories: [CommandCategory]?
    public var canon: [String: String]?
    public var commands: [String: Meta]?
    public var warning: String?
    public var allPairs: [(name: String, description: String)] {
        var out: [(String, String)] = []
        for p in pairs ?? [] where p.count >= 1 { out.append((p[0], p.count > 1 ? p[1] : "")) }
        return out
    }

    public init(pairs: [[String]]? = nil, categories: [CommandCategory]? = nil, canon: [String: String]? = nil, warning: String? = nil) {
        self.pairs = pairs
        self.categories = categories
        self.canon = canon
        self.warning = warning
    }
}

public struct CommandDispatchResult: Codable, Hashable, Sendable {
    public var type: String
    public var output: String?
    public var target: String?
    public var message: String?
    public var notice: String?
    public var display: String?

    public init(type: String, output: String? = nil, target: String? = nil, message: String? = nil, notice: String? = nil, display: String? = nil) {
        self.type = type
        self.output = output
        self.target = target
        self.message = message
        self.notice = notice
        self.display = display
    }
}


public extension Usage {
    /// Context fill as a whole percentage: the gateway's figure when it sends one, else used / window.
    var computedContextPercent: Int? {
        guard let max = contextMax, max > 0 else { return nil }
        return contextPercent ?? Int(Double(contextUsed ?? total ?? 0) / Double(max) * 100)
    }
}


/// `GET /api/analytics/usage?days=N`: the gateway's own usage numbers for one bot.
public struct UsageAnalytics: Codable, Sendable {
    public struct Day: Codable, Sendable, Hashable {
        public var day: String
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var cacheReadTokens: Int?
        public var reasoningTokens: Int?
        public var estimatedCost: Double?
        public var actualCost: Double?
        public var sessions: Int?
        public var apiCalls: Int?
    }
    public struct Model: Codable, Sendable, Hashable {
        public var model: String?
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var estimatedCost: Double?
        public var sessions: Int?
        public var apiCalls: Int?
    }
    public struct Totals: Codable, Sendable, Hashable {
        public var totalInput: Int?
        public var totalOutput: Int?
        public var totalCacheRead: Int?
        public var totalReasoning: Int?
        public var totalEstimatedCost: Double?
        public var totalActualCost: Double?
        public var totalSessions: Int?
        public var totalApiCalls: Int?
    }
    public var daily: [Day]?
    public var byModel: [Model]?
    public var totals: Totals?
    public var periodDays: Int?
}

// MARK: Plugins (GET /api/dashboard/plugins/hub)

/// The gateway's plugins as the dashboard's hub lists them: agent plugins (from the plugins
/// folder, bundled with Hermes, or disabled) and dashboard extensions.
public struct PluginsHub: Codable, Sendable {
    public struct Plugin: Codable, Sendable, Identifiable, Hashable {
        public var name: String
        public var version: String?
        public var description: String?
        /// Where it came from: "user", "bundled", "git"…
        public var source: String?
        /// "enabled", "disabled", "bundled" or "".
        public var runtimeStatus: String?
        public var path: String?
        public var hasDashboardManifest: Bool?
        public var userHidden: Bool?
        public var authRequired: Bool?
        public var authCommand: String?
        public var canRemove: Bool?
        public var canUpdateGit: Bool?
        public var removedReason: String?
        public var id: String { name }
    }
    public var plugins: [Plugin]
}
