import SwiftUI

/// Which cards Home shows, in what order and at what size. Saved as JSON under `home.layout`.
enum HomeCard: String, Codable, CaseIterable, Identifiable {
    case overview, bots, pickUp, since
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .bots: "Bots"
        case .pickUp: "Pick up where you left off"
        case .since: "Since you were here"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "chart.bar.fill"
        case .bots: "person.2.fill"
        case .pickUp: "bubble.left.and.text.bubble.right.fill"
        case .since: "sparkles"
        }
    }
    /// What the two sizes mean for this card, for the picker.
    var sizeWords: (compact: String, full: String) {
        switch self {
        case .overview: ("Numbers only", "Numbers and activity blocks")
        case .bots: ("Faces in a row", "List with status")
        case .pickUp: ("Three chats", "Five chats")
        case .since: ("Short", "Full")
        }
    }
}

enum HomeCardSize: String, Codable, CaseIterable { case compact, full }

struct HomeLayout: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var card: HomeCard
        var size: HomeCardSize
        var id: String { card.rawValue }
    }
    var items: [Item]

    static let storageKey = "home.layout"
    /// The chats cards list every bot's chats, not only the current bot's.
    static let allBotsKey = "home.allBots"
    static let `default` = HomeLayout(items: HomeCard.allCases.map { Item(card: $0, size: .full) })

    static func parse(_ raw: String) -> HomeLayout {
        guard let data = raw.data(using: .utf8), let l = try? JSONDecoder().decode(HomeLayout.self, from: data), !l.items.isEmpty else { return .default }
        return l
    }
    var encoded: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    var hidden: [HomeCard] { HomeCard.allCases.filter { c in !items.contains { $0.card == c } } }
    func size(of card: HomeCard) -> HomeCardSize { items.first { $0.card == card }?.size ?? .full }

    mutating func set(_ card: HomeCard, size: HomeCardSize) {
        if let i = items.firstIndex(where: { $0.card == card }) { items[i].size = size }
    }
    mutating func remove(_ card: HomeCard) { items.removeAll { $0.card == card } }
    mutating func add(_ card: HomeCard) {
        guard !items.contains(where: { $0.card == card }) else { return }
        items.append(Item(card: card, size: .full))
    }
    mutating func move(fromOffsets: IndexSet, toOffset: Int) { items.move(fromOffsets: fromOffsets, toOffset: toOffset) }
}

/// Settings › Home: the name, the launch choice, and the cards (order, size, shown or not).
struct HomeSettingsView: View {
    @AppStorage("user.name") private var userName = ""
    @AppStorage("launchTab") private var launchTab = "chats"
    @AppStorage(TabLayout.storageKey) private var tabLayoutRaw = ""
    @AppStorage(HomeLayout.storageKey) private var layoutRaw = ""
    @AppStorage(HomeLayout.allBotsKey) private var homeAllBots = false
    @Environment(\.editMode) private var editMode

    private var layout: HomeLayout { HomeLayout.parse(layoutRaw) }
    private func update(_ change: (inout HomeLayout) -> Void) {
        var l = layout; change(&l); layoutRaw = l.encoded
    }

    var body: some View {
        List {
            SettingsHeaderSection(title: "Home", symbol: "house.fill", color: .blue,
                                  description: "The dashboard: a greeting, the month in numbers, your bots, the chats to pick back up, and what changed while you were away. Choose which cards, in what order and at what size.")
            Section {
                TextField("Your name", text: $userName).textContentType(.givenName)
            } header: { Text("You") } footer: { Text("Home greets you by name. Stays on this phone.") }
            Section {
                Picker("Open Vory on", selection: Binding(get: { AppModel.AppTab(rawValue: launchTab) ?? .chats }, set: { tab in
                    launchTab = tab.rawValue
                    var l = TabLayout.parse(tabLayoutRaw)
                    if !l.contains(tab) { l.set(tab, enabled: true); tabLayoutRaw = l.encoded }
                })) {
                    ForEach(TabLayout.parse(tabLayoutRaw).visible()) { tab in Label(tab.title, systemImage: tab.symbol).tag(tab) }
                }
            } footer: { Text("The tab the app opens on. Only tabs on the bar are offered; add one from Appearance › Tab bar.") }
            Section {
                Toggle(isOn: $homeAllBots) { Label("Chats from all bots", systemImage: "person.2") }
            } footer: { Text("Off, the Pick up and Since cards show the current bot's chats. On, they merge every bot's recent chats, each with its bot's face.") }
            Section {
                ForEach(layout.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.card.symbol).foregroundStyle(.tint).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.card.title)
                            Text(item.size == .compact ? item.card.sizeWords.compact : item.card.sizeWords.full).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Picker("Size", selection: Binding(get: { item.size }, set: { s in update { $0.set(item.card, size: s) } })) {
                                Text(item.card.sizeWords.compact).tag(HomeCardSize.compact)
                                Text(item.card.sizeWords.full).tag(HomeCardSize.full)
                            }
                        } label: {
                            Image(systemName: item.size == .compact ? "rectangle.compress.vertical" : "rectangle.expand.vertical").foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Size for \(item.card.title)")
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { update { $0.remove(item.card) } } label: { Label("Hide", systemImage: "eye.slash") }
                    }
                }
                .onMove { from, to in update { $0.move(fromOffsets: from, toOffset: to) } }
                .onDelete { offsets in update { l in offsets.map { l.items[$0].card }.forEach { l.remove($0) } } }
            } header: {
                HStack { Text("On Home"); Spacer(); EditButton().font(.caption) }
            } footer: { Text("Drag to reorder, swipe to hide. The size icon switches a card between its two sizes.") }
            if !layout.hidden.isEmpty {
                Section("Not on Home") {
                    ForEach(layout.hidden) { card in
                        Button { update { $0.add(card) } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                                Image(systemName: card.symbol).foregroundStyle(.secondary).frame(width: 24)
                                Text(card.title)
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            Section {
                Button("Reset Home to default") { layoutRaw = "" }
            }
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
    }
}
