import Foundation
import Testing
@testable import VoryCore

/// A gateway that answers one test at a time: a Hermes before the session fence or after it (#467), with what it was
/// asked kept in order.
final class FenceURLProtocol: URLProtocol {
    nonisolated(unsafe) static var gateway: FakeFenceGateway?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let gateway = Self.gateway else { return }
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open(); var data = Data(); let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable { let n = stream.read(buf, maxLength: 4096); if n > 0 { data.append(buf, count: n) } else { break } }
            buf.deallocate(); stream.close(); req.httpBody = data
        }
        let (status, body) = gateway.answer(req)
        let response = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class FakeFenceGateway: @unchecked Sendable {
    struct Asked { var method: String; var path: String; var query: [String: String]; var body: JSONValue? }
    let fenced: Bool
    var revision = 3
    var generation: Int?
    var exists = true
    /// The next edits refused with these details, in order.
    var refusals: [String] = []
    /// After a refusal, the chat's revision as another client left it.
    var revisionAfterRefusal: Int?
    /// The snapshot route answered with this instead (a catch-all route's `{}`, say).
    var snapshotBody: String?
    /// The DELETE answered with this instead (a chat already gone, or one the gateway cannot reach).
    var deleteAnswer: (Int, String)?
    private(set) var asked: [Asked] = []
    var edits: [Asked] { asked.filter { $0.method != "GET" } }

    init(fenced: Bool) { self.fenced = fenced }

    func answer(_ req: URLRequest) -> (Int, String) {
        let url = req.url!
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let body = req.httpBody.flatMap { $0.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let path = url.path.replacingOccurrences(of: "/hermes", with: "")
        asked.append(Asked(method: req.httpMethod ?? "GET", path: path, query: query, body: body))
        if path.hasSuffix("/mutation-snapshot") {
            if let snapshotBody { return (200, snapshotBody) }
            guard fenced else { return (404, #"{"detail":"Not Found"}"#) }
            let gen = generation.map(String.init) ?? "null"
            return (200, #"{"session_id":"c1","exists":\#(exists),"runtime_revision":\#(exists ? revision : 0),"runtime_generation":\#(gen)}"#)
        }
        if req.httpMethod == "DELETE", let deleteAnswer { return deleteAnswer }
        guard fenced else { return (200, #"{"ok":true}"#) }
        let id = req.httpMethod == "DELETE" ? query["request_id"] : body?["request_id"]?.stringValue
        let rev = req.httpMethod == "DELETE" ? query["expected_revision"].flatMap(Int.init) : body?["expected_revision"]?.doubleValue.map(Int.init)
        if id == nil, rev == nil { return (409, #"{"detail":"client_upgrade_required: this app is out of sync (different versions) with the Hermes backend; update the app to edit sessions"}"#) }
        if !refusals.isEmpty {
            let r = refusals.removeFirst()
            if let moved = revisionAfterRefusal { revision = moved }
            return (409, #"{"detail":"\#(r)"}"#)
        }
        if rev != revision { return (409, #"{"detail":"revision_conflict"}"#) }
        if !exists { return req.httpMethod == "DELETE" ? (200, #"{"ok":true,"already_absent":true}"#) : (404, #"{"detail":"not_found"}"#) }
        revision += 1
        return (200, #"{"ok":true,"session_id":"c1","revision":\#(revision)}"#)
    }
}

@Suite(.serialized) struct SessionMutationTests {
    private func api(_ gateway: FakeFenceGateway) throws -> HermesAPI {
        FenceURLProtocol.gateway = gateway
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FenceURLProtocol.self]
        let g = try GatewayURL.normalize("https://h.example.com/hermes")
        return HermesAPI(gateway: g, signer: RequestSigner(authMode: .sessionToken, sessionToken: "tok"), urlSession: URLSession(configuration: cfg))
    }

    @Test func aHermesBeforeTheFenceGetsTodaysRequests() async throws {
        let gw = FakeFenceGateway(fenced: false)
        let api = try api(gw)
        try await SessionMutation.delete(api, id: "c1", profile: "work")
        try await SessionMutation.patch(api, id: "c1", profile: "work", fields: ["pinned": .bool(true)])
        #expect(gw.asked.filter { $0.path.hasSuffix("/mutation-snapshot") }.count == 2)
        let delete = try #require(gw.edits.first), patch = try #require(gw.edits.last)
        #expect(delete.method == "DELETE" && delete.query == ["profile": "work"])
        #expect(patch.method == "PATCH" && patch.body == .object(["pinned": .bool(true), "profile": .string("work")]))
    }

    @Test func aSnapshotWithoutTheRevisionIsNoFence() async throws {
        let gw = FakeFenceGateway(fenced: false); gw.snapshotBody = "{}"
        try await SessionMutation.delete(try api(gw), id: "c1", profile: "work")
        #expect(gw.edits.count == 1 && gw.edits.first?.query == ["profile": "work"])
    }

    @Test func aFencedDeleteCarriesItsIdentityInTheQuery() async throws {
        let gw = FakeFenceGateway(fenced: true)
        try await SessionMutation.delete(try api(gw), id: "c1", profile: "work")
        let d = try #require(gw.edits.first)
        #expect(gw.edits.count == 1 && d.method == "DELETE")
        #expect(d.query["expected_revision"] == "3" && d.query["profile"] == "work" && d.query["expected_generation"] == nil)
        #expect((d.query["request_id"] ?? "").count >= 8)
        // With a generation in the snapshot, it goes too.
        let gw2 = FakeFenceGateway(fenced: true); gw2.generation = 7
        try await SessionMutation.delete(try api(gw2), id: "c1", profile: "work")
        #expect(gw2.edits.first?.query["expected_generation"] == "7")
    }

    @Test func aFencedPatchCarriesItsIdentityInTheBody() async throws {
        let gw = FakeFenceGateway(fenced: true)
        try await SessionMutation.patch(try api(gw), id: "c1", profile: "work", fields: ["archived": .bool(true), "pinned": .bool(false)])
        let p = try #require(gw.edits.first)
        #expect(p.method == "PATCH" && p.query.isEmpty)
        #expect(p.body?["archived"] == .bool(true) && p.body?["pinned"] == .bool(false) && p.body?["profile"] == .string("work"))
        #expect(p.body?["expected_revision"] == .number(3) && p.body?["request_id"]?.stringValue?.isEmpty == false)
        #expect(p.body?["expected_generation"] == nil)
    }

    @Test func aChatThatMovedIsTriedOnceMoreWithANewSnapshotAndANewRequestID() async throws {
        let gw = FakeFenceGateway(fenced: true)
        gw.refusals = ["revision_conflict"]; gw.revisionAfterRefusal = 4
        try await SessionMutation.patch(try api(gw), id: "c1", profile: nil, fields: ["pinned": .bool(true)])
        #expect(gw.edits.count == 2)
        let first = try #require(gw.edits.first?.body), second = try #require(gw.edits.last?.body)
        #expect(first["expected_revision"] == .number(3) && second["expected_revision"] == .number(4))
        #expect(first["request_id"] != second["request_id"])
        #expect(gw.asked.filter { $0.path.hasSuffix("/mutation-snapshot") }.count == 2)
    }

    @Test func aSecondConflictIsSaidNotRetriedAgain() async throws {
        let gw = FakeFenceGateway(fenced: true)
        gw.refusals = ["stale_generation", "revision_conflict"]
        await #expect(throws: HermesAPIError.self) { try await SessionMutation.delete(try api(gw), id: "c1", profile: nil) }
        #expect(gw.edits.count == 2)
    }

    @Test func refusalsAreSaidInPlainWords() async throws {
        for (detail, words) in [("session_busy", "A turn is running in this chat"), ("unknown_execution", "its last turn was lost"),
                                ("runtime_draining", "Hermes is busy right now"), ("admission_conflict", "Try again")] {
            let gw = FakeFenceGateway(fenced: true); gw.refusals = [detail]
            do {
                try await SessionMutation.delete(try api(gw), id: "c1", profile: nil)
                Issue.record("\(detail) was not refused")
            } catch {
                #expect(SessionMutation.message(for: error)?.contains(words) == true, "\(detail): \(String(describing: SessionMutation.message(for: error)))")
                #expect(gw.edits.count == 1, "\(detail) was retried")
            }
        }
        let upgrade = HermesAPIError.http(status: 409, detail: "client_upgrade_required: this app is out of sync (different versions) with the Hermes backend; update the app to edit sessions")
        #expect(SessionMutation.refusal(upgrade) == .clientUpgradeRequired)
        #expect(SessionMutation.message(for: HermesAPIError.http(status: 500, detail: "boom")) == nil)
    }

    @Test func aChatAnOlderHermesNoLongerHasIsDeletedAlready() async throws {
        // Before the fence: a 404 to a DELETE is a chat already gone (deleted from another device first).
        let gw = FakeFenceGateway(fenced: false); gw.deleteAnswer = (404, #"{"detail":"Session not found"}"#)
        try await SessionMutation.delete(try api(gw), id: "c1", profile: nil)
        #expect(gw.edits.count == 1)
        // After it: a 404 not_found is a chat the gateway has but cannot reach, not deleted, and is said.
        let fenced = FakeFenceGateway(fenced: true); fenced.deleteAnswer = (404, #"{"detail":"not_found"}"#)
        await #expect(throws: HermesAPIError.self) { try await SessionMutation.delete(try api(fenced), id: "c1", profile: nil) }
    }

    @Test func aChatTheGatewayNoLongerHasIsDeletedAlready() async throws {
        let gw = FakeFenceGateway(fenced: true); gw.exists = false
        try await SessionMutation.delete(try api(gw), id: "c1", profile: nil)
        #expect(gw.edits.isEmpty)
        // A PATCH of one is the gateway's 404, which the list reads as a stale row.
        await #expect(throws: HermesAPIError.self) { try await SessionMutation.patch(try api(gw), id: "c1", profile: nil, fields: ["pinned": .bool(true)]) }
    }

    /// Move to Project: the socket's fenced `session.mutate` where the gateway has the fence, the old verb elsewhere.
    final class SocketCalls: @unchecked Sendable {
        var sent: [(method: String, params: [String: JSONValue])] = []
        /// Errors for the next calls, in order; nil answers.
        var errors: [Error?] = []
        func call(_ method: String, _ params: [String: JSONValue]) throws -> JSONValue {
            sent.append((method, params))
            if !errors.isEmpty, let e = errors.removeFirst() { throw e }
            return .object([:])
        }
    }

    @Test func aFencedMoveIsTheSocketsSessionMutate() async throws {
        let gw = FakeFenceGateway(fenced: true); gw.generation = 2
        let calls = SocketCalls()
        try await SessionMutation.moveWorkspace(try api(gw), id: "c1", profile: "work", cwd: "/srv/app") { try calls.call($0, $1) }
        let m = try #require(calls.sent.first)
        #expect(calls.sent.count == 1 && m.method == "session.mutate")
        #expect(m.params["session_id"] == .string("c1") && m.params["operation"] == .string("workspace"))
        #expect(m.params["payload"] == .object(["cwd": .string("/srv/app")]))
        #expect(m.params["expected_revision"] == .number(3) && m.params["expected_generation"] == .number(2))
        #expect(m.params["request_id"]?.stringValue?.isEmpty == false)
    }

    @Test func aMoveWithoutTheFenceIsTheOldVerb() async throws {
        let calls = SocketCalls()
        try await SessionMutation.moveWorkspace(try api(FakeFenceGateway(fenced: false)), id: "c1", profile: nil, cwd: "/srv/app") { try calls.call($0, $1) }
        #expect(calls.sent.map(\.method) == ["session.workspace.move"])
        #expect(calls.sent.first?.params == ["session_key": .string("c1"), "cwd": .string("/srv/app")])
        // A fenced gateway whose socket has no session.mutate gets the old verb too.
        let gw = FakeFenceGateway(fenced: true), again = SocketCalls()
        again.errors = [RPCError(code: RPCError.methodNotFound, message: "unknown method: session.mutate")]
        try await SessionMutation.moveWorkspace(try api(gw), id: "c1", profile: nil, cwd: "/srv/app") { try again.call($0, $1) }
        #expect(again.sent.map(\.method) == ["session.mutate", "session.workspace.move"])
    }

    @Test func aRefusedMoveIsSaidAndAStaleOneTriedOnceMore() async throws {
        let busy = SocketCalls()
        busy.errors = [RPCError(code: 4001, message: "session_busy", data: .object(["reason": .string("session_busy")]))]
        do {
            try await SessionMutation.moveWorkspace(try api(FakeFenceGateway(fenced: true)), id: "c1", profile: nil, cwd: "/srv/app") { try busy.call($0, $1) }
            Issue.record("a busy chat's move must throw")
        } catch {
            #expect(SessionMutation.message(for: error) == "A turn is running in this chat. Try again once it has finished.")
        }
        let stale = SocketCalls()
        stale.errors = [RPCError(code: 4001, message: "revision_conflict", data: .object(["reason": .string("revision_conflict")]))]
        try await SessionMutation.moveWorkspace(try api(FakeFenceGateway(fenced: true)), id: "c1", profile: nil, cwd: "/srv/app") { try stale.call($0, $1) }
        #expect(stale.sent.count == 2 && stale.sent[0].params["request_id"] != stale.sent[1].params["request_id"])
    }
}
