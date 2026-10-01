import SwiftUI
import VoryCore

/// Tapping the title pill in a chat opens this: what the chat is, one row into the bot's profile
/// card, and one row into its instructions. Both of those edit through the dashboard API
/// (`PUT /api/profiles/{name}/description|model|soul`) and come back here on Back.
struct ProfileInfoSheet: View {
    var chat: ChatSession?
    var profileName: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Opens tall; the medium detent stays reachable by pulling it down.
    @State private var detent: PresentationDetent = .medium
    @State private var titleDraft = ""
    @State private var titleStatus: String?

    private var profile: ProfileInfo? { model.runtime?.profiles.first { $0.name == profileName } }

    var body: some View {
        NavigationStack {
            ProfileCardView(profileName: profileName, chat: chat)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    private func saveTitle(_ chat: ChatSession) async {
        guard let rt = model.runtime else { return }
        let t = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != chat.title else { return }
        do {
            var body: [String: JSONValue] = ["title": .string(t)]
            if let p = rt.selectedProfile { body["profile"] = .string(p) }
            let r: JSONValue = try await rt.api.send("PATCH", "/api/sessions/\(chat.storedID)", json: .object(body))
            chat.title = r["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? t
            titleStatus = "Title saved."
            NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
        } catch { titleStatus = error.localizedDescription }
    }
}

/// The bot's card: colour, description and default model, each saved as it is changed.
struct ProfileCardView: View {
    var profileName: String
    var chat: ChatSession? = nil
    @Environment(AppModel.self) private var model
    @AppStorage(BotColors.storageKey) private var colorsRaw = ""
    @State private var description = ""
    @State private var tint: Color = .accentColor
    @State private var avatar: BotAvatarChoice = .default
    @AppStorage(BotAvatarStore.storageKey) private var avatarsRaw = ""
    @State private var options: ModelOptionsResult?
    @State private var status: String?
    @State private var loaded = false
    @State private var renaming = false
    @State private var renameText = ""
    @AppStorage(ChatStyle.showToolCalls) private var showToolCalls = true
    @AppStorage(ChatStyle.showReasoning) private var showReasoning = true
    @AppStorage(ChatStyle.showTurnStats) private var showTurnStats = true
    @AppStorage(ChatStyle.showSystemNotes) private var showSystemNotes = true
    @AppStorage(ChatStyle.showBots) private var showBots = false

    private var rt: GatewayRuntime? { model.runtime }
    private var profile: ProfileInfo? { rt?.profiles.first { $0.name == profileName } }
    private var modelLabel: String {
        let s = [profile?.provider, profile?.model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
        return s.isEmpty ? "not set" : s
    }

    var body: some View {
        SettingsList {
            Section {
                VStack(spacing: 10) {
                    BotAvatar(profile: profileName, size: 110, active: true)
                    Text(profile?.label ?? profileName).font(.title2.weight(.semibold))
                    if let m = profile?.model, !m.isEmpty { Text(m).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section {
                CreatorStudio(profile: profileName, choice: $avatar)
                    .onChange(of: avatar) { _, c in
                        BotAvatarStore.set(c, for: profileName)
                        avatarsRaw = String(data: (try? JSONEncoder().encode(BotAvatarStore.stored())) ?? Data(), encoding: .utf8) ?? avatarsRaw
                    }
            } header: { Text("Creator Studio") } footer: { Text("How this bot looks everywhere: chats, \(DeviceWords.isMac ? "the menu bar" : "the Island"), notifications. Stored on this device.") }
            if let chat {
                Section {
                    Menu { ModelMenuContent(chat: chat) } label: {
                        LabeledContent("Model", value: chat.modelName.isEmpty ? "Choose…" : (chat.modelName.split(separator: "/").last.map(String.init) ?? chat.modelName))
                    }
                    .tint(.primary)
                    if let u = chat.usage, let pct = u.computedContextPercent {
                        LabeledContent("Context", value: "\(pct)% of \((u.contextMax ?? 0).formatted())")
                    }
                    Button { renameText = chat.title; renaming = true } label: {
                        LabeledContent("Name", value: chat.title.isEmpty ? "Untitled" : chat.title)
                    }
                    .tint(.primary)
                    .alert("Rename chat", isPresented: $renaming) {
                        TextField("Name", text: $renameText)
                        Button("Save") {
                            let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            Task { await chat.rename(name) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("The new name shows in the chat list and the header.") }
                } header: { Text("This chat") }
            }
            Section {
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(1...4)
                    .onSubmit { Task { await saveDescription() } }
                Button("Save description") { Task { await saveDescription() } }
                    .disabled(description == (profile?.description ?? ""))
            } header: { Text("Profile") } footer: { Text("The description is what other Hermes surfaces show for this bot (and what kanban routing reads).") }
            Section {
                if let o = options {
                    Menu { modelMenuItems(o.providers) } label: { LabeledContent("Default model", value: modelLabel) }
                } else { ProgressView() }
            } header: { Text("Model") } footer: { Text("Writes this profile's config.yaml. Running chats keep their own model.") }
            if let p = profile?.path { Section { Text(p).font(.caption.monospaced()).foregroundStyle(.tertiary) } header: { Text("Home") } }
            if let status { Section { Text(status).font(.footnote).foregroundStyle(status.hasPrefix("Saved") ? Color.secondary : Color.red) } }
            if let chat {
                Section {
                    Toggle("Show tool calls", isOn: $showToolCalls)
                    Toggle("Show reasoning", isOn: $showReasoning)
                    Toggle("Show tokens per second", isOn: $showTurnStats)
                    Toggle("Show system notes", isOn: $showSystemNotes)
                    Toggle("Bot beside replies", isOn: $showBots)
                } header: { Text("Show in chats") } footer: { Text("Also under Settings › Appearance.") }
            }
            Section {
                NavigationLink { SoulEditorView(profileName: profileName) } label: {
                    Label("Instructions (SOUL.md)", systemImage: "doc.text")
                }
            } footer: { Text("The bot's standing instructions. Edits are written to the gateway when you \(DeviceWords.tap) the check mark.") }
        }
        .navigationTitle(profile?.label ?? profileName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            description = profile?.description ?? ""
            tint = BotColors.color(for: profileName)
            avatar = BotAvatarStore.choice(for: profileName)
            if let rt { options = try? await rt.api.get("/api/model/options", profile: profileName) }
        }
    }

    @ViewBuilder private func modelMenuItems(_ providers: [ModelProvider]) -> some View {
        ForEach(providers) { p in
            Section(p.name) {
                ForEach(p.models ?? [], id: \.self) { m in
                    Button(m) { Task { await saveModel(provider: p.slug, model: m) } }
                }
            }
        }
    }

    private func saveDescription() async {
        guard let rt else { return }
        do {
            let _: JSONValue = try await rt.api.send("PUT", "/api/profiles/\(profileName)/description", json: .object(["description": .string(description)]))
            await rt.loadProfiles()
            status = "Saved description."
        } catch { status = error.localizedDescription }
    }

    private func saveModel(provider: String, model: String) async {
        guard let rt else { return }
        do {
            let _: JSONValue = try await rt.api.send("PUT", "/api/profiles/\(profileName)/model", json: .object(["provider": .string(provider), "model": .string(model)]))
            await rt.loadProfiles()
            status = "Saved model \(model)."
        } catch { status = error.localizedDescription }
    }
}

/// Full-screen editor for SOUL.md; the check mark writes it back.
struct SoulEditorView: View {
    var profileName: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Group {
            if loading { ProgressView("Loading SOUL.md…") }
            else {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty { Text("Write the bot's instructions in Markdown…").foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.top, 8).allowsHitTesting(false) }
                    }
            }
        }
        .navigationTitle("SOUL.md")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await save() } } label: { if saving { ProgressView() } else { Image(systemName: "checkmark") } }
                    .disabled(saving || text == original)
                    .accessibilityLabel("Save instructions")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(8) }
        }
        .task {
            guard let rt = model.runtime else { loading = false; return }
            do {
                let r: JSONValue = try await rt.api.get("/api/profiles/\(profileName)/soul")
                text = r["content"]?.stringValue ?? ""; original = text
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func save() async {
        guard let rt = model.runtime else { return }
        saving = true; defer { saving = false }
        do {
            let _: JSONValue = try await rt.api.send("PUT", "/api/profiles/\(profileName)/soul", json: .object(["content": .string(text)]))
            original = text
            error = nil
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
