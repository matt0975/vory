import Foundation
import VoryCore

/// A bot's own Bot Chat: the session its bot-to-bot messages land in, and for a bot run from the
/// Hermes desktop app the main conversation with it. The gateway keeps it out of the session list,
/// so it is looked up here, the one way for both doors to it: a "Messaged X" notice opens it to
/// read, the bot's page opens it to type in (#653).
enum BotChat {
    /// The title the gateway gives every Bot Chat.
    static let title = "Bot Chat"

    /// The bot's page's way in: the chat itself, to type in, as any of the bot's chats opens.
    /// A turn sent there joins the Bot Chat's own queue on the gateway, behind whatever the bot
    /// is doing in it, and the desktop app showing it sees the same turn.
    static func route(_ storedID: String, profile: String) -> ChatRoute {
        ChatRoute(storedID: storedID, title: title, profile: profile)
    }

    /// The stored id of `profile`'s Bot Chat, nil when it has none. The gateway names it itself
    /// (`profiles.list` → `canonical_session`, the live tip of the lineage), which is how the
    /// companion finds it too. The recent list is the fallback for a gateway without that field,
    /// then a title search. Throws only when the recent list can't be read.
    static func storedID(of profile: String, on rt: GatewayRuntime) async throws -> String? {
        if let r = try? await rt.rpc("profiles.list"), let id = canonicalID(in: r, profile: profile) { return id }
        let recent: SessionListResponse = try await rt.api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "100")], profile: profile)
        if let id = titledID(in: recent.sessions, profile: profile) { return id }
        if let r: SessionListResponse = try? await rt.api.get("/api/sessions/search", query: [URLQueryItem(name: "q", value: title)], profile: profile) {
            return r.sessions.first { $0.title == title }?.id
        }
        return nil
    }

    /// `profiles.list`'s Bot Chat for `profile`: its canonical session's resolved id, else its id.
    static func canonicalID(in reply: JSONValue, profile: String) -> String? {
        var found: String?
        for row in reply["profiles"]?.arrayValue ?? [] where row["name"]?.stringValue == profile {
            if let cs = row["canonical_session"], !cs.isNull {
                found = cs["resolved_id"]?.stringValue ?? cs["id"]?.stringValue
            }
        }
        return found
    }

    /// Among a bot's recent chats, the one titled Bot Chat, else one whose title has it in it.
    /// A row naming no bot is taken as `profile`'s, the list having been asked for that bot.
    static func titledID(in sessions: [StoredSession], profile: String) -> String? {
        let own = sessions.filter { ($0.profile ?? profile) == profile }
        return (own.first { $0.title == title } ?? own.first { ($0.title ?? "").localizedCaseInsensitiveContains("bot chat") })?.id
    }
}
