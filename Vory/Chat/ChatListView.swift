import SwiftUI
import VoryCore

struct ChatRoute: Hashable, Codable {
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
    /// The model and reasoning level picked in the compose sheet: set on the new chat before its
    /// first message (#27). Not restored, as the picked files are not.
    var initialModel: ChatSession.ModelPick? = nil
    var initialReasoning: String? = nil

    /// Saved and restored without the picked files: `AttachmentPreview` carries local file
    /// URLs and is not Codable, and a route is only ever restored for a chat that exists.
    private enum CodingKeys: String, CodingKey { case storedID, title, profile, initialText, readOnly, cwd, token, startVoice }
}

struct ChatListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowGeometry) private var windowGeometry
    /// The status stands in a top corner: the top bar's row gets its room there, and the search keeps the bar (`TopBarRoom`).
    @Environment(\.statusInCorner) private var statusInCorner
    /// The top bar up in the status band (the open Duo upright): the bar kept while searching there too (#516).
    @Environment(\.barLift) private var barLift
    /// The Mac keeps this page mounted behind the others (`macPageShown`, MainSplitView).
    @Environment(\.macPageShown) private var pageShown
    /// The Mac's split view hands in the detail column's path: chats open there, beside the list,
    /// and a click replaces the one showing. On the phone the list owns its own stack and pushes.
    var detailPath: Binding<NavigationPath>? = nil
    /// A stack around the list that someone else owns (ChatsSplitPage's one-column root): the
    /// list pushes onto it instead of its own; the destinations are the owner's.
    /// Inside the stack the Chats page owns (`AppModel.chatPath`): the list pushes onto it and
    /// mounts no stack of its own. A flag, not a binding: a binding handed down on every path
    /// change made SwiftUI see a new view each time and re-run the whole list on every Back.
    var inModelStack = false
    /// The list's settings (filters, sort, the look keys): one observable object instead of
    /// fifteen @AppStorage properties, so this view's stored properties compare equal when its
    /// parent hands it a fresh copy on every path change, and SwiftUI skips the body instead of
    /// rebuilding a hundred rows on every Back (2026-10-11).
    private var prefs: ChatListPrefs { ChatListPrefs.shared }
    @State private var sessions: [StoredSession] = []
    /// Bumped by a tap on the selected Chats tab: the list scrolls to its first row.
    @State private var scrollToTop = 0
    /// Rows waiting for their swipe action or menu to close before they move (#372): their pin
    /// and archive as they were, kept by a reload that lands in the wait, so the change cannot
    /// arrive unanimated ahead of its own move.
    @State private var heldRows: [String: (pinned: Bool?, archived: Bool?)] = [:]
    /// Until when a row's move is playing: a reload placed in the middle of it left a blank row
    /// where the moving one was going, so it waits.
    @State private var movingUntil = Date.distantPast
    /// How long a row's swipe action, or its menu's preview, takes to close: the row moves after.
    /// Moved while its swipe was still closing, it went with its actions out and its place blank
    /// but for faint Pin and Archive circles, then popped in (#372, Matt on 24). 400 ms was set
    /// while the move itself also left a blank slot; with a pinned row leaving and arriving
    /// (`listRowID`) the circles are gone about 0.1 s after the tap and the row is back by about
    /// 0.3 s, so the move starts as the swipe settles (1.5 (26); two clean runs at 250).
    static let closeBeforeMove: Duration = .milliseconds(250)
    /// The move itself (a snappy spring), for `movingUntil`.
    static let moveLength: TimeInterval = 0.4
    /// Chats the user deleted here, so a pinned row is not kept alive from memory afterwards.
    @State private var droppedIDs: Set<String> = []
    @State private var searchText = ""
    #if os(macOS)
    @FocusState private var searchFocused: Bool
    #endif
    /// The chat VoiceOver is on after a pin or an unpin: the row it was on leaves (`listRowID`),
    /// and focus follows the chat to where it arrives.
    @AccessibilityFocusState private var spokenRow: String?
    @State private var searchResults: [StoredSession] = []
    @State private var loading = false
    @State private var errorText: String?
    /// A pin, an unpin or an archive the gateway refused, said in an alert: the list's red line
    /// was cleared by the next refresh, which a list of scheduled runs does every few minutes, and
    /// all a tester saw was the row going back (#406).
    @State private var actionFailure: ActionFailure?
    /// The gateway keeps chats' pins (`PinSupport`): Pin is offered only then.
    @State private var pinsKept = true
    @State private var ownPath = NavigationPath()
    private var path: Binding<NavigationPath> {
        if let detailPath { return detailPath }
        if inModelStack { let m = model; return Binding(get: { m.chatPath }, set: { m.chatPath = $0 }) }
        return $ownPath
    }
    /// The row a force click is peeking (Mac).
    @State private var peeking: StoredSession?
    /// The chat showing in the detail column (Mac), for the row's highlight.
    /// The highlighted row: `AppModel.chatSelectionID`, so it survives the list being rebuilt.
    private var selectedID: String? {
        get { model.chatSelectionID }
        nonmutating set { model.chatSelectionID = newValue }
    }
    @State private var pendingDelete: StoredSession?
    @State private var lastRouted: PendingRoute?
    /// Every profile's chats in one list, newest first, with the bot's avatar on each row.
    @State private var showNewChat = false
    /// The New Message sheet started a chat (as against being cancelled).
    @State private var sheetStarted = false
    @State private var showNewBot = false
    private var aiSummaries: Bool { prefs.aiTitles || prefs.aiPreviews }
    private var summarizer: ChatSummarizer { ChatSummarizer.shared }
    @State private var rooms: [Room] = []
    /// Each room's recent log, for the row's preview and its summary.
    @State private var roomLogs: [String: [RoomEvent]] = [:]
    // Filters (the funnel button): what to show and in which order.
    /// "" for every chat, a project id, or "__none__" for chats in no project.
    @State private var showProjects = false
    /// Chats under their projects, each one foldable, instead of one flat list.
    /// Projects showing every chat instead of the first few.
    @State private var shownInFull: Set<String> = []
    /// Picking several chats to move, archive or delete together.
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var movingSelection = false
    @State private var pendingDeleteMany = false
    /// Rooms have no archive on the gateway; archived ones are remembered here.
    @State private var pendingRoomDelete: Room?
    private var archivedRooms: Set<String> { Set(prefs.archivedRoomsRaw.split(separator: ",").map(String.init)) }
    private var filtering: Bool { prefs.pinnedOnly || prefs.needsYouOnly || prefs.liveOnly || prefs.groupsOnly || !prefs.showArchived || !prefs.projectFilter.isEmpty }
    /// The profile menu's icons are rendered images; UIKit keeps the built menu, so it is given a
    /// new identity whenever a bot's colour or look changes.
    @Environment(\.colorScheme) private var colorScheme
    /// Mirrors the tab bar's minimize-on-scroll so the compose circle drops beside the collapsed bar.

    private var runtime: GatewayRuntime? { model.runtime }

    #if os(macOS)
    /// The list as shown, for stepping through it from the keyboard.
    private func entries(_ runtime: GatewayRuntime) -> [ListEntry] {
        let rows = filtered(searchText.isEmpty ? sessions : searchResults, runtime: runtime)
        let visibleRooms = prefs.groupsOnly
            ? rooms.filter { (prefs.showArchived || !archivedRooms.contains($0.roomId)) && (searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)) }
            : []
        if grouped(runtime) {
            // Top to bottom as drawn: each open project's visible chats, then the group chats.
            return groups(rows, runtime: runtime).flatMap { g in collapsed.contains(g.id) ? [] : shown(g).map(ListEntry.session) } + visibleRooms.map(ListEntry.room)
        }
        return Self.merge(rows, visibleRooms, sort: prefs.sortKey)
    }

    /// Opens the chat `direction` rows away from the open one (the first when none is open).
    private func step(_ direction: Int, runtime: GatewayRuntime) {
        let list = entries(runtime)
        guard !list.isEmpty else { return }
        let current = list.firstIndex { e in
            switch e {
            case .session(let s): return s.id == selectedID
            case .room(let r): return ChatNavigation.selectionID(ofRoom: r.roomId) == selectedID
            }
        }
        let next = current.map { min(max($0 + direction, 0), list.count - 1) } ?? 0
        switch list[next] {
        case .session(let s): open(ChatRoute(storedID: s.id, title: s.displayTitle, profile: s.profile))
        case .room(let r): open(RoomRoute(room: r))
        }
    }
    #endif

    /// Opens a chat or a group chat: pushed when the list owns its stack (the phone); beside a
    /// detail column (the Mac; the iPad and the open Duo in 1.5) it replaces whatever the column
    /// shows, the way selecting a conversation does in Messages (`ChatNavigation`). `back` is the
    /// tab to return to when this chat closes (the compose circle tapped elsewhere); any other
    /// way in forgets a pending one.
    private func open(_ route: some Hashable, returningTo back: AppModel.AppTab? = nil) {
        model.composeReturnTab = back
        if detailPath != nil {
            ChatNavigation.select(route, in: &path.wrappedValue)
            selectedID = ChatNavigation.selectionID(of: route)
        } else {
            ChatNavigation.push(route, onto: &path.wrappedValue)
        }
    }

    var body: some View {
        if detailPath != nil || inModelStack {
            // A column of the split view (the detail column's stack shows the chats), or inside
            // a stack the page owns (`stackPath`).
            content
        } else {
            NavigationStack(path: path) {
                content
                    .navigationDestination(for: ChatRoute.self) { route in ConversationView(route: route).countsChatOnScreen() }
                    .navigationDestination(for: RoomRoute.self) { r in RoomView(room: r.room, initialText: r.initialText).countsChatOnScreen(room: true) }
            }
        }
    }

    private var content: some View {
            Group {
                if let runtime {
                    list(runtime)
                } else {
                    ContentUnavailableView("No gateway selected", systemImage: "antenna.radiowaves.left.and.right.slash", description: Text(model.activationError ?? "Choose a gateway in Settings."))
                }
            }
            .navigationTitle(windowTitle)
            .navigationBarTitleDisplayMode(.inline)
            #if os(iOS)
            // The search field is tucked under the title and revealed by a pull, as on the Bots
            // and Settings pages (Matt, 2026-10-12). On iOS 26 this drawer coexists with
            // pull-to-refresh (Bots does both), so the pinned custom field it replaced, from
            // before this iOS, is gone; the field no longer rides in and out with the bar on the
            // way back from a chat.
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search chats")
            // The bar kept while searching under a status in a top corner or with the bar up in the band, as on the other
            // pages (#516).
            .searchPresentationToolbarBehavior(TopBarRoom.keepsBarWhileSearching(statusInCorner: statusInCorner, barUp: barLift > 0) ? .avoidHidingContent : .automatic)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            #endif
            // One column on a window wider than a phone (the open Duo upright, 669 pt): the
            // bar centred its title, which landed beside the trailing buttons; the title goes
            // into the leading group after the bot circle, as on a phone.
            #if os(iOS)
            // In two columns as well: the list column is narrow, and the system's centred
            // inline title had 30 pt between the bot circle and the trailing group ("Ch…" on
            // the open Duo, 2026-10-12). The morph bar draws the title itself on one column.
            .pageHeading(selecting ? (selection.isEmpty ? "Select Chats" : "\(selection.count) Selected") : "Chats", on: !MorphTopBar.active(model))
            #endif
            #if os(iOS)
            // The morph prototype draws the list's controls over the page (MorphTopBar): the bar
            // stays, empty (its title removed, its items below skipped), so the rows keep the
            // bar's room and the search drawer. Hiding the bar here made the pushed chat's own
            // hidden bar come back (the system title and back button drew over the prototype).
            .toolbar(removing: MorphTopBar.active(model) ? .title : nil)
            // Out of the accessibility tree while another tab is up (#326; TabRoot does the
            // same for the other roots, inside their stacks where the flag is honoured).
            .accessibilityHidden(model.selectedTab != .chats)
            // An empty bar collapses (the Duo's search drawer rode up under the capsules): an
            // invisible item keeps it at its height under the prototype.
            .toolbar { if MorphTopBar.active(model) { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 44).accessibilityHidden(true) } } }
            // On the closed Duo the search drawer rode up under the bar's capsules (#340): the stack starts under its row.
            .background(TopBarRoomProbe(tab: .chats, room: TopBarRoom.inset(barsVertical: model.tabBarVertical, statusInCorner: statusInCorner,
                                                               barOn: MorphTopBar.active(model), rowBottom: MorphState.shared.rootRowBottom)).frame(width: 0, height: 0))
            #endif
            .background(InteractivePopEnabler())
            // The stack's path is watched by whoever owns it (ChatsSplitPage for the model's
            // stack, this view for its own) and reported through `chatsPathOpen`: reading the
            // path here made every path change re-run the whole list.
            .onChange(of: model.chatsPathOpen, initial: true) { was, open in
                // Collapsed to one column, the list is back in front with nothing open beside it.
                if !open { selectedID = nil }
                // A chat composed from another tab closes back onto that tab, not onto this list.
                if was, !open { returnFromCompose() }
            }
            .modifier(OwnPathWatch(path: inModelStack || detailPath != nil ? nil : $ownPath))
            .onChange(of: model.popToRoot[.chats]) { _, _ in path.wrappedValue = NavigationPath() }
            // A tap on the Chats tab while it is selected also brings the list back to the top.
            .onChange(of: model.tabReselected[.chats]) { _, _ in scrollToTop += 1 }
            .toolbar {
                if selecting {
                    // Select mode outlives a page switch now that the Mac keeps this page mounted;
                    // its Done and actions stand in the bar only while the page is on show. Under
                    // the morph bar they are the bar's own (`AppModel.chatsSelect`): here they sat
                    // under its capsules, out of reach (#408).
                    if pageShown, !MorphTopBar.active(model) {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { endSelecting() }.accessibilityIdentifier("chats.select.done") }
                    ToolbarItemGroup(placement: .topBarTrailing) { selectionActions }
                    }
                } else {
                #if os(macOS)
                // Only while the Chats page is the one on show: the Mac keeps this page mounted
                // behind the other pages, and its items must not stand in their toolbar.
                if pageShown {
                ToolbarItem(placement: .topBarLeading) { profileMenu }
                // Two buttons, the same size, that fit over the list at its narrowest: a button
                // each for refresh, new bot, sort and filters ran past the column's edge and sat
                // over the chat beside it, and moved about as the window was resized.
                ToolbarItem(placement: .primaryAction) { viewMenu }
                ToolbarItem(placement: .primaryAction) { voiceMenu }
                ToolbarItem(placement: .primaryAction) { composeMenu }
                }
                #else
                ToolbarItem(placement: .topBarLeading) { if !MorphTopBar.active(model) { profileMenu } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !MorphTopBar.active(model) {
                    if !model.isInDemo { Button { showNewBot = true } label: { Image(systemName: "plus") }.accessibilityLabel("New bot") }
                    // One View menu (sort + filters) wherever the list is a split view's column
                    // or shares a strip with the system's items: three buttons beside the title
                    // truncated "Chats" in a 380 pt column, and worse in the open Duo's portrait.
                    if model.tabBarVertical || model.wideLayout {
                        // The system lays these items down the same strip Vory's tab bar stands in
                        // (the closed Duo), or beside a narrow column on the open one: sort and
                        // filters share one View menu there, so the strip and the title keep room.
                        Menu { sortMenu; filterMenu } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                            .simultaneousGesture(TapGesture().onEnded { Smooth.animate("viewMenu") })
                            .accessibilityLabel("View")
                            .accessibilityIdentifier("chats.view")
                    } else {
                        sortMenu
                        filterMenu
                    }
                    }
                }
                #endif
                }
            }
            // Compose: one tap is a fresh chat with the current bot, straight in (a tester:
            // "I shouldn't have to name it or choose appearance"); a long press is the
            // Messages-style sheet (To: bots, project, first message, files).
            .onChange(of: model.newChatRequest) { _, r in if r != nil { openFreshChat() } }
            // The list's own actions asked for from outside (the morph prototype's bar, the
            // shared menu items).
            .onChange(of: model.chatListRequest) { _, r in
                guard let r else { return }
                model.chatListRequest = nil
                switch r.kind {
                // No New bot in the demo (#494): its look editor wrote the person's own bot's look.
                case .newBot: showNewBot = !model.isInDemo
                case .manageProjects: showProjects = true
                case .selectChats: withAnimation(selectMotion) { selecting = true }
                // Select's controls in the morph bar (#408).
                case .selectDone: endSelecting()
                case .selectMove: movingSelection = true
                case .selectArchive: let list = picked; endSelecting(); Task { await archive(list) }
                case .selectDelete: pendingDeleteMany = true
                }
            }
            .onChange(of: model.newChatSheetRequest) { _, r in
                guard r != nil, model.selectedTab == .chats, runtime != nil else { returnFromCompose(); return }
                sheetStarted = false
                showNewChat = true
            }
            // The mic circle beside it: a fresh chat, straight into voice mode (#237).
            .onChange(of: model.voiceChatRequest?.id) { _, id in if id != nil, let r = model.voiceChatRequest { openVoiceChat(r) } }
            .sheet(isPresented: $showNewBot) { if let runtime { NewBotSheet(runtime: runtime).sheetFrame().withAppModel() } }
            .sheet(isPresented: $showProjects) { NavigationStack { ProjectsView(inSheet: true).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showProjects = false } } } }.sheetFrame().withAppModel() }
            .sheet(isPresented: $movingSelection) {
                if let runtime {
                    MoveToProjectSheet(sessions: picked, runtime: runtime) { endSelecting() }.sheetFrame(.compact).withAppModel()
                }
            }
            // Cancelled from another tab's compose circle: straight back to that tab.
            .sheet(isPresented: $showNewChat, onDismiss: { if !sheetStarted { returnFromCompose() } }) {
                if let runtime {
                    NewChatSheet(runtime: runtime, initialProjectID: prefs.projectFilter.isEmpty || prefs.projectFilter == "__none__" ? runtime.projects.activeID : prefs.projectFilter) { start in
                        sheetStarted = true
                        let back = model.composeReturnTab
                        switch start {
                        case .chat(let profile, let text, let attachments, let cwd, let voice, let model, let reasoning):
                            open(ChatRoute(storedID: nil, title: nil, profile: profile, initialText: text, initialAttachments: attachments, cwd: cwd, startVoice: voice,
                                           initialModel: model, initialReasoning: reasoning), returningTo: back)
                        case .group(let room, let text): rooms.insert(room, at: 0); open(RoomRoute(room: room, initialText: text), returningTo: back)
                        }
                    }
                    .sheetFrame()
                    .withAppModel()
                }
            }
            .onChange(of: searchText) { _, q in Task { await search(q) } }
            #if os(macOS)
            .refreshable { await refresh() }
            // Chat › Refresh Chats (⌘R).
            .onReceive(NotificationCenter.default.publisher(for: .refreshChats)) { _ in Task { await refresh() } }
            #else
            // Vory's own pull-to-refresh, the wheel beside the title (PageChrome.swift): the
            // system's pull spinner drew inside the search drawer (Matt, 2026-10-10).
            .pullRefresh(ownWheel: true) { await refresh() }
            // The list's pull state, for the morph bar's title capsule to host the wheel (the
            // other roots publish theirs from TabRoot; the Chats page has no TabRoot).
            .onPreferenceChange(PullRefreshKey.self) { r in Task { @MainActor in model.pullStates[.chats] = r.state } }
            #endif
            .task(id: runtime?.connection.id) { await load() }
            .task(id: runtime?.selectedProfile) { await load() }
            // All bots, and Archived shown or hidden: the list asks for archived chats only while they're shown
            // (`listQuery`). One task for both: another modifier put this chain past the type checker.
            .task(id: "\(prefs.allBots)-\(prefs.showArchived)") { await load() }
            // The bots arriving (an empty list too) or changing, a rename included: All bots lists
            // each one's chats.
            .onChange(of: loadedBotNames) { _, _ in Task { await load() } }
            // The socket coming up is when the gateway becomes reachable; do not wait for a pull.
            .onChange(of: runtime?.socketState) { _, s in if case .open? = s { Task { await load() } } }
            .onReceive(NotificationCenter.default.publisher(for: .hermesSessionsChanged)) { _ in Task { await load() } }
            .onChange(of: model.pendingRoute) { _, r in
                // A route is pushed once while it waits; once a chat has taken it (back to nil) it is forgotten, so the
                // same one again opens its chat again: the same "Messaged X" notice after Back did nothing (#448).
                guard let r else { lastRouted = nil; return }
                guard r != lastRouted else { return }
                lastRouted = r
                // Already looking at that chat: nothing to push (a second copy of the same chat
                // used to land on top, and a confirmation asked there could go to the covered one).
                guard model.visibleChatID != r.storedSessionID else { return }
                open(ChatRoute(storedID: r.storedSessionID, title: r.title ?? (r.kind == "readonly" ? "Bot Chat" : nil), profile: r.profile, readOnly: r.kind == "readonly"),
                     returningTo: r.returnTab)
            }
            .alert("Delete group chat?", isPresented: Binding(get: { pendingRoomDelete != nil }, set: { if !$0 { pendingRoomDelete = nil } })) {
                Button("Delete", role: .destructive) { if let r = pendingRoomDelete { Task { await deleteRoom(r) } } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This disbands the group on the gateway. Its messages stay in the gateway's log.") }
            .alert(selection.count == 1 ? "Delete 1 chat?" : "Delete \(selection.count) chats?", isPresented: $pendingDeleteMany) {
                Button("Delete", role: .destructive) { let list = picked; endSelecting(); Task { await delete(list) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes the sessions and their transcripts from the gateway.") }
            // A modifier of its own: one more alert inline put this chain past the type checker.
            .modifier(ActionFailureAlert(failure: $actionFailure))
            // Select mode's state for the morph bar (#408), a modifier of its own for the same reason.
            .modifier(ChatsSelectPublisher(state: selectBarState))
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
        if !prefs.projectFilter.isEmpty, prefs.projectFilter != "__none__" { cwd = runtime.projects.project(id: prefs.projectFilter)?.startPath }
        open(ChatRoute(storedID: nil, title: nil, profile: profile, cwd: cwd), returningTo: model.composeReturnTab)
    }

    /// A fresh chat with the bot asked for (else the selected one), in the filter's project,
    /// and voice mode as soon as it exists; ending voice mode leaves the person in the chat.
    private func openVoiceChat(_ request: AppModel.VoiceChatRequest) {
        guard model.selectedTab == .chats, let runtime else { returnFromCompose(); return }
        var cwd: String? = nil
        if !prefs.projectFilter.isEmpty, prefs.projectFilter != "__none__" { cwd = runtime.projects.project(id: prefs.projectFilter)?.startPath }
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

    /// The list's title; while the Mac keeps this page mounted behind another page, that page's
    /// (the deepest title wins the window's, and this one read "Chats" over Settings).
    private var windowTitle: String {
        if !pageShown { return model.selectedTab.title }
        if selecting { return selection.isEmpty ? "Select Chats" : "\(selection.count) Selected" }
        return "Chats"
    }

    private var profileMenu: some View {
        Menu {
            ChatListProfileItems()
        } label: {
            // A fixed-size avatar: a text label changed width with each profile name and the bar
            // visibly jumped as it re-laid out.
            // A rendered, untinted image: live glass went murky on the toolbar's glass and a
            // painted view picked up the toolbar's tint in light mode.
            // Memoised: drawn afresh on every pass it flashed while the bar re-laid out (a pull).
            BarFaceCircle(profile: model.listChipProfile ?? "?", size: 26, scheme: colorScheme)
                .accessibilityLabel("Profile: \(model.listChipProfile ?? "none")")
        }
        .id("\(prefs.botColorsRaw)|\(prefs.botAvatarsRaw)|\(prefs.glassAll)|\(colorScheme == .light)")
    }

    /// Sort on its own button: inside the filter menu it sat under every project, a long
    /// scroll away once there were many.
    private var sortItems: some View { ChatListSortItems() }

    #if os(macOS)
    /// Refresh, sort, filters and Select in one menu.
    private var viewMenu: some View {
        Menu {
            Button { Task { await refresh() } } label: { MenuLabel("Refresh", systemImage: "arrow.clockwise") }
            Menu { sortItems.pickerStyle(.inline).labelsHidden() } label: { MenuLabel("Sort By", systemImage: "arrow.up.arrow.down") }
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
            Button { model.newChatRequest = UUID() } label: { MenuLabel("New Chat", systemImage: "square.and.pencil") }
            Button { model.newChatSheetRequest = UUID() } label: { MenuLabel("New Chat With…", systemImage: "person.2") }
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
                Button { model.voiceChatRequest = .init(profile: p.name) } label: { MenuLabel(p.label, systemImage: "person.fill") }
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
            Image(systemName: prefs.sortKey == "recent" ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle.fill")
                .accessibilityLabel("Sort: \(prefs.sortKey)")
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
        .simultaneousGesture(TapGesture().onEnded { Smooth.animate("viewMenu") })
        .accessibilityIdentifier("chats.filters")
    }

    private var filterItems: some View { ChatListFilterItems() }

    /// The filters and the sort applied to the loaded (or searched) sessions.
    private func filtered(_ list: [StoredSession], runtime: GatewayRuntime) -> [StoredSession] {
        var out = list
        if prefs.pinnedOnly { out = out.filter { $0.pinned == true } }
        if prefs.needsYouOnly { out = out.filter { runtime.needsAttention.contains($0.id) } }
        if prefs.liveOnly { out = out.filter { runtime.chatForStored($0.id)?.isRunning ?? false } }
        if !prefs.showArchived { out = out.filter { $0.archived != true } }
        if !prefs.projectFilter.isEmpty {
            let m = runtime.projects.membership
            out = out.filter { prefs.projectFilter == "__none__" ? m[$0.id] == nil : m[$0.id] == prefs.projectFilter }
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
            switch prefs.sortKey {
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
        case .unreachable: return "exclamationmark.triangle.fill"
        case .idle: return "circle"
        }
    }

    #if os(macOS)
    /// The Mac's search field, pinned over the list (the window toolbar put it at the far end,
    /// over the open chat). The phone uses the native `.searchable` drawer instead.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search chats", text: $searchText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { searchText = ""; searchFocused = false }
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    // A 28 pt target around the 13 pt glyph; the negative padding keeps its place
                    // and the field's width as they were.
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(.rect)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
                .padding(.horizontal, -7.5).padding(.vertical, -6)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: .capsule)
        // The whole capsule is the field: a click beside the 16 pt line of text (the glass, the
        // padding) went nowhere. The text field and the clear button keep their own clicks.
        .contentShape(.capsule)
        .onTapGesture { searchFocused = true }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 6)
    }
    #endif

    @ViewBuilder private func list(_ runtime: GatewayRuntime) -> some View {
        let rows = filtered(searchText.isEmpty ? sessions : searchResults, runtime: runtime)
        #if DEBUG
        let _ = Perf.tick("chatlist-body")
        #endif
        ScrollViewReader { proxy in
        List {
            // Not signed in on this device: the banner above says so and has the button; the
            // gateway's own "session expired" line under it would only repeat it in red.
            if let errorText, model.needsSignIn == nil { Text(errorText).foregroundStyle(.red).font(.footnote) }
            // Which project the list is narrowed to, since the rows' own chips are hidden then.
            if !prefs.projectFilter.isEmpty {
                HStack(spacing: 8) {
                    if let p = runtime.projects.project(id: prefs.projectFilter) { ProjectIcon(project: p, size: 22); Text(p.name).font(.subheadline.weight(.medium)) }
                    else { Image(systemName: "folder.badge.questionmark").foregroundStyle(.secondary); Text("Chats in no project").font(.subheadline.weight(.medium)) }
                    Spacer()
                    Button("Show all") { withAnimation { prefs.projectFilter = "" } }.font(.subheadline).buttonStyle(.borderless)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 6, trailing: 16))
            }
            // With the "Group chats" filter on, rooms sit among the chats by recency, as chats.
            let visibleRooms = prefs.groupsOnly
                ? rooms.filter { (prefs.showArchived || !archivedRooms.contains($0.roomId)) && (searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)) }
                : []
            if grouped(runtime) {
                groupedRows(rows, rooms: visibleRooms, runtime: runtime)
            } else {
                let entries = Self.merge(rows, visibleRooms, sort: prefs.sortKey)
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
        #endif
        // Wider rows: the card hugs the screen edges and the rows their card.
        .contentMargins(.horizontal, ChatRowStyle.cardInset, for: .scrollContent)
        #if os(iOS)
        // The tab bar's room at the list's end, its own and constant (it replaces the root's): the
        // root's drops to 0 while a chat is up, and a list scrolled to its end had its offset
        // clamped to the shorter content then, so after Back it sat that much lower, 59 pt, its
        // last row under the bar (Matt on 1.5 (11): the list "drops" after a swipe back).
        .contentMargins(.bottom, model.tabBarVertical ? 0 : VoryTabBar.reservedHeight(in: windowGeometry) + 16, for: .scrollContent)
        #endif
        #if os(macOS)
        // The list runs a little way under the column's edge, which cut the scroll bar in half
        // down its length; the bar is brought back inside the column.
        .contentMargins(.trailing, 8, for: .scrollIndicators)
        #endif
        .overlay { if loading && sessions.isEmpty { ProgressView() } }
        // Idle faces hold their blinks while the list moves (one write per phase change).
        .onScrollPhaseChange { _, phase in BotAmbient.shared.scrolling = phase != .idle }
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
        .overlay(alignment: .bottom) { SummaryStripAboveBar() }
        #endif
        // A bar, not a plain inset: the rows fade out under it the way they do under the
        // toolbar, instead of showing through behind the search field. On the phone too (Matt):
        // the system's search drawer sat exactly where the pull-to-refresh spinner draws, so
        // the spinner turned inside the field; our field is pinned above the list and the
        // spinner turns below it.
        .vorySafeAreaTopBar(spacing: 0) { topBars(runtime) }
        .animation(.snappy, value: runtime.restartRequired == nil)
        .animation(.snappy, value: model.needsSignIn == nil)
        .onChange(of: scrollToTop) { _, _ in
            let first = Self.merge(rows, prefs.groupsOnly ? rooms : [], sort: prefs.sortKey).first?.id ?? rows.first?.id
            if let first { withAnimation(.snappy) { proxy.scrollTo(first, anchor: .top) } }
        }
        }
    }

    /// What sits over the list: the search field on the Mac (the phone uses the native search
    /// drawer), then whatever needs saying.
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

    private var collapsed: Set<String> { ChatProjectGroups.collapsed(prefs.collapsedRaw) }

    /// Projects on top, each opening to its chats: when the switch is on, the gateway has
    /// projects, and the list is not already narrowed to one or showing search results.
    private func grouped(_ runtime: GatewayRuntime) -> Bool {
        prefs.byProject && runtime.projects.available == true && prefs.projectFilter.isEmpty && searchText.isEmpty
    }

    private func groups(_ rows: [StoredSession], runtime: GatewayRuntime) -> [ChatProjectGroup] {
        let store = runtime.projects
        return ChatProjectGroups.make(rows, own: store.projects, membership: store.membership, selected: runtime.selectedProfile,
                                      others: prefs.allBots ? store.others : [:], keepEmpty: !filtering)
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
                    ForEach(visible, id: \.listRowID) { s in sessionRow(s, runtime: runtime, showProject: false) }
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
                                     showBot: prefs.allBots,
                                     onToggle: { withAnimation(.snappy) { prefs.collapsedRaw = ChatProjectGroups.toggled(prefs.collapsedRaw, g.id) } },
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

    private func endSelecting() { withAnimation(selectMotion) { selecting = false; selection = [] } }

    /// Select mode on and off. Not animated where the pages had the cut (#372): a row is a
    /// different view while selecting (`rowLink`), so animated it cross-fades, its words doubled
    /// for a moment, rather than sliding over for the circle. As 24 until the row is reworked to
    /// slide. A wide window's list (iPad) keeps its step: it sits in a split view's column, in
    /// UIKit's hosting like a pushed chat, which the cut did not reach (likely the same for the
    /// column; not recorded). The Mac never had the cut.
    private var selectMotion: Animation? { MorphTopBar.cutsPages && !model.wideLayout ? nil : .snappy }

    /// What the morph bar shows while selecting (#408): nil when not selecting, the page is not on
    /// show, or the bar is not over the list (a wide window, the Mac: the toolbar has them).
    private var selectBarState: AppModel.ChatsSelect? {
        guard selecting, pageShown, MorphTopBar.active(model) else { return nil }
        return AppModel.ChatsSelect(title: selection.isEmpty ? "Select Chats" : "\(selection.count) Selected",
                                    canAct: !selection.isEmpty,
                                    canMove: runtime?.projects.available == true && runtime?.projects.canMove == true)
    }

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
        var failed: [(StoredSession, Error)] = []
        for s in list where s.archived != true {
            var body: [String: JSONValue] = ["archived": .bool(true)]
            if s.pinned == true { body["pinned"] = .bool(false) }
            do { try await SessionMutation.patch(runtime.api, id: s.id, profile: s.profile ?? runtime.selectedProfile, fields: body) }
            catch { failed.append((s, error)) }
        }
        // One alert for the batch, not one per chat (and not a red line the reload below clears).
        if let (first, error) = failed.first {
            actionFailure = ActionFailure(title: failed.count == 1 ? "Could not archive \u{201C}\(first.displayTitle)\u{201D}" : "Could not archive \(failed.count) chats",
                                          message: PinSupport.reason(error))
        }
        // The chats archived marked so in the list before it's read again, as a row's own Archive does (`patch`): the
        // gateway may leave them out of its list now (#474), and the list keeps a left-out chat's flags as they were.
        let done = Set(list.filter { s in s.archived != true && !failed.contains { $0.0.id == s.id } }.map(\.id))
        withAnimation(.snappy) {
            for i in sessions.indices where done.contains(sessions[i].id) { sessions[i].archived = true; sessions[i].pinned = false }
        }
        await load()
    }

    private func delete(_ list: [StoredSession]) async {
        guard let runtime else { return }
        var failed: [(StoredSession, Error)] = []
        for s in list {
            droppedIDs.insert(s.id)
            if let chat = runtime.chatForStored(s.id) { runtime.closeChat(chat) }
            // A refusal is said, and the chat stays: swallowed, it came back with the next list as if deleted and
            // undeleted by itself (#467, a newer Hermes refusing every delete without its revision).
            do { try await SessionMutation.delete(runtime.api, id: s.id, profile: s.profile ?? runtime.selectedProfile) }
            catch { failed.append((s, error)); droppedIDs.remove(s.id) }
        }
        sessions.removeAll { s in list.contains { l in l.id == s.id } && !failed.contains { $0.0.id == s.id } }
        if let (first, error) = failed.first {
            actionFailure = ActionFailure(title: failed.count == 1 ? "Could not delete \u{201C}\(first.displayTitle)\u{201D}" : "Could not delete \(failed.count) chats",
                                          message: PinSupport.reason(error))
        }
        await load()
    }

    /// A pull, or Refresh on the Mac. When the gateway has not answered for its bots yet (the
    /// first answer failed and the socket stayed up, so no reconnect asks again), ask for them
    /// first: with All bots the list cannot load without them. Only here, not in `load()`,
    /// which every trigger calls.
    private func refresh() async {
        if let runtime, !runtime.profilesLoaded { await runtime.loadProfiles() }
        await load()
    }

    /// The gateway's bot names once it has answered for them, nil before: the list's reload
    /// trigger when they arrive or change.
    private var loadedBotNames: [String]? {
        guard let runtime, runtime.profilesLoaded else { return nil }
        return runtime.profiles.map(\.name)
    }

    /// Whether the gateway can be asked for the list: with All bots, only once the gateway has
    /// answered for its bots (an empty answer counts: such a gateway lists no chats).
    static func canList(allBots: Bool, botsLoaded: Bool) -> Bool { !allBots || botsLoaded }

    /// The list's request: the most recent chats, a page of `limit`, with archived chats asked for only while the
    /// Archived filter shows them (#474). A Hermes that leaves them out unless asked (`archived=exclude`, its default
    /// since 1eda335a) sent none, so turning Archived on showed nothing; and with them hidden, they aren't asked for, so
    /// the page's rows aren't spent on chats nobody sees. An older Hermes ignores the parameter and lists every chat;
    /// the filter on the device (`filtered`) still hides the archived ones there.
    nonisolated static func listQuery(limit: Int, showArchived: Bool) -> [URLQueryItem] {
        [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: String(limit)),
         URLQueryItem(name: "archived", value: showArchived ? "include" : "exclude")]
    }

    private func load(attempt: Int = 0) async {
        guard let runtime else { return }
        let cacheProfile = prefs.allBots ? "*" : runtime.selectedProfile
        if sessions.isEmpty {
            sessions = SessionCache.load(connection: runtime.connection.id, profile: cacheProfile)
            // A cold launch before the bot is known: any list for this gateway beats a blank page.
            if sessions.isEmpty { sessions = SessionCache.loadAny(connection: runtime.connection.id) }
        }
        // All bots before the bots are known (a cold launch: every trigger, the socket's opening
        // included, can come before /api/profiles answers): nothing to ask for yet, and the empty
        // answer wiped the list until another page loaded it again (Matt on 1.5 (20)). The list
        // loads once the bots arrive (the `profiles` trigger above).
        guard Self.canList(allBots: prefs.allBots, botsLoaded: runtime.profilesLoaded) else { return }
        loading = sessions.isEmpty; defer { loading = false }
        Task {
            await runtime.projects.refresh()
            // Projects are per bot: with every bot's chats listed, each bot's are read too.
            if prefs.allBots { await runtime.projects.refreshOthers(runtime.profiles.map(\.name)) }
        }
        do {
            var all: [StoredSession] = []
            if prefs.allBots {
                let profiles = runtime.profiles.map(\.name)
                let showArchived = prefs.showArchived
                // Each bot's rows in the bots' own order, whichever answered first: a chat the
                // gateway lists under several bots kept whichever listing arrived first, so its
                // bot and avatar flipped between loads (Matt, 2026-10-12: "the bots and chats
                // glitch out").
                var byProfile: [String: [StoredSession]] = [:]
                try await withThrowingTaskGroup(of: (String, [StoredSession]).self) { group in
                    for p in profiles {
                        group.addTask {
                            let r: SessionListResponse = try await runtime.api.get("/api/sessions", query: Self.listQuery(limit: 50, showArchived: showArchived), profile: p)
                            return (p, r.sessions.map { var s = $0; if s.profile == nil || s.profile!.isEmpty { s.profile = p }; return s })
                        }
                    }
                    for try await (p, part) in group { byProfile[p] = part }
                }
                for p in profiles { all += byProfile[p] ?? [] }
                // One row per chat: a gateway whose bots share a store (and the mock) lists the
                // same chat under every bot, and All bots showed each one twice.
                var seen = Set<String>()
                all = all.filter { seen.insert($0.id).inserted }
            } else {
                // Each row carries the bot it was listed for: opening it later must not depend
                // on which bot is selected by then.
                let listed = runtime.selectedProfile
                let r: SessionListResponse = try await runtime.api.get("/api/sessions", query: Self.listQuery(limit: 100, showArchived: prefs.showArchived), profile: listed)
                all = r.sessions.map { var s = $0; if s.profile == nil || s.profile!.isEmpty { s.profile = listed }; return s }
            }
            pinsKept = PinSupport.kept(rows: all, connection: runtime.connection.id)
            // Chats open in the app that the gateway does not list yet: a new chat gets its
            // stored row on the first prompt and the row fills in as the turn flushes, so a chat
            // started moments ago (or one still running) could vanish from the list on the way
            // back from it. They stay listed from the live session until the gateway has them.
            let listed = Set(all.map(\.id))
            // No local "keep" of pinned rows the gateway left out: the gateway lists every
            // pinned chat itself, so the only rows such a keep held were stale ones (a chat
            // compressed onto a new id, one deleted elsewhere), and those could never be
            // unpinned or archived again (the row was the app's own copy).
            // Such a row keeps the pin and archive the list last had for it: a Hermes that lists archived chats only
            // when asked (#474) leaves out a chat archived here on purpose, and added as unarchived it came straight
            // back, unarchived, while Archived was hidden. Kept archived, the filter decides.
            let before = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let now = Date().timeIntervalSince1970
            for chat in runtime.chats where !listed.contains(chat.storedID) && !chat.storedID.isEmpty
                && (chat.isRunning || !chat.items.isEmpty)
                && (prefs.allBots || chat.profileName == (runtime.selectedProfile ?? chat.profileName)) {
                let last = chat.items.last?.timestamp.timeIntervalSince1970 ?? now
                all.append(StoredSession(id: chat.storedID, title: chat.title == "New chat" ? nil : chat.title,
                                         preview: chat.items.first.flatMap { if case .user(let t, _) = $0.kind { return t }; return nil },
                                         source: "ios", model: chat.modelName.isEmpty ? nil : chat.modelName,
                                         startedAt: chat.items.first?.timestamp.timeIntervalSince1970 ?? now, lastActive: max(last, now - 1),
                                         messageCount: chat.items.count, isActive: chat.isRunning,
                                         archived: before[chat.storedID]?.archived ?? false, pinned: before[chat.storedID]?.pinned ?? false,
                                         profile: chat.profileName))
            }
            // A chat keeps its place until it has new messages: the gateway counts an attach as
            // activity, so the chat just read floated to the top on the way back and every row
            // shifted (Matt, 2026-10-12: "the chats list jumps ... we want it to remain the same
            // when going into a chat and out of"). Its old time stays until something was said.
            all = all.map { s in
                guard let p = before[s.id], p.messageCount == s.messageCount, let was = p.lastActive, (s.lastActive ?? 0) > was else { return s }
                var kept = s; kept.lastActive = was; return kept
            }
            // A row's move under way plays out first; a row still waiting for its swipe or menu to
            // close keeps its pin and archive as they were until it moves (#372).
            let moving = movingUntil.timeIntervalSinceNow
            if moving > 0 { try? await Task.sleep(for: .seconds(moving)) }
            let held = heldRows
            if !held.isEmpty {
                all = all.map { s in
                    guard let h = held[s.id] else { return s }
                    var t = s; t.pinned = h.pinned; t.archived = h.archived; return t
                }
            }
            // Placed without animation: rows whose words changed cross-faded over themselves.
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) {
                sessions = all.sorted { ($0.pinned ?? false ? 1 : 0, $0.lastActive ?? 0) > ($1.pinned ?? false ? 1 : 0, $1.lastActive ?? 0) }
            }
            // What Siri can name without the app on screen: the bots and the recent chats' titles (#310); and the list
            // for the next launch. Neither for the demo (#392): its bots and chats stay out of Siri, Spotlight and the cache.
            if !runtime.isEphemeral {
                SiriCatalog.rememberBots(runtime.profiles)
                SiriCatalog.rememberChats(sessions)
                SessionCache.save(sessions, connection: runtime.connection.id, profile: cacheProfile)
            }
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
        var id: String { switch self { case .session(let s): return s.listRowID; case .room(let r): return "room:" + r.roomId } }
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
    /// `pick`: the chat's id, for a row that can be chosen while selecting. `face`: the bot and
    /// chat of the face the row shows, which reacts to the tap where the row stays on screen.
    @ViewBuilder private func rowLink<Label: View>(_ route: some Hashable, selected: Bool = false, pick: String? = nil, face: RowFace? = nil, @ViewBuilder label: () -> Label) -> some View {
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
            openLink(route, selected: selected, face: face, label: label)
        }
    }

    /// The face a row shows: its bot and its chat.
    struct RowFace { let profile: String; let session: String }

    @ViewBuilder private func openLink<Label: View>(_ route: some Hashable, selected: Bool, face: RowFace? = nil, @ViewBuilder label: () -> Label) -> some View {
        if detailPath != nil {
            // Beside a detail column (the Mac, the iPad, the open Duo, and the same split view
            // collapsed on a phone): the row selects into the detail path (`open`), never a
            // NavigationLink, which would push onto the list's own stack instead.
            // The row stays beside the chat it opens, so its face reacts to the tap. On the phone
            // the chat covers the list at once: the link alone, with no gesture over its row.
            Button {
                if let face { BotAmbient.shared.tap(profile: face.profile, session: face.session) }
                open(route)
            } label: { label().contentShape(.rect) }.buttonStyle(.plain)
                // The open chat's row, tinted like the selected conversation in Messages. Drawn
                // here: the Mac's list did not show a listRowBackground on these rows.
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.16))
                            .padding(.horizontal, -8).padding(.vertical, -7)
                    }
                }
        } else {
            NavigationLink(value: route) { label() }
        }
    }

    /// The bot beside each chat: with All bots on the phone, always on the Mac (the list reads
    /// like a list of conversations with someone).
    private var rowsShowBot: Bool {
        #if os(macOS)
        true
        #else
        prefs.allBots
        #endif
    }

    @ViewBuilder private func sessionRow(_ s: StoredSession, runtime: GatewayRuntime, showProject: Bool = true) -> some View {
        let route = ChatRoute(storedID: s.id, title: s.displayTitle, profile: s.profile)
                rowLink(route, selected: selectedID == s.id, pick: s.id, face: rowsShowBot ? RowFace(profile: s.profile ?? runtime.selectedProfile ?? "", session: s.id) : nil) {
                    SessionRow(session: s, needsYou: runtime.needsAttention.contains(s.id), live: runtime.chatForStored(s.id)?.isRunning ?? false, showBot: rowsShowBot,
                               botProfile: s.profile ?? runtime.selectedProfile,
                               thinking: runtime.chatForStored(s.id).map { $0.isRunning && ($0.statusLine ?? "Thinking…") == "Thinking…" } ?? false,
                               state: runtime.chatForStored(s.id)?.botState ?? .idle,
                               project: showProject && prefs.projectFilter.isEmpty ? runtime.projects.project(forSession: s.id) : nil,
                               step: runtime.needsAttention.contains(s.id) ? nil : runtime.chatForStored(s.id)?.statusLine,
                               summary: summarizer.shown(summarizer.summary(for: s), title: s.displayTitle, preview: s.preview ?? "", renamed: ChatSession.renamedByPerson(s.id)))
                        .task(id: "\(s.id)-\(s.lastActive ?? 0)-\(aiSummaries)") { if aiSummaries { summarizer.refresh(s, runtime: runtime, profile: prefs.allBots ? s.profile : nil) } }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: ChatRowStyle.rowInset, bottom: 10, trailing: 8))
                .accessibilityFocused($spokenRow, equals: s.id)
                #if os(macOS)
                // A firm press on the trackpad peeks the conversation, as the long press does on the phone.
                .onForceClick { peeking = s }
                .popover(isPresented: Binding(get: { peeking?.id == s.id }, set: { if !$0 { peeking = nil } })) {
                    SessionPreview(session: s, runtime: runtime, profile: prefs.allBots ? s.profile : nil).withAppModel()
                }
                #endif
                // In Select mode a long press or a swipe does nothing: the row's menu and swipes are
                // the list's, and opened while selecting they acted on the one row (a tester read the
                // selection as not taking, #408).
                .contextMenu {
                    if !selecting {
                    Button { open(route) } label: { Label("Open", systemImage: "bubble.left") }
                    if pinsKept {
                        Button { Task { await patch(s, ["pinned": .bool(!(s.pinned ?? false))], afterClose: true) } } label: { Label(s.pinned == true ? "Unpin" : "Pin", systemImage: s.pinned == true ? "pin.slash" : "pin") }
                    }
                    Button { Task { await patch(s, ["archived": .bool(!(s.archived ?? false))], afterClose: true) } } label: { Label(s.archived == true ? "Unarchive" : "Archive", systemImage: "archivebox") }
                    if runtime.projects.available == true, runtime.projects.canMove {
                        Menu {
                            ProjectMoveMenu(sessions: [s], runtime: runtime) { errorText = $0 }
                        } label: { Label("Move to Project", systemImage: "folder") }
                    }
                    Button { withAnimation(selectMotion) { selecting = true; selection = [s.id] } } label: { Label("Select", systemImage: "checkmark.circle") }
                    Divider()
                    Button(role: .destructive) { pendingDelete = s } label: { Label("Delete", systemImage: "trash") }
                    }
                } preview: {
                    SessionPreview(session: s, runtime: runtime, profile: prefs.allBots ? s.profile : nil).withAppModel()
                }
                // Delete alone on the trailing edge; Archive lives with Pin on the leading edge so
                // the two are never a thumb-width apart.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !selecting { Button(role: .destructive) { pendingDelete = s } label: { Label("Delete", systemImage: "trash") } }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    // No Pin where the gateway does not keep pins: it went back as soon as it was made (#406).
                    if !selecting, pinsKept {
                        Button { Task { await patch(s, ["pinned": .bool(!(s.pinned ?? false))], afterClose: true) } } label: { Label(s.pinned == true ? "Unpin" : "Pin", systemImage: s.pinned == true ? "pin.slash" : "pin") }.tint(.yellow)
                    }
                    if !selecting {
                    Button { Task { await patch(s, ["archived": .bool(!(s.archived ?? false))], afterClose: true) } } label: { Label(s.archived == true ? "Unarchive" : "Archive", systemImage: "archivebox") }.tint(.orange)
                    }
                }
    }

    @ViewBuilder private func roomRow(_ room: Room, runtime: GatewayRuntime) -> some View {
        let archived = archivedRooms.contains(room.roomId)
        let log = roomLogs[room.roomId] ?? []
        let summary = summarizer.shown(summarizer.summary(forRoom: room, events: log), title: room.name, preview: Self.lastLine(room, log) ?? "")
                rowLink(RoomRoute(room: room, initialText: nil), selected: selectedID == ChatNavigation.selectionID(ofRoom: room.roomId)) {
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
                    if !selecting {
                    Button { open(RoomRoute(room: room, initialText: nil)) } label: { Label("Open", systemImage: "bubble.left") }
                    Button { setArchived(room, !archived) } label: { Label(archived ? "Unarchive" : "Archive", systemImage: "archivebox") }
                    Divider()
                    Button(role: .destructive) { pendingRoomDelete = room } label: { Label("Delete", systemImage: "trash") }
                    }
                } preview: {
                    RoomPreview(room: room, runtime: runtime).withAppModel()
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !selecting { Button(role: .destructive) { pendingRoomDelete = room } label: { Label("Delete", systemImage: "trash") } }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if !selecting { Button { setArchived(room, !archived) } label: { Label(archived ? "Unarchive" : "Archive", systemImage: "archivebox") }.tint(.orange) }
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
        prefs.archivedRoomsRaw = set.sorted().joined(separator: ",")
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
        // The chat's own bot, not the selected one: with All bots on, rows come from every profile. A refusal is said
        // and the chat comes back at once, not silently with the next list (#467).
        do { try await SessionMutation.delete(runtime.api, id: s.id, profile: s.profile ?? runtime.selectedProfile) }
        catch {
            droppedIDs.remove(s.id)
            actionFailure = ActionFailure(title: "Could not delete \u{201C}\(s.displayTitle)\u{201D}", message: PinSupport.reason(error))
        }
        await load()
    }

    /// `afterClose`: from a row's swipe action or its menu, which close as the button is tapped.
    /// The gateway is told at once; the row moves (a pin, an unpin) or goes (an archive) once the
    /// swipe or the menu's preview has closed, in one animated step (`closeBeforeMove`).
    private func patch(_ s: StoredSession, _ fields: [String: JSONValue], afterClose: Bool = false) async {
        guard let runtime else { return }
        var body = fields
        // Archiving a pinned chat unpins it too: the gateway lists every pinned chat, archived
        // or not, so an archived pin would stay at the top as if nothing happened.
        if case .bool(true)? = body["archived"], s.pinned == true { body["pinned"] = .bool(false) }
        let was = (pinned: s.pinned, archived: s.archived)
        var pinned: Bool?, archived: Bool?
        if case .bool(let v)? = body["pinned"] { pinned = v }
        if case .bool(let v)? = body["archived"] { archived = v }
        if afterClose { heldRows[s.id] = was }
        // Fenced on a newer Hermes (#467): the chat's revision with the edit.
        async let sent: Void = SessionMutation.patch(runtime.api, id: s.id, profile: s.profile ?? runtime.selectedProfile, fields: body)
        if afterClose { try? await Task.sleep(for: Self.closeBeforeMove) }
        // Shown now, by the row's id (a reload in the wait may have reordered the list); the
        // gateway's answer decides whether it stays that way.
        heldRows[s.id] = nil
        movingUntil = Date().addingTimeInterval(Self.moveLength)
        withAnimation(.snappy) {
            if let i = sessions.firstIndex(where: { $0.id == s.id }) {
                if let pinned { sessions[i].pinned = pinned }
                if let archived { sessions[i].archived = archived }
            }
        }
        // A pin moves the chat to a new row: VoiceOver goes with it once it has arrived, instead of
        // wherever the system puts focus when the row it was on leaves (nothing without VoiceOver).
        if pinned != nil, archived == nil {
            Task { try? await Task.sleep(for: .seconds(Self.moveLength)); spokenRow = s.id }
        }
        do {
            _ = try await sent
        } catch HermesAPIError.http(let status, _) where status == 404 {
            // The gateway no longer has this id (compressed onto a new one, deleted elsewhere):
            // the row was stale, and the gateway's list is the truth.
            withAnimation(.snappy) { sessions.removeAll { $0.id == s.id } }
            droppedIDs.insert(s.id)
        } catch {
            withAnimation(.snappy) {
                if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i].pinned = was.pinned; sessions[i].archived = was.archived }
            }
            if pinned != nil, archived == nil, PinSupport.isOldGatewayRefusal(error) {
                PinSupport.noteRefused(runtime.connection.id)
                pinsKept = false
                actionFailure = ActionFailure(title: "Pinning is not available", message: PinSupport.tooOld)
            } else {
                let title = archived != nil ? "Could not archive the chat" : pinned == false ? "Could not unpin the chat" : pinned != nil ? "Could not pin the chat" : "Could not update the chat"
                actionFailure = ActionFailure(title: title, message: PinSupport.reason(error))
            }
            return
        }
        await load()
    }
}

/// Whether a gateway keeps chats' pins (#406). Hermes from before it kept them (2026-07-24) sends
/// rows without "pinned" and refuses a pin as having nothing to update; Pin is not offered there,
/// as it went back as soon as it was made. Decided from the key, not its value: a row that says
/// false is a gateway that keeps pins. A refusal is remembered per connection, until the first
/// list of a later launch whose rows carry the key (the gateway's Hermes was updated).
@MainActor
enum PinSupport {
    static let tooOld = "This gateway\u{2019}s Hermes is too old to pin chats. Update Hermes to pin."
    private static let key = "vory.pins.refused"

    static func refused(_ connection: UUID) -> Bool { (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(connection.uuidString) }
    static func noteRefused(_ connection: UUID) {
        guard connection != GatewayConnection.demoID else { return }
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        ids.insert(connection.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
    private static func clear(_ connection: UUID) {
        guard refused(connection) else { return }
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != connection.uuidString }, forKey: key)
    }

    /// Connections listed since launch: the first list is a fresh connect.
    private static var listedThisLaunch: Set<UUID> = []

    /// From rows the gateway listed: kept when any carries "pinned" and no refusal stands; not
    /// when none does. An empty list says nothing, and what was remembered stands.
    static func kept(rows: [StoredSession], connection: UUID) -> Bool {
        let fresh = listedThisLaunch.insert(connection).inserted
        guard !rows.isEmpty else { return !refused(connection) }
        let carries = rows.contains { $0.pinned != nil }
        if carries, fresh { clear(connection) }
        return carries && !refused(connection)
    }

    /// An older Hermes's answer to a PATCH with nothing it knows (a pin alone).
    static func isOldGatewayRefusal(_ error: Error) -> Bool {
        if let e = error as? HermesAPIError, case .http(400, let detail) = e { return detail.localizedCaseInsensitiveContains("nothing to update") }
        return false
    }

    /// The gateway's reason in plain words, without the HTTP status: a fenced edit's refusal in Vory's own (#467).
    static func reason(_ error: Error) -> String {
        if let words = SessionMutation.message(for: error) { return words }
        if let e = error as? HermesAPIError, case .http(_, let detail) = e, !detail.isEmpty { return detail }
        return error.localizedDescription
    }
}

/// A change to a chat the gateway refused, for the list's alert.
struct ActionFailure: Equatable {
    var title: String
    var message: String
}

private struct ActionFailureAlert: ViewModifier {
    @Binding var failure: ActionFailure?
    func body(content: Content) -> some View {
        content.alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure?.message ?? "")
        }
    }
}

extension StoredSession {
    /// A chat's row identity in the list, which changes with its pin: List animates a move by
    /// sliding the row underneath the opaque rows it passes, so a pinned row vanished from its
    /// place, a blank slot opened at the top and the row popped into it, and an unpinned one flew
    /// up over the search field before landing (Matt on 1.5 (25): "a really weird animation").
    /// As one row leaving and another arriving, each place animates on its own: the row fades
    /// out where it was while the rows close up, and fades in where it goes as they open.
    var listRowID: String { (pinned == true ? "pinned:" : "") + id }
}

struct SessionRow: View {
    var session: StoredSession
    var needsYou: Bool
    var live: Bool
    var showBot = false
    /// Whose face to draw when the session itself does not say (the selected bot's list).
    var botProfile: String? = nil
    var thinking = false
    /// What the chat's bot is doing, as the header shows it (1.5): the row's face shows the same.
    var state: BotFace.State = .idle
    var project: Project? = nil
    /// The step the bot is on while it works ("Running terminal…"), shown when no goal line is written.
    var step: String? = nil
    /// The on-device summary, when Vory Summaries is on and one is ready for this chat.
    var summary: ChatSummarizer.Summary? = nil

    var body: some View {
        let _ = Perf.tick("list-row")
        HStack(spacing: 12) {
            // In the list: the eyes and the held pose (a squint, the pebble), no routines.
            if showBot { BotAvatar(profile: session.profile ?? botProfile ?? "?", size: 34, active: live, mood: BotFaceView.Mood(session: session.id, state: live ? state : .idle)) }
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
                messages = Array(cached.filter { ($0.role == "user" || $0.role == "assistant") && !($0.text ?? "").isEmpty }.suffix(6)); return
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
struct RoomRoute: Hashable, Codable {
    var room: Room
    var initialText: String?
}


/// The bar's title at the leading edge, after the leading items, instead of centred (iOS,
/// where the layout is not wide). The navigation title stays for accessibility and the back
/// label; only the bar's own drawing of it is removed.


#if os(iOS)
/// The summary strip, lifted above the tab bar: its own view, so the bar's hide and show (every
/// chat open and every Back) does not re-run the list's body and rebuild a hundred rows inside
/// the navigation transition (the 75 ms stalls on Back, 2026-10-11). iOS only: the bar is.
private struct SummaryStripAboveBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowGeometry) private var windowGeometry
    var body: some View {
        SummaryProgressStrip().padding(.bottom, model.tabBarHidden || model.tabBarVertical ? 0 : VoryTabBar.reservedHeight(in: windowGeometry) + 6)
    }
}
#endif


/// The list's own stack (a tab without the split page): its path drives `chatsPathOpen` here.
private struct OwnPathWatch: ViewModifier {
    @Environment(AppModel.self) private var model
    var path: Binding<NavigationPath>?
    func body(content: Content) -> some View {
        if let path {
            content.onChange(of: path.wrappedValue.isEmpty, initial: true) { _, empty in
                model.chatsPathOpen = !empty; model.tabAtRoot[.chats] = empty
            }
        } else {
            content
        }
    }
}

// MARK: The list's menu items, shared with the morph prototype's bar (MorphTopBar)

/// The sort choices.
struct ChatListSortItems: View {
    @Environment(AppModel.self) private var model
    private var prefs: ChatListPrefs { ChatListPrefs.shared }
    private var runtime: GatewayRuntime? { model.runtime }
    @ViewBuilder var body: some View {
        Picker("Sort by", selection: Bindable(prefs).sortKey) {
            MenuLabel("Recent", systemImage: "clock").tag("recent")
            MenuLabel("Title", systemImage: "textformat").tag("title")
            MenuLabel("Bot", systemImage: "person").tag("bot")
            MenuLabel("Model", systemImage: "cpu").tag("model")
        }
        }
}

/// The filters, the project switch and Select.
struct ChatListFilterItems: View {
    @Environment(AppModel.self) private var model
    private var prefs: ChatListPrefs { ChatListPrefs.shared }
    private var runtime: GatewayRuntime? { model.runtime }
    private var filtering: Bool { prefs.pinnedOnly || prefs.needsYouOnly || prefs.liveOnly || prefs.groupsOnly || !prefs.showArchived || !prefs.projectFilter.isEmpty }
    @ViewBuilder var body: some View {
            Section("Show") {
                Toggle(isOn: Bindable(prefs).pinnedOnly) { MenuLabel("Pinned only", systemImage: "pin") }
                Toggle(isOn: Bindable(prefs).needsYouOnly) { MenuLabel("Needs you", systemImage: "exclamationmark.bubble") }
                Toggle(isOn: Bindable(prefs).liveOnly) { MenuLabel("Working now", systemImage: "bolt") }
                Toggle(isOn: Bindable(prefs).showArchived) { MenuLabel("Archived", systemImage: "archivebox") }
                Toggle(isOn: Bindable(prefs).groupsOnly) { MenuLabel("Group chats", systemImage: "person.3") }
            }
            if let runtime, runtime.projects.available == true {
                Section("Project") {
                    Picker("Project", selection: Bindable(prefs).projectFilter) {
                        MenuLabel("All projects", systemImage: "folder").tag("")
                        ForEach(runtime.projects.open) { p in Label(p.name, systemImage: "folder.fill").tag(p.id) }
                        Label("No project", systemImage: "folder.badge.questionmark").tag("__none__")
                    }
                    Toggle(isOn: Bindable(prefs).byProject) { Label("Group by project", systemImage: "rectangle.grid.1x2") }
                    Button { model.chatListRequest = .init(.manageProjects) } label: { Label("Manage projects…", systemImage: "folder.badge.gearshape") }
                }
            }
            Button { model.chatListRequest = .init(.selectChats) } label: { Label("Select Chats", systemImage: "checkmark.circle") }
            if filtering {
                Button { prefs.pinnedOnly = false; prefs.needsYouOnly = false; prefs.liveOnly = false; prefs.groupsOnly = false; prefs.showArchived = true; prefs.projectFilter = "" } label: { Label("Clear filters", systemImage: "xmark.circle") }
            }
        }
}

/// The bot picker, All bots, the connection and the gateway switch.
struct ChatListProfileItems: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    private var prefs: ChatListPrefs { ChatListPrefs.shared }
    private var runtime: GatewayRuntime? { model.runtime }
    @ViewBuilder var body: some View {
            if let runtime {
                Picker("Profile", selection: Binding(get: { runtime.selectedProfile ?? "" }, set: { runtime.selectedProfile = $0 })) {
                    ForEach(runtime.profiles) { p in
                        Label { Text(p.label) } icon: { Image(uiImage: BotAvatarImage.cached(profile: p.name, scheme: colorScheme)).renderingMode(.original) }.tag(p.name)
                    }
                }
                Toggle(isOn: Bindable(prefs).allBots) { Label("All bots", systemImage: "person.2") }
                #if os(macOS)
                if !model.isInDemo { Button { model.chatListRequest = .init(.newBot) } label: { Label("New Bot…", systemImage: "plus") } }
                #endif
                Divider()
                // With a backup address (#283), the address in use beside the gateway's name.
                Section([runtime.connection.name, runtime.addressLabel].compactMap { $0 }.joined(separator: " · ")) {
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
            }
    private func connectionSymbol(_ s: SocketState) -> String {
        switch s {
        case .open: return "checkmark.circle.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .authRejected, .failed: return "xmark.octagon.fill"
        case .unreachable: return "exclamationmark.triangle.fill"
        case .idle: return "circle"
        }
    }
}

extension Notification.Name {
    /// The Mac's Chats › Refresh Chats (⌘R): the Chats list's own refresh, which also asks for
    /// the bots when their first answer failed.
    static let refreshChats = Notification.Name("vory.refreshChats")
}

/// Hands the list's Select mode to the morph bar, and takes it back when the list goes.
private struct ChatsSelectPublisher: ViewModifier {
    var state: AppModel.ChatsSelect?
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content
            .onChange(of: state, initial: true) { _, s in if model.chatsSelect != s { model.chatsSelect = s } }
            .onDisappear { model.chatsSelect = nil }
    }
}
