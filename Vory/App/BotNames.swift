import Foundation
import VoryCore

/// A bot's display name and title as edited in Vory (#315). The gateway has `display_name` and
/// `bot_title` in the profile's own files, but its API only renames the whole profile (the
/// folder, with a gateway restart), so a name that is just a name lives here: in UserDefaults as
/// `{profile: {"n": name, "t": title}}` under `botNames`, synced through Vory's iCloud with the
/// bot's look (`CloudMerge.reconcileLooks`), and consulted by `ProfileInfo.label` and `title`
/// before the gateway's values. The folder name never changes; it stays the key.
enum BotNames {
    static let storageKey = "botNames"

    static func stored(_ defaults: UserDefaults = .standard) -> [String: [String: String]] {
        guard let raw = defaults.string(forKey: storageKey), let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return map
    }

    @MainActor static func save(_ map: [String: [String: String]], _ defaults: UserDefaults = .standard) {
        if map.isEmpty { defaults.removeObject(forKey: storageKey) }
        else if let data = try? JSONEncoder().encode(map), let s = String(data: data, encoding: .utf8) { defaults.set(s, forKey: storageKey) }
        CloudSync.shared.looksChanged()
    }

    /// The names kept for a bot, nil when none.
    static func names(for profile: String, _ defaults: UserDefaults = .standard) -> ProfileOwnNames? {
        // The demo's bots go by the demo's names while it runs (`DemoLooks`), never by those kept for this person's.
        guard let e = DemoLooks.isOn ? DemoLooks.names(for: profile) : stored(defaults)[profile] else { return nil }
        let n = e["n"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let t = e["t"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !n.isEmpty || !t.isEmpty else { return nil }
        return ProfileOwnNames(displayName: n.isEmpty ? nil : n, title: t.isEmpty ? nil : t)
    }

    /// Sets a bot's names. An empty name or title clears that one; both empty drops the bot's
    /// entry, so its gateway names (or the folder name) show again.
    @MainActor static func set(displayName: String?, title: String?, for profile: String, _ defaults: UserDefaults = .standard) {
        let n = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var entry: [String: String]?
        if !n.isEmpty || !t.isEmpty {
            var e: [String: String] = [:]
            if !n.isEmpty { e["n"] = n }
            if !t.isEmpty { e["t"] = t }
            entry = e
        }
        // A name given in the demo is the demo's only.
        if DemoLooks.keep(names: entry, for: profile) { return }
        var map = stored(defaults)
        map[profile] = entry
        save(map, defaults)
    }

    /// Hands the app's names to VoryCore, so every `label` and `title` in the app reads them.
    @MainActor static func install() {
        ProfileInfo.ownNames = { profile in BotNames.names(for: profile) }
    }
}
