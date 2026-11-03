import Foundation

/// The gateway whose bots' looks are read and set (#573): the one in use, by its connection's id (the id saved gateways
/// keep on every device, as the favourite models do). The app sets it as a gateway comes into use.
///
/// A bot's colour, avatar, photo and own names are kept for each gateway under "@<id>/<name>" in the same maps as before,
/// so two gateways' bots of one name (every gateway's "default") no longer share a look. A look kept by the name alone,
/// from before (or from a device still on 1.5.1 (42) or (43)), is what every gateway shows for that bot until the bot has a
/// look of its own there. A profile is a folder name, so no bot's name has this shape.
enum BotLookGateway {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var value: UUID?

    static var current: UUID? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    /// The key a bot's look is kept under for a gateway; the name alone with none.
    static func key(_ name: String, gateway: UUID? = current) -> String {
        gateway.map { "@\($0.uuidString)/\(name)" } ?? name
    }

    /// The key a bot's value is read from: the gateway's own when it has one (an empty one too, which means "the
    /// default"), else the name's from before.
    static func readKey<V>(in map: [String: V], for name: String, gateway: UUID? = current) -> String {
        let own = key(name, gateway: gateway)
        return map[own] != nil ? own : name
    }

    /// A bot's value in one of the look maps, as `readKey` finds it.
    static func value<V>(in map: [String: V], for name: String, gateway: UUID? = current) -> V? {
        map[readKey(in: map, for: name, gateway: gateway)]
    }

    /// A key's gateway and bot name; nil for a key from before (the name alone).
    static func split(_ key: String) -> (gateway: UUID, name: String)? {
        guard key.hasPrefix("@"), let slash = key.firstIndex(of: "/"),
              let id = UUID(uuidString: String(key[key.index(after: key.startIndex)..<slash])) else { return nil }
        return (id, String(key[key.index(after: slash)...]))
    }
}
