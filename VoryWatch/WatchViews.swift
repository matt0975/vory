import SwiftUI
import VoryCore

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @State private var path = NavigationPath()

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            Group {
                if model.runtime != nil { WatchChatsView(path: $path) }
                else { WatchConnectView() }
            }
            .navigationDestination(for: String.self) { WatchChatView(storedID: $0) }
            .navigationDestination(for: WatchActivityRoute.self) { _ in WatchActivityView(path: $path) }
            .navigationDestination(for: WatchOverviewRoute.self) { _ in WatchOverviewView() }
        }
        .onChange(of: model.pendingOverview) { _, go in
            if go { path = NavigationPath(); path.append(WatchOverviewRoute()); model.pendingOverview = false }
        }
        .onChange(of: model.pendingChat) { _, id in
            if let id { path.append(id); model.pendingChat = nil }
        }
        .onChange(of: model.pendingActivity) { _, go in
            if go { path = NavigationPath(); path.append(WatchActivityRoute()); model.pendingActivity = false }
        }
    }
}

struct WatchActivityRoute: Hashable {}
struct WatchOverviewRoute: Hashable {}

/// Home's overview on the wrist: the week and the month in numbers and the activity blocks,
/// from the same snapshot the complications draw. Opens at once with what is stored.
struct WatchOverviewView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let u = model.usage {
                    HStack(alignment: .top) {
                        stat("\(u.sessions7)", "chats, 7d")
                        stat(WidgetSnapshot.Usage.tokens(u.tokens7), "tokens, 7d")
                    }
                    UsageBlocks(days: u.days, weeks: nil)
                        .frame(height: 62)
                        .accessibilityLabel("Activity blocks, one per day")
                    HStack(alignment: .top) {
                        stat("\(u.sessions30)", "chats, 30d")
                        stat("\(u.activeDays30)", "active days")
                    }
                    if let m = u.topModel { Label(m, systemImage: "cpu").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    Text("Updated \(u.updatedAt, style: .relative) ago").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text("No numbers yet. They arrive from the gateway's analytics.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Overview")
        .task { await model.loadUsage() }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the complications open to: the chats waiting for an answer and the ones at work, with
/// the gateway's state on top. A row opens its chat.
struct WatchActivityView: View {
    @Environment(WatchModel.self) private var model
    @Binding var path: NavigationPath

    var body: some View {
        List {
            if let rt = model.runtime {
                let waiting = model.sessions.filter { rt.needsAttention.contains($0.id) }
                let working = model.sessions.filter { !rt.needsAttention.contains($0.id) && (rt.chatForStored($0.id)?.isRunning == true || $0.isActive == true) }
                Section {
                    HStack(spacing: 6) {
                        Circle().fill(model.socketUsable ? Color.green : Color.orange).frame(width: 8, height: 8)
                        Text(rt.connection.name).font(.headline).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(model.socketUsable ? "Online" : "Via iPhone").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("\(waiting.count) need you", systemImage: "exclamationmark.bubble.fill").foregroundStyle(waiting.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                        Spacer()
                        Label("\(working.count) working", systemImage: "ellipsis.message.fill").foregroundStyle(working.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
                    }
                    .font(.caption2)
                }
                Section("Needs you") {
                    if waiting.isEmpty { Text("Nothing waiting").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(waiting) { s in NavigationLink(value: s.id) { WatchSessionRow(session: s, badge: "exclamationmark.bubble.fill", showBot: true) } }
                }
                Section("Working") {
                    if working.isEmpty { Text("No chat is working right now").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(working) { s in NavigationLink(value: s.id) { WatchSessionRow(session: s, badge: "ellipsis.message", showBot: true) } }
                }
            }
        }
        .navigationTitle("Activity")
        .refreshable { await model.loadSessions() }
        .task { await model.loadSessions() }
    }
}

/// The bot's face on the watch: the look the iPhone sent (shape, eyes, colour, or a photo),
/// drawn still. Falls back to the default shape in the bot's palette colour.
struct WatchBotFace: View {
    @Environment(WatchModel.self) private var model
    var profile: String
    var label: String? = nil
    var size: CGFloat = 24

    var body: some View {
        let looks = model.looks
        let key = looks.key(profile: profile, label: label ?? "") ?? profile
        if looks.avatars[key] == "photo", let data = looks.photos[key], let img = WatchPhotoCache.image(key: key, data: data) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(.circle)
        } else {
            let hex = looks.colors[key] ?? WatchBotColor.hex(for: profile)
            BotFaceView(spec: BotLookSpec.from(choice: looks.avatars[key], hex: hex), size: size, active: false, drawn: true)
                .frame(width: size, height: size)
        }
    }
}

/// A bot's photo, decoded once: a list of chats used to decode the same JPEG for every row on
/// every redraw.
@MainActor
enum WatchPhotoCache {
    private static var images: [String: (bytes: Int, image: UIImage)] = [:]
    static func image(key: String, data: Data) -> UIImage? {
        if let hit = images[key], hit.bytes == data.count { return hit.image }
        guard let img = UIImage(data: data) else { return nil }
        images[key] = (data.count, img)
        return img
    }
}

/// Recent sessions, with the ones waiting for you on top.
struct WatchChatsView: View {
    @Environment(WatchModel.self) private var model
    @Binding var path: NavigationPath
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var showNewChat = false

    var body: some View {
        List {
            if let rt = model.runtime {
                let merged = model.listProfile == "*"
                let waiting = model.sessions.filter { rt.needsAttention.contains($0.id) }
                if !waiting.isEmpty {
                    Section("Needs you") {
                        ForEach(waiting) { s in NavigationLink(value: s.id) { WatchSessionRow(session: s, badge: "exclamationmark.bubble.fill", showBot: merged) } }
                    }
                }
                Section {
                    // One row for the three ways out of the list, so the chats start on the
                    // first screen instead of under three full-width rows.
                    HStack(spacing: 6) {
                        Button { showNewChat = true } label: { Image(systemName: "square.and.pencil").frame(maxWidth: .infinity) }
                            .accessibilityLabel("New chat")
                        Button { path.append(WatchActivityRoute()) } label: { Image(systemName: "bolt.horizontal.circle").frame(maxWidth: .infinity) }
                            .accessibilityLabel("Activity")
                        Button { path.append(WatchOverviewRoute()) } label: { Image(systemName: "square.grid.3x3.fill").frame(maxWidth: .infinity) }
                            .accessibilityLabel("Overview")
                    }
                    .buttonStyle(.bordered)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    ForEach(model.sessions.filter { !rt.needsAttention.contains($0.id) }) { s in
                        NavigationLink(value: s.id) { WatchSessionRow(session: s, badge: rt.chatForStored(s.id)?.isRunning == true ? "ellipsis.message" : nil, showBot: merged) }
                    }
                    if model.hasMore {
                        // A few chats load first; this brings the next page as you scroll down.
                        Button { Task { await model.loadMore() } } label: {
                            if model.loadingMore { Label { Text("Loading…") } icon: { ProgressView() } }
                            else { Label("Show more", systemImage: "arrow.down.circle") }
                        }
                        .disabled(model.loadingMore)
                        .onAppear { Task { await model.loadMore() } }
                    }
                } header: {
                    if merged { Text("All bots") }
                    else {
                        let p = model.listProfile ?? rt.selectedProfile ?? ""
                        HStack(spacing: 6) {
                            if !p.isEmpty { WatchBotFace(profile: p, label: rt.profiles.first { $0.name == p }?.label, size: 18) }
                            Text(p.isEmpty ? rt.connection.name : (rt.profiles.first { $0.name == p }?.label ?? p))
                        }
                    }
                }
                if let e = model.loadError { Text(e).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Vory")
        .toolbar {
            if model.runtime != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Choose bot")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                }
            }
        }
        .sheet(isPresented: $showPicker) { WatchProfilePicker() }
        .sheet(isPresented: $showSettings) { WatchSettingsView() }
        .sheet(isPresented: $showNewChat) {
            WatchNewChatSheet { profile in
                showNewChat = false
                Task { await newChat(profile: profile) }
            }
        }
        .refreshable { await model.loadSessions() }
        .task { await model.loadSessions() }
    }

    private func newChat(profile: String) async {
        guard let rt = model.runtime else { return }
        rt.selectedProfile = profile
        if model.listProfile != "*" { model.listProfile = profile }
        if model.socketUsable, let chat = try? await rt.newChat() { path.append(chat.storedID); return }
        // No direct socket (Bluetooth to the phone): ask the phone app to create it.
        do {
            let r = try await model.connectivity.request(["op": "new", "profile": profile])
            if let sid = r["session"] as? String, !sid.isEmpty { path.append(sid) }
            else { model.loadError = r["error"] as? String ?? "The phone could not create a chat." }
        } catch { model.loadError = "New chat needs the iPhone nearby: \(error.localizedDescription)" }
    }
}

/// New chat: the bots as a scrolling list, like the Bots page on the phone. Pick one and the
/// chat opens with it.
struct WatchNewChatSheet: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let rt = model.runtime {
                    ForEach(rt.profiles) { p in
                        Button { onPick(p.name) } label: {
                            HStack(spacing: 10) {
                                WatchBotFace(profile: p.name, label: p.label, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.label).font(.headline).lineLimit(1)
                                    if let m = p.model?.split(separator: "/").last { Text(String(m)).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    if rt.profiles.isEmpty { Text("No bots yet. Open Vory on the iPhone once.").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("New chat")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Pick which bot's chats the list shows, or all of them merged (watchOS has no Menu).
struct WatchProfilePicker: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Button { model.listProfile = "*"; Task { await model.loadSessions() }; dismiss() } label: {
                Label("All bots", systemImage: "person.2")
            }
            if let rt = model.runtime {
                ForEach(rt.profiles) { p in
                    Button { model.listProfile = p.name; rt.selectedProfile = p.name; Task { await model.loadSessions() }; dismiss() } label: {
                        HStack(spacing: 8) {
                            WatchBotFace(profile: p.name, label: p.label, size: 26)
                            Text(p.label)
                            Spacer()
                            if (model.listProfile ?? rt.selectedProfile) == p.name { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Bots")
    }
}

/// The same deterministic palette the phone uses when no colour was picked for a bot: the
/// phone's list itself, from VoryCore (a copy here had every colour off by a digit).
enum WatchBotColor {
    static func hex(for profile: String) -> String { BotPalette.defaultHex(for: profile) }
    static func color(for profile: String) -> Color { Color(botHex: hex(for: profile)) ?? .accentColor }
}

struct WatchSessionRow: View {
    @Environment(WatchModel.self) private var model
    var session: StoredSession
    var badge: String?
    var showBot = false
    var body: some View {
        let summary = model.summary(for: session)
        HStack(spacing: 8) {
            if showBot { WatchBotFace(profile: session.profile ?? "?", size: 24) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if session.pinned == true { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    Text(summary?.title ?? session.displayTitle).font(.headline).lineLimit(2)
                }
                Text(summary?.summary ?? session.preview ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(summary == nil ? 1 : 2)
            }
            Spacer(minLength: 0)
            if let badge { Image(systemName: badge).foregroundStyle(badge.hasPrefix("exclamation") ? .orange : .green) }
        }
    }
}

/// One chat: the tail of the transcript, the approval card when one is waiting, and a composer
/// pinned to the bottom edge so the thread opens at its end. The runtime and streaming are the
/// same VoryCore code the phone runs.
struct WatchChatView: View {
    @Environment(WatchModel.self) private var model
    var storedID: String
    @State private var chat: ChatSession?
    @State private var text = ""
    @State private var error: String?
    /// Talk: a recording to the gateway, the reply read aloud here.
    @State private var talk = WatchTalk()
    /// REST-polling fallback state (used when the socket cannot open, e.g. over Bluetooth).
    @State private var proxied = false
    @State private var items: [TranscriptItem] = []
    @State private var cards: [[String: Any]] = []
    @State private var running = false
    @State private var statusText = ""
    @State private var title = "Chat"
    @State private var profile: String?
    /// Messages on screen: the last few at first, more with "Show earlier".
    @State private var shown = 12
    /// When the thread last followed the stream to its end.
    @State private var lastFollow = Date.distantPast

    var body: some View {
        Group {
            if proxied {
                proxiedBody
            } else if let chat {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if chat.items.count > shown {
                                // The last few messages first; the rest a page at a time from the top.
                                Button { shown += 20 } label: { Label("Show earlier", systemImage: "arrow.up.circle") }.font(.caption)
                            }
                            ForEach(chat.items.suffix(shown)) { item in WatchTranscriptRow(item: item, profile: chat.profileName).id(item.id) }
                            if let s = chat.statusLine, chat.isRunning { Text(s).font(.caption2).foregroundStyle(.secondary) }
                            if let card = chat.firstCard { WatchCardView(chat: chat, card: card) }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }
                    .defaultScrollAnchor(.bottom)
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                    // The history lands after the view does: land the end again once it is in,
                    // and once more when the live snapshot replaces it.
                    .task { try? await Task.sleep(for: .milliseconds(350)); proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: chat.isResuming) { _, resuming in if !resuming { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: chat.items.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    // A reply grows token by token: following every one of them made the wrist
                    // lay the thread out dozens of times a second.
                    .onChange(of: chat.items.last) { _, _ in
                        let now = Date()
                        if now.timeIntervalSince(lastFollow) > 0.35 { lastFollow = now; proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: chat.isRunning) { _, running in if !running { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: chat.firstCard?.id) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .navigationTitle(chat.title)
                .toolbar {
                    // The bottom bar is where watchOS pins a field to the screen's bottom edge; a
                    // safe-area inset sat above a blank band on the Ultra.
                    ToolbarItem(placement: .bottomBar) { composer { let t = text; text = ""; await chat.send(t) } }
                    if chat.isRunning {
                        ToolbarItem(placement: .topBarTrailing) { Button { Task { await chat.stop() } } label: { Image(systemName: "stop.fill") }.tint(.red) }
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else { ProgressView() }
        }
        .task {
            guard let rt = model.runtime else { return }
            profile = model.sessions.first { $0.id == storedID }?.profile
            title = model.sessions.first { $0.id == storedID }?.displayTitle ?? "Chat"
            if model.socketUsable {
                do { chat = try await rt.openChat(storedID: storedID, title: nil, profile: profile); return } catch { /* fall through */ }
            }
            // No socket yet (the Bluetooth link never opens one): show the last messages over
            // REST at once instead of waiting on a socket that may never come, and keep polling.
            // The 4 s wait before the first byte was most of the "long time to load".
            proxied = true
            await pollLoop(rt)
        }
    }

    /// The message field, Talk and the send button, one row on the bottom edge. While Talk
    /// works the row says what it is doing instead of the field.
    private func composer(send: @escaping () async -> Void) -> some View {
        HStack(spacing: 6) {
            if talk.isBusy {
                Text(talk.phaseText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                TextField("Message", text: $text)
            }
            if let chat {
                // While the reply is awaited the same button gives the wait up (the reply still
                // lands in the chat); before, only the header's Stop or the 180 s limit ended it.
                Button { talk.tap(chat: chat) } label: {
                    Image(systemName: talk.phase == .recording ? "stop.circle.fill" : talk.phase == .speaking ? "speaker.slash.circle.fill" : talk.phase == .waiting ? "xmark.circle.fill" : "mic.circle.fill")
                        .font(.title3)
                        .symbolEffect(.pulse, isActive: talk.phase == .recording || talk.phase == .waiting)
                }
                .buttonStyle(.plain)
                .foregroundStyle(talk.phase == .recording ? Color.red : talk.isBusy ? Color.accentColor : Color.secondary)
                .disabled(talk.phase == .transcribing)
                .accessibilityLabel(talk.phase == .recording ? "Stop and send" : talk.phase == .speaking ? "Stop speaking" : talk.phase == .waiting ? "Stop waiting for the reply" : "Talk")
            }
            if !talk.isBusy {
                Button { Task { await send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .buttonStyle(.plain).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .foregroundStyle(text.isEmpty ? Color.secondary : Color.accentColor)
            }
        }
        .onChange(of: talk.error) { _, e in if let e { error = nil; chat?.banner = e; talk.error = nil } }
    }

    // MARK: REST + phone proxy

    private var proxiedBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if items.count >= shown {
                        Button { shown += 20; Task { if let rt = model.runtime { await refreshProxied(rt) } } } label: { Label("Show earlier", systemImage: "arrow.up.circle") }.font(.caption)
                    }
                    ForEach(items.suffix(shown)) { item in WatchTranscriptRow(item: item, profile: profile).id(item.id) }
                    if running { Text(statusText.isEmpty ? "Working…" : statusText).font(.caption2).foregroundStyle(.secondary) }
                    ForEach(Array(cards.enumerated()), id: \.offset) { _, c in proxiedCard(c) }
                    if let error { Text(error).font(.caption2).foregroundStyle(.red) }
                    Color.clear.frame(height: 1).id("bottom")
                }
            }
            .defaultScrollAnchor(.bottom)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .task { try? await Task.sleep(for: .milliseconds(350)); proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: items.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .bottomBar) { composer { await proxySend() } }
            if running {
                ToolbarItem(placement: .topBarTrailing) { Button { Task { _ = try? await model.connectivity.request(["op": "stop", "session": storedID, "profile": profile ?? ""]) } } label: { Image(systemName: "stop.fill") }.tint(.red) }
            }
        }
    }

    @ViewBuilder private func proxiedCard(_ c: [String: Any]) -> some View {
        let id = c["id"] as? String ?? ""; let method = c["method"] as? String ?? ""
        VStack(alignment: .leading, spacing: 8) {
            Label(method == "approval" ? "Approval" : "Needs an answer", systemImage: method == "approval" ? "checkmark.shield" : "questionmark.bubble").font(.caption.weight(.semibold))
            Text(c["text"] as? String ?? "").font(.footnote).lineLimit(6)
            if method == "approval" {
                HStack {
                    Button("Once") { Task { await proxyChoice(id, "once") } }.tint(.green)
                    Button("Deny") { Task { await proxyChoice(id, "deny") } }.tint(.red)
                }
                HStack { Button("Session") { Task { await proxyChoice(id, "session") } }; Button("Always") { Task { await proxyChoice(id, "always") } } }.font(.caption)
            } else {
                Button("Answer with the message field") { Task { await proxyAnswer(id) } }.disabled(text.isEmpty)
            }
        }
        .padding(10).background(.orange.opacity(0.15), in: .rect(cornerRadius: 14))
    }

    private func pollLoop(_ rt: GatewayRuntime) async {
        while !Task.isCancelled {
            // The socket came up after this chat opened (Wi-Fi joined, or it was still
            // connecting): move to the live path instead of polling for the rest of the visit.
            if model.socketUsable, let live = try? await rt.openChat(storedID: storedID, title: nil, profile: profile) {
                chat = live
                proxied = false
                return
            }
            await refreshProxied(rt)
            try? await Task.sleep(for: .seconds(running ? 2 : 6))
        }
    }

    private func refreshProxied(_ rt: GatewayRuntime) async {
        if let r: JSONValue = try? await rt.api.get("/api/sessions/\(storedID)/messages", query: [URLQueryItem(name: "order", value: "latest"), URLQueryItem(name: "limit", value: String(shown + 2))], profile: profile ?? rt.selectedProfile) {
            let msgs = (r["messages"]?.arrayValue ?? r.arrayValue ?? []).compactMap { try? $0.decode(TranscriptMessage.self) }
            let built = msgs.enumerated().compactMap { TranscriptItem.fromHistory($1, index: $0) }
            let sorted = built.sorted { $0.timestamp < $1.timestamp }
            // Only replace what changed: a fresh array every poll re-laid out every row.
            if sorted.map(\.id) != items.map(\.id) || sorted.last?.kind != items.last?.kind { items = sorted }
        }
        if let reply = try? await model.connectivity.request(["op": "cards", "session": storedID, "profile": profile ?? ""]) {
            cards = reply["cards"] as? [[String: Any]] ?? []
            running = reply["running"] as? Bool ?? false
            statusText = reply["status"] as? String ?? ""
            error = nil
        }
    }

    private func proxySend() async {
        let t = text; text = ""
        do {
            let r = try await model.connectivity.request(["op": "prompt", "session": storedID, "profile": profile ?? "", "text": t])
            if r["ok"] as? Bool != true { error = r["error"] as? String ?? "The phone could not send it." } else { running = true; error = nil }
            items.append(TranscriptItem(id: "local-\(UUID().uuidString)", kind: .user(text: t, attachments: [])))
        } catch { self.error = error.localizedDescription }
    }

    private func proxyChoice(_ card: String, _ choice: String) async {
        do { _ = try await model.connectivity.request(["op": "approval", "session": storedID, "profile": profile ?? "", "card": card, "choice": choice]); cards.removeAll { ($0["id"] as? String) == card } }
        catch { self.error = error.localizedDescription }
    }

    private func proxyAnswer(_ card: String) async {
        let t = text; text = ""
        do { _ = try await model.connectivity.request(["op": "answer", "session": storedID, "profile": profile ?? "", "card": card, "text": t]); cards.removeAll { ($0["id"] as? String) == card } }
        catch { self.error = error.localizedDescription }
    }
}

struct WatchTranscriptRow: View {
    var item: TranscriptItem
    /// The bot the reply came from: a small face beside each reply, as on the phone.
    var profile: String? = nil
    var body: some View {
        switch item.kind {
        case .user(let t, _):
            if let notice = WatchNotice.parse(t) {
                // Another bot writing in, or the gateway reporting: a quiet line, not your own bubble.
                VStack(alignment: .leading, spacing: 2) {
                    Label(notice.title, systemImage: notice.symbol).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    if !notice.body.isEmpty { Text(notice.body).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                }
            } else {
                HStack { Spacer(minLength: 24); Text(t).font(.footnote).padding(8).background(Color.accentColor, in: .rect(cornerRadius: 12)).foregroundStyle(.white) }
            }
        case .assistant(let raw, _, let streaming):
            // Pictures the bot sent are names here, not paths: the MEDIA: line stays out.
            let t = MediaScan.textWithoutMedia(raw)
            HStack(alignment: .bottom, spacing: 4) {
                if let profile { WatchBotFace(profile: profile, size: 16).accessibilityHidden(true) }
                // Bold, italics, code and links once the reply is whole; plain while it streams.
                Group {
                    if streaming { Text(t.isEmpty ? "…" : t) } else { Text(WatchMarkdown.inline(t)) }
                }
                .font(.footnote).padding(8).background(Color.gray.opacity(0.25), in: .rect(cornerRadius: 12))
                Spacer(minLength: 12)
            }
        case .tool(let a):
            Label("\(a.displayName)\(a.summary.map { " · \($0)" } ?? "")", systemImage: a.status == .done ? "checkmark.circle" : a.status == .failed ? "xmark.circle" : "gear")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        case .system(let t, let sym):
            Label(t, systemImage: sym).font(.caption2).foregroundStyle(.secondary)
        case .error(let t):
            Label(t, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.red)
        case .subagent(let a):
            Label(a.detailLine.map { "\(a.goal) · \($0)" } ?? a.goal, systemImage: "person.2").font(.caption2).foregroundStyle(.secondary)
        case .steer(let t, _):
            Text(t).font(.caption).padding(6).background(Color.gray.opacity(0.3), in: .rect(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// A message in the user's seat that is not the user's: another bot, or the gateway.
struct WatchNotice {
    var title: String
    var body: String
    var symbol: String

    /// Cheap checks first: almost every message is an ordinary one.
    static func parse(_ text: String) -> WatchNotice? {
        let t = text.drop { $0 == " " || $0 == "\n" }
        if t.hasPrefix("Message from") || t.hasPrefix("[Message from agent") {
            if let m = AgentMessage.parse(text) { return WatchNotice(title: "Message from \(m.sender)", body: m.body, symbol: "bubble.left.and.bubble.right") }
        } else if t.hasPrefix("[") {
            if let n = InjectedNote.parse(text) { return WatchNotice(title: n.title, body: "", symbol: "gearshape.2") }
        }
        return nil
    }
}

/// Inline markdown for finished replies, parsed once per text.
@MainActor
enum WatchMarkdown {
    private static var cache: [Int: AttributedString] = [:]

    static func inline(_ text: String) -> AttributedString {
        let key = text.hashValue
        if let hit = cache[key] { return hit }
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(text)
        if cache.count > 80 { cache.removeAll(keepingCapacity: true) }
        cache[key] = parsed
        return parsed
    }
}

/// Approval / clarify / secret cards, sized for a wrist.
struct WatchCardView: View {
    var chat: ChatSession
    var card: PendingCard
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let a = card.approval {
                Label("Approval", systemImage: "checkmark.shield").font(.caption.weight(.semibold))
                Text(a.description?.isEmpty == false ? a.description! : (a.command ?? "")).font(.footnote).lineLimit(6)
                HStack {
                    Button("Once") { Task { await chat.respond(card: card, result: ["choice": "once"]) } }.tint(.green)
                    Button("Deny") { Task { await chat.respond(card: card, result: ["choice": "deny"]) } }.tint(.red)
                }
                HStack {
                    Button("Session") { Task { await chat.respond(card: card, result: ["choice": "session"]) } }
                    Button("Always") { Task { await chat.respond(card: card, result: ["choice": "always"]) } }
                }
                .font(.caption)
            } else if let c = card.clarify {
                Label("Question", systemImage: "questionmark.bubble").font(.caption.weight(.semibold))
                Text(c.question ?? c.questions?.first?.question ?? "").font(.footnote)
                // Offered answers are buttons: one tap, no typing on the wrist.
                ForEach((c.choices ?? c.questions?.first?.choices ?? []).prefix(6), id: \.self) { choice in
                    Button(choice) { Task { await chat.respond(card: card, result: ["answer": .string(choice)]) } }
                        .font(.footnote)
                }
                TextField("Answer", text: $answer)
                Button("Send") { Task { await chat.respond(card: card, result: ["answer": .string(answer)]) } }.disabled(answer.isEmpty)
            } else {
                Label("Input needed", systemImage: "key").font(.caption.weight(.semibold))
                Text(card.valuePrompt?.prompt ?? card.method).font(.footnote)
                SecureField("Value", text: $answer)
                Button("Send") { Task { await chat.respond(card: card, result: ["value": .string(answer)]) } }.disabled(answer.isEmpty)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.15), in: .rect(cornerRadius: 14))
    }
}

/// Before a gateway is known: normally the phone pushes it over; a token can be typed if not.
struct WatchConnectView: View {
    @Environment(WatchModel.self) private var model
    @State private var url = ""
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "iphone.and.applewatch").font(.largeTitle).foregroundStyle(.tint)
                Text("Open Vory on your iPhone").font(.headline)
                Text(model.syncStatus).font(.caption2).foregroundStyle(.secondary)
                Text("Your gateways sync here automatically. Or enter one by hand:").font(.caption2).foregroundStyle(.secondary)
                TextField("https://hermes.example.com", text: $url).textContentType(.URL)
                SecureField("Session token", text: $token)
                Button(busy ? "Connecting…" : "Connect") { Task { await connect() } }.disabled(busy || url.isEmpty || token.isEmpty)
                if let error { Text(error).font(.caption2).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Vory")
    }

    private func connect() async {
        busy = true; defer { busy = false }
        do {
            let g = try GatewayURL.normalize(url, pathPrefix: nil)
            let conn = GatewayConnection(name: g.host, gateway: g, authMode: .sessionToken)
            try model.store.upsert(conn, secrets: GatewaySecrets(sessionToken: token))
            await model.activate(conn)
        } catch { self.error = error.localizedDescription }
    }
}

/// A small settings pane: which gateway, how the watch reaches it, and a way to re-pull the
/// credentials from the phone.
struct WatchSettingsView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let rt = model.runtime {
                    Section("Gateway") {
                        LabeledContent("Name", value: rt.connection.name)
                        LabeledContent("Link", value: model.socketUsable ? "Direct (Wi-Fi)" : "Through iPhone")
                        LabeledContent("Status", value: rt.socketState.label)
                        LabeledContent("Bot", value: model.listProfile == "*" ? "All bots" : (model.listProfile ?? rt.selectedProfile ?? "—"))
                        LabeledContent("Summaries", value: model.summaries.isEmpty ? "off on iPhone" : "\(model.summaries.count) from iPhone")
                    }
                    if model.store.connections.count > 1 {
                        // More than one saved gateway: the watch can move between them itself.
                        Section("Gateways") {
                            ForEach(model.store.connections) { c in
                                Button { Task { await model.activate(c); dismiss() } } label: {
                                    HStack {
                                        Text(c.name).lineLimit(1)
                                        Spacer()
                                        if c.id == rt.connection.id { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        Button { Task { await rt.reconnectNow() } } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                    } footer: { Text("Chats always load over HTTP. Sending and approving go through the iPhone unless the watch has its own Wi-Fi route to the gateway. Summaries and bot looks come from the iPhone.") }
                } else {
                    Section { Text("Open Vory on the iPhone once; it hands the gateway to the watch.").font(.footnote) }
                }
                Section {
                    LabeledContent("Version", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
