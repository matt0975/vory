import AppIntents
import CoreSpotlight
import Foundation
import VoryCore

// MARK: What Siri can name without the app on screen (#310, #311)
//
// Siri resolves a bot or a chat by name while the app may not be running, so the app keeps a
// small catalog as it learns them: the gateway's bots (name and label) and the recent chats'
// titles (never message text). Chat titles also go to Spotlight when the switch is on.

enum SiriCatalog {
    static let botsKey = "siri.bots"
    static let chatsKey = "siri.chats"
    /// "Show chats in Spotlight": on by default on the iPhone and iPad, off on the Mac (often shared).
    static let spotlightKey = "siri.spotlightChats"
    /// "Let Siri answer approvals": off by default, always.
    static let approvalsKey = "siri.answersApprovals"
    static let chatLimit = 50

    static var spotlightOn: Bool {
        get { UserDefaults.standard.object(forKey: spotlightKey) as? Bool ?? spotlightDefault }
        set { UserDefaults.standard.set(newValue, forKey: spotlightKey) }
    }
    static var spotlightDefault: Bool { !DeviceWords.isMac }
    static var answersApprovals: Bool {
        get { UserDefaults.standard.bool(forKey: approvalsKey) }
        set { UserDefaults.standard.set(newValue, forKey: approvalsKey) }
    }

    static func rememberBots(_ profiles: [ProfileInfo]) {
        let rows = profiles.map { [$0.name, $0.label] }
        UserDefaults.standard.set(rows, forKey: botsKey)
    }

    static func bots() -> [BotEntity] {
        let rows = UserDefaults.standard.array(forKey: botsKey) as? [[String]] ?? []
        return rows.compactMap { $0.count == 2 ? BotEntity(id: $0[0], label: $0[1]) : nil }
    }

    /// The recent chats' titles and bots, most recent first; Spotlight follows the switch.
    static func rememberChats(_ sessions: [StoredSession]) {
        let rows = sessions.prefix(chatLimit).map { [$0.id, $0.displayTitle, $0.profile ?? ""] }
        UserDefaults.standard.set(rows, forKey: chatsKey)
        Task { await syncSpotlight() }
    }

    static func chats() -> [ChatEntity] {
        let rows = UserDefaults.standard.array(forKey: chatsKey) as? [[String]] ?? []
        return rows.compactMap { $0.count == 3 ? ChatEntity(id: $0[0], title: $0[1], bot: $0[2].isEmpty ? nil : $0[2]) : nil }
    }

    /// Chat titles in Spotlight while the switch is on; none when it is off.
    static func syncSpotlight() async {
        let index = CSSearchableIndex.default()
        if spotlightOn {
            try? await index.indexAppEntities(chats())
        } else {
            try? await index.deleteAppEntities(ofType: ChatEntity.self)
        }
    }

    /// The bot a request means: the one named, else the app's default (or the selected one).
    @MainActor static func profile(for bot: BotEntity?, on rt: GatewayRuntime) -> String? {
        bot?.id ?? rt.defaultProfile ?? rt.selectedProfile
    }
}

/// A bot, as Siri lists and resolves it.
struct BotEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bot"
    static let defaultQuery = BotQuery()
    var id: String
    var label: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }
}

struct BotQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [BotEntity] {
        SiriCatalog.bots().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [BotEntity] { SiriCatalog.bots() }
    func entities(matching string: String) async throws -> [BotEntity] {
        let s = string.lowercased()
        return SiriCatalog.bots().filter { $0.id.lowercased().contains(s) || $0.label.lowercased().contains(s) }
    }
}

/// A recent chat, by its title; in Spotlight when the switch is on.
struct ChatEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Chat"
    static let defaultQuery = ChatQuery()
    var id: String
    var title: String
    var bot: String?
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: bot.map { "\($0)" })
    }
    var attributeSet: CSSearchableItemAttributeSet {
        let a = CSSearchableItemAttributeSet(contentType: .text)
        a.title = title
        a.contentDescription = bot.map { "Chat with \($0) in Vory" } ?? "Chat in Vory"
        return a
    }
}

struct ChatQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ChatEntity] {
        SiriCatalog.chats().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [ChatEntity] { Array(SiriCatalog.chats().prefix(10)) }
    func entities(matching string: String) async throws -> [ChatEntity] {
        let s = string.lowercased()
        return SiriCatalog.chats().filter { $0.title.lowercased().contains(s) }
    }
}

/// Approve or deny, as a spoken choice.
enum ApprovalAnswer: String, AppEnum {
    case approve, deny
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Answer"
    static let caseDisplayRepresentations: [ApprovalAnswer: DisplayRepresentation] = [.approve: "Approve", .deny: "Deny"]
}

/// The words Siri says for a bot's status and an approval, kept pure for the tests.
enum SiriWords {
    /// "<Bot> is working on <title>. Two approvals are waiting." and the like.
    static func status(running: [(bot: String, title: String)], waiting: Int, bot: String?) -> String {
        var parts: [String] = []
        let mine = bot.map { b in running.filter { $0.bot.lowercased() == b.lowercased() } } ?? running
        switch mine.count {
        case 0: parts.append(bot.map { "\($0) is not running anything." } ?? "No bot is running anything.")
        case 1: parts.append("\(mine[0].bot) is working on \(mine[0].title).")
        default: parts.append("\(mine.count) chats are running: " + mine.prefix(3).map { "\($0.bot) on \($0.title)" }.joined(separator: ", ") + ".")
        }
        switch waiting {
        case 0: break
        case 1: parts.append("One approval is waiting for you.")
        default: parts.append("\(waiting) approvals are waiting for you.")
        }
        return parts.joined(separator: " ")
    }

    /// "<Bot> wants to run <command>. Approve it?"
    static func approvalQuestion(bot: String, request: ApprovalRequest, answer: ApprovalAnswer) -> String {
        let what = (request.command ?? request.description ?? request.toolName ?? "a command").trimmingCharacters(in: .whitespacesAndNewlines)
        let short = what.count > 120 ? String(what.prefix(119)) + "…" : what
        return "\(bot) wants to run: \(short). \(answer == .approve ? "Approve" : "Deny") it?"
    }
}
