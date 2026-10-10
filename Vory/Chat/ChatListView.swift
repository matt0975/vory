import SwiftUI
import VoryCore

struct ChatRoute: Hashable {
    var storedID: String?
    var title: String?
    /// Sessions are profile-scoped on the gateway; when set, the chat screen selects this bot first.
    var profile: String?
    /// Sent as soon as the chat opens: the first message typed in the compose sheet.
    var initialText: String? = nil
    /// Files picked in the compose sheet; staged into the chat and sent with the first message.
    var initialAttachments: [AttachmentPreview] = []
    /// Another bot's chat opened from a "Messaged X" notice: the transcript, no composer, no cards.
    var readOnly: Bool = false
    /// A new chat's working folder on the gateway: the project it starts in.
    var cwd: String? = nil
    /// Sets one fresh chat apart from the next on the Mac, where a chat replaces the one beside
    /// the list: two "new chat" routes are otherwise equal and the second would change nothing.
    var token: UUID? = nil
    /// Voice mode as soon as the chat exists (the Chats page's mic, the sheet's Voice mode),
    /// after the first message if there is one.
    var startVoice: Bool = false
}

struct ChatListView: View {
    @Environment(AppModel.self) private var model
    /// The Mac's split view hands in the detail column's path: chats open there, beside the list,
    /// and a click replaces the one showing. On the phone the list owns its own stack and pushes.
    var detailPath: Binding<NavigationPath>? = nil
    @State private var sessions: [StoredSession] = []
    /// Bumped by a tap on the selected Chats tab: the list scrolls to its first row.
    @State private var scrollToTop = 0
    /// Chats the user deleted here, so a pinned row is not kept alive from memory afterwards.
    @State private var droppedIDs: Set<String> = []
    @State private var searchText = ""
    #if os(macOS)
    @FocusState private var searchFocused: Bool
    #endif
    @State private var searchResults: [StoredSession] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var ownPath = NavigationPath()
    private var path: Binding<NavigationPath> { detailPath ?? $ownPath }
    /// The row a force click is peeking (Mac).
    @State private var peeking: StoredSession?
    /// The chat showing in the detail column (Mac), for the row's highlight.
    @State private var selectedID: String?
    @State private var pendingDelete: StoredSession?
    @State private var lastRouted: PendingRoute?
    /// Every profile's chats in one list, newest first, with the bot's avatar on each row.
    @AppStorage("chats.allBots") private var allBots = false
    @State private var showNewChat = false
    /// The New Message sheet started a chat (as against being cancelled).
    @State private var sheetStarted = false
    @State private var showNewBot = false
    @AppStorage(ChatSummarizer.titlesKey) private var aiTitles = ChatSummarizer.titlesOn
    @AppStorage(ChatSummarizer.previewsKey) private var aiPreviews = ChatSummarizer.previewsOn
    private var aiSummaries: Bool { aiTitles || aiPreviews }
    private var summarizer: ChatSummarizer { ChatSummarizer.shared }
    @State private var rooms: [Room] = []
    /// Each room's recent log, for the row's preview and its summary.
    @State private var roomLogs: [String: [RoomEvent]] = [:]
    // Filters (the funnel button): what to show and in which order.
    @AppStorage("chats.filter.pinned") private var pinnedOnly = false
    @AppStorage("chats.filter.needsYou") private var needsYouOnly = false
    @AppStorage("chats.filter.live") private var liveOnly = false
    @AppStorage("chats.filter.archived") private var showArchived = true
    @AppStorage("chats.sort") private var sortKey = "recent"
    @AppStorage("chats.filter.groups") private var groupsOnly = false
    /// "" for every chat, a project id, or "__none__" for chats in no project.
    @AppStorage("chats.filter.project") private var projectFilter = ""
    @State private var showProjects = false
    /// Chats under their projects, each one foldable, instead of one flat list.
    @AppStorage("chats.byProject") private var byProject = false
    @AppStorage("chats.byProject.collapsed") private var collapsedRaw = ""
    /// Projects showing every chat instead of the first few.
    @State private var shownInFull: Set<String> = []
    /// Picking several chats to move, archive or delete together.
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var movingSelection = false
    @State private var pendingDeleteMany = false
    /// Rooms have no archive on the gateway; archived ones are remembered here.
    @AppStorage("chats.archivedRooms") private var archivedRoomsRaw = ""
    @State private var pendingRoomDelete: Room?
    private var archivedRooms: Set<String> { Set(archivedRoomsRaw.split(separator: ",").map(String.init)) }
    private var filtering: Bool { pinnedOnly || needsYouOnly || liveOnly || groupsOnly || !showArchived || !projectFilter.isEmpty }
    /// The profile menu's icons are rendered images; UIKit keeps the built menu, so it is given a
    /// new identity whenever a bot's colour or look changes.
    @AppStorage(BotColors.storageKey) private var botColorsRaw = ""
    @AppStorage(BotAvatarStore.storageKey) private var botAvatarsRaw = ""
    @AppStorage(BotAvatarStore.glassAllKey) private var glassAll = false
    @Environment(\.colorScheme) private var colorScheme
    /// Mirrors the tab bar's minimize-on-scroll so the compose circle drops beside the collapsed bar.

    private var runtime: GatewayRuntime? { model.runtime }

    #if os(macOS)
    /// The list as shown, for stepping through it from the keyboard.
    private func entries(_ runtime: GatewayRuntime) -> [ListEntry] {
        let rows = filtered(searchText.isEmpty ? sessions : searchResults, runtime: runtime)
        let visibleRooms = groupsOnly
            ? rooms.filter { (showArchived || !archivedRooms.contains($0.roomId)) && (searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)) }
            : []
        if grouped(runtime) {
            // Top to bottom as drawn: each open project's visible chats, then the group chats.
            return groups(rows, runtime: runtime).flatMap { g in collapsed.contains(g.id) ? [] : shown(g).map(ListEntry.session) } + visibleRooms.map(ListEntry.room)
        }
        return Self.merge(rows, visibleRooms, sort: sortKey)
    }

    /// Opens the chat `direction` rows away from the open one (the first when none is open).
    private func step(_ direction: Int, runtime: GatewayRuntime) {
        let list = entries(runtime)
        guard !list.isEmpty else { return }
        let current = list.firstIndex { e in
            switch e {
            case .session(let s): return s.id == selectedID
            case .room(let r): return "room:" + r.roomId == selectedID
            }
        }
        let next = current.map { min(max($0 + direction, 0), list.count - 1) } ?? 0
        switch list[next] {
        case .session(let s): open(ChatRoute(storedID: s.id, title: s.displayTitle, profile: s.profile))
        case .room(let r): open(RoomRoute(room: r))
        }
    }
    #endif

    /// Opens a chat or a group chat: pushed on the phone; on the Mac it replaces whatever the
    /// detail column shows, the way selecting a conversation does in Messages. `back` is the tab
    /// to return to when this chat closes (the compose circle tapped elsewhere); any other way
    /// in forgets a pending one.
    private func open(_ route: some Hashable, returningTo back: AppModel.AppTab? = nil) {
        model.composeReturnTab = back
        #if os(macOS)
        if var chat = route as? ChatRoute, chat.storedID == nil {
            chat.token = UUID()
            path.wrappedValue = NavigationPath([chat])
        } else {
            path.wrappedValue = NavigationPath([route])
        }
        selectedID = (route as? ChatRoute)?.storedID ?? (route as? RoomRoute).map { "room:" + $0.room.roomId }
        #else
        path.wrappedValue.append(route)
        #endif
    }

    var body: some View {
        #if os(macOS)
        // A column of the split view; the detail column's stack (`detailPath`) shows the chats.
        content
        #else
        NavigationStack(path: path) { content }
        #endif
    }

    private var content: some View {
            Group {
                if let runtime {
                    list(runtime)
                } else {
                    ContentUnavailableView("No gateway selected", systemImage: "antenna.radiowaves.left.and.right.slash", description: Text(model.activationError ?? "Choose a gateway in Settings."))
                }
            }
            .navigationTitle(selecting ? (selection.isEmpty ? "Select Chats" : "\(selection.count) Selected") : "Chats")
            .navigationBarTitleDisplayMode(.inline)
            .background(InteractivePopEnabler())
            // Driven by the stack's own path rather than by the pushed screen: the bar starts
            // coming back the instant a pop begins instead of after the transition settles.
            .onChange(of: path.wrappedValue.isEmpty, initial: true) { was, empty in
                model.chatsPathOpen = !empty; model.tabAtRoot[.chats] = empty
                // A chat composed from another tab closes back onto that tab, not onto this list.
                if !was, empty { returnFromCompose() }
            }
            .onChange(of: model.popToRoot[.chats]) { _, _ in path.wrappedValue = NavigationPath() }
            // A tap on the Chats tab while it is selected also brings the list back to the top.
            .onChange(of: model.tabReselected[.chats]) { _, _ in scrollToTop += 1 }
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { endSelecting() }.accessibilityIdentifier("chats.select.done") }
                    ToolbarItemGroup(placement: .topBarTrailing) { selectionActions }
                } else {
                ToolbarItem(placement: .topBarLeading) { profileMenu }
                #if os(macOS)
                // Two buttons, the same size, that fit over the list at its narrowest: a button
                // each for refresh, new bot, sort and filters ran past the column's edge and sat
                // over the chat beside it, and moved about as the window was resized.
                ToolbarItem(placement: .primaryAction) { viewMenu }
                ToolbarItem(placement: .primaryAction) { voiceMenu }
                ToolbarItem(placement: .primaryAction) { composeMenu }
                #else
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showNewBot = true } label: { Image(systemName: "plus") }.accessibilityLabel("New bot")
                    sortMenu
                    filterMenu
                }
                #endif
                }
            }
            // Compose: one tap is a fresh chat with the current bot, straight in (a tester:
            // "I shouldn't have to name it or choose appearance"); a long press is the
            // Messages-style sheet (To: bots, project, first message, files).
            .onChange(of: model.newChatRequest) { _, r in if r != nil { openFreshChat() } }
            .onChange(of: model.newChatSheetRequest) { _, r in
                guard r != nil, model.selectedTab == .chats, runtime != nil else { returnFromCompose(); return }
                sheetStarted = false
                showNewChat = true
            }
            // The mic circle beside it: a fresh chat, straight into voice mode (#237).
            .onChange(of: model.voiceChatRequest?.id) { _, id in if id != nil, let r = model.voiceChatRequest { openVoiceChat(r) } }
            .sheet(isPresented: $showNewBot) { if let runtime { NewBotSheet(runtime: runtime).sheetFrame().withAppModel() } }
            .sheet(isPresented: $showProjects) { NavigationStack { ProjectsView().toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showProjects = false } } } }.sheetFrame().withAppModel() }
            .sheet(isPresented: $movingSelection) {
                if let runtime {
                    MoveToProjectSheet(sessions: picked, runtime: runtime) { endSelecting() }.sheetFrame(.compact).withAppModel()
                }
            }
            // Cancelled from another tab's compose circle: straight back to that tab.
            .sheet(isPresented: $showNewChat, onDismiss: { if !sheetStarted { returnFromCompose() } }) {
                if let runtime {
                    NewChatSheet(runtime: runtime, initialProjectID: projectFilter.isEmpty || projectFilter == "__none__" ? runtime.projects.activeID : projectFilter) { start in
                        sheetStarted = true
                        let back = model.composeReturnTab
                        switch start {
                        case .chat(let profile, let text, let attachments, let cwd, let voice): open(ChatRoute(storedID: nil, title: nil, profile: profile, initialText: text, initialAttachments: attachments, cwd: cwd, startVoice: voice), returningTo: back)
                        case .group(let room, let text): rooms.insert(room, at: 0); open(RoomRoute(room: room, initialText: text), returningTo: back)
                        }
                    }
                    .sheetFrame()
                    .withAppModel()
                }
            }
            #if os(iOS)
            // The Mac's destinations are on the detail column's stack.
            .navigationDestination(for: ChatRoute.self) { route in ConversationView(route: route) }
            .navigationDestination(for: RoomRoute.self) { r in RoomView(room: r.room, initialText: r.initialText) }
            #endif
            .onChange(of: searchText) { _, q in Task { await search(q) } }
            .refreshable { await load() }
            .task(id: runtime?.connection.id) { await load() }
            .task(id: runtime?.selectedProfile) { await load() }
            .task(id: allBots) { await load() }
            // The socket coming up is when the gateway becomes reachable; do not wait for a pull.
            .onChange(of: runtime?.socketState) { _, s in if case .open? = s { Task { await load() } } }
            .onReceive(NotificationCenter.default.publisher(for: .hermesSessionsChanged)) { _ in Task { await load() } }
            .onChange(of: model.pendingRoute) { _, r in
                guard let r, r != lastRouted else { return }
                lastRouted = r
                // Already looking at that chat: nothing to push (a second copy of the same chat
                // used to land on top, and a confirmation asked there could go to the covered one).
                guard model.visibleChatID != r.storedSessionID else { return }
                open(ChatRoute(storedID: r.storedSessionID, title: r.kind == "readonly" ? "Bot Chat" : nil, profile: r.profile, readOnly: r.kind == "readonly"))
            }
            .alert("Delete group chat?", isPresented: Binding(get: { pendingRoomDelete != nil }, set: { if !$0 { pendingRoomDelete = nil } })) {
                Button("Delete", role: .destructive) { if let r = pendingRoomDelete { Task { await deleteRoom(r) } } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This disbands the group on the gateway. Its messages stay in the gateway's log.") }
            .alert(selection.count == 1 ? "Delete 1 chat?" : "Delete \(selection.count) chats?", isPresented: $pendingDeleteMany) {
                Button("Delete", role: .destructive) { let list = picked; endSelecting(); Task { await delete(list) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes the sessions and their transcripts from the gateway.") }
            .alert("Delete chat?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete", role: .destructive) { if let s = pendingDelete { Task { await delete(s) } } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes the session and its transcript from the gateway.") }
    }

    /// The compose circle's tap: a fresh chat with the current bot, in the project the list is
    /// narrowed to, with nothing to fill in first.
    private func openFreshChat() {
        guard model.selectedTab == .chats, let runtime else { returnFromCompose(); return }
        let profile = model.composeProfile ?? runtime.selectedProfile
        var cwd: String? = nil
        if !projectFilter.isEmpty, projectFilter != "__none__" { cwd = runtime.projects.project(id: projectFilter)?.startPath }
        open(ChatRoute(storedID: nil, title: nil, profile: profile, cwd: cwd), returningTo: model.composeReturnTab)
    }

    /// A fresh chat with the bot asked for (else the selected one), in the filter's project,
    /// and voice mode as soon as it exists; ending voice mode leaves the person in the chat.
    private func openVoiceChat(_ request: AppModel.VoiceChatRequest) {
        guard model.selectedTab == .chats, let runtime else { returnFromCompose(); return }
        var cwd: String? = nil
        if !projectFilter.isEmpty, projectFilter != "__none__" { cwd = runtime.projects.project(id: projectFilter)?.startPath }
        open(Self.voiceRoute(request, selectedProfile: runtime.selectedProfile, cwd: cwd), returningTo: model.composeReturnTab)
    }

    /// The chat a Voice Chat request opens: a fresh one with the bot asked for, else the bot
    /// the list shows, in the project filtered to, straight into voice mode.
    static func voiceRoute(_ request: AppModel.VoiceChatRequest, selectedProfile: String?, cwd: String?) -> ChatRoute {
        ChatRoute(storedID: nil, title: nil, profile: request.profile ?? selectedProfile, cwd: cwd, startVoice: true)
    }

    /// Back to the tab the compose circle was tapped on, if it was not this one.
    private func returnFromCompose() {
        guard let back = model.composeReturnTab else { return }
        model.composeReturnTab = nil
        withAnimation(.snappy(duration: 0.28)) { model.selectedTab = back }
    }

    private var profileMenu: some View {
        Menu {
            if let runtime {
                Picker("Profile", selection: Binding(get: { runtime.selectedProfile ?? "" }, set: { runtime.selectedProfile = $0 })) {
                    ForEach(runtime.profiles) { p in
                        Label { Text(p.label) } icon: { Image(uiImage: BotAvatarImage.make(profile: p.name, scheme: colorScheme)).renderingMode(.original) }.tag(p.name)
                    }
                }
                Toggle(isOn: $allBots) { Label("All bots", systemImage: "person.2") }
                #if os(macOS)
                Button { showNewBot = true } label: { Label("New Bot…", systemImage: "plus") }
                #endif
                Divider()
                Section(runtime.connection.name) {
                    Label(runtime.socketState.label, systemImage: connectionSymbol(runtime.socketState))
                    if case .open = runtime.socketState {} else {
                        Button { Task { await runtime.reconnectNow() } } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                    }
                }
                // Two gateways (a main machine and a homelab, say): switch here instead of
                // Settings › Gateways. Sessions belong to each gateway, so the list reloads.
                if model.store.connections.count > 1 {
                    Section("Switch gateway") {
                        ForEach(model.store.connections.filter { $0.id != runtime.connection.id }) { c in
                            Button { Task { await model.activate(c) } } label: { Label(c.name, systemImage: "server.rack") }
                        }
                    }
                }
            }
        } label: {
            // A fixed-size avatar: a text label changed width with each profile name and the bar
            // visibly jumped as it re-laid out.
            // A rendered, untinted image: live glass went murky on the toolbar's glass and a
            // painted view picked up the toolbar's tint in light mode.
            Image(uiImage: BotAvatarImage.make(profile: runtime?.selectedProfile ?? "?", size: 26, scheme: colorScheme)).renderingMode(.original)
                .accessibilityLabel("Profile: \(runtime?.selectedProfile ?? "none")")
        }
        .id("\(botColorsRaw)|\(botAvatarsRaw)|\(glassAll)|\(colorScheme == .light)")
    }

    /// Sort on its own button: inside the filter menu it sat under every project, a long
    /// scroll away once there were many.
    private var sortItems: some View {
        Picker("Sort by", selection: $sortKey) {
            Label("Recent", systemImage: "clock").tag("recent")
            Label("Title", systemImage: "textformat").tag("title")
            Label("Bot", systemImage: "person").tag("bot")
            Label("Model", systemImage: "cpu").tag("model")
        }
    }

    #if os(macOS)
    /// Refresh, sort, filters and Select in one menu.
    private var viewMenu: some View {
        Menu {
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            Menu { sortItems.pickerStyle(.inline).labelsHidden() } label: { Label("Sort By", systemImage: "arrow.up.arrow.down") }
            filterItems
        } label: {
            Label(filtering ? "View options (filters on)" : "View options", systemImage: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .menuIndicator(.hidden)
        .help(filtering ? "Sort and filters (filters on)" : "Sort and filters")
        .accessibilityIdentifier("chats.filters")
    }

    /// New Chat: a click is a fresh chat with the current bot; hold, or right-click, for the
    /// sheet with bots, a project and a first message.
    private var composeMenu: some View {
        Menu {
            Button { model.newChatRequest = UUID() } label: { Label("New Chat", systemImage: "square.and.pencil") }
            Button { model.newChatSheetRequest = UUID() } label: { Label("New Chat With…", systemImage: "person.2") }
        } label: {
            Label("New Chat", systemImage: "square.and.pencil")
        } primaryAction: {
            model.newChatRequest = UUID()
        }
        .menuIndicator(.hidden)
        .disabled(model.runtime == nil)
        .help("New Chat (⌘N). Hold for bots, a project and a first message (⇧⌘N).")
        .accessibilityLabel("New Chat")
        .accessibilityHint("Starts a chat with the current bot. Hold for the bots and a project.")
        .accessibilityIdentifier("chats.compose")
    }

    /// Voice chat: a click is a fresh chat with the bot the list shows (the default bot under
    /// All bots), straight into voice mode in its window; hold, or right-click, for the bots.
    private var voiceMenu: some View {
        Menu {
            ForEach(model.runtime?.profiles ?? []) { p in
                Button { model.voiceChatRequest = .init(profile: p.name) } label: { Label(p.label, systemImage: "person.fill") }
            }
        } label: {
            Label("Voice Chat", systemImage: "mic.fill")
        } primaryAction: {
            model.voiceChatRequest = .init(profile: nil)
        }
        .menuIndicator(.hidden)
        .disabled(model.runtime == nil)
        .help("Voice chat with the current bot. Hold to choose a bot.")
        .accessibilityLabel("Voice Chat")
        .accessibilityHint("Starts a voice chat with the current bot. Hold to choose a bot.")
        .accessibilityIdentifier("chats.voice")
    }
    #endif

    private var sortMenu: some View {
        Menu {
            sortItems
        } label: {
            Image(systemName: sortKey == "recent" ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle.fill")
                .accessibilityLabel("Sort: \(sortKey)")
        }
        .accessibilityIdentifier("chats.sort")
    }

    private var filterMenu: some View {
        Menu {
            filterItems
        } label: {
            Image(systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .accessibilityLabel(filtering ? "Filters (on)" : "Filters")
        }
        .accessibilityIdentifier("chats.filters")
    }

    @ViewBuilder private var filterItems: some View {
            Section("Show") {
                Toggle(isOn: $pinnedOnly) { Label("Pinned only", systemImage: "pin") }
                Toggle(isOn: $needsYouOnly) { Label("Needs you", systemImage: "exclamationmark.bubble") }
                Toggle(isOn: $liveOnly) { Label("Working now", systemImage: "bolt") }
                Toggle(isOn: $showArchived) { Label("Archived", systemImage: "archivebox") }
                Toggle(isOn: $groupsOnly) { Label("Group chats", systemImage: "person.3") }
            }
            if let runtime, runtime.projects.available == true {
                Section("Project") {
                    Picker("Project", selection: $projectFilter) {
                        Label("All projects", systemImage: "folder").tag("")
                        ForEach(runtime.projects.open) { p in Label(p.name, systemImage: "folder.fill").tag(p.id) }
                        Label("No project", systemImage: "folder.badge.questionmark").tag("__none__")
                    }
                    Toggle(isOn: $byProject) { Label("Group by project", systemImage: "rectangle.grid.1x2") }
                    Button { showProjects = true } label: { Label("Manage projects…", systemImage: "folder.badge.gearshape") }
                }
            }
            Button { withAnimation(.snappy) { selecting = true } } label: { Label("Select Chats", systemImage: "checkmark.circle") }
            if filtering {
                Button { pinnedOnly = false; needsYouOnly = false; liveOnly = false; groupsOnly = false; showArchived = true; projectFilter = "" } label: { Label("Clear filters", systemImage: "xmark.circle") }
            }
    }

    /// The filters and the sort applied to the loaded (or searched) sessions.
    private func filtered(_ list: [StoredSession], runtime: GatewayRuntime) -> [StoredSession] {
        var out = list
        if pinnedOnly { out = out.filter { $0.pinned == true } }
        if needsYouOnly { out = out.filter { runtime.needsAttention.contains($0.id) } }
        if liveOnly { out = out.filter { runtime.chatForStored($0.id)?.isRunning ?? false } }
        if !showArchived { out = out.filter { $0.archived != true } }
        if !projectFilter.isEmpty {
            let m = runtime.projects.membership
            out = out.filter { projectFilter == "__none__" ? m[$0.id] == nil : m[$0.id] == projectFilter }
        }
        // Every order keeps pinned chats first; within each half the chosen key decides, and
        // equal keys fall back to most recent (the sort is not stable on its own).
        func recent(_ a: StoredSession, _ b: StoredSession) -> Bool { (a.lastActive ?? a.startedAt ?? 0) > (b.lastActive ?? b.startedAt ?? 0) }
        func text(_ a: String, _ b: String, _ x: StoredSession, _ y: StoredSession) -> Bool {
            let c = a.localizedCaseInsensitiveCompare(b)
            return c == .orderedSame ? recent(x, y) : c == .orderedAscending
        }
        func shortModel(_ s: StoredSession) -> String { (s.model ?? "").split(separator: "/").last.map(String.init) ?? (s.model ?? "") }
        out.sort { a, b in
            let pa = a.pinned ?? false, pb = b.pinned ?? false
            if pa != pb { return pa }
            switch sortKey {
            case "title": return text(a.displayTitle, b.displayTitle, a, b)
            case "bot": return text(a.profile ?? "", b.profile ?? "", a, b)
            case "model": return text(shortModel(a), shortModel(b), a, b)
            default: return recent(a, b)
            }
        }
        return out
    }

    private func connectionSymbol(_ s: SocketState) -> String {
        switch s {
        case .open: return "checkmark.circle.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .authRejected, .failed: return "xmark.octagon.fill"
        case .idle: return "circle"
        }
    }

    /// The search field, our own rather than `.searchable`: the system's drawer sat where the
    /// pull-to-refresh spinner draws, so the spinner appeared inside the field. Pinned under the
    /// title by a safe-area inset; the list and its spinner scroll beneath it.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search chats", text: $searchText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search)
                #if os(macOS)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { searchText = ""; searchFocused = false }
                #endif
            if !searchText.isEmpty {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        #if os(macOS)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: .capsule)
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 6)
        #else
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 6)
        #endif
    }

    @ViewBuilder private func list(_ runtime: GatewayRuntime) -> some View {
        let rows = filtered(searchText.isEmpty ? sessions : searchResults, runtime: runtime)
        ScrollViewReader { proxy in
        List {
            // Not signed in on this device: the banner above says so and has the button; the
            // gateway's own "session expired" line under it would only repeat it in red.
            if let errorText, model.needsSignIn == nil { Text(errorText).foregroundStyle(.red).font(.footnote) }
            // Which project the list is narrowed to, since the rows' own chips are hidden then.
            if !projectFilter.isEmpty {
                HStack(spacing: 8) {
                    if let p = runtime.projects.project(id: projectFilter) { ProjectIcon(project: p, size: 22); Text(p.name).font(.subheadline.weight(.medium)) }
                    else { Image(systemName: "folder.badge.questionmark").foregroundStyle(.secondary); Text("Chats in no project").font(.subheadline.weight(.medium)) }
                    Spacer()
                    Button("Show all") { withAnimation { projectFilter = "" } }.font(.subheadline).buttonStyle(.borderless)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 6, trailing: 16))
            }
            // With the "Group chats" filter on, rooms sit among the chats by recency, as chats.
            let visibleRooms = groupsOnly
                ? rooms.filter { (showArchived || !archivedRooms.contains($0.roomId)) && (searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)) }
                : []
            if grouped(runtime) {
                groupedRows(rows, rooms: visibleRooms, runtime: runtime)
            } else {
                let entries = Self.merge(rows, visibleRooms, sort: sortKey)
                if entries.isEmpty && !loading {
                    if let waiting = model.needsSignIn {
                        ContentUnavailableView("Sign in to see your chats", systemImage: "person.badge.key",
                                               description: Text("\(waiting.name) has no sign-in on \(DeviceWords.this) yet."))
                            .listRowSeparator(.hidden)
                    } else {
                        ContentUnavailableView(searchText.isEmpty ? "No chats yet" : "No results", systemImage: "bubble.left.and.bubble.right",
                                               description: Text(searchText.isEmpty ? "Start a new chat with the compose button." : "Try another search."))
                            .listRowSeparator(.hidden)
                    }
                }
                ForEach(entries) { entry in
                    switch entry {
                    case .session(let s): sessionRow(s, runtime: runtime)
                    case .room(let room): roomRow(room, runtime: runtime)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        #if os(macOS)
        // The search field sits over the list it searches (in the top inset below), as in
        // Messages: in the window's toolbar it landed at the far end, over the open chat.
        .onChange(of: model.focusSearchRequest) { _, r in if r != nil { searchFocused = true } }
        // ⌥⌘↓ / ⌥⌘↑ from the Chat menu: the row after or before the open one.
        .onChange(of: model.chatStepRequest?.id) { _, _ in if let r = model.chatStepRequest { step(r.direction, runtime: runtime) } }
        #else
        // The system drawer: out of sight until the list is pulled down, like Mail.
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search chats")
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        #endif
        // Wider rows: the card hugs the screen edges and the rows their card.
        .contentMargins(.horizontal, ChatRowStyle.cardInset, for: .scrollContent)
        #if os(macOS)
        // The list runs a little way under the column's edge, which cut the scroll bar in half
        // down its length; the bar is brought back inside the column.
        .contentMargins(.trailing, 8, for: .scrollIndicators)
        #endif
        // The bots in the rows look where the list is going.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in BotAmbient.shared.scrolled(dy: new - old) }
        .overlay { if loading && sessions.isEmpty { ProgressView() } }
        // At the foot of the list, like Mail's status line: at the top it lay over the first
        // chat's title. The list is anchored at its top, so the rows do not move when it
        // comes and goes.
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) { SummaryProgressStrip() }
        #else
        // On the phone the tab bar floats over the pages and lists do not get its height as
        // safe area (RootView gives them a content margin instead), so a bottom inset still
        // lands behind the bar. The pill floats just above the bar, and at the bottom edge
        // when the bar is away (search with the keyboard up).
        .overlay(alignment: .bottom) {
            SummaryProgressStrip().padding(.bottom, model.tabBarHidden ? 0 : VoryTabBar.reservedHeight + 6)
        }
        #endif
        #if os(macOS)
        // A bar, not a plain inset: the rows fade out under it the way they do under the
        // toolbar, instead of showing through behind the search field.
        .safeAreaBar(edge: .top, spacing: 0) { topBars(runtime) }
        #else
        .safeAreaInset(edge: .top, spacing: 0) { topBars(runtime) }
        #endif
        .animation(.snappy, value: runtime.restartRequired == nil)
        .animation(.snappy, value: model.needsSignIn == nil)
        .onChange(of: scrollToTop) { _, _ in
            let first = Self.merge(rows, groupsOnly ? rooms : [], sort: sortKey).first?.id ?? rows.first?.id
            if let first { withAnimation(.snappy) { proxy.scrollTo(first, anchor: .top) } }
        }
        }
    }

    /// What sits over the list: the search field on the Mac, then whatever needs saying.
    private func topBars(_ runtime: GatewayRuntime) -> some View {
        VStack(spacing: 0) {
            #if os(macOS)
            searchField
            #endif
            if let waiting = model.needsSignIn {
                GatewaySignInBanner(connection: waiting)
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let msg = runtime.restartRequired {
                RestartRequiredBanner(runtime: runtime, message: msg)
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: Grouped by project

    private var collapsed: Set<String> { ChatProjectGroups.collapsed(collapsedRaw) }

    /// Projects on top, each opening to its chats: when the switch is on, the gateway has
    /// projects, and the list is not already narrowed to one or showing search results.
    private func grouped(_ runtime: GatewayRuntime) -> Bool {
        byProject && runtime.projects.available == true && projectFilter.isEmpty && searchText.isEmpty
    }

    private func groups(_ rows: [StoredSession], runtime: GatewayRuntime) -> [ChatProjectGroup] {
        let store = runtime.projects
        return ChatProjectGroups.make(rows, own: store.projects, membership: store.membership, selected: runtime.selectedProfile,
                                      others: allBots ? store.others : [:], keepEmpty: !filtering)
    }

    /// The first few chats of a project, or all of them once "Show all" was chosen.
    private func shown(_ g: ChatProjectGroup) -> [StoredSession] {
        shownInFull.contains(g.id) || g.sessions.count <= ChatProjectGroups.previewCount + 1 ? g.sessions : Array(g.sessions.prefix(ChatProjectGroups.previewCount))
    }

    @ViewBuilder private func groupedRows(_ rows: [StoredSession], rooms: [Room], runtime: GatewayRuntime) -> some View {
        ForEach(groups(rows, runtime: runtime)) { g in
            let folded = collapsed.contains(g.id)
            Section {
                if !folded {
                    let visible = shown(g)
                    ForEach(visible) { s in sessionRow(s, runtime: runtime, showProject: false) }
                    if visible.count < g.sessions.count {
                        Button { withAnimation(.snappy) { _ = shownInFull.insert(g.id) } } label: {
                            Text("Show all \(g.sessions.count)").font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                    }
                    if g.sessions.isEmpty {
                        Text("No chats here yet.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } header: {
                ProjectSectionHeader(group: g, collapsed: folded,
                                     working: g.sessions.filter { runtime.chatForStored($0.id)?.isRunning ?? false }.count,
                                     waiting: g.sessions.filter { runtime.needsAttention.contains($0.id) }.count,
                                     showBot: allBots,
                                     onToggle: { withAnimation(.snappy) { collapsedRaw = ChatProjectGroups.toggled(collapsedRaw, g.id) } },
                                     onNewChat: selecting ? nil : { startChat(in: g, runtime: runtime) })
            }
        }
        if !rooms.isEmpty {
            Section("Group chats") { ForEach(rooms.sorted { $0.updatedAt > $1.updatedAt }, id: \.roomId) { roomRow($0, runtime: runtime) } }
        }
    }

    /// The + on a project: a fresh chat with that project's bot, working in its folder.
    private func startChat(in g: ChatProjectGroup, runtime: GatewayRuntime) {
        let profile = g.project == nil ? (model.composeProfile ?? runtime.selectedProfile) : (g.profile ?? runtime.selectedProfile)
        open(ChatRoute(storedID: nil, title: nil, profile: profile, cwd: g.project?.startPath))
    }

    // MARK: Selecting several chats

    /// The chosen chats, in the list's order.
    private var picked: [StoredSession] { (searchText.isEmpty ? sessions : searchResults).filter { selection.contains($0.id) } }

    private func endSelecting() { withAnimation(.snappy) { selecting = false; selection = [] } }

    @ViewBuilder private var selectionActions: some View {
        if let runtime, runtime.projects.available == true, runtime.projects.canMove {
            Button { movingSelection = true } label: { Label("Move to Project", systemImage: "folder") }
                .disabled(selection.isEmpty).help("Move to Project").accessibilityIdentifier("chats.select.move")
        }
        Button { let list = picked; endSelecting(); Task { await archive(list) } } label: { Label("Archive", systemImage: "archivebox") }
            .disabled(selection.isEmpty).help("Archive")
        Button(role: .destructive) { pendingDeleteMany = true } label: { Label("Delete", systemImage: "trash") }
            .disabled(selection.isEmpty).help("Delete")
    }

    private func archive(_ list: [StoredSession]) async {
        guard let runtime else { return }
        for s in list where s.archived != true {
            var body: [String: JSONValue] = ["archived": .bool(true)]
            if s.pinned == true { body["pinned"] = .bool(false) }
            if let p = s.profile ?? runtime.selectedProfile, !p.isEmpty { body["profile"] = .string(p) }
            do { let _: JSONValue? = try await runtime.api.send("PATCH", "/api/sessions/\(s.id)", json: .object(body)) }
            catch { errorText = "Could not archive \u{201C}\(s.displayTitle)\u{201D}: \(error.localizedDescription)" }
        }
        await load()
    }

    private func delete(_ list: [StoredSession]) async {
        guard let runtime else { return }
        for s in list {
            droppedIDs.insert(s.id)
            if let chat = runtime.chatForStored(s.id) { runtime.closeChat(chat) }
            let _: JSONValue? = try? await runtime.api.send("DELETE", "/api/sessions/\(s.id)", profile: s.profile ?? runtime.selectedProfile, body: EmptyBody())
        }
        sessions.removeAll { s in list.contains { $0.id == s.id } }
        await load()
    }

    private func load(attempt: Int = 0) async {
        guard let runtime else { return }
        let cacheProfile = allBots ? "*" : runtime.selectedProfile
        if sessions.isEmpty {
            sessions = SessionCache.load(connection: runtime.connection.id, profile: cacheProfile)
            // A cold launch before the bot is known: any list for this gateway beats a blank page.
            if sessions.isEmpty { sessions = SessionCache.loadAny(connection: runtime.connection.id) }
        }
        loading = sessions.isEmpty; defer { loading = false }
        Task {
            await runtime.projects.refresh()
            // Projects are per bot: with every bot's chats listed, each bot's are read too.
            if allBots { await runtime.projects.refreshOthers(runtime.profiles.map(\.name)) }
        }
        do {
            var all: [StoredSession] = []
            if allBots {
                let profiles = runtime.profiles.map(\.name)
                try await withThrowingTaskGroup(of: [StoredSession].self) { group in
                    for p in profiles {
                        group.addTask {
                            let r: SessionListResponse = try await runtime.api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "50")], profile: p)
                            return r.sessions.map { var s = $0; if s.profile == nil || s.profile!.isEmpty { s.profile = p }; return s }
                        }
                    }
                    for try await part in group { all += part }
                }
            } else {
                // Each row carries the bot it was listed for: opening it later must not depend
                // on which bot is selected by then.
                let listed = runtime.selectedProfile
                let r: SessionListResponse = try await runtime.api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "100")], profile: listed)
                all = r.sessions.map { var s = $0; if s.profile == nil || s.profile!.isEmpty { s.profile = listed }; return s }
            }
            // Chats open in the app that the gateway does not list yet: a new chat gets its
            // stored row on the first prompt and the row fills in as the turn flushes, so a chat
            // started moments ago (or one still running) could vanish from the list on the way
            // back from it. They stay listed from the live session until the gateway has them.
            let listed = Set(all.map(\.id))
            // No local "keep" of pinned rows the gateway left out: the gateway lists every
            // pinned chat itself, so the only rows such a keep held were stale ones (a chat
            // compressed onto a new id, one deleted elsewhere), and those could never be
            // unpinned or archived again (the row was the app's own copy).
            let now = Date().timeIntervalSince1970
            for chat in runtime.chats where !listed.contains(chat.storedID) && !chat.storedID.isEmpty
                && (chat.isRunning || !chat.items.isEmpty)
                && (allBots || chat.profileName == (runtime.selectedProfile ?? chat.profileName)) {
                let last = chat.items.last?.timestamp.timeIntervalSince1970 ?? now
                all.append(StoredSession(id: chat.storedID, title: chat.title == "New chat" ? nil : chat.title,
                                         preview: chat.items.first.flatMap { if case .user(let t, _) = $0.kind { return t }; return nil },
                                         source: "ios", model: chat.modelName.isEmpty ? nil : chat.modelName,
                                         startedAt: chat.items.first?.timestamp.timeIntervalSince1970 ?? now, lastActive: max(last, now - 1),
                                         messageCount: chat.items.count, isActive: chat.isRunning, archived: false, pinned: false, profile: chat.profileName))
            }
            sessions = all.sorted { ($0.pinned ?? false ? 1 : 0, $0.lastActive ?? 0) > ($1.pinned ?? false ? 1 : 0, $1.lastActive ?? 0) }
            SessionCache.save(sessions, connection: runtime.connection.id, profile: cacheProfile)
            errorText = nil
            // Group chats live on the gateway's room driver; none when it has no rooms.
            if let r: GroupsListResult = try? await runtime.rpc("groups.list", ["limit": 50], timeout: 10).decode() {
                rooms = r.rooms.filter { $0.disbandedAt == nil }
            }
        } catch is CancellationError {
            // A newer load (the bot or the gateway changed) took over.
        } catch {
            if error.localizedDescription.localizedCaseInsensitiveContains("cancelled") { return }
            errorText = error.localizedDescription
            // A cold launch can ask before the session is refreshed or the gateway answers:
            // a blank page with nothing cached tries again a few times before giving up.
            if sessions.isEmpty, attempt < 3, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await load(attempt: attempt + 1)
            }
        }
    }

    private func search(_ q: String) async {
        guard let runtime, !q.trimmingCharacters(in: .whitespaces).isEmpty else { searchResults = []; return }
        do {
            let searched = runtime.selectedProfile
            let r: JSONValue = try await runtime.api.get("/api/sessions/search", query: [URLQueryItem(name: "q", value: q)], profile: searched)
            let arr = r["sessions"]?.arrayValue ?? r["results"]?.arrayValue ?? r.arrayValue ?? []
            searchResults = arr.compactMap { try? $0.decode(StoredSession.self) }.map { var s = $0; if s.profile == nil || s.profile!.isEmpty { s.profile = searched }; return s }
        } catch { errorText = error.localizedDescription }
    }

    /// A row of the list: a chat, or a group chat when the filter lets them in.
    enum ListEntry: Identifiable {
        case session(StoredSession), room(Room)
        var id: String { switch self { case .session(let s): return s.id; case .room(let r): return "room:" + r.roomId } }
        var pinned: Bool { if case .session(let s) = self { return s.pinned ?? false }; return false }
        var date: Double { switch self { case .session(let s): return s.lastActive ?? 0; case .room(let r): return r.updatedAt } }
    }

    /// The chats in the order `filtered` chose; group chats join them by recency under the
    /// Recent order, by name under Title, and after them otherwise. (This used to re-sort
    /// everything by date, which undid the Title / Bot / Model orders.)
    private static func merge(_ sessions: [StoredSession], _ rooms: [Room], sort: String = "recent") -> [ListEntry] {
        let chats = sessions.map(ListEntry.session)
        guard !rooms.isEmpty else { return chats }
        switch sort {
        case "recent":
            return (chats + rooms.map(ListEntry.room)).sorted { ($0.pinned ? 1 : 0, $0.date) > ($1.pinned ? 1 : 0, $1.date) }
        case "title":
            let byName = rooms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map(ListEntry.room)
            var out: [ListEntry] = [], r = byName.makeIterator(), next = r.next()
            for c in chats {
                if case .session(let s) = c {
                    while let n = next, case .room(let room) = n, !(s.pinned ?? false),
                          room.name.localizedCaseInsensitiveCompare(s.displayTitle) == .orderedAscending { out.append(n); next = r.next() }
                }
                out.append(c)
            }
            while let n = next { out.append(n); next = r.next() }
            return out
        default:
            return chats + rooms.sorted { $0.updatedAt > $1.updatedAt }.map(ListEntry.room)
        }
    }

    /// A row that opens `route`: a link on the phone, a button into the detail column on the Mac.
    /// `pick`: the chat's id, for a row that can be chosen while selecting.
    @ViewBuilder private func rowLink<Label: View>(_ route: some Hashable, selected: Bool = false, pick: String? = nil, @ViewBuilder label: () -> Label) -> some View {
        if selecting {
            let on = pick.map(selection.contains) ?? false
            Button {
                guard let pick else { return }
                if on { selection.remove(pick) } else { selection.insert(pick) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title3)
                        .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(pick == nil ? 0.25 : 0.7))
                    label()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(pick == nil)
            .accessibilityAddTraits(on ? .isSelected : [])
        } else {
            openLink(route, selected: selected, label: label)
        }
    }

    @ViewBuilder private func openLink<Label: View>(_ route: some Hashable, selected: Bool, @ViewBuilder label: () -> Label) -> some View {
        #if os(macOS)
        Button { open(route) } label: { label().contentShape(.rect) }.buttonStyle(.plain)
            // The open chat's row, tinted like the selected conversation in Messages. Drawn
            // here: the Mac's list did not show a listRowBackground on these rows.
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.16))
                        .padding(.horizontal, -8).padding(.vertical, -7)
                }
            }
        #else
        NavigationLink(value: route) { label() }
        #endif
    }

    /// The bot beside each chat: with All bots on the phone, always on the Mac (the list reads
    /// like a list of conversations with someone).
    private var rowsShowBot: Bool {
        #if os(macOS)
        true
        #else
        allBots
        #endif
    }

    @ViewBuilder private func sessionRow(_ s: StoredSession, runtime: GatewayRuntime, showProject: Bool = true) -> some View {
        let route = ChatRoute(storedID: s.id, title: s.displayTitle, profile: s.profile)
                rowLink(route, selected: selectedID == s.id, pick: s.id) {
                    SessionRow(session: s, needsYou: runtime.needsAttention.contains(s.id), live: runtime.chatForStored(s.id)?.isRunning ?? false, showBot: rowsShowBot,
                               botProfile: s.profile ?? runtime.selectedProfile,
                               thinking: runtime.chatForStored(s.id).map { $0.isRunning && ($0.statusLine ?? "Thinking…") == "Thinking…" } ?? false,
                               project: showProject && projectFilter.isEmpty ? runtime.projects.project(forSession: s.id) : nil,
                               step: runtime.needsAttention.contains(s.id) ? nil : runtime.chatForStored(s.id)?.statusLine,
                               summary: summarizer.shown(summarizer.summary(for: s), title: s.displayTitle, preview: s.preview ?? ""))
                        .task(id: "\(s.id)-\(s.lastActive ?? 0)-\(aiSummaries)") { if aiSummaries { summarizer.refresh(s, runtime: runtime, profile: allBots ? s.profile : nil) } }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: ChatRowStyle.rowInset, bottom: 10, trailing: 8))
                #if os(macOS)
                // A firm press on the trackpad peeks the conversation, as the long press does on the phone.
                .onForceClick { peeking = s }
                .popover(isPresented: Binding(get: { peeking?.id == s.id }, set: { if !$0 { peeking = nil } })) {
                    SessionPreview(session: s, runtime: runtime, profile: allBots ? s.profile : nil).withAppModel()
                }
                #endif
                .contextMenu {
                    Button { open(route) } label: { Label("Open", systemImage: "bubble.left") }
                    Button { Task { await patch(s, ["pinned": .bool(!(s.pinned ?? false))]) } } label: { Label(s.pinned == true ? "Unpin" : "Pin", systemImage: s.pinned == true ? "pin.slash" : "pin") }
                    Button { Task { await patch(s, ["archived": .bool(!(s.archived ?? false))]) } } label: { Label(s.archived == true ? "Unarchive" : "Archive", systemImage: "archivebox") }
                    if runtime.projects.available == true, runtime.projects.canMove {
                        Menu {
                            ProjectMoveMenu(sessions: [s], runtime: runtime) { errorText = $0 }
                        } label: { Label("Move to Project", systemImage: "folder") }
                    }
                    Button { withAnimation(.snappy) { selecting = true; selection = [s.id] } } label: { Label("Select", systemImage: "checkmark.circle") }
                    Divider()
                    Button(role: .destructive) { pendingDelete = s } label: { Label("Delete", systemImage: "trash") }
                } preview: {
                    SessionPreview(session: s, runtime: runtime, profile: allBots ? s.profile : nil).withAppModel()
                }
                // Delete alone on the trailing edge; Archive lives with Pin on the leading edge so
                // the two are never a thumb-width apart.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { pendingDelete = s } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button { Task { await patch(s, ["pinned": .bool(!(s.pinned ?? false))]) } } label: { Label(s.pinned == true ? "Unpin" : "Pin", systemImage: s.pinned == true ? "pin.slash" : "pin") }.tint(.yellow)
                    Button { Task { await patch(s, ["archived": .bool(!(s.archived ?? false))]) } } label: { Label(s.archived == true ? "Unarchive" : "Archive", systemImage: "archivebox") }.tint(.orange)
                }
    }

    @ViewBuilder private func roomRow(_ room: Room, runtime: GatewayRuntime) -> some View {
        let archived = archivedRooms.contains(room.roomId)
        let log = roomLogs[room.roomId] ?? []
        let summary = summarizer.shown(summarizer.summary(forRoom: room, events: log), title: room.name, preview: Self.lastLine(room, log) ?? "")
                rowLink(RoomRoute(room: room, initialText: nil), selected: selectedID == "room:" + room.roomId) {
                    HStack(spacing: 12) {
                        HStack(spacing: -12) {
                            ForEach(Array(room.members.prefix(3).enumerated()), id: \.offset) { _, m in
                                BotAvatar(profile: m.profile ?? m.handle ?? "?", size: 30)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                if archived { Image(systemName: "archivebox").font(.caption2).foregroundStyle(.secondary) }
                                Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(.secondary)
                                Text(summary?.title ?? room.name).font(.body.weight(.medium)).lineLimit(1)
                                SummarySparkle(key: ChatSummarizer.roomKey(room), done: summary != nil)
                            }
                            // The summary, else the last thing said, else who is in it.
                            Text(summary?.summary ?? Self.lastLine(room, log) ?? room.members.compactMap { $0.displayName ?? $0.handle ?? $0.profile }.joined(separator: ", "))
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: ChatRowStyle.rowInset, bottom: 10, trailing: 8))
                .task(id: "\(room.roomId)-\(room.latestSeq ?? 0)-\(aiSummaries)") {
                    if roomLogs[room.roomId] == nil || (room.latestSeq ?? 0) > (roomLogs[room.roomId]?.last?.seq ?? 0),
                       let r: GroupsLogResult = try? await runtime.rpc("groups.log", ["room_id": .string(room.roomId), "since_seq": 0, "limit": 40], timeout: 10).decode() {
                        roomLogs[room.roomId] = r.events
                    }
                    if aiSummaries, let events = roomLogs[room.roomId] { summarizer.refreshRoom(room, events: events) }
                }
                .contextMenu {
                    Button { open(RoomRoute(room: room, initialText: nil)) } label: { Label("Open", systemImage: "bubble.left") }
                    Button { setArchived(room, !archived) } label: { Label(archived ? "Unarchive" : "Archive", systemImage: "archivebox") }
                    Divider()
                    Button(role: .destructive) { pendingRoomDelete = room } label: { Label("Delete", systemImage: "trash") }
                } preview: {
                    RoomPreview(room: room, runtime: runtime).withAppModel()
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { pendingRoomDelete = room } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button { setArchived(room, !archived) } label: { Label(archived ? "Unarchive" : "Archive", systemImage: "archivebox") }.tint(.orange)
                }
    }

    /// "You: …" or "Hermes: …" from the last message in a room's log.
    private static func lastLine(_ room: Room, _ log: [RoomEvent]) -> String? {
        guard let ev = log.last(where: { $0.kind.hasPrefix("message.") }) else { return nil }
        // Plain words for a one-line preview: no markdown marks, no line breaks.
        let text = (ev.payload["text"]?.stringValue ?? ev.payload["content"]?.stringValue ?? "")
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty else { return nil }
        if ev.kind == "message.user" { return "You: \(text)" }
        let who = ev.payload["member_id"]?.stringValue ?? ev.actor.id
        let name = room.members.first { $0.memberId == who || $0.handle == who }?.displayName ?? who
        return "\(name): \(text)"
    }

    private func setArchived(_ room: Room, _ on: Bool) {
        var set = archivedRooms
        if on { set.insert(room.roomId) } else { set.remove(room.roomId) }
        archivedRoomsRaw = set.sorted().joined(separator: ",")
    }

    private func deleteRoom(_ room: Room) async {
        guard let runtime else { return }
        do {
            // Gateways name it differently; try the common ones before giving up.
            var lastError: Error?
            for method in ["groups.disband", "groups.delete", "groups.close"] {
                do { _ = try await runtime.rpc(method, ["room_id": .string(room.roomId)]); lastError = nil; break }
                catch { lastError = error }
            }
            if let lastError { throw lastError }
            rooms.removeAll { $0.roomId == room.roomId }
            setArchived(room, false)
        } catch { errorText = "Could not delete the group chat: \(error.localizedDescription)" }
    }

    private func delete(_ s: StoredSession) async {
        droppedIDs.insert(s.id)
        guard let runtime else { return }
        if let chat = runtime.chatForStored(s.id) { runtime.closeChat(chat) }
        sessions.removeAll { $0.id == s.id }
        // The chat's own bot, not the selected one: with All bots on, rows come from every profile.
        let _: JSONValue? = try? await runtime.api.send("DELETE", "/api/sessions/\(s.id)", profile: s.profile ?? runtime.selectedProfile, body: EmptyBody())
        await load()
    }

    private func patch(_ s: StoredSession, _ fields: [String: JSONValue]) async {
        guard let runtime else { return }
        var body = fields
        if let p = s.profile ?? runtime.selectedProfile, !p.isEmpty { body["profile"] = .string(p) }
        // Archiving a pinned chat unpins it too: the gateway lists every pinned chat, archived
        // or not, so an archived pin would stay at the top as if nothing happened.
        if case .bool(true)? = body["archived"], s.pinned == true { body["pinned"] = .bool(false) }
        // Shown at once; the gateway's answer decides whether it stays that way.
        let before = sessions
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {
            if case .bool(let v)? = body["pinned"] { sessions[i].pinned = v }
            if case .bool(let v)? = body["archived"] { sessions[i].archived = v }
        }
        do {
            let _: JSONValue? = try await runtime.api.send("PATCH", "/api/sessions/\(s.id)", json: .object(body))
        } catch HermesAPIError.http(let status, _) where status == 404 {
            // The gateway no longer has this id (compressed onto a new one, deleted elsewhere):
            // the row was stale, and the gateway's list is the truth.
            sessions.removeAll { $0.id == s.id }
            droppedIDs.insert(s.id)
        } catch {
            sessions = before
            errorText = "Could not update the chat: \(error.localizedDescription)"
            return
        }
        await load()
    }
}

struct SessionRow: View {
    var session: StoredSession
    var needsYou: Bool
    var live: Bool
    var showBot = false
    /// Whose face to draw when the session itself does not say (the selected bot's list).
    var botProfile: String? = nil
    var thinking = false
    var project: Project? = nil
    /// The step the bot is on while it works ("Running terminal…"), shown when no goal line is written.
    var step: String? = nil
    /// The on-device summary, when Vory Summaries is on and one is ready for this chat.
    var summary: ChatSummarizer.Summary? = nil

    var body: some View {
        HStack(spacing: 12) {
            // In the list: the eyes and the held pose (a squint, the pebble), no routines.
            if showBot { BotAvatar(profile: session.profile ?? botProfile ?? "?", size: 34, active: live, mood: BotFaceView.Mood(state: live ? (thinking ? .thinking : .streaming) : .idle)) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if session.pinned == true { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    if session.archived == true { Image(systemName: "archivebox").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Archived") }
                    Text(summary?.title ?? session.displayTitle).font(.body.weight(.medium)).lineLimit(1)
                    SummarySparkle(key: session.id, done: summary != nil)
                }
                // While the bot works: what it is working on, over one line of the preview, so
                // the row keeps its height.
                if live { ChatGoalLine(storedID: session.id, step: step) }
                Text(summary?.summary ?? session.preview ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(live ? max(1, ChatRowStyle.previewLines - 1) : ChatRowStyle.previewLines)
                HStack(spacing: 8) {
                    if let project { ProjectChip(project: project) }
                    if let m = session.model, !m.isEmpty { Text(m).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    if let d = session.lastDate { Text(d, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            Spacer(minLength: 0)
            if needsYou {
                Text("Needs you").font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.red.opacity(0.15), in: .capsule).foregroundStyle(.red)
            } else if live {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}


/// The long-press peek for a chat row: the tail of the conversation as small bubbles, like
/// peeking a thread in Messages. Open stays in the menu; SwiftUI previews cannot be tapped through.
struct SessionPreview: View {
    var session: StoredSession
    var runtime: GatewayRuntime?
    var profile: String?
    @State private var messages: [TranscriptMessage] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BotAvatar(profile: session.profile ?? profile ?? runtime?.selectedProfile ?? "?", size: 24)
                Text(session.displayTitle).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
            }
            if messages.isEmpty {
                if let p = session.preview, !p.isEmpty {
                    Text(p).font(.subheadline).foregroundStyle(.secondary).lineLimit(6)
                }
                if !loaded { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, m in
                        HStack {
                            if m.role == "user" { Spacer(minLength: 40) }
                            Text(m.text ?? "").font(.footnote).lineLimit(4)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .foregroundStyle(m.role == "user" ? .white : .primary)
                                .background(m.role == "user" ? Color.vory : Color(.systemGray5), in: .rect(cornerRadius: 12))
                            if m.role != "user" { Spacer(minLength: 40) }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if let n = session.messageCount { Label("\(n) messages", systemImage: "text.bubble") }
                if let m = session.model, !m.isEmpty { Label(m.split(separator: "/").last.map(String.init) ?? m, systemImage: "cpu").lineLimit(1) }
                if let d = session.lastDate { Text(d, format: .relative(presentation: .named)) }
            }
            .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .task {
            defer { loaded = true }
            if let cached = runtime.flatMap({ TranscriptCache.load(connection: $0.connection.id, storedID: session.id) }), !cached.isEmpty {
                messages = Array(cached.filter { $0.role == "user" || $0.role == "assistant" }.suffix(6)); return
            }
            guard let runtime, let r: JSONValue = try? await runtime.api.get("/api/sessions/\(session.id)/messages",
                                                                             query: [URLQueryItem(name: "order", value: "latest"), URLQueryItem(name: "limit", value: "12")],
                                                                             profile: profile ?? session.profile ?? runtime.selectedProfile) else { return }
            let all = TranscriptItem.withPromotedAnswers((r["messages"]?.arrayValue ?? []).compactMap { try? $0.decode(TranscriptMessage.self) })
            messages = Array(all.filter { ($0.role == "user" || $0.role == "assistant") && !($0.text ?? "").isEmpty }.suffix(6))
        }
    }
}

/// The long-press peek for a group chat: the bots in it and the last few messages.
struct RoomPreview: View {
    var room: Room
    var runtime: GatewayRuntime
    @State private var events: [RoomEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: -10) {
                    ForEach(Array(room.members.prefix(4).enumerated()), id: \.offset) { _, m in BotAvatar(profile: m.profile ?? m.handle ?? "?", size: 26) }
                }
                Text(room.name).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(room.members.compactMap { $0.displayName ?? $0.handle ?? $0.profile }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(events.suffix(5)) { ev in
                    let user = ev.kind == "message.user"
                    HStack {
                        if user { Spacer(minLength: 40) }
                        Text(ev.payload["text"]?.stringValue ?? "").font(.footnote).lineLimit(3)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .foregroundStyle(user ? .white : .primary)
                            .background(user ? Color.vory : Color(.systemGray5), in: .rect(cornerRadius: 12))
                        if !user { Spacer(minLength: 40) }
                    }
                }
            }
            Label("Group chat", systemImage: "person.3").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .task {
            if let r: GroupsLogResult = try? await runtime.rpc("groups.log", ["room_id": .string(room.roomId), "since_seq": 0, "limit": 60], timeout: 10).decode() {
                events = r.events.filter { $0.kind == "message.user" || $0.kind == "message.member" }
            }
        }
    }
}

/// How much room the chat rows get. DEBUG: `-vory-row-style a|b|c` tries the variants
/// (a = the old spacing, b = tighter, c = tighter with a three-line preview).
enum ChatRowStyle {
    static let variant: String = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-vory-row-style"), i + 1 < args.count { return args[i + 1] }
        #endif
        return "b"
    }()
    static var cardInset: CGFloat { variant == "a" ? 16 : 8 }
    static var rowInset: CGFloat { variant == "a" ? 16 : 12 }
    static var previewLines: Int { variant == "c" ? 3 : 2 }
}

/// A group chat as a navigation value, with the first message when it was just started.
struct RoomRoute: Hashable {
    var room: Room
    var initialText: String?
}
