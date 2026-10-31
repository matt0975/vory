import FoundationModels
import SwiftUI
import VoryCore
import WidgetKit

/// Home: a greeting, the month in numbers and blocks, which bots are busy, the chats to pick
/// back up, and what changed since the last visit (summed up on the phone by the on-device
/// model when there is one). The cards, their order and their size come from `HomeLayout`;
/// the numbers from the gateway's analytics endpoint; the sessions from its chat list.
/// Home's "since you were here" mark (`dashboard.lastVisit`): the later of the one kept and this visit's start. A visit
/// in the demo keeps none (#392), not even the key: after leaving the demo, the person's own Home measures from their own
/// last visit, as if the demo had never been opened.
enum HomeVisit {
    /// The mark to keep after a visit, or nil to leave the stored one as it is (and absent if it was).
    static func mark(kept: Double, visitStart: Double, inDemo: Bool) -> Double? { inDemo ? nil : max(kept, visitStart) }
}

/// What Home's desk answers in place, and in what order (Duo stage 4, `DeskSplit`).
enum DeskCards {
    /// An approval, with its choices. A question or a value prompt needs typing, and the keyboard would cover the half,
    /// so it opens the chat instead.
    static func answersInPlace(_ card: PendingCard) -> Bool { card.approval != nil }
    /// The chats waiting on the person, as Home's chat list orders them (the latest first), then any it doesn't list.
    static func waiting(ids: Set<String>, order: [String]) -> [String] {
        let place = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.sorted { (place[$0] ?? .max, $0) < (place[$1] ?? .max, $1) }
    }
    /// The word on a waiting chat's line: none when its card is answered here, "Answer in the chat" for one that needs
    /// typing, "Needs you" for a chat whose card isn't loaded.
    static func note(for card: PendingCard?) -> String? {
        guard let card else { return "Needs you" }
        return answersInPlace(card) ? nil : "Answer in the chat"
    }
}

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("user.name") private var userName = ""
    @AppStorage("dashboard.range") private var rangeDays = 30
    @AppStorage("dashboard.lastVisit") private var lastVisit: Double = 0
    @AppStorage("dashboard.greeting") private var cachedGreeting = ""
    @AppStorage("dashboard.greetingKey") private var cachedGreetingKey = ""
    @AppStorage(ChatSummarizer.titlesKey) private var aiOn = ChatSummarizer.titlesOn
    @AppStorage(HomeLayout.storageKey) private var layoutRaw = ""
    @State private var usage: UsageAnalytics?
    @AppStorage(HomeLayout.allBotsKey) private var homeAllBots = false
    @State private var sessions: [StoredSession] = []
    @State private var error: String?
    @State private var loading = false
    @State private var sinceSummary: String?
    @State private var summarizing = false
    @State private var visitStart: Double = 0
    /// The page's own liveness (the phone's tab in front; on the Mac the page on show in a window
    /// in front): its loads wait while it is hidden.
    @Environment(\.botsLive) private var pageLive
    /// The Mac keeps the page mounted behind the others: a visit starts and ends with it on show.
    @Environment(\.macPageShown) private var pageShown
    @State private var visits = 0
    @State private var loadedKey = ""
    /// The range changed: its load's numbers count over and the card's height glides (#377).
    @State private var rangeMoved = false
    /// The range moves under the title at the accessibility sizes.
    @Environment(\.dynamicTypeSize) private var typeSize
    /// A window that can fold: the tiles go two to a row, either side of the fold (`HomeTiles`).
    @Environment(\.reservedRegions) private var regions
    /// The tiles' span in the window, the width the card offers them (`OfferedWidth`), for the fold's place in it.
    @State private var tilesFrame = CGRect.zero
    /// The page in the window (under our top bar's row, to the window's safe bottom), for the desk's halves.
    @State private var pageFrame = CGRect.zero
    #if os(iOS)
    @Environment(\.windowGeometry) private var windowGeometry
    /// The tab bar's height under Home, when it is there and runs along the bottom. The page's scroll runs on under the
    /// bar (its content margin keeps the last card clear), so `pageFrame` reaches the window's safe bottom; the desk's
    /// bottom half ends at the bar's top, as the chat's dock does.
    private var barReserve: CGFloat { model.tabBarReserved && !model.tabBarVertical ? VoryTabBar.reservedHeight(in: windowGeometry) : 0 }
    #else
    private var barReserve: CGFloat { 0 }
    #endif
    /// The page the desk is laid in: `pageFrame` less our tab bar's reserve at its foot.
    private var deskPage: CGRect { CGRect(x: pageFrame.minX, y: pageFrame.minY, width: pageFrame.width, height: max(0, pageFrame.height - barReserve)) }
    /// Home as a desk, the window folded across like a laptop (`DeskSplit`); nil for Home as everywhere else.
    private var desk: (top: CGFloat, gap: CGFloat, bottom: CGFloat)? {
        DeskSplit.halves(page: deskPage, fold: deskFold, accessibilityText: typeSize.isAccessibilitySize, editing: editingHome)
    }
    /// The fold the desk lays out against: the window's, taken a main-actor turn after the system reports it (see the
    /// onChange that sets it).
    @State private var deskFold: CGRect?
    /// The idle bots' faces on the desk: 44 pt (Matt, on build 39's stills), 36 at the two largest text sizes short of
    /// the accessibility ones, so the row keeps clear of Who's working's rows and the fold. Hit areas stay at least 44.
    private var idleFace: CGFloat { typeSize >= .xxLarge ? 36 : 44 }
    /// The gateway the last finished load ran against (see `shouldLoad`).
    @State private var loadedConnection: UUID?

    private var runtime: GatewayRuntime? { model.runtime }
    /// This visit kept as "since you were here" (`HomeVisit`): never one of the demo's.
    private func markVisit() { if let mark = HomeVisit.mark(kept: lastVisit, visitStart: visitStart, inDemo: model.isInDemo) { lastVisit = mark } }
    private var layout: HomeLayout { HomeLayout.parse(layoutRaw) }
    private func update(_ change: (inout HomeLayout) -> Void) { var l = layout; change(&l); layoutRaw = l.encoded }

    var body: some View {
        let desk = desk
        // One tree in every pose: half open like a laptop the desk's top half stands over the scroll, which keeps its
        // place, its position and its numbers, so a posture change loads nothing (Duo stage 4).
        VStack(spacing: 0) {
            if let desk {
                // The fold's band as padding, no view of its own: a hidden Color.clear there still stood in the
                // accessibility audit as an element with no description, the fold's frame exactly.
                deskTop.frame(height: desk.top, alignment: .top).padding(.bottom, desk.gap)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // On the desk the greeting stands in its top half, and what needs you opens the bottom one.
                    if desk == nil { header() }
                    // Home opens first on a restored device: the sign-in it still owes is asked for here too.
                    if let waiting = model.needsSignIn { GatewaySignInBanner(connection: waiting) }
                    if let runtime, desk != nil { deskNeedsYou(runtime) }
                    else if let runtime, !runtime.needsAttention.isEmpty { needsYou(runtime) }
                    // On the desk the bots stand in its top half, as who's working.
                    ForEach(desk == nil ? layout.items : layout.items.filter { $0.card != .bots }) { item in
                        editableCard(item)
                            // While Home is being edited the press is a drag, so the menu stands
                            // aside; otherwise a long press races the drag and the menu won.
                            .contextMenu(menuItems: { if !editingHome { cardMenu(item) } })
                    }
                    if let error, model.needsSignIn == nil { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 4) }
                    // Edit: the cards can be dragged onto one another until Done; Settings has the
                    // sizes, the hidden cards, the name and the opening tab.
                    HStack(spacing: 10) {
                        Button { withAnimation(.snappy) { editingHome.toggle() } } label: {
                            Label(editingHome ? "Done" : "Edit Home", systemImage: editingHome ? "checkmark" : "arrow.up.arrow.down").font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered).tint(editingHome ? Color.vory : .secondary)
                        NavigationLink { HomeSettingsView().pushedPage() } label: {
                            Label("Settings", systemImage: "slider.horizontal.3").font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered).tint(.secondary)
                    }
                    .padding(.top, 4)
                    if editingHome {
                        Text("Press, hold and drag a card onto another to put it there.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
                .animation(.snappy, value: layoutRaw)
                // A reading width in the middle of a wide window, not cards the width of the screen.
                .readingColumn(640)
            }
            .scrollPosition($scrollPosition)
            .reloadable { await Task { await load(); await summarizeSince(force: true) }.value }
        }
        // The desk comes and goes in one frame. The system changes the posture inside an animation, and with it the
        // scroll's frame glided from the fold up to the page's top going flat, the greeting passing mid-screen (Matt, on
        // build 39; the recording put the slide at 0.2 s).
        .transaction(value: desk != nil) { $0.animation = nil }
        // The system reports a posture change inside its own UIKit animation, and a layout change made in that pass
        // glided with it (the scroll view's frame is a UIKit view's, out of SwiftUI's transactions' reach). Taken on
        // the next turn, the desk comes and goes outside it, in one frame. At once when Home appears, so a launch
        // already half open shows the desk from its first frame.
        .onAppear { deskFold = regions.horizontalFold }
        .onChange(of: regions.horizontalFold) { _, fold in Task { @MainActor in deskFold = fold } }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { pageFrame = $0 }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if Self.deskProbe {
                Text(deskReadout).font(.system(size: 1)).opacity(0.01).frame(width: 1, height: 1)
                    .accessibilityIdentifier("desk.frames").accessibilityLabel(deskReadout)
            }
        }
        #endif
        // A tap on the Home tab while it is in front brings the page back to its top, as the
        // other tabs' lists do (a tester asked for it).
        .onChange(of: model.tabReselected[.dashboard]) { _, _ in withAnimation(.snappy) { scrollPosition.scrollTo(edge: .top) } }
        .untitledPage()
        .alert(tileNote?.title ?? "", isPresented: Binding(get: { tileNote != nil }, set: { if !$0 { tileNote = nil } })) {
            Button("OK") { tileNote = nil }
        } message: { Text(tileNote?.text ?? "") }
        // See `shouldLoad`. The rows and numbers are replaced in place, so a return shows no reload.
        .task(id: "\(runtime?.connection.id.uuidString ?? "")|\(runtime?.selectedProfile ?? "")|\(rangeDays)|\(homeAllBots)|\(visits)|\(pageLive)") {
            let connection = runtime?.connection.id
            let key = "\(connection?.uuidString ?? "")|\(runtime?.selectedProfile ?? "")|\(rangeDays)|\(homeAllBots)|\(visits)"
            guard Self.shouldLoad(pageLive: pageLive, connection: connection, loadedConnection: loadedConnection, key: key, loadedKey: loadedKey) else { return }
            let gotList = await load()
            // Counted only when it ran to the end against a gateway and got the chat list: a load
            // with none (Home mounted before activation), one cut short by a hide, or one the
            // gateway did not answer (the launch load before the route is up) loads again.
            if Self.counts(cancelled: Task.isCancelled, hasGateway: runtime != nil, gotList: gotList) { loadedKey = key; loadedConnection = connection }
        }
        .onAppear { visitStart = Date().timeIntervalSince1970 }
        .onDisappear { markVisit(); editingHome = false }
        .onChange(of: pageShown) { _, shown in
            if shown { visitStart = Date().timeIntervalSince1970; visits += 1 } else { markVisit(); editingHome = false }
        }
        .navigationDestination(for: ChatRoute.self) { route in ConversationView(route: route).pushedPage() }
        .onChange(of: rangeDays) { _, _ in rangeMoved = true }
    }

    /// Whether Home loads now. Hidden (the phone's other tab in front, or another Mac page), it loads
    /// only for a gateway it has not loaded from yet: at launch, where Home mounts behind the tab in
    /// front before the gateway is up and its load also refreshes the Overview widget, and after a
    /// switch of gateway. Other changes made while it is hidden (another bot, the range) wait for its
    /// return, as does each new Mac visit (`key` counts them). Live, it loads whenever the key moved.
    static func counts(cancelled: Bool, hasGateway: Bool, gotList: Bool) -> Bool { !cancelled && hasGateway && gotList }

    static func shouldLoad(pageLive: Bool, connection: UUID?, loadedConnection: UUID?, key: String, loadedKey: String) -> Bool {
        guard key != loadedKey else { return false }
        if pageLive { return true }
        return connection != nil && connection != loadedConnection
    }

    @State private var editingHome = false
    @State private var scrollPosition = ScrollPosition()

    @ViewBuilder private func cardMenu(_ item: HomeLayout.Item) -> some View {
                            Section("Size") {
                                Button { update { $0.set(item.card, size: .compact) } } label: { Label(item.card.sizeWords.compact, systemImage: item.size == .compact ? "checkmark" : "rectangle.compress.vertical") }
                                Button { update { $0.set(item.card, size: .full) } } label: { Label(item.card.sizeWords.full, systemImage: item.size == .full ? "checkmark" : "rectangle.expand.vertical") }
                            }
                            if item.card == .pickUp || item.card == .since {
                                Section("Chats from") {
                                    Button { homeAllBots = false } label: { Label("This bot", systemImage: homeAllBots ? "person" : "checkmark") }
                                    Button { homeAllBots = true } label: { Label("All bots", systemImage: homeAllBots ? "checkmark" : "person.2") }
                                }
                            }
                            Button(role: .destructive) { withAnimation(.snappy) { update { $0.remove(item.card) } } } label: { Label("Hide from Home", systemImage: "eye.slash") }
    }

    /// The card, and while Home is being edited, a drag source and a drop target with a dashed
    /// edge to say so.
    @ViewBuilder private func editableCard(_ item: HomeLayout.Item) -> some View {
        if editingHome {
            card(item)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.vory.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                .draggable(item.card.rawValue) {
                    Label(item.card.title, systemImage: item.card.symbol).font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
                }
                .dropDestination(for: String.self) { dropped, _ in
                    guard let raw = dropped.first, let moved = HomeCard(rawValue: raw), moved != item.card else { return false }
                    withAnimation(.snappy) {
                        update { l in
                            guard let from = l.items.firstIndex(where: { $0.card == moved }), let to = l.items.firstIndex(where: { $0.card == item.card }) else { return }
                            l.items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                        }
                    }
                    return true
                }
        } else {
            card(item).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func card(_ item: HomeLayout.Item) -> some View {
        switch item.card {
        case .overview: overviewCard(full: item.size == .full)
        case .bots: botsCard(full: item.size == .full)
        case .pickUp: pickUpCard(full: item.size == .full)
        case .since: sinceCard(full: item.size == .full)
        }
    }

    private func cardBackground<V: View>(_ v: V) -> some View {
        #if os(macOS)
        // The window is already white; the card is a faint fill with a hairline edge.
        v.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        #else
        v.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        #endif
    }

    // MARK: Greeting

    private var dayPart: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<22: return "evening"
        default: return "night"
        }
    }

    private var plainGreeting: String {
        let who = userName.trimmingCharacters(in: .whitespaces)
        let name = who.isEmpty ? "" : ", \(who)"
        switch dayPart {
        case "morning": return "Good morning\(name)"
        case "afternoon": return "Good afternoon\(name)"
        case "evening": return "Good evening\(name)"
        default: return who.isEmpty ? "Still up?" : "Still up, \(who)?"
        }
    }

    private var greeting: String {
        let key = "\(dayPart)|\(userName)|\(Calendar.current.component(.day, from: Date()))"
        return cachedGreetingKey == key && !cachedGreeting.isEmpty ? cachedGreeting : plainGreeting
    }

    /// The greeting and the date; on one line on the desk, where the top half is short.
    private func header(oneLine: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                BotFaceView(spec: AboutView.voryBot, size: 34, active: BotAmbient.shared.decorativeActive)
                Text(greeting).font(.title.weight(.bold)).lineLimit(oneLine ? 1 : 2).minimumScaleFactor(0.8)
            }
            Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day()).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        // The page's heading for the UI tests that hold it clear of the top bar's capsules (#516).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.heading")
        .task(id: "\(dayPart)|\(userName)") { await freshenGreeting() }
    }

    /// A one-line greeting from the on-device model, once per part of the day; the plain one otherwise.
    private func freshenGreeting() async {
        let key = "\(dayPart)|\(userName)|\(Calendar.current.component(.day, from: Date()))"
        guard cachedGreetingKey != key, aiOn, ChatSummarizer.isAvailable else { return }
        let who = userName.trimmingCharacters(in: .whitespaces)
        do {
            let ai = LanguageModelSession(instructions: "You write one short, warm greeting for the home screen of an app. At most eight words. No emoji, no exclamation marks, no quotes. Use the person's name if given.")
            let line = try await ai.respond(to: "It is \(dayPart). \(who.isEmpty ? "No name is known." : "The person's name is \(who).") Write the greeting.").content
                .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
            if (3...60).contains(line.count), !line.contains("\n") { cachedGreeting = line; cachedGreetingKey = key }
        } catch {}
    }

    // MARK: Needs you

    private func needsYou(_ rt: GatewayRuntime) -> some View {
        let n = rt.needsAttention.count
        return Button { model.selectedTab = .chats } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.red)
                Text(n == 1 ? "One chat needs you" : "\(n) chats need you").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: The desk (Duo stage 4)

    /// The desk's top half: the greeting, then who's working (the bots working or waiting first, as the Bots card's list
    /// shows them, more than fit scrolling in the panel; then the idle ones' faces).
    private var deskTop: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(oneLine: true)
            cardBackground(VStack(alignment: .leading, spacing: 10) {
                Text("Who's working").font(.headline)
                if let rt = runtime, !rt.profiles.isEmpty {
                    let busy = rt.profiles.filter { let s = botStatus(rt, $0); return s.working != nil || s.waiting }
                    let idle = rt.profiles.filter { let s = botStatus(rt, $0); return s.working == nil && !s.waiting }
                    if busy.isEmpty {
                        Text("No one's working right now.").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        // The rows take what the half leaves them and scroll in it: without a floor of 0 the list stood
                        // at its whole height and the panel ran onto the fold with two bots working (the Duo, 2026-10-27).
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) { ForEach(busy) { p in botRow(rt, p) } }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                        .layoutPriority(-1)
                    }
                    if !idle.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(idle) { p in
                                    Button { rt.selectedProfile = p.name; model.selectedTab = .chats } label: {
                                        BotAvatar(profile: p.name, size: idleFace).frame(width: idleFace + 8, height: idleFace + 8).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(p.label): idle")
                                }
                            }
                        }
                    }
                } else {
                    Text("Connect a gateway to see your bots.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top))
            #if DEBUG
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probePanel = $0 }
            #endif
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
        .readingColumn(640)
    }

    /// What needs you, at the head of the desk's bottom half: each waiting chat's first card, an approval answered here
    /// with its choices at the large size, a question or a value prompt with the way into its chat (`DeskCards`), and a
    /// chat whose card isn't loaded with its line alone. One quiet line when nothing waits.
    private func deskNeedsYou(_ rt: GatewayRuntime) -> some View {
        let ids = DeskCards.waiting(ids: rt.needsAttention.union(rt.chats.filter(\.needsAttention).map(\.storedID)), order: sessions.map(\.id))
        return Group {
            if ids.isEmpty {
                Text("Nothing needs you").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ids, id: \.self) { id in
                        let chat = rt.chatForStored(id)
                        let stored = sessions.first { $0.id == id }
                        let card = chat?.firstCard
                        VStack(alignment: .leading, spacing: 8) {
                            deskChatLine(id: id, title: chat?.title ?? stored?.displayTitle ?? "A chat",
                                         profile: chat?.profileName ?? stored?.profile ?? rt.selectedProfile ?? "default", note: DeskCards.note(for: card))
                            if let chat, let card, DeskCards.answersInPlace(card) {
                                PendingCardView(chat: chat, card: card).controlSize(.large)
                            }
                        }
                    }
                }
            }
        }
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probeCards = $0 }
        #endif
    }

    /// A waiting chat's line on the desk: its bot's face, its title, and what it wants when that isn't answered here. A
    /// tap opens the chat, as Pick up's rows do.
    @ViewBuilder private func deskChatLine(id: String, title: String, profile: String, note: String?) -> some View {
        let line = HStack(spacing: 8) {
            BotAvatar(profile: profile, size: 24, mood: BotFaceView.Mood(session: id, state: .awaitingApproval))
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 8)
            if let note { Text(note).font(.caption.weight(.medium)).foregroundStyle(.red) }
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        if MorphTopBar.active(model) {
            Button { model.openStoredChat(id: id, profile: profile, title: title, returningTo: .dashboard) } label: { line }.buttonStyle(.plain)
        } else {
            NavigationLink(value: ChatRoute(storedID: id, title: title, profile: profile)) { line }.buttonStyle(.plain)
        }
    }

    #if DEBUG
    /// DEBUG `-vory-desk-frames`: the page, the desk's panel and what needs you (window space), the fold, the split and
    /// how many loads have run (a posture change must add none), read by the hinge legs as `desk.frames`' label. Checked
    /// absent from Release.
    private static let deskProbe = ProcessInfo.processInfo.arguments.contains("-vory-desk-frames")
    @State private var probePanel: CGRect = .zero
    @State private var probeCards: CGRect = .zero
    @State private var probeLoads = 0
    private var deskReadout: String {
        func r(_ f: CGRect) -> String { String(format: "%.1f %.1f %.1f %.1f", f.minX, f.minY, f.width, f.height) }
        return "page \(r(deskPage));panel \(r(probePanel));cards \(r(probeCards));fold \(regions.horizontalFold.map(r) ?? "none");split \(desk == nil ? "no" : "yes");loads \(probeLoads)"
    }
    #endif

    // MARK: Overview

    private var periodSessions: [StoredSession] {
        let cutoff = Date().timeIntervalSince1970 - Double(rangeDays) * 86400
        return sessions.filter { ($0.startedAt ?? $0.lastActive ?? 0) >= cutoff }
    }

    private func overviewCard(full: Bool) -> some View {
        cardBackground(VStack(alignment: .leading, spacing: 12) {
            // The range beside the title where it fits at its own size; on a row of its own under
            // it at the accessibility sizes, or wherever it does not fit.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) { Text("Overview").font(.headline); rangePicker }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { Text("Overview").font(.headline); Spacer(); rangePicker.fixedSize() }
                    VStack(alignment: .leading, spacing: 10) { Text("Overview").font(.headline); rangePicker }
                }
            }
            let t = usage?.totals
            let tokens = (t?.totalInput ?? 0) + (t?.totalOutput ?? 0) + (t?.totalCacheRead ?? 0)
            let messages = periodSessions.reduce(0) { $0 + ($1.messageCount ?? 0) }
            let activeDays = Set((usage?.daily ?? []).filter { ($0.sessions ?? 0) > 0 }.map(\.day)).count
            // Three to a row on a phone, an iPad and the Mac: six tiles fill two rows that way,
            // where four left a short second row on the Mac. Two to a row on a window that can
            // fold, so a fold up the middle falls between the tiles (`HomeTiles`, Duo stage 2).
            // The span the fold's place is read against is the width the card offers the tiles, whatever their columns
            // add up to (`OfferedWidth`).
            OfferedWidth {
                LazyVGrid(columns: HomeTiles.items(regions: regions, frame: tilesFrame, spacing: 8), spacing: 8) {
                    tile("Sessions", t.map { Format.count($0.totalSessions ?? 0) } ?? Format.count(periodSessions.count))
                    tile("Messages", Format.count(messages))
                    tile("Tokens", tokens > 0 ? Format.tokens(tokens) : "–")
                    tile("Active days", "\(activeDays > 0 ? activeDays : Set(periodSessions.compactMap { $0.startedAt.map { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: $0)) } }).count)")
                    tile("Peak hour", peakHour ?? "–")
                    tile("Top model", favoriteModel ?? "–")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if os(iOS)
            // Its span across the window only: Home scrolls, and its height and place down the page are no business
            // of the columns (a full frame changed on every frame of a scroll and re-ran the whole page).
            .onGeometryChange(for: CGRect.self) { g in
                let f = g.frame(in: .global); return CGRect(x: f.minX, y: 0, width: f.width, height: 0)
            } action: { tilesFrame = $0 }
            #endif
            if full {
                ActivityGrid(daily: usage?.daily ?? [], sessions: sessions, weeks: 13)
                    .contentShape(.rect)
                    .onTapGesture { tileNote = ("Activity", "One block per day for the last thirteen weeks, a column per week with Monday at the top. The more chats started that day, the brighter the block.") }
                if let cost = t?.totalEstimatedCost, cost > 0.005 {
                    Text("About \(cost, format: .currency(code: "USD").precision(.fractionLength(2))) estimated for the period, as the gateway counts it.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if usage == nil, !loading {
                    Text("Token counts need a gateway with the analytics API; sessions and messages come from the chat list.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        })
    }

    /// The system's segmented control (#377, call #35): its glass thumb slides to the range, and
    /// a finger can drag it along. Ours snapped: its lens jumped from one option to the next. The
    /// short labels are spoken in full. The numbers that hang on the range alone move with it.
    /// "Range" names the group for VoiceOver; the Mac drew it beside the segments as well.
    private var rangePicker: some View {
        Picker("Range", selection: $rangeDays.animation(.snappy(duration: 0.3))) {
            Text("7d").accessibilityLabel("7 days").tag(7)
            Text("30d").accessibilityLabel("30 days").tag(30)
            Text("90d").accessibilityLabel("90 days").tag(90)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// What each tile counts, for a tap on it.
    private static let tileNotes: [String: String] = [
        "Sessions": "Chats started in the period, as the gateway's analytics count them. On a gateway without the analytics API it is the chats in the list instead.",
        "Messages": "Messages sent and received across the chats of the period.",
        "Tokens": "Input, output and cached tokens the models used in the period, added up.",
        "Active days": "Days in the period with at least one chat started.",
        "Peak hour": "The hour of the day your chats most often start.",
        "Top model": "The model used by the most chats in the period.",
    ]
    @State private var tileNote: (title: String, text: String)?

    private func tile(_ title: String, _ value: String) -> some View {
        // A number sits on one line; a name (the model) may take two, in a smaller face.
        let isText = value.rangeOfCharacter(from: .letters) != nil && value.count > 6
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(isText ? .subheadline.weight(.semibold) : .title3.weight(.semibold).monospacedDigit())
                .lineLimit(isText ? 2 : 1).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true)
                // A change of range counts the number over (#377).
                .contentTransition(.numericText())
        }
        .frame(minHeight: 58, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .contentShape(.rect)
        .onTapGesture { if let t = Self.tileNotes[title] { tileNote = (title, t) } }
        .accessibilityHint("Tap for what this counts")
        #if os(macOS)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        #else
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        #endif
    }

    private var peakHour: String? {
        let hours = periodSessions.compactMap { $0.startedAt.map { Calendar.current.component(.hour, from: Date(timeIntervalSince1970: $0)) } }
        guard !hours.isEmpty else { return nil }
        let counts = Dictionary(grouping: hours) { $0 }.mapValues(\.count)
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        var c = DateComponents(); c.hour = best
        return Calendar.current.date(from: c).map { $0.formatted(.dateTime.hour()) }
    }

    private var favoriteModel: String? {
        if let m = usage?.byModel?.max(by: { ($0.inputTokens ?? 0) + ($0.outputTokens ?? 0) < ($1.inputTokens ?? 0) + ($1.outputTokens ?? 0) })?.model, !m.isEmpty {
            return m.split(separator: "/").last.map(String.init)
        }
        let models = periodSessions.compactMap(\.model).filter { !$0.isEmpty }
        guard !models.isEmpty else { return nil }
        let counts = Dictionary(grouping: models) { $0 }.mapValues(\.count)
        return counts.max(by: { $0.value < $1.value })?.key.split(separator: "/").last.map(String.init)
    }

    // MARK: Bots

    private func botStatus(_ rt: GatewayRuntime, _ p: ProfileInfo) -> (working: ChatSession?, waiting: Bool) {
        let chats = rt.chats.filter { $0.profileName == p.name }
        return (chats.first { $0.isRunning }, chats.contains { $0.needsAttention })
    }

    /// A bot with its face, its name and what it's doing (the goal or status line, "Needs you", or "Idle"); a tap opens
    /// its chats. The Bots card's list, and the desk's who's working.
    private func botRow(_ rt: GatewayRuntime, _ p: ProfileInfo) -> some View {
        let (working, waiting) = botStatus(rt, p)
        return Button { rt.selectedProfile = p.name; model.selectedTab = .chats } label: {
            HStack(spacing: 12) {
                BotAvatar(profile: p.name, size: 36, active: working != nil, mood: BotFaceView.Mood(session: working?.storedID, state: waiting ? .awaitingApproval : (working?.botState ?? .idle)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.label).font(.body.weight(.medium))
                    Text(waiting ? "Needs you" : (working.map { ChatGoals.shared.goal(for: $0.storedID) ?? $0.statusLine ?? "Working…" } ?? "Idle"))
                        .font(.caption).foregroundStyle(waiting ? .red : (working != nil ? .blue : .secondary)).lineLimit(1)
                }
                Spacer()
                Circle().fill(waiting ? Color.red : (working != nil ? Color.blue : Color.secondary.opacity(0.4))).frame(width: 8, height: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func botsCard(full: Bool) -> some View {
        cardBackground(VStack(alignment: .leading, spacing: 10) {
            Text("Bots").font(.headline)
            if let rt = runtime, !rt.profiles.isEmpty {
                if full {
                    ForEach(rt.profiles) { p in botRow(rt, p) }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(rt.profiles) { p in
                                let (working, waiting) = botStatus(rt, p)
                                Button { rt.selectedProfile = p.name; model.selectedTab = .chats } label: {
                                    VStack(spacing: 4) {
                                        ZStack(alignment: .topTrailing) {
                                            BotAvatar(profile: p.name, size: 44, active: working != nil, mood: BotFaceView.Mood(session: working?.storedID, state: waiting ? .awaitingApproval : (working?.botState ?? .idle)))
                                            if waiting || working != nil {
                                                Circle().fill(waiting ? Color.red : Color.blue).frame(width: 10, height: 10).offset(x: 2, y: -2)
                                            }
                                        }
                                        Text(p.label).font(.caption2).lineLimit(1).frame(width: 60)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(p.label): \(waiting ? "needs you" : (working != nil ? "working" : "idle"))")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                Text("Connect a gateway to see your bots.").font(.subheadline).foregroundStyle(.secondary)
            }
        })
    }

    // MARK: Pick up

    private func recent(_ n: Int) -> [StoredSession] {
        Array(sessions.filter { $0.archived != true }.sorted { ($0.lastActive ?? 0) > ($1.lastActive ?? 0) }.prefix(n))
    }

    private func pickUpCard(full: Bool) -> some View {
        let list = recent(full ? 5 : 3)
        return cardBackground(VStack(alignment: .leading, spacing: 10) {
            Text("Pick up where you left off").font(.headline)
            if list.isEmpty {
                Text(loading ? "Loading…" : (error == nil ? "No chats yet. Start one from the Chats tab." : "The chat list did not load. Pull down to try again.")).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(list) { s in
                // Under the phone's morph bar a chat has its bar (its bot, its actions, the morph)
                // on Chats only: pushed here it got the page Back alone and late, and with a chat
                // left open on Chats a bar stuck on Home's title with no Back (#378). It opens on
                // Chats as from the list, and its Back comes back to Home. Elsewhere (the Mac, a
                // wide window) the chat's own header stands over it here.
                if MorphTopBar.active(model) {
                    Button { model.openStoredChat(id: s.id, profile: s.profile, title: s.displayTitle, returningTo: .dashboard) } label: { pickUpRow(s) }
                        .buttonStyle(.plain)
                } else {
                    NavigationLink(value: ChatRoute(storedID: s.id, title: s.displayTitle, profile: s.profile)) { pickUpRow(s) }
                        .buttonStyle(.plain)
                }
            }
        })
    }

    private func pickUpRow(_ s: StoredSession) -> some View {
        HStack(spacing: 10) {
            BotAvatar(profile: s.profile ?? runtime?.selectedProfile ?? "default", size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.displayTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(s.preview ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let d = s.lastDate { Text(d, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary) }
            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    // MARK: Since you were here

    /// The last visit, or the last day when there is none yet: the card has something to say
    /// from the first open.
    private var sinceStamp: Double { lastVisit > 0 ? lastVisit : Date().timeIntervalSince1970 - 86400 }
    private var changedSinceVisit: [StoredSession] {
        sessions.filter { ($0.lastActive ?? 0) > sinceStamp }.sorted { ($0.lastActive ?? 0) > ($1.lastActive ?? 0) }
    }

    private func sinceCard(full: Bool) -> some View {
        cardBackground(VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(lastVisit > 0 ? "Since you were here" : "The last day").font(.headline)
                Spacer()
                // A pull on Home sums it up afresh; the card's own refresh button is gone (#377).
                if summarizing { ProgressView().controlSize(.small) }
            }
            if let sinceSummary {
                Text(sinceSummary).font(.subheadline).lineLimit(full ? nil : 3)
                Text("Summed up on \(DeviceWords.this).").font(.caption2).foregroundStyle(.tertiary)
            } else if changedSinceVisit.isEmpty, !loading {
                Text(lastVisit > 0 ? "Nothing new since \(Date(timeIntervalSince1970: lastVisit), format: .relative(presentation: .named))." : "Nothing happened in the last day.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(changedSinceVisit.prefix(full ? 5 : 3)) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(.secondary).frame(width: 5, height: 5).padding(.top, 6)
                        Text("\(s.displayTitle): \(s.preview ?? "updated")").font(.subheadline).lineLimit(2)
                    }
                }
            }
        })
        .task(id: "\(changedSinceVisit.map(\.id).joined())|\(pageLive)") { if pageLive { await summarizeSince(force: false) } }
    }

    private func summarizeSince(force: Bool) async {
        let changed = changedSinceVisit
        guard !changed.isEmpty, aiOn, ChatSummarizer.isAvailable, !summarizing else { if changed.isEmpty { sinceSummary = nil }; return }
        if !force, sinceSummary != nil { return }
        summarizing = true; defer { summarizing = false }
        let lines = changed.prefix(8).map { "- \($0.displayTitle) (\($0.profile ?? "bot")): \(($0.preview ?? "").prefix(200))" }
        let running = runtime?.chats.filter { $0.isRunning }.map { "- \($0.title) is still working: \($0.statusLine ?? "thinking")" } ?? []
        do {
            let ai = LanguageModelSession(instructions: "You sum up, for the owner of some AI assistants, what the assistants did while the owner was away. Two or three short sentences, plain words, no bullet points, no greeting. Name the chats. Do not say it is a summary.")
            let text = try await ai.respond(to: "Chats that changed since the last visit:\n" + (lines + running).joined(separator: "\n")).content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { sinceSummary = text }
        } catch {}
    }

    // MARK: Data

    /// The recent chats: the current bot's page, or one page per bot merged, each row tagged
    /// with its bot so the avatars and the chat routes know whose it is.
    private static func chats(_ rt: GatewayRuntime, allBots: Bool) async throws -> [StoredSession] {
        let query = [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: allBots ? "50" : "100")]
        guard allBots, rt.profiles.count > 1 else {
            let r: SessionListResponse = try await rt.api.get("/api/sessions", query: query, profile: rt.selectedProfile)
            return r.sessions
        }
        return try await withThrowingTaskGroup(of: [StoredSession].self) { group in
            for p in rt.profiles.map(\.name) {
                group.addTask {
                    let r: SessionListResponse = try await rt.api.get("/api/sessions", query: query, profile: p)
                    return r.sessions.map { var s = $0; if s.profile == nil || s.profile!.isEmpty { s.profile = p }; return s }
                }
            }
            var all: [StoredSession] = []
            for try await part in group { all += part }
            return all
        }
    }

    /// The month's numbers, or nil with `keep` when the fetch was cancelled or never reached the
    /// gateway: a refresh pulled and let go used to blank the card until the next launch, so
    /// those keep the numbers the card has; a gateway that answers without the analytics API
    /// clears them, which is what the footer explains.
    private static func usage(_ rt: GatewayRuntime, days: Int) async -> (UsageAnalytics?, keep: Bool) {
        do {
            let a: UsageAnalytics = try await rt.api.get("/api/analytics/usage", query: [URLQueryItem(name: "days", value: String(days))], profile: rt.selectedProfile)
            return (a, false)
        } catch is CancellationError { return (nil, true) }
        catch let e as URLError where e.code == .cancelled || e.code == .notConnectedToInternet || e.code == .timedOut { return (nil, true) }
        catch { return (nil, false) }
    }

    /// Whether the chat list arrived (a failed one may still leave the last list showing).
    @discardableResult private func load() async -> Bool {
        guard let rt = runtime else { return false }
        loading = true; defer { loading = false }
        #if DEBUG
        probeLoads += 1
        #endif
        // The gateway caps a page at 100 (a larger ask is refused outright).
        let allBots = homeAllBots
        async let u: (UsageAnalytics?, keep: Bool) = Self.usage(rt, days: rangeDays)
        async let s: [StoredSession]? = try? Self.chats(rt, allBots: allBots)
        let (usageResult, list) = await (u, s)
        // After a change of range the numbers count over, the grid's blocks fade to their new
        // shades and the card's height glides, so the cards below move with it instead of jumping
        // (#377). Any other load lands at once, as before.
        let animated = rangeMoved
        rangeMoved = false
        withAnimation(animated ? .snappy(duration: 0.4) : nil) {
            if let a = usageResult.0 { usage = a } else if !usageResult.keep { usage = nil }
            if let list { sessions = list; error = nil }
            else if sessions.isEmpty { error = "Could not load the chat list." }
        }
        if let a = usageResult.0 { Self.keepForWidgets(a, sessions: list, runtime: rt) }
        return list != nil
    }

    /// The month's numbers into the shared snapshot the Overview widget and complications draw from: a gateway's own,
    /// never the demo's (#493: its numbers stayed on the saved gateway's widget after leaving it).
    static func keepForWidgets(_ a: UsageAnalytics, sessions: [StoredSession]?, runtime rt: GatewayRuntime) {
        guard !rt.isEphemeral, var snap = WidgetSnapshot.load() else { return }
        snap.usage = WidgetSnapshot.Usage.make(analytics: a, sessions: sessions, previous: snap.usage)
        snap.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "vory.overview")
    }
}

/// The last `weeks` weeks as blocks, one column per week, one row per weekday, darker for busier
/// days (sessions started that day). Like the usage blocks in a coding terminal.
struct ActivityGrid: View {
    var daily: [UsageAnalytics.Day]
    var sessions: [StoredSession]
    var weeks: Int

    private var counts: [Date: Int] {
        let cal = Calendar.current
        var out: [Date: Int] = [:]
        if !daily.isEmpty {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
            for d in daily { if let date = f.date(from: d.day) { out[cal.startOfDay(for: date), default: 0] += d.sessions ?? 0 } }
        } else {
            for s in sessions { if let t = s.startedAt { out[cal.startOfDay(for: Date(timeIntervalSince1970: t)), default: 0] += 1 } }
        }
        return out
    }

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)   // 1 = Sunday
        let daysBack = weeks * 7 - (7 - weekday)             // the grid ends on today's column
        let start = cal.date(byAdding: .day, value: -(daysBack - 1), to: today)!
        let counts = counts
        let peak = max(1, counts.values.max() ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                            let n = counts[day] ?? 0
                            let future = day > today
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(future ? Color.clear : (n == 0 ? Color.primary.opacity(0.07) : Color.vory.opacity(0.25 + 0.75 * min(1, Double(n) / Double(peak)))))
                                .aspectRatio(1, contentMode: .fit)
                                .accessibilityLabel(future ? "" : "\(day.formatted(date: .abbreviated, time: .omitted)): \(n) sessions")
                        }
                    }
                }
            }
            HStack {
                Text(start, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("Today").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
        #if os(macOS)
        // Blocks the size of a terminal's, not of a window: at most 22 pt each.
        .frame(maxWidth: CGFloat(weeks) * 22 + CGFloat(weeks - 1) * 3, alignment: .leading)
        #endif
    }
}

enum Format {
    static func count(_ n: Int) -> String { n.formatted(.number) }
    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1000)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(n) / 1_000_000)
        default: return String(format: "%.2fB", Double(n) / 1_000_000_000)
        }
    }
}
