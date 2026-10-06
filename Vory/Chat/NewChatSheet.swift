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
        case chat(profile: String, text: String, attachments: [AttachmentPreview], cwd: String?, voice: Bool)
        case group(room: Room, text: String)
    }
    var runtime: GatewayRuntime
    var initialProjectID: String? = nil
    var onStart: (Start) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chosen: [ProfileInfo] = []
    /// While bots are chosen, an invisible mark sits at the start of the To: field. The
    /// software keyboard's backspace on an "empty" field deletes the mark, which is how
    /// Backspace removes the last chip (Messages style); `onKeyPress` only sees hardware keys.
    private let mark = "\u{200B}"
    private var typed: String { query.replacingOccurrences(of: mark, with: "") }
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?
    enum Field { case to }
    /// The message field is UIKit (ComposerTextView), so its focus is a plain flag.
    @State private var messageFocused = false
    /// Settings › Appearance › Return key sends; the field adds a line otherwise.
    @AppStorage(ChatStyle.returnSends) private var returnSends = false
    /// Files picked before the chat exists; staged into the chat as soon as it opens.
    @State private var staged: [AttachmentPreview] = []
    /// The project the chat starts in ("" for none): the Chats filter's project, else the
    /// gateway's active one. Only shown when the gateway has projects.
    @State private var projectID = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var showRecorder = false
    @State private var stagedPreview: URL?
    @State private var showAttach = false
    @State private var attachPanelHeight: CGFloat = 356

    private var candidates: [ProfileInfo] {
        let q = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return runtime.profiles.filter { p in
            !chosen.contains(where: { $0.name == p.name }) &&
            (q.isEmpty || p.label.lowercased().contains(q) || p.name.lowercased().contains(q))
        }
    }
    private var canSend: Bool { !chosen.isEmpty && chosen.count <= 6 && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!staged.isEmpty && chosen.count == 1)) && !busy }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(chosen.count > 1 ? "New Group Chat" : "New Message").font(.headline)
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.body.weight(.semibold))
                            .frame(width: 40, height: 40).glassEffect(.regular.interactive(), in: .circle)
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
                        .onKeyPress(.delete) { if typed.isEmpty, let last = chosen.last { remove(last); return .handled }; return .ignored }
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
                Button { messageFocused = false; focus = .to } label: {
                    Image(systemName: "plus").font(.body.weight(.semibold))
                        .frame(width: 32, height: 32).glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain).accessibilityLabel("Add a bot")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
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
            // The first message, with the same attach button as a chat's composer.
            VStack(spacing: 8) {
                if !staged.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(staged) { a in
                                StagedCard(attachment: a, onOpen: { stagedPreview = a.localURL },
                                           onRemove: { withAnimation(.snappy) { staged.removeAll { $0.id == a.id } } })
                                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                            }
                        }
                        .padding(.leading, 2)
                    }
                    // Only as tall as the cards: a scroll view in this stack would otherwise split
                    // the sheet's spare height with the bot list and float the cards up.
                    .frame(height: StagedCard.side + 12)
                    .quickLookPreview($stagedPreview)
                    if chosen.count > 1 {
                        Text("Attachments go with a chat to one bot; a group chat starts with text only.")
                            .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            HStack(alignment: .bottom, spacing: 8) {
                // The same + panel as a chat's composer (#236); it takes the keyboard's place.
                Button {
                    if !showAttach { messageFocused = false; focus = nil }
                    withAnimation(.snappy(duration: 0.32)) { showAttach.toggle() }
                } label: {
                    Image(systemName: "plus").font(.body.weight(.semibold))
                        .rotationEffect(.degrees(showAttach ? 45 : 0))
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(chosen.count != 1)
                .accessibilityLabel(showAttach ? "Close attach panel" : "Attach")
                .accessibilityIdentifier("newchat.attach")
                HStack(alignment: .bottom, spacing: 6) {
                    ComposerTextView(text: $text, placeholder: chosen.isEmpty ? "Choose a bot first" : "Message", focused: $messageFocused, accessibilityID: "newchat.text",
                                     onSend: { Task { await start() } },
                                     onPasteData: { data, name, type in stage(data, name: name, type: type) },
                                     returnSends: returnSends)
                        .padding(.leading, 14).padding(.vertical, 7)
                        .disabled(chosen.isEmpty)
                    // Voice mode with the bot chosen; whatever is typed or attached goes first.
                    Button { startVoice() } label: {
                        Image(systemName: "mic.fill").font(.body.weight(.semibold))
                            .foregroundStyle(chosen.count == 1 ? Color.primary : Color.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain).disabled(chosen.count != 1 || busy)
                    .padding(.bottom, 4)
                    .accessibilityLabel("Voice mode")
                    .accessibilityIdentifier("newchat.voice")
                    Button { Task { await start() } } label: {
                        Image(systemName: busy ? "ellipsis" : "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(canSend ? AnyShapeStyle(Color.vory) : AnyShapeStyle(.tertiary), in: .circle)
                    }
                    .buttonStyle(.plain).disabled(!canSend)
                    .padding(.trailing, 4).padding(.bottom, 4)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("newchat.send")
                }
                .frame(minHeight: 36)
                // Plain glass: an interactive capsule answered touches meant for the field's Paste menu.
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
            // The panel grows out of the + button and sits above the field.
            .overlay(alignment: .topLeading) {
                if showAttach {
                    AttachPanel(items: attachItems) { withAnimation(.snappy(duration: 0.28)) { showAttach = false } }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { attachPanelHeight = $0 }
                        .offset(y: -(attachPanelHeight + 10))
                        .transition(.scale(scale: 0.2, anchor: .bottomLeading).combined(with: .opacity))
                        .zIndex(2)
                }
            }
            // Anything tapped outside the panel closes it.
            .background {
                if showAttach {
                    Color.clear.contentShape(.rect).frame(width: 3000, height: 4000)
                        .onTapGesture { withAnimation(.snappy(duration: 0.28)) { showAttach = false } }
                }
            }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear { focus = .to }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in Task { await importPhotos(items) } }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) { CameraPicker { data, name in stage(data, name: name, kind: .image) }.ignoresSafeArea() }
        #endif
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { for u in urls { importFile(u) } }
        }
        .sheet(isPresented: $showRecorder) { AudioRecorderSheet { url in importFile(url) }.sheetFrame(.compact) }
    }

    /// The + panel's rows: a chat composer's, with Message History greyed (there is no chat yet).
    private var attachItems: [AttachItem] {
        var items: [AttachItem] = []
        #if os(iOS)
        items.append(AttachItem(title: "Camera", symbol: "camera.fill", color: .black, disabled: !UIImagePickerController.isSourceTypeAvailable(.camera)) { showCamera = true })
        #endif
        items.append(AttachItem(title: "Photos", symbol: "photo.on.rectangle.angled", color: Color(red: 0.98, green: 0.45, blue: 0.3)) { showPhotos = true })
        items.append(AttachItem(title: "Files", symbol: "folder.fill", color: .blue) { showFiles = true })
        items.append(AttachItem(title: "Audio", symbol: "waveform", color: .red) { showRecorder = true })
        #if os(iOS)
        items.append(AttachItem(title: "Voice mode", symbol: "waveform.badge.mic", color: .pink) { startVoice() })
        #endif
        items.append(AttachItem(title: "Paste", symbol: "doc.on.clipboard.fill", color: .indigo) { pasteAttachment() })
        items.append(AttachItem(title: "Message History", symbol: "clock.arrow.circlepath", color: .orange, disabled: true) {})
        return items
    }

    /// Voice mode from here: the chat with the one bot chosen, what was typed or attached as
    /// its first turn, then hands-free; ending voice mode leaves the person in that chat (#236).
    private func startVoice() {
        guard !busy else { return }
        guard chosen.count == 1 else { error = chosen.isEmpty ? "Choose a bot first." : "Voice mode is a conversation with one bot."; return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onStart(.chat(profile: chosen[0].name, text: t, attachments: staged, cwd: runtime.projects.project(id: projectID)?.startPath, voice: true))
        dismiss()
    }

    // MARK: Attachments before the chat exists

    private func stage(_ data: Data, name: String, kind: AttachmentPreview.Kind) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("newchat-staged", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + "-" + name)
        guard (try? data.write(to: url)) != nil else { error = "Could not stage \(name)."; return }
        withAnimation(.snappy) { staged.append(AttachmentPreview(id: url.lastPathComponent, name: name, kind: kind, localURL: url, byteCount: data.count)) }
    }

    private func stage(_ data: Data, name: String, type: UTType) {
        stage(data, name: name, kind: type.conforms(to: .image) ? .image : type.conforms(to: .movie) ? .video : type.conforms(to: .pdf) ? .pdf : type.conforms(to: .audio) ? .audio : .file)
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
            stage(data, name: "\(isVideo ? "video" : "photo")-\(Int(Date().timeIntervalSince1970)).\(ext)", kind: isVideo ? .video : .image)
        }
        photoItems = []
    }

    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { error = "Could not read \(url.lastPathComponent)"; return }
        if data.count > 200 * 1024 * 1024 { error = "\(url.lastPathComponent) is larger than 200 MB."; return }
        stage(data, name: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension) ?? .data)
    }

    private func pasteAttachment() {
        let pb = UIPasteboard.general
        if pb.hasImages, let img = pb.image, let data = img.jpegData(compressionQuality: 0.9) {
            stage(data, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg", kind: .image)
        } else if let s = pb.string {
            text += s
        }
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
        messageFocused = true
    }

    private func remove(_ p: ProfileInfo) {
        withAnimation(.snappy) { chosen.removeAll { $0.name == p.name } }
        query = chosen.isEmpty ? typed : mark + typed
    }

    private func start() async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chosen.isEmpty, canSend else { return }
        if chosen.count == 1 {
            onStart(.chat(profile: chosen[0].name, text: t, attachments: staged, cwd: runtime.projects.project(id: projectID)?.startPath, voice: false))
            dismiss()
            return
        }
        guard !t.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            let room = try await GroupChats.create(runtime: runtime, name: chosen.map(\.label).joined(separator: ", "), profiles: chosen)
            onStart(.group(room: room, text: t))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
