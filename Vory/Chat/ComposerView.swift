import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import VoryCore

/// What a composer is for: a chat's own, or the New Message sheet's first message (#27), on a
/// draft (`ChatSession.isDraft`): its send starts the chat, its mic starts voice mode while the
/// message is empty (Matt, 2026-10-13: the sheet's mic as it was), and to several bots (a group
/// chat) it takes words and "@" only, since a group starts with words and each bot keeps its model.
enum ComposerRole {
    case chat
    case newMessage(NewMessage)

    struct NewMessage {
        /// Several bots in To:.
        var group: Bool
        /// A bot is chosen: until then nothing can be written.
        var enabled: Bool
        var placeholder: String
        /// The words to start the chat with (the draft holds the files and the picks).
        var send: (String) -> Void
        var voice: () -> Void
        /// Changed when a bot is added in To:: the cursor goes to the message.
        var focus: Int = 0
    }
}

struct ComposerView: View {
    @Bindable var chat: ChatSession
    @Binding var text: String
    /// The bubble being replied to; sent as a quote block above the message.
    @Binding var quote: String
    /// The dock's morph namespace: the text capsule (alone, not the whole stack — the steer strip
    /// and the command list come and go under it) is what an approval card morphs from.
    var namespace: Namespace.ID
    var role: ComposerRole = .chat
    private var newMessage: ComposerRole.NewMessage? { if case .newMessage(let n) = role { n } else { nil } }
    /// Several bots: no + panel, no "/" list, no model chip.
    private var group: Bool { newMessage?.group == true }
    /// Keyboard focus, driven both ways (the text view is UIKit; see ComposerTextView).
    @State private var focused = false
    /// The cursor stays in the field after a send, ready for the next message, as in Messages. Onboarding's tour (#388)
    /// turns it off: its Send is a step of the tour, and the keyboard coming up covered the chat it shows.
    @Environment(\.composerFocusesAfterSend) private var focusesAfterSend
    @AppStorage(VoiceSettings.holdMicKey) private var holdMicRaw = VoiceSettings.HoldMicAction.dictate.rawValue
    /// Settings › Appearance › Return key sends (the on-screen keyboard's Return; a line otherwise).
    @AppStorage(ChatStyle.returnSends) private var returnSends = false
    #if os(iOS)
    @AppStorage(ChatStyle.closeKeyboardAfterSend) private var closeKeyboardAfterSend = false
    #else
    private let closeKeyboardAfterSend = false
    #endif
    /// Settings › Voice › Hold the mic to: Start voice mode. The Mac's mic is a click and keeps it.
    /// A drag is over the card (the Mac): the outline says it will take the drop.
    @State private var dropTargeted = false
    /// The pointer is over the model chip or a mention row (the Mac).
    @State private var chipHovered = false
    @State private var mentionHovered: String?
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
    /// Why the last Return did nothing (see SlashMenu.holdNote); gone with the next edit.
    @State private var holdNote: String?
    @State private var dictation = DictationController()
    @State private var stagedPreview: URL?
    /// Shown after a paste that dropped a lot of text into the field.
    @State private var longTextOffer = false
    @State private var showAttach = false
    /// The context breakdown sheet, from the ring in the bar (the … menu opens the same one).
    @State private var showContextSheet = false
    /// Settings › Appearance: the figure beside the ring as tokens ("18/200K") instead of "9%".
    @AppStorage(ChatStyle.contextAsTokens) private var contextAsTokens = false
    @State private var attachPanelHeight: CGFloat = 356
    /// Where the + button sits in the composer stack: the panel's glass starts as that circle.
    @State private var attachButtonFrame = CGRect(x: 10, y: 60, width: 36, height: 36)
    /// The rows are in the tree only while the panel is open or folding away: hidden rows in a
    /// closed panel stayed in the accessibility tree (reachable, and a test found them).
    @State private var attachRowsShown = false
    #if os(iOS)
    /// Where the text field sits in the composer stack, and the stack's width: the "/" list's
    /// glass starts as a circle at the field's leading edge and opens to the stack's width.
    @State private var fieldFrame = CGRect(x: 10, y: 10, width: 300, height: 36)
    @State private var stackWidth: CGFloat = 360
    /// The rows last shown, kept through the fold-away (the items empty the moment it starts).
    @State private var shownSlashItems: [SlashMenu.Item] = []
    #endif
    @State private var attachTappedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowGeometry) private var windowGeometry
    /// The fold of a partly open Duo, when it runs across the window above the composer (a
    /// laptop pose): the lists that grow up from the field stop under it (Step D).
    @Environment(\.reservedRegions) private var regions
    /// The chat's header's bottom in the window (ConversationView), for the + panel's cap.
    @Environment(\.chatHeaderBottom) private var chatHeaderBottom
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var composerFrame = CGRect.zero
    /// How far a list growing up from `y` (window space) may reach before the fold: nil with
    /// no such fold. No floor: a list that wants more lifts the dock over the fold instead
    /// (`listReach`, ConversationView's `foldLift`).
    private func roomUnderFold(from y: CGFloat) -> CGFloat? {
        guard composerFrame.height > 0 else { return nil }
        return regions.room(under: y)
    }

    /// How far above the composer's bottom edge its open list (+, "/", "@") reaches at full
    /// size, 0 with none open: the chat lifts its dock over a fold the list would cross, while
    /// the list is open (Duo stage 2).
    private var listReach: CGFloat {
        guard composerFrame.height > 0 else { return 0 }
        let h = composerFrame.height
        if showAttach { return h + 10 + AttachPanel.naturalHeight(rows: attachItems.count) }
        // The lists at the height they take with no fold (capped), so one that fits under the
        // fold leaves the dock where it is, however long the list.
        if !menuItems.isEmpty || menuLoading { return h + 10 + min(listCap, CGFloat(max(menuItems.count, 1)) * SlashMenuList.rowHeight + 8) }
        if !mentionSuggestions.isEmpty {
            // In the card: what it shows is in the card's height already.
            let full = min(listCap, mentionListHeight)
            return h + max(0, full - min(mentionListCap, full))
        }
        return 0
    }

    /// "@" at the start of the word being typed lists the bots; a pick puts "@name " in its place.
    private var mentionQuery: String? {
        guard !text.hasPrefix("/"), !showingRecalled,
              let last = text.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("@") else { return nil }
        return String(last.dropFirst())
    }
    private var mentionSuggestions: [ProfileInfo] {
        // The chat's own gateway's bots: onboarding's tour (#388) runs a demo that is not the app's gateway in use.
        guard let q = mentionQuery?.lowercased() else { return [] }
        return chat.runtime.profiles.filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) || $0.label.lowercased().hasPrefix(q) }
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
    private var menuContext: SlashMenu.Context? { showingRecalled || group ? nil : SlashMenu.context(for: text) }

    /// The chooser's context while it is open (not closed with Escape).
    private var openMenuContext: SlashMenu.Context? { menuDismissed ? nil : menuContext }

    private var menuItems: [SlashMenu.Item] {
        guard let ctx = openMenuContext else { return [] }
        switch ctx.kind {
        case .command: return catalog.map { SlashMenu.commandItems($0, query: ctx.query, draft: chat.isDraft) } ?? []
        case .model:
            return modelOptions.map { SlashMenu.modelItems($0, current: chat.modelName, currentProvider: chat.providerSlug, query: ctx.query) } ?? []
        }
    }

    /// The row Return takes, shown marked; nil when none is (see SlashMenu.markedIndex).
    private var markedIndex: Int? {
        openMenuContext.flatMap { SlashMenu.markedIndex(menuItems, context: $0, mark: menuMark) }
    }

    /// The model list is on its way: the chooser says so rather than staying shut.
    private var menuLoading: Bool { openMenuContext?.kind == .model && modelOptions == nil && modelOptionsLoading }

    /// The command list scrolls inside a cap: about 30 % of the window, so with the keyboard up
    /// it stops well short of the bot header at the top.
    private var commandListCap: CGFloat {
        // The "/" list stands 10 pt above the card (`slashOverlay`).
        roomUnderFold(from: composerFrame.minY - 10).map { min(listCap, $0) } ?? listCap
    }

    /// The "/" and "@" lists' cap with no fold: about 30 % of the window above the keyboard.
    private var listCap: CGFloat { max(120, min(280, visibleHeight * 0.30)) }

    /// The "@" list's cap: the same share, under a fold measured from the field's top (the
    /// stack's bottom edge less a one-line field and its padding), which the list itself does
    /// not move.
    private var mentionListCap: CGFloat {
        roomUnderFold(from: composerFrame.maxY - 46 - 10).map { min(listCap, $0) } ?? listCap
    }

    /// The "@" list's height with every bot in it.
    private var mentionListHeight: CGFloat { CGFloat(mentionSuggestions.count) * 40 + 8 }

    /// The window's height less the keyboard: what the caps are a share of. The Mac's views get
    /// the empty window geometry (its layout is the window's own), so there the window itself
    /// answers; without it the card stopped at four lines and the "/" list at 120 pt.
    private var visibleHeight: CGFloat {
        #if os(macOS)
        return NSApp.keyWindow?.contentLayoutRect.height ?? NSApp.windows.first { $0.isVisible }?.contentLayoutRect.height ?? 800
        #else
        return windowGeometry.bounds.height - windowGeometry.keyboardOverlap
        #endif
    }

    /// A row tapped or taken with Return, or completed with Tab (see SlashMenu.outcome): a
    /// command that takes nothing runs as if typed and sent, a model switches this chat the way
    /// the model menu does (with a line in the thread), the chat's own model stays, and anything
    /// else goes in the field.
    private func pick(_ item: SlashMenu.Item, completing: Bool = false) {
        Perf.stamp("slash: pick \(item.name)")
        menuMark = nil
        // With a reply quoted, files staged or a message being edited the text goes out as a message, not a command
        // (ChatSession.send, `resend`), so the command waits in the field instead.
        let outcome = SlashMenu.outcome(of: item, in: text, wholeText: menuContext?.wholeText == true,
                                        completing: completing, canRun: quote.isEmpty && chat.staged.isEmpty && chat.editingID == nil)
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
    /// SlashMenu.returnAction). With a reply quoted, files staged or a message being edited that text would go to the bot
    /// as a message, so it stays in the field instead. True when Return was used here.
    private func takeOnReturn() -> Bool {
        let canRun = quote.isEmpty && chat.staged.isEmpty && chat.editingID == nil
        switch SlashMenu.returnAction(menuItems, context: openMenuContext, marked: markedIndex, canRun: canRun) {
        case .take(let item): pick(item); return true
        case .send: Task { await send() }; return true
        case .hold: held(canRun: canRun); return true
        case .keep: break
        }
        // The chooser closed (Escape) or never opened for the line (a provider flag typed past
        // "/model"): a model command still does not go as a message with a quote or files.
        if SlashMenu.holdsClosed(text, canRun: canRun) { held(canRun: canRun); return true }
        if let p = mentionSuggestions.first { pickMention(p); return true }
        return false
    }

    /// Return kept the field as it is: say why under it.
    private func held(canRun: Bool) {
        withAnimation(.snappy(duration: 0.2)) { holdNote = SlashMenu.holdNote(text: text, canRun: canRun, loading: menuLoading) }
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
        // One glass container for the composer: the card's glass carries the "dock" id the
        // chat morphs with. The + panel used to morph out of the button's glass here (#285);
        // it now grows out of the button by a scale and fade (see the overlay below).
        VoryGlassEffectContainer(spacing: 0) { composerStack }
            // The panels above the card are measured against this view (the stack's own size).
            .coordinateSpace(.named("composerStack"))
            // Each panel in a glass container of its own, outside the card's: a glass shape
            // changing inside the card's container re-hosted the card's views, and the text
            // view lost the keyboard every time a panel opened (Matt, 2026-10-11). Behind the
            // card, not over it: a panel folding away ends behind the + (or the field) instead
            // of as a last shape drawn over it (Matt: "have it go behind the existing +").
            .background(alignment: .topLeading) { VoryGlassEffectContainer(spacing: 0) { attachOverlay } }
            #if os(iOS)
            .background(alignment: .topLeading) { VoryGlassEffectContainer(spacing: 0) { slashOverlay } }
            #endif
            // Anything tapped outside the + panel closes it: a clear catcher far larger than
            // the composer, behind the panels.
            .background {
                if showAttach {
                    Color.clear.contentShape(.rect).frame(width: 3000, height: 4000)
                        .onTapGesture { withAnimation(.snappy(duration: 0.28)) { showAttach = false } }
                }
            }
            // Where the composer stands in the window, for the fold above it (`roomUnderFold`).
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { composerFrame = $0 }
            #if os(iOS)
            // How far its open list reaches, for the dock's lift over a fold (ConversationView).
            .preference(key: ComposerListReach.self, value: listReach)
            #endif
    }

    /// The + panel, always in the tree: closed, a faint circle the size of the + button on
    /// the button; open, its shape, size and place animate to the full panel above the card
    /// while the rows scale up inside it and fade in. No insert transition: a glass container
    /// draws its members without their shadows while a transition runs, and the shadows came
    /// back in one frame a third of a second after the panel had settled (the spring's late
    /// end), under the card, the circles and the panel (Matt, 2026-10-11: "the dimmed part
    /// late after the animation").
    private var attachOverlay: some View {
        let open = showAttach, button = attachButtonFrame
        return Group {
            if attachRowsShown || open {
                attachPanel
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        attachPanelHeight = h
                        // How long the panel took to lay out after the tap (DEBUG "perf" log).
                        if let t = attachTappedAt { attachTappedAt = nil; Perf.note("attach panel laid out \(Int(Date().timeIntervalSince(t) * 1000)) ms after the tap") }
                    }
            } else {
                Color.clear.frame(width: 272, height: attachPanelHeight)
            }
        }
            // The rows shrink with the shape and fade on their own quick curve: on the
            // spring alone they showed as a clipped corner while the shape was small, and
            // the first icon lingered on the + after a close (the spring's long tail).
            .opacity(open ? 1 : 0)
            .animation(open ? .easeIn(duration: 0.26) : .easeOut(duration: 0.14), value: open)
            // Closed, nothing at all (no size) at the + button's centre, behind the card: the
            // shape grows out from behind the + and folds back behind it.
            .scaleEffect(open ? 1 : 0.02, anchor: .bottomLeading)
            .frame(width: open ? 272 : 0, height: open ? attachPanelHeight : 0, alignment: .bottomLeading)
            .clipShape(.rect(cornerRadius: open ? 30 : 0))
            // The glass stays on: closed, the shape has no size and draws nothing. Switching
            // the glass back on at an open placed it a frame late where the panel last was.
            .modifier(PanelSurface(shape: .rect(cornerRadius: open ? 30 : 0)))
            .opacity(open ? 1 : 0)
            .offset(x: open ? 0 : button.midX, y: open ? -(attachPanelHeight + 10) : button.midY)
            .allowsHitTesting(open)
            .accessibilityHidden(!open)
    }

    #if os(iOS)
    /// The "/" list (commands, skills, models) as a glass panel above the card, grown out of
    /// the field's leading edge the way the + panel grows out of its button. It used to sit
    /// inside the card: the card stretched to hold it, the thread's bottom margin followed
    /// the card's height frame by frame and the whole thread re-laid out while it opened
    /// (Matt, 2026-10-11: "/ commands ... still choppy"). The card keeps its height now.
    private var slashOverlay: some View {
        // Re-evaluated when the keyboard moves the dock: the rows' accessibility frames went
        // stale otherwise (a UI test tapped a row where it had been before the keyboard rose).
        let keyboard = windowGeometry.keyboardOverlap
        let open = !menuItems.isEmpty || menuLoading, field = fieldFrame
        let items = open ? menuItems : shownSlashItems
        let height = min(commandListCap, CGFloat(max(items.count, menuLoading ? 1 : 0)) * SlashMenuList.rowHeight + 8)
        // Closed, the panel is nothing at all (no size) at the field's leading edge: a closed
        // circle of glass showed through its own opacity as an orb over the + while the panel
        // folded away (Matt, 2026-10-11: "i dont want to see that at all").
        return SlashMenuList(items: items, selection: markedIndex, loading: menuLoading, cap: commandListCap, glass: false) { pick($0) }
            .frame(width: stackWidth)
            .opacity(open ? 1 : 0)
            .animation(open ? .easeIn(duration: 0.22) : .easeOut(duration: 0.12), value: open)
            .scaleEffect(open ? 1 : 0.02, anchor: .bottomLeading)
            .frame(width: open ? stackWidth : 0, height: open ? height : 0, alignment: .bottomLeading)
            .clipShape(.rect(cornerRadius: open ? 22 : 0))
            .modifier(PanelSurface(shape: .rect(cornerRadius: open ? 22 : 0)))
            .opacity(open ? 1 : 0)
            // Grows straight up from 10 pt above the card's top edge: its bottom edge never moves,
            // so no part of it passes behind the card (seen through the card's glass as a shade).
            .offset(x: open ? 0 : field.minX + 8, y: -(open ? height : 0) - 10 + 0 * keyboard)
            // Its own spring: outside the card's animated subtree the shape snapped shut.
            .animation(.snappy(duration: 0.28), value: open)
            .allowsHitTesting(open)
            .accessibilityHidden(!open)
    }
    #endif

    private var composerStack: some View {
        VStack(spacing: 8) {
            card
            if chat.isRunning, !text.isEmpty {
                HStack {
                    Text("Agent is working. Send queues the message.").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Steer now") { let t = text; text = ""; Task { if let back = await chat.steer(t) { text = back } } }.font(.caption2)
                }
                .padding(.horizontal, 8)
            }
        }
        #if os(iOS)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stackWidth = $0 }
        .onChange(of: menuItems.map(\.id)) { _, _ in if !menuItems.isEmpty { shownSlashItems = menuItems } }
        .onChange(of: !menuItems.isEmpty || menuLoading) { _, open in
            Smooth.animate("slashMenu")
            // The kept rows go once the fold has ended, so a closed list has none.
            if !open { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if menuItems.isEmpty, !menuLoading { shownSlashItems = [] } } }
        }
        .onChange(of: showAttach) { _, open in
            if open { attachRowsShown = true } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if !showAttach { attachRowsShown = false } } }
        }
        #endif
        .animation(.snappy(duration: 0.25), value: menuItems.map(\.id))
        .animation(.snappy(duration: 0.25), value: mentionSuggestions.map(\.name))
        .animation(.snappy(duration: 0.2), value: dictation.isListening)
        #if os(macOS)
        // Files dropped on the card from the Finder, cards dragged out of a chat, and pictures,
        // PDFs, movies or sounds dragged out of another app as data: staged like picked ones, the
        // card outlined while the drag is over it (`dropTargeted`).
        .onDrop(of: [.fileURL, .content], delegate: ComposerDropDelegate(targeted: $dropTargeted, perform: dropped))
        #else
        // Files dropped on the composer (another app on an iPad) are staged like picked ones.
        .dropDestination(for: URL.self) { urls, _ in
            for u in urls { importFile(u) }
            return !urls.isEmpty
        }
        #endif
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
        #if os(iOS)
        // The camera question answered before the + panel can need it (see cameraAvailable).
        .task { try? await Task.sleep(for: .seconds(1)); _ = Self.cameraAvailable }
        // The model list behind the chip, fetched before its first open.
        .task { await chat.warmModelOptions() }
        // The cursor comes back after a layout switch rebuilt the chat (`ChatViewMemory`).
        .onAppear { if !chat.isDraft, ChatViewMemory.focused.contains(ChatViewMemory.key(for: chat)) { focused = true } }
        .onDisappear { if !chat.isDraft { ChatViewMemory.setFocused(focused, for: chat) } }
        #endif
        #if os(macOS)
        // A new chat on the Mac (⌘N, the list's button, an intent) opens with the cursor in
        // the box, ready to type, as the box is after a message goes out (#212).
        .onAppear { if chat.items.isEmpty, !chat.isDraft { focused = true } }
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
        ComposerTextView(text: $text, placeholder: newMessage?.placeholder ?? "Type / for commands", focused: $focused, maxLines: visibleLines,
                         accessibilityID: newMessage != nil ? "newchat.text" : "composer.text",
                         onSend: { Task { await send() } },
                         onPasteData: { data, name, type in stagePasted(data, name: name, type: type) },
                         onArrow: { moveSelection($0) || recallHistory($0) },
                         onReturn: { takeOnReturn() },
                         returnSends: returnSends,
                         menuOpen: !menuItems.isEmpty || menuLoading,
                         onTab: { completeOnTab() },
                         onEscape: { dismissMenu() })
            .padding(.horizontal, 4).padding(.top, 2)
            .frame(minHeight: 30)
            .task(id: chat.profile) { if !group { catalog = await chat.commandsCatalog() } }
            // Another bot in the New Message sheet's To: is another draft: its own model list.
            .onChange(of: ObjectIdentifier(chat)) { _, _ in modelOptions = nil; menuMark = nil }
            .onChange(of: newMessage?.focus) { _, f in if f != nil, newMessage?.enabled == true { focused = true } }
            // The model list loads when "/model " is first typed, and is kept for this chat.
            .task(id: menuContext?.kind == .model) { if menuContext?.kind == .model { await loadModelOptions() } }
            // A new word (or the model list after "/model") opens a dismissed chooser again,
            // and a mark made by hand is let go once the list is narrowed (the usual mark is back).
            .onChange(of: menuContext.map { "\($0.kind)-\($0.anchor)" }) { _, _ in menuDismissed = false }
            .onChange(of: menuContext) { _, ctx in if menuMark?.context != ctx { menuMark = nil } }
            .onChange(of: text) { old, new in
                holdNote = nil
                // Offered once as the text gets long (a paste lands in one jump;
                // typing crosses the line once); "Keep" holds until it shrinks again.
                let limit = 800
                if new.count >= limit, old.count < limit || new.count - old.count > 400 { withAnimation(.snappy) { longTextOffer = true } }
                else if new.count < limit { longTextOffer = false }
            }
    }

    /// One rounded glass card (#320, Matt: "expands up as you type or do / commands", the
    /// attachments added at the top): the staged files' thumbnails along the top, the reply
    /// strip, then whatever opens for "/" or "@" above the words, the words themselves (growing
    /// upward to about 40% of the visible height, then scrolling inside), and under them a row
    /// of controls: +, the chat's model and reasoning level (the existing menus), the mic or
    /// send (stop while a turn runs). Shared with the Mac, which adds its own keys, drops and
    /// hover.
    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chat.staged.isEmpty { thumbnails }
            if chat.editingID != nil { editStrip }
            if !quote.isEmpty { quoteStrip }
            #if os(macOS)
            if !menuItems.isEmpty || menuLoading {
                SlashMenuList(items: menuItems, selection: markedIndex, loading: menuLoading, cap: commandListCap, glass: false) { pick($0) }
                    // In place, not sliding up from under the keyboard.
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                Divider()
            }
            #endif
            if let holdNote {
                Text(holdNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .accessibilityIdentifier("composer.holdNote")
                    .transition(.opacity)
            }
            if !mentionSuggestions.isEmpty {
                mentionList
                Divider()
            }
            if longTextOffer {
                // A big paste: offer to send it as a file rather than a wall of text.
                HStack(spacing: 10) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text("That's a lot of text.").font(.subheadline)
                    Spacer(minLength: 0)
                    Button("Keep") { withAnimation(.snappy) { longTextOffer = false } }.font(.subheadline)
                    Button("Attach as file") { attachTextAsFile() }.font(.subheadline.weight(.semibold)).voryGlassButtonStyle(prominent: true)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if dictation.isListening {
                // The field is the waveform while the mic listens; the words land when it stops.
                DictationWaveform(dictation: dictation)
                    .padding(.horizontal, 6).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                textField
                    // The New Message sheet: nothing to write until a bot is chosen.
                    .disabled(newMessage?.enabled == false)
                    #if os(iOS)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("composerStack")) } action: { fieldFrame = $0 }
                    #endif
            }
            HStack(alignment: .center, spacing: 8) {
                if !group {
                    attachMenu.layoutPriority(1).disabled(newMessage?.enabled == false)
                    // The chip gives way first: at the accessibility sizes it shortened to its
                    // level alone and the send button was cut by the card's edge.
                    modelChip
                }
                Spacer(minLength: 0)
                contextRing
                trailingControl.layoutPriority(1)
            }
            // The controls stop growing at XXXL, as the top bar's do and the system's bars: at the
            // accessibility sizes the +, the ring's number and the chip still ran past the card,
            // and Send was cut by its edge, a tap on what showed of it sending nothing (#396). A
            // long press shows each control large instead. The words above keep their full size.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
        // Plain glass, not interactive: an interactive shape answers touches itself, and on the
        // phone that swallowed the taps meant for the text field's Paste menu.
        // While a drag is over the card (the Mac) the glass itself takes the tint: an overlay
        // alone came through the glass as a faint rim.
        .voryGlassEffect(.regular.tint(dropTargeted ? Color.vory.opacity(0.35) : nil), in: .rect(cornerRadius: 22))
        .voryGlassEffectID("dock", in: namespace)
        // The Mac's drop outline: drawn on the card's own shape while a drag is over it.
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.vory, lineWidth: 2)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.15), value: dropTargeted)
    }

    /// The staged files, along the top of the card: a real preview of each, × on the corner.
    private var thumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(chat.staged) { a in
                    // In a group's first message the files stay behind (the sheet says so): dimmed.
                    StagedCard(attachment: a, notSent: group, onOpen: { stagedPreview = a.localURL },
                               onRemove: { withAnimation(.snappy) { chat.removeStaged(a.id) } })
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .padding(.leading, 2).padding(.vertical, 2)
        }
        .quickLookPreview($stagedPreview)
    }

    /// Edit & resend: the words in the box replace the chat's last message when sent (#556). Cancel ends the edit and
    /// empties the box, as cancelling an edit in Messages does; nothing was taken back yet.
    private var editStrip: some View {
        HStack(alignment: .center, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Color.vory).frame(width: 3)
            Label("Editing your message", systemImage: "pencil").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            // A 44 pt square to hit, the glyph its usual size: the audit's smallest target.
            Button { withAnimation(.snappy) { chat.cancelEdit(); text = "" } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(.rect)
            }
                .buttonStyle(.plain).disabled(chat.resending)
                .accessibilityLabel("Cancel editing")
                .accessibilityIdentifier("composer.cancelEdit")
        }
        // No padding above and below: the button's square sets the strip's height.
        .padding(.leading, 6)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.editing")
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// What the reply answers: the first lines of the bubble, with a way out.
    private var quoteStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Color.vory).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(quote).font(.caption).lineLimit(2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Spacer(minLength: 0)
            // A 44 pt square to hit, the glyph its usual size: the audit's smallest target, as Cancel editing's.
            Button { withAnimation(.snappy) { quote = "" } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(.rect)
            }
                .buttonStyle(.plain).accessibilityLabel("Cancel reply")
                .accessibilityIdentifier("composer.cancelReply")
        }
        // The words keep their padding; the button's square sets the strip's height where it's taller.
        .padding(.leading, 6)
        // The bar beside the words is flexible in height; without this the strip took the whole screen.
        .fixedSize(horizontal: false, vertical: true)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// The bots "@" can mean, in the card above the words.
    private var mentionList: some View {
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
                        .padding(.horizontal, 6)
                        .background(mentionHovered == p.id ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .onHover { over in if over { mentionHovered = p.id } else if mentionHovered == p.id { mentionHovered = nil } }
                    #endif
                    if p.id != mentionSuggestions.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .frame(height: min(mentionListCap, mentionListHeight))
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
    }

    /// The chat's model and reasoning level on one small chip; a tap opens the same menus the
    /// header's … menu has (models by provider, then the reasoning levels).
    private var modelChip: some View {
        Menu {
            Section("Model") { ModelMenuContent(chat: chat) }
            ReasoningEffortMenu(chat: chat)
        } label: {
            // Matt's wording (2026-10-10): the model's name in the text's own
            // tone, the level after it in a lighter one, no "Reasoning:"; at the accessibility
            // sizes the level stands alone.
            HStack(spacing: 6) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(chat.modelName.isEmpty ? "Model" : Self.shortModel(chat.modelName)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.primary.opacity(0.85))
                }
                Text(ReasoningEffort.name(of: chat.reasoningEffort ?? "medium")).lineLimit(1)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            // Under the pointer the capsule firms up (the Mac); a touch has no hover.
            .background(.quaternary.opacity(chipHovered ? 1 : 0.85), in: .capsule)
            .contentShape(.capsule)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { Smooth.animate("modelChip") })
        #if os(macOS)
        .onHover { chipHovered = $0 }
        #endif
        .accessibilityIdentifier("composer.modelChip")
        .accessibilityShowsLargeContentViewer {
            Label("\(chat.modelName.isEmpty ? "Model" : Self.shortModel(chat.modelName)) · \(ReasoningEffort.name(of: chat.reasoningEffort ?? "medium"))", systemImage: "cpu")
        }
        .accessibilityLabel("Model \(chat.modelName.isEmpty ? "not set" : chat.modelName), reasoning \(ReasoningEffort.name(of: chat.reasoningEffort ?? "medium"))")
    }

    static func shortModel(_ m: String) -> String {
        let last = m.split(separator: "/").last.map(String.init) ?? m
        return last.count > 22 ? String(last.prefix(21)) + "…" : last
    }

    /// Lines the words may grow to before they scroll inside the card: about 40% of what is
    /// visible above the keyboard, never under four.
    private var visibleLines: Int {
        max(4, Int(visibleHeight * 0.4 / 22))
    }

    /// Mic when the field is empty, send otherwise, stop while a turn runs — one 28pt slot.
    /// How full the chat's context is (#325): a ring and the percentage left of the mic or
    /// send, the same number as … › Context usage, which a tap opens too. Nothing until the
    /// chat has usage numbers. Quiet until 80 %, orange from there, red from 95 %. Its own
    /// size and a fixed gap from the button; the model chip truncates before it does.
    @ViewBuilder private var contextRing: some View {
        if let pct = chat.usage?.computedContextPercent {
            let fill = CGFloat(min(100, max(0, pct))) / 100
            let tint: Color = pct >= 95 ? .red : pct >= 80 ? .orange : Color.primary.opacity(0.55)
            Button { showContextSheet = true } label: {
                HStack(spacing: 5) {
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
                        Circle().trim(from: 0, to: fill)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 15, height: 15)
                    Text(contextAsTokens ? Self.tokensLabel(chat.usage) : "\(pct)%").font(.caption.weight(.medium)).monospacedDigit()
                        .foregroundStyle(pct >= 80 ? tint : Color.secondary)
                }
                .fixedSize()
                .padding(.trailing, 4)
                // The row's height to tap, as the + beside it (36 pt): the ring and its number alone were a
                // 16 pt strip (the audit's "hit area is too small").
                .frame(minHeight: 36)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            // The numbers change as the turn runs and never animate: no motion in the bar while
            // typing, and nothing of it moves with the + panel or the keyboard.
            .transaction { $0.animation = nil }
            .accessibilityLabel("Context \(pct) percent used")
            .accessibilityShowsLargeContentViewer { Label("Context \(pct)%", systemImage: "circle.dashed") }
            .accessibilityIdentifier("composer.context")
            .sheet(isPresented: $showContextSheet) { ContextBreakdownSheet(chat: chat).sheetFrame().withAppModel() }
        }
    }

    /// "18/200K": the context used and its window, in thousands (one decimal under 10K).
    static func tokensLabel(_ u: Usage?) -> String {
        guard let u, let max = u.contextMax, max > 0 else { return "" }
        let used = u.contextUsed ?? u.total ?? 0
        func k(_ n: Int) -> String { n < 10_000 ? String(format: "%.1f", Double(n) / 1000) : "\(Int((Double(n) / 1000).rounded()))" }
        return "\(k(used))/\(k(max))K"
    }

    @ViewBuilder private var trailingControl: some View {
        if let newMessage {
            newMessageControl(newMessage)
        } else if dictation.isListening {
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
            .accessibilityShowsLargeContentViewer { Label("Stop", systemImage: "stop.fill") }
        } else if text.isEmpty && chat.staged.isEmpty && !HandsFreeSession.shared.isActive {
            // Dictation steps aside while voice mode has the microphone (its recorder reset the
            // audio session under the engine).
            // Held, the mic does what Settings › Voice › Hold the mic to says: dictation, or
            // the whole conversation by voice on this chat (the Mac's mic is a click; it keeps it).
            TalkButton(dictation: dictation, engine: chat.runtime.voice, onHold: holdStartsVoiceMode ? { HandsFreeSession.shared.start(chat: chat) } : nil) { transcript in text = transcript; focused = true; if VoiceSettings.sendAfterDictation { Task { await send() } } }
        } else {
            // An edit on its way is sent once (#556).
            let disabled = (text.trimmingCharacters(in: .whitespaces).isEmpty && chat.staged.isEmpty) || chat.resending
            Button { Task { await send() } } label: {
                Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.vory), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel(chat.editingID != nil ? "Send edited message" : chat.isRunning ? "Queue message" : "Send")
            .accessibilityShowsLargeContentViewer { Label(chat.editingID != nil ? "Send edited message" : chat.isRunning ? "Queue message" : "Send", systemImage: "arrow.up") }
            .accessibilityIdentifier("composer.send")
        }
    }

    /// The + button, and the panel it opens: a tall glass sheet of big round icons like the one
    /// in Messages, grown out of the button and folded back into it.
    private var attachMenu: some View {
        Button {
            // The keyboard stays up (Matt, 2026-10-11: "it shouldn't close the keyboard"); the
            // panel is capped to the room between the header and the card and scrolls inside it,
            // where it used to take the keyboard's place and, uncapped, covered the header.
            // The slash list closes with it: on the Duo the two stood open together, the panel pushed up onto the fold.
            if !showAttach { attachTappedAt = Date(); menuDismissed = true }
            Smooth.animate("plusPanel")
            withAnimation(.snappy(duration: 0.32)) { showAttach.toggle() }
        } label: {
            // Same 36pt as the single-line capsule; a glass *button* style added its own padding
            // and grew past the bar.
            Image(systemName: "plus").font(.body.weight(.semibold))
                .rotationEffect(.degrees(showAttach ? 45 : 0))
                .frame(width: 36, height: 36)
                // The whole circle takes the tap and is the control's frame: on iOS 26 the button was its 14 pt glyph
                // (the audit's "hit area is too small" on 26.5), and a tap near the circle's edge missed.
                .contentShape(.circle)
                .voryGlassEffect(.regular.interactive(), in: .circle)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("composerStack")) } action: { attachButtonFrame = $0 }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(newMessage != nil ? "newchat.attach" : "composer.attach")
        .accessibilityLabel(showAttach ? "Close attach panel" : "Attach")
        .accessibilityShowsLargeContentViewer { Label(showAttach ? "Close attach panel" : "Attach", systemImage: "plus") }
    }

    #if os(iOS)
    /// Whether a camera is there, asked once: the system's answer takes a moment the first
    /// time (it wakes the capture devices), and it used to be asked on the tap that opens
    /// the panel, which is where the first open lagged (#285). Warmed when the chat opens.
    nonisolated(unsafe) private static var cameraAvailableCache: Bool?
    private static var cameraAvailable: Bool {
        if let c = cameraAvailableCache { return c }
        let c = UIImagePickerController.isSourceTypeAvailable(.camera)
        cameraAvailableCache = c
        return c
    }
    #endif

    private var attachPanel: some View {
        AttachPanel(items: attachItems, surface: false, cap: attachCap) { withAnimation(.snappy(duration: 0.28)) { showAttach = false } }
    }

    /// The + panel's rows: a fixed set, some greyed out where they cannot be used now.
    private var attachItems: [AttachItem] {
        var items: [AttachItem] = []
        #if os(iOS)
        items.append(AttachItem(title: "Camera", symbol: "camera.fill", color: .black, disabled: !Self.cameraAvailable) { showCamera = true })
        #endif
        items.append(AttachItem(title: "Photos", symbol: "photo.on.rectangle.angled", color: Color(red: 0.98, green: 0.45, blue: 0.3)) { showPhotos = true })
        items.append(AttachItem(title: "Files", symbol: "folder.fill", color: .blue) { showFiles = true })
        // Not while voice mode has the microphone: the recorder would reset the session under it.
        items.append(AttachItem(title: "Audio", symbol: "waveform", color: .red, disabled: HandsFreeSession.shared.isActive) { showRecorder = true })
        items.append(AttachItem(title: "Voice mode", symbol: "waveform.badge.mic", color: .pink) {
            if let newMessage { newMessage.voice() } else { HandsFreeSession.shared.start(chat: chat) }
        })
        items.append(AttachItem(title: "Paste", symbol: "doc.on.clipboard.fill", color: .indigo) { paste() })
        items.append(AttachItem(title: "Message History", symbol: "clock.arrow.circlepath", color: .orange, disabled: chat.composerHistory.isEmpty) { showHistory = true })
        return items
    }

    /// The room above the card for the + panel: down from the header (the status bar plus the
    /// pill, about 60 pt) to 10 pt above the card, wherever the keyboard has put the card.
    private var attachCap: CGFloat {
        #if os(iOS)
        guard composerFrame.minY > 0 else { return 400 }
        let room = AttachPanel.room(cardTop: composerFrame.minY, safeTop: windowGeometry.safeArea.top, headerBottom: chatHeaderBottom)
        // Under a fold, no 180 pt floor: it won over the fold (the 10-12 round). The panel
        // stands 10 pt above the card.
        return roomUnderFold(from: composerFrame.minY - 10).map { min(room, $0) } ?? max(180, room)
        #else
        return 600
        #endif
    }

    /// The New Message sheet's slot: the mic while nothing is written (voice mode with the bot
    /// chosen, after whatever is attached), the send arrow once there are words or files.
    @ViewBuilder private func newMessageControl(_ n: ComposerRole.NewMessage) -> some View {
        // A group starts with words only: its files do not count toward sending.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, n.group || chat.staged.isEmpty {
            Button { n.voice() } label: {
                Image(systemName: "mic.fill").font(.body.weight(.semibold))
                    .foregroundStyle(n.enabled && !n.group ? Color.primary : Color.secondary)
                    .frame(width: 28, height: 28).contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(!n.enabled || n.group)
            .accessibilityLabel("Voice mode")
            .accessibilityIdentifier("newchat.voice")
        } else {
            Button { Task { await send() } } label: {
                Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(n.enabled ? AnyShapeStyle(Color.vory) : AnyShapeStyle(.tertiary), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!n.enabled)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("newchat.send")
        }
    }

    private func send() async {
        // The New Message sheet starts the chat with the words; the draft holds the rest.
        if let newMessage { newMessage.send(text); return }
        if chat.editingID != nil { await resendEdited(); return }
        var t = text
        Perf.stamp("slash: send \(t.prefix(30))")
        if !quote.isEmpty {
            // A Markdown quote the bot reads as context; the quoted bubble is left out of the
            // app's own history recall.
            let q = quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            t = q + "\n\n" + t
            quote = ""
        }
        text = ""
        // The app's chats keep the cursor for the next message unless Close keyboard after sending is on (#350); the
        // tour's and the demo's put the keyboard away either way.
        focused = ComposerFocusRule.afterSend(placeKeepsFocus: focusesAfterSend, closeAfterSending: closeKeyboardAfterSend)
        historyCursor = nil
        NotificationCenter.default.post(name: .hermesMessageSent, object: chat)
        if let prefill = await chat.send(t) { text = prefill }
    }

    /// Send while editing (#556): the gateway takes the old message and what followed it back, and these words go in its
    /// place. Until it's sent the words stay in the box, so anything that stops it (a reply running, a gateway that can't
    /// take messages back) keeps them, with the reason in the banner; nothing is sent then.
    private func resendEdited() async {
        let outcome = await chat.resend(text)
        guard outcome == .sent else { chat.banner = outcome.message; return }
        text = ""
        focused = ComposerFocusRule.afterSend(placeKeepsFocus: focusesAfterSend, closeAfterSending: closeKeyboardAfterSend)
        historyCursor = nil
        NotificationCenter.default.post(name: .hermesMessageSent, object: chat)
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

    #if os(macOS)
    /// A drop on the card: file URLs (the Finder) go through `importFile`; a picture, PDF, movie
    /// or sound carried as data (dragged out of Safari, Photos, Preview) is staged under its
    /// own type. True when anything was taken, so the drag's cursor says so.
    private func dropped(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                took = true
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url else { return }
                    Task { @MainActor in importFile(url) }
                }
            } else if let type = p.registeredTypeIdentifiers.compactMap({ UTType($0) }).first(where: { $0.conforms(to: .content) }) {
                // A card dragged out of a chat (any file: a PDF, a CSV, a log), or a picture, PDF
                // or clip out of another app. The file representation keeps the file's own name:
                // the pasteboard drops `suggestedName` on the way over, so "report.pdf" arrived as
                // "Dropped.pdf". The file is gone when the handler returns, so it is read there.
                // Plain text with no file behind it is not taken: the field handles text drags.
                let family = [UTType.image, .pdf, .movie, .audio].first { type.conforms(to: $0) }
                guard family != nil || p.hasRepresentationConforming(toTypeIdentifier: type.identifier, fileOptions: []) else { continue }
                took = true
                let fallback = (p.suggestedName.map { ($0 as NSString).deletingPathExtension } ?? "Dropped") + "." + (type.preferredFilenameExtension ?? family?.preferredFilenameExtension ?? "bin")
                _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url) else { return }
                    // The representation's file is named after the item and typed again by the
                    // provider ("report.pdf.pdf"): one extension, the type's.
                    let ext = type.preferredFilenameExtension ?? family?.preferredFilenameExtension ?? url.pathExtension
                    var base = url.deletingPathExtension().lastPathComponent
                    if !ext.isEmpty, base.lowercased().hasSuffix("." + ext.lowercased()) { base = String(base.dropLast(ext.count + 1)) }
                    let name = url.pathExtension.isEmpty ? fallback : (ext.isEmpty ? base : base + "." + ext)
                    Task { @MainActor in stagePasted(data, name: name, type: type) }
                }
            }
        }
        return took
    }
    #endif

    /// Something other than text pasted into the field (the edit menu, or the keyboard's
    /// "Paste from Screenshots"): staged like a picked file.
    private func stagePasted(_ data: Data, name: String, type: UTType) {
        let kind: AttachmentPreview.Kind = type.conforms(to: .image) ? .image : type.conforms(to: .movie) ? .video : type.conforms(to: .pdf) ? .pdf : type.conforms(to: .audio) ? .audio : .file
        withAnimation(.snappy) { chat.stageAttachment(data: data, name: name, kind: kind) }
    }
}

#if os(macOS)
/// The card's drop target. A delegate rather than `onDrop(isTargeted:)`: on the Mac that
/// binding never went true for a drag over the card (the drops landed, the outline never
/// showed), while `dropEntered` and `dropExited` are called for every validated drag.
struct ComposerDropDelegate: DropDelegate {
    @Binding var targeted: Bool
    var perform: ([NSItemProvider]) -> Bool
    static let types: [UTType] = [.fileURL, .content]

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: Self.types) }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        return perform(info.itemProviders(for: Self.types))
    }
}
#endif

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

extension EnvironmentValues {
    /// Whether a send leaves the cursor in the composer (`ComposerView`); the app's chats do. Onboarding's tour and Demo
    /// mode's chats don't: there a send puts the keyboard away (#490), where the next thing to read is the reply.
    @Entry var composerFocusesAfterSend: Bool = true
    /// The message bar's field takes no typing (onboarding's tour, #490: beat 3's message is ready-made and beat 4's
    /// mention types itself), so no keyboard comes up for it. VoiceOver reads its words as text, not as a field.
    @Entry var composerReadOnly: Bool = false
}

/// How far above the composer's bottom edge its open list (+, "/", "@") reaches at full size,
/// 0 with none open (`ComposerView.listReach`): the chat lifts its dock over a fold across the
/// window that the list would cross (Duo stage 2).
struct ComposerListReach: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension EnvironmentValues {
    /// The bottom of the chat's header in window space, 0 until measured (ConversationView): the morph bar's chat row
    /// on a narrow window, the chat's own header on a wide one.
    @Entry var chatHeaderBottom: CGFloat = 0
}
