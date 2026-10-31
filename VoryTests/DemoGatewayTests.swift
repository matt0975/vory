import Foundation
import Testing
@testable import VoryCore

/// The demo's gateway (#392) read through the real client: a `GatewayRuntime` on the demo transport, its socket
/// and API exactly as for a gateway on the network, and the answers decoded by the app's own models.
@MainActor
@Suite(.serialized) struct DemoGatewayTests {
    private func runtime() -> GatewayRuntime {
        let name = "dev.vory.tests.demogw." + UUID().uuidString
        let store = ConnectionStore(defaults: UserDefaults(suiteName: name)!, connections: [])
        return GatewayRuntime(connection: .demo, store: store, transport: .demo(DemoGateway(pace: .quick)))
    }

    @Test func theDemoConnectsAndListsItsBotsChatsAndNumbers() async throws {
        let rt = runtime()
        await rt.start()
        defer { Task { await rt.stop() } }
        #expect(rt.socketState == .open)
        #expect(rt.profiles.map(\.name) == DemoContent.bots.map(\.name))

        let sessions: SessionListResponse = try await rt.api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"),
                                                                                         URLQueryItem(name: "limit", value: "50")])
        #expect(sessions.sessions.count == DemoContent.chats.count)
        #expect(sessions.sessions.contains { $0.id == DemoContent.longChatID })

        let usage: UsageAnalytics = try await rt.api.get("/api/analytics/usage", query: [URLQueryItem(name: "days", value: "30")])
        #expect((usage.daily?.count ?? 0) > 15)
        #expect((usage.daily ?? []).allSatisfy { ($0.sessions ?? 0) > 0 })

        let files: FilesListing = try await rt.api.get("/api/files", query: [])
        #expect(!files.entries.isEmpty)
    }

    @Test func everyChatOpensWithItsHistory() async throws {
        let rt = runtime()
        await rt.start()
        defer { Task { await rt.stop() } }
        for chat in DemoContent.chats {
            let c = try await rt.openChat(storedID: chat.id, title: chat.title, profile: chat.bot, waitForResume: true)
            #expect(!c.items.isEmpty, "\(chat.title) opened empty")
            #expect(c.resumeError == nil, "\(chat.title): \(c.resumeError ?? "")")
        }
        // The long chat opens whole: all its exchanges, none left to load in (#491).
        let long = try await rt.openChat(storedID: DemoContent.longChatID, title: nil, profile: "beacon", waitForResume: true)
        #expect(long.items.filter { if case .user = $0.kind { true } else { false } }.count == DemoContent.maxExchanges)
    }

    /// No demo chat is longer than four exchanges (#491): a longer one jumped while its older rows loaded in, and the
    /// window that loads them as you scroll (#345) is for real chats.
    @Test func everyChatHoldsAtMostFourExchanges() {
        #expect(DemoContent.maxExchanges == 4)
        for chat in DemoContent.chats {
            let asked = chat.rows().filter { $0.role == "user" }.count
            #expect((1...DemoContent.maxExchanges).contains(asked), "\(chat.title): \(asked) exchanges")
        }
    }

    @Test func projectsTheBoardAndThePictureLoad() async throws {
        let rt = runtime()
        await rt.start()
        defer { Task { await rt.stop() } }
        await rt.projects.refresh()
        #expect(rt.projects.projects.count == DemoContent.projects.count)
        await rt.kanban.refresh()
        #expect(rt.kanban.board?.columns.reduce(0) { $0 + $1.tasks.count } == DemoContent.tasks.count)
        let png = try await GatewayMediaAPI(api: rt.api).fetch(path: "/home/demo/images/ereader-battery.png")
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    /// Every other read a page makes, decoded with the app's own model, or checked for the keys a view reads by hand from
    /// JSONValue (#392 review): a field the demo misnames or leaves out fails here rather than as a blank page.
    @Test func everyReadDecodesWithTheAppsOwnModels() async throws {
        let rt = runtime()
        await rt.start()
        defer { Task { await rt.stop() } }
        let api = rt.api
        // The bots' pages: each bot's model menu, skills, tools, keys and soul.
        let profiles: ProfilesResponse = try await api.get("/api/profiles")
        #expect(profiles.profiles.map(\.name) == DemoContent.bots.map(\.name))
        for bot in DemoContent.bots.map(\.name) {
            let options: ModelOptionsResult = try await api.get("/api/model/options", profile: bot)
            #expect(!options.providers.isEmpty, "\(bot): no providers")
            let skills: [SkillInfo] = try await api.get("/api/skills", profile: bot)
            #expect(!skills.isEmpty, "\(bot): no skills")
            let toolsets: [ToolsetInfo] = try await api.get("/api/tools/toolsets", profile: bot)
            #expect(!toolsets.isEmpty, "\(bot): no tools")
            let _: [String: EnvVarInfo] = try await api.get("/api/env", profile: bot)
            let soul: JSONValue = try await api.get("/api/profiles/\(bot)/soul")
            #expect(soul["content"]?.stringValue?.isEmpty == false, "\(bot): no soul")
        }
        // Search and the store's numbers (Settings, the chat list's search).
        let found: SessionListResponse = try await api.get("/api/sessions/search", query: [URLQueryItem(name: "q", value: "NAS")])
        #expect(!found.sessions.isEmpty)
        let stats: JSONValue = try await api.get("/api/sessions/stats")
        #expect((stats["total"]?.intValue ?? 0) == DemoContent.chats.count)
        #expect(stats["by_source"]?.objectValue?.isEmpty == false)
        // Groups: the list and each room's log (Bots).
        let groups: GroupsListResult = try await rt.rpc("groups.list", ["limit": 50]).decode()
        #expect(!groups.rooms.isEmpty)
        for room in groups.rooms {
            let log: GroupsLogResult = try await rt.rpc("groups.log", ["room_id": .string(room.roomId), "since_seq": 0, "limit": 200]).decode()
            #expect(!log.events.isEmpty, "\(room.roomId): an empty log")
        }
        // The board: each task's page and its log.
        let board = KanbanAPI(api: api)
        for task in DemoContent.tasks {
            let detail = try await board.task(task.id)
            #expect(detail.task.id == task.id)
            _ = try await board.log(task.id)
        }
        // A file read as the pictures' fallback reads it (GatewayMediaAPI), and the long chat's context ring.
        let read: GatewayMediaAPI.DataURLReply = try await api.get("/api/files/read", query: [URLQueryItem(name: "path", value: "/home/demo/trip/packing.md")])
        #expect((read.data_url ?? read.dataUrl)?.hasPrefix("data:text/markdown;base64,") == true)
        let long = try await rt.openChat(storedID: DemoContent.longChatID, title: nil, profile: "beacon", waitForResume: true)
        let context = try await long.contextBreakdown()
        #expect(!context.categories.isEmpty && context.contextMax > 0)
    }

    /// The demo answers what a route allows with reads only, so the app offers no rename for its bots (the page tour's
    /// one tripwire hit), and the question trips nothing.
    @Test func theDemosBotsOfferNoRename() async throws {
        let gw = DemoGateway(pace: .quick)
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "dev.vory.tests.demogw." + UUID().uuidString)!, connections: [])
        let rt = GatewayRuntime(connection: .demo, store: store, transport: .demo(gw))
        await rt.start()
        defer { Task { await rt.stop() } }
        let allowed = try await rt.api.allowedMethods("/api/profiles/_probe")
        #expect(allowed == ["GET"])
        #if DEBUG
        #expect(await gw.tripwire.isEmpty)
        #endif
    }

    /// A chat deleted, pinned and archived from the list stays so for the demo's life: the edits go as the app sends them
    /// (`SessionMutation`, which finds no snapshot route on the demo and sends them plainly, #467) and the list read back
    /// agrees, with nothing on the wire. Dropped instead, the app's own reload brought a deleted chat back and put a pin
    /// back. A fresh demo starts from its seed again.
    @Test func aChatsDeletePinAndArchiveStayForTheDemosLife() async throws {
        let gw = DemoGateway(pace: .quick)
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "dev.vory.tests.demogw." + UUID().uuidString)!, connections: [])
        let rt = GatewayRuntime(connection: .demo, store: store, transport: .demo(gw))
        await rt.start()
        defer { Task { await rt.stop() } }
        func rows(_ g: DemoGateway) async throws -> [String: [String: Any]] {
            let a = await g.rest(method: "GET", url: URL(string: "http://\(DemoGateway.host)/api/sessions?archived=include")!, body: Data(), contentType: "")
            let list = try #require((try JSONSerialization.jsonObject(with: a.body) as? [String: Any])?["sessions"] as? [[String: Any]])
            return Dictionary(uniqueKeysWithValues: list.compactMap { r in (r["id"] as? String).map { ($0, r) } })
        }
        let before = try await rows(gw)
        let loose = DemoContent.chats.filter { !$0.pinned }
        try #require(loose.count >= 2)
        let gone = DemoContent.chats[0], pin = loose[0], box = loose[1]
        try #require(gone.id != pin.id && gone.id != box.id)

        try await SessionMutation.delete(rt.api, id: gone.id, profile: gone.bot)
        try await SessionMutation.patch(rt.api, id: pin.id, profile: pin.bot, fields: ["pinned": .bool(true)])
        try await SessionMutation.patch(rt.api, id: box.id, profile: box.bot, fields: ["archived": .bool(true)])
        let after = try await rows(gw)
        #expect(after[gone.id] == nil, "the deleted chat is listed again")
        #expect(after.count == before.count - 1)
        #expect(after[pin.id]?["pinned"] as? Bool == true, "the pin did not stay")
        #expect(after[box.id]?["archived"] as? Bool == true, "the archive did not stay")
        // Unpinned again; and a delete of the chat already gone counts as done, as a Hermes before the fence answers 404.
        try await SessionMutation.patch(rt.api, id: pin.id, profile: pin.bot, fields: ["pinned": .bool(false)])
        #expect(try await rows(gw)[pin.id]?["pinned"] as? Bool == false)
        try await SessionMutation.delete(rt.api, id: gone.id, profile: gone.bot)
        #if DEBUG
        let trips = await gw.tripwire
        #expect(trips.isEmpty, "the edits tripped \(trips)")
        #endif

        // A fresh demo: its seed, untouched.
        let fresh = try await rows(DemoGateway(pace: .quick))
        #expect(fresh.count == before.count && fresh[gone.id] != nil)
        #expect(fresh[pin.id]?["pinned"] as? Bool == false && fresh[box.id]?["archived"] as? Bool == false)
    }

    /// The list leaves archived chats out unless asked for, as Hermes does (#474): `archived=only` lists them alone and
    /// `archived=include` lists both, marked, so the app's Archived filter gets what it asks for.
    @Test func theListHonoursArchivedAsHermesDoes() async throws {
        let gw = DemoGateway(pace: .quick)
        func ids(_ query: String) async throws -> Set<String> {
            let a = await gw.rest(method: "GET", url: URL(string: "http://\(DemoGateway.host)/api/sessions\(query)")!, body: Data(), contentType: "")
            let list = try #require((try JSONSerialization.jsonObject(with: a.body) as? [String: Any])?["sessions"] as? [[String: Any]])
            return Set(list.compactMap { $0["id"] as? String })
        }
        let all = Set(DemoContent.chats.map(\.id))
        let box = DemoContent.chats[1].id
        let archive = try JSONSerialization.data(withJSONObject: ["archived": true])
        #expect(await gw.rest(method: "PATCH", url: URL(string: "http://\(DemoGateway.host)/api/sessions/\(box)")!,
                              body: archive, contentType: "application/json").status == 200)
        #expect(try await ids("") == all.subtracting([box]), "archived listed by default")
        #expect(try await ids("?archived=exclude") == all.subtracting([box]))
        #expect(try await ids("?archived=only") == [box])
        #expect(try await ids("?archived=include") == all)
    }

    /// The NAS chat's tool steps keep the names its history gives them, in order: #387's naming reads a row's own name
    /// before it matches a result to its call, so "read file" and "patch" don't all come out as one name.
    @Test func theNASChatsToolStepsKeepTheirNames() async throws {
        let rt = runtime()
        await rt.start()
        defer { Task { await rt.stop() } }
        let nas = try #require(DemoContent.chats.first { $0.title == "Why is the NAS slow tonight?" })
        let expected = nas.rows().filter { $0.role == "tool" }.compactMap(\.name)
        #expect(Set(expected).count > 2)
        let chat = try await rt.openChat(storedID: nas.id, title: nas.title, profile: nas.bot, waitForResume: true)
        let names = chat.items.compactMap { item -> String? in if case .tool(let t) = item.kind { return t.name }; return nil }
        #expect(names == expected)
    }

    /// Each file the Files page lists opens, shares and saves as its own bytes (FilesView's GET /api/files/download):
    /// without the route the catch-all's empty object was saved as the file, "{}".
    @Test func everyFileDownloadsAsItsOwnBytes() async throws {
        let rt = runtime()
        await rt.start()
        defer { Task { await rt.stop() } }
        let picture = "/home/demo/images/ereader-battery.png"
        let paths = DemoContent.files.filter { !$0.directory }.map(\.path) + [picture]
        #expect(paths.count > 3)
        for path in paths {
            let url = try await rt.api.download("/api/files/download", query: [URLQueryItem(name: "path", value: path)])
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let data = try Data(contentsOf: url)
            #expect(url.lastPathComponent == (path as NSString).lastPathComponent)
            if let text = DemoContent.files.first(where: { $0.path == path })?.text {
                #expect(data == Data(text.utf8), "\(path) came down as \(data.count) bytes")
            } else {
                #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "\(path) is not a PNG")
            }
        }
    }

    /// The route's own answer: the bytes' media type and an attachment naming the file; a folder or an unknown path is a 404.
    @Test func aDownloadIsAnAttachmentAndAMissingFileIsA404() async {
        let gw = DemoGateway(pace: .quick)
        func get(_ path: String) async -> DemoGateway.HTTPAnswer {
            var c = URLComponents(string: "http://\(DemoGateway.host)/api/files/download")!
            c.queryItems = [URLQueryItem(name: "path", value: path)]
            return await gw.rest(method: "GET", url: c.url!, body: Data(), contentType: "")
        }
        let text = await get("/home/demo/trip/packing.md")
        #expect(text.status == 200)
        #expect(text.contentType == "text/markdown")
        #expect(text.headers["Content-Disposition"] == "attachment; filename=\"packing.md\"")
        let picture = await get("/home/demo/images/ereader-battery.png")
        #expect(picture.status == 200 && picture.contentType == "image/png")
        #expect(await get("/home/demo/trip").status == 404)
        #expect(await get("/home/demo/no-such-file.txt").status == 404)
    }

    #if DEBUG
    /// What the demo lacks trips the wire once each, and what it has doesn't (the page tour reads the same list).
    @Test func aRouteOrMethodTheDemoLacksTripsTheWire() async {
        let gw = DemoGateway(pace: .quick)
        func get(_ path: String) async -> Int {
            await gw.rest(method: "GET", url: URL(string: "http://\(DemoGateway.host)\(path)")!, body: Data(), contentType: "").status
        }
        #expect(await get("/api/status") == 200)
        #expect(await get("/api/plugins/kanban/board") == 200)
        // The snapshot asked before a chat's delete, pin or archive: no such route, as on a Hermes before the fence (#467).
        #expect(await get("/api/sessions/\(DemoContent.chats[0].id)/mutation-snapshot") == 404)
        #expect(await gw.tripwire.isEmpty)
        #expect(await get("/api/no-such-route") == 200)
        #expect(await get("/api/no-such-route") == 200)
        #expect(await get("/api/plugins/kanban/no-such-route") == 404)
        // A socket method it doesn't know, sent as the app sends one.
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "dev.vory.tests.demogw." + UUID().uuidString)!, connections: [])
        let rt = GatewayRuntime(connection: .demo, store: store, transport: .demo(gw))
        await rt.start()
        defer { Task { await rt.stop() } }
        await #expect(throws: (any Error).self) { _ = try await rt.rpc("no.such.method") }
        #expect(await gw.tripwire == ["GET /api/no-such-route", "board GET /no-such-route", "rpc no.such.method"])
    }
    #endif

    /// A demo session takes every request it makes: one for another host fails as if the device were offline, and is
    /// counted, rather than going to the network.
    @Test func aDemoSessionSendsNothingAnywhereElse() async throws {
        let rt = runtime()
        await rt.start()
        defer { Task { await rt.stop() } }
        #expect(DemoURLProtocol.canInit(with: URLRequest(url: URL(string: "https://gateway.example.test/api/status")!)))
        let before = DemoURLProtocol.refused
        let session = rt.transport.makeHTTPSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: URL(string: "https://gateway.example.test/api/status")!)
            Issue.record("a request for another host was answered")
        } catch let e as URLError {
            #expect(e.code == .notConnectedToInternet)
        }
        #expect(DemoURLProtocol.refused == before + 1)
    }

    /// Two demos at once (a runtime made while another stops) each answer their own runtime's requests, and a runtime
    /// that has stopped reaches no demo at all.
    @Test func eachDemoAnswersItsOwnRuntimeUntilItStops() async throws {
        let earlier = Date(timeIntervalSince1970: 1_790_000_000), later = Date(timeIntervalSince1970: 1_790_500_000)
        func make(_ now: Date) -> GatewayRuntime {
            let store = ConnectionStore(defaults: UserDefaults(suiteName: "dev.vory.tests.demogw." + UUID().uuidString)!, connections: [])
            return GatewayRuntime(connection: .demo, store: store, transport: .demo(DemoGateway(pace: .quick, now: now)))
        }
        let a = make(earlier), b = make(later)
        await a.start(); await b.start()
        func newest(_ rt: GatewayRuntime) async throws -> Double {
            let r: JSONValue = try await rt.api.get("/api/sessions")
            return r["sessions"]?.arrayValue?.compactMap { $0["last_active"]?.doubleValue }.max() ?? 0
        }
        let fromA = try await newest(a), fromB = try await newest(b)
        #expect(fromA < earlier.timeIntervalSince1970 + 1 && fromA > earlier.timeIntervalSince1970 - 86_400 * 30)
        #expect(fromB > later.timeIntervalSince1970 - 86_400 * 30)
        await a.stop()
        let before = DemoURLProtocol.refused
        await #expect(throws: (any Error).self) { _ = try await newest(a) }
        #expect(DemoURLProtocol.refused == before + 1)
        #expect(try await newest(b) == fromB)
        await b.stop()
    }

    @Test func theDemoWordsHaveNoEmDashesOrLinks() {
        var words: [String] = DemoContent.bots.flatMap { [$0.display, $0.title] }
        words += DemoContent.chats.flatMap { [$0.title, $0.preview] + $0.rows().map(\.text) + $0.rows().compactMap(\.reasoning) }
        words += DemoContent.files.compactMap(\.text) + DemoContent.tasks.map(\.title) + DemoContent.groupLog.map(\.text)
        for turn in [DemoContent.everyday, DemoContent.cleanup] {
            words += [turn.reasoning, turn.opening, turn.closing] + turn.steps.flatMap { [$0.context, $0.summary, $0.output] }
            if let a = turn.approval { words += [a.ask, a.description, a.done, a.denied, a.ran.summary] }
        }
        for w in words {
            #expect(!w.contains("\u{2014}"), "an em dash in: \(w.prefix(60))")
            #expect(!w.contains("http://") && !w.contains("https://"), "a link in: \(w.prefix(60))")
        }
    }

    /// Scheduled tasks in the demo (#428's + on Scheduled Tasks): none at first; a task made with the + is listed, and its
    /// page's actions (pause, Run now, Save, delete) act on it in memory; a create without a schedule is refused as the
    /// gateway refuses it (422).
    @Test func scheduledTasksAreKeptForTheDemosLife() async throws {
        let rt = runtime()
        await rt.start()
        defer { Task { await rt.stop() } }
        let empty: JSONValue = try await rt.api.get("/api/cron/jobs")
        #expect(empty["jobs"]?.arrayValue?.isEmpty == true)
        let targets: JSONValue = try await rt.api.get("/api/cron/delivery-targets")
        #expect(targets["targets"]?.arrayValue?.first?["id"]?.stringValue == "local")

        let made: JSONValue = try await rt.api.send("POST", "/api/cron/jobs", profile: "gizmo", json: .object([
            "name": .string("Morning check"), "schedule": .string("0 9 * * *"), "prompt": .string("Check last night's backups."),
            "deliver": .string("local")]))
        let id = try #require(made["job_id"]?.stringValue)
        #expect(made["profile"]?.stringValue == "gizmo")
        let listed: JSONValue = try await rt.api.get("/api/cron/jobs")
        #expect(listed["jobs"]?.arrayValue?.map { $0["job_id"]?.stringValue } == [id])

        do {
            let _: JSONValue = try await rt.api.send("POST", "/api/cron/jobs", json: .object(["name": .string("No time given")]))
            Issue.record("a task without a schedule was made")
        } catch HermesAPIError.http(let status, _) {
            #expect(status == 422)
        }

        let paused: JSONValue = try await rt.api.send("POST", "/api/cron/jobs/\(id)/pause", body: EmptyBody())
        #expect(paused["enabled"]?.boolValue == false)
        let ran: JSONValue = try await rt.api.send("POST", "/api/cron/jobs/\(id)/trigger", body: EmptyBody())
        #expect(ran["last_status"]?.stringValue == "ok" && ran["last_run_at"]?.stringValue != nil)
        let _: JSONValue = try await rt.api.send("PUT", "/api/cron/jobs/\(id)", json: .object(["updates": .object(["schedule": .string("30 8 * * 1")])]))
        let one: JSONValue = try await rt.api.get("/api/cron/jobs/\(id)")
        #expect(one["schedule"]?.stringValue == "30 8 * * 1")
        let _: JSONValue = try await rt.api.send("DELETE", "/api/cron/jobs/\(id)", body: EmptyBody())
        let after: JSONValue = try await rt.api.get("/api/cron/jobs")
        #expect(after["jobs"]?.arrayValue?.isEmpty == true)

        // A fresh demo has none (nothing outlives the demo it was made in).
        let fresh = runtime()
        await fresh.start()
        defer { Task { await fresh.stop() } }
        let none: JSONValue = try await fresh.api.get("/api/cron/jobs")
        #expect(none["jobs"]?.arrayValue?.isEmpty == true)
    }
}
