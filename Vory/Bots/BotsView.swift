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
    @State private var searchText = ""
    /// A bot being edited in the same sheet that creates one.
    @State private var editing: ProfileInfo?
    /// A bot whose folder is being renamed, and one about to be deleted, from its menu (#139).
    @State private var renaming: ProfileInfo?
    @State private var deleting: ProfileInfo?
    /// Rename bot… is offered only where the gateway has the route (#315).
    @State private var renameSupported = false
    @State private var path = NavigationPath()

    @Environment(\.wideLayout) private var wide
    /// The page's width as laid out, for the grid's column count.
    @State private var pageWidth: CGFloat = 0
    /// Two columns on the phone; on a wide layout as many 150 pt columns as fit, kept even so a
    /// fold down the middle (the Duo's book posture) falls between cards.
    private var columns: [GridItem] {
        wide ? EvenColumns.items(EvenColumns.count(width: min(pageWidth, 720), minimum: 150, spacing: 18), spacing: 18)
             : EvenColumns.items(2, spacing: 14)
    }

    /// Press and hold a bot: its settings page (colour, look, description, model, instructions).
    struct BotSettingsRoute: Hashable { var profile: String }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                pageContent
                    // Cards the size of the phone's, in a column, not pills the width of the window.
                    .readingColumn(720)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
            }
            .onScrollPhaseChange { _, phase in BotAmbient.shared.scrolling = phase != .idle }
            .navigationTitle("Bots")
            .pageSearchable(text: $searchText, prompt: "Search bots")
            .tabRoot(.bots)
            .background(InteractivePopEnabler())
            .overlay {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-vory-shape-grid") { ShapeSeatGrid() }
                if ProcessInfo.processInfo.arguments.contains("-vory-motion-demo") { MotionDemoView() }
                // The measuring scene: six bots on screen, one of them working.
                if ProcessInfo.processInfo.arguments.contains("-vory-motion-bench") { MotionDemoView(bench: true) }
                #endif
            }
            .pageToolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // No New bot in the demo (#494): its look editor wrote the person's own bot's look.
                    if !MorphTopBar.active(model), !model.isInDemo { Button { showNewBot = true } label: { Image(systemName: "plus") }.accessibilityLabel("New bot") }
                }
            }
            .sheet(isPresented: $showNewBot) { if let rt = model.runtime { NewBotSheet(runtime: rt).sheetFrame().withAppModel() } }
            .sheet(item: $editing) { p in if let rt = model.runtime { NewBotSheet(runtime: rt, editing: p).sheetFrame().withAppModel() } }
            .sheet(item: $renaming) { p in BotRenameSheet(profileName: p.name) { _ in renaming = nil }.sheetFrame().withAppModel() }
            .confirmationDialog(BotDelete.question(deleting?.label ?? "this bot"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { p in
                Button("Delete bot", role: .destructive) { Task { await delete(p) } }
            } message: { _ in Text(BotDelete.consequence) }
            .navigationDestination(for: ProfileInfo.self) { BotDetailView(profile: $0).pushedPage() }
            .navigationDestination(for: BotSettingsRoute.self) { r in ProfileCardView(profileName: r.profile).untitledPage() }
            .navigationDestination(for: Room.self) { RoomView(room: $0).pushedPage() }
            .navigationDestination(for: ChatRoute.self) { ConversationView(route: $0).pushedPage() }
            .reloadable { await load() }
            .task(id: model.runtime?.connection.id) { await load() }
            .onChange(of: model.pageRequest) { _, r in
                guard let r, r.kind == .botsNewBot else { return }
                model.pageRequest = nil; showNewBot = !model.isInDemo
            }
        }
    }

    /// The grid of bots and the group chats under it.
    @ViewBuilder private var pageContent: some View {
        if let rt = model.runtime {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(Array(rt.profiles.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) || $0.label.localizedCaseInsensitiveContains(searchText) }.enumerated()), id: \.element.id) { i, p in
                    // The card's tap opens the bot (the same push as a link; on the Mac, its
                    // settings) and its face reacts on the phone, a blink and a small bounce. A
                    // tap gesture beside a link's own lost the link's tap on the card's glass pill.
                    Button {
                        #if os(macOS)
                        // The Mac: a click opens the bot's settings (its look, instructions and
                        // model); its chats and the rest are a right-click away (Matt, 2026-10-13).
                        path.append(BotSettingsRoute(profile: p.name))
                        #else
                        BotAmbient.shared.tap(profile: p.name)
                        // The push covers the card at once: the bot page's face plays it as it lands.
                        BotAmbient.shared.markArrival(profile: p.name)
                        path.append(p)
                        #endif
                    } label: {
                        BotCard(profile: p, isActive: rt.selectedProfile == p.name,
                                working: rt.chats.contains { $0.profileName == p.name && $0.isRunning },
                                slot: i, slots: rt.profiles.count)
                    }
                    .buttonStyle(.plain)
                    // VoiceOver: the menu's items as the card's actions, from the same list.
                    .accessibilityActions { botActions(p, rt) }
                    .accessibilityIdentifier("bots.card.\(p.name)")
                    // Press and hold (a right-click on the Mac): the bot's menu. The … that also
                    // opened it is gone (Matt on 1.5 (21): "just press and hold").
                    .modifier(BotCardLift(profile: p.name))
                    .contextMenu { botActions(p, rt) }
                }
            }
            .padding(.horizontal, 16).padding(.top, 18)
            if rt.profiles.isEmpty {
                Text("No profiles reported by this gateway.").foregroundStyle(.secondary).font(.footnote).padding()
            }
            Text("Each bot is a Hermes profile: its own SOUL.md, model and sessions. \(DeviceWords.Tap) one for its chats.")
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

    /// Everything the Bots page does to one bot, in one menu (#139): what to do with it, then
    /// changing it, then deleting it, last and in red. The default bot's folder is fixed, so it
    /// has neither Rename nor Delete (Edit Bot says why).
    @ViewBuilder private func botActions(_ p: ProfileInfo, _ rt: GatewayRuntime) -> some View {
        Button { path.append(ChatRoute(storedID: nil, title: nil, profile: p.name)) } label: { Label("New chat", systemImage: "square.and.pencil") }
        Button { path.append(p) } label: { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
        if rt.selectedProfile != p.name {
            Button { rt.selectedProfile = p.name } label: { Label("Make active", systemImage: "checkmark.circle") }
        }
        Divider()
        // Not in the demo (#494): Edit Bot has the look editor, which wrote the person's own bot's look.
        if !rt.isEphemeral { Button { editing = p } label: { Label("Edit bot…", systemImage: "pencil") } }
        if renameSupported, p.isDefault != true {
            Button { renaming = p } label: { Label("Rename bot…", systemImage: "folder.badge.gearshape") }
        }
        Button { path.append(BotSettingsRoute(profile: p.name)) } label: { Label("Bot settings", systemImage: "slider.horizontal.3") }
        if p.isDefault != true {
            Divider()
            Button(role: .destructive) { deleting = p } label: { Label("Delete bot…", systemImage: "trash") }
        }
    }

    private func delete(_ p: ProfileInfo) async {
        guard let rt = model.runtime else { return }
        do { try await BotDelete.delete(p.name, runtime: rt); error = nil } catch { self.error = error.localizedDescription }
    }

    private func load() async {
        guard let rt = model.runtime else { return }
        if rt.profiles.isEmpty { await rt.loadProfiles() }
        renameSupported = await BotRename.supported(on: rt.api)
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
    /// From the stored looks this view reads, so a changed shape re-seats it: read from the store
    /// directly, the card kept the old shape's seat (a cloud changed to a circle sat 10 pt low,
    /// over its own name; Matt on 1.5 (17): "it now broke the look").
    private var overlap: CGFloat {
        Self.overlap(shape: BotAvatarStore.choice(for: profile.name, overrides: BotLookMaps.map(avatarsRaw)).spec(hex: "").shape)
    }
    static func overlap(shape: String) -> CGFloat { 10 + 78 * BotFace.seatDrop(shape) }

    var body: some View {
        VStack(spacing: -overlap) {
            // The bot sits on the pill, its base a few points over the top edge.
            // Only a working bot moves (the battery rule); while the page scrolls the eyes follow
            // the scroll (BotAmbient's gaze), nothing else (decision C).
            BotAvatar(profile: profile.name, size: 78, active: working,
                      mood: BotFaceView.Mood(profile: profile.name, followsTilt: true, groupIndex: slot, groupCount: slots))
                .zIndex(1)
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Text(profile.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if isActive { Circle().fill(Color.vory).frame(width: 6, height: 6).accessibilityLabel("active") }
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

/// A bot card's outline: the bot's own silhouette over its name pill. Its press and hold lifts
/// just the bot and its name; the card's rectangle lifted on a light platter read as a window
/// behind it (Matt on 1.5 (21)).
struct BotCardOutline: Shape {
    /// The body at rest; nil for a photo, a circle.
    var head: BotBodyShape?
    var overlap: CGFloat
    func path(in rect: CGRect) -> Path {
        let face = CGRect(x: rect.midX - 39, y: rect.minY, width: 78, height: 78)
        let pill = CGRect(x: rect.minX, y: face.maxY - overlap, width: rect.width, height: rect.maxY - (face.maxY - overlap))
        return (head?.path(in: face) ?? Path(ellipseIn: face)).union(Path(roundedRect: pill, cornerRadius: pill.height / 2))
    }
}

/// The card's press-and-hold preview in its own outline (the phone; the Mac's right-click has no
/// preview).
private struct BotCardLift: ViewModifier {
    let profile: String
    @AppStorage(BotAvatarStore.storageKey) private var avatarsRaw = ""
    func body(content: Content) -> some View {
        #if os(iOS)
        let choice = BotAvatarStore.choice(for: profile, overrides: BotLookMaps.map(avatarsRaw))
        let spec = choice.spec(hex: "")
        content.contentShape(.contextMenuPreview, BotCardOutline(head: choice == .photo ? nil : BotBodyShape(spec: spec, time: 0, active: false),
                                                                  overlap: BotCard.overlap(shape: spec.shape)))
        #else
        content
        #endif
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
    /// Six bots at rest and one working: the scene the CPU and frame time are measured on.
    var bench = false
    private static let benchCells: [Cell] = [
        Cell(id: "working · blob", spec: BotLookSpec(shape: "blob", eyes: "curious", hex: "#E07A5F"), state: .working, active: true),
        Cell(id: "idle · triangle", spec: BotLookSpec(shape: "triangle", eyes: "bold", hex: "#F5A524"), state: .idle, active: false),
        Cell(id: "idle · pill", spec: BotLookSpec(shape: "pill", eyes: "wide", hex: "#F4F4F5", finish: "glass"), state: .idle, active: false),
        Cell(id: "idle · cloud", spec: BotLookSpec(shape: "cloud", eyes: "classic", hex: "#4C8DFF"), state: .idle, active: false),
        Cell(id: "idle · circle", spec: BotLookSpec(shape: "circle", eyes: "classic", hex: "#111111", finish: "glass"), state: .idle, active: false),
        Cell(id: "idle · drop", spec: BotLookSpec(shape: "drop", eyes: "tiny", hex: "#2BB5A0"), state: .idle, active: false),
        Cell(id: "idle · hexagon", spec: BotLookSpec(shape: "hexagon", eyes: "round", hex: "#8E6CFF"), state: .idle, active: false),
    ]
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
                    ForEach(bench ? Self.benchCells : cells) { c in
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
                    Button("Finish spin (all)") { for c in (bench ? Self.benchCells : cells) { BotAmbient.shared.turnFinished(profile: "demo-\(c.id)") } }.buttonStyle(.glass)
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
            SettingsList {
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
                                    .foregroundStyle(members.contains(p.name) ? Color.vory : Color.secondary)
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
        SettingsList {
            Section {
                NavigationLink { ProfileCardView(profileName: profile.name).pushedPage() } label: {
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
                    .contextMenu { Button(role: .destructive) { pendingDelete = s } label: { Label("Delete", systemImage: "trash") } } preview: { SessionPreview(session: s).withAppModel() }
                }
            } header: { Text("Chats") }
        }
        .navigationTitle(profile.label)
        .navigationBarTitleDisplayMode(.inline)
        // Landed from a card's tap: the bot's face here plays the reaction the push covered.
        .background(ArrivalProbe(profile: profile.name))
        .onAppear { model.composeProfile = profile.name }
        .onDisappear { if model.composeProfile == profile.name { model.composeProfile = nil } }
        // The compose circle in the tab bar, while this bot's page is in front: a chat with it.
        .onChange(of: model.newChatRequest) { _, r in
            guard r != nil, model.selectedTab == .bots, model.composeProfile == profile.name else { return }
            composing = true
        }
        .navigationDestination(isPresented: $composing) { ConversationView(route: ChatRoute(storedID: nil, title: nil, profile: profile.name)).pushedPage() }
        .reloadable { await load() }
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
        // A refusal is said; swallowed, the chat came back with the list as if never deleted (#467).
        var failure: String?
        do { try await SessionMutation.delete(rt.api, id: s.id, profile: profile.name) }
        catch { failure = SessionMutation.message(for: error) ?? error.localizedDescription }
        await load()
        if let failure { error = "Could not delete \u{201C}\(s.displayTitle)\u{201D}: \(failure)" }
    }
}

struct RoomView: View {
    @Environment(\.colorScheme) private var colorScheme
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
    @State private var showMembers = false
    @Environment(\.dismiss) private var dismiss
    /// One thread per room composer; the gateway wants the same id on every message.
    private let threadID = "main"

    /// Which rows draw: the human's messages as blue bubbles, the bots' as grey ones with the
    /// bot in front, room activity as a quiet line (typing becomes the bubble below instead, and
    /// "settled", which the gateway files after every exchange, says nothing the thread does
    /// not); everything else stays out of the way.
    private var shown: [RoomEvent] {
        events.filter { $0.kind.hasPrefix("message.") || ($0.kind == "room.activity" && !Self.isTyping($0) && Self.status(of: $0) != "settled") }
    }

    private static func status(of ev: RoomEvent) -> String {
        (ev.payload["status"]?.stringValue ?? ev.payload["state"]?.stringValue ?? ev.payload["text"]?.stringValue ?? "").lowercased()
    }
    private static func isTyping(_ ev: RoomEvent) -> Bool {
        let s = status(of: ev); return s.contains("typing") || s.contains("thinking") || s.contains("working") || s.contains("composing")
    }
    /// What the room's log says about who is working, read when the log changes (in `load`), not
    /// in the body: every keystroke in the composer runs the body again.
    @State private var activity = GroupActivity.Reading()
    /// Who is working: the bots the room's log says are on a turn now (`GroupActivity`).
    private var typing: [RoomMember] { activity.working() }

    var body: some View {
        let working = typing
        thread(working: working)
            // The group's own header: its bots over its name, and the member list a tap away.
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                GroupChatHeader(room: room, working: working, onBack: { dismiss() }, onMembers: { showMembers = true })
            }
            // The bar is hidden, which switches off the edge swipe back; put it back.
            .background(InteractivePopEnabler())
            #else
            .pageToolbar {
                ToolbarItem(placement: .principal) {
                    GroupToolbarTitle(room: room, working: working) { showMembers = true }
                }
            }
            .navigationSubtitle(GroupActivity.names(room.members))
            #endif
            .sheet(isPresented: $showMembers) { GroupMembersSheet(room: room, working: working).sheetFrame().withAppModel() }
    }

    private func thread(working typing: [RoomMember]) -> some View {
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
                                    .background(Color.vory, in: MessageBubbleShape(side: .trailing))
                            }
                            .roomBubble(.trailing)
                        case _ where ev.kind.hasPrefix("message."):
                            let member = ev.payload["member_id"]?.stringValue ?? ev.actor.id
                            let profile = room.members.first { $0.memberId == member || $0.handle == member }?.profile ?? member
                            HStack(alignment: .bottom, spacing: 10) {
                                // A still, like the one-to-one thread's rows: an earlier message's
                                // face neither blinks nor spins (the battery rule).
                                Image(uiImage: BotAvatarImage.cached(profile: profile, size: 28, scheme: colorScheme)).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(room.members.first { $0.memberId == member || $0.handle == member }?.displayName ?? member).font(.caption2).foregroundStyle(.secondary)
                                    MarkdownView(text: body)
                                        .padding(.horizontal, 14).padding(.vertical, 9)
                                        .background(Color(.systemGray5), in: MessageBubbleShape(side: .leading))
                                }
                                Spacer(minLength: 40)
                            }
                            .roomBubble(.leading)
                        default:
                            Text(body.isEmpty ? ev.kind : body).font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 2)
                        }
                    }
                    .id("rows")
                    // Whoever is working: their bot (their bots, side by side) beside one typing
                    // bubble, with their names over it. It fades in on its own; nothing else in
                    // the thread is animated with it (an animation of the whole thread slid the
                    // rows under a message that arrived in the same update).
                    if !typing.isEmpty {
                        GroupTypingRow(members: typing)
                            .transition(ChatRowTransition.fadeIn)
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    Color.clear.frame(height: 0).id("bottom")
                }
                .padding()
                // The same reading column as a single chat on a wide layout.
                .readingColumn(ChatStyle.readingColumn)
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
                .readingColumn(ChatStyle.readingColumn)
                #if os(macOS)
                .textFieldStyle(.plain)
                // Return sends, as in a single chat.
                .onSubmit { Task { await send() } }
                #endif
            }
            .onChange(of: events.count) { _, _ in withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) } }
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
            let changed = cursor == 0 || !r.events.isEmpty
            if cursor == 0 { events = r.events } else { events.append(contentsOf: r.events) }
            if changed { activity = GroupActivity.read(members: room.members, events: events) }
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


private extension View {
    /// A room bubble's share of the reading column on a wide layout, on its side; the phone's
    /// own width is the limit.
    func roomBubble(_ side: Alignment) -> some View { modifier(RoomBubbleWidth(side: side)) }
}

private struct RoomBubbleWidth: ViewModifier {
    @Environment(\.wideLayout) private var wide
    let side: Alignment
    func body(content: Content) -> some View {
        content.frame(maxWidth: wide ? ChatStyle.readingColumn * 0.72 : .infinity, alignment: side).frame(maxWidth: .infinity, alignment: side)
    }
}
