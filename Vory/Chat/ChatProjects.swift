import SwiftUI
import VoryCore

/// One project's chats in the Chats list when it is grouped by project: projects on top,
/// each opening to its own chats, with the chats that are in none at the end.
struct ChatProjectGroup: Identifiable {
    /// "<bot>|<project id>", or `ChatProjectGroups.noneID`.
    var id: String
    var project: Project?
    /// The bot the project belongs to (projects are kept per bot on the gateway).
    var profile: String?
    var sessions: [StoredSession]
}

enum ChatProjectGroups {
    static let noneID = "__none__"
    /// How many chats a project shows before "Show all".
    static let previewCount = 5

    /// `sessions` arrive filtered and sorted, and keep that order inside each group.
    /// `own`: the selected bot's projects and which chat is in which; `others`: the same for
    /// the other bots, when every bot's chats are listed. `keepEmpty`: a project with no chat
    /// still shows (so a chat can be started in it); off while a filter narrows the list.
    static func make(_ sessions: [StoredSession], own: [Project], membership: [String: String], selected: String?,
                     others: [String: ProjectsStore.Scope] = [:], keepEmpty: Bool = true) -> [ChatProjectGroup] {
        var placed: Set<String> = []
        var out: [ChatProjectGroup] = []
        func add(_ projects: [Project], _ m: [String: String], profile: String?) {
            for p in projects where !p.isArchived {
                let mine = sessions.filter { m[$0.id] == p.id && !placed.contains($0.id) }
                placed.formUnion(mine.map(\.id))
                if !mine.isEmpty || keepEmpty { out.append(ChatProjectGroup(id: "\(profile ?? "")|\(p.id)", project: p, profile: profile, sessions: mine)) }
            }
        }
        add(own, membership, profile: selected)
        for name in others.keys.sorted() where name != selected {
            if let scope = others[name] { add(scope.projects, scope.membership, profile: name) }
        }
        let rest = sessions.filter { !placed.contains($0.id) }
        if !rest.isEmpty || out.isEmpty { out.append(ChatProjectGroup(id: noneID, project: nil, profile: nil, sessions: rest)) }
        return out
    }

    /// The collapsed projects, remembered as their ids joined by commas.
    static func collapsed(_ raw: String) -> Set<String> { Set(raw.split(separator: ",").map(String.init)) }
    static func toggled(_ raw: String, _ id: String) -> String {
        var set = collapsed(raw)
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        return set.sorted().joined(separator: ",")
    }
}

/// A project's header in the grouped list: its folder and name, how many chats, whether one
/// of them is working or waiting, and a way to start a chat in it. A tap folds it.
struct ProjectSectionHeader: View {
    var group: ChatProjectGroup
    var collapsed: Bool
    var working: Int
    var waiting: Int
    /// The bot's face beside the name, when several bots' projects are listed.
    var showBot = false
    var onToggle: () -> Void
    var onNewChat: (() -> Void)?

    private var name: String { group.project?.name ?? "No project" }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    if let p = group.project { ProjectIcon(project: p, size: 20) }
                    else { Image(systemName: "tray").font(.footnote).foregroundStyle(.secondary).frame(width: 20, height: 20) }
                    Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    if showBot, let bot = group.profile { BotAvatar(profile: bot, size: 16) }
                    Text("\(group.sessions.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if waiting > 0 {
                        Text(waiting == 1 ? "Needs you" : "\(waiting) need you").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.red.opacity(0.15), in: .capsule).foregroundStyle(.red)
                    } else if working > 0 {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(group.sessions.count) \(group.sessions.count == 1 ? "chat" : "chats")\(working > 0 ? ", working" : "")\(waiting > 0 ? ", needs you" : "")")
            .accessibilityHint(collapsed ? "Shows its chats" : "Hides its chats")
            .accessibilityIdentifier("chats.project.\(group.project?.slug ?? group.project?.id ?? "none")")
            if let onNewChat {
                Button(action: onNewChat) { Image(systemName: "plus").font(.footnote.weight(.semibold)).frame(width: 28, height: 24).contentShape(.rect) }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                    .help("New chat in \(name)")
                    .accessibilityLabel("New chat in \(name)")
            }
        }
        .textCase(nil)
        .padding(.vertical, 2)
    }
}

/// Files chats under a project. A chat is in a project because it works in that project's
/// folder, so a move changes the folder the bot works in from then on; nothing on disk moves.
@MainActor
enum ProjectMover {
    /// Returns what went wrong in words, or nil.
    static func move(_ sessions: [StoredSession], to project: Project?, runtime: GatewayRuntime) async -> String? {
        // Projects belong to a bot, so each bot's chats are moved with that bot's name on the call.
        let byBot = Dictionary(grouping: sessions) { $0.profile ?? runtime.selectedProfile ?? "" }
        do {
            for (bot, list) in byBot {
                try await runtime.projects.move(list.map(\.id), to: project, profile: bot.isEmpty ? nil : bot)
            }
            NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The bots the chats belong to. More than one means there is no project they can all go to.
    static func bots(_ sessions: [StoredSession], runtime: GatewayRuntime) -> Set<String> {
        Set(sessions.map { $0.profile ?? runtime.selectedProfile ?? "" })
    }
}

/// The projects a chat (or several chats of one bot) can be moved to, as menu items: for a
/// row's context menu and the chat's own menu.
struct ProjectMoveMenu: View {
    var sessions: [StoredSession]
    var runtime: GatewayRuntime
    var onError: (String) -> Void

    var body: some View {
        let store = runtime.projects
        let bots = ProjectMover.bots(sessions, runtime: runtime)
        let current = Set(sessions.map { store.projectID(forSession: $0.id) ?? "" })
        if bots.count == 1, let bot = bots.first {
            ForEach(store.open(for: bot.isEmpty ? nil : bot)) { p in
                Button { run(p) } label: {
                    if current == [p.id] { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
                .disabled(current == [p.id])
            }
            Divider()
        }
        Button { run(nil) } label: {
            if current == [""] { Label("No project", systemImage: "checkmark") } else { Label("No project", systemImage: "tray") }
        }
        .disabled(current == [""])
    }

    private func run(_ project: Project?) {
        Task { if let why = await ProjectMover.move(sessions, to: project, runtime: runtime) { onError(why) } }
    }
}

/// Move to Project as a sheet, for a selection of chats: the projects with their folders, the
/// one the chats are in ticked, and what a move means.
struct MoveToProjectSheet: View {
    var sessions: [StoredSession]
    var runtime: GatewayRuntime
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        let store = runtime.projects
        let bots = ProjectMover.bots(sessions, runtime: runtime)
        let current = Set(sessions.map { store.projectID(forSession: $0.id) ?? "" })
        NavigationStack {
            Form {
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
                Section {
                    if bots.count == 1, let bot = bots.first {
                        let projects = store.open(for: bot.isEmpty ? nil : bot)
                        ForEach(projects) { p in
                            row(id: p.id, ticked: current == [p.id]) {
                                ProjectIcon(project: p, size: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name)
                                    Text(p.startPath ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                }
                            } action: { move(p) }
                        }
                        if projects.isEmpty { Text("This bot has no projects yet. Make one in Settings › Projects.").foregroundStyle(.secondary) }
                    } else {
                        Text("These chats belong to \(bots.count) bots. Each bot has its own projects, so there is no project they can all go to. Select one bot's chats to file them together.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    row(id: ChatProjectGroups.noneID, ticked: current == [""]) {
                        Image(systemName: "tray").frame(width: 26, height: 26).foregroundStyle(.secondary)
                        Text("No project")
                    } action: { move(nil) }
                } header: {
                    Text(sessions.count == 1 ? "Move \u{201C}\(sessions[0].displayTitle)\u{201D} to" : "Move \(sessions.count) chats to")
                } footer: {
                    Text("A chat is in a project because it works in that project's folder on the gateway. Moving it changes the folder the bot works in from now on. Nothing on disk is moved, and the conversation stays as it is.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Move to Project").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row<Label: View>(id: String, ticked: Bool, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                label()
                Spacer(minLength: 0)
                if busy == id { ProgressView().controlSize(.small) }
                else if ticked { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Current project") }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(busy != nil || ticked)
        .accessibilityIdentifier("move.project.\(id)")
    }

    private func move(_ project: Project?) {
        busy = project?.id ?? ChatProjectGroups.noneID
        Task {
            error = await ProjectMover.move(sessions, to: project, runtime: runtime)
            busy = nil
            if error == nil { onDone(); dismiss() }
        }
    }
}

/// A chat's project in its own menu: where it is filed, and the way to file it elsewhere.
struct ChatProjectMenu: View {
    var chat: ChatSession
    @State private var error: String?

    var body: some View {
        let store = chat.runtime.projects
        if store.available == true, store.canMove, !chat.storedID.isEmpty {
            let row = StoredSession(id: chat.storedID, title: chat.title, profile: chat.profileName)
            Menu {
                ProjectMoveMenu(sessions: [row], runtime: chat.runtime) { chat.banner = $0 }
            } label: {
                Label("Project: \(store.project(forSession: chat.storedID)?.name ?? "none")", systemImage: "folder")
            }
        }
    }
}
