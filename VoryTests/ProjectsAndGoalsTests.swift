import Foundation
import Testing
@testable import Vory
@testable import VoryCore

// MARK: Chats grouped by project

@Suite struct ChatProjectGroupsTests {
    private func chat(_ id: String, bot: String = "default") -> StoredSession { StoredSession(id: id, title: id, profile: bot) }
    private func project(_ id: String, _ name: String, archived: Bool = false) -> Project {
        Project(id: id, name: name, primaryPath: "/srv/\(id)", archived: archived)
    }

    @Test func projectsComeInTheirOwnOrderAndKeepTheListOrderInside() {
        let chats = [chat("c1"), chat("c2"), chat("c3"), chat("c4")]
        let groups = ChatProjectGroups.make(chats, own: [project("a", "Acme"), project("h", "Homelab")],
                                            membership: ["c1": "h", "c3": "a", "c4": "h"], selected: "default")
        #expect(groups.map { $0.project?.name ?? "none" } == ["Acme", "Homelab", "none"])
        #expect(groups[0].sessions.map(\.id) == ["c3"])
        #expect(groups[1].sessions.map(\.id) == ["c1", "c4"])
        #expect(groups[2].sessions.map(\.id) == ["c2"])
        #expect(groups[2].id == ChatProjectGroups.noneID)
    }

    @Test func aProjectWithNoChatShowsUnlessTheListIsNarrowed() {
        let chats = [chat("c1")]
        let projects = [project("a", "Acme"), project("h", "Homelab")]
        let all = ChatProjectGroups.make(chats, own: projects, membership: ["c1": "a"], selected: "default")
        #expect(all.map { $0.project?.name ?? "none" } == ["Acme", "Homelab"])
        let narrowed = ChatProjectGroups.make(chats, own: projects, membership: ["c1": "a"], selected: "default", keepEmpty: false)
        #expect(narrowed.map { $0.project?.name ?? "none" } == ["Acme"])
    }

    @Test func aChatOfAnArchivedProjectIsListedUnderNoProject() {
        let groups = ChatProjectGroups.make([chat("c1")], own: [project("old", "Old", archived: true)], membership: ["c1": "old"], selected: "default")
        #expect(groups.count == 1)
        #expect(groups[0].project == nil)
        #expect(groups[0].sessions.map(\.id) == ["c1"])
    }

    @Test func everyBotsProjectsAreListedWithItsOwnChats() {
        let chats = [chat("d1"), chat("w1", bot: "work"), chat("w2", bot: "work")]
        let others = ["work": ProjectsStore.Scope(projects: [project("a", "Acme")], membership: ["w1": "a"])]
        // Two bots can each have a project with the same id; the groups stay apart.
        let groups = ChatProjectGroups.make(chats, own: [project("a", "Acme")], membership: ["d1": "a"], selected: "default", others: others)
        #expect(groups.map(\.id) == ["default|a", "work|a", ChatProjectGroups.noneID])
        #expect(groups[0].sessions.map(\.id) == ["d1"])
        #expect(groups[1].sessions.map(\.id) == ["w1"])
        #expect(groups[1].profile == "work")
        #expect(groups[2].sessions.map(\.id) == ["w2"])
    }

    @Test func withNoProjectsAtAllThereIsStillOneGroup() {
        let groups = ChatProjectGroups.make([], own: [], membership: [:], selected: nil)
        #expect(groups.map(\.id) == [ChatProjectGroups.noneID])
    }

    @Test func foldedProjectsAreRememberedAsAList() {
        var raw = ""
        raw = ChatProjectGroups.toggled(raw, "default|a")
        raw = ChatProjectGroups.toggled(raw, ChatProjectGroups.noneID)
        #expect(ChatProjectGroups.collapsed(raw) == ["default|a", ChatProjectGroups.noneID])
        raw = ChatProjectGroups.toggled(raw, "default|a")
        #expect(ChatProjectGroups.collapsed(raw) == [ChatProjectGroups.noneID])
    }
}

// MARK: The status line for a working chat

@MainActor @Suite struct ChatGoalsTests {
    private func user(_ id: String, _ text: String) -> TranscriptItem { TranscriptItem(id: id, kind: .user(text: text, attachments: [])) }
    private func tool(_ name: String, _ context: String) -> TranscriptItem {
        TranscriptItem(id: UUID().uuidString, kind: .tool(ToolActivity(id: UUID().uuidString, name: name, context: context, argsText: nil)))
    }

    @Test func aLineIsDueShortlyAfterATurnStartsAndThenOnlyAsTheWorkMovesOn() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        typealias Pace = ChatGoals.Pace
        // A turn this young gets none: a quick answer is over first.
        #expect(!Pace.due(goal: nil, turn: "u1", turnAge: 1, steps: 0, now: t0))
        #expect(Pace.due(goal: nil, turn: "u1", turnAge: 2, steps: 0, now: t0))
        // Written from the prompt alone: looked at again after two steps and fifteen seconds, not before.
        let first = ChatGoals.Goal(text: "Finding the leak", turn: "u1", madeAt: t0, steps: 0)
        #expect(!Pace.due(goal: first, turn: "u1", turnAge: 30, steps: 5, now: t0.addingTimeInterval(10)))
        #expect(!Pace.due(goal: first, turn: "u1", turnAge: 30, steps: 1, now: t0.addingTimeInterval(60)))
        #expect(Pace.due(goal: first, turn: "u1", turnAge: 30, steps: 2, now: t0.addingTimeInterval(15)))
        // After that: three more steps and forty-five seconds, so it does not rewrite itself on every tool call.
        let later = ChatGoals.Goal(text: "Finding the leak", turn: "u1", madeAt: t0, steps: 4)
        #expect(!Pace.due(goal: later, turn: "u1", turnAge: 90, steps: 6, now: t0.addingTimeInterval(120)))
        #expect(!Pace.due(goal: later, turn: "u1", turnAge: 90, steps: 9, now: t0.addingTimeInterval(30)))
        #expect(Pace.due(goal: later, turn: "u1", turnAge: 90, steps: 7, now: t0.addingTimeInterval(45)))
        // A new turn starts over.
        #expect(Pace.due(goal: later, turn: "u2", turnAge: 3, steps: 0, now: t0.addingTimeInterval(1)))
    }

    @Test func theModelsWordsAreMadeFitForOneLine() {
        #expect(ChatGoals.clean("\"Finding why the export times out.\"") == "Finding why the export times out")
        #expect(ChatGoals.clean("  checking the log host's disk…") == "Checking the log host's disk")
        #expect(ChatGoals.clean("Clearing rotated logs\nAnd a second line the model added") == "Clearing rotated logs")
        #expect(ChatGoals.clean("ok") == nil)
        #expect(ChatGoals.clean("") == nil)
        let long = ChatGoals.clean("Working through every rotated log file on the log host to find which service is filling the disk so quickly")
        #expect(long?.hasSuffix("…") == true)
        #expect((long?.count ?? 99) <= 65)
        #expect(long?.contains("  ") == false)
    }

    @Test func theModelReadsThisTurnsPromptStepsAndLastWords() {
        var items = [user("u0", "an earlier question"), TranscriptItem(id: "a0", kind: .assistant(text: "an earlier answer", reasoning: nil, streaming: false))]
        items.append(user("u1", "The log host is at 94% disk. Can you take a look?"))
        for i in 0..<10 { items.append(tool("terminal", "du -sh /var/log/part\(i)")) }
        items.append(TranscriptItem(id: "a1", kind: .assistant(text: "The journal is the biggest part.", reasoning: nil, streaming: true)))
        items.append(TranscriptItem(id: "s1", kind: .steer(text: "leave nginx alone", status: "delivered")))
        let input = ChatGoals.input(items, earlier: "Checking the disk")
        #expect(input.prompt.hasPrefix("The log host is at 94% disk."))
        #expect(input.prompt.contains("leave nginx alone"))
        #expect(!input.prompt.contains("earlier question"))
        #expect(input.steps.count == 8)
        #expect(input.steps.last == "terminal: du -sh /var/log/part9")
        #expect(input.said == "The journal is the biggest part.")
        #expect(input.earlier == "Checking the disk")
        #expect(ChatGoals.turnKey(items) == "u1")
        #expect(ChatGoals.stepCount(items) == 10)
    }

    /// A clock and a writer the test controls.
    private final class Rig: @unchecked Sendable {
        var time = Date(timeIntervalSince1970: 5_000)
        var answers: [String?] = []
        var asked: [ChatGoals.Input] = []
        let lock = NSLock()
        func answer(_ input: ChatGoals.Input) -> String? {
            lock.lock(); defer { lock.unlock() }
            asked.append(input)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    private func goals(_ rig: Rig) -> ChatGoals {
        let g = ChatGoals()
        g.on = { true }
        g.now = { rig.time }
        g.writer = { input in rig.answer(input) }
        return g
    }

    private func settle(_ g: ChatGoals) async {
        for _ in 0..<200 where g.isWriting { try? await Task.sleep(for: .milliseconds(5)) }
        await Task.yield()
    }

    private func working(_ id: String, turn: String = "u1", steps: Int = 0) -> ChatGoals.Working {
        ChatGoals.Working(id: id, turn: turn, steps: steps, input: ChatGoals.Input(prompt: "Find why the export times out", steps: Array(repeating: "terminal", count: steps), said: nil, earlier: nil))
    }

    @Test func aWorkingChatGetsItsLineAndLosesItWhenTheTurnEnds() async {
        let rig = Rig(); rig.answers = ["Finding why the export times out."]
        let g = goals(rig)
        var live: [String: String] = ["c1": "u1"]
        let turnNow: @MainActor (String) -> String? = { live[$0] }

        g.tick([working("c1")], turnNow: turnNow)
        await settle(g)
        #expect(g.goal(for: "c1") == nil, "nothing is written in a turn's first two seconds")
        #expect(rig.asked.isEmpty)

        rig.time += 3
        g.tick([working("c1")], turnNow: turnNow)
        await settle(g)
        #expect(g.goal(for: "c1") == "Finding why the export times out")

        // Every later look leaves it alone until the work has moved on.
        rig.time += 5
        g.tick([working("c1", steps: 1)], turnNow: turnNow)
        await settle(g)
        #expect(rig.asked.count == 1)

        live = [:]
        g.tick([], turnNow: turnNow)
        #expect(g.goal(for: "c1") == nil)
    }

    @Test func aLineThatComesBackAfterTheTurnChangedIsDropped() async {
        let rig = Rig(); rig.answers = ["Finding the slow query"]
        let g = goals(rig)
        var live: [String: String] = ["c1": "u1"]
        g.tick([working("c1")], turnNow: { live[$0] })
        rig.time += 3
        live["c1"] = "u2"   // the person sent another message while the model was writing
        g.tick([working("c1")], turnNow: { live[$0] })
        await settle(g)
        #expect(g.goal(for: "c1") == nil)
    }

    @Test func aModelThatCannotWriteIsNotAskedAgainRightAway() async {
        let rig = Rig(); rig.answers = [nil, "Finding the slow query"]
        let g = goals(rig)
        let turnNow: @MainActor (String) -> String? = { _ in "u1" }
        g.tick([working("c1")], turnNow: turnNow)
        rig.time += 3
        g.tick([working("c1")], turnNow: turnNow)
        await settle(g)
        #expect(rig.asked.count == 1)
        rig.time += 10
        g.tick([working("c1")], turnNow: turnNow)
        await settle(g)
        #expect(rig.asked.count == 1, "asked again \(rig.asked.count - 1) times within the gap")
        rig.time += ChatGoals.Pace.gap
        g.tick([working("c1")], turnNow: turnNow)
        await settle(g)
        #expect(g.goal(for: "c1") == "Finding the slow query")
    }

    @Test func switchedOffThereIsNoLine() async {
        let rig = Rig(); rig.answers = ["Finding the slow query"]
        let g = goals(rig)
        g.on = { false }
        g.tick([working("c1")], turnNow: { _ in "u1" })
        rig.time += 3
        g.tick([working("c1")], turnNow: { _ in "u1" })
        await settle(g)
        #expect(rig.asked.isEmpty)
        #expect(g.goal(for: "c1") == nil)
    }
}

// MARK: A turn the gateway cut short

@Suite struct InterruptedTurnTests {
    @Test func onlyTheGatewaysOwnSentenceIsACard() {
        #expect(InterruptedTurn.parse("Operation interrupted.") == InterruptedTurn())
        #expect(InterruptedTurn.parse("  Operation interrupted \n") == InterruptedTurn())
        #expect(InterruptedTurn.parse("Operation interrupted: waiting for model response (12.4s elapsed).")?.doing == "waiting for model response (12.4s elapsed)")
        #expect(InterruptedTurn.parse("Operation interrupted during retry (rate limit, attempt 2/5).")?.doing == "during retry (rate limit, attempt 2/5)")
        // A reply that only mentions it, or carries on after it, is an ordinary message.
        #expect(InterruptedTurn.parse("The log says \"Operation interrupted.\" twice.") == nil)
        #expect(InterruptedTurn.parse("Operation interrupted.\nHere is what I had found so far: …") == nil)
        #expect(InterruptedTurn.parse("Operation interrupted by the firewall rule you added") == nil)
        #expect(InterruptedTurn.parse("") == nil)
    }

    @Test func theGatewaysWaitIsReadFromItsConfig() throws {
        let set = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"config": {"dashboard": {"ws_orphan_reap_grace_s": 3600}}}"#.utf8))
        #expect(AwayGrace.read(config: set).seconds == 3600)
        #expect(!AwayGrace.read(config: set).isShort)
        // Not set: the gateway's own twenty seconds apply, which is short.
        let unset = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"config": {"dashboard": {}}}"#.utf8))
        #expect(AwayGrace.read(config: unset).seconds == nil)
        #expect(AwayGrace.read(config: unset).effective == 20)
        #expect(AwayGrace.read(config: unset).isShort)
        // Without the wrapper, and as text, as a hand-edited config can have it.
        let flat = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"dashboard": {"ws_orphan_reap_grace_s": "600"}}"#.utf8))
        #expect(AwayGrace.read(config: flat).seconds == 600)
        // Zero means the gateway never stops a turn for this.
        #expect(!AwayGrace(seconds: 0).isShort)
    }

    @Test func theChoiceIsWrittenWhereTheGatewayReadsIt() {
        let body = AwayGrace.writeBody(seconds: 28_800)
        #expect(body["config"]?["dashboard"]?["ws_orphan_reap_grace_s"]?.doubleValue == 28_800)
        #expect(AwayGrace.choices.map(AwayGrace.label) == ["20 seconds", "10 minutes", "1 hour", "8 hours", "Never stop it"])
    }
}

// MARK: Against a gateway

extension GatewayIntegrationTests {
    /// A stored chat is filed under a project, then under none, and the gateway's own tree says
    /// so each time. Needs a gateway whose first chat may be moved (the mock).
    @MainActor @Test func aChatMovesToAProjectAndOut() async throws {
        guard let env = Self.env, env.token == "mock-token" else { return }
        let store = ConnectionStore()
        let conn = GatewayConnection(name: "e2e projects", gateway: try GatewayURL.normalize(env.url), authMode: .sessionToken)
        try store.upsert(conn, secrets: GatewaySecrets(sessionToken: env.token))
        defer { store.delete(id: conn.id) }
        let rt = GatewayRuntime(connection: conn, store: store)
        await rt.start()
        await rt.projects.refresh()
        try #require(rt.projects.available == true)
        let project = try #require(rt.projects.open.first)
        let list: SessionListResponse = try await rt.api.get("/api/sessions", query: [URLQueryItem(name: "limit", value: "5")], profile: rt.selectedProfile)
        let chat = try #require(list.sessions.first { rt.projects.membership[$0.id] != project.id })
        let was = rt.projects.project(forSession: chat.id)

        try await rt.projects.move([chat.id], to: project)
        #expect(rt.projects.membership[chat.id] == project.id)
        await rt.projects.refreshTree()
        #expect(rt.projects.membership[chat.id] == project.id, "the gateway's tree does not have the chat in the project")

        try await rt.projects.move([chat.id], to: nil)
        #expect(rt.projects.membership[chat.id] == nil)

        // A folder that is not there: the gateway's words come back, and nothing moved.
        var missing = project
        missing.primaryPath = "/nowhere/at/all"
        await #expect(throws: (any Error).self) { try await rt.projects.move([chat.id], to: missing) }
        #expect(rt.projects.membership[chat.id] == nil)

        if let was { try await rt.projects.move([chat.id], to: was) }
        await rt.stop()
    }
}
