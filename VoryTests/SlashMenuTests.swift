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
}
