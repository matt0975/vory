import Foundation
import SwiftUI
import Testing
@testable import Vory
@testable import VoryCore

// MARK: URL normalization

@Suite struct GatewayURLTests {
    @Test func acceptsCommonForms() throws {
        #expect(try GatewayURL.normalize("https://hermes.example.com").description == "https://hermes.example.com")
        #expect(try GatewayURL.normalize("https://hermes.example.com/").description == "https://hermes.example.com")
        #expect(try GatewayURL.normalize("https://hermes.example.com/hermes/").description == "https://hermes.example.com/hermes")
        #expect(try GatewayURL.normalize("http://gateway.example.com:9119").description == "http://gateway.example.com:9119")
        #expect(try GatewayURL.normalize("gateway.example.com:9119").description == "https://gateway.example.com:9119")
        #expect(try GatewayURL.normalize("HTTPS://Hermes.Example.com").description == "https://hermes.example.com")
    }

    @Test func stripsPastedRoutesAndAppliesPrefix() throws {
        #expect(try GatewayURL.normalize("https://h.example.com/hermes/api/status").description == "https://h.example.com/hermes")
        #expect(try GatewayURL.normalize("https://h.example.com", pathPrefix: "hermes").description == "https://h.example.com/hermes")
        #expect(try GatewayURL.normalize("https://h.example.com/hermes", pathPrefix: "/hermes/").description == "https://h.example.com/hermes")
    }

    @Test func buildsApiAndWebSocketURLs() throws {
        let g = try GatewayURL.normalize("https://h.example.com/hermes")
        #expect(g.api("/api/status").absoluteString == "https://h.example.com/hermes/api/status")
        #expect(g.api("/api/config", query: [URLQueryItem(name: "profile", value: "work")]).absoluteString == "https://h.example.com/hermes/api/config?profile=work")
        #expect(g.websocket("/api/ws").absoluteString == "wss://h.example.com/hermes/api/ws")
        let plain = try GatewayURL.normalize("http://10.0.0.5:9119")
        #expect(plain.websocket("/api/ws").absoluteString == "ws://10.0.0.5:9119/api/ws")
        #expect(plain.isPrivateHost)
        #expect(!g.isPrivateHost)
    }

    @Test func rejectsBadInput() {
        #expect(throws: GatewayURLError.empty) { try GatewayURL.normalize("   ") }
        #expect(throws: GatewayURLError.unsupportedScheme("ftp")) { try GatewayURL.normalize("ftp://x.example.com") }
        #expect(throws: GatewayURLError.containsQuery) { try GatewayURL.normalize("https://x.example.com/?token=abc") }
    }
}

// MARK: Header injection

@Suite struct RequestSignerTests {
    @Test func accessHeadersAbsentWhenEmpty() {
        let s = RequestSigner(authMode: .sessionToken, sessionToken: "tok", access: CloudflareAccess())
        #expect(s.headers[CloudflareAccess.clientIdHeader] == nil)
        #expect(s.headers[CloudflareAccess.clientSecretHeader] == nil)
        #expect(s.headers[RequestSigner.sessionTokenHeader] == "tok")
        #expect(s.headers["Authorization"] == nil)
    }

    @Test func accessHeadersPresentOnlyWhenBothSet() {
        let partial = CloudflareAccess(clientId: "id", clientSecret: "")
        #expect(partial.headers.isEmpty)
        #expect(partial.isPartiallyConfigured)
        let full = CloudflareAccess(clientId: "id", clientSecret: "secret")
        let s = RequestSigner(authMode: .oauth, bearer: "at", access: full)
        #expect(s.headers[CloudflareAccess.clientIdHeader] == "id")
        #expect(s.headers[CloudflareAccess.clientSecretHeader] == "secret")
        #expect(s.headers["Authorization"] == "Bearer at")
        #expect(s.headers[RequestSigner.sessionTokenHeader] == nil)
        #expect(s.publicHeaders["Authorization"] == nil)
        #expect(s.publicHeaders[CloudflareAccess.clientIdHeader] == "id")
    }

    @Test func websocketCredentialByMode() throws {
        let g = try GatewayURL.normalize("https://h.example.com/hermes")
        #expect(RequestSigner.websocketURL(gateway: g, token: "tok", ticket: nil).absoluteString == "wss://h.example.com/hermes/api/ws?token=tok")
        #expect(RequestSigner.websocketURL(gateway: g, token: "tok", ticket: "tkt").absoluteString == "wss://h.example.com/hermes/api/ws?ticket=tkt")
        #expect(RequestSigner(authMode: .oauth, bearer: "x").websocketTokenQuery == nil)
        #expect(RequestSigner(authMode: .sessionToken, sessionToken: "t").websocketTokenQuery?.value == "t")
    }
}

// MARK: JSON-RPC frames / approval

@Suite struct JSONRPCTests {
    @Test func parsesEventFrame() {
        let f = InboundFrame.parse(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"s1","payload":{"text":"Hi"}}}"#)
        guard case .event(let ev) = f else { Issue.record("not an event"); return }
        #expect(ev.type == "message.delta")
        #expect(ev.sessionID == "s1")
        #expect(ev.payload["text"]?.stringValue == "Hi")
    }

    @Test func parsesApprovalServerRequestAndEncodesResponse() throws {
        let f = InboundFrame.parse(#"{"jsonrpc":"2.0","id":"srq-abc123","method":"approval","params":{"session_id":"s1","request_id":"r9","command":"rm -rf build","choices":["once","session","always","deny"]}}"#)
        guard case .serverRequest(let req) = f else { Issue.record("not a server request"); return }
        #expect(req.id == "srq-abc123")
        #expect(req.sessionID == "s1")
        let approval = try req.params.decode(ApprovalRequest.self)
        #expect(approval.requestId == "r9")
        #expect(approval.offeredChoices == ["once", "session", "always", "deny"])
        let response = RPCFrames.response(id: req.id, result: ["choice": "once"])
        let obj = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
        #expect(obj["id"]?.stringValue == "srq-abc123")
        #expect(obj["result"]?["choice"]?.stringValue == "once")
        #expect(obj["jsonrpc"]?.stringValue == "2.0")
    }

    @Test func parsesResponseAndError() {
        if case .response(let id, let result, let error) = InboundFrame.parse(#"{"jsonrpc":"2.0","id":7,"result":{"pong":true}}"#) {
            #expect(id.intValue == 7); #expect(result?["pong"]?.boolValue == true); #expect(error == nil)
        } else { Issue.record("not a response") }
        if case .response(_, _, let error) = InboundFrame.parse(#"{"jsonrpc":"2.0","id":8,"error":{"code":4000,"message":"bad"}}"#) {
            #expect(error?.code == 4000)
        } else { Issue.record("not a response") }
    }

    @Test func requestFrameShape() throws {
        let text = RPCFrames.request(id: 3, method: "prompt.submit", params: ["session_id": "s1", "text": "hello"])
        let obj = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(obj["method"]?.stringValue == "prompt.submit")
        #expect(obj["id"]?.intValue == 3)
        #expect(obj["params"]?["text"]?.stringValue == "hello")
    }
}

// MARK: Streaming assembly + markdown

@Suite struct StreamingTests {
    @Test func assemblesDeltasAndHonoursFinalText() {
        var a = StreamAssembler()
        a.start()
        a.appendDelta("Hel")
        a.appendDelta("lo ")
        a.appendDelta("world")
        #expect(a.text == "Hello world")
        #expect(a.isStreaming)
        let final = a.complete(finalText: nil)
        #expect(final == "Hello world")
        #expect(!a.isStreaming)
        var b = StreamAssembler()
        b.appendDelta("partial")
        #expect(b.complete(finalText: "authoritative") == "authoritative")
    }

    @Test func finalTextIsNotDuplicatedAfterToolSplitTheStream() {
        // A turn interrupted by a tool call: the first half is sealed into its own bubble, then
        // message.complete arrives carrying the WHOLE turn. Only the remainder may be rendered.
        let sealed = "I'll check the disk.\n\n## What I found\n\n4.2 GB of old logs.\n\n"
        let full = sealed + "Removed 34 files, 4.2 GB freed."
        #expect(StreamAssembler.tail(ofFinalText: full, alreadySealed: sealed) == "Removed 34 files, 4.2 GB freed.")
        // Nothing new after the last tool: the trailing bubble ends up empty and is dropped.
        #expect(StreamAssembler.tail(ofFinalText: sealed, alreadySealed: sealed) == "")
        // Uninterrupted turn: the full text is the whole bubble.
        #expect(StreamAssembler.tail(ofFinalText: full, alreadySealed: "") == full)
        // Divergence (server rewrote the turn): fall back to the authoritative text.
        #expect(StreamAssembler.tail(ofFinalText: full, alreadySealed: "something else") == full)
        // Whitespace drift between the streamed chunks and the final text must still reconcile.
        let drifted = sealed + "  "
        #expect(StreamAssembler.tail(ofFinalText: full, alreadySealed: drifted) == "Removed 34 files, 4.2 GB freed.")
        #expect(StreamAssembler.tail(ofFinalText: full, alreadySealed: sealed.replacingOccurrences(of: "\n\n", with: "\n")) == "Removed 34 files, 4.2 GB freed.")
    }

    @Test func codeFenceStabilizesWhenClosed() {
        let open = MarkdownParser.blocks(from: "Intro\n```swift\nlet x = 1")
        #expect(open.count == 2)
        if case .code(let lang, let text, let closed) = open[1] { #expect(lang == "swift"); #expect(text == "let x = 1"); #expect(!closed) } else { Issue.record("expected code") }
        let done = MarkdownParser.blocks(from: "Intro\n```swift\nlet x = 1\n```\nAfter")
        #expect(done.count == 3)
        if case .code(_, _, let closed) = done[1] { #expect(closed) } else { Issue.record("expected code") }
        if case .paragraph(let t) = done[2] { #expect(t == "After") } else { Issue.record("expected paragraph") }
    }

    @Test func listsHeadingsAndQuotes() {
        let blocks = MarkdownParser.blocks(from: "# Title\n- a\n- b\n1. one\n2. two\n> quoted\n---")
        #expect(blocks.count == 5)
        if case .heading(let l, let t) = blocks[0] { #expect(l == 1); #expect(t == "Title") } else { Issue.record("heading") }
        if case .bullets(let items) = blocks[1] { #expect(items == ["a", "b"]) } else { Issue.record("bullets") }
        if case .numbered(let items) = blocks[2] { #expect(items == ["one", "two"]) } else { Issue.record("numbered") }
        if case .quote(let q) = blocks[3] { #expect(q == "quoted") } else { Issue.record("quote") }
        if case .rule = blocks[4] {} else { Issue.record("rule") }
    }
}

// MARK: Config GET / PUT against a mocked transport

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open(); var data = Data(); let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable { let n = stream.read(buf, maxLength: 4096); if n > 0 { data.append(buf, count: n) } else { break } }
            buf.deallocate(); stream.close(); req.httpBody = data
        }
        let (status, headers, body) = handler(req)
        let response = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct HermesAPITests {
    private func makeAPI(mode: AuthMode = .sessionToken) throws -> HermesAPI {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let g = try GatewayURL.normalize("https://h.example.com/hermes")
        let signer = RequestSigner(authMode: mode, sessionToken: "tok", bearer: mode.usesBearer ? "at" : nil, access: CloudflareAccess(clientId: "cid", clientSecret: "csec"))
        return HermesAPI(gateway: g, signer: signer, urlSession: URLSession(configuration: cfg))
    }

    @Test func configGetSendsProfileAndHeaders() async throws {
        let api = try makeAPI()
        MockURLProtocol.handler = { req in
            #expect(req.url?.absoluteString == "https://h.example.com/hermes/api/config?profile=work")
            #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
            #expect(req.value(forHTTPHeaderField: "CF-Access-Client-Id") == "cid")
            #expect(req.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "csec")
            return (200, ["Content-Type": "application/json"], Data(#"{"config":{"approvals":{"mode":"smart"}}}"#.utf8))
        }
        let cfg: JSONValue = try await api.get("/api/config", profile: "work")
        #expect(cfg["config"]?["approvals"]?["mode"]?.stringValue == "smart")
    }

    @Test func configPutBodyShape() async throws {
        let api = try makeAPI(mode: .oauth)
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "PUT")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer at")
            #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
            let body = try! JSONDecoder().decode(JSONValue.self, from: req.httpBody ?? Data())
            #expect(body["config"]?["approvals"]?["mode"]?.stringValue == "manual")
            return (200, ["Content-Type": "application/json"], Data(#"{"ok":true}"#.utf8))
        }
        let r: JSONValue = try await api.send("PUT", "/api/config", profile: "work", json: ["config": ["approvals": ["mode": "manual"]]])
        #expect(r["ok"]?.boolValue == true)
    }

    @Test func htmlLoginPageIsDiagnosed() async throws {
        let api = try makeAPI()
        MockURLProtocol.handler = { _ in (200, ["Content-Type": "text/html"], Data("<!DOCTYPE html><html><body>Access</body></html>".utf8)) }
        do {
            let _: JSONValue = try await api.get("/api/status", authenticated: false)
            Issue.record("expected html error")
        } catch let e as HermesAPIError {
            if case .htmlResponse = e { #expect(e.localizedDescription.contains("not the Hermes dashboard API")) } else { Issue.record("wrong error \(e)") }
        }
    }

    @Test func serverDetailSurfacesOn422() async throws {
        let api = try makeAPI()
        MockURLProtocol.handler = { _ in (422, ["Content-Type": "application/json"], Data(#"{"detail":"timeout must be positive"}"#.utf8)) }
        do {
            let _: JSONValue = try await api.send("PUT", "/api/config", json: ["config": [:]])
            Issue.record("expected error")
        } catch let e as HermesAPIError {
            if case .http(let status, let detail) = e { #expect(status == 422); #expect(detail == "timeout must be positive") } else { Issue.record("wrong error") }
        }
    }
}


// MARK: Chat registry (event routing after a reconnect hands a chat a new runtime id)

@MainActor
private final class StubChat: ChatIdentity {
    var runtimeID: String
    var storedID: String
    init(runtimeID: String, storedID: String) { self.runtimeID = runtimeID; self.storedID = storedID }
}

@MainActor
@Suite struct ChatRegistryTests {
    @Test func routesByCurrentRuntimeID() {
        var reg = ChatRegistry<StubChat>()
        let chat = StubChat(runtimeID: "rt-1", storedID: "stored-A")
        reg.add(chat)
        #expect(reg.byRuntime("rt-1") === chat)
        // A resume after reconnect gives the gateway a new runtime id for the same stored session.
        chat.runtimeID = "rt-2"
        #expect(reg.byRuntime("rt-2") === chat)
        #expect(reg.byRuntime("rt-1") == nil)
        #expect(reg.byStored("stored-A") === chat)
    }

    @Test func addReplacesSameStoredID() {
        var reg = ChatRegistry<StubChat>()
        let a = StubChat(runtimeID: "rt-1", storedID: "S")
        let b = StubChat(runtimeID: "rt-9", storedID: "S")
        reg.add(a); reg.add(b)
        #expect(reg.all.count == 1)
        #expect(reg.byStored("S") === b)
        reg.remove(b)
        #expect(reg.all.isEmpty)
    }
}

// MARK: Log grouping

@Suite struct LogEntriesTests {
    @Test func continuationLinesAttachToPreviousEntry() {
        let lines = [
            "2026-09-22 20:39:05,879 INFO tools.registry: check",
            "Traceback (most recent call last):",
            "  File \"x.py\", line 1",
            "2026-09-22T20:39:06 WARNING second",
            "",
            "2026-09-22 20:39:07,000 INFO third",
        ]
        let entries = LogEntries.group(lines)
        #expect(entries.count == 3)
        #expect(entries[0].hasSuffix("line 1"))
        #expect(entries[1] == "2026-09-22T20:39:06 WARNING second")
    }

    @Test func leadingContinuationStillProducesAnEntry() {
        #expect(LogEntries.group(["no timestamp", "2026-01-01 00:00:00 x"]).count == 2)
        #expect(LogEntries.startsEntry("2026-09-22 20:39:05,879 INFO") == true)
        #expect(LogEntries.startsEntry("20:39:05 INFO") == false)
    }
}

// MARK: Tab layout

@Suite struct TabLayoutTests {
    @Test func parseDropsUnknownAndKeepsRequired() {
        let l = TabLayout.parse("files,bogus,cron")
        #expect(l.tabs == [.chats, .files, .cron, .settings])
        #expect(TabLayout.parse(nil) == .default)
        #expect(TabLayout.parse("") == .default)
    }

    @Test func requiredTabsCannotBeRemovedAndSettingsStaysLast() {
        var l = TabLayout.default
        l.set(.chats, enabled: false)
        l.set(.settings, enabled: false)
        #expect(l.contains(.chats) && l.contains(.settings))
        l.set(.bots, enabled: false)          // make room: the default already fills all four slots
        l.set(.system, enabled: true)
        #expect(l.tabs.last == .settings)
        #expect(l.tabs.contains(.system))
        #expect(l.visible(hasBotMode: true) == [.dashboard, .chats, .system, .settings])
        #expect(TabLayout.parse(l.encoded) == l)
    }

    @Test func chatsAndSettingsCanMoveButNotGo() {
        // Any order is kept, Chats included; only the two required tabs are forced back in.
        let moved = TabLayout.parse("bots,settings,chats,dashboard")
        #expect(moved.tabs == [.bots, .settings, .chats, .dashboard])
        let missing = TabLayout.parse("bots,files")
        #expect(missing.contains(.chats) && missing.contains(.settings))
    }

    // The phone's bar holds four; the Mac's sidebar holds every page.
    #if os(macOS)
    @Test func sidebarTakesEveryPage() {
        var l = TabLayout.default
        #expect(!l.isFull)
        for tab in AppModel.AppTab.allCases { l.set(tab, enabled: true) }
        #expect(l.tabs.count == AppModel.AppTab.allCases.count && l.tabs.last == .settings)
        // A layout with more than four survives a round trip.
        #expect(TabLayout.parse(l.encoded).tabs == l.tabs)
    }
    #else
    @Test func tabBarCapsAtFour() {
        var l = TabLayout.default            // chats, bots, files, settings = 4
        #expect(l.isFull)
        l.set(.cron, enabled: true)           // refused
        #expect(l.tabs.count == 4 && !l.contains(.cron))
        l.set(.bots, enabled: false)
        l.set(.cron, enabled: true)
        #expect(l.contains(.cron) && l.tabs.last == .settings)
    }
    #endif

    @Test func botsAlwaysVisible() {
        #expect(TabLayout.default.visible(hasBotMode: false) == [.dashboard, .chats, .bots, .settings])
    }

    #if os(iOS)
    @Test func storedFiveTabLayoutIsTrimmedToFour() {
        // A layout saved by a build that allowed five must not draw five.
        let l = TabLayout.parse("chats,bots,cron,system,settings")
        #expect(l.tabs.count == 4)
        #expect(l.tabs.first == .chats && l.tabs.last == .settings)
        #expect(!l.contains(.system))
    }
    #endif

    @Test func turnStatsPreferExactCounts() {
        let exact = TurnStats.make(outputBefore: 100, outputAfter: 512, streamedCharacters: 9999, seconds: 10.3)
        #expect(exact.exact && exact.outputTokens == 412)
        #expect(exact.label == "412 tokens · 40 tok/s · 10.3s")
        let est = TurnStats.make(outputBefore: nil, outputAfter: 512, streamedCharacters: 400, seconds: 0.2)
        #expect(!est.exact && est.outputTokens == 100 && est.tokensPerSecond == nil)
        #expect(est.label == "~100 tokens · 0.2s")
    }
}


// MARK: Bundled push companion must match the source of truth in server/hermes-push

@Suite struct PushCompanionBundleTests {
    private func repoFile(_ rel: String) -> Data? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try? Data(contentsOf: root.appendingPathComponent(rel))
    }

    @Test func bundledCompanionMatchesRepo() throws {
        let bundle = Bundle(for: AppModel.self)
        for (name, ext) in [("hermes_push", "py"), ("install", "sh")] {
            let url = try #require(bundle.url(forResource: name, withExtension: ext, subdirectory: "hermes-push") ?? bundle.url(forResource: name, withExtension: ext))
            let bundled = try Data(contentsOf: url)
            let source = try #require(repoFile("server/hermes-push/\(name).\(ext)"))
            #expect(bundled == source, "\(name).\(ext) drifted — run Tools/sync-push-companion.sh")
        }
    }

    /// The app shows both numbers side by side, so they must agree.
    @MainActor @Test func companionVersionsAgree() throws {
        let manifestData = try #require(repoFile("server/hermes-push/plugin/vory-push/plugin.yaml"))
        let scriptData = try #require(repoFile("server/hermes-push/hermes_push.py"))
        let manifest = try #require(String(data: manifestData, encoding: .utf8))
        let script = try #require(String(data: scriptData, encoding: .utf8))
        let m = try #require(manifest.firstMatch(of: /version: "([^"]+)"/)?.1)
        let s = try #require(script.firstMatch(of: /VERSION = "([^"]+)"/)?.1)
        #expect(m == s)
        let bundled = PushSetupModel.bundledPluginVersion
        #expect(String(m) == bundled)
    }
}


// MARK: Messages-style separators and bot colours

@Suite struct TranscriptPresentationTests {
    @Test func separatorsOnlyAfterAGap() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let items = [
            TranscriptItem(id: "a", kind: .user(text: "hi", attachments: []), timestamp: t0),
            TranscriptItem(id: "b", kind: .assistant(text: "hello", reasoning: nil, streaming: false), timestamp: t0.addingTimeInterval(30)),
            TranscriptItem(id: "c", kind: .user(text: "later", attachments: []), timestamp: t0.addingTimeInterval(3600)),
        ]
        let rows = TranscriptRowModel.build(items, now: t0.addingTimeInterval(4000))
        #expect(rows[0].separator != nil)
        #expect(rows[1].separator == nil)
        #expect(rows[2].separator?.hasPrefix("Today") == true)
    }

    @Test func botColoursAreStableAndValid() {
        #expect(BotColors.defaultHex(for: "default") == BotColors.defaultHex(for: "default"))
        #expect(BotColors.palette.contains(BotColors.defaultHex(for: "work")))
        #expect(Color(hex: BotColors.defaultHex(for: "ops")) != nil)
        #expect(Color(hex: "nope") == nil)
    }
}


// MARK: Relay payload encryption (vector produced by the companion's Python encryptor)

@Suite struct PushRelayCryptoTests {
    @Test func decryptsCompanionVector() throws {
        // AES-256-GCM, key = 32 zero bytes, nonce = 12 zero bytes, plaintext {"title":"hi","body":"there"}
        let key = Data(repeating: 0, count: 32).base64EncodedString()
        let enc = "AAAAAAAAAAAAAAAAtYU0VDkMDkw9bK26mN+/eh0EeugNhF4ctNCQrAgnBvQ6vurB94SMNXCYlKJV"
        let out = try PushRelay.decrypt(enc, keyBase64: key)
        #expect(out["title"]?.stringValue == "hi")
        #expect(out["body"]?.stringValue == "there")
    }
}


// MARK: Transcript rows in both wire shapes

@Suite struct TranscriptMessageDecodingTests {
    @Test func decodesWebSocketHistoryShape() throws {
        let j = JSONValue.object(["role": "assistant", "text": "hi", "timestamp": 1_700_000_000, "row_id": 7, "reasoning": "why"])
        let m = try j.decode(TranscriptMessage.self)
        #expect(m.role == "assistant" && m.text == "hi" && m.rowId == 7 && m.reasoning == "why")
        #expect(m.timestamp == 1_700_000_000)
    }

    @Test func decodesRawStoredRowFromREST() throws {
        // `/api/sessions/{id}/messages` returns the stored row: content parts, `id`, ISO timestamp, tool_calls.
        let j = JSONValue.object([
            "role": "assistant", "id": 42, "timestamp": "2026-09-23T06:04:11.123456",
            "content": .array([.object(["type": "text", "text": "first"]), .object(["type": "text", "text": "second"])]),
            "tool_calls": .array([.object(["id": "c1", "function": .object(["name": "terminal", "arguments": "{}"])])]),
        ])
        let m = try j.decode(TranscriptMessage.self)
        #expect(m.text == "first\nsecond")
        #expect(m.rowId == 42)
        #expect(m.name == "terminal")
        #expect(m.timestamp != nil)
        let user = try JSONValue.object(["role": "user", "content": "plain", "id": 1]).decode(TranscriptMessage.self)
        #expect(user.text == "plain" && user.role == "user")
        #expect(TranscriptItem.fromHistory(user, index: 0) != nil)
    }

    @Test func roundTripsThroughTheCacheEncoding() throws {
        let m = TranscriptMessage(role: "tool", text: "out", timestamp: 5, rowId: 3, name: "grep", context: "-r foo")
        let data = try JSONEncoder().encode([m])
        let back = try JSONDecoder().decode([TranscriptMessage].self, from: data)
        #expect(back == [m])
    }
}


// MARK: Bot-to-bot deliveries

@Suite struct BotDeliveryTests {
    @Test func quietRunWithInlineMessage() {
        let d = BotDelivery.parse(name: "terminal", context: "hermes -p work chat -q \"Message from 🤖 default: hold the export\"", argsText: nil)
        #expect(d?.target == "work")
        #expect(d?.message == "hold the export")
    }
    @Test func dmTransportWithQueryFileAndEnvPrefix() {
        let cmd = "HERMES_BIN=/home/hermes/.hermes/venv/bin/hermes; $HERMES_BIN -p defender chat --in ~ -c \"Bot Chat\" --create-if-missing -Q --query-file /tmp/hermes-dm-1003/dm-coa-status.md"
        #expect(BotDelivery.parse(name: "terminal", context: cmd, argsText: nil)?.target == "defender")
    }
    @Test func botChatTargetWithoutQuietFlag() {
        #expect(BotDelivery.parse(name: "terminal", context: "hermes --profile mailman chat -c 'Bot Chat' --create-if-missing", argsText: nil)?.target == "mailman")
    }
    @Test func dmRunnerWithTruncatedPreviewAndFullArgs() {
        let preview = "/home/hermes/.hermes/tools/python-3.14.7/bin/python3 /home/hermes/.hermes/hermes-agent/tools/bot_mode_dm.py --run-delivery --author '{\"id\":\"defende"
        let args = "{\"command\": \"/home/hermes/.hermes/tools/python-3.14.7/bin/python3 /home/hermes/.hermes/hermes-agent/tools/bot_mode_dm.py --run-delivery --author '{\\\"id\\\":\\\"defender\\\"}' local /home/hermes/.hermes/profiles/defender/cache/bot_dm/dm-1.md --profile-home /home/hermes/.hermes/profiles/unifi /home/hermes/.hermes/venv/bin/hermes -p unifi chat --in ~ -c 'Bot Chat' --create-if-missing -Q\", \"background\": true}"
        #expect(BotDelivery.parse(name: "terminal", context: preview, argsText: args)?.target == "unifi")
    }
    @Test func dmRunnerPeerFormReadsTheTargetNotTheSender() {
        let cmd = "python3 bot_mode_dm.py --run-delivery peer /tmp/dm.md /usr/local/bin/hermes -p defender peer dm laptop/scribe"
        #expect(BotDelivery.parse(name: "terminal", context: cmd, argsText: nil)?.target == "scribe")
    }
    @Test func peerDM() {
        #expect(BotDelivery.parse(name: "terminal", context: "hermes peer dm laptop/scribe < /tmp/dm.md", argsText: nil)?.target == "scribe")
    }
    @Test func messageAgentTool() {
        let d = BotDelivery.parse(name: "message_agent", context: nil, argsText: "{\"target\": \"@Dr. Foo\", \"message\": \"ping\"}")
        #expect(d?.target == "dr. foo")
        #expect(d?.message == "ping")
    }
    @Test func plainTerminalIsNotADelivery() {
        #expect(BotDelivery.parse(name: "terminal", context: "ls -la /home/hermes/.hermes/profiles/", argsText: nil) == nil)
        #expect(BotDelivery.parse(name: "terminal", context: "hermes chat -q \"what time is it\"", argsText: nil) == nil)
    }
    @Test func inboundRows() {
        #expect(AgentMessage.parse("Message from 🤖 Defender (@defender): all quiet")?.key == "defender")
        #expect(AgentMessage.parse("[Message from agent 'Mailman'] inbox clear")?.body == "inbox clear")
        #expect(AgentMessage.parse("Please message defender for me") == nil)
    }
}
