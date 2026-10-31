import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import VoryCore

/// Compose, the way Messages does it: a To: field that takes bots, the matching bots listed as
/// cards underneath, and the first message typed at the bottom. One bot starts a chat with it;
/// more than one starts a group chat with all of them.
struct NewChatSheet: View {
    enum Start {
        /// `voice`: straight into voice mode once the chat exists, after the first message if any.
        /// `model` and `reasoning`: picked on the composer's chip (or by "/model") before the chat
        /// existed; set on it before its first message.
        case chat(profile: String, text: String, attachments: [AttachmentPreview], cwd: String?, voice: Bool,
                  model: ChatSession.ModelPick?, reasoning: String?)
        case group(room: Room, text: String)
    }
    var runtime: GatewayRuntime
    var initialProjectID: String? = nil
    var onStart: (Start) -> Void
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    /// The bots list is shorter than one of its rows (see the list's `onGeometryChange`).
    @State private var listSqueezed = false
    /// A bot's row in the list: its 40 pt face and 10 pt above and below.
    private static let botRowHeight: CGFloat = 60
    #endif
    @State private var query = ""
    @State private var chosen: [ProfileInfo] = []
    /// While bots are chosen, an invisible mark sits at the start of the To: field. The
    /// software keyboard's backspace on an "empty" field deletes the mark, which is how
    /// Backspace removes the last chip (Messages style); `onKeyPress` only sees hardware keys.
    private let mark = "\u{200B}"
    private var typed: String { query.replacingOccurrences(of: mark, with: "") }
    @State private var text = ""
    @State private var quote = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?
    enum Field { case to }
    /// The first message's composer runs on a draft for the first bot in To: (#27): the chat's own
    /// card, files, "/" and "@" lists and model chip, with nothing on the gateway until it is sent.
    /// Another first bot is a new draft: the words and files go with it, a picked model does not.
    @State private var draft: ChatSession?
    /// Bumped as a bot is added: the cursor goes to the message.
    @State private var messageFocus = 0
    /// The chat was started (or voice mode): the draft's files went with it. Otherwise the sheet's
    /// close takes them away.
    @State private var started = false
    @Namespace private var composerSpace
    /// The project the chat starts in ("" for none): the Chats filter's project, else the
    /// gateway's active one. Only shown when the gateway has projects.
    @State private var projectID = ""

    private var candidates: [ProfileInfo] {
        let q = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return runtime.profiles.filter { p in
            !chosen.contains(where: { $0.name == p.name }) &&
            (q.isEmpty || p.label.lowercased().contains(q) || p.name.lowercased().contains(q))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(chosen.count > 1 ? "New Group Chat" : "New Message").font(.headline)
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.body.weight(.semibold))
                            .frame(width: 40, height: 40).voryGlassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Close")
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            // To: the chosen bots as chips that wrap onto more lines, then the search text.
            HStack(alignment: .top, spacing: 8) {
                Text("To:").foregroundStyle(.secondary).padding(.top, 4)
                FlowLayout(spacing: 6) {
                    ForEach(chosen) { p in
                        HStack(spacing: 5) {
                            BotAvatar(profile: p.name, size: 20)
                            Text(p.label).font(.subheadline).lineLimit(1)
                        }
                        .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
                        .background(Color.vory.opacity(0.15), in: .capsule)
                        // The whole chip, bot included: the face is not hit-testable on its own.
                        .contentShape(.capsule)
                        .onTapGesture { remove(p) }
                        .accessibilityLabel("\(p.label), \(DeviceWords.tap) to remove")
                    }
                    TextField(chosen.isEmpty ? "Bot name" : "", text: $query)
                        #if os(macOS)
                        // No boxed field inside the capsule.
                        .textFieldStyle(.plain)
                        #endif
                        .focused($focus, equals: .to)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .frame(minWidth: 90, minHeight: 28)
                        .onSubmit { if let first = candidates.first { add(first) } }
                        // Backspace while an input method is composing edits its text, never a chip.
                        .onKeyPress(.delete) { if typed.isEmpty, let last = chosen.last, !InputComposition.isActive { remove(last); return .handled }; return .ignored }
                        .onChange(of: query) { old, new in
                            guard !chosen.isEmpty else { return }
                            if !new.contains(mark) {
                                // The mark went: Backspace on an empty field takes the last chip
                                // (`remove` re-marks the field); otherwise the field lost its mark
                                // some other way and gets it back.
                                if old == mark, let last = chosen.last { remove(last) } else { query = mark + new }
                            } else if !new.hasPrefix(mark) {
                                query = mark + new.replacingOccurrences(of: mark, with: "")
                            }
                        }
                }
                Button { focus = .to } label: {
                    Image(systemName: "plus").font(.body.weight(.semibold))
                        .frame(width: 32, height: 32).voryGlassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain).accessibilityLabel("Add a bot")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .voryGlassEffect(.regular, in: .rect(cornerRadius: 22))
            .padding(.horizontal, 16)

            // The bots that match, as cards; a tap adds one to To:.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(candidates) { p in
                        Button { add(p) } label: {
                            HStack(spacing: 12) {
                                BotAvatar(profile: p.name, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(highlighted(p.label)).font(.body)
                                    Text([p.description, p.model.map { $0.split(separator: "/").last.map(String.init) ?? $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 72)
                    }
                    if candidates.isEmpty, !chosen.isEmpty, typed.isEmpty {
                        Text(chosen.count > 1 ? "These bots will share one group chat." : "Add another bot to make it a group chat.")
                            .font(.footnote).foregroundStyle(.secondary).padding(.top, 24)
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red).padding() }
                }
                .padding(.top, 6)
            }
            .scrollDismissesKeyboard(.interactively)
            #if os(macOS)
            // Squeezed by a tall first message (its "/" list open), the bots that match showed one row cut in
            // half above "In:". Under a row's height the list steps aside until there is room for it again.
            .onGeometryChange(for: Bool.self) { $0.size.height < Self.botRowHeight } action: { listSqueezed = $0 }
            .opacity(listSqueezed ? 0 : 1)
            .allowsHitTesting(!listSqueezed)
            .accessibilityHidden(listSqueezed)
            #endif
            .onAppear { if let initialProjectID, projectID.isEmpty { projectID = initialProjectID } }

            if chosen.count <= 1, runtime.projects.available == true, !runtime.projects.open.isEmpty {
                HStack(spacing: 8) {
                    Text("In:").foregroundStyle(.secondary)
                    Menu {
                        Picker("Project", selection: $projectID) {
                            Label("No project", systemImage: "folder.badge.questionmark").tag("")
                            ForEach(runtime.projects.open) { p in Label(p.name, systemImage: "folder.fill").tag(p.id) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: projectID.isEmpty ? "folder" : "folder.fill")
                            Text(runtime.projects.project(id: projectID)?.name ?? "No project")
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .font(.subheadline)
                    }
                    .accessibilityLabel("Project: \(runtime.projects.project(id: projectID)?.name ?? "none")")
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            // The first message, in the chat's own composer.
            if let draft {
                VStack(spacing: 6) {
                    if chosen.count > 1, !draft.staged.isEmpty {
                        Text(Self.groupFilesNote(count: draft.staged.count))
                            .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .accessibilityIdentifier("newchat.groupFiles")
                    }
                    ComposerView(chat: draft, text: $text, quote: $quote, namespace: composerSpace,
                                 role: .newMessage(.init(group: chosen.count > 1, enabled: !chosen.isEmpty && !busy,
                                                         placeholder: chosen.isEmpty ? "Choose a bot first" : "Message",
                                                         send: { t in Task { await start(t) } },
                                                         voice: { startVoice() },
                                                         focus: messageFocus)))
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            focus = .to
            if draft == nil { draft = .draft(runtime: runtime, profile: nil) }
        }
        .onChange(of: chosen.first?.name) { _, name in retarget(to: name) }
        // Closed without starting: the files picked for it go.
        .onDisappear { if !started, let draft { for a in draft.staged { draft.removeStaged(a.id) } } }
    }

    /// The draft for the first bot in To:: a new one when that bot changes, with the files.
    private func retarget(to name: String?) {
        guard let name else { return }
        if draft?.profile != name {
            let next = ChatSession.draft(runtime: runtime, profile: name)
            next.staged = draft?.staged ?? []
            draft = next
        }
        #if DEBUG
        // For a UI test: `-vory-test-stage-compose <name>.pdf` stages a small PDF in the message,
        // where the system file picker cannot be driven.
        if let draft, draft.staged.isEmpty, let file = UserDefaults.standard.string(forKey: "vory-test-stage-compose"), !file.isEmpty {
            let pdf = "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n"
            draft.stageAttachment(data: Data(pdf.utf8), name: file, kind: .pdf)
        }
        #endif
    }

    /// Voice mode from here: the chat with the one bot chosen, what was typed or attached as
    /// its first turn, then hands-free; ending voice mode leaves the person in that chat (#236).
    private func startVoice() {
        guard !busy else { return }
        guard chosen.count == 1, let draft else { error = chosen.isEmpty ? "Choose a bot first." : "Voice mode is a conversation with one bot."; return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        started = true
        onStart(.chat(profile: chosen[0].name, text: t, attachments: draft.staged, cwd: runtime.projects.project(id: projectID)?.startPath, voice: true,
                      model: draft.pendingModel, reasoning: draft.pendingReasoning))
        dismiss()
    }

    private func highlighted(_ label: String) -> AttributedString {
        var a = AttributedString(label)
        let q = typed.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, let r = a.range(of: q, options: .caseInsensitive) { a[r].font = .body.weight(.semibold); a[r].foregroundColor = .accentColor }
        return a
    }

    private func add(_ p: ProfileInfo) {
        guard chosen.count < 6 else { error = "A group chat can have up to six bots."; return }
        withAnimation(.snappy) { chosen.append(p) }
        query = mark
        focus = nil
        messageFocus += 1
    }

    /// Under a group's first message with files staged: they stay behind, and how to send them.
    static func groupFilesNote(count: Int) -> String {
        count == 1
            ? "Group chats start with text only, so this file won't be sent. Remove a bot to send it."
            : "Group chats start with text only, so these files won't be sent. Remove a bot to send them."
    }

    private func remove(_ p: ProfileInfo) {
        withAnimation(.snappy) { chosen.removeAll { $0.name == p.name } }
        query = chosen.isEmpty ? typed : mark + typed
    }

    private func start(_ typedText: String) async {
        let t = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chosen.isEmpty, chosen.count <= 6, !busy, let draft else { return }
        if chosen.count == 1 {
            guard !t.isEmpty || !draft.staged.isEmpty else { return }
            started = true
            onStart(.chat(profile: chosen[0].name, text: t, attachments: draft.staged, cwd: runtime.projects.project(id: projectID)?.startPath, voice: false,
                          model: draft.pendingModel, reasoning: draft.pendingReasoning))
            dismiss()
            return
        }
        guard !t.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            let room = try await GroupChats.create(runtime: runtime, name: chosen.map(\.label).joined(separator: ", "), profiles: chosen)
            // A group starts with words only: files picked for one bot go.
            for a in draft.staged { draft.removeStaged(a.id) }
            started = true
            onStart(.group(room: room, text: t))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
