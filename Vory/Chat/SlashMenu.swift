import SwiftUI
import VoryCore

/// The composer's chooser: what "/" offers (the gateway's commands and skills, from
/// `commands.catalog`) and what "/model " offers (the models from `/api/model/options`, the
/// list the model menu shows), narrowed and ranked as the text is typed. The ranking is the
/// gateway's own (its slash menus score the same way): a match in the name beats one in the
/// description, and an exact word beats the start of a word, which beats anywhere in it.
enum SlashMenu {
    /// Where the chooser stands in the text being typed.
    struct Context: Equatable {
        enum Kind: Equatable { case command, model }
        var kind: Kind
        /// What has been typed of the name so far (after the "/", or after "/model "), lower case.
        var query: String
        /// The command is the whole message. A later "/word" is another command's argument
        /// (a skill told to run a command, say), so a pick there is only ever put in the text.
        var wholeText: Bool
        /// Where the word being chosen starts. Escape closes the chooser for this word; a new
        /// word, or the model list after a command, opens it again.
        var anchor: Int
    }

    /// One row of the chooser.
    struct Item: Identifiable, Hashable {
        enum Kind: Hashable { case command, skill, model }
        var kind: Kind
        /// A command's name without its "/", or a model's id.
        var name: String
        /// A command's description, or the model's provider.
        var detail: String
        /// A command that takes nothing after it runs when picked; the rest go in the field.
        var runsOnPick = false
        /// Models: the provider's slug (the switch names it), whether it is the chat's model
        /// now, and whether the provider still needs a key on the gateway.
        var provider: String?
        var current = false
        var needsKey = false
        var id: String { kind == .model ? (provider ?? "") + "|" + name : name }
    }

    static func context(for text: String) -> Context? {
        guard text.hasPrefix("/") else { return nil }
        // "/model " and at most one word after it: the model list. More words (a provider flag,
        // say) are typed by hand, as before.
        let modelPrefix = "/model "
        if text.lowercased().hasPrefix(modelPrefix) {
            let rest = text.dropFirst(modelPrefix.count).drop { $0 == " " }
            guard !rest.contains(where: \.isWhitespace) else { return nil }
            return Context(kind: .model, query: rest.lowercased(), wholeText: true, anchor: modelPrefix.count)
        }
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        guard let last = words.last, last.hasPrefix("/") else { return nil }
        return Context(kind: .command, query: last.dropFirst().lowercased(), wholeText: words.count == 1,
                       anchor: text.distance(from: text.startIndex, to: last.startIndex))
    }

    /// A catalog name as the lists compare it: some gateways send the names with their "/" and
    /// some without, and the maps beside the list are keyed with it.
    static func key(_ name: String) -> String {
        (name.hasPrefix("/") ? String(name.dropFirst()) : name).lowercased()
    }

    // MARK: Matching

    /// How well `query` matches: 0 the name exactly (or one of its words), 1 the start of the
    /// name or a word in it, 2 anywhere in the name; 3, 4 and 5 the same in the description.
    /// Nil when it is in neither. Lower is better. `query` is lower case.
    static func score(name: String, detail: String, query: String) -> Int? {
        if let s = tier(fields(name), query) { return s }
        if let s = tier(fields(detail), query) { return s + 3 }
        return nil
    }

    /// The text and each word in it ("code-review" is also "code" and "review"), lower case.
    private static func fields(_ text: String) -> [String] {
        let t = text.lowercased()
        return [t] + t.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func tier(_ fields: [String], _ q: String) -> Int? {
        if fields.contains(q) { return 0 }
        if fields.contains(where: { $0.hasPrefix(q) }) { return 1 }
        if fields.contains(where: { $0.contains(q) }) { return 2 }
        return nil
    }

    // MARK: Commands and skills

    /// Every command and skill the catalog lists that the app can run, for `query`. A bare "/"
    /// lists the commands A to Z, then the skills most used first, leaving out the bundled skills
    /// nobody has used (the gateway's menus do the same; a search still finds them). A search
    /// ranks by the score, commands before skills on a tie, then use, then name.
    static func commandItems(_ catalog: CommandsCatalog, query: String) -> [Item] {
        let meta = Dictionary((catalog.commands ?? [:]).map { (key($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        let skills = Dictionary((catalog.skills ?? [:]).map { (key($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        struct Row { var item: Item; var usage: Int; var unusedBundled: Bool }
        var seen = Set<String>()
        var rows: [Row] = []
        for pair in catalog.allPairs {
            let name = pair.name.hasPrefix("/") ? String(pair.name.dropFirst()) : pair.name
            let k = key(name)
            guard !k.isEmpty, seen.insert(k).inserted else { continue }
            if let s = skills[k] {
                rows.append(Row(item: Item(kind: .skill, name: name, detail: pair.description),
                                usage: s.usage ?? 0, unusedBundled: s.origin == "bundled" && (s.usage ?? 0) == 0))
                continue
            }
            let local = ChatSession.localCommands[k]
            let m = meta[k]
            // What the gateway keeps to another surface (the terminal, Settings, a messaging
            // platform, or out of its own menu) is left out, unless the app runs it itself.
            if m?.desktop != nil, local == nil { continue }
            // A command the catalog describes with no argument runs as it is; one it does not
            // describe (a quick command, an older gateway) is put in the field to be sure.
            let runs = local ?? (m != nil && m?.argumentMode == nil)
            rows.append(Row(item: Item(kind: .command, name: name, detail: pair.description, runsOnPick: runs), usage: 0, unusedBundled: false))
        }

        if query.isEmpty {
            let commands = rows.filter { $0.item.kind == .command }
                .sorted { $0.item.name.lowercased() < $1.item.name.lowercased() }
            let skillRows = rows.filter { $0.item.kind == .skill && !$0.unusedBundled }
                .sorted { $0.usage != $1.usage ? $0.usage > $1.usage : $0.item.name.lowercased() < $1.item.name.lowercased() }
            return (commands + skillRows).map(\.item)
        }

        // An alias typed in full ("/reset") finds the command it stands for ("/new"), which the
        // catalog lists under its own name only.
        let aliasOf = (catalog.canon?[query] ?? catalog.canon?["/" + query]).map(key)
        let scored: [(row: Row, score: Int)] = rows.compactMap { row in
            if let aliasOf, aliasOf != query, key(row.item.name) == aliasOf { return (row, 0) }
            return score(name: row.item.name, detail: row.item.detail, query: query).map { (row, $0) }
        }
        return scored.sorted { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.row.item.kind != b.row.item.kind { return a.row.item.kind == .command }
            if a.row.usage != b.row.usage { return a.row.usage > b.row.usage }
            return a.row.item.name.lowercased() < b.row.item.name.lowercased()
        }.map(\.row.item)
    }

    // MARK: Models

    /// The models to switch this chat to, for `query`. A bare "/model " lists each provider's
    /// featured models (as the model menu does) and the chat's own; a search looks through every
    /// model a provider lists. Providers the gateway can use come first, as in the menu.
    static func modelItems(_ options: ModelOptionsResult, current: String, query: String) -> [Item] {
        var seen = Set<String>()
        var scored: [(item: Item, score: Int, order: Int)] = []
        for p in options.sortedProviders {
            let all = p.models ?? p.featuredModels ?? []
            var models = all
            if query.isEmpty {
                models = p.featuredModels.flatMap { $0.isEmpty ? nil : $0 } ?? all
                if all.contains(current), !models.contains(current) { models.insert(current, at: 0) }
            }
            for m in models where seen.insert(p.slug + "|" + m).inserted {
                let item = Item(kind: .model, name: m, detail: p.name, provider: p.slug, current: m == current,
                                needsKey: p.authenticated == false)
                let s = query.isEmpty ? 0 : score(name: m, detail: p.name + " " + p.slug, query: query)
                if let s { scored.append((item, s, scored.count)) }
            }
        }
        return scored.sorted { $0.score != $1.score ? $0.score < $1.score : $0.order < $1.order }.map(\.item)
    }
}

/// The chooser as it shows above the composer: a glass list that scrolls inside a cap, with the
/// row Return (or Tab) would take marked; arrows move the mark and keep it in view.
struct SlashMenuList: View {
    var items: [SlashMenu.Item]
    var selection: Int
    /// The model list is still loading: one quiet row says so.
    var loading = false
    var cap: CGFloat
    var pick: (SlashMenu.Item) -> Void

    private static let rowHeight: CGFloat = 38

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if items.isEmpty, loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading models…").font(.subheadline).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .frame(height: Self.rowHeight)
                        .padding(.horizontal, 8)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        Button { pick(item) } label: { row(item, selected: i == selection) }
                            .buttonStyle(.plain)
                            .id(item.id)
                            .accessibilityIdentifier(item.kind == .model ? "composer.model.\(item.name)" : "composer.command.\(item.name)")
                            .accessibilityAddTraits(i == selection ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .scrollIndicators(.visible)
            .onChange(of: selection) { _, s in
                guard items.indices.contains(s) else { return }
                withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(items[s].id) }
            }
            // A narrowed list starts at its top: scrolled down and then narrowed to a row or
            // two, it kept the old offset and showed an empty box.
            .onChange(of: items.map(\.id)) { _, ids in
                if let first = ids.first { proxy.scrollTo(first, anchor: .top) }
            }
        }
        // A fixed height; the dock's keyboard handling is manual (ConversationView) so this
        // scroll view cannot swallow the keyboard inset.
        .frame(height: min(cap, CGFloat(max(items.count, loading ? 1 : 0)) * Self.rowHeight + 8))
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func row(_ item: SlashMenu.Item, selected: Bool) -> some View {
        HStack(spacing: 10) {
            if item.kind == .model {
                Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            } else {
                Text("/" + item.name).font(.subheadline.monospaced().weight(.medium)).lineLimit(1).layoutPriority(1)
            }
            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if item.kind == .skill { tag("Skill", .teal) }
            if item.needsKey { tag("no key", .orange) }
            if item.current { Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Color.vory) }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(selected ? Color.vory.opacity(0.14) : .clear, in: .rect(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        // Whole, whatever the name beside it: a long skill name broke "Skill" over two lines.
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.14), in: .capsule)
            .fixedSize()
    }
}
