import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// The iCloud merge, with a dictionary for the cloud and one defaults suite per "device".
@MainActor
struct CloudSyncTests {
    final class Clock { var t: Double = 1_000 }

    /// A device: its own defaults, the shared cloud and the shared clock.
    private func device(_ cloud: MemoryCloudStore, _ clock: Clock, id: String) -> (CloudMerge, UserDefaults) {
        let suite = "cloud-test-\(id)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var merge = CloudMerge(cloud: cloud, defaults: defaults)
        merge.deviceID = id
        merge.deviceName = id
        merge.now = { clock.t += 1; return clock.t }
        return (merge, defaults)
    }

    /// Both devices have run the sync once: they have joined, with nothing to exchange yet.
    private func joined(_ devices: CloudMerge...) { for d in devices { d.reconcile(.merge) } }

    @Test func aChangeOnOneDeviceReachesTheOther() {
        let cloud = MemoryCloudStore(), clock = Clock()
        let (phone, phoneDefaults) = device(cloud, clock, id: "phone")
        let (mac, macDefaults) = device(cloud, clock, id: "mac")
        joined(phone, mac)

        phoneDefaults.set("green", forKey: AppTheme.accentKey)
        #expect(phone.reconcile(.merge).pushed == 1)
        #expect(mac.reconcile(.merge).applied == 1)
        #expect(macDefaults.string(forKey: AppTheme.accentKey) == "green")
        // Settled: another pass moves nothing either way.
        #expect(mac.reconcile(.merge) == CloudMerge.Outcome())
        #expect(phone.reconcile(.merge) == CloudMerge.Outcome())

        // And back the other way.
        macDefaults.set("pink", forKey: AppTheme.accentKey)
        #expect(mac.reconcile(.merge).pushed == 1)
        #expect(phone.reconcile(.merge).applied == 1)
        #expect(phoneDefaults.string(forKey: AppTheme.accentKey) == "pink")
    }

    @Test func valuesOnBothSidesAtTheFirstMeetingAreLeftAlone() {
        let cloud = MemoryCloudStore(), clock = Clock()
        let (phone, phoneDefaults) = device(cloud, clock, id: "phone")
        let (mac, macDefaults) = device(cloud, clock, id: "mac")

        // The Mac syncs first with its own choice; the phone has had another one for months.
        macDefaults.set("teal", forKey: AppTheme.accentKey)
        phoneDefaults.set("orange", forKey: AppTheme.accentKey)
        mac.reconcile(.merge)
        let first = phone.reconcile(.merge)
        #expect(first.applied == 0 && first.pushed == 0)
        #expect(phoneDefaults.string(forKey: AppTheme.accentKey) == "orange")
        #expect(macDefaults.string(forKey: AppTheme.accentKey) == "teal")

        // Whoever changes it next is followed.
        phoneDefaults.set("purple", forKey: AppTheme.accentKey)
        #expect(phone.reconcile(.merge).pushed == 1)
        #expect(mac.reconcile(.merge).applied == 1)
        #expect(macDefaults.string(forKey: AppTheme.accentKey) == "purple")
    }

    @Test func restoreTakesTheCloudAndBackUpTakesTheDevice() {
        let cloud = MemoryCloudStore(), clock = Clock()
        let (phone, phoneDefaults) = device(cloud, clock, id: "phone")
        let (mac, macDefaults) = device(cloud, clock, id: "mac")

        phoneDefaults.set("orange", forKey: AppTheme.accentKey)
        phoneDefaults.set(true, forKey: ChatStyle.wideReplies)
        phone.reconcile(.merge)
        macDefaults.set("teal", forKey: AppTheme.accentKey)
        mac.reconcile(.merge)                                   // joining: what the cloud held is left where it is

        #expect(macDefaults.string(forKey: AppTheme.accentKey) == "teal")
        #expect(macDefaults.object(forKey: ChatStyle.wideReplies) == nil)
        #expect(mac.reconcile(.restore).applied == 2)           // the accent and wide replies
        #expect(macDefaults.string(forKey: AppTheme.accentKey) == "orange")
        #expect(macDefaults.bool(forKey: ChatStyle.wideReplies))

        macDefaults.set("graphite", forKey: AppTheme.accentKey)
        mac.reconcile(.backUp)
        phone.reconcile(.merge)
        #expect(phoneDefaults.string(forKey: AppTheme.accentKey) == "graphite")
    }

    @Test func aNewDeviceStartsCleanAndFollowsFromThenOn() {
        let cloud = MemoryCloudStore(), clock = Clock()
        let (phone, phoneDefaults) = device(cloud, clock, id: "phone")
        let (mac, macDefaults) = device(cloud, clock, id: "mac")
        phoneDefaults.set("Sam", forKey: "user.name")
        phone.reconcile(.merge)

        // Get Started on a new device (or one just reset): nothing older comes down by itself.
        #expect(mac.reconcile(.merge) == CloudMerge.Outcome())
        #expect(macDefaults.string(forKey: "user.name") == nil)

        // A change made after it joined does.
        phoneDefaults.set(false, forKey: ChatStyle.showReasoning)
        phone.reconcile(.merge)
        #expect(mac.reconcile(.merge).applied == 1)
        #expect(macDefaults.object(forKey: ChatStyle.showReasoning) as? Bool == false)

        // And Restore brings the rest.
        #expect(mac.reconcile(.restore).applied == 1)
        #expect(macDefaults.string(forKey: "user.name") == "Sam")
    }

    // The name Home greets the person by, on every path it can take.

    @Test func theNameOnHomeIsBackedUpAndRestored() {
        let cloud = MemoryCloudStore(), clock = Clock()
        let (phone, phoneDefaults) = device(cloud, clock, id: "phone")
        let (mac, macDefaults) = device(cloud, clock, id: "mac")
        phoneDefaults.set("Sam", forKey: CloudMerge.nameKey)
        phone.reconcile(.backUp)
        #expect(mac.summary().name == "Sam", "the restore sheet cannot say whose backup it found")

        // A new device that chooses Restore, with no name of its own or with another one typed.
        mac.reconcile(.restore)
        #expect(macDefaults.string(forKey: CloudMerge.nameKey) == "Sam")
        let (pad, padDefaults) = device(cloud, clock, id: "pad")
        padDefaults.set("Samantha", forKey: CloudMerge.nameKey)
        pad.reconcile(.restore)
        #expect(padDefaults.string(forKey: CloudMerge.nameKey) == "Sam")

        // Back Up takes this device's side, the name included.
        pad.reconcile(.merge)
        padDefaults.set("Samantha", forKey: CloudMerge.nameKey)
        pad.reconcile(.backUp)
        mac.reconcile(.merge)
        #expect(macDefaults.string(forKey: CloudMerge.nameKey) == "Samantha")
    }

    @Test func aNameAlreadyOnOneDeviceReachesTheOnesThatJoinedBeforeIt() {
        let cloud = MemoryCloudStore(), clock = Clock()
        let (phone, phoneDefaults) = device(cloud, clock, id: "phone")
        let (mac, macDefaults) = device(cloud, clock, id: "mac")
        // The Mac has synced for a while and never had a name; the phone has had one for months
        // and only now gets a build that syncs.
        mac.reconcile(.merge)
        phoneDefaults.set("Sam", forKey: CloudMerge.nameKey)
        #expect(phone.reconcile(.merge).pushed == 1)
        #expect(mac.reconcile(.merge).applied == 1)
        #expect(macDefaults.string(forKey: CloudMerge.nameKey) == "Sam")

        // A later change of name travels too, and clearing it clears it everywhere.
        macDefaults.set("Sam W", forKey: CloudMerge.nameKey)
        mac.reconcile(.merge)
        phone.reconcile(.merge)
        #expect(phoneDefaults.string(forKey: CloudMerge.nameKey) == "Sam W")
        phoneDefaults.set("", forKey: CloudMerge.nameKey)
        phone.reconcile(.merge)
        mac.reconcile(.merge)
        #expect(macDefaults.string(forKey: CloudMerge.nameKey) == "")
        #expect(mac.summary().name == nil)
    }

    @Test func aResetDeviceJoinsAgainAsNew() {
        let cloud = MemoryCloudStore(), clock = Clock()
        let (phone, phoneDefaults) = device(cloud, clock, id: "phone")
        phoneDefaults.set("green", forKey: AppTheme.accentKey)
        phone.reconcile(.merge)

        // The reset wipes the device's defaults, the sync's own bookkeeping included.
        for key in phoneDefaults.dictionaryRepresentation().keys { phoneDefaults.removeObject(forKey: key) }
        let after = phone.reconcile(.merge)
        #expect(after == CloudMerge.Outcome())
        #expect(phoneDefaults.string(forKey: AppTheme.accentKey) == nil)
        // The cloud still has it, for Restore.
        #expect(phone.reconcile(.restore).applied == 1)
        #expect(phoneDefaults.string(forKey: AppTheme.accentKey) == "green")
    }

    @Test func thisDevicesOwnSettingsNeverLeaveIt() {
        let cloud = MemoryCloudStore(), clock = Clock()
        let (phone, phoneDefaults) = device(cloud, clock, id: "phone")
        for key in [TabLayout.storageKey, PushRegistrar.enabledKey, PushRegistrar.installIDKey, PushRegistrar.muteDesktopOriginKey,
                    AppLock.enabledKey, ApprovalConfirm.modeKey, ChatStyle.textSize, "launchTab", "activeConnectionID", "companionPromptShown",
                    ComposeAction.tapKey, ComposeAction.holdKey] {
            phoneDefaults.set("x", forKey: key)
            #expect(!CloudMerge.syncedSettings.contains(key))
        }
        phone.reconcile(.backUp)
        #expect(cloud.cloudKeys.allSatisfy { !$0.hasPrefix(CloudMerge.settingPrefix) })
    }

    @Test func botLooksMergePerBotAndARemovedOneStaysRemoved() {
        let cloud = MemoryCloudStore(), clock = Clock()
        let (phone, phoneDefaults) = device(cloud, clock, id: "phone")
        let (mac, macDefaults) = device(cloud, clock, id: "mac")
        func colors(_ d: UserDefaults) -> [String: String] { CloudMerge.map(d.string(forKey: BotColors.storageKey)) }

        phoneDefaults.set(CloudMerge.string(["alpha": "#111111", "beta": "#222222"]), forKey: BotColors.storageKey)
        phoneDefaults.set(CloudMerge.string(["alpha": "studio:blob:classic"]), forKey: BotAvatarStore.storageKey)
        phone.reconcile(.merge)
        mac.reconcile(.restore)
        #expect(colors(macDefaults) == ["alpha": "#111111", "beta": "#222222"])
        #expect(CloudMerge.map(macDefaults.string(forKey: BotAvatarStore.storageKey)) == ["alpha": "studio:blob:classic"])

        // Each device edits a different bot: both edits survive.
        phoneDefaults.set(CloudMerge.string(["alpha": "#AAAAAA", "beta": "#222222"]), forKey: BotColors.storageKey)
        macDefaults.set(CloudMerge.string(["alpha": "#111111", "beta": "#BBBBBB"]), forKey: BotColors.storageKey)
        phone.reconcile(.merge); mac.reconcile(.merge); phone.reconcile(.merge)
        #expect(colors(phoneDefaults) == ["alpha": "#AAAAAA", "beta": "#BBBBBB"])
        #expect(colors(macDefaults) == ["alpha": "#AAAAAA", "beta": "#BBBBBB"])

        // A colour removed on the Mac does not come back from the phone.
        macDefaults.set(CloudMerge.string(["alpha": "#AAAAAA"]), forKey: BotColors.storageKey)
        mac.reconcile(.merge); phone.reconcile(.merge); mac.reconcile(.merge)
        #expect(colors(phoneDefaults) == ["alpha": "#AAAAAA"])
        #expect(colors(macDefaults) == ["alpha": "#AAAAAA"])
    }

    @Test func theSummarySaysWhatIsThereAndWhoWroteLast() {
        let cloud = MemoryCloudStore(), clock = Clock()
        let (phone, phoneDefaults) = device(cloud, clock, id: "phone")
        let (mac, _) = device(cloud, clock, id: "mac")
        #expect(mac.summary().isEmpty)
        phoneDefaults.set("green", forKey: AppTheme.accentKey)
        phoneDefaults.set(CloudMerge.string(["alpha": "#111111"]), forKey: BotColors.storageKey)
        phone.reconcile(.merge)
        let s = mac.summary()
        #expect(s.settings == 1 && s.bots == 1 && s.device == "phone")
    }

    /// "Last backup" is the latest write from any device, this one included: it used to prefer
    /// another device's word, so a backup made here stayed invisible (stuck on the Mac's date).
    @Test func theLastBackupFollowsEveryWriteThisDevicesAndTheOthers() {
        let cloud = MemoryCloudStore(), clock = Clock()
        let (phone, phoneDefaults) = device(cloud, clock, id: "phone")
        let (mac, macDefaults) = device(cloud, clock, id: "mac")
        joined(phone, mac)
        // The Mac writes: both see the Mac as the last.
        macDefaults.set("pink", forKey: AppTheme.accentKey)
        mac.reconcile(.merge)
        let macWrote = clock.t
        var s = phone.summary()
        #expect(s.device == "mac" && !s.isOwnDevice && s.date == Date(timeIntervalSince1970: macWrote))
        // Then this phone backs up: its own write is the latest, and it says so.
        phone.reconcile(.merge)   // takes the Mac's value
        phone.reconcile(.backUp)
        phone.stamp()
        let phoneWrote = clock.t
        s = phone.summary()
        #expect(s.device == "phone" && s.isOwnDevice && s.date == Date(timeIntervalSince1970: phoneWrote), "the phone's own backup is the last one: \(String(describing: s.device))")
        // An external change arrives (the Mac wrote again): the Mac is the last once more.
        macDefaults.set("teal", forKey: AppTheme.accentKey)
        mac.reconcile(.merge)
        s = phone.summary()
        #expect(s.device == "mac" && !s.isOwnDevice && s.date == Date(timeIntervalSince1970: clock.t))
        _ = phoneDefaults
    }

    /// The daily backup: due when there was none, or the last was a day or more ago.
    @Test func theDailyBackupIsDueAfterADayOrWhenThereWasNone() {
        let now: Double = 2_000_000
        #expect(CloudSync.backupDue(lastBackupAt: nil, now: now))
        #expect(!CloudSync.backupDue(lastBackupAt: now - 3600, now: now))
        #expect(!CloudSync.backupDue(lastBackupAt: now - CloudSync.backupInterval + 1, now: now))
        #expect(CloudSync.backupDue(lastBackupAt: now - CloudSync.backupInterval, now: now))
        #expect(CloudSync.backupDue(lastBackupAt: now - 3 * 86_400, now: now))
    }

    @Test func aLongBotNameStillFitsACloudKey() {
        let name = String(repeating: "long-bot-name-", count: 8)
        #expect(CloudMerge.lookKey(name).utf8.count <= 64)
        #expect(CloudMerge.lookKey("alpha") == "look.alpha")
        // The hash is the same on every launch and every device.
        #expect(CloudMerge.hash(Data("abc".utf8)) == CloudMerge.hash(Data("abc".utf8)))
    }
}

/// The gateway list between two devices: one shared "cloud" file, a list and a defaults suite each.
@MainActor
struct CloudGatewayTests {
    final class FakeStore: GatewayStoring {
        var connections: [GatewayConnection] = []
        var secretsByID: [UUID: GatewaySecrets] = [:]
        /// The gateways whose remembered sign-in was forgotten, in order.
        var forgotten: [UUID] = []
        /// The device's remembered sign-ins, for a test that follows one into the vault.
        var vault: RememberedSignInVault?
        func connection(id: UUID) -> GatewayConnection? { connections.first { $0.id == id } }
        func secrets(for id: UUID) -> GatewaySecrets { secretsByID[id] ?? GatewaySecrets() }
        func upsert(_ connection: GatewayConnection, secrets: GatewaySecrets) throws {
            if let i = connections.firstIndex(where: { $0.id == connection.id }) { connections[i] = connection } else { connections.append(connection) }
            secretsByID[connection.id] = secrets
        }
        func remove(_ id: UUID) { connections.removeAll { $0.id == id }; secretsByID[id] = nil }
        func forgetRememberedSignIn(_ id: UUID) { forgotten.append(id); vault?.forget(id) }
    }

    final class Cloud { var file = CloudGatewayFile(); var clock: Double = 1_000
        var storage: CloudGateways.Storage { .init(load: { self.file }, save: { self.file = $0 }) }
        func tick() -> Double { clock += 1; return clock }
    }

    final class Device {
        let store = FakeStore()
        let defaults: UserDefaults
        let cloud: Cloud
        init(_ cloud: Cloud) {
            let suite = "gateway-test-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            self.cloud = cloud
        }
        @MainActor @discardableResult func sync(importNew: Bool = true) -> CloudGateways.Outcome {
            CloudGateways.reconcile(store: store, importNew: importNew, storage: cloud.storage, defaults: defaults, now: cloud.tick())
        }
    }

    private func gateway(_ name: String, _ url: String, token: String = "t") throws -> (GatewayConnection, GatewaySecrets) {
        (GatewayConnection(name: name, gateway: try GatewayURL.normalize(url, pathPrefix: nil), authMode: .sessionToken), GatewaySecrets(sessionToken: token))
    }

    @Test func aRenameAndANewTokenTravelOnceAndDoNotBounce() throws {
        let cloud = Cloud(), phone = Device(cloud), mac = Device(cloud)
        let (g, s) = try gateway("Home", "https://hermes.example.com")
        try phone.store.upsert(g, secrets: s)
        phone.sync()
        #expect(mac.sync().added.count == 1)
        #expect(mac.store.connections.first?.name == "Home")

        // Renamed and given a new token on the phone.
        var renamed = g; renamed.name = "House"
        try phone.store.upsert(renamed, secrets: GatewaySecrets(sessionToken: "t2"))
        #expect(phone.sync().pushed)
        let down = mac.sync()
        #expect(down.changed == [g.id] && !down.pushed)
        #expect(mac.store.connections.first?.name == "House")
        #expect(mac.store.secrets(for: g.id).sessionToken == "t2")

        // Settled: nothing goes back up from either side, pass after pass.
        for _ in 0..<3 {
            #expect(phone.sync() == CloudGateways.Outcome())
            #expect(mac.sync() == CloudGateways.Outcome())
        }
        #expect(cloud.file.gateways.count == 1 && cloud.file.gateways[0].connection.name == "House")
    }

    /// A sign-in remembered on a device was typed for the gateway's address and method: either
    /// one changed on another device forgets it there, rather than still offer it behind Face ID
    /// and drop it only after the prompt. A rename keeps it.
    @Test func aNewAddressOrMethodFromAnotherDeviceForgetsTheRememberedSignIn() throws {
        let cloud = Cloud(), phone = Device(cloud), mac = Device(cloud)
        var g = GatewayConnection(name: "Home", gateway: try GatewayURL.normalize("https://hermes.example.com", pathPrefix: nil), authMode: .password, authProvider: "basic")
        try phone.store.upsert(g, secrets: GatewaySecrets(provider: "basic"))
        phone.sync()
        #expect(mac.sync().added.count == 1)

        g.name = "House"
        try phone.store.upsert(g, secrets: GatewaySecrets(provider: "basic"))
        phone.sync()
        #expect(mac.sync().changed == [g.id])
        #expect(mac.store.forgotten.isEmpty, "a rename forgot the sign-in")

        g.gateway = try GatewayURL.normalize("https://moved.example.com", pathPrefix: nil)
        try phone.store.upsert(g, secrets: GatewaySecrets(provider: "basic"))
        phone.sync()
        #expect(mac.sync().changed == [g.id])
        #expect(mac.store.connections.first?.gateway == g.gateway)
        #expect(mac.store.forgotten == [g.id])

        g.authMode = .oauth
        try phone.store.upsert(g, secrets: GatewaySecrets())
        phone.sync()
        #expect(mac.sync().changed == [g.id])
        #expect(mac.store.forgotten == [g.id, g.id])
        // The device that made the change forgets its own in the form, not here.
        #expect(phone.store.forgotten.isEmpty)
    }

    /// A merge while the device is locked (a launch in the background, the backup task, an
    /// iCloud change) cannot delete the remembered sign-in, which is kept only while it is
    /// unlocked. From that moment it is never offered, not after a relaunch either, and it is
    /// deleted once the device is unlocked.
    @Test func aSignInForgottenWhileTheDeviceIsLockedIsDeletedOnceItIsUnlocked() throws {
        let cloud = Cloud(), phone = Device(cloud), mac = Device(cloud)
        let keychain = MemoryRememberedSignInBackend()
        let vault = RememberedSignInVault(backend: keychain, defaults: mac.defaults)
        mac.store.vault = vault
        var g = GatewayConnection(name: "Home", gateway: try GatewayURL.normalize("https://hermes.example.com", pathPrefix: nil), authMode: .password, authProvider: "basic")
        try phone.store.upsert(g, secrets: GatewaySecrets(provider: "basic"))
        phone.sync()
        #expect(mac.sync().added.count == 1)
        try vault.remember(RememberedSignIn(provider: "basic", username: "sam", password: "pw", gateway: g.gateway), for: g.id)
        let item = RememberedSignInVault.account(g.id)

        // Moved on the phone, and merged on the other device while it is locked.
        g.gateway = try GatewayURL.normalize("https://moved.example.com", pathPrefix: nil)
        try phone.store.upsert(g, secrets: GatewaySecrets(provider: "basic"))
        phone.sync()
        keychain.unreadable = true; keychain.undeletable = true
        #expect(mac.sync().changed == [g.id])
        #expect(mac.store.forgotten == [g.id])
        #expect(keychain.items[item] != nil, "deleted while locked")
        #expect(!vault.contains(g.id), "offered while it waits to be deleted")
        #expect(try vault.signIn(for: g.id, context: nil) == nil, "used while it waits to be deleted")

        // The next launch, still locked, and a list read before it could be deleted: not offered.
        let relaunched = RememberedSignInVault(backend: keychain, defaults: mac.defaults)
        #expect(relaunched.pendingForgets == [g.id] && !relaunched.contains(g.id))
        keychain.unreadable = false
        relaunched.reload()
        #expect(relaunched.isKnown && !relaunched.contains(g.id))

        // Unlocked: deleted, and nothing is left waiting.
        keychain.undeletable = false
        relaunched.reload()
        #expect(keychain.items[item] == nil)
        #expect(relaunched.pendingForgets.isEmpty && !relaunched.contains(g.id))
        #expect(mac.defaults.object(forKey: RememberedSignInVault.pendingForgetsKey) == nil)
    }

    @Test func aDeviceWithNoGatewayTakesNoneUntilItRestores() throws {
        let cloud = Cloud(), phone = Device(cloud), mac = Device(cloud)
        let (g, s) = try gateway("Home", "https://hermes.example.com")
        try phone.store.upsert(g, secrets: s)
        phone.sync()
        #expect(mac.sync(importNew: false).added.isEmpty && mac.store.connections.isEmpty)
        #expect(mac.sync(importNew: true).added.count == 1)
    }

    @Test func theSameAddressAddedAgainAfterAResetIsNotASecondGateway() throws {
        let cloud = Cloud(), phone = Device(cloud), mac = Device(cloud)
        let (g, s) = try gateway("Home", "https://hermes.example.com")
        try phone.store.upsert(g, secrets: s)
        phone.sync(); mac.sync()

        // The phone is reset (its list and its memory gone) and the same gateway added again: a new id.
        let reset = Device(cloud)
        let (again, s2) = try gateway("Home", "https://hermes.example.com")
        #expect(again.id != g.id)
        try reset.store.upsert(again, secrets: s2)
        reset.sync(importNew: false)
        #expect(cloud.file.gateways.count == 1)
        mac.sync()
        #expect(mac.store.connections.count == 1)
    }

    @Test func aLoopbackAddressStaysOnItsDevice() throws {
        let cloud = Cloud(), mac = Device(cloud), phone = Device(cloud)
        let (local, s) = try gateway("This Mac", "http://127.0.0.1:9119")
        let (real, s2) = try gateway("Home", "https://hermes.example.com")
        try mac.store.upsert(local, secrets: s)
        try mac.store.upsert(real, secrets: s2)
        mac.sync()
        #expect(cloud.file.gateways.map(\.connection.name) == ["Home"])
        #expect(phone.sync().added.map(\.connection.name) == ["Home"])
    }

    @Test func aGatewayRemovedOnOneDeviceDoesNotComeBackFromAnother() throws {
        let cloud = Cloud(), phone = Device(cloud), mac = Device(cloud)
        let (g, s) = try gateway("Home", "https://hermes.example.com")
        try phone.store.upsert(g, secrets: s)
        phone.sync(); mac.sync()
        phone.store.remove(g.id)
        phone.sync()
        #expect(cloud.file.gateways.isEmpty && cloud.file.deleted[g.id.uuidString] != nil)
        // The Mac still has its own copy and does not put it back.
        mac.sync()
        #expect(cloud.file.gateways.isEmpty)
        #expect(phone.sync().added.isEmpty)
    }

    // MARK: Gateways that arrive after the restore (#181)

    @Test func aDeviceOwedGatewaysTakesThemWhenTheirItemArrives() throws {
        // Restore ran before the Keychain item reached this device: nothing came, the device has none.
        let cloud = Cloud(), phone = Device(cloud), mac = Device(cloud)
        #expect(mac.sync(importNew: CloudSync.importsGateways(hasConnections: false, awaiting: false)).added.isEmpty)
        // The phone's copy lands later; a pass that is still owed the gateways takes it.
        let (g, s) = try gateway("Home", "https://hermes.example.com")
        try phone.store.upsert(g, secrets: s)
        phone.sync()
        #expect(mac.sync(importNew: CloudSync.importsGateways(hasConnections: false, awaiting: true)).added.count == 1)
        #expect(mac.store.connections.count == 1)
        // Not owed, with none: still Restore's job.
        #expect(!CloudSync.importsGateways(hasConnections: false, awaiting: false))
        #expect(CloudSync.importsGateways(hasConnections: true, awaiting: false))
    }

    @Test func onlyAGatewayWithoutItsSignInIsPending() throws {
        let store = FakeStore()
        let (withToken, s) = try gateway("Home", "https://hermes.example.com")
        var browser = GatewayConnection(name: "Work", gateway: try GatewayURL.normalize("https://work.example.com", pathPrefix: nil), authMode: .oauth)
        browser.authProvider = "github"
        try store.upsert(withToken, secrets: s)
        try store.upsert(browser, secrets: GatewaySecrets())
        let added = [CloudGateway(connection: withToken, sessionToken: "t", access: s.access, updatedAt: 1),
                     CloudGateway(connection: browser, sessionToken: nil, access: CloudflareAccess(), updatedAt: 1)]
        #expect(CloudSync.pendingSignIns(added, in: store).map(\.name) == ["Work"])
        // A token that travelled empty needs a sign-in too.
        let empty = [CloudGateway(connection: withToken, sessionToken: "", access: s.access, updatedAt: 1)]
        #expect(CloudSync.pendingSignIns(empty, in: store).map(\.name) == ["Home"])
    }

    @Test func theRestoreSheetSaysWhenItIsStillLookingForGateways() {
        #expect(CloudRestoreSheet.gatewayLine(count: 0, waiting: true) == "Looking for your gateways…")
        #expect(CloudRestoreSheet.gatewayLine(count: 0, waiting: false) == "No saved gateways yet")
        #expect(CloudRestoreSheet.gatewayLine(count: 2, waiting: false) == "2 gateways")
        var r = CloudSync.RestoreOutcome(settings: 3, gatewaysAwaited: true)
        #expect(CloudRestoreSheet.words(for: r).contains("have not reached"))
        r.gatewaysAwaited = false
        #expect(!CloudRestoreSheet.words(for: r).contains("have not reached"))
    }
}
