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
    /// Ask for a sync with the server soon; a no-op where there is none. False when the store
    /// would not take it (over its quota, or no iCloud account).
    @discardableResult func flush() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudKeyValueStore {
    func cloudValue(_ key: String) -> Any? { object(forKey: key) }
    func setCloudValue(_ value: Any?, for key: String) {
        if let value { set(value, forKey: key) } else { removeObject(forKey: key) }
    }
    var cloudKeys: [String] { Array(dictionaryRepresentation.keys) }
    @discardableResult func flush() -> Bool { synchronize() }
}

/// A cloud that is a dictionary: two `CloudMerge`s sharing one stand in for two devices.
final class MemoryCloudStore: CloudKeyValueStore {
    var values: [String: Any] = [:]
    func cloudValue(_ key: String) -> Any? { values[key] }
    func setCloudValue(_ value: Any?, for key: String) { values[key] = value }
    var cloudKeys: [String] { Array(values.keys) }
    @discardableResult func flush() -> Bool { true }
}

// MARK: The merge

/// What iCloud holds, for the restore screens.
struct CloudSummary: Equatable {
    var settings = 0
    var bots = 0
    var gateways = 0
    /// The name Home greets the person by, when iCloud holds one.
    var name: String?
    /// The device that wrote to iCloud last, this one included (it used to prefer another
    /// device's word, so a backup made here never showed as the last one).
    var device: String?
    var date: Date?
    /// The last write was this device's.
    var isOwnDevice = false
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
        HomeLayout.storageKey, HomeLayout.allBotsKey, nameKey,
        ChatStyle.showToolCalls, ChatStyle.showReasoning, ChatStyle.showTurnStats, ChatStyle.showSystemNotes,
        ChatStyle.showBots, ChatStyle.showToolOutput, ChatStyle.currentStepOnly, ChatStyle.compactTools,
        ChatStyle.collapseAfterTurn, ChatStyle.bubbleStyle, ChatStyle.botTint, ChatStyle.wideReplies, ChatStyle.returnSends,
        BotAvatarStore.glassAllKey, GatewayRuntime.defaultProfileKey,
        ChatSummarizer.enabledKey, ChatSummarizer.titlesKey, ChatSummarizer.previewsKey, ChatGoals.enabledKey,
    ] + VoiceSettings.syncedKeys

    /// The name Home greets the person by.
    static let nameKey = "user.name"
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
            stamp()
            cloud.flush()
        }
        return out
    }

    /// This device's "last write" entry: its name and now.
    func stamp() {
        cloud.setCloudValue(["name": deviceName, "t": now()], for: Self.devicePrefix + deviceID)
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
            if key.hasPrefix(Self.settingPrefix) {
                s.settings += 1
                if key == Self.settingPrefix + Self.nameKey, let n = ((cloud.cloudValue(key) as? [String: Any])?["v"] as? String)?.trimmingCharacters(in: .whitespaces), !n.isEmpty { s.name = n }
            }
            else if key.hasPrefix(Self.lookPrefix) {
                if (cloud.cloudValue(key) as? [String: Any])?["gone"] as? Bool != true { s.bots += 1 }
            } else if key.hasPrefix(Self.devicePrefix), let d = cloud.cloudValue(key) as? [String: Any], let t = d["t"] as? Double {
                let own = key == Self.devicePrefix + deviceID
                // The latest write, whichever device made it: a backup made here is the last one.
                if latest == nil || t > latest!.t {
                    latest = (d["name"] as? String ?? "another device", t, own)
                }
            }
        }
        if let latest { s.device = latest.name; s.date = Date(timeIntervalSince1970: latest.t); s.isOwnDevice = latest.own }
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

    /// The same gateway, whatever id a device saved it under (one added again after a reset
    /// gets a new id): where it is and how it signs in.
    var address: String { CloudGateways.address(connection) }
}

struct CloudGatewayFile: Codable, Equatable {
    var gateways: [CloudGateway] = []
    /// Gateways removed on some device, by id, so the copy on another does not bring them back.
    var deleted: [String: Double] = [:]
    /// When someone chose "Reset and Erase iCloud Data": a device that joined before that
    /// stops syncing and says so, instead of quietly putting its own copy back.
    var erasedAt: Double?
}

/// The synced copy of the gateway list. The device-only Keychain items stay the source of
/// truth for the running app, its extensions and the watch; this is a separate item that
/// iCloud Keychain carries.
///
/// The same memory the settings have, per gateway: the time of the cloud copy this device
/// last agreed with, and what its own copy looked like then. A gateway edited here goes up; one
/// edited elsewhere comes down; neither is sent back and forth.
/// What the gateway merge needs from the store of saved gateways: the app's `ConnectionStore`,
/// or a plain list in tests (two of them stand in for two devices).
@MainActor
protocol GatewayStoring: AnyObject {
    var connections: [GatewayConnection] { get }
    func connection(id: UUID) -> GatewayConnection?
    func secrets(for id: UUID) -> GatewaySecrets
    func upsert(_ connection: GatewayConnection, secrets: GatewaySecrets) throws
    /// Forgets the sign-in this device remembers for the gateway, if any (no Face ID needed).
    /// A merge while the device is locked cannot delete it: it is no longer offered, and is
    /// deleted once the device is unlocked (see `RememberedSignInVault.pendingForgets`).
    func forgetRememberedSignIn(_ id: UUID)
}

extension ConnectionStore: GatewayStoring {
    func forgetRememberedSignIn(_ id: UUID) { remembered.forget(id) }
}

@MainActor
enum CloudGateways {
    static let account = "gateways"
    static let knownKey = "cloudSync.knownGateways"
    static let stampsKey = "cloudSync.gatewayStamps"
    static let seenKey = "cloudSync.gatewaySeen"

    /// What a pass did. `changed` are gateways this device already had whose setup came down.
    struct Outcome: Equatable {
        var added: [CloudGateway] = []
        var changed: [UUID] = []
        var pushed = false
    }

    /// The cloud's file. A dictionary in tests; the synced Keychain item in the app.
    struct Storage {
        var load: () -> CloudGatewayFile
        var save: (CloudGatewayFile) -> Void

        @MainActor static let keychain = Storage(
            load: { Keychain.getSynced(account: CloudGateways.account).flatMap { try? JSONDecoder().decode(CloudGatewayFile.self, from: $0) } ?? CloudGatewayFile() },
            save: { file in if let data = try? JSONEncoder().encode(file) { try? Keychain.setSynced(data, account: CloudGateways.account) } })
    }

    static func load() -> CloudGatewayFile { Storage.keychain.load() }

    nonisolated static func address(_ c: GatewayConnection) -> String {
        "\(c.gateway.description.lowercased())|\(c.authMode)|\(c.authProvider ?? "")"
    }

    /// An address only this machine can reach: it means nothing on another device.
    nonisolated static func isLoopback(_ c: GatewayConnection) -> Bool {
        #if DEBUG
        // The demo copy's whole world is a mock on this machine, its "iCloud" included.
        if DemoMode.isOn { return false }
        #endif
        let host = c.gateway.host.lowercased()
        return host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.") || host.hasSuffix(".localhost")
    }

    /// One pass, both ways.
    ///
    /// - A gateway here that the cloud lacks goes up (unless it was removed elsewhere, is a
    ///   loopback address, or the cloud already has the same address under another id).
    /// - A gateway both have: edited here since the last agreement, it goes up; edited
    ///   elsewhere, it comes down; the same, nothing moves.
    /// - A gateway removed here leaves the cloud and is remembered as removed.
    /// - `importNew`: gateways only the cloud has are added here. Off for a device that has
    ///   none yet, where bringing them in is Restore's job.
    @discardableResult
    static func reconcile(store: any GatewayStoring, importNew: Bool, storage: Storage = .keychain,
                          defaults: UserDefaults = .standard, now: Double = Date().timeIntervalSince1970) -> Outcome {
        var file = storage.load()
        let before = file
        var out = Outcome()
        var stamps = (defaults.dictionary(forKey: stampsKey) as? [String: Double]) ?? [:]
        var seen = (defaults.dictionary(forKey: seenKey) as? [String: String]) ?? [:]
        let known = Set(defaults.stringArray(forKey: knownKey) ?? [])

        func copy(of c: GatewayConnection) -> CloudGateway {
            let secrets = store.secrets(for: c.id)
            return CloudGateway(connection: c, sessionToken: c.authMode == .sessionToken ? secrets.sessionToken : nil, access: secrets.access, updatedAt: now)
        }

        for c in store.connections {
            let id = c.id.uuidString
            let mine = copy(of: c)
            if let i = file.gateways.firstIndex(where: { $0.connection.id == c.id }) {
                let theirs = file.gateways[i]
                if theirs.signature == mine.signature {
                    stamps[id] = theirs.updatedAt; seen[id] = mine.signature
                } else if seen[id] == nil {
                    // The first meeting with different copies: both stay until one is edited.
                    stamps[id] = theirs.updatedAt; seen[id] = mine.signature
                } else if seen[id] != mine.signature {
                    // Edited here since the last agreement: this device's edit goes up.
                    file.gateways[i] = mine
                    stamps[id] = now; seen[id] = mine.signature
                } else if theirs.updatedAt > (stamps[id] ?? 0) {
                    // Edited on another device since this one last agreed: take it. What travels
                    // is the setup and the secrets every device shares; a browser sign-in stays.
                    var conn = c
                    conn.name = theirs.connection.name
                    conn.gateway = theirs.connection.gateway
                    conn.authMode = theirs.connection.authMode
                    conn.authProvider = theirs.connection.authProvider
                    conn.connectionKind = theirs.connection.connectionKind
                    var secrets = store.secrets(for: c.id)
                    if theirs.connection.authMode == .sessionToken { secrets.sessionToken = theirs.sessionToken }
                    secrets.access = theirs.access
                    if (try? store.upsert(conn, secrets: secrets)) != nil {
                        out.changed.append(c.id)
                        stamps[id] = theirs.updatedAt; seen[id] = theirs.signature
                        // A sign-in remembered here was typed for the old address and method. Of
                        // no use now, and kept, it would still be offered behind Face ID.
                        if conn.gateway != c.gateway || conn.authMode != c.authMode { store.forgetRememberedSignIn(c.id) }
                    }
                }
            } else if file.deleted[id] == nil, !isLoopback(c) {
                // The same address under another id (added again after a reset): this copy
                // takes its place, so no device ends up with the address twice.
                if let j = file.gateways.firstIndex(where: { $0.address == mine.address }) {
                    file.deleted[file.gateways[j].connection.id.uuidString] = now
                    file.gateways.remove(at: j)
                }
                file.gateways.append(mine)
                stamps[id] = now; seen[id] = mine.signature
            }
        }

        // Had it, pushed it, and it is gone now: removed here.
        let localIDs = Set(store.connections.map(\.id.uuidString))
        for id in known.subtracting(localIDs) {
            file.gateways.removeAll { $0.connection.id.uuidString == id }
            file.deleted[id] = now
            stamps[id] = nil; seen[id] = nil
        }

        if importNew {
            let addresses = Set(store.connections.map(address))
            for g in file.gateways where store.connection(id: g.connection.id) == nil {
                // Not a second copy of an address this device already has, and not an address
                // only the device that saved it can reach.
                guard !addresses.contains(g.address), !isLoopback(g.connection) else { continue }
                let secrets = GatewaySecrets(sessionToken: g.sessionToken, provider: g.connection.authProvider, access: g.access)
                if (try? store.upsert(g.connection, secrets: secrets)) != nil {
                    out.added.append(g)
                    let id = g.connection.id.uuidString
                    stamps[id] = g.updatedAt; seen[id] = g.signature
                }
            }
        }

        defaults.set(Array(Set(store.connections.map(\.id.uuidString))).sorted(), forKey: knownKey)
        defaults.set(stamps, forKey: stampsKey)
        defaults.set(seen, forKey: seenKey)
        if file != before { storage.save(file); out.pushed = true }
        return out
    }
}

// MARK: The running sync

@MainActor
@Observable
final class CloudSync {
    static let shared = CloudSync()
    static let enabledKey = "cloudSync.enabled"
    static let deviceIDKey = "cloudSync.deviceID"
    static let erasedSeenKey = "cloudSync.erasedSeen"
    /// In the key-value store: when the iCloud data was last erased from a device.
    static let erasedAtCloudKey = "meta.erasedAt"

    /// What a restore did, for the screen that asked for it.
    struct RestoreOutcome: Equatable {
        var settings = 0
        var gateways = 0
        /// Restored gateways whose sign-in stays per device: they need one here.
        var needSignIn = 0
        /// Those gateways, for the sign-in that follows a restore.
        var pending: [GatewayConnection] = []
        /// No gateway came and this device has none: they are taken when their iCloud
        /// Keychain item arrives.
        var gatewaysAwaited = false
    }
    /// Set by a restore that brought no gateway to a device with none: the running sync
    /// takes them when their item arrives.
    static let awaitingGatewaysKey = "cloudSync.awaitingGateways"
    /// Settings › iCloud Sync › Back up automatically: once a day, from this device; per device, on unless turned off.
    nonisolated static let autoBackupKey = "cloudSync.autoBackup"
    /// When this device last backed itself up (Back Up Now or the daily one), seconds since 1970; per device.
    nonisolated static let lastOwnBackupKey = "cloudSync.lastOwnBackupAt"
    /// The background task that runs the daily backup when the system allows (Info.plist lists it).
    nonisolated static let backupTaskID = "com.vorantx.vory.backup"
    /// How old this device's last backup may be before the daily one runs.
    nonisolated static let backupInterval: TimeInterval = 24 * 3600

    /// Whether the daily backup is due: never backed up, or the last one is over a day old.
    nonisolated static func backupDue(lastBackupAt: Double?, now: Double) -> Bool {
        guard let last = lastBackupAt else { return true }
        return now - last >= backupInterval
    }

    /// On unless switched off in Settings › iCloud Sync.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { pausedByErase = nil; syncNow() }
        }
    }
    private(set) var lastSyncedAt: Date?
    /// Why the last pass did not reach iCloud, in plain words; nil when it did.
    private(set) var lastSyncError: String?
    /// Settings › iCloud Sync › Back up automatically.
    var autoBackup: Bool {
        didSet { UserDefaults.standard.set(autoBackup, forKey: Self.autoBackupKey) }
    }
    /// When this device last backed itself up, by hand or by the day.
    private(set) var lastOwnBackupAt: Date?
    /// Why the last daily backup did not happen; shown under the switch, never a prompt.
    private(set) var lastAutoBackupError: String?
    /// A restore is running: nothing backs up over it.
    @ObservationIgnored private var restoring = false
    /// Bumped whenever the cloud's contents may have changed, so a summary on screen is read again.
    private(set) var revision = 0
    /// Set when another device erased the iCloud data: this one stopped syncing rather than
    /// put its own copy back, and Settings says so.
    private(set) var pausedByErase: Date?

    /// Whether this device is signed in to iCloud at all (never in the simulator).
    var signedIn: Bool {
        #if DEBUG
        if DemoMode.isOn { return true }
        #endif
        return FileManager.default.ubiquityIdentityToken != nil
    }

    #if DEBUG
    /// The demo copy has no iCloud: a dictionary stands in for it.
    @ObservationIgnored private let cloud: any CloudKeyValueStore = DemoMode.cloud ?? NSUbiquitousKeyValueStore.default
    #else
    @ObservationIgnored private let cloud: any CloudKeyValueStore = NSUbiquitousKeyValueStore.default
    #endif
    @ObservationIgnored private weak var store: ConnectionStore?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// What the synced settings and looks looked like at the last pass: a defaults change
    /// that touches none of them (a cache, a last-visit time) costs nothing.
    @ObservationIgnored private var lastLocalFingerprint = ""
    /// While the app is being reset: nothing taken apart here must reach iCloud as a change.
    @ObservationIgnored var suspended = false

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        autoBackup = defaults.object(forKey: Self.autoBackupKey) as? Bool ?? true
        let last = defaults.double(forKey: Self.lastOwnBackupKey)
        lastOwnBackupAt = last > 0 ? Date(timeIntervalSince1970: last) : nil
    }

    private var deviceID: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: Self.deviceIDKey), !id.isEmpty { return id }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        defaults.set(id, forKey: Self.deviceIDKey)
        return id
    }

    private var merge: CloudMerge {
        var m = CloudMerge(cloud: cloud, defaults: .standard)
        m.deviceID = deviceID
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
        center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud as? NSUbiquitousKeyValueStore, queue: .main) { [weak self] n in
            // The store says why it changed: an account change or a full store are the two
            // that deserve a word on the page; a plain change from another device just syncs.
            // (Read before the hop: a Notification does not cross into the actor.)
            let reason = n.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            MainActor.assumeIsolated {
                if let reason {
                    if reason == NSUbiquitousKeyValueStoreAccountChange { self?.lastSyncError = "The iCloud account changed; sync starts over with the account now signed in." }
                    else if reason == NSUbiquitousKeyValueStoreQuotaViolationChange { self?.lastSyncError = "iCloud's key-value store is full; the last change did not reach it." }
                    else { self?.lastSyncError = nil }
                }
                self?.syncNow()
            }
        }
        // A setting changed here (or was just applied from the cloud, which the merge sees as
        // already agreed and leaves alone).
        center.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.localChanged() }
        }
        Task { @MainActor in
            self.cloud.flush()
            self.syncNow()
            self.watchGateways()
        }
    }

    /// Everything, both ways, now: on launch, when iCloud says something changed, when the app
    /// comes forward, and when sync is switched on.
    func syncNow() {
        guard enabled, started, !suspended, !stoppedByErase() else { return }
        syncSettings()
        syncGateways()
        if !cloud.flush() { lastSyncError = "iCloud did not take the last sync: the store may be full, or \(DeviceWords.this) is not signed in." }
        else if lastSyncError?.hasPrefix("iCloud did not take") == true { lastSyncError = nil }
        lastSyncedAt = Date()
        revision += 1
        // The day's backup, when it is due: launch, coming forward, and the Mac's activation
        // all come through here.
        backUpIfDue()
    }

    /// The daily backup, quietly, when the switch is on, iCloud is there, no restore is
    /// running and this device's last backup is over a day old. The same backup as Back Up
    /// Now; a failure is a line under the switch, never a prompt.
    func backUpIfDue() {
        guard autoBackup, enabled, started, !suspended, !restoring else { return }
        guard Self.backupDue(lastBackupAt: lastOwnBackupAt?.timeIntervalSince1970, now: Date().timeIntervalSince1970) else { return }
        guard signedIn else { lastAutoBackupError = "\(DeviceWords.This) is not signed in to iCloud."; return }
        guard !stoppedByErase() else { lastAutoBackupError = "Sync stopped after the iCloud data was erased from another device."; return }
        if backUpNow() { lastAutoBackupError = nil }
        else { lastAutoBackupError = "iCloud did not take it: the store may be full, or iCloud is unreachable." }
    }

    private func syncSettings() {
        let out = merge.reconcile(.merge)
        lastLocalFingerprint = localFingerprint()
        if out.applied > 0 { BotLooksMirror.mirror() }
    }

    /// A device with no gateway yet takes none: that is Restore's job, on the first screen,
    /// where the person chooses it. Unless a restore already asked for them and they had not
    /// arrived: gateways travel as an iCloud Keychain item, which can reach a new device
    /// minutes after the settings do, so they are taken when it shows up (#181).
    private func syncGateways() {
        guard let store else { return }
        let defaults = UserDefaults.standard
        let awaiting = defaults.bool(forKey: Self.awaitingGatewaysKey)
        let out = CloudGateways.reconcile(store: store, importNew: Self.importsGateways(hasConnections: !store.connections.isEmpty, awaiting: awaiting))
        reconnectIfChanged(out.changed)
        if awaiting, !store.connections.isEmpty {
            defaults.removeObject(forKey: Self.awaitingGatewaysKey)
            if !out.added.isEmpty { gatewaysArrived(out.added, store: store) }
        }
    }

    /// Whether a sync pass takes gateways only the cloud has: a device with gateways follows
    /// the list; one with none waits for Restore, or for the gateways a restore is owed.
    nonisolated static func importsGateways(hasConnections: Bool, awaiting: Bool) -> Bool {
        hasConnections || awaiting
    }

    /// The gateways a restore was owed came in: the first is connected, the way the restore
    /// itself would have, and the ones whose sign-in stays per device are asked for.
    private func gatewaysArrived(_ added: [CloudGateway], store: ConnectionStore) {
        let model = AppModel.shared
        model.signInPrompt = Self.pendingSignIns(added, in: store)
        if model.runtime == nil { Task { await model.activateSavedConnection() } }
    }

    /// Among restored gateways, the ones this device cannot use until it signs in: a session
    /// token travels, a browser or password sign-in does not. As saved here: the restore may
    /// have given a gateway a new id on this device.
    static func pendingSignIns(_ added: [CloudGateway], in store: any GatewayStoring) -> [GatewayConnection] {
        added.filter { $0.connection.authMode != .sessionToken || ($0.sessionToken ?? "").isEmpty }
            .compactMap { p in store.connections.first { $0.id == p.connection.id } ?? store.connections.first { $0.gateway == p.connection.gateway } }
    }

    /// Looks for the gateway item for a while: on a new device it can arrive after the
    /// settings. Returns how many gateways iCloud holds once it is there or the time is up.
    func waitForGateways(upTo seconds: Double) async -> Int {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let n = CloudGateways.load().gateways.count
            if n > 0 { revision += 1; return n }
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
        }
        return CloudGateways.load().gateways.count
    }

    /// A gateway whose address or token came down while the app is connected to it: connect again.
    private func reconnectIfChanged(_ ids: [UUID]) {
        let model = AppModel.shared
        guard let active = model.runtime?.connection.id, ids.contains(active), let conn = model.store.connection(id: active) else { return }
        Task { await model.deactivate(); await model.activate(conn) }
    }

    /// The values that sync, as one string. Photos are not in it: the looks mirror calls
    /// `looksChanged()` when one is replaced.
    private func localFingerprint() -> String {
        let d = UserDefaults.standard
        var parts = CloudMerge.syncedSettings.map { d.object(forKey: $0).map(CloudMerge.fingerprint) ?? "" }
        parts.append(d.string(forKey: BotColors.storageKey) ?? "")
        parts.append(d.string(forKey: BotAvatarStore.storageKey) ?? "")
        return parts.joined(separator: "\u{1f}")
    }

    /// Any defaults change lands here, and most are not ours (caches, last-visit times): only a
    /// change to something that syncs schedules a pass, and that pass is the settings alone.
    private func localChanged() {
        guard enabled, started, !suspended, localFingerprint() != lastLocalFingerprint else { return }
        schedule()
    }

    /// A bot's photo was replaced: its file changed, its settings did not.
    func looksChanged() {
        guard enabled, started, !suspended else { return }
        schedule()
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, self.enabled, !self.suspended, !self.stoppedByErase() else { return }
            self.syncSettings()
            self.lastSyncedAt = Date()
        }
    }

    /// The gateway list is observable: a gateway added, edited or removed goes up.
    private func watchGateways() {
        guard let store else { return }
        withObservationTracking { _ = store.connections } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.enabled, !self.suspended, !self.stoppedByErase(), let store = self.store {
                    CloudGateways.reconcile(store: store, importNew: false)
                }
                self.watchGateways()
            }
        }
    }

    // MARK: Erased elsewhere

    /// Someone erased the iCloud data from another device after this one joined: stop here and
    /// say so, rather than quietly putting this device's copy back. Turning sync on again in
    /// Settings joins afresh and puts this device's settings up.
    private func stoppedByErase() -> Bool {
        let defaults = UserDefaults.standard
        let erased = max((cloud.cloudValue(Self.erasedAtCloudKey) as? Double ?? 0), CloudGateways.load().erasedAt ?? 0)
        guard erased > defaults.double(forKey: Self.erasedSeenKey) else { return false }
        defaults.set(erased, forKey: Self.erasedSeenKey)
        let joined = defaults.double(forKey: CloudMerge.joinedKey)
        guard joined > 0, erased > joined else { return false }
        forgetAgreements()
        enabled = false
        pausedByErase = Date(timeIntervalSince1970: erased)
        return true
    }

    /// This device's memory of what it agreed with the cloud: gone, so its next pass is a first one.
    private func forgetAgreements() {
        let defaults = UserDefaults.standard
        for key in [CloudMerge.stampsKey, CloudMerge.seenKey, CloudMerge.joinedKey, CloudGateways.knownKey, CloudGateways.stampsKey, CloudGateways.seenKey] {
            defaults.removeObject(forKey: key)
        }
        lastLocalFingerprint = ""
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
        cloud.flush()
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
        restoring = true
        defer { restoring = false }
        var result = RestoreOutcome()
        result.settings = merge.reconcile(.restore).applied
        lastLocalFingerprint = localFingerprint()
        BotLooksMirror.mirror()
        if let store {
            let out = CloudGateways.reconcile(store: store, importNew: true)
            result.gateways = out.added.count
            result.pending = Self.pendingSignIns(out.added, in: store)
            result.needSignIn = result.pending.count
            reconnectIfChanged(out.changed)
            // Nothing came and this device has none: the gateway item has not reached this
            // device yet (or iCloud Keychain is off). The running sync takes them when it does.
            result.gatewaysAwaited = out.added.isEmpty && store.connections.isEmpty
            UserDefaults.standard.set(result.gatewaysAwaited, forKey: Self.awaitingGatewaysKey)
        }
        lastSyncedAt = Date()
        revision += 1
        return result
    }

    /// This device's settings, looks and gateways over what iCloud holds. True when iCloud
    /// took it; this device's last-backup time is kept either way it was asked.
    @discardableResult
    func backUpNow() -> Bool {
        let m = merge
        m.reconcile(.backUp)
        // The device's stamp goes up with every backup, even one with nothing new to push,
        // so "Last backup" says this device and now.
        m.stamp()
        lastLocalFingerprint = localFingerprint()
        if let store { CloudGateways.reconcile(store: store, importNew: false) }
        let took = cloud.flush()
        let at = Date()
        lastOwnBackupAt = at
        UserDefaults.standard.set(at.timeIntervalSince1970, forKey: Self.lastOwnBackupKey)
        lastSyncedAt = at
        revision += 1
        return took
    }

    // MARK: Reset

    /// Everything Vory keeps in iCloud, gone: the settings, the looks and the synced gateway
    /// list. A marker stays behind so the person's other devices stop syncing and say why,
    /// instead of putting their own copies straight back.
    func eraseCloud() {
        let now = Date().timeIntervalSince1970
        for key in cloud.cloudKeys where key.hasPrefix(CloudMerge.settingPrefix) || key.hasPrefix(CloudMerge.lookPrefix) || key.hasPrefix(CloudMerge.devicePrefix) {
            cloud.setCloudValue(nil, for: key)
        }
        cloud.setCloudValue(now, for: Self.erasedAtCloudKey)
        CloudGateways.Storage.keychain.save(CloudGatewayFile(erasedAt: now))
        cloud.flush()
        revision += 1
    }

    /// This device's own "last change from" entry, for a reset: it joins again under a new id.
    func removeOwnDeviceEntry() {
        cloud.setCloudValue(nil, for: CloudMerge.devicePrefix + deviceID)
    }

    /// After a reset: this device joins again as a new one. An erase it just did itself is not
    /// news to it.
    func resumeAfterReset() {
        pending?.cancel()
        suspended = false
        lastSyncedAt = nil
        lastLocalFingerprint = ""
        let erased = max((cloud.cloudValue(Self.erasedAtCloudKey) as? Double ?? 0), CloudGateways.load().erasedAt ?? 0)
        if erased > 0 { UserDefaults.standard.set(erased, forKey: Self.erasedSeenKey) }
        enabled = true
    }
}
