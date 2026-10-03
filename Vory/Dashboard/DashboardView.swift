import FoundationModels
import SwiftUI
import VoryCore
import WidgetKit

/// Home: a greeting, the month in numbers and blocks, which bots are busy, the chats to pick
/// back up, and what changed since the last visit (summed up on the phone by the on-device
/// model when there is one). The cards, their order and their size come from `HomeLayout`;
/// the numbers from the gateway's analytics endpoint; the sessions from its chat list.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("user.name") private var userName = ""
    @AppStorage("dashboard.range") private var rangeDays = 30
    @AppStorage("dashboard.lastVisit") private var lastVisit: Double = 0
    @AppStorage("dashboard.greeting") private var cachedGreeting = ""
    @AppStorage("dashboard.greetingKey") private var cachedGreetingKey = ""
    @AppStorage(ChatSummarizer.titlesKey) private var aiOn = ChatSummarizer.titlesOn
    @AppStorage(HomeLayout.storageKey) private var layoutRaw = ""
    @State private var usage: UsageAnalytics?
    @AppStorage(HomeLayout.allBotsKey) private var homeAllBots = false
    @State private var sessions: [StoredSession] = []
    @State private var error: String?
    @State private var loading = false
    @State private var sinceSummary: String?
    @State private var summarizing = false
    @State private var visitStart: Double = 0

    private var runtime: GatewayRuntime? { model.runtime }
    private var layout: HomeLayout { HomeLayout.parse(layoutRaw) }
    private func update(_ change: (inout HomeLayout) -> Void) { var l = layout; change(&l); layoutRaw = l.encoded }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                // Home opens first on a restored device: the sign-in it still owes is asked for here too.
                if let waiting = model.needsSignIn { GatewaySignInBanner(connection: waiting) }
                if let runtime, !runtime.needsAttention.isEmpty { needsYou(runtime) }
                ForEach(layout.items) { item in
                    editableCard(item)
                        // While Home is being edited the press is a drag, so the menu stands
                        // aside; otherwise a long press races the drag and the menu won.
                        .contextMenu(menuItems: { if !editingHome { cardMenu(item) } })
                }
                if let error, model.needsSignIn == nil { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 4) }
                // Edit: the cards can be dragged onto one another until Done; Settings has the
                // sizes, the hidden cards, the name and the opening tab.
                HStack(spacing: 10) {
                    Button { withAnimation(.snappy) { editingHome.toggle() } } label: {
                        Label(editingHome ? "Done" : "Edit Home", systemImage: editingHome ? "checkmark" : "arrow.up.arrow.down").font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered).tint(editingHome ? Color.vory : .secondary)
                    NavigationLink { HomeSettingsView() } label: {
                        Label("Settings", systemImage: "slider.horizontal.3").font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered).tint(.secondary)
                }
                .padding(.top, 4)
                if editingHome {
                    Text("Press, hold and drag a card onto another to put it there.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
            .animation(.snappy, value: layoutRaw)
            #if os(macOS)
            // A reading width in the middle of the window, not cards the width of the screen.
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            #endif
        }
        .scrollPosition($scrollPosition)
        // A tap on the Home tab while it is in front brings the page back to its top, as the
        // other tabs' lists do (a tester asked for it).
        .onChange(of: model.tabReselected[.dashboard]) { _, _ in withAnimation(.snappy) { scrollPosition.scrollTo(edge: .top) } }
        .untitledPage()
        .alert(tileNote?.title ?? "", isPresented: Binding(get: { tileNote != nil }, set: { if !$0 { tileNote = nil } })) {
            Button("OK") { tileNote = nil }
        } message: { Text(tileNote?.text ?? "") }
        .reloadable { await Task { await load() }.value }
        .task(id: "\(runtime?.connection.id.uuidString ?? "")|\(runtime?.selectedProfile ?? "")|\(rangeDays)|\(homeAllBots)") { await load() }
        .onAppear { visitStart = Date().timeIntervalSince1970 }
        .onDisappear { lastVisit = max(lastVisit, visitStart); editingHome = false }
        .navigationDestination(for: ChatRoute.self) { route in ConversationView(route: route) }
    }

    @State private var editingHome = false
    @State private var scrollPosition = ScrollPosition()

    @ViewBuilder private func cardMenu(_ item: HomeLayout.Item) -> some View {
                            Section("Size") {
                                Button { update { $0.set(item.card, size: .compact) } } label: { Label(item.card.sizeWords.compact, systemImage: item.size == .compact ? "checkmark" : "rectangle.compress.vertical") }
                                Button { update { $0.set(item.card, size: .full) } } label: { Label(item.card.sizeWords.full, systemImage: item.size == .full ? "checkmark" : "rectangle.expand.vertical") }
                            }
                            if item.card == .pickUp || item.card == .since {
                                Section("Chats from") {
                                    Button { homeAllBots = false } label: { Label("This bot", systemImage: homeAllBots ? "person" : "checkmark") }
                                    Button { homeAllBots = true } label: { Label("All bots", systemImage: homeAllBots ? "checkmark" : "person.2") }
                                }
                            }
                            Button(role: .destructive) { withAnimation(.snappy) { update { $0.remove(item.card) } } } label: { Label("Hide from Home", systemImage: "eye.slash") }
    }

    /// The card, and while Home is being edited, a drag source and a drop target with a dashed
    /// edge to say so.
    @ViewBuilder private func editableCard(_ item: HomeLayout.Item) -> some View {
        if editingHome {
            card(item)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.vory.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                .draggable(item.card.rawValue) {
                    Label(item.card.title, systemImage: item.card.symbol).font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                }
                .dropDestination(for: String.self) { dropped, _ in
                    guard let raw = dropped.first, let moved = HomeCard(rawValue: raw), moved != item.card else { return false }
                    withAnimation(.snappy) {
                        update { l in
                            guard let from = l.items.firstIndex(where: { $0.card == moved }), let to = l.items.firstIndex(where: { $0.card == item.card }) else { return }
                            l.items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                        }
                    }
                    return true
                }
        } else {
            card(item).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func card(_ item: HomeLayout.Item) -> some View {
        switch item.card {
        case .overview: overviewCard(full: item.size == .full)
        case .bots: botsCard(full: item.size == .full)
        case .pickUp: pickUpCard(full: item.size == .full)
        case .since: sinceCard(full: item.size == .full)
        }
    }

    private func cardBackground<V: View>(_ v: V) -> some View {
        #if os(macOS)
        // The window is already white; the card is a faint fill with a hairline edge.
        v.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        #else
        v.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        #endif
    }

    // MARK: Greeting

    private var dayPart: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<22: return "evening"
        default: return "night"
        }
    }

    private var plainGreeting: String {
        let who = userName.trimmingCharacters(in: .whitespaces)
        let name = who.isEmpty ? "" : ", \(who)"
        switch dayPart {
        case "morning": return "Good morning\(name)"
        case "afternoon": return "Good afternoon\(name)"
        case "evening": return "Good evening\(name)"
        default: return who.isEmpty ? "Still up?" : "Still up, \(who)?"
        }
    }

    private var greeting: String {
        let key = "\(dayPart)|\(userName)|\(Calendar.current.component(.day, from: Date()))"
        return cachedGreetingKey == key && !cachedGreeting.isEmpty ? cachedGreeting : plainGreeting
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                BotFaceView(spec: AboutView.voryBot, size: 34, active: true)
                Text(greeting).font(.title.weight(.bold)).lineLimit(2).minimumScaleFactor(0.8)
            }
            Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day()).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        .task(id: "\(dayPart)|\(userName)") { await freshenGreeting() }
    }

    /// A one-line greeting from the on-device model, once per part of the day; the plain one otherwise.
    private func freshenGreeting() async {
        let key = "\(dayPart)|\(userName)|\(Calendar.current.component(.day, from: Date()))"
        guard cachedGreetingKey != key, aiOn, ChatSummarizer.isAvailable else { return }
        let who = userName.trimmingCharacters(in: .whitespaces)
        do {
            let ai = LanguageModelSession(instructions: "You write one short, warm greeting for the home screen of an app. At most eight words. No emoji, no exclamation marks, no quotes. Use the person's name if given.")
            let line = try await ai.respond(to: "It is \(dayPart). \(who.isEmpty ? "No name is known." : "The person's name is \(who).") Write the greeting.").content
                .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
            if (3...60).contains(line.count), !line.contains("\n") { cachedGreeting = line; cachedGreetingKey = key }
        } catch {}
    }

    // MARK: Needs you

    private func needsYou(_ rt: GatewayRuntime) -> some View {
        let n = rt.needsAttention.count
        return Button { model.selectedTab = .chats } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.red)
                Text(n == 1 ? "One chat needs you" : "\(n) chats need you").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Overview

    private var periodSessions: [StoredSession] {
        let cutoff = Date().timeIntervalSince1970 - Double(rangeDays) * 86400
        return sessions.filter { ($0.startedAt ?? $0.lastActive ?? 0) >= cutoff }
    }

    private func overviewCard(full: Bool) -> some View {
        cardBackground(VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Overview").font(.headline)
                Spacer()
                GlassSegments(options: [(7, "7d"), (30, "30d"), (90, "90d")], selection: $rangeDays)
                    .accessibilityLabel("Range")
            }
            let t = usage?.totals
            let tokens = (t?.totalInput ?? 0) + (t?.totalOutput ?? 0) + (t?.totalCacheRead ?? 0)
            let messages = periodSessions.reduce(0) { $0 + ($1.messageCount ?? 0) }
            let activeDays = Set((usage?.daily ?? []).filter { ($0.sessions ?? 0) > 0 }.map(\.day)).count
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                tile("Sessions", t.map { Format.count($0.totalSessions ?? 0) } ?? Format.count(periodSessions.count))
                tile("Messages", Format.count(messages))
                tile("Tokens", tokens > 0 ? Format.tokens(tokens) : "–")
                tile("Active days", "\(activeDays > 0 ? activeDays : Set(periodSessions.compactMap { $0.startedAt.map { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: $0)) } }).count)")
                tile("Peak hour", peakHour ?? "–")
                tile("Top model", favoriteModel ?? "–")
            }
            if full {
                ActivityGrid(daily: usage?.daily ?? [], sessions: sessions, weeks: 13)
                    .contentShape(.rect)
                    .onTapGesture { tileNote = ("Activity", "One block per day for the last thirteen weeks, a column per week with Monday at the top. The more chats started that day, the brighter the block.") }
                if let cost = t?.totalEstimatedCost, cost > 0.005 {
                    Text("About \(cost, format: .currency(code: "USD").precision(.fractionLength(2))) estimated for the period, as the gateway counts it.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if usage == nil, !loading {
                    Text("Token counts need a gateway with the analytics API; sessions and messages come from the chat list.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        })
    }

    /// What each tile counts, for a tap on it.
    private static let tileNotes: [String: String] = [
        "Sessions": "Chats started in the period, as the gateway's analytics count them. On a gateway without the analytics API it is the chats in the list instead.",
        "Messages": "Messages sent and received across the chats of the period.",
        "Tokens": "Input, output and cached tokens the models used in the period, added up.",
        "Active days": "Days in the period with at least one chat started.",
        "Peak hour": "The hour of the day your chats most often start.",
        "Top model": "The model used by the most chats in the period.",
    ]
    @State private var tileNote: (title: String, text: String)?

    private func tile(_ title: String, _ value: String) -> some View {
        // A number sits on one line; a name (the model) may take two, in a smaller face.
        let isText = value.rangeOfCharacter(from: .letters) != nil && value.count > 6
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(isText ? .subheadline.weight(.semibold) : .title3.weight(.semibold).monospacedDigit())
                .lineLimit(isText ? 2 : 1).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 58, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .contentShape(.rect)
        .onTapGesture { if let t = Self.tileNotes[title] { tileNote = (title, t) } }
        .accessibilityHint("Tap for what this counts")
        #if os(macOS)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        #else
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        #endif
    }

    private var peakHour: String? {
        let hours = periodSessions.compactMap { $0.startedAt.map { Calendar.current.component(.hour, from: Date(timeIntervalSince1970: $0)) } }
        guard !hours.isEmpty else { return nil }
        let counts = Dictionary(grouping: hours) { $0 }.mapValues(\.count)
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        var c = DateComponents(); c.hour = best
        return Calendar.current.date(from: c).map { $0.formatted(.dateTime.hour()) }
    }

    private var favoriteModel: String? {
        if let m = usage?.byModel?.max(by: { ($0.inputTokens ?? 0) + ($0.outputTokens ?? 0) < ($1.inputTokens ?? 0) + ($1.outputTokens ?? 0) })?.model, !m.isEmpty {
            return m.split(separator: "/").last.map(String.init)
        }
        let models = periodSessions.compactMap(\.model).filter { !$0.isEmpty }
        guard !models.isEmpty else { return nil }
        let counts = Dictionary(grouping: models) { $0 }.mapValues(\.count)
        return counts.max(by: { $0.value < $1.value })?.key.split(separator: "/").last.map(String.init)
    }

    // MARK: Bots

    private func botStatus(_ rt: GatewayRuntime, _ p: ProfileInfo) -> (working: ChatSession?, waiting: Bool) {
        let chats = rt.chats.filter { $0.profileName == p.name }
        return (chats.first { $0.isRunning }, chats.contains { $0.needsAttention })
    }

    private func botsCard(full: Bool) -> some View {
        cardBackground(VStack(alignment: .leading, spacing: 10) {
            Text("Bots").font(.headline)
            if let rt = runtime, !rt.profiles.isEmpty {
                if full {
                    ForEach(rt.profiles) { p in
                        let (working, waiting) = botStatus(rt, p)
                        Button { rt.selectedProfile = p.name; model.selectedTab = .chats } label: {
                            HStack(spacing: 12) {
                                BotAvatar(profile: p.name, size: 36, active: working != nil)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.label).font(.body.weight(.medium))
                                    Text(waiting ? "Needs you" : (working.map { ChatGoals.shared.goal(for: $0.storedID) ?? $0.statusLine ?? "Working…" } ?? "Idle"))
                                        .font(.caption).foregroundStyle(waiting ? .red : (working != nil ? .blue : .secondary)).lineLimit(1)
                                }
                                Spacer()
                                Circle().fill(waiting ? Color.red : (working != nil ? Color.blue : Color.secondary.opacity(0.4))).frame(width: 8, height: 8)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(rt.profiles) { p in
                                let (working, waiting) = botStatus(rt, p)
                                Button { rt.selectedProfile = p.name; model.selectedTab = .chats } label: {
                                    VStack(spacing: 4) {
                                        ZStack(alignment: .topTrailing) {
                                            BotAvatar(profile: p.name, size: 44, active: working != nil)
                                            if waiting || working != nil {
                                                Circle().fill(waiting ? Color.red : Color.blue).frame(width: 10, height: 10).offset(x: 2, y: -2)
                                            }
                                        }
                                        Text(p.label).font(.caption2).lineLimit(1).frame(width: 60)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(p.label): \(waiting ? "needs you" : (working != nil ? "working" : "idle"))")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                Text("Connect a gateway to see your bots.").font(.subheadline).foregroundStyle(.secondary)
            }
        })
    }

    // MARK: Pick up

    private func recent(_ n: Int) -> [StoredSession] {
        Array(sessions.filter { $0.archived != true }.sorted { ($0.lastActive ?? 0) > ($1.lastActive ?? 0) }.prefix(n))
    }

    private func pickUpCard(full: Bool) -> some View {
        let list = recent(full ? 5 : 3)
        return cardBackground(VStack(alignment: .leading, spacing: 10) {
            Text("Pick up where you left off").font(.headline)
            if list.isEmpty {
                Text(loading ? "Loading…" : (error == nil ? "No chats yet. Start one from the Chats tab." : "The chat list did not load. Pull down to try again.")).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(list) { s in
                NavigationLink(value: ChatRoute(storedID: s.id, title: s.displayTitle, profile: s.profile)) {
                    HStack(spacing: 10) {
                        BotAvatar(profile: s.profile ?? runtime?.selectedProfile ?? "default", size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.displayTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(s.preview ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let d = s.lastDate { Text(d, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary) }
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        })
    }

    // MARK: Since you were here

    /// The last visit, or the last day when there is none yet: the card has something to say
    /// from the first open.
    private var sinceStamp: Double { lastVisit > 0 ? lastVisit : Date().timeIntervalSince1970 - 86400 }
    private var changedSinceVisit: [StoredSession] {
        sessions.filter { ($0.lastActive ?? 0) > sinceStamp }.sorted { ($0.lastActive ?? 0) > ($1.lastActive ?? 0) }
    }

    private func sinceCard(full: Bool) -> some View {
        cardBackground(VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(lastVisit > 0 ? "Since you were here" : "The last day").font(.headline)
                Spacer()
                if summarizing { ProgressView().controlSize(.small) }
                else { Button { Task { await summarizeSince(force: true) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            if let sinceSummary {
                Text(sinceSummary).font(.subheadline).lineLimit(full ? nil : 3)
                Text("Summed up on \(DeviceWords.this).").font(.caption2).foregroundStyle(.tertiary)
            } else if changedSinceVisit.isEmpty, !loading {
                Text(lastVisit > 0 ? "Nothing new since \(Date(timeIntervalSince1970: lastVisit), format: .relative(presentation: .named))." : "Nothing happened in the last day.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(changedSinceVisit.prefix(full ? 5 : 3)) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(.secondary).frame(width: 5, height: 5).padding(.top, 6)
                        Text("\(s.displayTitle): \(s.preview ?? "updated")").font(.subheadline).lineLimit(2)
                    }
                }
            }
        })
        .task(id: changedSinceVisit.map(\.id).joined()) { await summarizeSince(force: false) }
    }

    private func summarizeSince(force: Bool) async {
        let changed = changedSinceVisit
        guard !changed.isEmpty, aiOn, ChatSummarizer.isAvailable, !summarizing else { if changed.isEmpty { sinceSummary = nil }; return }
        if !force, sinceSummary != nil { return }
        summarizing = true; defer { summarizing = false }
        let lines = changed.prefix(8).map { "- \($0.displayTitle) (\($0.profile ?? "bot")): \(($0.preview ?? "").prefix(200))" }
        let running = runtime?.chats.filter { $0.isRunning }.map { "- \($0.title) is still working: \($0.statusLine ?? "thinking")" } ?? []
        do {
            let ai = LanguageModelSession(instructions: "You sum up, for the owner of some AI assistants, what the assistants did while the owner was away. Two or three short sentences, plain words, no bullet points, no greeting. Name the chats. Do not say it is a summary.")
            let text = try await ai.respond(to: "Chats that changed since the last visit:\n" + (lines + running).joined(separator: "\n")).content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { sinceSummary = text }
        } catch {}
    }

    // MARK: Data

    /// The recent chats: the current bot's page, or one page per bot merged, each row tagged
    /// with its bot so the avatars and the chat routes know whose it is.
    private static func chats(_ rt: GatewayRuntime, allBots: Bool) async throws -> [StoredSession] {
        let query = [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: allBots ? "50" : "100")]
        guard allBots, rt.profiles.count > 1 else {
            let r: SessionListResponse = try await rt.api.get("/api/sessions", query: query, profile: rt.selectedProfile)
            return r.sessions
        }
        return try await withThrowingTaskGroup(of: [StoredSession].self) { group in
            for p in rt.profiles.map(\.name) {
                group.addTask {
                    let r: SessionListResponse = try await rt.api.get("/api/sessions", query: query, profile: p)
                    return r.sessions.map { var s = $0; if s.profile == nil || s.profile!.isEmpty { s.profile = p }; return s }
                }
            }
            var all: [StoredSession] = []
            for try await part in group { all += part }
            return all
        }
    }

    /// The month's numbers, or nil with `keep` when the fetch was cancelled or never reached the
    /// gateway: a refresh pulled and let go used to blank the card until the next launch, so
    /// those keep the numbers the card has; a gateway that answers without the analytics API
    /// clears them, which is what the footer explains.
    private static func usage(_ rt: GatewayRuntime, days: Int) async -> (UsageAnalytics?, keep: Bool) {
        do {
            let a: UsageAnalytics = try await rt.api.get("/api/analytics/usage", query: [URLQueryItem(name: "days", value: String(days))], profile: rt.selectedProfile)
            return (a, false)
        } catch is CancellationError { return (nil, true) }
        catch let e as URLError where e.code == .cancelled || e.code == .notConnectedToInternet || e.code == .timedOut { return (nil, true) }
        catch { return (nil, false) }
    }

    private func load() async {
        guard let rt = runtime else { return }
        loading = true; defer { loading = false }
        // The gateway caps a page at 100 (a larger ask is refused outright).
        let allBots = homeAllBots
        async let u: (UsageAnalytics?, keep: Bool) = Self.usage(rt, days: rangeDays)
        async let s: [StoredSession]? = try? Self.chats(rt, allBots: allBots)
        let (usageResult, list) = await (u, s)
        if let a = usageResult.0 { usage = a } else if !usageResult.keep { usage = nil }
        if let list { sessions = list; error = nil }
        else if sessions.isEmpty { error = "Could not load the chat list." }
        // The Overview widget and complications draw from the shared snapshot.
        if let a = usageResult.0, var snap = WidgetSnapshot.load() {
            snap.usage = WidgetSnapshot.Usage.make(analytics: a, sessions: list, previous: snap.usage)
            snap.save()
            WidgetCenter.shared.reloadTimelines(ofKind: "vory.overview")
        }
    }
}

/// The last `weeks` weeks as blocks, one column per week, one row per weekday, darker for busier
/// days (sessions started that day). Like the usage blocks in a coding terminal.
struct ActivityGrid: View {
    var daily: [UsageAnalytics.Day]
    var sessions: [StoredSession]
    var weeks: Int

    private var counts: [Date: Int] {
        let cal = Calendar.current
        var out: [Date: Int] = [:]
        if !daily.isEmpty {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
            for d in daily { if let date = f.date(from: d.day) { out[cal.startOfDay(for: date), default: 0] += d.sessions ?? 0 } }
        } else {
            for s in sessions { if let t = s.startedAt { out[cal.startOfDay(for: Date(timeIntervalSince1970: t)), default: 0] += 1 } }
        }
        return out
    }

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)   // 1 = Sunday
        let daysBack = weeks * 7 - (7 - weekday)             // the grid ends on today's column
        let start = cal.date(byAdding: .day, value: -(daysBack - 1), to: today)!
        let counts = counts
        let peak = max(1, counts.values.max() ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                            let n = counts[day] ?? 0
                            let future = day > today
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(future ? Color.clear : (n == 0 ? Color.primary.opacity(0.07) : Color.vory.opacity(0.25 + 0.75 * min(1, Double(n) / Double(peak)))))
                                .aspectRatio(1, contentMode: .fit)
                                .accessibilityLabel(future ? "" : "\(day.formatted(date: .abbreviated, time: .omitted)): \(n) sessions")
                        }
                    }
                }
            }
            HStack {
                Text(start, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("Today").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
        #if os(macOS)
        // Blocks the size of a terminal's, not of a window: at most 22 pt each.
        .frame(maxWidth: CGFloat(weeks) * 22 + CGFloat(weeks - 1) * 3, alignment: .leading)
        #endif
    }
}

enum Format {
    static func count(_ n: Int) -> String { n.formatted(.number) }
    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1000)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(n) / 1_000_000)
        default: return String(format: "%.2fB", Double(n) / 1_000_000_000)
        }
    }
}


/// A small choice drawn the way the tab bar is: labels on a glass capsule, a clear lens sliding
/// under the chosen one (the lens morphs between positions inside the container).
struct GlassSegments<T: Hashable>: View {
    var options: [(T, String)]
    @Binding var selection: T
    @Namespace private var lens

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).font(.caption.weight(.semibold))
                        .foregroundStyle(selection == option.0 ? .primary : .secondary)
                        .frame(width: 42, height: 26)
                        .contentShape(.rect)
                        .background {
                            if selection == option.0 {
                                Capsule().fill(.clear)
                                    .glassEffect(.clear.interactive(), in: .capsule)
                                    .glassEffectID("lens", in: lens)
                            }
                        }
                        .onTapGesture { withAnimation(.snappy(duration: 0.3)) { selection = option.0 } }
                        .accessibilityAddTraits(selection == option.0 ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
        }
    }
}
