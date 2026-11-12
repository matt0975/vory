import SwiftUI
import VoryCore

extension ChatSession {
    /// The gateway's model list (`/api/model/options`), as the model menu, the model page and the
    /// composer's "/model " chooser all read it. `refresh` asks the gateway to look again. It is
    /// this chat's bot's list (the gateway lists each bot's own providers and keys), not the bot
    /// selected at the time: after a switch elsewhere, a pick sent another bot's provider to
    /// this chat.
    func modelOptions(refresh: Bool = false) async throws -> ModelOptionsResult {
        let key = modelOptionsCacheKey
        if !refresh, let cached = ModelOptionsCache.results[key] { return cached }
        let q = refresh ? [URLQueryItem(name: "refresh", value: "true")] : []
        let result: ModelOptionsResult = try await runtime.api.get("/api/model/options", query: q, profile: Self.modelOptionsProfile(chat: profile, selected: runtime.selectedProfile))
        ModelOptionsCache.results[key] = result
        return result
    }

    /// The list already fetched for this chat's bot, if any (the model menu opens with it).
    var cachedModelOptions: ModelOptionsResult? { ModelOptionsCache.results[modelOptionsCacheKey] }

    /// Fetches the list ahead of the first open of the model menu, quietly: the menu used to
    /// load it on its first open and rebuild itself while it opened (2026-10-11: "load
    /// the stuff behind the model chip so it doesn't look weird on first open").
    func warmModelOptions() async {
        guard cachedModelOptions == nil else { return }
        _ = try? await modelOptions()
    }

    private var modelOptionsCacheKey: String {
        "\(ObjectIdentifier(runtime).hashValue)|\(Self.modelOptionsProfile(chat: profile, selected: runtime.selectedProfile) ?? "")"
    }

    /// The bot whose model list a chat reads: its own, or the selected one for a chat that has
    /// none recorded.
    nonisolated static func modelOptionsProfile(chat: String?, selected: String?) -> String? {
        chat ?? selected
    }
}

/// The model lists fetched this run, one per gateway and bot, shared by the model menu, the
/// model page and the "/model " chooser. "Refresh models" asks the gateway again.
@MainActor enum ModelOptionsCache {
    static var results: [String: ModelOptionsResult] = [:]
}

extension ModelOptionsResult {
    /// Providers the gateway can use first, then by name: the order every model list shows.
    var sortedProviders: [ModelProvider] {
        providers.sorted { ($0.authenticated ?? false ? 0 : 1, $0.name) < ($1.authenticated ?? false ? 0 : 1, $1.name) }
    }
}

/// Stock Menu listing models by provider. Mid-chat switches are session-scoped (`config.set model --session`).
struct ModelPickerMenu: View {
    @Bindable var chat: ChatSession
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Menu {
            ModelMenuContent(chat: chat)
        } label: {
            if sizeClass == .compact {
                Image(systemName: "cpu")
            } else {
                Label(chat.modelName.isEmpty ? "Model" : shortModel(chat.modelName), systemImage: "cpu")
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Model: \(chat.modelName)")
    }

    private func shortModel(_ m: String) -> String {
        let last = m.split(separator: "/").last.map(String.init) ?? m
        return last.count > 22 ? String(last.prefix(21)) + "…" : last
    }
}

/// The menu items themselves, so they can be a top-level menu or a submenu of the chat's … menu.
/// The person's favourite models for this gateway come first, then "All Models…" (the whole list, searchable:
/// ModelChooserSheet), then each provider's featured models (#401).
struct ModelMenuContent: View {
    @Bindable var chat: ChatSession
    @State private var options: ModelOptionsResult?
    @State private var loading = false
    @State private var error: String?
    @State private var favourites = FavouriteModels.shared

    init(chat: ChatSession) {
        self.chat = chat
        // Opens with the list already fetched for this bot (warmed when the chat opened).
        _options = State(initialValue: chat.cachedModelOptions)
    }

    /// The newest list fetched for this chat's bot (the model list's pull to refresh updates it too), else this menu's own.
    private var shown: ModelOptionsResult? { chat.cachedModelOptions ?? options }

    var body: some View {
        Group {
            let options = shown
            let favs = favourites.list(chat.runtime.connection.id)
            if !favs.isEmpty {
                Section("Favourites") {
                    ForEach(favs) { f in favouriteItem(f) }
                }
            }
            // The menu closes as this is picked; the chat's page (or the bot card over it) opens the list.
            Button { Perf.stamp("models: All Models… picked"); AppModel.shared.modelChooser = ModelChooserRequest(chat: chat) } label: { MenuLabel("All Models…", systemImage: "magnifyingglass") }
                .accessibilityIdentifier("models.all")
            if let options {
                ForEach(options.sortedProviders) { p in
                    Section(p.name + (p.authenticated == false ? " (no key)" : p.warning != nil ? " (needs setup)" : "")) {
                        if let w = p.warning, !w.isEmpty { Text(w) }
                        ForEach(p.featuredModels ?? p.models ?? [], id: \.self) { m in
                            Button { select(provider: p.slug, model: m) } label: {
                                if chat.modelName == m { MenuLabel(m, systemImage: "checkmark") } else { Text(m) }
                            }
                        }
                        if let more = p.models, let featured = p.featuredModels, more.count > featured.count {
                            Menu("All \(more.count) models") {
                                ForEach(more, id: \.self) { m in Button(m) { select(provider: p.slug, model: m) } }
                            }
                        }
                    }
                }
            } else if loading {
                Text("Loading models…")
            } else if let error {
                Text(RestartRequiredCallout.matches(error) ? "Hermes needs a restart — see Settings › System" : error)
            }
            Divider()
            // Reasoning effort is its own item in the chat's menu (ReasoningEffortMenu, #301).
            if currentCapabilities?.fast == true {
                Toggle("Fast mode", isOn: Binding(get: { chat.info?.fast ?? false }, set: { v in Task { try? await chat.setFast(v) } }))
            }
            Toggle("YOLO (skip approvals, this session)", isOn: Binding(get: { chat.info?.yolo ?? false }, set: { v in Task { try? await chat.setYolo(v) } }))
            Button { Task { await load(refresh: true) } } label: { MenuLabel("Refresh models", systemImage: "arrow.clockwise") }
                .accessibilityIdentifier("models.refresh")
        }
        .task { if options == nil { await load(refresh: false) } }
    }

    /// A favourite: its model, its provider under it, ticked when it is the chat's. One the gateway no longer offers
    /// is shown, and cannot be picked, until it is removed in the list.
    @ViewBuilder private func favouriteItem(_ f: FavouriteModel) -> some View {
        let offered = shown?.offers(f) ?? true
        let provider = shown?.providerName(f.provider) ?? f.provider
        Button { select(provider: f.provider, model: f.model) } label: {
            if chat.modelName == f.model && (chat.providerSlug ?? f.provider) == f.provider { MenuLabel(f.model, systemImage: "checkmark") } else { Text(f.model) }
            Text(offered ? provider : "\(provider) · unavailable")
        }
        .disabled(!offered)
        .accessibilityIdentifier("models.fav.\(f.id)")
    }

    private var currentCapabilities: ModelCapabilities? {
        shown?.providers.first { $0.slug == chat.providerSlug }?.capabilities?[chat.modelName]
    }

    private func load(refresh: Bool) async {
        loading = true; defer { loading = false }
        do {
            options = try await chat.modelOptions(refresh: refresh)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func select(provider: String, model: String) {
        Task {
            do { try await chat.setModel(provider: provider, model: model) }
            catch { chat.banner = error.localizedDescription }
        }
    }
}

/// Reasoning effort as its own item in the chat's … menu, next to Model (#301): the level
/// now, and a short list to pick from. Hidden once the model is known to have no reasoning
/// setting; until the model list has loaded it is offered as is.
enum ReasoningEffort {
    /// The levels every model is offered when the gateway says nothing at all: Hermes's own set
    /// (`VALID_REASONING_EFFORTS`), never just three (#319).
    static let standard = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    /// The known levels, weakest first: the order the list keeps whichever of them appear.
    /// Hermes's own set (`VALID_REASONING_EFFORTS`); a level only a gateway knows goes after.
    static let byStrength = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// How a level reads in the menu; the raw value is what the gateway is sent. "xhigh" is
    /// the one that is not a word (#319); the rest are their own name, capitalised.
    static func name(of level: String) -> String {
        let l = level.trimmingCharacters(in: .whitespaces)
        if l == "xhigh" { return "Extra high" }
        return l.prefix(1).uppercased() + l.dropFirst()
    }

    /// The levels to list: the standard three plus whatever the gateway's own config schema
    /// offers for `agent.reasoning_effort`, the known ones by strength (minimal, low, medium,
    /// high, xhigh, max, ultra), any the gateway alone knows after them in its order, without
    /// repeats or the empty "unset" choice. The schema is the only source: Hermes keeps each
    /// model's own `supported_efforts` out of its model options on purpose (the catalogs
    /// under-report levels that work), so the list is the gateway's, not the model's (#319).
    static func levels(offered: [String]?) -> [String] {
        let given = (offered ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let wanted = Set(standard + given)
        var out = byStrength.filter { wanted.contains($0) }
        for g in given where !out.contains(g) { out.append(g) }
        return out
    }

    /// The item's title: the level the chat runs at, or that none is set.
    static func title(current: String?) -> String {
        let c = (current ?? "").trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? "Reasoning: not set" : "Reasoning: \(name(of: c))"
    }

    /// The schema's offered levels, from `GET /api/config/schema`: `fields["agent.reasoning_effort"].options`
    /// when the gateway lists them, else `fields["delegation.reasoning_effort"].options` (the one
    /// reasoning select Hermes's schema carries; `agent.reasoning_effort` is built from the config
    /// with a type but no options, which is what left the menu at three levels, #319), else nil
    /// and the full known set is shown.
    static func offered(in schema: JSONValue) -> [String]? {
        for key in ["agent.reasoning_effort", "delegation.reasoning_effort"] {
            if let o = schema["fields"]?[key]?["options"]?.arrayValue?.compactMap(\.stringValue), !o.isEmpty { return o }
        }
        return nil
    }
}

struct ReasoningEffortMenu: View {
    @Bindable var chat: ChatSession
    @State private var capabilities: ModelCapabilities?
    @State private var offered: [String]?
    @State private var loaded = false

    var body: some View {
        if capabilities?.reasoning != false {
            Menu {
                ForEach(ReasoningEffort.levels(offered: offered), id: \.self) { level in
                    Button {
                        Task {
                            do { try await chat.setReasoning(level) } catch { chat.banner = error.localizedDescription }
                        }
                    } label: {
                        if chat.reasoningEffort == level { MenuLabel(ReasoningEffort.name(of: level), systemImage: "checkmark") } else { Text(ReasoningEffort.name(of: level)) }
                    }
                }
            } label: {
                MenuLabel(ReasoningEffort.title(current: chat.reasoningEffort), systemImage: "brain")
            }
            .accessibilityIdentifier("chat.reasoning")
            .task {
                guard !loaded else { return }
                loaded = true
                if let o = try? await chat.modelOptions() {
                    capabilities = o.providers.first { $0.slug == chat.providerSlug }?.capabilities?[chat.modelName]
                }
                let profile = ChatSession.modelOptionsProfile(chat: chat.profile, selected: chat.runtime.selectedProfile)
                do {
                    let schema: JSONValue = try await chat.runtime.api.get("/api/config/schema", profile: profile)
                    offered = ReasoningEffort.offered(in: schema)
                } catch {
                    // The full known set still shows; the failure is only worth a line in the log.
                    #if DEBUG
                    print("reasoning levels: the config schema could not be read (\(error.localizedDescription)); showing the known set")
                    #endif
                }
            }
        }
    }
}

struct ContextBreakdownSheet: View {
    var chat: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var breakdown: ContextBreakdown?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            SettingsList {
                if let b = breakdown {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(b.contextUsed.formatted()) of \(b.contextMax.formatted()) tokens (\(b.contextPercent)%)").font(.headline)
                            GeometryReader { geo in
                                HStack(spacing: 1) {
                                    ForEach(b.categories.filter { $0.tokens > 0 }) { c in
                                        Rectangle().fill(color(c)).frame(width: max(2, geo.size.width * CGFloat(c.tokens) / CGFloat(max(1, b.contextMax))))
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .frame(height: 10).clipShape(.capsule).background(Color(.tertiarySystemFill), in: .capsule)
                            if let m = b.model { Text(m).font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(.vertical, 4)
                    }
                    Section("By category") {
                        ForEach(b.categories) { c in
                            HStack {
                                Circle().fill(color(c)).frame(width: 10, height: 10)
                                Text(c.label)
                                Spacer()
                                Text(c.tokens.formatted()).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let u = chat.usage {
                    Section("Session") {
                        LabeledContent("Input tokens", value: (u.input ?? 0).formatted())
                        LabeledContent("Output tokens", value: (u.output ?? 0).formatted())
                        if let r = u.reasoning, r > 0 { LabeledContent("Reasoning tokens", value: r.formatted()) }
                        LabeledContent("Model calls", value: "\(u.calls ?? 0)")
                        if let c = u.compressions, c > 0 { LabeledContent("Compressions", value: "\(c)") }
                        if let p = u.cacheHitPct { LabeledContent("Cache hit", value: "\(p)%") }
                        if let cost = u.costUsd { LabeledContent("Cost", value: String(format: "$%.4f%@", cost, u.costStatus == "estimated" ? " (est.)" : "")) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                do { breakdown = try await chat.contextBreakdown() } catch { self.error = error.localizedDescription }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func color(_ c: ContextCategory) -> Color {
        switch c.id {
        case "system", "system_prompt": return .blue
        case "tools": return .purple
        case "skills": return .teal
        case "memory": return .green
        case "mcp": return .indigo
        case "conversation", "messages": return .orange
        case "free": return Color(.systemFill)
        default: return .gray
        }
    }
}

/// The model picker as a page, for where a menu cannot go: a card in the thread, say.
/// Providers the gateway can use come first; the ones without a key or with a warning are
/// marked so nobody picks them blind.
struct ModelSheet: View {
    @Bindable var chat: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var options: ModelOptionsResult?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            SettingsList {
                if let options {
                    ForEach(options.sortedProviders) { p in
                        Section {
                            if let w = p.warning, !w.isEmpty { Text(w).font(.footnote).foregroundStyle(.orange) }
                            ForEach(p.models ?? p.featuredModels ?? [], id: \.self) { m in
                                Button { pick(p.slug, m) } label: {
                                    HStack {
                                        Text(m).foregroundStyle(.primary)
                                        Spacer()
                                        if chat.modelName == m { Image(systemName: "checkmark").foregroundStyle(Color.vory) }
                                    }
                                }
                                .disabled(busy)
                            }
                        } header: {
                            HStack {
                                Text(p.name)
                                if p.authenticated == false { Text("no key").font(.caption2).foregroundStyle(.orange) }
                                else if p.warning != nil { Text("needs setup").font(.caption2).foregroundStyle(.orange) }
                            }
                        }
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Model for this chat").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                do { options = try await chat.modelOptions() }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private func pick(_ provider: String, _ model: String) {
        busy = true
        Task {
            do { try await chat.setModel(provider: provider, model: model); dismiss() }
            catch { chat.banner = error.localizedDescription; busy = false }
        }
    }
}
