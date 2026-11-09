import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// #665: on a socket served by Hermes's session authority (v0.23.0, and a gateway-hosted listener on 0.22.7), a new
/// chat's session.create is checked against CanonicalCreateParams before any handler runs, and a key it doesn't declare
/// is refused: 4001 "invalid_params", the key in data.fields. The legacy create takes the same keys and defaults
/// "cols" to 80, so a create sends only declared keys, and never "cols", which only session.resume declares.
@MainActor @Suite struct Hermes023ContractTests {
    /// CanonicalCreateParams' fields at v0.23.0 (tui_gateway/contracts/canonical_sessions.py), with ProfileParams'
    /// "profile"; the same in v0.22.7.
    static let createDeclared: Set<String> = [
        "accept_hooks", "api_key", "base_url", "checkpoints", "client_env", "cwd", "cwd_explicit", "editor",
        "follow_profile_config", "hidden", "ignore_rules", "ignore_user_config", "max_turns", "model", "pass_session_id",
        "profile", "provider", "reasoning", "request_id", "row_cwd", "run_budget", "safe_mode", "service_tier", "skills",
        "source", "title", "toolsets", "verbose", "yolo",
    ]

    private func runtime() throws -> GatewayRuntime {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        return GatewayRuntime(connection: conn, store: ConnectionStore())
    }

    /// The params of each session.create a new chat sends while `open` runs; every other call is answered empty.
    private func creates(_ open: @MainActor (ChatSession) async throws -> Void) async throws -> [[String: JSONValue]] {
        let chat = ChatSession.draft(runtime: try runtime(), profile: "work")
        var sent: [[String: JSONValue]] = []
        chat.gatewayStandIn = { method, params in
            guard method == "session.create" else { return .object([:]) }
            sent.append(params)
            return .object(["session_id": "rt-665", "stored_session_id": "st-665"])
        }
        try await open(chat)
        #expect(chat.runtimeID == "rt-665")
        return sent
    }

    @Test func aNewChatsCreateSendsOnlyKeysHermesDeclares() async throws {
        let sent = try await creates { try await $0.create() }
        #expect(sent.count == 1)
        for params in sent {
            let undeclared = Set(params.keys).subtracting(Self.createDeclared).sorted()
            #expect(undeclared.isEmpty, "session.create sent keys Hermes v0.23.0 refuses: \(undeclared)")
            #expect(params["cols"] == nil)
        }
    }

    @Test func aNewChatInAFolderSendsOnlyKeysHermesDeclares() async throws {
        let sent = try await creates { try await $0.create(cwd: "/work/site") }
        #expect(sent.count == 1)
        for params in sent {
            let undeclared = Set(params.keys).subtracting(Self.createDeclared).sorted()
            #expect(undeclared.isEmpty, "session.create sent keys Hermes v0.23.0 refuses: \(undeclared)")
            #expect(params["cwd"] == .string("/work/site"))
            #expect(params["cwd_explicit"] == .bool(true))
            #expect(params["cols"] == nil)
        }
    }
}
