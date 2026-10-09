import SwiftUI
import VoryCore

/// Tapping the title pill in a chat opens this: the bot's card (header plus Info), with the
/// chat's own rows when opened from one. The card edits through the dashboard API
/// (`PUT /api/profiles/{name}/description|model|soul`).
struct ProfileInfoSheet: View {
    var chat: ChatSession?
    var profileName: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Opens at the medium height; the tall one is a pull away.
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            #if os(iOS)
            // The card's own round buttons over its header stand in for the bar.
            ProfileCardView(profileName: profileName, chat: chat, floatingControls: true, onClose: { dismiss() })
                .toolbar(.hidden, for: .navigationBar)
            #else
            ProfileCardView(profileName: profileName, chat: chat)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            #endif
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }
}

/// The bot's card: a hero header (the face, then the name and description on one card, with
/// round Close and … buttons over it in a sheet), then the Info content: Character, Instructions,
/// Description, Model, the chat's rows when opened from a chat, Show in chats, Home. Built so a
/// row of tabs can go between the header and the content later without redoing the header.
/// Every setting saves as it is changed.
struct ProfileCardView: View {
    var profileName: String
    var chat: ChatSession? = nil
    /// Round buttons over the header (a sheet); a pushed page keeps the navigation bar's.
    var floatingControls = false
    var onClose: (() -> Void)? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
    private var label: String { profile?.label ?? profileName }
    private var modelLabel: String {
        let s = [profile?.provider, profile?.model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
        return s.isEmpty ? "not set" : s
    }
    /// What the header says under the name: the description, or the model until there is one.
    private var headerLine: String {
        let d = (profile?.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { return d }
        if let m = profile?.model, !m.isEmpty { return m }
        return "No description yet"
    }

    var body: some View {
        SettingsList {
            header
            Section {
                CreatorStudio(profile: profileName, choice: $avatar)
                    .onChange(of: avatar) { _, c in
                        BotAvatarStore.set(c, for: profileName)
                        avatarsRaw = String(data: (try? JSONEncoder().encode(BotAvatarStore.stored())) ?? Data(), encoding: .utf8) ?? avatarsRaw
                    }
            } header: { Text("Character") } footer: { Text("How this bot looks everywhere: chats, \(DeviceWords.isMac ? "the menu bar" : "the Island"), notifications. Stored on this device.") }
            Section {
                NavigationLink { SoulEditorView(profileName: profileName) } label: {
                    Label("Instructions (SOUL.md)", systemImage: "doc.text")
                }
            } footer: { Text("The bot's standing instructions. Edits are written to the gateway when you \(DeviceWords.tap) the check mark.") }
            Section {
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(1...4)
                    .onSubmit { Task { await saveDescription() } }
                Button("Save description") { Task { await saveDescription() } }
                    .disabled(description == (profile?.description ?? ""))
            } header: { Text("Description") } footer: { Text("What other Hermes surfaces show for this bot (and what kanban routing reads).") }
            Section {
                if let o = options {
                    Menu { modelMenuItems(o.providers) } label: { LabeledContent("Default model", value: modelLabel) }
                } else { ProgressView() }
            } header: { Text("Model") } footer: { Text("Writes this profile's config.yaml. Running chats keep their own model.") }
            if let chat {
                Section {
                    // A pencil says the name can be changed (#286); the row opens the dialog.
                    Button { renameText = chat.title; renaming = true } label: {
                        LabeledContent("Name") {
                            HStack(spacing: 6) {
                                Text(chat.title.isEmpty ? "Untitled" : chat.title).foregroundStyle(.secondary)
                                Image(systemName: "pencil").foregroundStyle(.tint)
                            }
                        }
                    }
                    .tint(.primary)
                    .accessibilityHint("Renames this chat")
                    .accessibilityIdentifier("profile.rename")
                    Menu { ModelMenuContent(chat: chat) } label: {
                        LabeledContent("Model", value: chat.modelName.isEmpty ? "Choose…" : (chat.modelName.split(separator: "/").last.map(String.init) ?? chat.modelName))
                    }
                    .tint(.primary)
                    if let u = chat.usage, let pct = u.computedContextPercent {
                        LabeledContent("Context", value: "\(pct)% of \((u.contextMax ?? 0).formatted())")
                    }
                } header: { Text("This chat") }
                Section {
                    Toggle("Show tool calls", isOn: $showToolCalls)
                    Toggle("Show reasoning", isOn: $showReasoning)
                    Toggle("Show tokens per second", isOn: $showTurnStats)
                    Toggle("Show system notes", isOn: $showSystemNotes)
                    Toggle("Bot beside replies", isOn: $showBots)
                } header: { Text("Show in chats") } footer: { Text("Also under Settings › Appearance.") }
            }
            if let status { Section { Text(status).font(.footnote).foregroundStyle(status.hasPrefix("Saved") ? Color.secondary : Color.red) } }
            if let p = profile?.path {
                Section { Text(p).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled) } header: { Text("Home") }
            }
        }
        .navigationTitle(floatingControls ? "" : label)
        // On the card, not its Name row: the … menu over the header asks for it before the
        // list has built that row.
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let chat else { return }
                Task { await chat.rename(name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The new name shows in the chat list and the header.") }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) { if floatingControls { controls } }
        #endif
        .task {
            guard !loaded else { return }
            loaded = true
            description = profile?.description ?? ""
            tint = BotColors.color(for: profileName)
            avatar = BotAvatarStore.choice(for: profileName)
            if let rt { options = try? await rt.api.get("/api/model/options", profile: profileName) }
        }
    }

    /// The face, large and centred, then one card with the name and the description under a
    /// hairline. VoiceOver reads the three as one element.
    private var header: some View {
        Section {
            VStack(spacing: 16) {
                BotAvatar(profile: profileName, size: 132, active: true)
                    .padding(.top, floatingControls ? 48 : 6)
                VStack(spacing: 0) {
                    Text(label)
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                    Divider().padding(.horizontal, 16)
                    Text(headerLine)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity)
                .background(Self.cardFill, in: .rect(cornerRadius: 20))
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label). \(headerLine)")
            .accessibilityIdentifier("profile.header")
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
    }

    private static var cardFill: Color {
        #if os(iOS)
        Color(.secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    #if os(iOS)
    /// Round Close on the left and, from a chat, the … menu on the right, over the header.
    private var controls: some View {
        HStack {
            Button { if let onClose { onClose() } else { dismiss() } } label: { circle("xmark") }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("profile.close")
            Spacer()
            if let chat {
                Menu {
                    Button { renameText = chat.title; renaming = true } label: { Label("Rename chat", systemImage: "pencil") }
                } label: { circle("ellipsis") }
                .accessibilityLabel("More")
                .accessibilityIdentifier("profile.more")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.top, 12)
    }

    /// A 40 pt glass circle; a solid one under Reduce Transparency.
    @ViewBuilder private func circle(_ symbol: String) -> some View {
        let glyph = Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(.primary).frame(width: 40, height: 40).contentShape(.circle)
        if reduceTransparency {
            glyph.background(Circle().fill(Self.cardFill).overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)))
        } else {
            glyph.glassEffect(.regular.interactive(), in: .circle)
        }
    }
    #endif

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
