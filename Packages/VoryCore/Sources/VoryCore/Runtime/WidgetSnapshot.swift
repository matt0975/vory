import Foundation

/// The little state every widget and complication draws from. Written by whichever app is
/// running (iPhone or watch) into the shared Keychain group; read by the widget extensions.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct Chat: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var profile: String
        public var lastActive: Double?
        public var running: Bool
        public var needsYou: Bool
        public init(id: String, title: String, profile: String, lastActive: Double?, running: Bool, needsYou: Bool) {
            self.id = id; self.title = title; self.profile = profile; self.lastActive = lastActive; self.running = running; self.needsYou = needsYou
        }
    }

    public var gatewayName: String
    public var connectionID: String
    public var profile: String
    public var needsAttention: Int
    public var chats: [Chat]
    public var contextPercent: Int?
    public var updatedAt: Date
    /// Whether the app's socket to the gateway was open when this was written; nil on snapshots
    /// from before the field existed, or written by a widget refresh that could not tell.
    public var connected: Bool?
    /// The Home tab's overview numbers, for the Overview widget and complications. Written by
    /// the app when Home loads and by the widget itself when it is older than half an hour.
    public var usage: Usage?

    public struct Usage: Codable, Sendable, Equatable {
        public struct Day: Codable, Sendable, Equatable {
            public var day: String      // yyyy-MM-dd, local
            public var sessions: Int
            public var tokens: Int
            public init(day: String, sessions: Int, tokens: Int) { self.day = day; self.sessions = sessions; self.tokens = tokens }
        }
        public var days: [Day]
        public var sessions7: Int
        public var sessions30: Int
        public var tokens7: Int
        public var tokens30: Int
        public var messages30: Int?
        public var activeDays30: Int
        public var peakHour: String?
        public var topModel: String?
        public var cost30: Double?
        public var updatedAt: Date

        /// From the gateway's analytics (30 days or more) and, when at hand, the chat list for
        /// the message count and the peak hour. Fields the caller cannot fill keep `previous`.
        public static func make(analytics a: UsageAnalytics, sessions: [StoredSession]?, previous: Usage? = nil) -> Usage {
            let cal = Calendar.current
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
            let today = cal.startOfDay(for: Date())
            let days = (a.daily ?? []).map { Day(day: $0.day, sessions: $0.sessions ?? 0, tokens: ($0.inputTokens ?? 0) + ($0.outputTokens ?? 0) + ($0.cacheReadTokens ?? 0)) }
            func within(_ n: Int) -> [Day] {
                let cutoff = cal.date(byAdding: .day, value: -(n - 1), to: today)!
                return days.filter { d in f.date(from: d.day).map { $0 >= cutoff } ?? false }
            }
            let d7 = within(7), d30 = within(30)
            var messages: Int? = previous?.messages30
            var peak: String? = previous?.peakHour
            if let sessions {
                let cutoff = today.timeIntervalSince1970 - 29 * 86400
                let recent = sessions.filter { ($0.startedAt ?? $0.lastActive ?? 0) >= cutoff }
                messages = recent.reduce(0) { $0 + ($1.messageCount ?? 0) }
                let hours = recent.compactMap { $0.startedAt.map { cal.component(.hour, from: Date(timeIntervalSince1970: $0)) } }
                if let best = Dictionary(grouping: hours, by: { $0 }).mapValues(\.count).max(by: { $0.value < $1.value })?.key {
                    var c = DateComponents(); c.hour = best
                    peak = cal.date(from: c).map { $0.formatted(.dateTime.hour()) }
                }
            }
            let top = (a.byModel ?? []).max { ($0.inputTokens ?? 0) + ($0.outputTokens ?? 0) < ($1.inputTokens ?? 0) + ($1.outputTokens ?? 0) }?.model
            return Usage(days: days, sessions7: d7.reduce(0) { $0 + $1.sessions }, sessions30: d30.reduce(0) { $0 + $1.sessions },
                         tokens7: d7.reduce(0) { $0 + $1.tokens }, tokens30: d30.reduce(0) { $0 + $1.tokens }, messages30: messages,
                         activeDays30: d30.filter { $0.sessions > 0 }.count, peakHour: peak,
                         topModel: top.flatMap { $0.split(separator: "/").last.map(String.init) } ?? previous?.topModel,
                         cost30: a.totals?.totalEstimatedCost, updatedAt: Date())
        }

        /// "1.2k", "3.4M".
        public static func tokens(_ n: Int) -> String {
            switch n {
            case ..<1000: return "\(n)"
            case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1000)
            case ..<1_000_000_000: return String(format: "%.1fM", Double(n) / 1_000_000)
            default: return String(format: "%.2fB", Double(n) / 1_000_000_000)
            }
        }
    }

    public init(gatewayName: String, connectionID: String, profile: String, needsAttention: Int, chats: [Chat], contextPercent: Int?, updatedAt: Date = Date(), connected: Bool? = nil, usage: Usage? = nil) {
        self.gatewayName = gatewayName; self.connectionID = connectionID; self.profile = profile
        self.needsAttention = needsAttention; self.chats = chats; self.contextPercent = contextPercent; self.updatedAt = updatedAt
        self.connected = connected; self.usage = usage
    }

    public static let account = "widget.snapshot"

    public static func load() -> WidgetSnapshot? { Keychain.getCodable(WidgetSnapshot.self, account: account) }
    public func save() { try? Keychain.setCodable(self, account: Self.account) }

    public var activeChat: Chat? { chats.first { $0.running } }
    public var attentionChat: Chat? { chats.first { $0.needsYou } }
    public var runningCount: Int { chats.filter(\.running).count }
    /// How the status widget reads the gateway: reachable, unreachable, or unknown (stale).
    public enum Health: Sendable { case online, offline, unknown }
    public var health: Health {
        // Older than an hour, the last word is not worth much either way.
        guard Date().timeIntervalSince(updatedAt) < 3600, let connected else { return .unknown }
        return connected ? .online : .offline
    }
}
