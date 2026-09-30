import SwiftUI
import VoryCore

/// Bots are the gateway's profiles: each is an agent with its own instructions, model and
/// sessions. A bot's chats are just sessions filtered to that profile; hosted group rooms
/// (`groups.*`) sit underneath when the gateway offers them.
struct BotsView: View {
    @Environment(AppModel.self) private var model
    @State private var capabilities: GroupsCapabilities?
    @State private var rooms: [Room] = []
    @State private var error: String?
    @State private var showNewBot = false
    @State private var path = NavigationPath()

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    /// Press and hold a bot: its settings page (colour, look, description, model, instructions).
    struct BotSettingsRoute: Hashable { var profile: String }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if let rt = model.runtime {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(Array(rt.profiles.enumerated()), id: \.element.id) { i, p in
                            NavigationLink(value: p) {
                                BotCard(profile: p, isActive: rt.selectedProfile == p.name,
                                        working: rt.chats.contains { $0.profileName == p.name && $0.isRunning },
                                        slot: i, slots: rt.profiles.count)
                            }
                            .buttonStyle(.plain)
                            // Press and hold: what you would otherwise dig for.
                            .contextMenu {
                                Button { path.append(ChatRoute(storedID: nil, title: nil, profile: p.name)) } label: { Label("New chat", systemImage: "square.and.pencil") }
                                Button { path.append(p) } label: { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                                Button { path.append(BotSettingsRoute(profile: p.name)) } label: { Label("Bot settings", systemImage: "slider.horizontal.3") }
                                if rt.selectedProfile != p.name {
                                    Button { rt.selectedProfile = p.name } label: { Label("Make active", systemImage: "checkmark.circle") }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 18)
                    if rt.profiles.isEmpty {
                        Text("No profiles reported by this gateway.").foregroundStyle(.secondary).font(.footnote).padding()
                    }
                    Text("Each bot is a Hermes profile: its own SOUL.md, model and sessions. Tap one for its chats.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 28).padding(.top, 14)
                    if capabilities != nil, !rooms.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Group chats").font(.title3.weight(.semibold)).padding(.horizontal, 20).padding(.top, 26)
                            if capabilities?.driver == false {
                                Label("The room driver is not running on the gateway; group chats are listed but the bots will not answer in them.", systemImage: "exclamationmark.triangle")
                                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
                            }
                            ForEach(rooms) { room in
                                NavigationLink(value: room) { RoomCard(room: room) }.buttonStyle(.plain)
                            }
                            Text("Start one from the compose button on Chats by adding more than one bot.")
                                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote).padding() }
                } else {
                    ContentUnavailableView("No gateway selected", systemImage: "antenna.radiowaves.left.and.right.slash")
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in BotAmbient.shared.scrolled(dy: new - old) }
            .navigationTitle("Bots")
            .tabRoot(.bots)
            .background(InteractivePopEnabler())
            .overlay {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-vory-shape-grid") { ShapeSeatGrid() }
                if ProcessInfo.processInfo.arguments.contains("-vory-motion-demo") { MotionDemoView() }
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewBot = true } label: { Image(systemName: "plus") }.accessibilityLabel("New bot")
                }
            }
            .sheet(isPresented: $showNewBot) { if let rt = model.runtime { NewBotSheet(runtime: rt) } }
            .navigationDestination(for: ProfileInfo.self) { BotDetailView(profile: $0) }
            .navigationDestination(for: BotSettingsRoute.self) { r in ProfileCardView(profileName: r.profile).navigationTitle("").navigationBarTitleDisplayMode(.inline) }
            .navigationDestination(for: Room.self) { RoomView(room: $0) }
            .navigationDestination(for: ChatRoute.self) { ConversationView(route: $0) }
            .refreshable { await load() }
            .task(id: model.runtime?.connection.id) { await load() }
        }
    }

    private func load() async {
        guard let rt = model.runtime else { return }
        if rt.profiles.isEmpty { await rt.loadProfiles() }
        capabilities = try? (await rt.rpc("groups.capabilities")).decode()
        guard capabilities != nil else { rooms = []; return }
        do {
            let r: GroupsListResult = try await rt.rpc("groups.list", ["limit": 50]).decode()
            rooms = r.rooms.filter { $0.disbandedAt == nil }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

/// A bot on the Bots page: the bot floating above a glass pill with its name and model, like the
/// header of its chat. It blinks and glances on its own; while it works it moves.
struct BotCard: View {
    var profile: ProfileInfo
    var isActive: Bool
    var working: Bool
    /// This card's turn in the grid: only one bot moves its body per five-second block.
    var slot = 0
    var slots = 1

    private var ambient: BotAmbient { BotAmbient.shared }
    @AppStorage(BotAvatarStore.storageKey) private var avatarsRaw = ""
    @AppStorage(BotAvatarStore.glassAllKey) private var glassAll = false
    /// Every shape ends at a different height (a pill well above the frame, a blob near its
    /// bottom); the overlap is measured from the shape's real base so each bot sits the same.
    private var overlap: CGFloat {
        let shape = BotAvatarStore.choice(for: profile.name).spec(hex: "").shape
        return 10 + 78 * BotFace.seatDrop(shape)
    }

    var body: some View {
        VStack(spacing: -overlap) {
            // The bot sits on the pill, its base a few points over the top edge.
            // Plays while the page scrolls (random per bot), settles when it stops.
            BotAvatar(profile: profile.name, size: 78, active: working || (ambient.scrolling && ambient.enabled),
                      mood: BotFaceView.Mood(profile: profile.name, followsTilt: true, groupIndex: slot, groupCount: slots))
                .zIndex(1)
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Text(profile.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if isActive { Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityLabel("active") }
                }
                Text(profile.model.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? "no model")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 7)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.label), \(profile.model ?? "no model")\(isActive ? ", active" : "")\(working ? ", working" : "")")
    }
}

#if DEBUG
/// Every body shape on its pill, for checking that each one sits the same.
private struct ShapeSeatGrid: View {
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(BotLookSpec.shapes, id: \.self) { shape in
                    VStack(spacing: -(10 + 78 * BotFace.seatDrop(shape))) {
                        BotFaceView(spec: BotLookSpec(shape: shape, eyes: "classic", hex: "#0A84FF", finish: "glass"), size: 78, active: false, mood: BotFaceView.Mood(profile: "grid-\(shape)"))
                            .zIndex(1)
                        VStack(spacing: 2) { Text(shape).font(.subheadline.weight(.semibold)); Text("model").font(.caption2).foregroundStyle(.secondary) }
                            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 7).frame(maxWidth: .infinity)
                            .glassEffect(.regular, in: .capsule)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
    }
}
#endif

/// Every pose the bots know, side by side: the working routines on a few shapes and finishes,
/// then each state held. Tap a bot for the tap turn. Settings › Bots › Preview motion, and
/// DEBUG `-vory-motion-demo` over the Bots tab.
struct MotionDemoView: View {
    private struct Cell: Identifiable { let id: String; let spec: BotLookSpec; let state: BotFace.State; let active: Bool }
    private let cells: [Cell] = [
        Cell(id: "working · blob", spec: BotLookSpec(shape: "blob", eyes: "curious", hex: "#E07A5F"), state: .working, active: true),
        Cell(id: "working · triangle", spec: BotLookSpec(shape: "triangle", eyes: "bold", hex: "#F5A524"), state: .working, active: true),
        Cell(id: "working · pill", spec: BotLookSpec(shape: "pill", eyes: "wide", hex: "#F4F4F5", finish: "glass"), state: .working, active: true),
        Cell(id: "working · cloud", spec: BotLookSpec(shape: "cloud", eyes: "classic", hex: "#4C8DFF", finish: "glass"), state: .working, active: true),
        Cell(id: "working · circle", spec: BotLookSpec(shape: "circle", eyes: "classic", hex: "#111111", finish: "glass"), state: .working, active: true),
        Cell(id: "working · drop", spec: BotLookSpec(shape: "drop", eyes: "tiny", hex: "#2BB5A0"), state: .working, active: true),
        Cell(id: "thinking", spec: BotLookSpec(shape: "circle", eyes: "classic", hex: "#111111", finish: "glass"), state: .thinking, active: true),
        Cell(id: "using tool", spec: BotLookSpec(shape: "square", eyes: "classic", hex: "#4C8DFF", finish: "glass"), state: .usingTool, active: true),
        Cell(id: "approval", spec: BotLookSpec(shape: "triangle", eyes: "bold", hex: "#F5A524"), state: .awaitingApproval, active: true),
        Cell(id: "error", spec: BotLookSpec(shape: "hexagon", eyes: "round", hex: "#FF453A", finish: "glass"), state: .error, active: true),
        Cell(id: "reconnecting", spec: BotLookSpec(shape: "drop", eyes: "tiny", hex: "#2BB5A0"), state: .reconnecting, active: true),
        Cell(id: "streaming", spec: BotLookSpec(shape: "blob", eyes: "classic", hex: "#BF5AF2"), state: .streaming, active: true),
        Cell(id: "guide (Vory)", spec: BotLookSpec.vory, state: .guide, active: false),
        Cell(id: "idle", spec: BotLookSpec(shape: "cloud", eyes: "sleepy", hex: "#F4F4F5"), state: .idle, active: false),
        Cell(id: "idle · curious", spec: BotLookSpec(shape: "square", eyes: "curious", hex: "#30D158"), state: .idle, active: false),
    ]
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    /// Off: the state cells drop to idle (the bodies morph back); on again: they morph in.
    @State private var holding = true
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(cells) { c in
                        let state: BotFace.State = holding || c.state == .working || c.state == .guide ? c.state : .idle
                        VStack(spacing: 6) {
                            BotFaceView(spec: c.spec, size: 72, active: c.active && (holding || c.state == .working), mood: BotFaceView.Mood(profile: "demo-\(c.id)", state: state))
                            Text(c.id).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                HStack(spacing: 12) {
                    Button(holding ? "Release states" : "Hold states") { holding.toggle() }.buttonStyle(.glass)
                    Button("Finish spin (all)") { for c in cells { BotAmbient.shared.turnFinished(profile: "demo-\(c.id)") } }.buttonStyle(.glass)
                }
                .padding(.bottom, 120)
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Preview motion")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RoomCard: View {
    var room: Room
    var body: some View {
        HStack(spacing: 12) {
            // The members' bots, overlapping like a group in Messages.
            HStack(spacing: -12) {
                ForEach(Array(room.members.prefix(3).enumerated()), id: \.offset) { _, m in
                    BotAvatar(profile: m.profile ?? m.handle ?? "?", size: 32)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(room.name).font(.body.weight(.medium)).lineLimit(1)
                Text(room.members.compactMap { $0.displayName ?? $0.handle ?? $0.profile }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .padding(.horizontal, 16)
    }
}

/// Creates a hosted group chat on the gateway for these bots; the name is what the room is called.
enum GroupChats {
    static func create(runtime: GatewayRuntime, name: String, profiles: [ProfileInfo]) async throws -> Room {
        // The gateway does not mint room ids: the client sends one (a string, letters/digits/-._:).
        let roomID = "room-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
        let list: [JSONValue] = profiles.prefix(6).map { .object(["member_id": .string($0.name), "handle": .string($0.name), "profile": .string($0.name), "display_name": .string($0.label)]) }
        let r = try await runtime.rpc("groups.create", ["room_id": .string(roomID), "name": .string(String(name.prefix(200))), "members": .array(list)])
        // Gateways answer in different shapes (the room, {room}, or an id only); the room list is
        // the one source that always has the full record, so the new room is taken from there.
        let createdID = r["room_id"]?.stringValue ?? r["room"]?["room_id"]?.stringValue ?? r["id"]?.stringValue ?? roomID
        let all: GroupsListResult = try await runtime.rpc("groups.list", ["limit": 100]).decode()
        let room = all.rooms.first { $0.roomId == createdID && !$0.roomId.isEmpty }
            ?? all.rooms.filter { $0.name == name && $0.disbandedAt == nil }.max { $0.updatedAt < $1.updatedAt }
        guard let room, !room.roomId.isEmpty else { throw HermesAPIError.transport("The gateway created the group chat but did not list it.") }
        return room
    }
}

/// "New group" the way Messages does it: a name, then tick the bots (profiles) that take part.
struct NewRoomSheet: View {
    var runtime: GatewayRuntime
    var onCreated: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: Set<String> = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Room name", text: $name)
                } footer: { Text("A hosted group chat on this gateway; every bot you add takes part in one shared thread.") }
                Section {
                    ForEach(runtime.profiles) { p in
                        Button {
                            if members.contains(p.name) { members.remove(p.name) } else { members.insert(p.name) }
                        } label: {
                            HStack(spacing: 12) {
                                BotAvatar(profile: p.name, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.label)
                                    if let d = p.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                Image(systemName: members.contains(p.name) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(members.contains(p.name) ? Color.accentColor : Color.secondary)
                            }
                        }
                        .tint(.primary)
                    }
                    if runtime.profiles.isEmpty { Text("No profiles reported by this gateway.").foregroundStyle(.secondary).font(.footnote) }
                } header: { Text("Bots") }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("New Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Creating…" : "Create") { Task { await create() } }
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || members.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func create() async {
        busy = true; defer { busy = false }
        let list: [JSONValue] = runtime.profiles.filter { members.contains($0.name) }.map {
            .object(["member_id": .string($0.name), "handle": .string($0.name), "profile": .string($0.name), "display_name": .string($0.label)])
        }
        do {
            _ = try await runtime.rpc("groups.create", ["name": .string(name.trimmingCharacters(in: .whitespaces)), "members": .array(list)])
            await onCreated()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct BotRow: View {
    var profile: ProfileInfo
    var isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            BotAvatar(profile: profile.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.label).font(.body.weight(.medium))
                    if isActive { Text("active").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.tint.opacity(0.15), in: .capsule).foregroundStyle(.tint) }
                }
                Text([profile.description, profile.model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One bot: its instructions up top, then its sessions. Opening a session switches the app's
/// selected profile to this bot first, because every session RPC is profile-scoped.
struct BotDetailView: View {
    @Environment(AppModel.self) private var model
    var profile: ProfileInfo
    @State private var sessions: [StoredSession] = []
    @State private var error: String?
    @State private var pendingDelete: StoredSession?
    @State private var composing = false

    var body: some View {
        List {
            Section {
                NavigationLink { ProfileCardView(profileName: profile.name) } label: {
                    HStack(spacing: 12) {
                        BotAvatar(profile: profile.name, size: 36)
                        Text("Profile")
                    }
                }
            }
            Section {
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                if sessions.isEmpty, error == nil {
                    Text("No chats with this bot yet.").foregroundStyle(.secondary).font(.footnote)
                }
                ForEach(sessions) { s in
                    NavigationLink(value: ChatRoute(storedID: s.id, title: s.displayTitle, profile: profile.name)) {
                        SessionRow(session: s, needsYou: model.runtime?.needsAttention.contains(s.id) ?? false, live: model.runtime?.chatForStored(s.id)?.isRunning ?? false)
                    }
                    .contextMenu { Button(role: .destructive) { pendingDelete = s } label: { Label("Delete", systemImage: "trash") } } preview: { SessionPreview(session: s) }
                }
            } header: { Text("Chats") }
        }
        .navigationTitle(profile.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.composeProfile = profile.name }
        .onDisappear { if model.composeProfile == profile.name { model.composeProfile = nil } }
        // The compose circle in the tab bar, while this bot's page is in front: a chat with it.
        .onChange(of: model.newChatRequest) { _, r in
            guard r != nil, model.selectedTab == .bots, model.composeProfile == profile.name else { return }
            composing = true
        }
        .navigationDestination(isPresented: $composing) { ConversationView(route: ChatRoute(storedID: nil, title: nil, profile: profile.name)) }
        .refreshable { await load() }
        .task { await load() }
        .alert("Delete chat?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) { if let s = pendingDelete { Task { await delete(s) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes the session and its transcript from the gateway.") }
    }

    private func load() async {
        guard let rt = model.runtime else { return }
        do {
            let r: SessionListResponse = try await rt.api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "100")], profile: profile.name)
            sessions = r.sessions
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ s: StoredSession) async {
        guard let rt = model.runtime else { return }
        if let chat = rt.chatForStored(s.id) { rt.closeChat(chat) }
        let _: JSONValue? = try? await rt.api.send("DELETE", "/api/sessions/\(s.id)", profile: profile.name, body: EmptyBody())
        await load()
    }
}

struct RoomView: View {
    @Environment(AppModel.self) private var model
    var room: Room
    /// The first message, when the chat was started from the compose sheet.
    var initialText: String? = nil
    @State private var events: [RoomEvent] = []
    @State private var text = ""
    @State private var error: String?
    @State private var cursor = 0
    @State private var loaded = false
    @State private var lastSendAt: Date = .distantPast
    /// One thread per room composer; the gateway wants the same id on every message.
    private let threadID = "main"

    /// Which rows draw: the human's messages as blue bubbles, the bots' as grey ones with the
    /// bot in front, room activity as a quiet line (typing becomes the bubble below instead);
    /// everything else stays out of the way.
    private var shown: [RoomEvent] {
        events.filter { $0.kind.hasPrefix("message.") || ($0.kind == "room.activity" && !Self.isTyping($0)) }
    }

    private static func status(of ev: RoomEvent) -> String {
        (ev.payload["status"]?.stringValue ?? ev.payload["state"]?.stringValue ?? ev.payload["text"]?.stringValue ?? "").lowercased()
    }
    private static func isTyping(_ ev: RoomEvent) -> Bool {
        let s = status(of: ev); return s.contains("typing") || s.contains("thinking") || s.contains("working") || s.contains("composing")
    }
    private func member(named id: String) -> RoomMember? {
        let k = id.lowercased()
        return room.members.first { [$0.memberId, $0.handle, $0.profile, $0.displayName].compactMap { $0?.lowercased() }.contains(k) }
    }
    private func memberKey(_ m: RoomMember) -> String { m.memberId ?? m.handle ?? m.profile ?? "" }

    /// Who is typing: from each room activity after the last thing they said — the member the
    /// payload names, or the first word of "hermes is typing…". A message from them, or a
    /// "settled"/"idle" activity, clears it.
    private var typing: [RoomMember] {
        var active: [String: RoomMember] = [:]
        for ev in events {
            if ev.kind.hasPrefix("message."), ev.kind != "message.user" {
                let who = ev.payload["member_id"]?.stringValue ?? ev.actor.id
                if let m = member(named: who) { active[memberKey(m)] = nil }
                continue
            }
            guard ev.kind == "room.activity" else { continue }
            let s = Self.status(of: ev)
            let named = ev.payload["member_id"]?.stringValue ?? ev.payload["handle"]?.stringValue ?? ev.payload["member"]?.stringValue
                ?? s.split(separator: " ").first.map(String.init) ?? ""
            let m = member(named: named)
            if Self.isTyping(ev) {
                if let m { active[memberKey(m)] = m }
            } else if s.contains("settled") || s.contains("idle") || s.contains("done") || s.contains("stopped") {
                if let m { active[memberKey(m)] = nil } else { active.removeAll() }
            }
        }
        return room.members.filter { active[memberKey($0)] != nil }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(shown) { ev in
                        let body = ev.payload["text"]?.stringValue ?? ev.payload["content"]?.stringValue ?? ev.payload["status"]?.stringValue ?? ""
                        switch ev.kind {
                        case "message.user":
                            HStack {
                                Spacer(minLength: 56)
                                Text(body).textSelection(.enabled)
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .foregroundStyle(.white)
                                    .background(Color.accentColor, in: MessageBubbleShape(side: .trailing))
                            }
                        case _ where ev.kind.hasPrefix("message."):
                            let member = ev.payload["member_id"]?.stringValue ?? ev.actor.id
                            let profile = room.members.first { $0.memberId == member || $0.handle == member }?.profile ?? member
                            HStack(alignment: .bottom, spacing: 10) {
                                BotAvatar(profile: profile, size: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(room.members.first { $0.memberId == member || $0.handle == member }?.displayName ?? member).font(.caption2).foregroundStyle(.secondary)
                                    MarkdownView(text: body)
                                        .padding(.horizontal, 14).padding(.vertical, 9)
                                        .background(Color(.systemGray5), in: MessageBubbleShape(side: .leading))
                                }
                                Spacer(minLength: 40)
                            }
                        default:
                            Text(body.isEmpty ? ev.kind : body).font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 2)
                        }
                    }
                    .id("rows")
                    // Whoever is composing: their bot, thinking, beside a typing bubble.
                    ForEach(typing, id: \.self) { m in
                        HStack(alignment: .bottom, spacing: 10) {
                            BotAvatar(profile: m.profile ?? m.handle ?? "?", size: 28, active: true, mood: BotFaceView.Mood(profile: "room-typing-\(memberKey(m))", state: .thinking))
                            TypingBubble()
                            Spacer(minLength: 40)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    Color.clear.frame(height: 0).id("bottom")
                }
                .padding()
            }
            .overlay {
                // Nothing said yet: the bots in the room, the way a new chat shows its bot.
                if shown.isEmpty, loaded, error == nil {
                    VStack(spacing: 12) {
                        HStack(spacing: -14) {
                            ForEach(Array(room.members.enumerated()), id: \.offset) { i, m in
                                // The front bot has its eyes; the ones behind it stay still.
                                BotAvatar(profile: m.profile ?? m.handle ?? "?", size: 56, mood: BotFaceView.Mood(profile: "room-\(room.roomId)-\(i)", still: i != 0))
                                    .zIndex(Double(room.members.count - i))
                            }
                        }
                        Text(room.members.compactMap { $0.displayName ?? $0.handle ?? $0.profile }.formatted(.list(type: .and)))
                            .font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                        Text("Say something to the group").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 32)
                    .transition(.opacity)
                }
            }
            // A chat: the tab bar steps aside so the composer sits at the bottom, as in a single chat.
            .hidesTabBar()
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("Message the group", text: $text, axis: .vertical).lineLimit(1...4).padding(.vertical, 6)
                    Button { Task { await send() } } label: { Image(systemName: "arrow.up").font(.body.weight(.bold)) }.buttonStyle(.glassProminent).disabled(text.isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                .padding(12)
            }
            .onChange(of: events.count) { _, _ in withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .animation(.snappy(duration: 0.25), value: typing)
        }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let t = initialText, !t.isEmpty, events.isEmpty { text = t; await send() }
            await load(); await poll()
        }
    }

    private func load() async {
        guard let rt = model.runtime else { return }
        do {
            let r: GroupsLogResult = try await rt.rpc("groups.log", ["room_id": .string(room.roomId), "since_seq": .number(Double(cursor)), "limit": 200]).decode()
            if cursor == 0 { events = r.events } else { events.append(contentsOf: r.events) }
            cursor = r.latestSeq
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    /// Quick while someone is typing or a send is fresh (replies land within seconds), lazy
    /// otherwise.
    private func poll() async {
        while !Task.isCancelled {
            let busy = !typing.isEmpty || Date().timeIntervalSince(lastSendAt) < 30
            try? await Task.sleep(for: .seconds(busy ? 1.2 : 4))
            await load()
        }
    }

    private func send() async {
        guard let rt = model.runtime else { return }
        let t = text; text = ""; lastSendAt = Date()
        // The gateway wants exactly {text, thread_id} in the payload and an identifier-shaped
        // event_id per send (letters, digits, - . _ :); it hashes the id itself.
        let eventID = "evt-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        do {
            _ = try await rt.rpc("groups.send", ["room_id": .string(room.roomId), "event_id": .string(eventID),
                                                 "payload": .object(["text": .string(t), "thread_id": .string(threadID)])])
            await load()
        } catch { self.error = error.localizedDescription }
    }
}
