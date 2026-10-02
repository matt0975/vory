import Foundation
import VoryCore

#if DEBUG
/// The demo copy of the app, for recording it: the same debug build under its own bundle id
/// (ending in `.demo`), ad-hoc signed, so it has its own settings and never sees the real
/// app's gateways, chats or iCloud. It is made by `Tools/dev/make-demo-app.sh`.
///
/// Such a copy has no Keychain it may use and no iCloud, so credentials are kept in memory
/// and iCloud is a dictionary. What it shows comes from launch arguments:
///   -vory-demo-gateway <url> <session token> <name>   one saved gateway, connected at launch
///   -vory-demo-cloud <url> <session token> <name>     an iCloud backup to restore from, holding
///                                                     that gateway, a name and a few bot looks
/// None of this exists in a release build.
@MainActor
enum DemoMode {
    nonisolated static let isOn = Bundle.main.bundleIdentifier?.hasSuffix(".demo") == true

    private static func values(after flag: String) -> (url: String, token: String, name: String)? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 3 < args.count else { return nil }
        return (args[i + 1], args[i + 2], args[i + 3])
    }

    /// First thing at launch, before anything reads the Keychain.
    static func prepare() {
        guard isOn else { return }
        Keychain.memoryOnly = true
        seedCloudGateway()
    }

    /// The gateway named on the command line, saved (in memory) and made the one in use.
    static func addGateway(to store: ConnectionStore) {
        guard isOn, let g = values(after: "-vory-demo-gateway"), let url = try? GatewayURL.normalize(g.url) else { return }
        var conn = GatewayConnection(name: g.name, gateway: url, authMode: .sessionToken)
        conn.connectionKind = "local"
        try? store.upsert(conn, secrets: GatewaySecrets(sessionToken: g.token))
        store.activeConnectionID = conn.id
    }

    /// The stand-in for iCloud: empty, or holding a backup made "on another device".
    static let cloud: MemoryCloudStore? = {
        guard isOn else { return nil }
        let store = MemoryCloudStore()
        guard values(after: "-vory-demo-cloud") != nil else { return store }
        let t = Date().timeIntervalSince1970 - 3 * 3600
        let settings: [(String, Any)] = [(CloudMerge.nameKey, "Sam"), ("colorSchemePreference", "dark")]
        for (key, value) in settings { store.values[CloudMerge.settingPrefix + key] = ["v": value, "t": t] }
        for (bot, hex, look) in [("default", "#3B7BFF", "studio:cloud:classic"), ("work", "#30D158", "studio:blob:curious")] {
            store.values[CloudMerge.lookKey(bot)] = ["n": bot, "hex": hex, "avatar": look, "t": t]
        }
        store.values[CloudMerge.devicePrefix + "demo-phone"] = ["name": "Sam\u{2019}s iPhone", "t": t]
        return store
    }()

    /// The gateway list iCloud Keychain would carry, for the restore.
    private static func seedCloudGateway() {
        guard let g = values(after: "-vory-demo-cloud"), let url = try? GatewayURL.normalize(g.url) else { return }
        var conn = GatewayConnection(name: g.name, gateway: url, authMode: .sessionToken)
        conn.connectionKind = "local"
        let file = CloudGatewayFile(gateways: [CloudGateway(connection: conn, sessionToken: g.token, access: CloudflareAccess(), updatedAt: Date().timeIntervalSince1970 - 3 * 3600)])
        if let data = try? JSONEncoder().encode(file) { try? Keychain.setSynced(data, account: CloudGateways.account) }
    }
}
#endif
