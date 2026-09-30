import Foundation
import VoryCore

/// Bot looks (colours, bodies and eyes, photo thumbnails) shared between the user's devices
/// through the gateway: `<profile home>/push/looks.json`, next to the push device files. The
/// iPhone publishes whenever a look changes and on connect; every device pulls on connect and
/// takes a newer file. The Mac only reads for now, so nothing set on the phone can be
/// overwritten from it.
@MainActor
enum LooksSync {
    static let schema = 1
    #if os(iOS)
    static let publishes = true
    #else
    static let publishes = false
    #endif

    struct File: Codable {
        var schema: Int
        var updatedAt: Double
        var device: String
        var colors: [String: String]
        var avatars: [String: String]
        /// `{profile: JPEG}` thumbnails, about 128 px.
        var photos: [String: Data]
        enum CodingKeys: String, CodingKey { case schema, updatedAt = "updated_at", device, colors, avatars, photos }
    }

    static func path(_ runtime: GatewayRuntime) -> String? { runtime.profileHome.map { "\($0)/push/looks.json" } }
    private static func appliedKey(_ runtime: GatewayRuntime) -> String { "looks.applied." + runtime.connection.id.uuidString }
    private static var publishTask: Task<Void, Never>?
    /// Set while a pulled file is being written into the stores, so the mirror does not publish it back.
    private static var applying = false

    /// On connect: this device's looks go up (iPhone), or the gateway's come down (Mac).
    static func sync(runtime: GatewayRuntime) async {
        if publishes { await publish(runtime: runtime) } else { await pull(runtime: runtime) }
    }

    /// After a look changed: publish soon, once, with whatever else changes in the same moment.
    static func publishSoon() {
        guard publishes, !applying else { return }
        publishTask?.cancel()
        publishTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let rt = AppModel.shared.runtime else { return }
            await publish(runtime: rt)
        }
    }

    static func publish(runtime: GatewayRuntime) async {
        guard publishes, let path = path(runtime) else { return }
        // The mirror is the looks as the extensions see them: every known bot, the all-bots
        // glass setting baked in, each look under its profile name and its label.
        let looks = BotLooks.load()
        let file = File(schema: schema, updatedAt: Date().timeIntervalSince1970, device: AppModel.shared.push.installID,
                        colors: looks.colors, avatars: looks.avatars, photos: looks.photos)
        do {
            let data = try JSONEncoder().encode(file)
            let body: JSONValue = ["path": .string(path), "data_url": .string("data:application/json;base64," + data.base64EncodedString()), "overwrite": true]
            let _: ManagedUploadResult = try await runtime.api.send("POST", "/api/files/upload", json: body)
            UserDefaults.standard.set(file.updatedAt, forKey: appliedKey(runtime))
        } catch {
            LiveActivityController.note("looks: publish failed: \(error.localizedDescription)")
        }
    }

    static func pull(runtime: GatewayRuntime) async {
        guard let path = path(runtime) else { return }
        do {
            let r: JSONValue = try await runtime.api.get("/api/files/read", query: [URLQueryItem(name: "path", value: path)])
            guard let url = r["data_url"]?.stringValue, let comma = url.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return }
            let file = try JSONDecoder().decode(File.self, from: data)
            guard file.updatedAt > UserDefaults.standard.double(forKey: appliedKey(runtime)) else { return }
            apply(file)
            UserDefaults.standard.set(file.updatedAt, forKey: appliedKey(runtime))
            LiveActivityController.note("looks: took the gateway's file from \(file.device.prefix(8)) (\(file.colors.count) bots)")
        } catch HermesAPIError.http(let status, _) where status == 404 {
            // Nothing published yet.
        } catch {
            LiveActivityController.note("looks: could not read the gateway's file: \(error.localizedDescription)")
        }
    }

    /// Writes the file's looks into this device's stores, over what is here: a bot the file does
    /// not name keeps its local look. Straight into UserDefaults, then one mirror pass.
    private static func apply(_ file: File) {
        applying = true; defer { applying = false }
        for (profile, data) in file.photos { try? BotAvatarStore.savePhoto(data, for: profile) }
        var colors = BotColors.stored()
        for (k, v) in file.colors { colors[k] = v }
        var avatars = BotAvatarStore.stored()
        for (k, v) in file.avatars { avatars[k] = v }
        store(colors, key: BotColors.storageKey)
        store(avatars, key: BotAvatarStore.storageKey)
        BotLooksMirror.mirror()
    }

    private static func store(_ map: [String: String], key: String) {
        if let data = try? JSONEncoder().encode(map), let s = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: key)
        }
    }
}
