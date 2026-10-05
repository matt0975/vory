import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// A stand-in network for one suite: answers, or fails the way an unreachable host does.
final class RelayStubProtocol: URLProtocol {
    enum Outcome { case answer(Int, [String: String], Data), fail(URLError.Code) }
    nonisolated(unsafe) static var outcome: (@Sendable (URLRequest) -> Outcome)?
    nonisolated(unsafe) static var hits = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.hits += 1
        guard let outcome = Self.outcome?(request) else { return }
        switch outcome {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .answer(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// What the relay was asked, and what it answers.
final class RelayRecorder: @unchecked Sendable {
    var asked: [RelayedRequest] = []
    var answer: RelayedResponse = RelayedResponse(status: 200, contentType: "application/json", body: Data(#"{"via":"phone"}"#.utf8))
    var away = false
    /// The phone reached, but it could not reach the gateway either.
    var failing = false
    var relay: HermesAPI.Relay {
        { [self] r in
            if away { throw RelayUnavailable("Your iPhone is not reachable.") }
            asked.append(r)
            if failing { throw HermesAPIError.transport("The iPhone could not reach the gateway.") }
            return answer
        }
    }
}

/// The watch's way to its gateway (Settings › Connect through): its own connection while the
/// gateway answers there, the iPhone when it does not, or the iPhone only.
@Suite(.serialized) struct WatchRouteTests {
    private func api(mode: AuthMode = .sessionToken) throws -> HermesAPI {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RelayStubProtocol.self]
        let g = try GatewayURL.normalize("https://h.example.com")
        let signer = RequestSigner(authMode: mode, sessionToken: "tok", bearer: mode.usesBearer ? "at" : nil, access: CloudflareAccess(clientId: "cid", clientSecret: "csec"))
        return HermesAPI(gateway: g, signer: signer, urlSession: URLSession(configuration: cfg))
    }

    private static let json = ["Content-Type": "application/json"]

    @Test func iPhoneOnlyNeverTouchesTheWatchsOwnConnection() async throws {
        RelayStubProtocol.hits = 0
        RelayStubProtocol.outcome = { _ in .answer(200, Self.json, Data(#"{"via":"direct"}"#.utf8)) }
        let rec = RelayRecorder()
        let api = try api()
        await api.setRelay(rec.relay, route: .relayOnly)
        let r: JSONValue = try await api.get("/api/sessions", query: [URLQueryItem(name: "limit", value: "8")], profile: "ada")
        #expect(r["via"]?.stringValue == "phone")
        #expect(RelayStubProtocol.hits == 0)
        // The bot goes with the call, as a query item the phone passes on unchanged.
        #expect(rec.asked.first?.path == "/api/sessions")
        #expect(rec.asked.first?.query.contains(URLQueryItem(name: "profile", value: "ada")) == true)
        #expect(await api.lastRelayed)
    }

    @Test func iPhoneOnlyWithThePhoneAwaySaysSo() async throws {
        let rec = RelayRecorder(); rec.away = true
        let api = try api()
        await api.setRelay(rec.relay, route: .relayOnly)
        await #expect(throws: HermesAPIError.self) { let _: JSONValue = try await api.get("/api/profiles") }
    }

    @Test func automaticUsesTheWatchsOwnConnectionWhileItAnswers() async throws {
        RelayStubProtocol.outcome = { _ in .answer(200, Self.json, Data(#"{"via":"direct"}"#.utf8)) }
        let rec = RelayRecorder()
        let api = try api()
        await api.setRelay(rec.relay, route: .automatic)
        let r: JSONValue = try await api.get("/api/profiles")
        #expect(r["via"]?.stringValue == "direct")
        #expect(rec.asked.isEmpty)
        #expect(await api.lastRelayed == false)
    }

    @Test func automaticGoesThroughTheIPhoneWhenTheGatewayDoesNotAnswerAndStaysThere() async throws {
        RelayStubProtocol.hits = 0
        RelayStubProtocol.outcome = { _ in .fail(.cannotConnectToHost) }
        let rec = RelayRecorder()
        let used = RouteLog()
        let api = try api()
        await api.setRelay(rec.relay, route: .automatic, onRouteUsed: { used.add($0) })
        let r: JSONValue = try await api.get("/api/profiles")
        #expect(r["via"]?.stringValue == "phone")
        #expect(RelayStubProtocol.hits == 1)
        // The next call goes to the phone first: no wait on a route that just failed.
        let _: JSONValue = try await api.get("/api/sessions")
        #expect(RelayStubProtocol.hits == 1)
        #expect(rec.asked.map(\.path) == ["/api/profiles", "/api/sessions"])
        #expect(used.values == [true])
    }

    @Test func automaticTakesAnAccessSignInPageAsNotReachingTheGateway() async throws {
        RelayStubProtocol.outcome = { _ in .answer(200, ["Content-Type": "text/html"], Data("<!DOCTYPE html><html><body>Sign in</body></html>".utf8)) }
        let rec = RelayRecorder()
        let api = try api()
        await api.setRelay(rec.relay, route: .automatic)
        let r: JSONValue = try await api.get("/api/profiles")
        #expect(r["via"]?.stringValue == "phone")
        #expect(rec.asked.count == 1)
    }

    @Test func automaticLeavesTheGatewaysOwnRefusalAlone() async throws {
        RelayStubProtocol.outcome = { _ in .answer(404, Self.json, Data(#"{"detail":"Session not found"}"#.utf8)) }
        let rec = RelayRecorder()
        let api = try api()
        await api.setRelay(rec.relay, route: .automatic)
        do {
            let _: JSONValue = try await api.get("/api/sessions/x")
            Issue.record("a 404 should throw")
        } catch let HermesAPIError.http(status, detail) {
            #expect(status == 404)
            #expect(detail == "Session not found")
        }
        #expect(rec.asked.isEmpty)
    }

    @Test func automaticWithThePhoneAwayToo() async throws {
        RelayStubProtocol.outcome = { _ in .fail(.cannotConnectToHost) }
        let rec = RelayRecorder(); rec.away = true
        let api = try api()
        await api.setRelay(rec.relay, route: .automatic)
        do {
            let _: JSONValue = try await api.get("/api/profiles")
            Issue.record("should throw")
        } catch let HermesAPIError.transport(m) {
            #expect(m.contains("iPhone is not reachable"))
        }
        // Nothing sticks: with the phone back, the next call still goes to the watch's own
        // connection first, without asking the phone.
        rec.away = false
        RelayStubProtocol.hits = 0
        RelayStubProtocol.outcome = { _ in .answer(200, Self.json, Data(#"{"via":"direct"}"#.utf8)) }
        let r: JSONValue = try await api.get("/api/profiles")
        #expect(r["via"]?.stringValue == "direct")
        #expect(RelayStubProtocol.hits == 1)
        #expect(rec.asked.isEmpty)
    }

    @Test func aReadThePhoneCannotCarryGoesBackToTheWatchsOwnConnection() async throws {
        RelayStubProtocol.outcome = { _ in .fail(.timedOut) }
        let rec = RelayRecorder()
        let api = try api()
        await api.setRelay(rec.relay, route: .automatic)
        let _: JSONValue = try await api.get("/api/profiles")
        #expect(rec.asked.count == 1)
        // The phone now fails its calls while the watch's own route answers again.
        rec.failing = true
        RelayStubProtocol.outcome = { _ in .answer(200, Self.json, Data(#"{"via":"direct"}"#.utf8)) }
        let r: JSONValue = try await api.get("/api/profiles")
        #expect(r["via"]?.stringValue == "direct")
        // And the phone is not asked first any more.
        rec.failing = false
        let _: JSONValue = try await api.get("/api/profiles")
        #expect(rec.asked.count == 2)
    }

    @Test func aWriteThatMayHaveReachedTheGatewayIsNotSentTwice() async throws {
        RelayStubProtocol.outcome = { _ in .fail(.networkConnectionLost) }
        let rec = RelayRecorder()
        let api = try api()
        await api.setRelay(rec.relay, route: .automatic)
        await #expect(throws: HermesAPIError.self) { let _: JSONValue = try await api.send("POST", "/api/files/upload", json: ["path": "x"]) }
        #expect(rec.asked.isEmpty)
        // One that never left the watch goes through the phone.
        RelayStubProtocol.outcome = { _ in .fail(.cannotConnectToHost) }
        let r: JSONValue = try await api.send("POST", "/api/files/upload", json: ["path": "x"])
        #expect(r["via"]?.stringValue == "phone")
    }

    @Test func whenThePhoneFailsTooTheWatchsOwnAnswerStands() async throws {
        RelayStubProtocol.outcome = { _ in .answer(200, ["Content-Type": "text/html"], Data("<html>Sign in</html>".utf8)) }
        let rec = RelayRecorder(); rec.failing = true
        let api = try api()
        await api.setRelay(rec.relay, route: .automatic)
        do {
            let _: JSONValue = try await api.get("/api/profiles")
            Issue.record("should throw")
        } catch HermesAPIError.htmlResponse {}
    }

    @Test func theSocketsTicketNeverGoesThroughThePhone() async throws {
        RelayStubProtocol.outcome = { _ in .fail(.cannotConnectToHost) }
        let rec = RelayRecorder()
        let api = try api(mode: .oauth)
        await api.setRelay(rec.relay, route: .relayOnly)
        await #expect(throws: HermesAPIError.self) { let _: JSONValue = try await api.send("POST", "/api/auth/ws-ticket", body: EmptyBody(), directOnly: true) }
        #expect(rec.asked.isEmpty)
    }

    @Test func automaticFallsBackToItsOwnConnectionWhenThePhoneLeaves() async throws {
        RelayStubProtocol.outcome = { _ in .fail(.timedOut) }
        let rec = RelayRecorder()
        let api = try api()
        await api.setRelay(rec.relay, route: .automatic)
        let _: JSONValue = try await api.get("/api/profiles")
        // The phone goes away while the watch prefers it; the watch's own route works again.
        rec.away = true
        RelayStubProtocol.outcome = { _ in .answer(200, Self.json, Data(#"{"via":"direct"}"#.utf8)) }
        let r: JSONValue = try await api.get("/api/profiles")
        #expect(r["via"]?.stringValue == "direct")
    }

    @Test func aRelayed401IsNotRenewedOnTheWatch() async throws {
        let rec = RelayRecorder()
        rec.answer = RelayedResponse(status: 401, contentType: "application/json", body: Data(#"{"detail":"expired"}"#.utf8))
        let calls = RouteLog()
        let api = try api(mode: .oauth)
        await api.setRefresher { calls.add(true); throw HermesAPIError.sessionExpired }
        await api.setRelay(rec.relay, route: .relayOnly)
        await #expect(throws: HermesAPIError.self) { let _: JSONValue = try await api.get("/api/profiles") }
        #expect(calls.values.isEmpty)
    }

    @Test func theWatchsStaleSignInGoesThroughThePhone() async throws {
        // The watch has no refresh token; its iPhone does.
        RelayStubProtocol.outcome = { _ in .answer(401, Self.json, Data(#"{"detail":"expired"}"#.utf8)) }
        let rec = RelayRecorder()
        let api = try api(mode: .oauth)
        await api.setRelay(rec.relay, route: .automatic)
        let r: JSONValue = try await api.get("/api/profiles")
        #expect(r["via"]?.stringValue == "phone")
    }

    @Test func forwardHandsBackTheGatewaysAnswerAsItCame() async throws {
        RelayStubProtocol.outcome = { req in
            #expect(req.value(forHTTPHeaderField: "CF-Access-Client-Id") == "cid")
            return .answer(404, Self.json, Data(#"{"detail":"nope"}"#.utf8))
        }
        let api = try api()
        let out = try await api.forward(RelayedRequest(method: "GET", path: "/api/sessions/x", query: [URLQueryItem(name: "profile", value: "ada")], body: nil, contentType: nil, authenticated: true))
        #expect(out.status == 404)
        #expect(out.contentType == "application/json")
        #expect(String(decoding: out.body, as: UTF8.self).contains("nope"))
    }

    @Test func forwardRenewsThePhonesOwnSignInOnce() async throws {
        let n = RouteLog()
        RelayStubProtocol.outcome = { req in
            req.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" ? .answer(200, Self.json, Data("{}".utf8)) : .answer(401, Self.json, Data("{}".utf8))
        }
        let api = try api(mode: .oauth)
        await api.setRefresher { n.add(true); return RequestSigner(authMode: .oauth, sessionToken: nil, bearer: "fresh", access: CloudflareAccess(clientId: "cid", clientSecret: "csec")) }
        let out = try await api.forward(RelayedRequest(method: "GET", path: "/api/profiles", query: [], body: nil, contentType: nil, authenticated: true))
        #expect(out.status == 200)
        #expect(n.values.count == 1)
    }
}

final class RouteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Bool] = []
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return _values }
    func add(_ v: Bool) { lock.lock(); _values.append(v); lock.unlock() }
}

/// The watch ↔ iPhone messages for relayed calls: within WatchConnectivity's size, nothing lost.
@Suite struct RelayWireTests {
    /// Bytes that do not compress (xorshift), so a body stays big after compression.
    private func noise(_ count: Int, seed: UInt64 = 0x9E3779B97F4A7C15) -> Data {
        var x = seed, out = Data(capacity: count)
        for _ in 0..<count { x ^= x << 13; x ^= x >> 7; x ^= x << 17; out.append(UInt8(truncatingIfNeeded: x)) }
        return out
    }

    @Test func aRequestSurvivesTheTrip() throws {
        let body = Data(String(repeating: "{\"a\":1}", count: 400).utf8)
        let r = RelayedRequest(method: "POST", path: "/api/files/upload", query: [URLQueryItem(name: "profile", value: "ada"), URLQueryItem(name: "x", value: nil)],
                               body: body, contentType: "application/json", authenticated: true)
        let m = RelayWire.message(r, gateway: "g", inlineBody: RelayWire.compress(body))
        #expect((m["body"] as? Data)!.count < body.count)
        let back = try #require(RelayWire.request(from: m))
        #expect(back.method == "POST")
        #expect(back.body == body)
        #expect(back.query == [URLQueryItem(name: "profile", value: "ada"), URLQueryItem(name: "x", value: "")])
        #expect(back.contentType == "application/json")
        #expect(PropertyListSerialization.propertyList(m, isValidFor: .binary))
    }

    @Test func onlyTheGatewaysAPIIsCarried() {
        #expect(RelayWire.isAllowed(path: "/api/sessions/abc/messages"))
        #expect(!RelayWire.isAllowed(path: "/api/../etc/passwd"))
        #expect(!RelayWire.isAllowed(path: "https://elsewhere.example/api/x"))
        #expect(!RelayWire.isAllowed(path: "/login"))
        #expect(RelayWire.request(from: ["method": "GET", "path": "/admin"]) == nil)
    }

    @Test func aBigBodyIsSplitIntoMessageSizedParts() {
        let big = noise(130_000)
        let parts = RelayWire.split(big)
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { $0.count <= RelayWire.partSize })
        #expect(parts.reduce(Data(), +) == big)
        #expect(RelayWire.split(Data()) == [Data()])
        #expect(RelayWire.decompress(RelayWire.compress(Data())) == Data())
    }

    #if os(iOS)
    // RelayParts and WatchRequestHold live in the iPhone app (Vory/Watch), which the Mac build leaves out.
    @Test @MainActor func thePhoneHandsABigAnswerBackInParts() throws {
        // A long history page: noisy enough that compressing it still leaves several parts.
        let noisy = noise(200_000)
        let first = RelayParts.reply(RelayedResponse(status: 200, contentType: "application/json", body: noisy))
        let parts = try #require(first["parts"] as? Int)
        #expect(parts > 1)
        let more = try #require(first["more"] as? String)
        var packed = try #require(first["body"] as? Data)
        for i in 1..<parts {
            let p = RelayParts.part(["id": more, "index": i])
            packed.append(try #require(p["part"] as? Data))
        }
        #expect(RelayWire.decompress(packed) == noisy)
        // Fetched to the end: gone.
        #expect(RelayParts.part(["id": more, "index": parts - 1])["ok"] as? Bool == false)
        #expect(PropertyListSerialization.propertyList(first, isValidFor: .binary))
    }

    @Test @MainActor func aBigRequestArrivesInPartsAndIsPutBackTogether() throws {
        let body = noise(100_000, seed: 42)
        let packed = RelayWire.compress(body)
        let parts = RelayWire.split(packed, size: 10_000)
        #expect(parts.count > 1)
        for (i, p) in parts.enumerated() { #expect(RelayParts.put(["id": "req1", "index": i, "part": p])["ok"] as? Bool == true) }
        let joined = try #require(RelayParts.assemble("req1", parts: parts.count))
        let r = RelayedRequest(method: "POST", path: "/api/audio/transcribe", query: [], body: nil, contentType: "multipart/form-data; boundary=x", authenticated: true)
        let m = RelayWire.message(r, gateway: "g", bodyRef: "req1", parts: parts.count)
        let back = try #require(RelayWire.request(from: m, assembled: joined))
        #expect(back.body == body)
        // A part missing: nothing is sent on.
        _ = RelayParts.put(["id": "req2", "index": 0, "part": parts[0]])
        #expect(RelayParts.assemble("req2", parts: 2) == nil)
    }

    @Test @MainActor func aWatchRequestIsAnsweredOnce() {
        let log = RouteLog()
        let hold = WatchRequestHold { _ in log.add(true) }
        hold.finish(["ok": true])
        hold.finish(["ok": false])
        #expect(log.values.count == 1)
    }
    #endif

    @Test func failuresKeepTheirMeaning() {
        #expect(RelayWire.isUnavailable(RelayWire.unavailable("gone")))
        #expect(!RelayWire.isUnavailable(RelayWire.failure(HermesAPIError.transport("down"))))
        if case .sessionExpired = RelayWire.error(from: RelayWire.failure(HermesAPIError.sessionExpired)) {} else { Issue.record("expired lost") }
        if case .transport(let m) = RelayWire.error(from: RelayWire.failure(HermesAPIError.transport("down"))) { #expect(m == "down") } else { Issue.record("transport lost") }
    }
}
