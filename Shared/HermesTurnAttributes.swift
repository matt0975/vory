#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Live Activity payload shared by the app and the widget extension.
public struct HermesTurnAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        /// "streaming", "tool", "waiting", "done", "error"
        public var phase: String
        /// Tool name, approval summary, or a short status line.
        public var detail: String
        public var outputTokens: Int
        public var contextPercent: Int?
        /// Context window in tokens (used / size), shown as "12.3k/128k" when both are known.
        public var contextUsed: Int?
        public var contextMax: Int?
        public var needsAttention: Bool
        /// "approval" (Approve / Deny make sense) or "input" (a password, a secret, a question):
        /// the widget must not offer Approve on a sudo prompt. Absent on older pushes.
        public var attentionKind: String? = nil
        /// When the turn started, as Unix seconds; the widget renders a live elapsed timer from it.
        /// Plain numbers so the `hermes-push` companion can set them in a `liveactivity` push.
        public var startedAtUnix: Double
        /// When the turn ended (Unix seconds), so the timer freezes instead of counting past "done".
        public var endedAtUnix: Double?

        public var startedAt: Date { Date(timeIntervalSince1970: startedAtUnix) }
        public var endedAt: Date? { endedAtUnix.map { Date(timeIntervalSince1970: $0) } }

        public init(phase: String, detail: String, outputTokens: Int, contextPercent: Int?, needsAttention: Bool,
                    startedAt: Date = Date(), endedAt: Date? = nil, contextUsed: Int? = nil, contextMax: Int? = nil) {
            self.phase = phase
            self.detail = detail
            self.outputTokens = outputTokens
            self.contextPercent = contextPercent
            self.contextUsed = contextUsed
            self.contextMax = contextMax
            self.needsAttention = needsAttention
            self.startedAtUnix = startedAt.timeIntervalSince1970
            self.endedAtUnix = endedAt?.timeIntervalSince1970
        }
    }

    public var sessionTitle: String
    public var storedSessionID: String
    public var connectionID: String
    public var profile: String
    /// Short model name, e.g. `grok-4.7`; empty when unknown.
    public var model: String
    /// The bot's accent colour as `#RRGGBB`; empty means use the phase colours.
    public var tintHex: String
    /// The bot's display name (profile label); the widget leads with it, not the chat title.
    public var botName: String?
    /// The bot's avatar choice as stored by the app ("initial", "photo", "animated:<style>"); the
    /// widget draws the animated styles itself and falls back to the initial for the rest.
    public var avatar: String?

    public init(sessionTitle: String, storedSessionID: String, connectionID: String, profile: String, model: String = "", tintHex: String = "",
                botName: String? = nil, avatar: String? = nil) {
        self.sessionTitle = sessionTitle
        self.storedSessionID = storedSessionID
        self.connectionID = connectionID
        self.profile = profile
        self.model = model
        self.tintHex = tintHex
        self.botName = botName
        self.avatar = avatar
    }
}
#endif
