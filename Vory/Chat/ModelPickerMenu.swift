import SwiftUI
import VoryCore

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
struct ModelMenuContent: View {
    @Bindable var chat: ChatSession
    @State private var options: ModelOptionsResult?
    @State private var loading = false
    @State private var error: String?

    private let efforts = ["minimal", "low", "medium", "high", "xhigh", "max"]

    var body: some View {
        Group {
            if let options {
                ForEach(options.providers.sorted { ($0.authenticated ?? false ? 0 : 1, $0.name) < ($1.authenticated ?? false ? 0 : 1, $1.name) }) { p in
                    Section(p.name + (p.authenticated == false ? " (no key)" : p.warning != nil ? " (needs setup)" : "")) {
                        if let w = p.warning, !w.isEmpty { Text(w) }
                        ForEach(p.featuredModels ?? p.models ?? [], id: \.self) { m in
                            Button { select(provider: p.slug, model: m) } label: {
                                if chat.modelName == m { Label(m, systemImage: "checkmark") } else { Text(m) }
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
            if currentCapabilities?.reasoning != false {
                Menu("Reasoning effort") {
                    ForEach(efforts, id: \.self) { e in
                        Button { Task { try? await chat.setReasoning(e) } } label: {
                            if chat.info?.reasoningEffort == e { Label(e, systemImage: "checkmark") } else { Text(e) }
                        }
                    }
                }
            }
            if currentCapabilities?.fast == true {
                Toggle("Fast mode", isOn: Binding(get: { chat.info?.fast ?? false }, set: { v in Task { try? await chat.setFast(v) } }))
            }
            Toggle("YOLO (skip approvals, this session)", isOn: Binding(get: { chat.info?.yolo ?? false }, set: { v in Task { try? await chat.setYolo(v) } }))
            Button { Task { await load(refresh: true) } } label: { Label("Refresh models", systemImage: "arrow.clockwise") }
        }
        .task { await load(refresh: false) }
    }

    private var currentCapabilities: ModelCapabilities? {
        options?.providers.first { $0.slug == chat.info?.provider }?.capabilities?[chat.modelName]
    }

    private func load(refresh: Bool) async {
        loading = true; defer { loading = false }
        do {
            var q: [URLQueryItem] = []
            if refresh { q.append(URLQueryItem(name: "refresh", value: "true")) }
            options = try await chat.runtime.api.get("/api/model/options", query: q, profile: chat.runtime.selectedProfile)
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

/// Context gauge in the nav bar; tap for the breakdown sheet. Glyph only on a phone (the
/// percentage is in the subtitle), glyph + `24.1k / 128k · 19%` where there is room.
struct TokenChipView: View {
    var usage: Usage?
    var onTap: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Button(action: onTap) {
            if sizeClass == .compact {
                Image(systemName: gaugeSymbol)
            } else {
                Label(label, systemImage: gaugeSymbol).monospacedDigit().lineLimit(1)
            }
        }
        .accessibilityLabel("Context usage \(label)")
    }

    /// The needle tracks the fill level so the glyph alone says something.
    private var gaugeSymbol: String {
        let pct = usage.flatMap(Self.percent) ?? 0
        switch pct {
        case ..<20: return "gauge.with.dots.needle.0percent"
        case ..<55: return "gauge.with.dots.needle.33percent"
        case ..<85: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }

    static func percent(_ u: Usage) -> Int? { u.computedContextPercent }

    private var label: String {
        guard let u = usage else { return "—" }
        let used = u.contextUsed ?? u.total ?? 0
        if let max = u.contextMax, max > 0 {
            let pct = u.contextPercent ?? Int(Double(used) / Double(max) * 100)
            return "\(compact(used)) / \(compact(max)) · \(pct)%"
        }
        return compact(used)
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
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
                    ForEach(options.providers.sorted { ($0.authenticated ?? false ? 0 : 1, $0.name) < ($1.authenticated ?? false ? 0 : 1, $1.name) }) { p in
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
                do { options = try await chat.runtime.api.get("/api/model/options", profile: chat.runtime.selectedProfile) }
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
