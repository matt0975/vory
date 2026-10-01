import SwiftUI
import VoryCore
import WidgetKit

// Compiled into both widget extensions: the iPhone one (home-screen + lock-screen families) and
// the watch one (complications). Everything draws from `WidgetSnapshot`, which the running app
// writes into the shared Keychain group; the provider also refreshes the session list itself
// when the snapshot is stale and credentials are available.

struct UncheckedSendable<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: WidgetSnapshot(gatewayName: "Hermes", connectionID: "", profile: "default", needsAttention: 1,
                                                             chats: [.init(id: "1", title: "Disk cleanup on the log host", profile: "default", lastActive: Date().timeIntervalSince1970, running: true, needsYou: true)],
                                                             contextPercent: 42))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview ? placeholder(in: context).snapshot : Self.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // WidgetKit's completion is not Sendable; it is safe to call from the task once.
        let done = UncheckedSendable(completion)
        Task {
            let snap = await Self.loadRefreshing()
            let entry = SnapshotEntry(date: Date(), snapshot: snap)
            done.value(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }

    static func load() -> WidgetSnapshot? {
        Keychain.accessGroup = Keychain.sharedGroupFromBundle()
        return WidgetSnapshot.load()
    }

    /// Snapshot as written by the app, refreshed from the gateway when it is older than ten
    /// minutes and a saved gateway exists. Network failures just keep the last snapshot.
    static func loadRefreshing() async -> WidgetSnapshot? {
        guard var snap = load() else { return nil }
        guard Date().timeIntervalSince(snap.updatedAt) > 600 else { return snap }
        // ConnectionStore is main-actor; read what we need there and hand back plain values.
        let wanted = UUID(uuidString: snap.connectionID)
        let creds: (GatewayConnection, GatewaySecrets)? = await MainActor.run {
            let store = ConnectionStore()
            guard let c = wanted.flatMap({ store.connection(id: $0) }) ?? store.active else { return nil }
            return (c, store.secrets(for: c.id))
        }
        guard let (conn, secrets) = creds else { return snap }
        let api = HermesAPI(gateway: conn.gateway, signer: RequestSigner(authMode: conn.authMode, secrets: secrets))
        if let r: SessionListResponse = try? await api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "8")], profile: snap.profile) {
            let needs = Set(snap.chats.filter(\.needsYou).map(\.id))
            snap.chats = r.sessions.map { s in
                WidgetSnapshot.Chat(id: s.id, title: s.displayTitle, profile: s.profile ?? snap.profile, lastActive: s.lastActive, running: s.isActive ?? false, needsYou: needs.contains(s.id))
            }
            snap.updatedAt = Date()
            // The gateway answered, so it is reachable even if the app has no socket open.
            snap.connected = true
            snap.save()
        }
        // The overview numbers refresh on their own, every half hour the widget is scheduled,
        // so the Overview widget stays current without the app being opened.
        if snap.usage.map({ Date().timeIntervalSince($0.updatedAt) > 1800 }) ?? true,
           let a: UsageAnalytics = try? await api.get("/api/analytics/usage", query: [URLQueryItem(name: "days", value: "91")], profile: snap.profile) {
            let list: SessionListResponse? = try? await api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "100")], profile: snap.profile)
            snap.usage = WidgetSnapshot.Usage.make(analytics: a, sessions: list?.sessions, previous: snap.usage)
            snap.save()
        }
        return snap
    }
}

// MARK: Widgets

/// One glance at the gateway: reachable or not, how many chats are working, how many need you.
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "vory.status", provider: SnapshotProvider()) { entry in
            StatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(Self.tapURL(entry))
        }
        .configurationDisplayName("Status")
        .description("Gateway health, chats at work and chats that need you.")
        .supportedFamilies(Self.families)
    }

    static var families: [WidgetFamily] {
        #if os(watchOS)
        [.accessoryRectangular]
        #else
        [.systemSmall, .systemMedium, .accessoryRectangular]
        #endif
    }

    /// Where a tap lands. On the watch every complication opens the Activity page (what needs
    /// you, what is working); on the phone the widget opens the chat that needs you, else the list.
    static func tapURL(_ entry: SnapshotEntry, prefer: WidgetSnapshot.Chat? = nil) -> URL? {
        #if os(watchOS)
        return URL(string: "vory://activity")
        #else
        let chat = entry.snapshot?.attentionChat ?? prefer
        return chat.map { URL(string: "vory://chat/\($0.id)") } ?? URL(string: "vory://chats")
        #endif
    }
}

struct StatusView: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var snap: WidgetSnapshot? { entry.snapshot }
    private var working: Int { snap?.runningCount ?? 0 }
    private var needs: Int { snap?.needsAttention ?? 0 }
    private var health: WidgetSnapshot.Health { snap?.health ?? .unknown }
    private var healthColor: Color {
        switch health { case .online: .green; case .offline: .red; case .unknown: .secondary }
    }
    private var healthWord: String {
        switch health {
        case .online: "Online"
        case .offline: "Offline"
        case .unknown: snap == nil ? "Not set up" : "Last seen \(entry.date.timeIntervalSince(snap!.updatedAt) < 90 ? "just now" : RelativeDateTimeFormatter().localizedString(for: snap!.updatedAt, relativeTo: entry.date))"
        }
    }
    private var isMedium: Bool {
        #if os(watchOS)
        false
        #else
        family == .systemMedium
        #endif
    }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(healthColor).frame(width: 7, height: 7)
                    Text(snap?.gatewayName ?? "Vory").font(.headline).lineLimit(1).widgetAccentable()
                }
                Text(healthWord).font(.caption2).foregroundStyle(.secondary)
                Text("\(working) working · \(needs) need you").font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(healthColor).frame(width: 9, height: 9)
                    Text(snap?.gatewayName ?? "Vory").font(.headline).lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(healthWord).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    counter(working, "working", "ellipsis.message.fill", tint: .green)
                    counter(needs, "need you", "exclamationmark.bubble.fill", tint: .orange)
                    if isMedium { counter(snap?.chats.count ?? 0, "recent", "bubble.left", tint: .secondary) }
                }
                if isMedium, let chats = snap?.chats.filter({ $0.running || $0.needsYou }).prefix(3), !chats.isEmpty {
                    Divider()
                    ForEach(Array(chats)) { c in
                        HStack(spacing: 6) {
                            Circle().fill(c.needsYou ? Color.orange : Color.green).frame(width: 6, height: 6)
                            Text(c.title).font(.caption).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(c.profile).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func counter(_ n: Int, _ label: String, _ symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.caption2).foregroundStyle(n == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                Text("\(n)").font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit().contentTransition(.numericText())
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Approvals waiting for you. The one to put on a watch face.
struct AttentionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "vory.attention", provider: SnapshotProvider()) { entry in
            AttentionView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(StatusWidget.tapURL(entry))
        }
        .configurationDisplayName("Needs you")
        .description("Approvals and questions waiting for an answer.")
        .supportedFamilies(Self.families)
    }

    static var families: [WidgetFamily] {
        #if os(watchOS)
        [.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner]
        #else
        [.accessoryCircular, .accessoryRectangular, .accessoryInline, .systemSmall]
        #endif
    }
}

struct AttentionView: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var count: Int { entry.snapshot?.needsAttention ?? 0 }
    private var chat: WidgetSnapshot.Chat? { entry.snapshot?.attentionChat }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(count == 0 ? "Hermes: nothing waiting" : "\(count) waiting · \(chat?.title ?? "")", systemImage: count == 0 ? "checkmark.circle" : "exclamationmark.bubble.fill")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: count == 0 ? "checkmark" : "exclamationmark.bubble.fill").font(.system(size: 14, weight: .semibold))
                    Text(count == 0 ? "OK" : "\(count)").font(.system(size: 16, weight: .bold, design: .rounded))
                }
            }
            .widgetAccentable()
        #if os(watchOS)
        case .accessoryCorner:
            Text(count == 0 ? "✓" : "\(count)").font(.title3.weight(.bold))
                .widgetLabel { Text(count == 0 ? "Hermes" : (chat?.profile ?? "Hermes")) }
                .widgetAccentable()
        #endif
        default:
            VStack(alignment: .leading, spacing: 3) {
                Label(count == 0 ? "Nothing waiting" : "\(count) need\(count == 1 ? "s" : "") you", systemImage: count == 0 ? "checkmark.circle" : "exclamationmark.bubble.fill")
                    .font(.headline).widgetAccentable()
                if let chat {
                    Text(chat.title).font(.caption).lineLimit(2)
                    Text(chat.profile).font(.caption2).foregroundStyle(.secondary)
                } else if let g = entry.snapshot?.gatewayName {
                    Text(g).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Open Vory to connect").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

/// The chat the agent is working in right now, or the most recent one.
struct ActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "vory.activity", provider: SnapshotProvider()) { entry in
            ActivityView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(StatusWidget.tapURL(entry, prefer: entry.snapshot?.activeChat ?? entry.snapshot?.chats.first))
        }
        .configurationDisplayName("Current chat")
        .description("What the agent is working on, or the last chat.")
        .supportedFamilies(AttentionWidget.families.filter { $0 != .accessoryCircular } + Self.homeFamilies)
    }
    static var homeFamilies: [WidgetFamily] {
        #if os(watchOS)
        []
        #else
        [.systemMedium]
        #endif
    }
}

struct ActivityView: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var chat: WidgetSnapshot.Chat? { entry.snapshot?.activeChat ?? entry.snapshot?.chats.first }
    private var isMedium: Bool {
        #if os(watchOS)
        false
        #else
        family == .systemMedium
        #endif
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let chat { Label(chat.running ? "Working: \(chat.title)" : chat.title, systemImage: chat.running ? "ellipsis.message.fill" : "bubble.left") }
            else { Label("Hermes", systemImage: "bubble.left") }
        #if os(watchOS)
        case .accessoryCorner:
            Image(systemName: chat?.running == true ? "ellipsis.message.fill" : "bubble.left").font(.title3)
                .widgetLabel { Text(chat?.title ?? "Hermes") }
                .widgetAccentable()
        #endif
        default:
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: chat?.running == true ? "ellipsis.message.fill" : "bubble.left").widgetAccentable()
                    Text(chat?.running == true ? "Working" : "Last chat").font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    if let p = entry.snapshot?.contextPercent { Text("\(p)%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Text(chat?.title ?? "No chats yet").font(.headline).lineLimit(isMedium ? 2 : 1)
                if let chat {
                    HStack(spacing: 6) {
                        Text(chat.profile).font(.caption2).foregroundStyle(.secondary)
                        if let t = chat.lastActive { Text(Date(timeIntervalSince1970: t), style: .relative).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                if isMedium, let more = entry.snapshot?.chats.dropFirst().prefix(3), !more.isEmpty {
                    Divider()
                    ForEach(Array(more)) { c in
                        HStack(spacing: 6) {
                            Circle().fill(c.needsYou ? Color.orange : (c.running ? Color.green : Color.secondary)).frame(width: 6, height: 6)
                            Text(c.title).font(.caption).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

/// Context-window fill of the active chat as a gauge.
struct ContextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "vory.context", provider: SnapshotProvider()) { entry in
            ContextView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "vory://chats"))
        }
        .configurationDisplayName("Context")
        .description("How full the current chat's context window is.")
        .supportedFamilies([.accessoryCircular, .accessoryInline] + Self.corner)
    }
    static var corner: [WidgetFamily] {
        #if os(watchOS)
        [.accessoryCorner]
        #else
        []
        #endif
    }
}

struct ContextView: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family
    private var pct: Int? { entry.snapshot?.contextPercent }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(pct.map { "Context \($0)%" } ?? "Context —", systemImage: "gauge.with.dots.needle.33percent")
        #if os(watchOS)
        case .accessoryCorner:
            Text(pct.map { "\($0)%" } ?? "—").font(.title3.weight(.semibold))
                .widgetCurvesContent()
                .widgetLabel { ProgressView(value: Double(pct ?? 0), total: 100) }
                .widgetAccentable()
        #endif
        default:
            Gauge(value: Double(pct ?? 0), in: 0...100) {
                Image(systemName: "text.word.spacing")
            } currentValueLabel: {
                Text(pct.map { "\($0)" } ?? "—").font(.system(.caption, design: .rounded).weight(.bold))
            }
            .gaugeStyle(.accessoryCircular)
            .widgetAccentable()
        }
    }
}


// MARK: Overview

/// The Home tab's numbers on the Home Screen, the Lock Screen and the watch: sessions and tokens
/// for the week and the month, and the activity blocks. Refreshes itself from the gateway.
struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "vory.overview", provider: SnapshotProvider()) { entry in
            OverviewView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "vory://home"))
        }
        .configurationDisplayName("Overview")
        .description("Sessions and tokens this week and this month, with your activity blocks.")
        .supportedFamilies(Self.families)
    }

    static var families: [WidgetFamily] {
        #if os(watchOS)
        [.accessoryRectangular, .accessoryCircular, .accessoryInline, .accessoryCorner]
        #else
        [.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline]
        #endif
    }
}

struct OverviewView: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family
    private var usage: WidgetSnapshot.Usage? { entry.snapshot?.usage }
    private var fmt: (Int) -> String { WidgetSnapshot.Usage.tokens }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(usage.map { "7d: \($0.sessions7) chats · \(fmt($0.tokens7)) tokens" } ?? "Open Vory to fill this in", systemImage: "chart.bar.fill")
        case .accessoryCircular:
            VStack(spacing: 0) {
                Text(usage.map { "\($0.sessions7)" } ?? "—").font(.system(.title3, design: .rounded).weight(.bold))
                Text("week").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .widgetAccentable()
        #if os(watchOS)
        case .accessoryCorner:
            Text(usage.map { "\($0.sessions7)" } ?? "—").font(.title3.weight(.semibold))
                .widgetCurvesContent()
                .widgetLabel { Text(usage.map { "\(fmt($0.tokens7)) tokens" } ?? "sessions this week") }
                .widgetAccentable()
        #endif
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("This week", systemImage: "chart.bar.fill").font(.caption.weight(.semibold)).widgetAccentable()
                if let u = usage {
                    Text("\(u.sessions7) chats · \(fmt(u.tokens7)) tokens").font(.caption)
                    Text("Month: \(u.sessions30) chats, \(u.activeDays30) active days").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Open Vory's Home tab once to fill this in.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        default:
            homeScreen
        }
    }

    #if os(iOS)
    private var isMedium: Bool { family == .systemMedium }
    #else
    private var isMedium: Bool { false }
    #endif

    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(isMedium ? "Overview · 30 days" : "This week", systemImage: "chart.bar.fill").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let u = usage, isMedium, let m = u.topModel { Text(m).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
            if let u = usage {
                if isMedium {
                    HStack(spacing: 10) {
                        stat("Sessions", "\(u.sessions30)")
                        stat("Messages", u.messages30.map { "\($0)" } ?? "—")
                        stat("Tokens", fmt(u.tokens30))
                        stat("Active days", "\(u.activeDays30)")
                    }
                } else {
                    HStack(spacing: 10) {
                        stat("Sessions", "\(u.sessions7)")
                        stat("Tokens", fmt(u.tokens7))
                    }
                }
                UsageBlocks(days: u.days, weeks: isMedium ? 13 : 6)
            } else {
                Text("Open Vory's Home tab once to fill this in.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One column per week, one row per weekday, darker for busier days.
struct UsageBlocks: View {
    var days: [WidgetSnapshot.Usage.Day]
    var weeks: Int

    private var counts: [Date: Int] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return Dictionary(days.compactMap { d in f.date(from: d.day).map { (cal.startOfDay(for: $0), d.sessions) } }, uniquingKeysWith: +)
    }

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let daysBack = weeks * 7 - (7 - weekday)
        let start = cal.date(byAdding: .day, value: -(daysBack - 1), to: today)!
        let counts = counts
        let peak = max(1, counts.values.max() ?? 1)
        HStack(alignment: .top, spacing: 2) {
            ForEach(0..<weeks, id: \.self) { w in
                VStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { d in
                        let day = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                        let n = counts[day] ?? 0
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(day > today ? Color.clear : (n == 0 ? Color.primary.opacity(0.08) : Color.accentColor.opacity(0.3 + 0.7 * min(1, Double(n) / Double(peak)))))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
        .widgetAccentable()
    }
}
