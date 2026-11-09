import Foundation

/// One `session.mutate` on Hermes's session authority (v0.23.0: gateway/session_mutations.py), over the socket: exactly
/// {session_id, request_id, expected_revision, operation, payload}, and `expected_generation` for an edit that needs it
/// (rewind, workspace). Beside the REST edits of #467 (delete, pin, archive), which this leaves as they are. The
/// request_id makes it safe to send again: the gateway answers one it has seen with its first receipt. A refusal on a
/// fence that moved (`revision_conflict`, `stale_generation`) carries the session's current revision and generation, and
/// the edit is sent once more with them and the same request_id; a second refusal is the caller's (#666).
extension SessionMutation {
    public typealias Call = @MainActor (String, [String: JSONValue]) async throws -> JSONValue

    /// `revision` and `generation` are what the caller last saw, 0 when it never saw the session (a stored chat no
    /// one has open here): the refusal then brings the real ones. `beforeRetry` runs between the refusal and the second
    /// send, and may stop it by throwing. `fences` hears the refusal's revision and generation.
    @MainActor
    public static func send(call: Call, sessionID: String, operation: String, payload: [String: JSONValue],
                            revision: Int?, generation: Int?, needsGeneration: Bool,
                            beforeRetry: (@MainActor () async throws -> Void)? = nil,
                            fences: (@MainActor (Int?, Int?) -> Void)? = nil) async throws -> JSONValue {
        let requestID = UUID().uuidString
        func params(_ rev: Int, _ gen: Int) -> [String: JSONValue] {
            var p: [String: JSONValue] = ["session_id": .string(sessionID), "request_id": .string(requestID),
                                          "expected_revision": .number(Double(rev)), "operation": .string(operation),
                                          "payload": .object(payload)]
            if needsGeneration { p["expected_generation"] = .number(Double(gen)) }
            return p
        }
        do {
            return try await call("session.mutate", params(revision ?? 0, generation ?? 0))
        } catch let e as RPCError where isStaleFence(e) {
            let rev = e.data?["revision"]?.intValue, gen = e.data?["execution_generation"]?.intValue
            fences?(rev, gen)
            if let beforeRetry { try await beforeRetry() }
            return try await call("session.mutate", params(rev ?? revision ?? 0, gen ?? generation ?? 0))
        }
    }

    /// A refusal on a fence that moved, named as #467's `Refusal` names it: over the socket the reason is the error's
    /// message (4001), where REST has it in the detail.
    public static func isStaleFence(_ e: RPCError) -> Bool { Refusal(rawValue: e.message)?.isStale == true }
}
