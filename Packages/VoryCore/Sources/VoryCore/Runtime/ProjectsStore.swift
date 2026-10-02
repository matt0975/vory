import Foundation

/// The gateway's projects for the selected bot, and which stored chat sits in which project.
/// Nothing is known until `refresh()` ran: `available` is nil, then false on a gateway whose
/// Hermes has no projects methods (JSON-RPC -32601, the only way to tell), true otherwise.
@MainActor
@Observable
public final class ProjectsStore {
    public private(set) var available: Bool?
    public private(set) var projects: [Project] = []
    public private(set) var activeID: String?
    /// Stored session id → project id, from `projects.tree`. Sessions in the gateway's auto
    /// groups (a git root nobody made a project of) and in its Home bucket are absent.
    public private(set) var membership: [String: String] = [:]
    public private(set) var lastError: String?
    /// Projects are kept per bot on the gateway. With every bot's chats in one list, the
    /// other bots' projects and memberships are held here, by profile name.
    public struct Scope: Sendable {
        public var projects: [Project] = []
        public var membership: [String: String] = [:]
        public init(projects: [Project] = [], membership: [String: String] = [:]) {
            self.projects = projects
            self.membership = membership
        }
    }
    public private(set) var others: [String: Scope] = [:]
    /// False once the gateway answered that it cannot re-home a chat (an older Hermes).
    public private(set) var canMove = true
    private weak var runtime: GatewayRuntime?
    private var refreshing = false

    public init() {}
    func attach(_ runtime: GatewayRuntime) { self.runtime = runtime }

    public var open: [Project] { projects.filter { !$0.isArchived } }
    public func project(id: String?) -> Project? { id.flatMap { id in projects.first { $0.id == id } } }
    public func project(forSession id: String) -> Project? {
        if let p = project(id: membership[id]) { return p }
        for scope in others.values {
            if let pid = scope.membership[id], let p = scope.projects.first(where: { $0.id == pid }) { return p }
        }
        return nil
    }
    /// The projects a chat of `profile` can be filed under: its own bot's, never another's.
    public func open(for profile: String?) -> [Project] {
        guard let profile, profile != runtime?.selectedProfile, let scope = others[profile] else { return open }
        return scope.projects.filter { !$0.isArchived }
    }
    /// The project id a chat sits in, whichever bot it belongs to.
    public func projectID(forSession id: String) -> String? {
        if let pid = membership[id] { return pid }
        for scope in others.values { if let pid = scope.membership[id] { return pid } }
        return nil
    }

    public func refresh() async {
        guard let runtime, !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            let r: ProjectsListResponse = try await runtime.rpc("projects.list").decode()
            projects = r.projects
            activeID = r.activeId
            available = true
            lastError = nil
            await refreshTree()
        } catch let e as RPCError where e.code == -32601 {
            available = false; projects = []; membership = [:]; activeID = nil; others = [:]
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Which chats are in which project. Cheap; called again when the session list changes.
    public func refreshTree() async {
        guard let runtime, available == true else { return }
        guard let r: ProjectsTreeResponse = try? await runtime.rpc("projects.tree", ["preview_limit": .number(0), "session_limit": .number(2000)]).decode() else { return }
        membership = Self.membership(from: r)
    }

    private static func membership(from r: ProjectsTreeResponse) -> [String: String] {
        var m: [String: String] = [:]
        for node in r.projects where node.isNoProject != true && node.isAuto != true {
            for sid in node.sessionIds ?? [] { m[sid] = node.id }
        }
        return m
    }

    /// The projects and memberships of bots other than the selected one, for a list that
    /// shows every bot's chats. Bots that are no longer asked for are dropped.
    public func refreshOthers(_ profiles: [String]) async {
        guard let runtime, available == true else {
            if available == false { others = [:] }
            return
        }
        let wanted = profiles.filter { $0 != runtime.selectedProfile }
        var out: [String: Scope] = [:]
        for p in wanted {
            guard let list: ProjectsListResponse = try? await runtime.rpc("projects.list", profile: p).decode() else { continue }
            var scope = Scope(projects: list.projects)
            if let tree: ProjectsTreeResponse = try? await runtime.rpc("projects.tree", ["preview_limit": .number(0), "session_limit": .number(2000)], profile: p).decode() {
                scope.membership = Self.membership(from: tree)
            }
            out[p] = scope
        }
        others = out
    }

    public enum MoveError: LocalizedError {
        case unsupported, noFolder(String), stillInProject(String, String)
        public var errorDescription: String? {
            switch self {
            case .unsupported: return "This gateway's Hermes cannot move a chat yet. Update Hermes on the gateway and try again."
            case .noFolder(let name): return "\(name) has no folder on the gateway to move the chat into."
            case .stillInProject(let folder, let name): return "The bot's own folder (\(folder)) is part of \(name), so there is nowhere outside a project to put the chat."
            }
        }
    }

    /// Files stored chats under `project`, or under none. On the gateway a chat is in a
    /// project because it works in that project's folder, so this moves the chat's working
    /// folder (`session.workspace.move`): to the project's primary folder, or to the bot's own
    /// default folder for "no project". A chat that is running follows at once.
    /// `profile`: the bot the chats belong to. Returns how many moved.
    @discardableResult
    public func move(_ sessionIDs: [String], to project: Project?, profile: String? = nil) async throws -> Int {
        let runtime = try rt()
        let folder: String
        if let project {
            guard let path = project.startPath, !path.isEmpty else { throw MoveError.noFolder(project.name) }
            folder = path
        } else {
            let r = try await runtime.rpc("config.get", ["key": "project"], profile: profile)
            guard let cwd = r["cwd"]?.stringValue, !cwd.isEmpty else { throw MoveError.noFolder("The bot") }
            folder = cwd
        }
        var moved = 0
        let own = profile == nil || profile == runtime.selectedProfile
        for id in sessionIDs {
            do {
                _ = try await runtime.rpc("session.workspace.move", ["session_key": .string(id), "cwd": .string(folder)], profile: profile)
            } catch let e as RPCError where e.code == RPCError.methodNotFound {
                canMove = false
                throw MoveError.unsupported
            } catch {
                // Some went and one did not: the list still has to show the ones that did.
                if moved > 0 { await refreshAfterMove(profile: profile) }
                throw error
            }
            moved += 1
            // Shown at once; the tree read below is the truth.
            if own { membership[id] = project?.id } else if let profile { others[profile, default: Scope()].membership[id] = project?.id }
        }
        await refreshAfterMove(profile: profile)
        if project == nil, let id = sessionIDs.first, let still = self.project(forSession: id) { throw MoveError.stillInProject(folder, still.name) }
        return moved
    }

    private func refreshAfterMove(profile: String?) async {
        guard let runtime else { return }
        if profile == nil || profile == runtime.selectedProfile { await refreshTree() }
        else { await refreshOthers(Array(others.keys)) }
    }

    private func rt() throws -> GatewayRuntime {
        guard let runtime else { throw HermesAPIError.transport("No gateway connected") }
        return runtime
    }

    @discardableResult
    public func create(name: String, folder: String, makeActive: Bool = false) async throws -> Project {
        let r = try await rt().rpc("projects.create", ["name": .string(name), "folders": .array([.string(folder)]), "use": .bool(makeActive)])
        await refresh()
        guard let p = r["project"] else { throw HermesAPIError.decoding("projects.create returned no project") }
        return try p.decode(Project.self)
    }
    public func rename(_ p: Project, to name: String) async throws {
        _ = try await rt().rpc("projects.update", ["id": .string(p.id), "name": .string(name)]); await refresh()
    }
    public func archive(_ p: Project, restore: Bool = false) async throws {
        _ = try await rt().rpc("projects.archive", ["id": .string(p.id), "restore": .bool(restore)]); await refresh()
    }
    public func delete(_ p: Project) async throws {
        _ = try await rt().rpc("projects.delete", ["id": .string(p.id)]); await refresh()
    }
    public func setActive(_ p: Project?) async throws {
        _ = try await rt().rpc("projects.set_active", ["id": p.map { .string($0.id) } ?? .null]); await refresh()
    }
}
