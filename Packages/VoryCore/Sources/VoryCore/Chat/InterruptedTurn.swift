import Foundation

/// A turn the gateway ended before the bot finished. It is stored as the bot's own message,
/// "Operation interrupted." or "Operation interrupted: <what it was doing>", whether Stop was
/// pressed or the gateway gave up on a chat no app was connected to, so the text alone cannot
/// say which. The chat shows it as a card that can explain both.
public struct InterruptedTurn: Hashable, Sendable {
    /// What the bot was doing when it was stopped, when the gateway said ("waiting for model
    /// response", "retrying API call after error"); nil for the bare sentence.
    public var doing: String?

    /// Why the turn ended, when the app can tell.
    public enum Cause: String, Hashable, Sendable {
        /// The app was not connected (suspended, asleep, offline) and the gateway stopped waiting.
        case appWasAway
        /// Stop was pressed here.
        case stopped
    }

    public init(doing: String? = nil) { self.doing = doing }

    private static let marker = "operation interrupted"

    /// Only a message that is nothing but the gateway's sentence: a reply that merely quotes it
    /// (a bot explaining the error, say) stays an ordinary bubble.
    public static func parse(_ text: String) -> InterruptedTurn? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 240, t.lowercased().hasPrefix(marker), !t.contains("\n") else { return nil }
        var rest = String(t.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty || rest == "." { return InterruptedTurn() }
        // "…: waiting for model response (12.4s elapsed)." or "… during retry (rate limit, attempt 2/5)."
        guard rest.hasPrefix(":") || rest.lowercased().hasPrefix("during ") else { return nil }
        if rest.hasPrefix(":") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        while rest.hasSuffix(".") { rest.removeLast() }
        return InterruptedTurn(doing: rest.isEmpty ? nil : rest)
    }
}

/// How long the gateway keeps a chat that no app is connected to before it stops the turn
/// (`dashboard.ws_orphan_reap_grace_s`, seconds; the gateway's own default is 20 and 0 means
/// it never stops one). Read from and written to the gateway's config; it takes effect when
/// the dashboard restarts.
public struct AwayGrace: Hashable, Sendable {
    public static let configPath = "dashboard.ws_orphan_reap_grace_s"
    public static let envKey = "HERMES_TUI_WS_ORPHAN_REAP_GRACE_S"
    public static let gatewayDefault: Double = 20

    /// Seconds; nil when the config does not set it (the gateway's default applies).
    public var seconds: Double?
    /// Set in the gateway's environment, which wins over the config.
    public var envOverride = false

    public init(seconds: Double? = nil, envOverride: Bool = false) {
        self.seconds = seconds
        self.envOverride = envOverride
    }

    public var effective: Double { seconds ?? Self.gatewayDefault }
    /// Short enough that a phone going to the background can lose a long turn on an older Hermes.
    public var isShort: Bool { effective > 0 && effective < 600 }

    /// The choices offered, in seconds; 0 is "never stop it".
    public static let choices: [Double] = [20, 600, 3600, 8 * 3600, 0]

    public static func label(_ seconds: Double) -> String {
        switch seconds {
        case 0: return "Never stop it"
        case ..<60: return "\(Int(seconds)) seconds"
        case ..<3600: return "\(Int(seconds / 60)) minutes"
        case 3600: return "1 hour"
        default: return "\(Int(seconds / 3600)) hours"
        }
    }

    /// From `GET /api/config` (the value may sit under `config`).
    public static func read(config: JSONValue) -> AwayGrace {
        let root = config["config"] ?? config
        let raw = root["dashboard"]?["ws_orphan_reap_grace_s"]
        let n = raw?.doubleValue ?? raw?.stringValue.flatMap(Double.init)
        return AwayGrace(seconds: n.map { max(0, $0) })
    }

    /// The body for `PUT /api/config`.
    public static func writeBody(seconds: Double) -> JSONValue {
        .object(["config": .object(["dashboard": .object(["ws_orphan_reap_grace_s": .number(seconds)])])])
    }
}
