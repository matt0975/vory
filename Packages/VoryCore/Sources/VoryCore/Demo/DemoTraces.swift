import Foundation

/// What builds before 11bd131 left of the demo (#493): the chat list saved the demo's chats under its id, and a later
/// launch read them back, so the list kept their first times and the demo's chats aged ("last week"). Nothing is
/// written for the demo now (`GatewayRuntime.isEphemeral`, and the list's cache never reads or writes it); this takes
/// away what was: every key of the app's defaults that names the demo's id, and its transcript folder. Run at launch
/// and when the demo ends, so a device that ran an older demo is cleaned too. It matches the demo's gateway id only:
/// its chats' ids have the shape of a real Hermes chat's.
public enum DemoTraces {
    /// At launch, unless the demo is already the gateway in use (a test build's `-vory-demo`): nothing is taken from
    /// under a demo that runs. Leaving the demo sweeps in any case (`sweep`).
    @MainActor public static func sweepAtLaunch(store: ConnectionStore, defaults: UserDefaults = .standard,
                                                caches: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                                                temporary: URL = FileManager.default.temporaryDirectory, now: Date = Date()) {
        guard store.demo == nil else { return }
        sweep(defaults: defaults, caches: caches)
        sweepKeychain(store: store)
        // A demo's scratch folder its runtime never stopped to take away (#494: the app ended in the demo). Not one
        // written in the last hour: a test build's temporary folder can be another copy's too, its demo running.
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: temporary.path)) ?? [] where name.hasPrefix("vory-demo-") {
            let folder = temporary.appending(path: name, directoryHint: .isDirectory)
            let written = (try? fm.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date ?? .distantPast
            if now.timeIntervalSince(written) > 3600 { try? fm.removeItem(at: folder) }
        }
    }

    public static func sweep(defaults: UserDefaults = .standard,
                             caches: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first) {
        let id = GatewayConnection.demoID.uuidString
        for key in defaults.dictionaryRepresentation().keys where key.uppercased().contains(id) {
            defaults.removeObject(forKey: key)
        }
        if let caches {
            try? FileManager.default.removeItem(at: caches.appending(path: "transcripts/\(id)", directoryHint: .isDirectory))
        }
        // Inside three of the app's values, the demo's entry an older build kept (#494): its favourite models (a JSON
        // object by gateway id, which iCloud would get), the gateways that refused a pin (a list of ids) and those that
        // refused a scheduled task's create (by id). Rewritten only when the demo's entry is there.
        if let json = defaults.string(forKey: "models.favourites"), let data = json.data(using: .utf8),
           var map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], map[id] != nil {
            map[id] = nil
            if map.isEmpty { defaults.removeObject(forKey: "models.favourites") }
            else if let out = try? JSONSerialization.data(withJSONObject: map, options: .sortedKeys) {
                defaults.set(String(decoding: out, as: UTF8.self), forKey: "models.favourites")
            }
        }
        if let ids = defaults.stringArray(forKey: "vory.pins.refused"), ids.contains(id) {
            defaults.set(ids.filter { $0 != id }, forKey: "vory.pins.refused")
        }
        if var refused = defaults.dictionary(forKey: "vory.cron.createRefused"), refused[id] != nil {
            refused[id] = nil
            defaults.set(refused, forKey: "vory.cron.createRefused")
        }
    }

    /// The Keychain's twins (#494): secrets kept under the demo's id, its Companion's, and a sign-in remembered for it.
    @MainActor public static func sweepKeychain(store: ConnectionStore) {
        let id = GatewayConnection.demoID
        Keychain.delete(account: "secrets." + id.uuidString)
        Keychain.delete(account: "companion-secrets." + id.uuidString)
        if store.remembered.contains(id) { _ = store.remembered.forget(id) }
    }
}
