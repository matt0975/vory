import SwiftUI
import VoryCore

/// Creates a bot: a Hermes profile on the gateway (name, description, default model) plus its
/// look from the Creator Studio, kept on this device under the new name.
struct NewBotSheet: View {
    var runtime: GatewayRuntime
    /// Set, the sheet edits this bot instead of creating one: description, model and look, with
    /// Delete at the bottom. The name stays, because the gateway has no rename call (a profile
    /// is its folder); the sheet says so.
    var editing: ProfileInfo? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var description = ""
    @State private var cloneFrom = ""
    @State private var options: ModelOptionsResult?
    @State private var provider = ""
    @State private var modelName = ""
    @State private var choice: BotAvatarChoice = .default
    @State private var busy = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    /// Profile names are folder names on the gateway: letters, digits, dash and underscore.
    private var cleanName: String {
        name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
            .reduce(into: "") { if !($0.last == "-" && $1 == "-") { $0.append($1) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    /// The studio stores looks by profile name; while the name is being typed they live under
    /// a draft key and move to the real name on create.
    private var draftKey: String { editing?.name ?? (cleanName.isEmpty ? "new-bot" : cleanName) }
    private var canCreate: Bool { editing != nil ? !busy : (!cleanName.isEmpty && !busy && !runtime.profiles.contains { $0.name == cleanName }) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 6) {
                        BotAvatar(profile: draftKey, size: 84, active: true, override: choice)
                        Text(cleanName.isEmpty ? "New bot" : cleanName).font(.title3.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                Section {
                    CreatorStudio(profile: draftKey, choice: $choice)
                } header: { Text("Creator Studio") }
                Section {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(editing != nil)
                        .foregroundStyle(editing != nil ? .secondary : .primary)
                    if editing == nil, !name.isEmpty, cleanName != name { Text("Saved as \(cleanName)").font(.caption).foregroundStyle(.secondary) }
                    if editing == nil, runtime.profiles.contains(where: { $0.name == cleanName }) { Text("A bot with this name already exists.").font(.caption).foregroundStyle(.red) }
                    TextField("Description", text: $description, axis: .vertical).lineLimit(1...3)
                } header: { Text("Bot") } footer: {
                    Text(editing != nil ? "The name is the bot's folder on the gateway, and Hermes has no rename yet; make a new bot with the name you want and start it from this one. The description is what other Hermes surfaces show for this bot."
                                        : "The description is what other Hermes surfaces show for this bot.")
                }
                Section {
                    if let o = options {
                        Menu {
                            ForEach(o.providers) { p in
                                Section(p.name) {
                                    ForEach(p.models ?? [], id: \.self) { m in Button(m) { provider = p.slug; modelName = m } }
                                }
                            }
                        } label: { LabeledContent("Default model", value: modelName.isEmpty ? "Gateway default" : modelName) }
                        .tint(.primary)
                    } else { ProgressView() }
                    if editing == nil {
                        Picker("Start from", selection: $cloneFrom) {
                            Text("A fresh profile").tag("")
                            ForEach(runtime.profiles) { Text($0.label).tag($0.name) }
                        }
                    }
                } header: { Text("Model") } footer: { Text(editing == nil ? "Starting from another bot copies its config, skills and instructions." : "New chats with this bot use the model; running chats keep theirs.") }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
                if let e = editing {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete \(e.label)", systemImage: "trash") }
                            .disabled(busy || e.isDefault == true)
                    } footer: {
                        Text(e.isDefault == true ? "The default bot cannot be deleted." : "Removes the profile and its folder from the gateway: its SOUL.md, config and chats go with it.")
                    }
                }
            }
            .navigationTitle(editing == nil ? "New Bot" : "Edit Bot")
            .confirmationDialog("Delete \(editing?.label ?? "this bot")?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete bot", role: .destructive) { Task { await deleteBot() } }
            } message: { Text("Its SOUL.md, config and chats on the gateway are removed. This cannot be undone.") }
            // The preview starts right under the bar; the studio is the first thing to touch.
            .contentMargins(.top, 6, for: .scrollContent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? (editing == nil ? "Creating…" : "Saving…") : (editing == nil ? "Create" : "Save")) { Task { if editing == nil { await create() } else { await save() } } }.disabled(!canCreate)
                }
            }
            .task {
                if let e = editing, name.isEmpty {
                    name = e.name
                    description = e.description ?? ""
                    modelName = e.model ?? ""
                    provider = e.provider ?? ""
                    choice = BotAvatarStore.choice(for: e.name)
                }
                options = try? await runtime.api.get("/api/model/options", profile: runtime.selectedProfile)
            }
        }
        .presentationDetents([.large])
    }

    private func save() async {
        guard let e = editing else { return }
        busy = true; defer { busy = false }
        let n = e.name
        do {
            let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if d != (e.description ?? "") { let _: JSONValue = try await runtime.api.send("PUT", "/api/profiles/\(n)/description", json: .object(["description": .string(d)])) }
            if !modelName.isEmpty, modelName != (e.model ?? "") || provider != (e.provider ?? "") {
                let _: JSONValue = try await runtime.api.send("PUT", "/api/profiles/\(n)/model", json: .object(["provider": .string(provider), "model": .string(modelName)]))
            }
            BotAvatarStore.set(choice, for: n)
            await runtime.loadProfiles()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func deleteBot() async {
        guard let e = editing else { return }
        busy = true; defer { busy = false }
        do {
            let _: JSONValue = try await runtime.api.send("DELETE", "/api/profiles/\(e.name)", body: EmptyBody())
            if runtime.selectedProfile == e.name { runtime.selectedProfile = runtime.profiles.first { $0.name != e.name }?.name }
            await runtime.loadProfiles()
            NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func create() async {
        busy = true; defer { busy = false }
        let n = cleanName
        do {
            var body: [String: JSONValue] = ["name": .string(n)]
            if !cloneFrom.isEmpty { body["clone_from"] = .string(cloneFrom) }
            let _: JSONValue = try await runtime.api.send("POST", "/api/profiles", json: .object(body))
            let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !d.isEmpty { let _: JSONValue? = try? await runtime.api.send("PUT", "/api/profiles/\(n)/description", json: .object(["description": .string(d)])) }
            if !modelName.isEmpty { let _: JSONValue? = try? await runtime.api.send("PUT", "/api/profiles/\(n)/model", json: .object(["provider": .string(provider), "model": .string(modelName)])) }
            // The look chosen under the draft key belongs to the new name now.
            BotAvatarStore.set(choice, for: n)
            var colors = BotColors.stored()
            if let c = colors[draftKey] { colors[n] = c }
            colors[draftKey] = nil
            BotColors.save(colors)
            await runtime.loadProfiles()
            NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
