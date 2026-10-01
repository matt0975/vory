import SwiftUI
import VoryCore

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    var route: ChatRoute

    @State private var chat: ChatSession?
    @State private var loadError: String?
    @State private var showContext = false
    @State private var showProfile = false
    @State private var composerText = ""
    /// A bubble chosen with Reply: quoted above the next message, like a reply in Messages.
    @State private var composerQuote = ""
    @State private var dockHeight: CGFloat = 60
    /// The floating header's height on iOS; the Mac's header is the window toolbar, outside the thread.
    #if os(macOS)
    @State private var headerHeight: CGFloat = 0
    #else
    @State private var headerHeight: CGFloat = 96
    #endif
    @State private var dockTop: CGFloat = 0
    private var safeTop: CGFloat {
        #if os(iOS)
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }.first ?? 0
        #else
        0
        #endif
    }
    /// The keyboard's height above the home-indicator area. Tracked by hand for the dock as the
    /// transcript does for itself: SwiftUI's own avoidance hands the inset to any scroll view in
    /// the dock (the command list) instead of lifting the dock, which left the composer under
    /// the keyboard.
    @State private var keyboardInset: CGFloat = 0
    @State private var sentInitial = false
    @State private var confirming: ApprovalConfirm?
    private var confirmTitle: String { confirming?.choice == "deny" ? "Deny this action?" : "Approve this action?" }
    @Namespace private var glassNamespace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let chat {
                framed(chat)
                    .navigationTitle(chat.title)
                    .toolbar(.hidden, for: .navigationBar)
                    .sheet(isPresented: $showContext) { ContextBreakdownSheet(chat: chat) }
                    // Approve/Deny from the Live Activity or a notification, with "Confirm
                    // approvals" on: asked once more here, on the card it concerns.
                    .alert(confirmTitle, isPresented: confirmShown) { confirmButtons(chat: chat) } message: { confirmMessage(chat: chat) }
                    .onChange(of: model.approvalConfirm, initial: true) { _, c in if let c, c.storedID == chat.storedID { confirming = c } }
                    .onAppear { model.visibleChatID = chat.storedID; LocalNotifier.clearDelivered(for: chat.storedID) }
                    // What arrived for this chat while it was away is read now: its notifications
                    // leave Notification Center (a tester: "notifications won't stop even after
                    // attending to chat").
                    .onChange(of: chat.items.count) { _, _ in if model.visibleChatID == chat.storedID { LocalNotifier.clearDelivered(for: chat.storedID) } }
                    .onReceive(NotificationCenter.default.publisher(for: .hermesNewChatRequested)) { n in
                        guard model.visibleChatID == chat.storedID else { return }
                        model.composeProfile = (n.userInfo?["profile"] as? String) ?? chat.profileName
                        model.newChatRequest = UUID()
                    }
                    .onDisappear {
                        if model.visibleChatID == chat.storedID { model.visibleChatID = nil }
                        // Leaving a chat: back to the default bot, when one is chosen.
                        model.runtime?.returnToDefaultProfile()
                    }
                    .sheet(isPresented: $showProfile) { ProfileInfoSheet(chat: chat, profileName: chat.profileName) }
                    .onChange(of: model.pendingRoute) { _, r in handle(route: r, chat: chat) }
                    .onAppear { handle(route: model.pendingRoute, chat: chat) }
                    // Whatever was typed survives leaving the chat: saved per session as it changes,
                    // restored when the chat opens, cleared by a send (the composer empties the text).
                    .onChange(of: composerText) { _, t in ComposerDrafts.save(t, for: chat) }
            } else if let loadError {
                ContentUnavailableView("Could not open chat", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView("Opening…")
            }
        }
        // Like Messages: inside a conversation the composer owns the bottom edge.
        .hidesTabBar()
        // The navigation bar is hidden, which switches off UIKit's edge-swipe back; put it back.
        .background(InteractivePopEnabler())
        .task { await open() }
    }

    /// The thread with its dock and header. On the phone both float over the thread (the text
    /// scrolls under their glass) and the keyboard is tracked by hand. On the Mac the dock is a
    /// bottom inset, so the scroll bar ends above it, and the window's title and subtitle are
    /// the header, with the menu as a chevron.
    private func framed(_ chat: ChatSession) -> some View {
        #if os(macOS)
        thread(chat)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                dock(chat).frame(maxWidth: ChatStyle.macColumn).frame(maxWidth: .infinity)
            }
            .navigationSubtitle(macSubtitle(chat))
            .toolbar {
                // The bot, in the middle over its thread; a click opens its profile.
                ToolbarItem(placement: .principal) {
                    Button { showProfile = true } label: {
                        HStack(spacing: 7) {
                            BotAvatar(profile: chat.profileName, size: 22)
                            Text(chat.runtime.profiles.first { $0.name == chat.profileName }?.label ?? chat.profileName)
                                .font(.headline).lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                    }
                    .help(macSubtitle(chat))
                    .accessibilityIdentifier("chat.bot")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ChatMenuItems(chat: chat, onProfile: { showProfile = true }, onContext: { showContext = true },
                                      onNewChat: { Task { await newChat() } }, onClose: { model.runtime?.closeChat(chat); dismiss() })
                    } label: { Image(systemName: "chevron.down") }
                    .help("Chat options")
                    .accessibilityIdentifier("chat.more")
                }
            }
        #else
        // The thread runs under the status bar (it ignores the top safe area) while the
        // header sits inside it, so the thread's top margin is the header plus that inset;
        // without it the first message starts under the pill.
        thread(chat)
            // Like Messages: header and dock float over the thread and the text scrolls under their glass.
            .overlay(alignment: .bottom) { dock(chat) }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification), perform: keyboardChanged)
            .overlay(alignment: .top) { header(chat) }
        #endif
    }

    private func open() async {
        guard let runtime = model.runtime else { loadError = "No gateway connected."; return }
        do {
            // A read-only look at another bot's chat carries its bot on its own calls and leaves
            // the selected bot alone; a chat of ours selects its bot first.
            if !route.readOnly, let p = route.profile, !p.isEmpty, runtime.selectedProfile != p { runtime.selectedProfile = p }
            // Stored chats return at once with the cached transcript and sync behind the header.
            if let sid = route.storedID { chat = try await runtime.openChat(storedID: sid, title: route.title, profile: route.readOnly ? route.profile : nil) }
            else { chat = try await runtime.newChat(cwd: route.cwd) }
            if let chat, composerText.isEmpty, let draft = ComposerDrafts.load(for: chat) { composerText = draft }
            // The first message from the compose sheet goes out as soon as the chat exists.
            if let chat, !sentInitial, let t = route.initialText, !t.isEmpty || !route.initialAttachments.isEmpty {
                sentInitial = true
                for a in route.initialAttachments {
                    guard let u = a.localURL, let data = try? Data(contentsOf: u) else { continue }
                    chat.stageAttachment(data: data, name: a.name, kind: a.kind)
                    try? FileManager.default.removeItem(at: u)
                }
                _ = await chat.send(t)
                NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    // The thread, the dock, the header and the keyboard watcher live apart from the body: inside
    // it they tipped the type checker over its limit.
    private func thread(_ chat: ChatSession) -> some View {
        #if os(macOS)
        // The dock is a bottom inset on the Mac: the thread needs no margins of its own.
        let (dockTopArg, fallback, top): (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        #else
        let (dockTopArg, fallback, top) = (dockTop, dockHeight + keyboardInset, headerHeight + safeTop)
        #endif
        return TranscriptView(chat: chat, onEditMessage: editMessage, onOpenBot: { openBot($0, from: chat) }, onReply: reply,
                       dockTop: dockTopArg, fallbackInset: fallback, topInset: top)
            .overlay {
                if let e = chat.resumeError, chat.items.isEmpty {
                    ContentUnavailableView("Could not open chat", systemImage: "exclamationmark.triangle", description: Text(e))
                        // Centred in what is left above the composer and the keyboard.
                        .padding(.bottom, dockHeight + keyboardInset)
                }
            }
    }
    private func dock(_ chat: ChatSession) -> some View {
        BottomDock(chat: chat, text: $composerText, quote: $composerQuote, namespace: glassNamespace, readOnly: route.readOnly)
            .disabled(chat.resumeError != nil && chat.items.isEmpty)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 < 400 { dockHeight = $0 } }
            .padding(.bottom, keyboardInset)
            // The dock's top edge on screen, keyboard included: the thread measures its
            // own bottom edge the same way and keeps its last line above this.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { dockTop = $0 }
    }
    private func header(_ chat: ChatSession) -> some View {
        ChatHeader(chat: chat, onBack: { dismiss() }, onProfile: { showProfile = true }, onContext: { showContext = true },
                   onNewChat: { Task { await newChat() } }, onClose: { model.runtime?.closeChat(chat); dismiss() })
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 < 200 { headerHeight = $0 } }
    }
    #if os(iOS)
    private func keyboardChanged(_ n: Notification) {
        guard let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let screen = UIScreen.main.bounds
        // A frame that is not a keyboard's (a floating or hardware keyboard's accessory, a frame
        // from another scene, a whole-screen rect) must not push the dock to the top of the
        // screen, as it did for a tester mid-turn. A keyboard sits on the bottom edge and is
        // less than two thirds of the screen tall.
        let onScreen = end.intersection(screen)
        guard end.height < screen.height * 0.66, onScreen.isNull || onScreen.maxY >= screen.maxY - 1 || end.minY >= screen.maxY else { return }
        let covered = max(0, screen.maxY - end.minY)
        let safeBottom = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }.first ?? 0
        withAnimation(.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)) {
            keyboardInset = min(max(0, covered - safeBottom), screen.height * 0.6)
        }
    }
    #endif

    // The confirmation alert's pieces live apart from the body: inside it they tipped the type
    // checker over its limit.
    private var confirmShown: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil; model.approvalConfirm = nil } })
    }
    @ViewBuilder private func confirmButtons(chat: ChatSession) -> some View {
        let deny = confirming?.choice == "deny"
        Button(deny ? "Deny" : "Approve once", role: deny ? .destructive : nil) {
            if let c = confirming, let card = chat.cards.first(where: { $0.id == c.cardID }) {
                Task { await chat.respond(card: card, result: ["choice": .string(c.choice)]) }
            }
            confirming = nil; model.approvalConfirm = nil
        }
        Button("Cancel", role: .cancel) { confirming = nil; model.approvalConfirm = nil }
    }
    @ViewBuilder private func confirmMessage(chat: ChatSession) -> some View {
        if let c = confirming, let card = chat.cards.first(where: { $0.id == c.cardID }), let a = card.approval {
            Text([a.description, a.command].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        } else {
            Text("The request is no longer waiting.")
        }
    }

    private func editMessage(_ text: String) { composerText = text }
    private func reply(_ text: String) { withAnimation(.snappy) { composerQuote = text } }
    /// A "Messaged X" notice: X's chat opens read-only, or the banner says why it cannot.
    private func openBot(_ handle: String, from chat: ChatSession) {
        Task { if let why = await model.openBotChat(handle) { chat.banner = why } }
    }

    private func newChat() async {
        guard let runtime = model.runtime else { return }
        do { chat = try await runtime.newChat() } catch { loadError = error.localizedDescription }
    }

    #if os(macOS)
    /// "unifi · grok-4.7 · Thinking…": the bot, its model, and the status while it works.
    private func macSubtitle(_ chat: ChatSession) -> String {
        let bot = chat.runtime.profiles.first { $0.name == chat.profileName }?.label ?? chat.profileName
        let model = chat.modelName.split(separator: "/").last.map(String.init) ?? chat.modelName
        var parts = [bot]
        if !model.isEmpty { parts.append(model) }
        if chat.isRunning { parts.append(chat.statusLine ?? "Thinking…") } else if chat.isResuming { parts.append("Syncing…") }
        return parts.joined(separator: " · ")
    }
    #endif

    private func handle(route r: PendingRoute?, chat: ChatSession) {
        guard let r, r.storedSessionID == chat.storedID else { return }
        model.pendingRoute = nil
    }
}

/// Composer + queue + cards, in one glass container so the composer morphs into an approval card.
struct BottomDock: View {
    @Bindable var chat: ChatSession
    @Binding var text: String
    @Binding var quote: String
    var namespace: Namespace.ID
    /// Another bot's chat: a Read-only pill where the composer would be.
    var readOnly = false

    var body: some View {
        // The container is what lets the composer morph into a card; menus presented from
        // inside it (the + button) did not take taps on the phone, so the container only wraps
        // what morphs, and the composer draws its own glass.
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 10) {
                if let banner = chat.banner {
                    HStack {
                        Text(banner).font(.footnote).lineLimit(3)
                        Spacer()
                        Button { chat.banner = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                    }
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !chat.queue.isEmpty { QueueStrip(chat: chat) }
                if readOnly {
                    // Another bot's chat, opened from a notice: look, don't type, and leave its
                    // cards to its owner.
                    Label("Read-only", systemImage: "lock")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .glassEffectID("dock", in: namespace)
                        .accessibilityLabel("Read-only: this is another bot's chat")
                } else if let card = chat.firstCard {
                    if card.method == "approval" {
                        PendingCardView(chat: chat, card: card)
                            .glassEffectID("dock", in: namespace)
                            .contextMenu {
                                Button { Task { await chat.respond(card: card, result: ["choice": "once"]) } } label: { Label("Allow once", systemImage: "checkmark") }
                                Button { Task { await chat.respond(card: card, result: ["choice": "session"]) } } label: { Label("Allow for this session", systemImage: "checkmark.circle") }
                                Button { Task { await chat.respond(card: card, result: ["choice": "always"]) } } label: { Label("Always allow", systemImage: "checkmark.seal") }
                                Divider()
                                Button(role: .destructive) { Task { await chat.respond(card: card, result: ["choice": "deny"]) } } label: { Label("Deny", systemImage: "xmark") }
                            }
                    } else {
                        // No context menu on a password or question card: a long press on the
                        // secure field inside an empty menu was one more thing to go wrong.
                        PendingCardView(chat: chat, card: card)
                            .glassEffectID("dock", in: namespace)
                    }
                } else {
                    ComposerView(chat: chat, text: $text, quote: $quote, namespace: namespace)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .animation(.snappy, value: chat.firstCard?.id)
        .animation(.snappy, value: chat.banner)
    }
}

struct QueueStrip: View {
    @Bindable var chat: ChatSession
    @State private var editing: QueuedMessage?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Queued (\(chat.queue.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(chat.queue) { q in
                HStack {
                    Text(q.text).font(.subheadline).lineLimit(2)
                    Spacer()
                    Button { editing = q; draft = q.text } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
                    Button(role: .destructive) { chat.removeQueued(q.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .alert("Edit queued message", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Message", text: $draft)
            Button("Save") { if let e = editing { chat.updateQueued(e.id, text: draft) }; editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        }
    }
}

/// The floating chat header, built like the Messages one: a glass back circle, a centred pill with
/// the bot's avatar above the name (status while the agent works), and a glass … circle.
struct ChatHeader: View {
    @Bindable var chat: ChatSession
    var onBack: () -> Void
    var onProfile: () -> Void
    var onContext: () -> Void
    var onNewChat: () -> Void
    var onClose: () -> Void
    @Environment(\.colorScheme) private var scheme
    /// The bot pops into the header the way a contact does in Messages.
    @State private var popped = false
    @AppStorage(ChatStyle.headerShowsTitle) private var headerShowsTitle = false
    private var botLabel: String { chat.runtime.profiles.first { $0.name == chat.profileName }?.label ?? chat.profileName }
    private var headline: String { headerShowsTitle ? chat.title : botLabel }
    private var idleLine: String { headerShowsTitle ? chat.subtitle : (chat.title.count > 30 ? String(chat.title.prefix(29)) + "…" : chat.title) }

    var body: some View {
        // No glass container here: a container draws its glass on a layer above the rest, and
        // the pill covered the bot sitting on it.
        HStack(alignment: .top, spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain).accessibilityLabel("Back").accessibilityIdentifier("chat.back")
            Spacer(minLength: 0)
            Button {
                // The bot on the pill turns for the tap as it does elsewhere, and the plate opens.
                BotAmbient.shared.tap(profile: chat.profileName)
                onProfile()
            } label: {
                // Seated on the pill by its base; while it asks (the "!"), it lifts clear so the
                // dot does not cover the name.
                VStack(spacing: chat.botState == .awaitingApproval ? 2 : -(9 + 52 * BotFace.seatDrop(BotAvatarStore.choice(for: chat.profileName).spec(hex: "").shape))) {
                    // The bot sits on the pill, its base a few points over the top edge (measured from
                    // the shape, not the frame), like a contact photo in Messages; it springs in from
                    // small on the first appearance.
                    BotAvatar(profile: chat.profileName, size: 52, active: chat.isRunning,
                              mood: BotFaceView.Mood(state: chat.botState))
                        .opacity(popped ? 1 : 0)
                        .zIndex(1)
                        // The face's own tap gesture would swallow the tap before the button saw
                        // it; the whole plate, bot included, is one target.
                        .allowsHitTesting(false)
                    VStack(spacing: 1) {
                        HStack(spacing: 3) {
                            // Hug the text like Messages does; long titles are shortened in code rather
                            // than letting a max-width frame stretch the pill across the screen.
                            Text(headline.count > 26 ? String(headline.prefix(25)) + "…" : headline).font(.caption.weight(.semibold)).lineLimit(1)
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        }
                        // Shortened in code like the title: a compaction notice runs to a full
                        // sentence and the pill (fixedSize) stretched past the screen.
                        let status = chat.isRunning ? (chat.statusLine ?? "Thinking…") : (chat.isResuming ? "Syncing…" : idleLine)
                        Text(status.count > 42 ? String(status.prefix(41)).trimmingCharacters(in: .whitespaces) + "…" : status)
                            .font(.caption2).lineLimit(1)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: chat.statusLine)
                            .animation(.snappy, value: chat.botState == .awaitingApproval)
                    }
                    .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 6)
                    .fixedSize()
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onAppear { withAnimation(.easeOut(duration: 0.25).delay(0.05)) { popped = true } }
            .accessibilityLabel("Chat info: \(chat.title), \(chat.subtitle)")
            .accessibilityIdentifier("chat.titlePill")
            Spacer(minLength: 0)
            Menu {
                ChatMenuItems(chat: chat, onProfile: onProfile, onContext: onContext, onNewChat: onNewChat, onClose: onClose)
            } label: {
                Image(systemName: "ellipsis").font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: .circle)
            }
            .menuStyle(.button).buttonStyle(.plain)
            .accessibilityIdentifier("chat.more")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        // The bar is one surface, like the Messages header: a tap anywhere on it stays on it and
        // never reaches the thread scrolling underneath (a tool card would otherwise expand).
        .contentShape(.rect)
        .onTapGesture {}
    }
}

/// The … menu's items, shared by the iOS header's glass circle and the Mac toolbar's button.
struct ChatMenuItems: View {
    @Bindable var chat: ChatSession
    var onProfile: () -> Void
    var onContext: () -> Void
    var onNewChat: () -> Void
    var onClose: () -> Void

    var body: some View {
        Menu {
            ModelMenuContent(chat: chat)
        } label: { Label("Model: \(chat.modelName.isEmpty ? "none" : (chat.modelName.split(separator: "/").last.map(String.init) ?? chat.modelName))", systemImage: "cpu") }
        Button(action: onContext) { Label("Context usage\(chat.usage?.computedContextPercent.map { " · \($0)%" } ?? "")", systemImage: "gauge.with.dots.needle.33percent") }
        Button(action: onProfile) { Label("Bot info", systemImage: "person.text.rectangle") }
        Divider()
        Button(action: onNewChat) { Label("New Chat", systemImage: "square.and.pencil") }
        Button { Task { await chat.loadUsage() } } label: { Label("Refresh usage", systemImage: "arrow.clockwise") }
        Divider()
        Button(role: .destructive, action: onClose) { Label("Close session", systemImage: "xmark.circle") }
    }
}

#if os(macOS)
/// The Mac has no pop gesture to put back; the chat sits in the split view's detail column.
struct InteractivePopEnabler: View {
    var body: some View { Color.clear }
}
#else
/// Re-enables the navigation controller's interactive pop gesture while its bar is hidden, and
/// lets it start anywhere on the screen (not only at the left edge) for one-handed use: a pan
/// recognizer on the navigation view drives the same targets as the edge gesture. Put one under
/// each tab's root page (and under a page that hides the bar); a stack gets exactly one pan,
/// owned by a delegate that lives as long as the stack does. (Earlier each pushed chat added its
/// own pan and left it behind with a dead delegate, so after a few chats a stack carried several
/// pans that began on ANY drag: threads that slid both ways, and no time reveal.)
struct InteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ c: Controller, context: Context) { c.enable() }

    final class Controller: UIViewController {
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); enable() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); enable() }
        func enable() {
            guard let nav = navigationController ?? parent?.navigationController else { return }
            FullScreenPop.install(on: nav)
        }
    }
}

/// The one full-screen back pan of a navigation stack and the delegate for both it and the
/// system's edge gesture; kept alive on the navigation controller itself.
final class FullScreenPop: NSObject, UIGestureRecognizerDelegate {
    private static var key = 0
    private weak var nav: UINavigationController?
    private weak var pan: UIPanGestureRecognizer?

    static func install(on nav: UINavigationController) {
        guard let edge = nav.interactivePopGestureRecognizer else { return }
        edge.isEnabled = true
        if let existing = objc_getAssociatedObject(nav, &key) as? FullScreenPop {
            edge.delegate = existing
            if existing.pan == nil || existing.pan?.view == nil { existing.addPan(edge: edge) }
            return
        }
        let d = FullScreenPop()
        d.nav = nav
        objc_setAssociatedObject(nav, &key, d, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        edge.delegate = d
        d.addPan(edge: edge)
    }

    private func addPan(edge: UIGestureRecognizer) {
        guard let nav, let targets = edge.value(forKey: "targets") as? NSArray, targets.count > 0 else { return }
        // Never two on one view (a stack re-created around the same controller, say).
        nav.view.gestureRecognizers?.filter { $0.name == "vory.fullScreenPop" }.forEach { nav.view.removeGestureRecognizer($0) }
        let pan = UIPanGestureRecognizer()
        pan.name = "vory.fullScreenPop"
        pan.setValue(targets, forKey: "targets")
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        nav.view.addGestureRecognizer(pan)
        self.pan = pan
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let nav, nav.viewControllers.count > 1 else { return false }
        guard let pan = g as? UIPanGestureRecognizer, g === self.pan else { return true }
        // Only a clear rightward, mostly horizontal drag; vertical scrolling and the leftward
        // time-reveal drag in the thread are left alone.
        let v = pan.velocity(in: pan.view)
        return v.x > 250 && abs(v.x) > abs(v.y) * 1.8
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
}
#endif

/// Unsent composer text, per session, so leaving a chat and coming back does not lose it.
@MainActor
enum ComposerDrafts {
    private static func key(for chat: ChatSession) -> String { "composerDraft." + (chat.storedID ?? chat.runtimeID) }

    static func load(for chat: ChatSession) -> String? {
        let t = UserDefaults.standard.string(forKey: key(for: chat)) ?? ""
        return t.isEmpty ? nil : t
    }

    static func save(_ text: String, for chat: ChatSession) {
        if text.isEmpty { UserDefaults.standard.removeObject(forKey: key(for: chat)) }
        else { UserDefaults.standard.set(text, forKey: key(for: chat)) }
    }
}
