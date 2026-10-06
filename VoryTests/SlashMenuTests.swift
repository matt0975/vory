import Foundation
import Testing
import VoryCore
@testable import Vory

/// The composer's chooser: "/" lists the gateway's commands and skills, "/model " its models,
/// narrowed and ranked as the text is typed (SlashMenu).
@Suite struct SlashMenuTests {
    typealias M = SlashMenu

    // MARK: Where the chooser stands

    @Test func aSlashAtTheStartOpensTheCommandsAndModelAndASpaceOpensTheModels() throws {
        let bare = try #require(M.context(for: "/"))
        #expect(bare.kind == .command && bare.query == "" && bare.wholeText && bare.anchor == 0)
        #expect(M.context(for: "/Mo")?.query == "mo")
        // "/model" is still a command being typed; the space after it opens the model list.
        #expect(M.context(for: "/model")?.kind == .command)
        let models = try #require(M.context(for: "/model "))
        #expect(models.kind == .model && models.query == "" && models.anchor == 7)
        #expect(M.context(for: "/MODEL Sonnet")?.query == "sonnet")
        #expect(M.context(for: "/model  mini")?.query == "mini")
        // More than one word after "/model" (a provider flag) is typed by hand.
        #expect(M.context(for: "/model mini --provider workshop") == nil)
        #expect(M.context(for: "hello /there") == nil)
        #expect(M.context(for: "") == nil)
    }

    @Test func aLaterSlashWordIsAnArgumentNotTheWholeMessage() throws {
        let later = try #require(M.context(for: "/code-review then /sta"))
        #expect(later.kind == .command && later.query == "sta")
        #expect(!later.wholeText)
        #expect(later.anchor == "/code-review then ".count)
        // A word after the command closes the list (its argument is being typed).
        #expect(M.context(for: "/compress here") == nil)
    }

    // MARK: Scoring

    @Test func theNameOutranksTheDescriptionAndExactOutranksPrefixOutranksAnywhere() {
        #expect(M.score(name: "status", detail: "", query: "status") == 0)
        #expect(M.score(name: "code-review", detail: "", query: "review") == 0)
        #expect(M.score(name: "status", detail: "", query: "sta") == 1)
        #expect(M.score(name: "code-review", detail: "", query: "rev") == 1)
        #expect(M.score(name: "rollback", detail: "", query: "llb") == 2)
        #expect(M.score(name: "compress", detail: "Summarize the context", query: "summarize") == 3)
        #expect(M.score(name: "compress", detail: "Summarize the context", query: "summ") == 4)
        #expect(M.score(name: "compress", detail: "Summarize the context", query: "mari") == 5)
        #expect(M.score(name: "compress", detail: "Summarize the context", query: "xyz") == nil)
    }

    // MARK: Commands and skills

    /// Shaped like the gateway's `commands.catalog`: names with their "/", the built-ins'
    /// argument modes and surfaces, the skills' use and origin, aliases in `canon`.
    static let catalog = CommandsCatalog(
        pairs: [["/status", "Show session status"], ["/compress", "Summarize the context to free space"],
                ["/new", "Start a new session (usage: /new [name])"], ["/model", "Switch model"],
                ["/approve", "Approve a pending command"], ["/cron", "Manage scheduled jobs"],
                ["/skills", "Search, install, inspect, or manage skills"], ["/my-quick", "exec: uptime"],
                ["/code-review", "Review a diff for correctness bugs"], ["/incident-writeup", "Turn an incident timeline into a postmortem"],
                ["/academic-paper-acquisition", "Find and fetch papers"], ["/spreadsheet-tools", "Read, edit and chart spreadsheets"]],
        canon: ["/new": "/new", "/reset": "/new", "/compress": "/compress", "/compact": "/compress"],
        commands: ["/status": .init(), "/compress": .init(argumentMode: "text"), "/new": .init(argumentMode: "text"),
                   "/model": .init(argumentMode: "text", desktop: "hidden"), "/approve": .init(argumentMode: "text", desktop: "messaging"),
                   "/cron": .init(argumentMode: "text", desktop: "terminal"), "/skills": .init(argumentMode: "options", desktop: "settings")],
        skills: ["/code-review": .init(usage: 42, origin: "bundled"), "/incident-writeup": .init(usage: 7, origin: "hub"),
                 "/academic-paper-acquisition": .init(usage: 7, origin: "local"), "/spreadsheet-tools": .init(usage: 0, origin: "bundled")])

    @Test func aBareSlashListsTheCommandsAToZThenTheSkillsMostUsedFirst() {
        let items = M.commandItems(Self.catalog, query: "")
        #expect(items.map(\.name) == ["approve", "compress", "model", "my-quick", "new", "status",
                                      "code-review", "academic-paper-acquisition", "incident-writeup"])
        #expect(items.prefix(6).allSatisfy { $0.kind == .command })
        #expect(items.suffix(3).allSatisfy { $0.kind == .skill })
    }

    @Test func whatTheAppCannotRunIsLeftOutButItsOwnCommandsStay() {
        let names = Set(M.commandItems(Self.catalog, query: "").map(\.name))
        // Terminal-only and Settings-only commands are not offered...
        #expect(!names.contains("cron") && !names.contains("skills"))
        // ...but the ones the app runs itself are, whatever the gateway says of other clients.
        #expect(names.contains("approve") && names.contains("model"))
        // A search does not bring them back either.
        #expect(M.commandItems(Self.catalog, query: "cron").isEmpty)
    }

    @Test func aBundledSkillNobodyUsedIsOnlyFoundBySearching() {
        #expect(!M.commandItems(Self.catalog, query: "").contains { $0.name == "spreadsheet-tools" })
        #expect(M.commandItems(Self.catalog, query: "spread").first?.name == "spreadsheet-tools")
    }

    @Test func aCommandThatTakesNothingRunsOnAPickAndTheRestGoInTheField() {
        let items = Dictionary(uniqueKeysWithValues: M.commandItems(Self.catalog, query: "").map { ($0.name, $0) })
        #expect(items["status"]?.runsOnPick == true)
        #expect(items["approve"]?.runsOnPick == true)
        // The app opens a new chat for /new whatever follows it.
        #expect(items["new"]?.runsOnPick == true)
        #expect(items["compress"]?.runsOnPick == false)
        // /model opens the model list rather than running bare.
        #expect(items["model"]?.runsOnPick == false)
        // A command the catalog does not describe (a quick command) waits in the field.
        #expect(items["my-quick"]?.runsOnPick == false)
        // Skills take what follows them as their task.
        #expect(items["code-review"]?.runsOnPick == false)
    }

    @Test func aSearchRanksByTheMatchThenCommandsBeforeSkillsThenUse() {
        #expect(M.commandItems(Self.catalog, query: "rev").map(\.name) == ["code-review"])
        // "co": the start of "compress" and of "code" in "code-review"; the command first.
        #expect(M.commandItems(Self.catalog, query: "co").prefix(2).map(\.name) == ["compress", "code-review"])
        // Skills on the same match ("e" somewhere in each name): the more used first, then by name.
        #expect(M.commandItems(Self.catalog, query: "e").filter { $0.kind == .skill }.map(\.name)
                == ["code-review", "academic-paper-acquisition", "incident-writeup", "spreadsheet-tools"])
        // A word of the description finds a command whose name does not match.
        #expect(M.commandItems(Self.catalog, query: "summarize").map(\.name) == ["compress"])
        // The start of a word in the name beats the same letters inside a description.
        #expect(M.commandItems(Self.catalog, query: "in").first?.name == "incident-writeup")
    }

    @Test func anAliasTypedInFullFindsItsCommand() {
        #expect(M.commandItems(Self.catalog, query: "reset").first?.name == "new")
        #expect(M.commandItems(Self.catalog, query: "compact").first?.name == "compress")
    }

    @Test func namesWithoutTheirSlashMatchTheMapsKeyedWithIt() {
        // The mock gateway (and some gateways) list the names bare.
        let bare = CommandsCatalog(pairs: [["status", "Show status"], ["code-review", "Review a diff"], ["cron", "Jobs"]],
                                   commands: ["/status": .init(), "/cron": .init(desktop: "terminal")],
                                   skills: ["/code-review": .init(usage: 1)])
        let items = M.commandItems(bare, query: "")
        #expect(items.map(\.name) == ["status", "code-review"])
        #expect(items.first?.runsOnPick == true)
        #expect(items.last?.kind == .skill)
    }

    @Test func theGatewaysCatalogDecodesWithItsSkillsAndArgumentModes() throws {
        let json = """
        {"pairs": [["/status", "Show session status"], ["/code-review", "Review a diff"]],
         "canon": {"/status": "/status"},
         "commands": {"/status": {"argument_mode": null, "desktop": null}, "/cron": {"argument_mode": "text", "desktop": "terminal"}},
         "skills": {"/code-review": {"usage": 3, "origin": "bundled"}}, "skill_count": 1, "warning": ""}
        """
        let c = try JSONCoding.decoder.decode(CommandsCatalog.self, from: Data(json.utf8))
        #expect(c.skills?["/code-review"]?.usage == 3)
        #expect(c.skills?["/code-review"]?.origin == "bundled")
        #expect(c.commands?["/cron"]?.desktop == "terminal")
        let items = M.commandItems(c, query: "")
        #expect(items.map(\.name) == ["status", "code-review"])
        #expect(items.map(\.kind) == [.command, .skill])
    }

    // MARK: Models

    static let options = ModelOptionsResult(providers: [
        ModelProvider(slug: "local", name: "Local", models: ["local/assistant", "local/assistant-mini"], authenticated: false,
                      featuredModels: ["local/assistant"]),
        ModelProvider(slug: "workshop", name: "Workshop", models: ["workshop/assistant-large", "workshop/assistant", "workshop/assistant-mini", "workshop/assistant-legacy"],
                      authenticated: true, featuredModels: ["workshop/assistant-large", "workshop/assistant", "workshop/assistant-mini"]),
        ModelProvider(slug: "free", name: "Free tier", models: ["free/assistant-open"], authenticated: true),
    ])

    @Test func aBareModelListsTheFeaturedModelsUsableProvidersFirst() {
        let items = M.modelItems(Self.options, current: "workshop/assistant", query: "")
        #expect(items.map(\.name) == ["free/assistant-open", "workshop/assistant-large", "workshop/assistant", "workshop/assistant-mini", "local/assistant"])
        #expect(items.filter(\.current).map(\.name) == ["workshop/assistant"])
        #expect(items.filter(\.needsKey).map(\.name) == ["local/assistant"])
        #expect(items.allSatisfy { $0.kind == .model })
        #expect(items[1].provider == "workshop" && items[1].detail == "Workshop")
    }

    @Test func theChatsOwnModelIsListedEvenWhenItIsNotFeatured() {
        let items = M.modelItems(Self.options, current: "workshop/assistant-legacy", query: "")
        #expect(items.contains { $0.name == "workshop/assistant-legacy" && $0.current })
    }

    @Test func aModelSearchLooksThroughEveryModelAndRanksTheBestMatchFirst() {
        // "mini" is a whole word of two models: both, the usable provider's first.
        #expect(M.modelItems(Self.options, current: "", query: "mini").map(\.id) == ["workshop|workshop/assistant-mini", "local|local/assistant-mini"])
        // Not featured, still found.
        #expect(M.modelItems(Self.options, current: "", query: "legacy").map(\.name) == ["workshop/assistant-legacy"])
        // The provider's name finds its models, after any match in a model's own name.
        let free = M.modelItems(Self.options, current: "", query: "free")
        #expect(free.first?.name == "free/assistant-open")
        #expect(M.modelItems(Self.options, current: "", query: "zzz").isEmpty)
    }

    /// The same id under two providers: on a relay (an aggregator) and at its maker.
    static let sharedID = ModelOptionsResult(providers: [
        ModelProvider(slug: "workshop", name: "Workshop", models: ["workshop/assistant", "workshop/assistant-mini"], authenticated: true,
                      featuredModels: ["workshop/assistant-mini"]),
        ModelProvider(slug: "relay", name: "Relay", models: ["workshop/assistant", "relay/open"], authenticated: true,
                      featuredModels: ["relay/open"]),
    ])

    @Test func onlyTheChatsOwnProvidersRowIsItsModel() {
        // On the relay: its row is the chat's model; the maker's row with the same id is a switch.
        let bare = M.modelItems(Self.sharedID, current: "workshop/assistant", currentProvider: "relay", query: "")
        #expect(bare.filter(\.current).map(\.id) == ["relay|workshop/assistant"])
        // The chat's own model is added to its own provider's featured list only.
        #expect(bare.map(\.id) == ["relay|workshop/assistant", "relay|relay/open", "workshop|workshop/assistant-mini"])
        let search = M.modelItems(Self.sharedID, current: "workshop/assistant", currentProvider: "relay", query: "assistant")
        #expect(search.filter(\.current).map(\.id) == ["relay|workshop/assistant"])
        // Provider unknown, or not in the list: every row with the id, as before.
        #expect(M.modelItems(Self.sharedID, current: "workshop/assistant", query: "assistant").filter(\.current).count == 2)
        #expect(M.modelItems(Self.sharedID, current: "workshop/assistant", currentProvider: "elsewhere", query: "assistant").filter(\.current).count == 2)
    }

    @Test func aRowCheckedByItsIdAloneStillSwitches() throws {
        // On its own provider the row is the chat's own and has nothing to switch; the same id at
        // its maker is a switch.
        let home = M.modelItems(Self.sharedID, current: "workshop/assistant", currentProvider: "relay", query: "assistant")
        let own = try #require(home.first { $0.id == "relay|workshop/assistant" })
        let maker = try #require(home.first { $0.id == "workshop|workshop/assistant" })
        #expect(own.own && !maker.own)
        #expect(M.outcome(of: own, in: "/model assistant", wholeText: true, completing: false, canRun: true) == .keepModel)
        #expect(M.outcome(of: maker, in: "/model assistant", wholeText: true, completing: false, canRun: true) == .switchModel)

        // The chat's provider not in the list (a custom endpoint, say) or unknown: both rows with the
        // id are checked, but either may be another provider, so taking one switches, as the model
        // menu does.
        for provider in ["elsewhere", nil] as [String?] {
            let checked = M.modelItems(Self.sharedID, current: "workshop/assistant", currentProvider: provider, query: "assistant").filter(\.current)
            #expect(checked.count == 2)
            #expect(checked.allSatisfy { !$0.own })
            #expect(checked.allSatisfy { M.outcome(of: $0, in: "/model assistant", wholeText: true, completing: false, canRun: true) == .switchModel })
            // A bare "/model " marks none of them, so a habitual Return Return switches nothing: it
            // sends "/model" as typed.
            let bare = try #require(M.context(for: "/model "))
            let listed = M.modelItems(Self.sharedID, current: "workshop/assistant", currentProvider: provider, query: "")
            #expect(listed.filter(\.current).count == 2)
            #expect(M.markedIndex(listed, context: bare, mark: nil) == nil)
            #expect(M.returnAction(listed, context: bare, marked: nil) == .send)
        }
    }

    // MARK: The mark and the keys

    @Test func theCommandListMarksItsTopRowAndABareModelListTheChatsModel() throws {
        let commands = M.commandItems(Self.catalog, query: "co")
        let co = try #require(M.context(for: "/co"))
        #expect(M.markedIndex(commands, context: co, mark: nil) == 0)
        // "/model ": the chat's own model, not the first listed (it is third here).
        let bare = try #require(M.context(for: "/model "))
        let models = M.modelItems(Self.options, current: "workshop/assistant", currentProvider: "workshop", query: "")
        #expect(M.markedIndex(models, context: bare, mark: nil) == 2)
        // The chat's model is not listed: nothing is marked.
        #expect(M.markedIndex(M.modelItems(Self.options, current: "elsewhere/unlisted", query: ""), context: bare, mark: nil) == nil)
        // A typed model name marks nothing (Return sends it as typed).
        let typed = try #require(M.context(for: "/model mini"))
        #expect(M.markedIndex(M.modelItems(Self.options, current: "", query: "mini"), context: typed, mark: nil) == nil)
        #expect(M.markedIndex([], context: co, mark: nil) == nil)
    }

    @Test func aMarkMadeByHandHoldsForItsTextOnly() throws {
        let typed = try #require(M.context(for: "/model mini"))
        let items = M.modelItems(Self.options, current: "", query: "mini")
        let mark = M.Mark(context: typed, id: "local|local/assistant-mini")
        #expect(M.markedIndex(items, context: typed, mark: mark) == 1)
        // Typed on: the mark is left behind.
        let more = try #require(M.context(for: "/model minis"))
        #expect(M.markedIndex(items, context: more, mark: mark) == nil)
        // A row that is no longer listed: the usual mark.
        #expect(M.markedIndex(items, context: typed, mark: M.Mark(context: typed, id: "gone")) == nil)
    }

    @Test func theArrowsGoRoundTheEndsAndStartFromNothingAtEitherEnd() {
        #expect(M.move(0, by: 1, count: 3) == 1)
        #expect(M.move(2, by: 1, count: 3) == 0)
        #expect(M.move(0, by: -1, count: 3) == 2)
        // A mark past a list that shrank comes back inside it.
        #expect(M.move(7, by: -1, count: 3) == 1)
        #expect(M.move(nil, by: 1, count: 3) == 0)
        #expect(M.move(nil, by: -1, count: 3) == 2)
        #expect(M.move(nil, by: 1, count: 0) == nil)
    }

    @Test func returnTakesTheMarkedRowAndSendsATypedModelNameAsTyped() throws {
        let co = try #require(M.context(for: "/co"))
        let commands = M.commandItems(Self.catalog, query: "co")
        #expect(M.returnAction(commands, context: co, marked: 0) == .take(commands[0]))
        // Nothing matches (or the catalog has not come): Return keeps its own meaning.
        #expect(M.returnAction([], context: M.context(for: "/zzz"), marked: nil) == .keep)
        // No chooser (closed with Escape, or none for the text).
        #expect(M.returnAction(commands, context: nil, marked: 0) == .keep)

        // "/model mini" lists two minis, but Return sends what was typed: the gateway resolves it
        // (an alias, the user's own name, an unlisted id) on the chat's own provider.
        let typed = try #require(M.context(for: "/model mini"))
        let minis = M.modelItems(Self.options, current: "", query: "mini")
        #expect(M.returnAction(minis, context: typed, marked: M.markedIndex(minis, context: typed, mark: nil)) == .send)
        // The same while the list is loading.
        #expect(M.returnAction([], context: typed, marked: nil) == .send)
        // Chosen with the arrows: that row.
        #expect(M.returnAction(minis, context: typed, marked: 1) == .take(minis[1]))
    }

    @Test func aTypedModelNameIsNotSentWithAReplyQuotedOrFilesStaged() throws {
        // The text would go to the bot as a message (the quote above it, or the files with it), so
        // Return keeps its own meaning, as a picked command waits in the field then.
        let typed = try #require(M.context(for: "/model mini"))
        let minis = M.modelItems(Self.options, current: "", query: "mini")
        #expect(M.returnAction(minis, context: typed, marked: nil, canRun: false) == .keep)
        #expect(M.returnAction([], context: typed, marked: nil, canRun: false) == .keep)
        // A row chosen with the arrows still switches: a switch is not a message.
        #expect(M.returnAction(minis, context: typed, marked: 1, canRun: false) == .take(minis[1]))
        #expect(M.outcome(of: minis[1], in: "/model mini", wholeText: true, completing: false, canRun: false) == .switchModel)
    }

    @Test func modelReturnReturnKeepsTheChatsModel() throws {
        // "/model", Return: the command is the top row; it takes something, so it goes in the field.
        let first = try #require(M.context(for: "/model"))
        let commands = M.commandItems(Self.catalog, query: first.query)
        guard case .take(let command) = M.returnAction(commands, context: first, marked: M.markedIndex(commands, context: first, mark: nil)) else {
            Issue.record("Return did not take the command"); return
        }
        #expect(M.outcome(of: command, in: "/model", wholeText: first.wholeText, completing: false, canRun: true) == .fill("/model "))
        // Return again: the chat's own model, and nothing to switch.
        let bare = try #require(M.context(for: "/model "))
        let models = M.modelItems(Self.options, current: "workshop/assistant", currentProvider: "workshop", query: bare.query)
        guard case .take(let model) = M.returnAction(models, context: bare, marked: M.markedIndex(models, context: bare, mark: nil)) else {
            Issue.record("Return did not take the marked model"); return
        }
        #expect(model.name == "workshop/assistant")
        #expect(M.outcome(of: model, in: "/model ", wholeText: true, completing: false, canRun: true) == .keepModel)
    }

    @Test func tabCompletesAndNeverRuns() throws {
        let items = Dictionary(uniqueKeysWithValues: M.commandItems(Self.catalog, query: "").map { ($0.name, $0) })
        let status = try #require(items["status"])
        let new = try #require(items["new"])
        // Return (or a tap) runs a command that takes nothing; Tab only completes it.
        #expect(M.outcome(of: status, in: "/sta", wholeText: true, completing: false, canRun: true) == .run("/status"))
        #expect(M.outcome(of: status, in: "/sta", wholeText: true, completing: true, canRun: true) == .fill("/status "))
        #expect(M.outcome(of: new, in: "/ne", wholeText: true, completing: true, canRun: true) == .fill("/new "))
        // With a reply quoted or files staged it would go out as a message: it waits in the field.
        #expect(M.outcome(of: status, in: "/sta", wholeText: true, completing: false, canRun: false) == .fill("/status "))
        // A later word is an argument: completed in place.
        #expect(M.outcome(of: status, in: "/code-review then /sta", wholeText: false, completing: false, canRun: true)
                == .fill("/code-review then /status "))
        // A model: Return switches (the chat's own stays); Tab puts its id after "/model ".
        let mini = try #require(M.modelItems(Self.options, current: "workshop/assistant", query: "mini").first)
        #expect(M.outcome(of: mini, in: "/model mini", wholeText: true, completing: false, canRun: true) == .switchModel)
        #expect(M.outcome(of: mini, in: "/model mini", wholeText: true, completing: true, canRun: true) == .fill("/model workshop/assistant-mini"))
    }

    @Test func aModelCompletedWithTabIsTheOneReturnTakesProviderAndAll() throws {
        // "/model workshop/assistant": the same id at its maker and on the relay; the relay's row
        // is marked with the arrows and completed with Tab.
        let typed = try #require(M.context(for: "/model workshop/assistant"))
        let items = M.modelItems(Self.sharedID, current: "workshop/assistant-mini", currentProvider: "workshop", query: typed.query)
        let relay = try #require(items.first { $0.provider == "relay" })
        guard case .fill(let filled) = M.outcome(of: relay, in: "/model workshop/assistant", wholeText: true, completing: true, canRun: true) else {
            Issue.record("Tab did not complete"); return
        }
        let ctx = try #require(M.context(for: filled))
        let after = M.modelItems(Self.sharedID, current: "workshop/assistant-mini", currentProvider: "workshop", query: ctx.query)
        let marked = M.markedIndex(after, context: ctx, mark: M.Mark(context: ctx, id: relay.id))
        #expect(M.returnAction(after, context: ctx, marked: marked) == .take(relay))
        // Without that mark the same text goes out as typed.
        #expect(M.returnAction(after, context: ctx, marked: M.markedIndex(after, context: ctx, mark: nil)) == .send)
    }

    @Test func aRecalledEntryIsShownAsItWasSentUntilItIsEdited() {
        let history = ["hello", "/status"]
        #expect(M.isRecalled("/status", history: history, cursor: 1))
        // Edited after recall: the choosers open again.
        #expect(!M.isRecalled("/statu", history: history, cursor: 1))
        // Typed, not recalled.
        #expect(!M.isRecalled("/status", history: history, cursor: nil))
        #expect(!M.isRecalled("/status", history: history, cursor: 5))
    }

    @Test func aChatReadsItsOwnBotsModelListNotTheSelectedOne() {
        #expect(ChatSession.modelOptionsProfile(chat: "writer", selected: "coder") == "writer")
        #expect(ChatSession.modelOptionsProfile(chat: nil, selected: "coder") == "coder")
        #expect(ChatSession.modelOptionsProfile(chat: nil, selected: nil) == nil)
    }
}
