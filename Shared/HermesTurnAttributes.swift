#if canImport(ActivityKit)
import ActivityKit
import Foundation
import VoryCore

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
        /// The approval Approve / Deny answer: its request's id (or its card's), set by the app.
        /// Absent (the Companion's pushes), they answer the chat's approval only when it has
        /// just one; with several the chat opens on them, as the first shown may be another
        /// approval than the one this card said.
        public var attentionRequest: String? = nil
        /// What the bot is working toward this turn ("Finding why the export times out"), when
        /// Vory Summaries has written one. Leads the card while the turn runs; `detail` is then
        /// the step under it. Absent on pushes from a Companion older than 1.0.36.
        public var goal: String? = nil
        /// The goal line sealed with this install's key, as a relay-mode push carries it (`LiveTurnSealed`); `unsealed`
        /// opens it into `goal`. Absent on the app's own updates and from a Companion older than 1.0.40.
        public var sealed: String? = nil
        /// Voice mode is on for this chat: its state line ("Listening…", "Speaking", "Paused").
        /// The card then carries End, and stays up between turns. Absent otherwise.
        public var voiceMode: String? = nil
        /// When the turn started, as Unix seconds; the widget renders a live elapsed timer from it.
        /// Plain numbers so the `hermes-push` companion can set them in a `liveactivity` push.
        public var startedAtUnix: Double
        /// When the turn ended (Unix seconds), so the timer freezes instead of counting past "done".
        public var endedAtUnix: Double?

        /// The goal line, while it applies: a turn that is running and not waiting for an answer.
        public var shownGoal: String? {
            guard !needsAttention, endedAtUnix == nil, let g = goal?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty else { return nil }
            return g
        }

        public var startedAt: Date { Date(timeIntervalSince1970: startedAtUnix) }
        public var endedAt: Date? { endedAtUnix.map { Date(timeIntervalSince1970: $0) } }

        /// This state with its sealed goal line opened by `open`, or no goal line when it can't be: never the sealed text.
        public func unsealed(open: (String) -> [String: JSONValue]? = LiveTurnSealed.open) -> ContentState {
            guard let sealed else { return self }
            var s = self
            s.goal = open(sealed)?["goal"]?.stringValue
            s.sealed = nil
            return s
        }

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
    /// A push-to-start's chat title, bot name, profile, colour and avatar sealed with this install's key, the plain ones
    /// empty (a relay-mode Companion 1.0.40 or later; `unsealed` opens them). Absent on the app's own activities.
    public var sealed: String?

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

    /// These attributes with their sealed names opened by `open`. Fields it doesn't name keep their plain value; when the
    /// blob can't be opened (no key on this phone, a key from another install, a damaged blob), the chat is "Chat" and
    /// the bot has the default name and look. Never the sealed text.
    public func unsealed(open: (String) -> [String: JSONValue]? = LiveTurnSealed.open) -> HermesTurnAttributes {
        guard let sealed else { return self }
        var a = self
        let names = open(sealed) ?? [:]
        func name(_ key: String, else plain: String?) -> String? {
            if let v = names[key]?.stringValue, !v.isEmpty { return v }
            return plain.flatMap { $0.isEmpty ? nil : $0 }
        }
        a.sessionTitle = name("title", else: sessionTitle) ?? "Chat"
        a.botName = name("bot", else: botName)
        a.profile = name("profile", else: profile) ?? ""
        a.tintHex = name("hex", else: tintHex) ?? ""
        a.avatar = name("avatar", else: avatar)
        a.sealed = nil
        return a
    }

    /// Approve / Deny on the card: the app opens on the chat and answers the approval the card
    /// shows (`attentionRequest`), if it still waits (`AppModel.open`).
    public func approvalURL(choice: String, state: ContentState) -> URL {
        var c = URLComponents(); c.scheme = "vory"; c.host = "approval"
        c.queryItems = [URLQueryItem(name: "session", value: storedSessionID), URLQueryItem(name: "choice", value: choice)]
        if let request = state.attentionRequest, !request.isEmpty { c.queryItems?.append(URLQueryItem(name: "request", value: request)) }
        return c.url!
    }
}

/// Opens what a relay-mode push carried sealed (#497): the Companion seals the goal line and a push-started activity's
/// names with the key this install minted for the relay, so neither the relay nor Apple reads them. The key comes from
/// the shared Keychain group, readable once the phone has been unlocked after starting up. Each blob is opened once and
/// kept; one that can't be opened isn't kept, so it opens once the key can be read.
public enum LiveTurnSealed {
    public static func open(_ blob: String) -> [String: JSONValue]? {
        if let hit = opened.value(blob) { return hit }
        if Keychain.accessGroup == nil { Keychain.accessGroup = Keychain.sharedGroupFromBundle() }
        guard let creds = Keychain.getCodable(PushRelay.Credentials.self, account: PushRelay.credentialsAccount),
              let fields = try? PushRelay.decrypt(blob, keyBase64: creds.payloadKey) else { return nil }
        opened.keep(fields, for: blob)
        return fields
    }

    private static let opened = Opened()

    /// The blobs opened so far, a few dozen at most (an activity's names and its turn's goal lines).
    private final class Opened: @unchecked Sendable {
        private let lock = NSLock()
        private var fields: [String: [String: JSONValue]] = [:]
        func value(_ blob: String) -> [String: JSONValue]? { lock.withLock { fields[blob] } }
        func keep(_ value: [String: JSONValue], for blob: String) {
            lock.withLock {
                if fields.count >= 32 { fields.removeAll() }
                fields[blob] = value
            }
        }
    }
}
#endif
