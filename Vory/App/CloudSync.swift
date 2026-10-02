import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif
import VoryCore

// Settings, bot looks and saved gateways, kept the same on a person's devices through their
// own iCloud: the key-value store for settings and looks, iCloud Keychain for the gateways.
// Nothing is hosted by Vory and there is no account to sign in to.
//
//   CloudMerge      the per-key merge between this device and the cloud (pure, unit-tested)
//   CloudGateways   the synced copy of the gateway list
//   CloudSync       the running thing: observes both sides and calls the two above

// MARK: The cloud as a key-value store

/// The cloud side: `NSUbiquitousKeyValueStore` in the app, a dictionary in tests.
protocol CloudKeyValueStore: AnyObject {
    func cloudValue(_ key: String) -> Any?
    /// `nil` removes the key.
    func setCloudValue(_ value: Any?, for key: String)
    var cloudKeys: [String] { get }
    /// Ask for a sync with the server soon; a no-op where there is none.
    func flush()
}

extension NSUbiquitousKeyValueStore: CloudKeyValueStore {
    func cloudValue(_ key: String) -> Any? { object(forKey: key) }
    func setCloudValue(_ value: Any?, for key: String) {
        if let value { set(value, forKey: key) } else { removeObject(forKey: key) }
    }
    var cloudKeys: [String] { Array(dictionaryRepresentation.keys) }
    func flush() { synchronize() }
}

/// A cloud that is a dictionary: two `CloudMerge`s sharing one stand in for two devices.
final class MemoryCloudStore: CloudKeyValueStore {
    var values: [String: Any] = [:]
    func cloudValue(_ key: String) -> Any? { values[key] }
    func setCloudValue(_ value: Any?, for key: String) { values[key] = value }
    var cloudKeys: [String] { Array(values.keys) }
    func flush() {}
}

// MARK: The merge

/// What iCloud holds, for the restore screens.
struct CloudSummary: Equatable {
    var settings = 0
    var bots = 0
    var gateways = 0
    /// The device that wrote last, other than this one when there is another.
    var device: String?
    var date: Date?
    var isEmpty: Bool { settings == 0 && bots == 0 && gateways == 0 }
}

/// The merge between this device's settings and the cloud's, one key at a time.
///
/// Every cloud entry carries the time it was written. This device remembers, per key, the
/// time of the version it last agreed with (`stamps`) and what its own value was then
/// (`seen`). A local value that differs from `seen` was changed here and goes up; a cloud
/// entry newer than `stamps` was changed elsewhere and comes down.
///
/// A device joins the sync the first time this runs on it (and again after a reset). What the
/// cloud already held at that moment is left where it is, and so is the device: a fresh start
/// stays fresh and nothing is overwritten silently. From then on changes flow both ways.
/// Restore and Back Up are the two explicit ways to take a side.
@MainActor
struct CloudMerge {
    enum Mode {
        /// The running sync: changes flow both ways.
        case merge
        /// The cloud wins everywhere it has a value; what only this device has goes up.
        case restore
        /// This device wins everywhere it has a value.
        case backUp
    }

    struct Outcome: Equatable {
        var applied = 0
        var pushed = 0
    }

    /// The settings that follow the person. Everything else is this device's own: notifications,
    /// the app lock and how approvals are confirmed, the tab bar or sidebar, text size, motion,
    /// list filters, caches, and anything that identifies the install.
    static let syncedSettings: [String] = [
        AppTheme.accentKey, "colorSchemePreference",
        HomeLayout.storageKey, HomeLayout.allBotsKey, "user.name",
        ChatStyle.showToolCalls, ChatStyle.showReasoning, ChatStyle.showTurnStats, ChatStyle.showSystemNotes,
        ChatStyle.showBots, ChatStyle.showToolOutput, ChatStyle.currentStepOnly, ChatStyle.compactTools,
        ChatStyle.collapseAfterTurn, ChatStyle.bubbleStyle, ChatStyle.botTint, ChatStyle.wideReplies,
        BotAvatarStore.glassAllKey, GatewayRuntime.defaultProfileKey,
        ChatSummarizer.enabledKey, ChatSummarizer.titlesKey, ChatSummarizer.previewsKey,
    ]

    static let stampsKey = "cloudSync.stamps"
    static let seenKey = "cloudSync.seen"
    /// When this device joined the sync: cloud entries older than that are not taken by themselves.
    static let joinedKey = "cloudSync.joinedAt"
    static let settingPrefix = "set."
    static let lookPrefix = "look."
    static let devicePrefix = "dev."
    /// A photo larger than this stays on its device: the whole store holds 1 MB.
    static let photoLimit = 60_000

    let cloud: CloudKeyValueStore
    let defaults: UserDefaults
    var deviceID = "device"
    var deviceName = "Device"
    var now: () -> Double = { Date().timeIntervalSince1970 }
    /// A bot's photo as it should travel (a small JPEG), and something that changes when the
    /// photo does. Files in the app; nothing in tests.
    var photoData: (String) -> Data? = { _ in nil }
    var photoStamp: (String) -> String? = { _ in nil }
    var savePhoto: (String, Data) -> Void = { _, _ in }

    @discardableResult
    func reconcile(_ mode: Mode) -> Outcome {
        var stamps = (defaults.dictionary(forKey: Self.stampsKey) as? [String: Double]) ?? [:]
        var seen = (defaults.dictionary(forKey: Self.seenKey) as? [String: String]) ?? [:]
        let before = (stamps, seen)
        var out = Outcome()
        var joined = defaults.double(forKey: Self.joinedKey)
        if joined == 0 { joined = now(); defaults.set(joined, forKey: Self.joinedKey) }

        for key in Self.syncedSettings {
            let ck = Self.settingPrefix + key
            let local = defaults.object(forKey: key)
            let entry = cloud.cloudValue(ck) as? [String: Any]
            let cloudValue = entry?["v"]
            step(ck, local: local.map(Self.fingerprint), cloud: cloudValue.map(Self.fingerprint), cloudTime: entry?["t"] as? Double,
                 mode: mode, joined: joined, stamps: &stamps, seen: &seen, out: &out,
                 push: { t in if let local { cloud.setCloudValue(["v": local, "t": t], for: ck) } },
                 apply: { defaults.set(cloudValue, forKey: key); return cloudValue.map(Self.fingerprint) })
        }

        reconcileLooks(mode, joined: joined, stamps: &stamps, seen: &seen, out: &out)

        // Only when something moved: writing these wakes the defaults observer again.
        if stamps != before.0 { defaults.set(stamps, forKey: Self.stampsKey) }
        if seen != before.1 { defaults.set(seen, forKey: Self.seenKey) }
        if out.pushed > 0 {
            cloud.setCloudValue(["name": deviceName, "t": now()], for: Self.devicePrefix + deviceID)
            cloud.flush()
        }
        return out
    }

    /// One key: which way, if any, it moves.
    private func step(_ ck: String, local: String?, cloud cloudFP: String?, cloudTime: Double?, mode: Mode, joined: Double,
                      stamps: inout [String: Double], seen: inout [String: String], out: inout Outcome,
                      push: (Double) -> Void, apply: () -> String?) {
        func agree(_ fp: String?, at t: Double) { stamps[ck] = t; seen[ck] = fp }
        func doPush() { let t = now(); push(t); agree(local, at: t); out.pushed += 1 }
        func doApply() { let fp = apply(); agree(fp, at: cloudTime ?? 0); out.applied += 1 }

        switch mode {
        case .restore:
            if let cloudTime {
                if cloudFP == local { agree(local, at: cloudTime) } else { doApply() }
            } else if local != nil { doPush() }
        case .backUp:
            if local != nil { doPush() }
        case .merge:
            let changedHere = local != seen[ck]
            if let cloudTime, cloudTime > (stamps[ck] ?? 0) {
                if cloudFP == local { agree(local, at: cloudTime) }
                // In the cloud before this device joined: both sides stay as they are until one
                // of them changes (or the person restores).
                else if stamps[ck] == nil, cloudTime <= joined { agree(local, at: cloudTime) }
                // Changed here since the last agreement: this device's edit is the later act.
                else if changedHere { doPush() }
                else { doApply() }
            } else if changedHere, local != nil || seen[ck] != nil {
                doPush()
            }
        }
    }

    // MARK: Bot looks, one entry per bot

    private func reconcileLooks(_ mode: Mode, joined: Double, stamps: inout [String: Double], seen: inout [String: String], out: inout Outcome) {
        var colors = Self.map(defaults.string(forKey: BotColors.storageKey))
        var avatars = Self.map(defaults.string(forKey: BotAvatarStore.storageKey))
        let original = (colors, avatars)

        var names = Set(colors.keys).union(avatars.keys)
        for key in cloud.cloudKeys where key.hasPrefix(Self.lookPrefix) {
            if let n = (cloud.cloudValue(key) as? [String: Any])?["n"] as? String { names.insert(n) }
        }

        for name in names.sorted() {
            let ck = Self.lookKey(name)
            let entry = cloud.cloudValue(ck) as? [String: Any]
            let gone = entry?["gone"] as? Bool == true
            let hex = colors[name], avatar = avatars[name]
            let local: String? = (hex == nil && avatar == nil) ? nil
                : Self.lookFingerprint(hex: hex, avatar: avatar, photo: avatar == "photo" ? photoStamp(name) : nil)
            let cloudFP: String? = (entry == nil || gone) ? nil
                : Self.lookFingerprint(hex: entry?["hex"] as? String, avatar: entry?["avatar"] as? String, photo: entry?["ph"] as? String)

            step(ck, local: local, cloud: cloudFP, cloudTime: entry?["t"] as? Double, mode: mode, joined: joined, stamps: &stamps, seen: &seen, out: &out,
                 push: { t in
                    guard local != nil else { cloud.setCloudValue(["n": name, "gone": true, "t": t], for: ck); return }
                    var e: [String: Any] = ["n": name, "t": t]
                    e["hex"] = hex; e["avatar"] = avatar
                    if avatar == "photo", let data = photoData(name), data.count <= Self.photoLimit {
                        e["photo"] = data; e["ph"] = Self.hash(data)
                    }
                    cloud.setCloudValue(e, for: ck)
                 },
                 apply: {
                    guard let entry, !gone else { colors[name] = nil; avatars[name] = nil; return nil }
                    colors[name] = entry["hex"] as? String
                    avatars[name] = entry["avatar"] as? String
                    if let data = entry["photo"] as? Data { savePhoto(name, data) }
                    return Self.lookFingerprint(hex: colors[name], avatar: avatars[name], photo: avatars[name] == "photo" ? photoStamp(name) : nil)
                 })
        }

        if colors != original.0 { defaults.set(Self.string(colors), forKey: BotColors.storageKey) }
        if avatars != original.1 { defaults.set(Self.string(avatars), forKey: BotAvatarStore.storageKey) }
    }

    // MARK: What is there

    /// What the cloud holds, without the gateways (those are in the Keychain).
    func summary() -> CloudSummary {
        var s = CloudSummary()
        var latest: (name: String, t: Double, own: Bool)?
        for key in cloud.cloudKeys {
            if key.hasPrefix(Self.settingPrefix) { s.settings += 1 }
            else if key.hasPrefix(Self.lookPrefix) {
                if (cloud.cloudValue(key) as? [String: Any])?["gone"] as? Bool != true { s.bots += 1 }
            } else if key.hasPrefix(Self.devicePrefix), let d = cloud.cloudValue(key) as? [String: Any], let t = d["t"] as? Double {
                let own = key == Self.devicePrefix + deviceID
                // Another device's word over this one's own; among those, the latest.
                if latest == nil || (latest!.own && !own) || (latest!.own == own && t > latest!.t) {
                    latest = (d["name"] as? String ?? "another device", t, own)
                }
            }
        }
        if let latest { s.device = latest.name; s.date = Date(timeIntervalSince1970: latest.t) }
        return s
    }

    // MARK: Small things

    /// One string per value, the same for a value read here and the one that came back from
    /// the cloud (a Bool is a number on both sides).
    static func fingerprint(_ value: Any) -> String { "\(value)" }

    static func lookFingerprint(hex: String?, avatar: String?, photo: String?) -> String {
        "\(hex ?? "")|\(avatar ?? "")|\(photo ?? "")"
    }

    /// The cloud's keys hold 64 bytes: a long bot name goes in by its hash.
    static func lookKey(_ name: String) -> String {
        name.utf8.count <= 48 ? lookPrefix + name : lookPrefix + "#" + hash(Data(name.utf8))
    }

    /// FNV-1a, stable across launches (Swift's own hashing is seeded per process).
    static func hash(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    static func map(_ raw: String?) -> [String: String] {
        guard let raw, let data = raw.data(using: .utf8), let m = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return m
    }

    static func string(_ map: [String: String]) -> String {
        (try? JSONEncoder().encode(map)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: Gateways, through iCloud Keychain

/// One saved gateway as it travels: where it is and how it signs in, and the secrets that are
/// the same on every device (a session token, Cloudflare Access values). A browser sign-in
/// stays with its device: two devices sharing one refresh token log each other out.
struct CloudGateway: Codable, Equatable {
    var connection: GatewayConnection
    var sessionToken: String?
    var access: CloudflareAccess
    var updatedAt: Double

    /// What makes two copies the same gateway setup; the bookkeeping fields do not count.
    var signature: String {
        [connection.name, connection.gateway.description, "\(connection.authMode)", connection.authProvider ?? "", connection.connectionKind ?? "",
         sessionToken ?? "", access.clientId, access.clientSecret].joined(separator: "\u{1f}")
    }
}

struct CloudGatewayFile: Codable, Equatable {
    var gateways: [CloudGateway] = []
    /// Gateways removed on some device, by id, so the copy on another does not bring them back.
    var deleted: [String: Double] = [:]
}

/// The synced copy of the gateway list. The device-only Keychain items stay the source of
/// truth for the running app, its extensions and the watch; this is a separate item that
/// iCloud Keychain carries, merged in on restore.
@MainActor
enum CloudGateways {
    static let account = "gateways"
    static let knownKey = "cloudSync.knownGateways"

    static func load() -> CloudGatewayFile {
        Keychain.getSynced(account: account).flatMap { try? JSONDecoder().decode(CloudGatewayFile.self, from: $0) } ?? CloudGatewayFile()
    }

    static func save(_ file: CloudGatewayFile) {
        if let data = try? JSONEncoder().encode(file) { try? Keychain.setSynced(data, account: account) }
    }

    /// This device's gateways into the synced copy: new and changed ones go in, one removed
    /// here leaves it and is remembered as removed. Returns whether anything changed.
    @discardableResult
    static func push(store: ConnectionStore, defaults: UserDefaults = .standard, now: Double = Date().timeIntervalSince1970) -> Bool {
        var file = load()
        let before = file
        let local = store.connections
        let known = Set(defaults.stringArray(forKey: knownKey) ?? [])

        for c in local {
            let secrets = store.secrets(for: c.id)
            let mine = CloudGateway(connection: c, sessionToken: c.authMode == .sessionToken ? secrets.sessionToken : nil, access: secrets.access, updatedAt: now)
            if let i = file.gateways.firstIndex(where: { $0.connection.id == c.id }) {
                if file.gateways[i].signature != mine.signature { file.gateways[i] = mine }
            } else if file.deleted[c.id.uuidString] == nil {
                file.gateways.append(mine)
            }
        }
        // Had it, pushed it, and it is gone now: removed here.
        let localIDs = Set(local.map(\.id.uuidString))
        for id in known.subtracting(localIDs) {
            file.gateways.removeAll { $0.connection.id.uuidString == id }
            file.deleted[id] = now
        }
        defaults.set(Array(localIDs).sorted(), forKey: knownKey)
        guard file != before else { return false }
        save(file)
        return true
    }

    /// The synced copy into this device: gateways it does not have are added, signed in when
    /// their sign-in travels. Nothing here is replaced or removed. Returns the ones added.
    @discardableResult
    static func merge(into store: ConnectionStore, defaults: UserDefaults = .standard) -> [CloudGateway] {
        var added: [CloudGateway] = []
        for g in load().gateways where store.connection(id: g.connection.id) == nil {
            let secrets = GatewaySecrets(sessionToken: g.sessionToken, provider: g.connection.authProvider, access: g.access)
            if (try? store.upsert(g.connection, secrets: secrets)) != nil { added.append(g) }
        }
        if !added.isEmpty {
            defaults.set(Array(Set(store.connections.map(\.id.uuidString))).sorted(), forKey: knownKey)
        }
        return added
    }
}

// MARK: The running sync

@MainActor
@Observable
final class CloudSync {
    static let shared = CloudSync()
    static let enabledKey = "cloudSync.enabled"
    static let deviceIDKey = "cloudSync.deviceID"

    /// What a restore did, for the screen that asked for it.
    struct RestoreOutcome: Equatable {
        var settings = 0
        var gateways = 0
        /// Restored gateways whose sign-in stays per device: they need one here.
        var needSignIn = 0
    }

    /// On unless switched off in Settings › iCloud Sync.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { syncNow() }
        }
    }
    private(set) var lastSyncedAt: Date?
    /// Bumped whenever the cloud's contents may have changed, so a summary on screen is read again.
    private(set) var revision = 0

    /// Whether this device is signed in to iCloud at all (never in the simulator).
    var signedIn: Bool { FileManager.default.ubiquityIdentityToken != nil }

    @ObservationIgnored private let cloud = NSUbiquitousKeyValueStore.default
    @ObservationIgnored private weak var store: ConnectionStore?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// While the app is being reset: nothing taken apart here must reach iCloud as a change.
    @ObservationIgnored var suspended = false

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private var merge: CloudMerge {
        let defaults = UserDefaults.standard
        var id = defaults.string(forKey: Self.deviceIDKey) ?? ""
        if id.isEmpty { id = String(UUID().uuidString.prefix(8)).lowercased(); defaults.set(id, forKey: Self.deviceIDKey) }
        var m = CloudMerge(cloud: cloud, defaults: defaults)
        m.deviceID = id
        m.deviceName = PushRegistrar.deviceName
        m.photoStamp = { name in
            guard let url = BotAvatarStore.photoURL(for: name), let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            return "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\(a[.size] as? Int ?? 0)"
        }
        m.photoData = { name in BotAvatarStore.photo(for: name)?.jpegData(compressionQuality: 0.6) }
        m.savePhoto = { name, data in try? BotAvatarStore.savePhoto(data, for: name) }
        return m
    }

    /// Called once the app model exists. Nothing is read or written until the next turn of the
    /// run loop: the model is still being made when this is called.
    func start(store: ConnectionStore) {
        guard !started else { return }
        started = true
        self.store = store
        let center = NotificationCenter.default
        center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cloudChanged() }
        }
        // A setting changed here (or was just applied from the cloud, which the merge sees as
        // already agreed and leaves alone).
        center.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.localChanged() }
        }
        Task { @MainActor in
            self.cloud.synchronize()
            self.syncNow()
            self.watchGateways()
        }
    }

    /// Both ways, now. A device with no gateway yet takes none: that is Restore's job, on the
    /// first screen, where the person chooses it.
    func syncNow() {
        guard enabled, started, !suspended else { return }
        let out = merge.reconcile(.merge)
        if out.applied > 0 { BotLooksMirror.mirror() }
        if let store {
            if !store.connections.isEmpty { CloudGateways.merge(into: store) }
            CloudGateways.push(store: store)
        }
        lastSyncedAt = Date()
        revision += 1
    }

    private func cloudChanged() {
        revision += 1
        syncNow()
    }

    private func localChanged() {
        guard enabled, started, !suspended else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self.syncNow()
        }
    }

    /// The gateway list is observable: a gateway added, edited or removed goes up.
    private func watchGateways() {
        guard let store else { return }
        withObservationTracking { _ = store.connections } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.enabled, !self.suspended, let store = self.store { CloudGateways.push(store: store) }
                self.watchGateways()
            }
        }
    }

    // MARK: Restore and back up

    /// What iCloud holds right now.
    func summary() -> CloudSummary {
        var s = merge.summary()
        s.gateways = CloudGateways.load().gateways.count
        return s
    }

    /// Asks iCloud for its latest and waits a moment for it: on a new device the store starts empty.
    func refresh() async -> CloudSummary {
        cloud.synchronize()
        for _ in 0..<8 {
            let s = summary()
            if !s.isEmpty { return s }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return summary()
    }

    /// iCloud's settings and looks over this device's, and its gateways added to this device's.
    @discardableResult
    func restore() -> RestoreOutcome {
        var result = RestoreOutcome()
        result.settings = merge.reconcile(.restore).applied
        BotLooksMirror.mirror()
        if let store {
            let added = CloudGateways.merge(into: store)
            result.gateways = added.count
            result.needSignIn = added.filter { $0.connection.authMode != .sessionToken || ($0.sessionToken ?? "").isEmpty }.count
            CloudGateways.push(store: store)
        }
        lastSyncedAt = Date()
        revision += 1
        return result
    }

    /// Everything Vory keeps in iCloud, gone: the settings, the looks and the synced gateway list.
    func eraseCloud() {
        for key in cloud.cloudKeys where key.hasPrefix(CloudMerge.settingPrefix) || key.hasPrefix(CloudMerge.lookPrefix) || key.hasPrefix(CloudMerge.devicePrefix) {
            cloud.removeObject(forKey: key)
        }
        Keychain.deleteSynced(account: CloudGateways.account)
        cloud.synchronize()
        revision += 1
    }

    /// After a reset: this device joins again as a new one.
    func resumeAfterReset() {
        pending?.cancel()
        suspended = false
        lastSyncedAt = nil
        enabled = true
    }

    /// This device's settings, looks and gateways over what iCloud holds.
    func backUpNow() {
        merge.reconcile(.backUp)
        if let store { CloudGateways.push(store: store) }
        cloud.synchronize()
        lastSyncedAt = Date()
        revision += 1
    }
}
