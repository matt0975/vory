import SwiftUI
import VoryCore

// MARK: Model

struct ModelSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var options: ModelOptionsResult?
    @State private var auxiliary: JSONValue?
    @State private var error: String?
    @State private var confirm: (message: String, provider: String, modelName: String, scope: String, task: String?)?
    @State private var refreshing = false

    private var rt: GatewayRuntime? { model.runtime }

    var body: some View {
        List {
            SettingsHeaderSection(title: "Model", symbol: "cpu", color: .blue, description: "The default model and provider for this bot.")
            if let o = options {
                Section {
                    LabeledContent("Current", value: o.model?.isEmpty == false ? "\(o.provider ?? "")/\(o.model!)" : "not set")
                    // The gateway keeps each provider's model list for an hour and serves a
                    // stale one for up to a week while it refreshes behind; only an explicit
                    // refresh asks every provider again (15 s or more).
                    Button { Task { await load(refresh: true) } } label: {
                        HStack { Label(refreshing ? "Asking the providers…" : "Refresh model list", systemImage: "arrow.clockwise"); if refreshing { Spacer(); ProgressView().controlSize(.small) } }
                    }
                    .disabled(refreshing)
                    modelMenu(title: "Change default model", providers: o.providers) { p, m in Task { await set(scope: "main", task: nil, provider: p, model: m, confirmed: false) } }
                } header: { Text("Main model") } footer: { Text("Writes model.default and model.provider in this profile's config.yaml. New sessions use it; running chats keep their own model.") }
                if let tasks = auxiliary?["tasks"]?.arrayValue {
                    Section("Auxiliary models") {
                        ForEach(tasks, id: \.self) { t in
                            let task = t["task"]?.stringValue ?? ""
                            let prov = t["provider"]?.stringValue ?? "auto"
                            let mdl = t["model"]?.stringValue ?? ""
                            modelMenu(title: task.replacingOccurrences(of: "_", with: " ").capitalized + ": " + (mdl.isEmpty ? prov : "\(prov)/\(mdl)"), providers: o.providers, allowAuto: true) { p, m in
                                Task { await set(scope: "auxiliary", task: task, provider: p, model: m, confirmed: false) }
                            }
                        }
                    }
                }
            } else if let error {
                if RestartRequiredCallout.matches(error) { RestartRequiredCallout(message: error) }
                else { Text(error).foregroundStyle(.red) }
            } else { ProgressView() }
        }
        .refreshable { await load(refresh: true) }
        .task(id: rt?.selectedProfile) { await load() }
        .alert("Confirm model", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Use it anyway") { if let c = confirm { Task { await set(scope: c.scope, task: c.task, provider: c.provider, model: c.modelName, confirmed: true) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(confirm?.message ?? "") }
    }

    private func modelMenu(title: String, providers: [ModelProvider], allowAuto: Bool = false, pick: @escaping (String, String) -> Void) -> some View {
        Menu {
            if allowAuto { Button("Auto (follow main)") { pick("auto", "") } }
            ForEach(providers) { p in
                Section(p.name + (p.authenticated == false ? " (no key)" : p.warning != nil ? " (needs setup)" : "")) {
                    if let w = p.warning, !w.isEmpty { Text(w) }
                    ForEach(p.models ?? [], id: \.self) { m in Button(m) { pick(p.slug, m) } }
                }
            }
        } label: { Text(title) }
    }

    private func load(refresh: Bool = false) async {
        guard let rt else { return }
        if refresh { refreshing = true }
        defer { refreshing = false }
        do {
            options = try await rt.api.get("/api/model/options", query: refresh ? [URLQueryItem(name: "refresh", value: "true")] : [], profile: rt.selectedProfile)
            auxiliary = try? await rt.api.get("/api/model/auxiliary", profile: rt.selectedProfile)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func set(scope: String, task: String?, provider: String, model: String, confirmed: Bool) async {
        guard let rt else { return }
        var body: [String: JSONValue] = ["scope": .string(scope), "provider": .string(provider), "model": .string(model)]
        if let task { body["task"] = .string(task) }
        if confirmed { body["confirm_expensive_model"] = true }
        do {
            let r: JSONValue = try await rt.api.send("POST", "/api/model/set", profile: rt.selectedProfile, json: .object(body))
            if r["confirm_required"]?.boolValue == true { confirm = (r["confirm_message"]?.stringValue ?? "This model may be expensive.", provider, model, scope, task); return }
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: Config (schema-driven form over /api/config)

struct ConfigFormView: View {
    @Environment(AppModel.self) private var model
    @State private var config: JSONValue = .object([:])
    @State private var schema: ConfigSchemaResponse?
    @State private var error: String?
    @State private var search = ""
    @State private var saving: Set<String> = []

    private var rt: GatewayRuntime? { model.runtime }

    private var categories: [(String, [(String, ConfigSchemaField)])] {
        guard let s = schema else { return [] }
        let order = s.categoryOrder ?? []
        var groups: [String: [(String, ConfigSchemaField)]] = [:]
        for (k, f) in s.fields where search.isEmpty || k.localizedCaseInsensitiveContains(search) || (f.description ?? "").localizedCaseInsensitiveContains(search) {
            groups[f.category ?? "other", default: []].append((k, f))
        }
        return groups.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max, ib = order.firstIndex(of: b) ?? Int.max
            return ia == ib ? a < b : ia < ib
        }.map { ($0, groups[$0]!.sorted { $0.0 < $1.0 }) }
    }

    var body: some View {
        List {
            SettingsHeaderSection(title: "Config", symbol: "slider.horizontal.3", color: .gray, description: "Every setting in this bot's config, grouped the way the gateway reports them.")
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            ForEach(categories, id: \.0) { cat, fields in
                Section(cat.capitalized) {
                    ForEach(fields, id: \.0) { key, field in
                        row(key: key, field: field)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search config keys")
        .overlay { if schema == nil && error == nil { ProgressView() } }
        .refreshable { await load() }
        .task(id: rt?.selectedProfile) { await load() }
    }

    @ViewBuilder private func row(key: String, field: ConfigSchemaField) -> some View {
        let current = value(at: key)
        VStack(alignment: .leading, spacing: 4) {
            switch field.type {
            case "boolean":
                Toggle(key, isOn: Binding(get: { current?.boolValue ?? false }, set: { v in Task { await write(key, .bool(v)) } }))
            case "select":
                Picker(key, selection: Binding(get: { current?.displayText ?? "" }, set: { v in Task { await write(key, .string(v)) } })) {
                    ForEach(field.options ?? [], id: \.self) { Text($0.isEmpty ? "(none)" : $0).tag($0) }
                }
            case "number":
                LabeledContent(key) {
                    NumberField(value: current?.doubleValue ?? 0) { v in Task { await write(key, .number(v)) } }
                }
            default:
                LabeledContent(key) {
                    StringField(value: current?.displayText ?? "") { v in Task { await write(key, .string(v)) } }
                }
            }
            if let d = field.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
        }
        .opacity(saving.contains(key) ? 0.5 : 1)
    }

    private func value(at dotted: String) -> JSONValue? {
        var cur: JSONValue? = config["config"] ?? config
        for part in dotted.split(separator: ".") { cur = cur?[String(part)] }
        return cur
    }

    private func load() async {
        guard let rt else { return }
        do {
            config = try await rt.api.get("/api/config", profile: rt.selectedProfile)
            schema = try await rt.api.get("/api/config/schema", profile: rt.selectedProfile)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func write(_ dotted: String, _ v: JSONValue) async {
        guard let rt else { return }
        saving.insert(dotted); defer { saving.remove(dotted) }
        var nested: JSONValue = v
        for part in dotted.split(separator: ".").reversed() { nested = .object([String(part): nested]) }
        do {
            let _: JSONValue = try await rt.api.send("PUT", "/api/config", profile: rt.selectedProfile, json: .object(["config": nested]))
            await load()
        } catch { self.error = "\(dotted): \(error.localizedDescription)" }
    }
}

struct StringField: View {
    var value: String
    var commit: (String) -> Void
    @State private var text = ""
    var body: some View {
        TextField("", text: $text).multilineTextAlignment(.trailing).autocorrectionDisabled().textInputAutocapitalization(.never)
            .onAppear { text = value }
            .onChange(of: value) { _, v in text = v }
            .onSubmit { if text != value { commit(text) } }
    }
}

struct NumberField: View {
    var value: Double
    var commit: (Double) -> Void
    @State private var text = ""
    var body: some View {
        TextField("", text: $text).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            .onAppear { text = value.rounded() == value ? String(Int(value)) : String(value) }
            .onSubmit { if let d = Double(text), d != value { commit(d) } }
    }
}

// MARK: Env (API keys)

struct EnvView: View {
    @Environment(AppModel.self) private var model
    @State private var vars: [String: EnvVarInfo] = [:]
    @State private var error: String?
    @State private var editing: String?
    @State private var newValue = ""
    @State private var search = ""
    @State private var showAdd = false
    @State private var newKey = ""

    private var rt: GatewayRuntime? { model.runtime }
    private var grouped: [(String, [String])] {
        let keys = vars.keys.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
        let g = Dictionary(grouping: keys) { vars[$0]?.category ?? "Other" }
        return g.keys.sorted().map { ($0, g[$0]!.sorted()) }
    }

    var body: some View {
        List {
            SettingsHeaderSection(title: "API Keys & Environment", symbol: "key.fill", color: .orange, description: "Provider keys and environment variables the gateway uses.")
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            Section {
                Text("These are the keys in the .env file of the bot \((rt?.selectedProfile).map { "\"\($0)\"" } ?? "selected"). Each bot has its own file. A key the gateway gets from its environment or from a login is used but not listed here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(grouped, id: \.0) { cat, keys in
                Section(cat) {
                    ForEach(keys, id: \.self) { k in
                        Button { editing = k; newValue = "" } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(k).font(.body.monospaced())
                                    Spacer()
                                    Text(vars[k]?.hasValue == true ? (vars[k]?.preview ?? "Set") : "Not set").font(.caption).foregroundStyle(vars[k]?.hasValue == true ? .green : .secondary)
                                }
                                if let d = vars[k]?.description { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                        }
                        .tint(.primary)
                        .swipeActions {
                            if vars[k]?.hasValue == true { Button(role: .destructive) { Task { await clear(k) } } label: { Label("Clear", systemImage: "trash") } }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { showAdd = true } label: { Label("Add", systemImage: "plus") } } }
        .refreshable { await load() }
        .task(id: rt?.selectedProfile) { await load() }
        .alert(editing ?? "", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            SecureField("Value", text: $newValue)
            Button("Save") { if let k = editing { Task { await save(k, newValue) } } }
            if vars[editing ?? ""]?.hasValue == true { Button("Clear", role: .destructive) { if let k = editing { Task { await clear(k) } } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The value is sent to your gateway's .env and never shown again.") }
        .alert("Add variable", isPresented: $showAdd) {
            TextField("NAME", text: $newKey).textInputAutocapitalization(.characters)
            SecureField("Value", text: $newValue)
            Button("Save") { Task { await save(newKey.trimmingCharacters(in: .whitespaces), newValue) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() async {
        guard let rt else { return }
        do { vars = try await rt.api.get("/api/env", profile: rt.selectedProfile); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func save(_ key: String, _ value: String) async {
        guard let rt, !key.isEmpty else { return }
        do {
            let _: JSONValue = try await rt.api.send("PUT", "/api/env", profile: rt.selectedProfile, json: ["key": .string(key), "value": .string(value)])
            newValue = ""; newKey = ""
            await load()
        } catch { self.error = error.localizedDescription }
    }

    private func clear(_ key: String) async {
        guard let rt else { return }
        do {
            let _: JSONValue = try await rt.api.send("DELETE", "/api/env", profile: rt.selectedProfile, json: ["key": .string(key)])
            await load()
        } catch HermesAPIError.http(let status, _) where status == 404 {
            await load()   // not in the file any more: already cleared
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: Tools / Skills / MCP

struct ToolsView: View {
    @Environment(AppModel.self) private var model
    @State private var toolsets: [ToolsetInfo] = []
    @State private var error: String?
    private var rt: GatewayRuntime? { model.runtime }

    var body: some View {
        List {
            SettingsHeaderSection(title: "Tools", symbol: "wrench.and.screwdriver", color: .teal, description: "What the bot may do: each tool on or off.")
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            ForEach(toolsets) { t in
                Toggle(isOn: Binding(get: { t.enabled }, set: { v in Task { await toggle(t, v) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(t.label ?? t.name); if t.configured == false { Text("needs setup").font(.caption2).foregroundStyle(.orange) } }
                        if let d = t.description { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        if let tools = t.tools, !tools.isEmpty { Text(tools.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                }
            }
        }
        .refreshable { await load() }
        .task(id: rt?.selectedProfile) { await load() }
    }

    private func load() async {
        guard let rt else { return }
        do { toolsets = try await rt.api.get("/api/tools/toolsets", profile: rt.selectedProfile); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func toggle(_ t: ToolsetInfo, _ enabled: Bool) async {
        guard let rt else { return }
        do {
            let _: JSONValue = try await rt.api.send("PUT", "/api/tools/toolsets/\(t.name)", profile: rt.selectedProfile, json: ["enabled": .bool(enabled)])
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @State private var skills: [SkillInfo] = []
    @State private var error: String?
    @State private var search = ""
    private var rt: GatewayRuntime? { model.runtime }

    var body: some View {
        List {
            SettingsHeaderSection(title: "Skills", symbol: "sparkles", color: .purple, description: "The skills installed for this bot and what they add.")
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            ForEach(skills.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { s in
                Toggle(isOn: Binding(get: { s.enabled ?? true }, set: { v in Task { await toggle(s, v) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(s.name); if let p = s.provenance { Text(p).font(.caption2).foregroundStyle(.tertiary) } }
                        if let d = s.description { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .refreshable { await load() }
        .task(id: rt?.selectedProfile) { await load() }
    }

    private func load() async {
        guard let rt else { return }
        do { skills = try await rt.api.get("/api/skills", profile: rt.selectedProfile); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func toggle(_ s: SkillInfo, _ enabled: Bool) async {
        guard let rt else { return }
        do {
            let _: JSONValue = try await rt.api.send("PUT", "/api/skills/toggle", profile: rt.selectedProfile, json: ["name": .string(s.name), "enabled": .bool(enabled)])
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

struct MCPView: View {
    @Environment(AppModel.self) private var model
    @State private var servers: [MCPServerInfo] = []
    @State private var error: String?
    @State private var testResult: String?
    @State private var pendingDelete: MCPServerInfo?
    private var rt: GatewayRuntime? { model.runtime }

    var body: some View {
        List {
            SettingsHeaderSection(title: "MCP Servers", symbol: "point.3.connected.trianglepath.dotted", color: .mint, description: "External tool servers the bot can call, and whether each is on.")
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            if let testResult { Text(testResult).font(.footnote) }
            ForEach(servers) { s in
                Toggle(isOn: Binding(get: { s.enabled ?? true }, set: { v in Task { await setEnabled(s, v) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name)
                        Text(s.url ?? ([s.command].compactMap { $0 } + (s.args ?? [])).joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { pendingDelete = s } label: { Label("Remove", systemImage: "trash") }
                    Button { Task { await test(s) } } label: { Label("Test", systemImage: "bolt") }.tint(.blue)
                }
            }
        }
        .refreshable { await load() }
        .task(id: rt?.selectedProfile) { await load() }
        .alert("Remove MCP server?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Remove", role: .destructive) { if let s = pendingDelete { Task { await remove(s) } } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() async {
        guard let rt else { return }
        do {
            let raw: JSONValue = try await rt.api.get("/api/mcp/servers", profile: rt.selectedProfile)
            servers = Self.parse(raw)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    static func parse(_ raw: JSONValue) -> [MCPServerInfo] {
        let container = raw["servers"] ?? raw
        if let arr = container.arrayValue { return arr.compactMap { try? $0.decode(MCPServerInfo.self) } }
        if let obj = container.objectValue {
            return obj.keys.sorted().compactMap { name in
                var o = obj[name]?.objectValue ?? [:]
                o["name"] = .string(name)
                return try? JSONValue.object(o).decode(MCPServerInfo.self)
            }
        }
        return []
    }

    private func setEnabled(_ s: MCPServerInfo, _ enabled: Bool) async {
        guard let rt else { return }
        do {
            let _: JSONValue = try await rt.api.send("PUT", "/api/mcp/servers/\(s.name)/enabled", profile: rt.selectedProfile, json: ["enabled": .bool(enabled)])
            await load()
        } catch { self.error = error.localizedDescription }
    }

    private func test(_ s: MCPServerInfo) async {
        guard let rt else { return }
        do {
            let r: JSONValue = try await rt.api.send("POST", "/api/mcp/servers/\(s.name)/test", profile: rt.selectedProfile, body: EmptyBody())
            testResult = "\(s.name): \(r["status"]?.stringValue ?? (r["ok"]?.boolValue == true ? "ok" : r.displayText)) — \(r["tool_count"]?.intValue.map { "\($0) tools" } ?? "")"
        } catch { testResult = "\(s.name): \(error.localizedDescription)" }
    }

    private func remove(_ s: MCPServerInfo) async {
        guard let rt else { return }
        do {
            let _: JSONValue = try await rt.api.send("DELETE", "/api/mcp/servers/\(s.name)", profile: rt.selectedProfile, body: EmptyBody())
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: Approvals

struct ApprovalsView: View {
    @Environment(AppModel.self) private var model
    @State private var mode = "smart"
    @State private var timeout = 300.0
    @State private var error: String?
    @State private var loaded = false
    private var rt: GatewayRuntime? { model.runtime }

    var body: some View {
        List {
            SettingsHeaderSection(title: "Approvals", symbol: "checkmark.shield", color: .green, description: "How commands get approved — manual, smart or off — and what is always allowed.")
            Section {
                Picker("Mode", selection: $mode) {
                    Text("Smart").tag("smart"); Text("Manual").tag("manual"); Text("Off").tag("off")
                }
                .onChange(of: mode) { _, v in if loaded { Task { await write(["mode": .string(v)]) } } }
                LabeledContent("Timeout (seconds)") {
                    NumberField(value: timeout) { v in Task { await write(["timeout": .number(v)]) } }
                }
            } header: { Text("approvals") } footer: {
                Text("Smart lets a guardian model auto-approve routine commands and escalate risky ones. Manual asks you for every dangerous command. Off disables the gate. YOLO (skip approvals) is per session, default off, and lives in the chat's model menu.")
            }
            Section {
                if allowlist.isEmpty {
                    Text("Nothing yet. Answering \u{201C}Always\u{201D} on an approval card adds a rule here.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(allowlist, id: \.self) { rule in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule).font(.system(.body, design: .monospaced)).lineLimit(2)
                            Text(ruleKind(rule)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        var next = allowlist; next.remove(atOffsets: offsets)
                        Task { await write(["command_allowlist": .array(next.map { .string($0) })], topLevel: true) }
                    }
                }
            } header: { Text("Always allowed · \(botLabel)") } footer: {
                Text("Each rule is a command pattern or a tool, not one exact command, and it belongs to this bot's gateway profile: every chat with \(botLabel) runs matching commands without asking. Swipe a rule to remove it; new chats pick that up at once.")
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .task(id: rt?.selectedProfile) { await load() }
    }

    @State private var allowlist: [String] = []
    private var botLabel: String { rt?.profiles.first { $0.name == rt?.selectedProfile }?.label ?? rt?.selectedProfile ?? "this bot" }

    /// The rule in words: a command pattern, a tool, or a tool rule (see `ApprovalRequest.alwaysScope`).
    private func ruleKind(_ rule: String) -> String {
        if let colon = rule.firstIndex(of: ":") { return "Tool rule · \(rule[..<colon])" }
        if rule == "execute_code" || !rule.contains(" ") && !rule.contains("*") && rule.allSatisfy({ $0.isLetter || $0 == "_" }) { return "Tool" }
        return "Command pattern"
    }

    private func load() async {
        guard let rt else { return }
        do {
            let cfg: JSONValue = try await rt.api.get("/api/config", profile: rt.selectedProfile)
            let a = cfg["config"]?["approvals"] ?? cfg["approvals"]
            mode = a?["mode"]?.stringValue ?? "smart"
            timeout = a?["timeout"]?.doubleValue ?? 300
            let raw = cfg["config"]?["command_allowlist"] ?? cfg["command_allowlist"]
            allowlist = raw?.arrayValue?.compactMap(\.stringValue) ?? []
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    /// `topLevel`: the fields sit at the root of the config (the allowlist) rather than under `approvals`.
    private func write(_ fields: [String: JSONValue], topLevel: Bool = false) async {
        guard let rt else { return }
        do {
            let body: JSONValue = topLevel ? .object(fields) : .object(["approvals": .object(fields)])
            let _: JSONValue = try await rt.api.send("PUT", "/api/config", profile: rt.selectedProfile, json: ["config": body])
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: Cron

struct CronView: View {
    @Environment(AppModel.self) private var model
    @State private var jobs: [CronJob] = []
    @State private var raw: [String: JSONValue] = [:]
    @State private var error: String?
    private var rt: GatewayRuntime? { model.runtime }

    var body: some View {
        List {
            SettingsHeaderSection(title: "Scheduled Tasks", symbol: "timer", color: .pink, description: "Prompts your bots run on a schedule.")
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            if jobs.isEmpty, error == nil { ContentUnavailableView("No cron jobs", systemImage: "clock", description: Text("Jobs scheduled on any profile of this gateway appear here.")) }
            ForEach(jobs, id: \.identity) { j in
                NavigationLink { CronJobDetailView(job: j, raw: raw[j.identity] ?? .null, onChange: { Task { await load() } }) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: j.enabled == false || j.state == "paused" ? "pause.circle" : "clock").foregroundStyle(j.enabled == false || j.state == "paused" ? Color.secondary : Color.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(j.name?.isEmpty == false ? j.name! : (j.jobId ?? j.id ?? "job")).font(.body.weight(.medium)).lineLimit(1)
                            Text(CronSchedule.describe(j.schedule)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let n = j.nextRunAt, let d = ISO8601DateFormatter().date(from: n) { Text(d, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
            }
        }
        .contentMargins(.top, 14, for: .scrollContent)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let rt else { return }
        do {
            // No profile filter: the dashboard lists every profile's jobs when none is given.
            let r: JSONValue = try await rt.api.get("/api/cron/jobs")
            let arr = r["jobs"]?.arrayValue ?? r["items"]?.arrayValue ?? r.arrayValue ?? []
            var out: [CronJob] = []; var rawMap: [String: JSONValue] = [:]
            for j in arr {
                let c: CronJob
                if let d = try? j.decode(CronJob.self), d.id != nil || d.jobId != nil || d.name != nil { c = d }
                else { c = CronJob(id: j["id"]?.stringValue ?? j["job_id"]?.stringValue, name: j["name"]?.stringValue, schedule: CronSchedule.expression(of: j["schedule"]), prompt: j["prompt"]?.stringValue, enabled: j["enabled"]?.boolValue, state: j["state"]?.stringValue) }
                var c2 = c
                // Some gateways send the schedule as an object ({kind, expr, …}); keep the expression.
                if let e = CronSchedule.expression(of: j["schedule"]), c2.schedule?.hasPrefix("{") ?? true { c2.schedule = e }
                out.append(c2); rawMap[c2.identity] = j
            }
            jobs = out; raw = rawMap; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

/// Human wording for the common cron shapes; anything else is shown verbatim.
enum CronSchedule {
    /// The cron expression out of whatever the gateway sent: a string, or an object with the
    /// expression under one of the usual keys, or an interval.
    static func expression(of v: JSONValue?) -> String? {
        guard let v else { return nil }
        if let s = v.stringValue { return s }
        for k in ["cron", "expr", "expression", "spec", "value"] { if let s = v[k]?.stringValue, !s.isEmpty { return s } }
        if let every = v["every"]?.stringValue ?? v["interval"]?.stringValue { return "every \(every)" }
        if let secs = v["every_seconds"]?.doubleValue ?? v["interval_seconds"]?.doubleValue {
            return secs >= 3600 ? "every \(Int(secs / 3600)) h" : "every \(Int(secs / 60)) min"
        }
        if let at = v["at"]?.stringValue { return "at \(at)" }
        return v.displayText
    }

    static func describe(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "no schedule" }
        let p = s.split(separator: " ").map(String.init)
        guard p.count == 5, let h = Int(p[1]), let m = Int(p[0]) else { return s }
        let time = String(format: "%d:%02d", h == 0 ? 12 : (h > 12 ? h - 12 : h), m) + (h >= 12 ? " PM" : " AM")
        let days = ["0": "Sunday", "1": "Monday", "2": "Tuesday", "3": "Wednesday", "4": "Thursday", "5": "Friday", "6": "Saturday", "7": "Sunday"]
        if p[2] == "*", p[3] == "*" {
            switch p[4] {
            case "*": return "Every day at \(time)"
            case "1-5": return "Weekdays at \(time)"
            case "0,6", "6,0": return "Weekends at \(time)"
            default: if let d = days[p[4]] { return "\(d)s at \(time)" }
            }
        }
        if p[2] != "*", p[3] == "*", p[4] == "*" { return "Day \(p[2]) of every month at \(time)" }
        return s
    }
}

/// One job as a form: the fields of its JSON as native controls (name, on/off, a schedule built
/// from pickers with the cron line kept in step, the prompt, delivery, profile), and under them
/// the raw JSON in an editor for anything the form does not cover. Both save to the same job.
struct CronJobDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var job: CronJob
    var raw: JSONValue
    var onChange: () -> Void
    @State private var name = ""
    @State private var schedule = ""
    @State private var prompt = ""
    @State private var deliver = ""
    @State private var enabled = true
    @State private var rawText = ""
    @State private var rawError: String?
    @State private var loaded = false
    @State private var status: String?
    @State private var showRaw = false
    // Schedule pickers
    @State private var repeatKind = "daily"      // daily, weekdays, weekends, weekly, monthly, custom
    @State private var weekday = 1               // 0 = Sunday
    @State private var monthDay = 1
    @State private var time = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()

    private var rt: GatewayRuntime? { model.runtime }
    private var original: (name: String, schedule: String, prompt: String, deliver: String, enabled: Bool) {
        (job.name ?? "", job.schedule ?? "", job.prompt ?? raw["prompt"]?.stringValue ?? job.promptPreview ?? raw["prompt_preview"]?.stringValue ?? "", job.deliver ?? raw["deliver"]?.stringValue ?? "",
         !(job.enabled == false || job.state == "paused"))
    }
    private var dirty: Bool {
        name != original.name || schedule != original.schedule || prompt != original.prompt || deliver != original.deliver || enabled != original.enabled || rawDirty
    }
    private var rawDirty: Bool { rawText != Self.pretty(raw) }
    private var deliverOptions: [String] { Array(Set(["local", "telegram", "discord", "slack", "email", deliver].filter { !$0.isEmpty })).sorted() }

    var body: some View {
        List {
            Section {
                TextField("Name", text: $name)
                Toggle("Enabled", isOn: $enabled)
            } header: { Text("Task") }
            Section {
                Picker("Repeats", selection: $repeatKind) {
                    Text("Every day").tag("daily")
                    Text("Weekdays").tag("weekdays")
                    Text("Weekends").tag("weekends")
                    Text("Weekly").tag("weekly")
                    Text("Monthly").tag("monthly")
                    Text("Custom cron").tag("custom")
                }
                if repeatKind == "weekly" {
                    Picker("Day", selection: $weekday) {
                        ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) }
                    }
                }
                if repeatKind == "monthly" {
                    Picker("Day of month", selection: $monthDay) { ForEach(1...28, id: \.self) { Text("\($0)").tag($0) } }
                }
                if repeatKind != "custom" {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                } else {
                    TextField("min hour day month weekday", text: $schedule).font(.body.monospaced()).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                LabeledContent("Cron") { Text(schedule).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Text(CronSchedule.describe(schedule)).font(.caption).foregroundStyle(.secondary)
            } header: { Text("When") } footer: { Text("Times are in the gateway machine's time zone.") }
            .onChange(of: repeatKind) { _, _ in rebuildSchedule() }
            .onChange(of: weekday) { _, _ in rebuildSchedule() }
            .onChange(of: monthDay) { _, _ in rebuildSchedule() }
            .onChange(of: time) { _, _ in rebuildSchedule() }
            Section {
                TextEditor(text: $prompt).frame(minHeight: 120).font(.body)
            } header: { Text("What it does") } footer: { Text("The prompt the agent runs on schedule.") }
            Section {
                Picker("Delivers to", selection: $deliver) {
                    ForEach(deliverOptions, id: \.self) { Text($0).tag($0) }
                }
                if let p = raw["profile"]?.stringValue { LabeledContent("Bot", value: model.runtime?.profiles.first { $0.name == p }?.label ?? p) }
                LabeledContent("Status", value: job.state ?? (job.enabled == false ? "paused" : "active"))
                if let n = job.nextRunAt, let d = ISO8601DateFormatter().date(from: n) { LabeledContent("Next run", value: d.formatted(date: .abbreviated, time: .shortened)) }
                if let l = job.lastRunAt, let d = ISO8601DateFormatter().date(from: l) { LabeledContent("Last run", value: d.formatted(date: .abbreviated, time: .shortened)) }
                if let s = job.lastStatus { LabeledContent("Last result", value: s) }
            } header: { Text("Details") }
            Section {
                DisclosureGroup(isExpanded: $showRaw) {
                    TextEditor(text: $rawText)
                        .font(.caption.monospaced())
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .frame(minHeight: 220)
                    if let rawError { Text(rawError).font(.caption).foregroundStyle(.red) }
                } label: {
                    Label("Raw JSON", systemImage: "curlybraces")
                }
            } footer: { Text("Everything the gateway holds for this task. Edit here for fields the form does not show; the form and the JSON save to the same task.") }
            Section {
                Button { Task { await act("trigger") } } label: { Label("Run now", systemImage: "play.circle") }
                Button(role: .destructive) { Task { await act("delete") } } label: { Label("Delete task", systemImage: "trash") }
            }
            if let status { Section { Text(status).font(.footnote).foregroundStyle(status.hasPrefix("Saved") || status.hasPrefix("Done") ? Color.secondary : Color.red) } }
        }
        .navigationTitle(job.name?.isEmpty == false ? job.name! : "Scheduled task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(!dirty) } }
        .task {
            guard !loaded else { return }
            loaded = true
            name = original.name; schedule = original.schedule; prompt = original.prompt; deliver = original.deliver; enabled = original.enabled
            rawText = Self.pretty(raw)
            readSchedule(schedule)
        }
    }

    /// The pickers from a cron line, when it is one of the shapes they can express.
    private func readSchedule(_ s: String) {
        let p = s.split(separator: " ").map(String.init)
        guard p.count == 5, let m = Int(p[0]), let h = Int(p[1]) else { repeatKind = "custom"; return }
        time = Calendar.current.date(from: DateComponents(hour: h, minute: m)) ?? time
        switch (p[2], p[3], p[4]) {
        case ("*", "*", "*"): repeatKind = "daily"
        case ("*", "*", "1-5"): repeatKind = "weekdays"
        case ("*", "*", "0,6"), ("*", "*", "6,0"): repeatKind = "weekends"
        case ("*", "*", let d) where Int(d) != nil: repeatKind = "weekly"; weekday = Int(d)! % 7
        case (let d, "*", "*") where Int(d) != nil: repeatKind = "monthly"; monthDay = Int(d)!
        default: repeatKind = "custom"
        }
    }

    private func rebuildSchedule() {
        guard repeatKind != "custom" else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hm = "\(c.minute ?? 0) \(c.hour ?? 0)"
        switch repeatKind {
        case "weekdays": schedule = "\(hm) * * 1-5"
        case "weekends": schedule = "\(hm) * * 0,6"
        case "weekly": schedule = "\(hm) * * \(weekday)"
        case "monthly": schedule = "\(hm) \(monthDay) * *"
        default: schedule = "\(hm) * * *"
        }
    }

    private static func pretty(_ v: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(v), let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return v.displayText }
        return String(decoding: out, as: UTF8.self)
    }

    private func save() async {
        guard let rt else { return }
        var updates: [String: JSONValue] = [:]
        // The raw editor wins for whatever it changed; the form's fields go on top of that.
        if rawDirty {
            guard let data = rawText.data(using: .utf8), let edited = try? JSONDecoder().decode(JSONValue.self, from: data), let obj = edited.objectValue else {
                rawError = "The JSON does not parse."; return
            }
            rawError = nil
            for (k, v) in obj where raw[k] != v { updates[k] = v }
        }
        if name != original.name { updates["name"] = .string(name) }
        if schedule != original.schedule { updates["schedule"] = .string(schedule) }
        if prompt != original.prompt { updates["prompt"] = .string(prompt) }
        if deliver != original.deliver, !deliver.isEmpty { updates["deliver"] = .string(deliver) }
        do {
            if !updates.isEmpty {
                let _: JSONValue = try await rt.api.send("PUT", "/api/cron/jobs/\(job.identity)", json: .object(["updates": .object(updates)]))
            }
            if enabled != original.enabled {
                let _: JSONValue = try await rt.api.send("POST", "/api/cron/jobs/\(job.identity)/\(enabled ? "resume" : "pause")", body: EmptyBody())
            }
            status = "Saved."; onChange()
        } catch { status = error.localizedDescription }
    }

    private func act(_ action: String) async {
        guard let rt else { return }
        do {
            if action == "delete" { let _: JSONValue = try await rt.api.send("DELETE", "/api/cron/jobs/\(job.identity)", body: EmptyBody()); onChange(); dismiss(); return }
            let _: JSONValue = try await rt.api.send("POST", "/api/cron/jobs/\(job.identity)/\(action)", body: EmptyBody())
            status = "Done: \(action)."; onChange()
        } catch { status = error.localizedDescription }
    }
}

// MARK: Sessions

struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [StoredSession] = []
    @State private var search = ""
    @State private var error: String?
    @State private var stats: JSONValue?
    @State private var showAdvanced = false
    private var rt: GatewayRuntime? { model.runtime }

    var body: some View {
        List {
            SettingsHeaderSection(title: "Sessions", symbol: "list.bullet.rectangle", color: .cyan, description: "Every conversation on the gateway, with search and storage.")
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            Section {
                ForEach(sessions) { s in
                    Button { model.pendingRoute = PendingRoute(connectionID: rt?.connection.id, storedSessionID: s.id, profile: rt?.selectedProfile); model.selectedTab = .chats } label: {
                        VStack(alignment: .leading) { Text(s.displayTitle).lineLimit(1); Text("\(s.messageCount ?? 0) messages · \(s.model ?? "")").font(.caption).foregroundStyle(.secondary) }
                    }
                    .tint(.primary)
                    .swipeActions { Button(role: .destructive) { Task { await delete(s) } } label: { Label("Delete", systemImage: "trash") } }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .onChange(of: search) { _, _ in Task { await load() } }
        .refreshable { await load() }
        .task(id: rt?.selectedProfile) { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showAdvanced = true } label: { Label("Advanced", systemImage: "internaldrive") }
                } label: { Label("Options", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $showAdvanced) { SessionStoreSheet(stats: stats) }
    }

    private func load() async {
        guard let rt else { return }
        do {
            if search.isEmpty {
                let r: SessionListResponse = try await rt.api.get("/api/sessions", query: [URLQueryItem(name: "archived", value: "include"), URLQueryItem(name: "limit", value: "100")], profile: rt.selectedProfile)
                sessions = r.sessions
            } else {
                let r: JSONValue = try await rt.api.get("/api/sessions/search", query: [URLQueryItem(name: "q", value: search)], profile: rt.selectedProfile)
                sessions = (r["sessions"]?.arrayValue ?? r["results"]?.arrayValue ?? []).compactMap { try? $0.decode(StoredSession.self) }
            }
            stats = try? await rt.api.get("/api/sessions/stats", profile: rt.selectedProfile)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ s: StoredSession) async {
        guard let rt else { return }
        let _: JSONValue? = try? await rt.api.send("DELETE", "/api/sessions/\(s.id)", profile: rt.selectedProfile, body: EmptyBody())
        await load()
    }
}

// MARK: Channels (read-only)

struct ChannelsView: View {
    @Environment(AppModel.self) private var model
    @State private var platforms: [JSONValue] = []
    @State private var error: String?

    var body: some View {
        List {
            SettingsHeaderSection(title: "Channels", symbol: "antenna.radiowaves.left.and.right", color: .brown, description: "Messaging platforms the gateway is connected to.")
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            ForEach(Array(platforms.enumerated()), id: \.offset) { _, p in
                HStack {
                    VStack(alignment: .leading) {
                        Text(p["label"]?.stringValue ?? p["name"]?.stringValue ?? p["id"]?.stringValue ?? "?")
                        Text(p["status"]?.stringValue ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if p["enabled"]?.boolValue == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            }
            Section { Text("Channel setup (bot tokens, allowlists) happens on the gateway machine or its web dashboard.").font(.footnote).foregroundStyle(.secondary) }
        }
        .task {
            guard let rt = model.runtime else { return }
            do {
                let raw: JSONValue = try await rt.api.get("/api/messaging/platforms", profile: rt.selectedProfile)
                let container = raw["platforms"] ?? raw
                if let arr = container.arrayValue { platforms = arr }
                else if let obj = container.objectValue { platforms = obj.keys.sorted().map { k in var o = obj[k]?.objectValue ?? [:]; o["id"] = .string(k); return .object(o) } }
            } catch { self.error = error.localizedDescription }
        }
    }
}
