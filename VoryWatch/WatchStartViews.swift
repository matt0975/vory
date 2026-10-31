import SwiftUI
import VoryCore
import WatchKit

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
            let r = try await model.askPhone(["op": "new", "profile": profile])
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
