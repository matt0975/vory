import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import VoryCore

struct ComposerView: View {
    @Bindable var chat: ChatSession
    @Binding var text: String
    /// The bubble being replied to; sent as a quote block above the message.
    @Binding var quote: String
    /// The dock's morph namespace: the text capsule (alone, not the whole stack — the steer strip
    /// and the command list come and go under it) is what an approval card morphs from.
    var namespace: Namespace.ID
    /// Keyboard focus, driven both ways (the text view is UIKit; see ComposerTextView).
    @State private var focused = false
    @AppStorage(VoiceSettings.holdMicKey) private var holdMicRaw = VoiceSettings.HoldMicAction.dictate.rawValue
    /// Settings › Appearance › Return key sends (the on-screen keyboard's Return; a line otherwise).
    @AppStorage(ChatStyle.returnSends) private var returnSends = false
    /// Settings › Voice › Hold the mic to: Start voice mode. The Mac's mic is a click and keeps it.
    private var holdStartsVoiceMode: Bool {
        #if os(iOS)
        return VoiceSettings.HoldMicAction(rawValue: holdMicRaw) == .voiceMode
        #else
        return false
        #endif
    }
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var showRecorder = false
    @State private var showHistory = false
    @State private var historyCursor: Int?
    @State private var catalog: CommandsCatalog?
    /// The gateway's models, loaded the first time "/model " is typed in this chat.
    @State private var modelOptions: ModelOptionsResult?
    @State private var modelOptionsLoading = false
    /// A chooser row marked on purpose (the arrows, or a model completed with Tab), for the text
    /// it was marked on; otherwise SlashMenu.markedIndex decides what is marked.
    @State private var menuMark: SlashMenu.Mark?
    /// Escape closed the chooser for the word being typed; a new word opens it again.
    @State private var menuDismissed = false
    @State private var dictation = DictationController()
    @State private var stagedPreview: URL?
    /// Shown after a paste that dropped a lot of text into the field.
    @State private var longTextOffer = false
    @State private var showAttach = false
    @State private var attachPanelHeight: CGFloat = 356
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model

    /// "@" at the start of the word being typed lists the bots; a pick puts "@name " in its place.
    private var mentionQuery: String? {
        guard !text.hasPrefix("/"), !showingRecalled,
              let last = text.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("@") else { return nil }
        return String(last.dropFirst())
    }
    private var mentionSuggestions: [ProfileInfo] {
        guard let q = mentionQuery?.lowercased(), let profiles = model.runtime?.profiles else { return [] }
        return profiles.filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) || $0.label.lowercased().hasPrefix(q) }
    }
    private func pickMention(_ p: ProfileInfo) {
        var parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if !parts.isEmpty { parts[parts.count - 1] = "@" + p.name }
        text = parts.joined(separator: " ") + " "
    }

    /// The field's text becomes a staged text file and the field is cleared.
    private func attachTextAsFile() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let data = t.data(using: .utf8) else { return }
        let firstLine = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Pasted text"
        let stem = String(firstLine.prefix(32)).components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
            .trimmingCharacters(in: .whitespaces)
        chat.stageAttachment(data: data, name: (stem.isEmpty ? "Pasted text" : stem) + ".txt", kind: .file)
        withAnimation(.snappy) { longTextOffer = false; text = "" }
    }

    /// Up or Down put a history entry in the field and nothing has been typed since: no chooser
    /// opens for it (see SlashMenu.isRecalled).
    private var showingRecalled: Bool { SlashMenu.isRecalled(text, history: chat.composerHistory, cursor: historyCursor) }

    /// The chooser above the field: the gateway's commands and skills while a "/word" is typed,
    /// its models after "/model " (see SlashMenu).
    private var menuContext: SlashMenu.Context? { showingRecalled ? nil : SlashMenu.context(for: text) }

    /// The chooser's context while it is open (not closed with Escape).
    private var openMenuContext: SlashMenu.Context? { menuDismissed ? nil : menuContext }

    private var menuItems: [SlashMenu.Item] {
        guard let ctx = openMenuContext else { return [] }
        switch ctx.kind {
        case .command: return catalog.map { SlashMenu.commandItems($0, query: ctx.query) } ?? []
        case .model:
            return modelOptions.map { SlashMenu.modelItems($0, current: chat.modelName, currentProvider: chat.info?.provider, query: ctx.query) } ?? []
        }
    }

    /// The row Return takes, shown marked; nil when none is (see SlashMenu.markedIndex).
    private var markedIndex: Int? {
        openMenuContext.flatMap { SlashMenu.markedIndex(menuItems, context: $0, mark: menuMark) }
    }

    /// The model list is on its way: the chooser says so rather than staying shut.
    private var menuLoading: Bool { openMenuContext?.kind == .model && modelOptions == nil && modelOptionsLoading }

    /// The command list scrolls inside a cap: about 30 % of the screen, so with the keyboard up
    /// it stops well short of the bot header at the top.
    private var commandListCap: CGFloat { max(120, min(280, UIScreen.main.bounds.height * 0.30)) }

    /// A row tapped or taken with Return, or completed with Tab (see SlashMenu.outcome): a
    /// command that takes nothing runs as if typed and sent, a model switches this chat the way
    /// the model menu does (with a line in the thread), the chat's own model stays, and anything
    /// else goes in the field.
    private func pick(_ item: SlashMenu.Item, completing: Bool = false) {
        menuMark = nil
        // With a reply quoted or files staged the text goes out as a message, not a command
        // (ChatSession.send), so the command waits in the field instead.
        let outcome = SlashMenu.outcome(of: item, in: text, wholeText: menuContext?.wholeText == true,
                                        completing: completing, canRun: quote.isEmpty && chat.staged.isEmpty)
        switch outcome {
        case .run(let command):
            text = command
            Task { await send() }
        case .fill(let filled):
            text = filled
            // A model completed with Tab stays marked, so Return then takes that row, provider and all.
            if item.kind == .model, let ctx = SlashMenu.context(for: filled) { menuMark = SlashMenu.Mark(context: ctx, id: item.id) }
        case .switchModel:
            text = ""
            Task { await chat.switchModel(provider: item.provider, model: item.name) }
        case .keepModel:
            text = ""
        }
    }

    /// A bare Return with a chooser open (a bare Return would otherwise add a line, or send,
    /// under a half-typed command): the marked row, or a typed "/model …" sent as typed (see
    /// SlashMenu.returnAction). With a reply quoted or files staged that text would go to the bot
    /// as a message, so it stays in the field instead. True when Return was used here.
    private func takeOnReturn() -> Bool {
        switch SlashMenu.returnAction(menuItems, context: openMenuContext, marked: markedIndex,
                                      canRun: quote.isEmpty && chat.staged.isEmpty) {
        case .take(let item): pick(item); return true
        case .send: Task { await send() }; return true
        case .hold: return true
        case .keep: break
        }
        if let p = mentionSuggestions.first { pickMention(p); return true }
        return false
    }

    /// Tab completes the marked row (see SlashMenu.tabCompletion for when none is) and never
    /// runs anything. With the list open and nothing to complete it does nothing, rather than
    /// put a tab in the field or move the focus.
    private func completeOnTab() -> Bool {
        let items = menuItems
        if let ctx = openMenuContext, !items.isEmpty {
            if let completion = SlashMenu.tabCompletion(items, context: ctx, marked: markedIndex) {
                pick(completion.item, completing: true)
                if !completion.marks { menuMark = nil }
            }
            return true
        }
        if let p = mentionSuggestions.first { pickMention(p); return true }
        return false
    }

    /// Up and Down move the chooser's mark (round the ends) while it is open; history recall
    /// has them otherwise.
    private func moveSelection(_ delta: Int) -> Bool {
        let items = menuItems
        guard let ctx = openMenuContext, let i = SlashMenu.move(markedIndex, by: delta, count: items.count) else { return false }
        menuMark = SlashMenu.Mark(context: ctx, id: items[i].id)
        return true
    }

    /// Escape: the chooser closes until the word changes.
    private func dismissMenu() -> Bool {
        guard !menuItems.isEmpty || menuLoading else { return false }
        withAnimation(.snappy(duration: 0.2)) { menuDismissed = true }
        return true
    }

    private func loadModelOptions() async {
        guard modelOptions == nil, !modelOptionsLoading else { return }
        modelOptionsLoading = true
        defer { modelOptionsLoading = false }
        do { modelOptions = try await chat.modelOptions() }
        catch {
            // Typed past "/model " before the list came: the load was called off, nothing failed.
            guard !Task.isCancelled else { return }
            chat.banner = RestartRequiredCallout.matches(error.localizedDescription) ? "Hermes needs a restart: see Settings › System" : error.localizedDescription
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if !menuItems.isEmpty || menuLoading {
                SlashMenuList(items: menuItems, selection: markedIndex, loading: menuLoading, cap: commandListCap) { pick($0) }
                    // In place, not sliding up from under the keyboard.
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))            }
            if !mentionSuggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(mentionSuggestions) { p in
                            Button { pickMention(p) } label: {
                                HStack(spacing: 10) {
                                    BotAvatar(profile: p.name, size: 26)
                                    Text("@" + p.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    if let m = p.model?.split(separator: "/").last { Text(String(m)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    Spacer(minLength: 0)
                                }
                                .frame(height: 34)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if p.id != mentionSuggestions.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 4)
                }
                .frame(height: min(commandListCap, CGFloat(mentionSuggestions.count) * 40 + 8))
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
            if longTextOffer {
                // A big paste: offer to send it as a file rather than a wall of text.
                HStack(spacing: 10) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text("That's a lot of text.").font(.subheadline)
                    Spacer(minLength: 0)
                    Button("Keep") { withAnimation(.snappy) { longTextOffer = false } }.font(.subheadline)
                    Button("Attach as file") { attachTextAsFile() }.font(.subheadline.weight(.semibold)).buttonStyle(.glassProminent)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !chat.staged.isEmpty {
                // Cards with a real preview of each file, the kind on a pill, × on the corner.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(chat.staged) { a in
                            StagedCard(attachment: a, onOpen: { stagedPreview = a.localURL },
                                       onRemove: { withAnimation(.snappy) { chat.removeStaged(a.id) } })
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    .padding(.leading, 2)
                }
                .quickLookPreview($stagedPreview)
            }
            if !quote.isEmpty {
                // What the reply answers: the first lines of the bubble, with a way out.
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.vory).frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replying to").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(quote).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { withAnimation(.snappy) { quote = "" } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Cancel reply")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                // The bar beside the words is flexible in height; without this the strip took
                // the whole screen.
                .fixedSize(horizontal: false, vertical: true)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // Same shape as the Messages app: a round attach button outside the field, and one
            // thin capsule holding the text with the mic or send control inside its trailing edge.
            HStack(alignment: .bottom, spacing: 8) {
                attachMenu
                HStack(alignment: .bottom, spacing: 6) {
                    if dictation.isListening {
                        // The field is the waveform while the mic listens; the words land when it stops.
                        DictationWaveform(dictation: dictation)
                            .padding(.leading, 14).padding(.vertical, 7)
                            .transition(.opacity)
                    } else {
                        textField
                    }
                    trailingControl
                        .padding(.trailing, 4).padding(.bottom, 4)
                }
                .frame(minHeight: 36)
                // Plain glass, not interactive: an interactive capsule answers touches itself,
                // and on the phone that swallowed the taps meant for the text field's Paste menu.
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .glassEffectID("dock", in: namespace)
            }
            if chat.isRunning, !text.isEmpty {
                HStack {
                    Text("Agent is working. Send queues the message.").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Steer now") { let t = text; text = ""; Task { await chat.steer(t) } }.font(.caption2)
                }
                .padding(.horizontal, 8)
            }
        }
        // The attach panel grows out of the + button and sits above the whole composer, the reply
        // strip included (anchored to the button it overlapped the strip).
        .overlay(alignment: .topLeading) {
            if showAttach {
                attachPanel
                    .glassEffectID("attach", in: namespace)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { attachPanelHeight = $0 }
                    .offset(y: -(attachPanelHeight + 10))
                    .transition(.scale(scale: 0.2, anchor: .bottomLeading).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        // Anything tapped outside the panel closes it: a clear catcher far larger than the
        // composer, under the panel.
        .background {
            if showAttach {
                Color.clear.contentShape(.rect).frame(width: 3000, height: 4000)
                    .onTapGesture { withAnimation(.snappy(duration: 0.28)) { showAttach = false } }
            }
        }
        .animation(.snappy(duration: 0.25), value: menuItems.map(\.id))
        .animation(.snappy(duration: 0.25), value: mentionSuggestions.map(\.name))
        .animation(.snappy(duration: 0.2), value: dictation.isListening)
        // Files dropped on the composer (the Finder on a Mac, another app on an iPad) are staged like picked ones.
        .dropDestination(for: URL.self) { urls, _ in
            for u in urls { importFile(u) }
            return !urls.isEmpty
        }
        #if os(macOS)
        // File › Import from iPhone or iPad (Continuity Camera): a photo or a scan taken on the
        // phone is staged here, the Mac's stand-in for the camera row.
        .importsItemProviders([.image, .pdf]) { providers in
            for p in providers {
                let pdf = p.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
                let type = pdf ? UTType.pdf : UTType.image
                _ = p.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    guard let data else { return }
                    let name = (p.suggestedName ?? (pdf ? "Scan" : "Photo")) + (pdf ? ".pdf" : ".jpg")
                    Task { @MainActor in chat.stageAttachment(data: data, name: name, kind: pdf ? .pdf : .image) }
                }
            }
            return !providers.isEmpty
        }
        #endif
        // Why the mic did nothing (no permission, no recognizer): said in the banner, not swallowed.
        .onChange(of: dictation.error) { _, e in if let e { chat.banner = e; dictation.error = nil } }
        #if os(macOS)
        // A new chat on the Mac (⌘N, the list's button, an intent) opens with the cursor in
        // the box, ready to type, as the box is after a message goes out (#212).
        .onAppear { if chat.items.isEmpty { focused = true } }
        #endif
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in Task { await importPhotos(items) } }
        #if os(iOS)
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) { CameraPicker { data, name in chat.stageAttachment(data: data, name: name, kind: .image) }.ignoresSafeArea().withAppModel() }
        #endif
        #endif
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { for u in urls { importFile(u) } }
        }
        .sheet(isPresented: $showRecorder) { AudioRecorderSheet { url in importFile(url, kind: .audio) }.sheetFrame(.compact).withAppModel() }
        .sheet(isPresented: $showHistory) { HistorySheet(history: chat.composerHistory) { text = $0 }.sheetFrame().withAppModel() }
    }

    /// The field itself (its own view: the body's one expression grew past what the compiler
    /// types in reasonable time).
    private var textField: some View {
        ComposerTextView(text: $text, placeholder: "Type / for commands", focused: $focused, accessibilityID: "composer.text",
                         onSend: { Task { await send() } },
                         onPasteData: { data, name, type in stagePasted(data, name: name, type: type) },
                         onArrow: { moveSelection($0) || recallHistory($0) },
                         onReturn: { takeOnReturn() },
                         returnSends: returnSends,
                         menuOpen: !menuItems.isEmpty || menuLoading,
                         onTab: { completeOnTab() },
                         onEscape: { dismissMenu() })
            .padding(.leading, 14).padding(.vertical, 7)
            .task { catalog = await chat.commandsCatalog() }
            // The model list loads when "/model " is first typed, and is kept for this chat.
            .task(id: menuContext?.kind == .model) { if menuContext?.kind == .model { await loadModelOptions() } }
            // A new word (or the model list after "/model") opens a dismissed chooser again,
            // and a mark made by hand is let go once the list is narrowed (the usual mark is back).
            .onChange(of: menuContext.map { "\($0.kind)-\($0.anchor)" }) { _, _ in menuDismissed = false }
            .onChange(of: menuContext) { _, ctx in if menuMark?.context != ctx { menuMark = nil } }
            .onChange(of: text) { old, new in
                // Offered once as the text gets long (a paste lands in one jump;
                // typing crosses the line once); "Keep" holds until it shrinks again.
                let limit = 800
                if new.count >= limit, old.count < limit || new.count - old.count > 400 { withAnimation(.snappy) { longTextOffer = true } }
                else if new.count < limit { longTextOffer = false }
            }
    }

    /// Mic when the field is empty, send otherwise, stop while a turn runs — one 28pt slot.
    @ViewBuilder private var trailingControl: some View {
        if dictation.isListening {
            TalkButton(dictation: dictation, engine: chat.runtime.voice) { transcript in text = transcript; focused = true; if VoiceSettings.sendAfterDictation { Task { await send() } } }
        } else if dictation.isTranscribing {
            // The recording is being turned into words (on the gateway or here).
            ProgressView().controlSize(.small).frame(width: 28, height: 28).accessibilityLabel("Transcribing")
        } else if chat.isRunning, text.isEmpty {
            Button { Task { await chat.stop() } } label: {
                Image(systemName: "stop.fill").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(.red, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
        } else if text.isEmpty && chat.staged.isEmpty && !HandsFreeSession.shared.isActive {
            // Dictation steps aside while voice mode has the microphone (its recorder reset the
            // audio session under the engine).
            // Held, the mic does what Settings › Voice › Hold the mic to says: dictation, or
            // the whole conversation by voice on this chat (the Mac's mic is a click; it keeps it).
            TalkButton(dictation: dictation, engine: chat.runtime.voice, onHold: holdStartsVoiceMode ? { HandsFreeSession.shared.start(chat: chat) } : nil) { transcript in text = transcript; focused = true; if VoiceSettings.sendAfterDictation { Task { await send() } } }
        } else {
            let disabled = text.trimmingCharacters(in: .whitespaces).isEmpty && chat.staged.isEmpty
            Button { Task { await send() } } label: {
                Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.vory), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel(chat.isRunning ? "Queue message" : "Send")
            .accessibilityIdentifier("composer.send")
        }
    }

    /// The + button, and the panel it opens: a tall glass sheet of big round icons like the one
    /// in Messages, grown out of the button and folded back into it.
    private var attachMenu: some View {
        Button {
            // The panel takes the keyboard's place, as the + tray does in Messages: with the
            // keyboard up it grew over the thread and covered the header (a tester, on the
            // first build with Voice mode in it).
            if !showAttach { focused = false }
            withAnimation(.snappy(duration: 0.32)) { showAttach.toggle() }
        } label: {
            // Same 36pt as the single-line capsule; a glass *button* style added its own padding
            // and grew past the bar.
            Image(systemName: "plus").font(.body.weight(.semibold))
                .rotationEffect(.degrees(showAttach ? 45 : 0))
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID(showAttach ? "attach-open" : "attach", in: namespace)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showAttach ? "Close attach panel" : "Attach")
    }

    private var attachPanel: some View {
        var items: [AttachItem] = []
        #if os(iOS)
        items.append(AttachItem(title: "Camera", symbol: "camera.fill", color: .black, disabled: !UIImagePickerController.isSourceTypeAvailable(.camera)) { showCamera = true })
        #endif
        items.append(AttachItem(title: "Photos", symbol: "photo.on.rectangle.angled", color: Color(red: 0.98, green: 0.45, blue: 0.3)) { showPhotos = true })
        items.append(AttachItem(title: "Files", symbol: "folder.fill", color: .blue) { showFiles = true })
        // Not while voice mode has the microphone: the recorder would reset the session under it.
        items.append(AttachItem(title: "Audio", symbol: "waveform", color: .red, disabled: HandsFreeSession.shared.isActive) { showRecorder = true })
        items.append(AttachItem(title: "Voice mode", symbol: "waveform.badge.mic", color: .pink) { HandsFreeSession.shared.start(chat: chat) })
        items.append(AttachItem(title: "Paste", symbol: "doc.on.clipboard.fill", color: .indigo) { paste() })
        items.append(AttachItem(title: "Message History", symbol: "clock.arrow.circlepath", color: .orange, disabled: chat.composerHistory.isEmpty) { showHistory = true })
        return AttachPanel(items: items) { withAnimation(.snappy(duration: 0.28)) { showAttach = false } }
    }

    private func send() async {
        var t = text
        if !quote.isEmpty {
            // A Markdown quote the bot reads as context; the quoted bubble is left out of the
            // app's own history recall.
            let q = quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            t = q + "\n\n" + t
            quote = ""
        }
        text = ""
        focused = true
        historyCursor = nil
        NotificationCenter.default.post(name: .hermesMessageSent, object: chat)
        if let prefill = await chat.send(t) { text = prefill }
    }

    private func recallHistory(_ delta: Int) -> Bool {
        let h = chat.composerHistory
        guard !h.isEmpty, text.isEmpty || historyCursor != nil else { return false }
        let next = (historyCursor ?? h.count) + delta
        guard next >= 0, next < h.count else { if next >= h.count { historyCursor = nil; text = "" ; return true }; return false }
        historyCursor = next
        text = h[next]
        return true
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
            chat.stageAttachment(data: data, name: "\(isVideo ? "video" : "photo")-\(Int(Date().timeIntervalSince1970)).\(ext)", kind: isVideo ? .video : .image)
        }
        photoItems = []
    }

    private func importFile(_ url: URL, kind: AttachmentPreview.Kind? = nil) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { chat.banner = "Could not read \(url.lastPathComponent)"; return }
        if data.count > 200 * 1024 * 1024 { chat.banner = "\(url.lastPathComponent) is larger than 200 MB."; return }
        let type = UTType(filenameExtension: url.pathExtension)
        let k: AttachmentPreview.Kind = kind ?? (type?.conforms(to: .image) == true ? .image : type?.conforms(to: .pdf) == true ? .pdf : type?.conforms(to: .audio) == true ? .audio : type?.conforms(to: .movie) == true ? .video : .file)
        chat.stageAttachment(data: data, name: url.lastPathComponent, kind: k)
    }

    /// The attach menu's Paste: images and files become attachments, text lands in the field.
    private func paste() {
        let pb = UIPasteboard.general
        if pb.hasImages, let img = pb.image, let data = img.jpegData(compressionQuality: 0.9) {
            chat.stageAttachment(data: data, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg", kind: .image)
        } else if let s = pb.string {
            text += s
        } else if let items = pb.items.first, let (type, value) = items.first, let data = value as? Data {
            stagePasted(data, name: "pasted-\(Int(Date().timeIntervalSince1970)).\(UTType(type)?.preferredFilenameExtension ?? "bin")", type: UTType(type) ?? .data)
        } else {
            chat.banner = "Nothing to paste."
        }
    }

    /// Something other than text pasted into the field (the edit menu, or the keyboard's
    /// "Paste from Screenshots"): staged like a picked file.
    private func stagePasted(_ data: Data, name: String, type: UTType) {
        let kind: AttachmentPreview.Kind = type.conforms(to: .image) ? .image : type.conforms(to: .movie) ? .video : type.conforms(to: .pdf) ? .pdf : type.conforms(to: .audio) ? .audio : .file
        withAnimation(.snappy) { chat.stageAttachment(data: data, name: name, kind: kind) }
    }
}

struct HistorySheet: View {
    var history: [String]
    var pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(Array(history.reversed().enumerated()), id: \.offset) { _, h in
                Button { pick(h); dismiss() } label: { Text(h).lineLimit(3) }
            }
            .navigationTitle("Message History")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}
