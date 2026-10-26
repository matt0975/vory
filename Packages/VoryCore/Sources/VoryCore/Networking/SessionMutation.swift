import Foundation

/// A chat's delete, pin or archive, as Hermes from about 2026-10-17 takes them (#467): fenced. The gateway applies an
/// edit only with the chat's revision as the client last read it, and refuses one without (`client_upgrade_required`,
/// which Vory sent until now: a delete came back with the next list, a pin failed). So: the chat's mutation snapshot
/// first (`GET /api/sessions/{id}/mutation-snapshot`), then the edit with a request id of its own and that revision
/// (and generation, when the snapshot has one): on a DELETE in the query, on a PATCH in the body. A Hermes from before
/// the fence has no snapshot route (404) and gets the request it always got. Renames go over the socket
/// (`session.title`), which is not fenced. A move to another folder (Move to Project) has no REST route: it is the
/// socket's `session.mutate`, with the same revision and generation.
public enum SessionMutation {
    /// What the gateway answered for the chat's revision (`runtime_revision`, `runtime_generation`: the API's decoder
    /// takes snake case to these names). Never 404 for an absent chat (`exists` false); a 404 is a Hermes without the
    /// route.
    public struct Snapshot: Decodable, Equatable, Sendable {
        public var exists: Bool?
        public var runtimeRevision: Int
        public var runtimeGeneration: Int?

        public init(exists: Bool?, runtimeRevision: Int, runtimeGeneration: Int?) {
            self.exists = exists; self.runtimeRevision = runtimeRevision; self.runtimeGeneration = runtimeGeneration
        }
    }

    /// The identity a fenced edit carries.
    public struct Identity: Equatable, Sendable {
        public var requestID: String
        public var revision: Int
        public var generation: Int?

        public init(requestID: String = UUID().uuidString, revision: Int, generation: Int?) {
            self.requestID = requestID; self.revision = revision; self.generation = generation
        }

        public init(_ snapshot: Snapshot) { self.init(revision: snapshot.runtimeRevision, generation: snapshot.runtimeGeneration) }

        /// On a DELETE: query items beside `profile`.
        public var queryItems: [URLQueryItem] {
            var q = [URLQueryItem(name: "request_id", value: requestID), URLQueryItem(name: "expected_revision", value: String(revision))]
            if let generation { q.append(URLQueryItem(name: "expected_generation", value: String(generation))) }
            return q
        }

        /// On a PATCH: fields beside the edit's own.
        public func adding(to fields: [String: JSONValue]) -> [String: JSONValue] {
            var f = fields
            f["request_id"] = .string(requestID)
            f["expected_revision"] = .number(Double(revision))
            if let generation { f["expected_generation"] = .number(Double(generation)) }
            return f
        }

        /// The params of a socket `session.mutate`.
        public func mutation(session id: String, operation: String, payload: [String: JSONValue]) -> [String: JSONValue] {
            adding(to: ["session_id": .string(id), "operation": .string(operation), "payload": .object(payload)])
        }
    }

    /// The gateway's refusals of a fenced edit, by the `detail` it sends.
    public enum Refusal: String, Sendable {
        case clientUpgradeRequired = "client_upgrade_required"
        case identityRequired = "mutation_identity_required"
        case revisionConflict = "revision_conflict"
        case staleGeneration = "stale_generation"
        case admissionConflict = "admission_conflict"
        case busy = "session_busy"
        case unknownExecution = "unknown_execution"
        case draining = "runtime_draining"
        case storageUnavailable = "storage_unavailable"

        /// The chat moved between the snapshot and the edit: a new snapshot and one more try.
        var isStale: Bool { self == .revisionConflict || self == .staleGeneration }
    }

    public static func refusal(_ error: Error) -> Refusal? {
        // Over the socket the reason is the error's `data.reason` (and its message).
        if let e = error as? RPCError { return Refusal(rawValue: e.data?["reason"]?.stringValue ?? e.message) }
        guard let e = error as? HermesAPIError, case .http(_, let detail) = e else { return nil }
        if let r = Refusal(rawValue: detail) { return r }
        // The upgrade refusal carries a sentence after its code.
        return detail.hasPrefix(Refusal.clientUpgradeRequired.rawValue) ? .clientUpgradeRequired : nil
    }

    /// A refusal in plain words for the person, or nil for any other error.
    public static func message(for error: Error) -> String? {
        switch refusal(error) {
        case .busy?: return "A turn is running in this chat. Try again once it has finished."
        case .unknownExecution?: return "Hermes can\u{2019}t change this chat right now: its last turn was lost when the gateway restarted."
        case .revisionConflict?, .staleGeneration?: return "The chat changed on the gateway at the same moment. Try again."
        case .admissionConflict?, .identityRequired?: return "Hermes didn\u{2019}t take the change as sent. Try again."
        case .clientUpgradeRequired?: return "This gateway\u{2019}s Hermes needs a newer Vory to change chats. Update Vory."
        case .draining?, .storageUnavailable?: return "Hermes is busy right now. Try again in a moment."
        case nil: return nil
        }
    }

    /// The chat's snapshot, or nil from a Hermes without the route: a 404, the web app's own page in its place, or an
    /// answer without the fence's revision (a catch-all route's), none of which fences an edit.
    public static func snapshot(_ api: HermesAPI, id: String, profile: String?) async throws -> Snapshot? {
        do {
            let s: Snapshot = try await api.get("/api/sessions/\(id)/mutation-snapshot", profile: profile)
            return s
        } catch let e as HermesAPIError {
            switch e {
            case .http(let status, _) where status == 404 || status == 405: return nil
            case .htmlResponse, .decoding: return nil
            default: throw e
            }
        }
    }

    /// Deletes the chat. A chat the gateway no longer has counts as deleted: a fenced gateway answers `already_absent`,
    /// or its snapshot says the chat does not exist; a Hermes before the fence answers 404 (deleted from another device
    /// first, say). A fenced gateway's 404 stays an error: it is a chat it has but cannot reach, not deleted.
    public static func delete(_ api: HermesAPI, id: String, profile: String?) async throws {
        try await fenced(api, id: id, profile: profile) { identity in
            do {
                let _: JSONValue? = try await api.send("DELETE", "/api/sessions/\(id)", query: identity?.queryItems ?? [], profile: profile, body: EmptyBody())
            } catch HermesAPIError.http(404, _) where identity == nil {
                return
            }
        } absent: { $0.exists == false }
    }

    /// A PATCH of the chat's flags (`pinned`, `archived`, …). `profile` goes in the body, where the gateway reads it.
    public static func patch(_ api: HermesAPI, id: String, profile: String?, fields: [String: JSONValue]) async throws {
        var body = fields
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        let base = body
        try await fenced(api, id: id, profile: profile) { identity in
            let sent = identity?.adding(to: base) ?? base
            let _: JSONValue? = try await api.send("PATCH", "/api/sessions/\(id)", json: .object(sent))
        } absent: { _ in false }
    }

    /// Moves the chat's working folder to `cwd`. A Hermes whose session authority owns its chats (about 2026-10-20 on)
    /// answers the old `session.workspace.move` with -32601 and takes the move only as the fenced `session.mutate`
    /// operation `workspace`, as its Desktop sends it; Vory read that -32601 as a Hermes that cannot move chats, and
    /// Move to Project did nothing. A Hermes without the fence (no snapshot) or without `session.mutate` on the socket
    /// gets `session.workspace.move` as before. `rpc` is the socket call for the chat's bot.
    public static func moveWorkspace(_ api: HermesAPI, id: String, profile: String?, cwd: String,
                                     rpc: @Sendable (String, [String: JSONValue]) async throws -> JSONValue) async throws {
        let legacy: [String: JSONValue] = ["session_key": .string(id), "cwd": .string(cwd)]
        try await fenced(api, id: id, profile: profile) { identity in
            guard let identity else { _ = try await rpc("session.workspace.move", legacy); return }
            do {
                _ = try await rpc("session.mutate", identity.mutation(session: id, operation: "workspace", payload: ["cwd": .string(cwd)]))
            } catch let e as RPCError where e.code == RPCError.methodNotFound {
                _ = try await rpc("session.workspace.move", legacy)
            }
        } absent: { _ in false }
    }

    /// The edit with the identity from a snapshot, once more with a new snapshot (and a new request id: a refused
    /// attempt leaves no receipt, and reusing its id with a new revision would read as a different request) if the chat
    /// moved in between; with no identity at all where the gateway has no fence.
    static func fenced(_ api: HermesAPI, id: String, profile: String?,
                       _ send: (Identity?) async throws -> Void, absent: (Snapshot) -> Bool) async throws {
        guard let first = try await snapshot(api, id: id, profile: profile) else { return try await send(nil) }
        if absent(first) { return }
        do {
            try await send(Identity(first))
        } catch {
            guard refusal(error)?.isStale == true, let again = try await snapshot(api, id: id, profile: profile) else { throw error }
            if absent(again) { return }
            try await send(Identity(again))
        }
    }
}
