import Foundation
import LocalAuthentication
import Security
import Testing
@testable import Vory
@testable import VoryCore

/// "Remember sign-in on this device" (#256): how the item is stored, when it is used, and that it
/// never travels.
@MainActor
struct RememberedSignInTests {
    /// Face ID that answers as told and counts the times it was asked.
    final class FakeAuthenticator: DeviceOwnerAuthenticating {
        var answer = true
        var canAuthenticate = true
        var methodName = "Face ID"
        var delay: Duration = .zero
        private(set) var reasons: [String] = []
        func authenticate(reason: String) async -> LAContext? {
            reasons.append(reason)
            if delay > .zero { try? await Task.sleep(for: delay) }
            return answer ? LAContext() : nil
        }
    }

    /// What a closure saw, kept on the main actor so the closures may record into it.
    @MainActor final class Recorder<T> { var items: [T] = [] }

    /// The address the sign-in was typed for, and the one the test gateways have.
    private static let home = try! GatewayURL.normalize("https://gateway.example.com")
    private let secret = RememberedSignIn(provider: "basic", username: "sam-at-home", password: "correct-horse-battery", gateway: Self.home)

    private func gateway(_ mode: AuthMode = .password, name: String = "Home", address: GatewayURL = Self.home) throws -> GatewayConnection {
        GatewayConnection(name: name, gateway: address, authMode: mode, authProvider: "basic")
    }

    /// A clock the test moves by hand.
    @MainActor final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    private func coordinator(_ backend: MemoryRememberedSignInBackend = MemoryRememberedSignInBackend(), auth: FakeAuthenticator = FakeAuthenticator()) -> RememberedSignInCoordinator {
        RememberedSignInCoordinator(vault: RememberedSignInVault(backend: backend), authenticator: auth)
    }

    // MARK: Storage policy

    @Test func theItemIsThisDeviceOnlyNeverSyncedAndBehindFaceIDOrThePasscode() throws {
        let q = KeychainRememberedSignInBackend.query(account: "signin.x")
        #expect(q[kSecAttrSynchronizable as String] as? Bool == false, "iCloud Keychain must not carry it")
        #expect(q[kSecClass as String] as? String == kSecClassGenericPassword as String)
        // Its own service: nothing that reads the gateways' items (the migration, the iCloud copy)
        // ever reads it, and so never makes Face ID ask at launch.
        let service = try #require(q[kSecAttrService as String] as? String)
        #expect(service == Keychain.baseBundleID + ".remembered")
        #expect(service != Keychain.service && service != Keychain.cloudService)
        #if os(macOS)
        #expect(q[kSecUseDataProtectionKeychain as String] as? Bool == true, "the legacy Mac keychain ignores access control")
        #endif

        #expect(KeychainRememberedSignInBackend.protection as String == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
        #expect(KeychainRememberedSignInBackend.accessFlags == .userPresence)

        let add = try KeychainRememberedSignInBackend.addAttributes(Data("x".utf8), account: "signin.x")
        #expect(add[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(add[kSecValueData as String] as? Data == Data("x".utf8))
        // The protection class rides in the access control; set beside it the add is refused.
        #expect(add[kSecAttrAccessible as String] == nil)
        let control = try #require(add[kSecAttrAccessControl as String])
        #expect(CFGetTypeID(control as AnyObject) == SecAccessControlGetTypeID())
        // The system's own description of it: "akpu" is when-passcode-set, this device only, and
        // the operation needs the device owner (Face ID, Touch ID or the passcode).
        let described = String(describing: control)
        #expect(described.contains("akpu"), "\(described)")
        #expect(described.contains("DeviceOwnerAuthentication"), "\(described)")
    }

    @Test func itIsNeverPrinted() {
        var dumped = ""
        dump(secret, to: &dumped)
        for text in [String(describing: secret), String(reflecting: secret), "\(secret)", dumped] {
            #expect(!text.contains(secret.password), "the password shows in \(text)")
            #expect(!text.contains(secret.username), "the username shows in \(text)")
        }
    }

    @Test func theVaultKnowsWhichGatewaysHaveOneWithoutAPrompt() throws {
        let backend = MemoryRememberedSignInBackend()
        let id = UUID(), other = UUID()
        let vault = RememberedSignInVault(backend: backend)
        try vault.remember(secret, for: id)
        #expect(vault.contains(id) && !vault.contains(other))
        // A new vault (the next launch) finds it from the accounts alone.
        let reopened = RememberedSignInVault(backend: backend)
        #expect(reopened.ids == [id])
        // Opened with the evaluated check's context, which is what spares a second prompt.
        #expect(try reopened.signIn(for: id, context: LAContext()) == secret)
        #expect(backend.readsWithContext == 1)
        reopened.forget(id)
        #expect(!reopened.contains(id) && backend.items.isEmpty)
        // Gone underneath (the passcode was turned off): nothing, and no longer listed.
        try vault.remember(secret, for: other)
        backend.delete(account: RememberedSignInVault.account(other))
        #expect(try vault.signIn(for: other, context: nil) == nil)
        #expect(!vault.contains(other))
    }

    /// A launch while the phone is locked (a watch message, a notification, the backup task)
    /// cannot read the list: it is not known, and it is read again once it can be.
    @Test func aListThatCannotBeReadIsUnknownUntilItCanBe() throws {
        let backend = MemoryRememberedSignInBackend()
        let id = UUID()
        try RememberedSignInVault(backend: backend).remember(secret, for: id)

        backend.unreadable = true
        let vault = RememberedSignInVault(backend: backend)
        #expect(!vault.isKnown && vault.ids.isEmpty)
        vault.reload()
        #expect(!vault.isKnown, "a read that fails again is still no answer")

        // Unlocked: read again (on unlock, coming to the front, or before it is needed).
        backend.unreadable = false
        vault.reload()
        #expect(vault.isKnown && vault.ids == [id])

        // Locked again later: what was known stays known.
        backend.unreadable = true
        vault.reload()
        #expect(vault.isKnown && vault.contains(id))
        // Read with nothing there: known, and empty.
        backend.unreadable = false
        backend.delete(account: RememberedSignInVault.account(id))
        vault.reload()
        #expect(vault.isKnown && vault.ids.isEmpty)
    }

    /// The Keychain's answer to the listing: none is an answer, a locked device is not.
    @Test func whatTheKeychainListingMeans() {
        typealias K = KeychainRememberedSignInBackend
        #expect(K.accounts(status: errSecItemNotFound, found: nil) == [])
        #expect(K.accounts(status: errSecInteractionNotAllowed, found: nil) == nil, "locked is not none")
        #expect(K.accounts(status: errSecMissingEntitlement, found: nil) == nil)
        let found = [[kSecAttrAccount as String: "signin.a"], [kSecAttrAccount as String: "signin.b"]] as AnyObject
        #expect(K.accounts(status: errSecSuccess, found: found) == ["signin.a", "signin.b"])
        #expect(K.accounts(status: errSecSuccess, found: nil) == nil)
        #if os(iOS)
        // The device Keychain itself (the Mac's unsigned test build has none): an answer.
        #expect(K().accounts() != nil)
        #endif
    }

    @Test func theCoordinatorReadsAListItCouldNotReadAtLaunch() async throws {
        let backend = MemoryRememberedSignInBackend(), auth = FakeAuthenticator()
        let c = try gateway()
        try RememberedSignInVault(backend: backend).remember(secret, for: c.id)
        backend.unreadable = true
        let co = coordinator(backend, auth: auth)
        #expect(co.decision(for: c, asked: false) == .askPerson(.nothingRemembered))
        co.signIn = { _, _, _ in GatewaySecrets(accessToken: "a") }

        // Still locked: nothing, and nothing asked.
        #expect(await co.signInAgain(c, access: CloudflareAccess()) == nil)
        #expect(auth.reasons.isEmpty)
        // Unlocked and in front: the list is read before deciding, and used.
        backend.unreadable = false
        #expect(await co.signInAgain(c, access: CloudflareAccess())?.accessToken == "a")
        #expect(auth.reasons.count == 1)
    }

    // MARK: The gateway's form

    @Test func whatSavingTheFormDoes() {
        typealias C = RememberedSignInCoordinator
        func change(_ mode: AuthMode = .password, on: Bool, wasOn: Bool, typed: Bool = true, moved: Bool = false) -> C.FormChange {
            C.formChange(authMode: mode, switchOn: on, wasOn: wasOn, typed: typed, moved: moved)
        }
        // Turned on, or left on, with the sign-in typed: kept, for the address saved.
        #expect(change(on: true, wasOn: false) == .remember)
        #expect(change(on: true, wasOn: true) == .remember)
        #expect(change(on: true, wasOn: true, moved: true) == .remember)
        // Left on with nothing typed: what was remembered stays.
        #expect(change(on: true, wasOn: true, typed: false) == .keep)
        // Turned off here: forgotten.
        #expect(change(on: false, wasOn: true) == .forget)
        #expect(change(on: false, wasOn: true, typed: false) == .forget)
        // Opened off and saved off: nothing forgotten. The switch also opens off while the list
        // could not be read, and a Save then deleted a sign-in the person had asked to keep.
        #expect(change(on: false, wasOn: false) == .keep)
        #expect(change(on: false, wasOn: false, typed: false) == .keep)
        // A new address: what was typed for the old one goes.
        #expect(change(on: false, wasOn: false, moved: true) == .forget)
        #expect(change(on: true, wasOn: true, typed: false, moved: true) == .forget)
        // Another sign-in method: nothing typed to sign in again with.
        #expect(change(.oauth, on: true, wasOn: true) == .forget)
        #expect(change(.sessionToken, on: false, wasOn: false) == .forget)
    }

    // MARK: When it is used

    @Test func theDecision() {
        typealias C = RememberedSignInCoordinator
        func decide(_ mode: AuthMode = .password, remembered: Bool = true, passcode: Bool = true, now: Bool = true, declined: Bool = false, recently: Bool = false, asked: Bool = false) -> C.Decision {
            C.decide(authMode: mode, remembered: remembered, canAuthenticate: passcode, canPromptNow: now, declined: declined, usedRecently: recently, asked: asked)
        }
        #expect(decide() == .useRemembered)
        // A browser sign-in has nothing typed to sign in again with; neither has a session token.
        #expect(decide(.oauth) == .askPerson(.notPasswordSignIn))
        #expect(decide(.sessionToken) == .askPerson(.notPasswordSignIn))
        #expect(decide(remembered: false) == .askPerson(.nothingRemembered))
        #expect(decide(passcode: false) == .askPerson(.noPasscode))
        // In the background or behind the app's lock: later, not never.
        #expect(decide(now: false) == .askPerson(.notNow))
        // Turned down once: not asked again by itself…
        #expect(decide(declined: true) == .askPerson(.declined))
        // …but the Sign In sheet's button asks, whenever it is tapped.
        #expect(decide(now: false, declined: true, asked: true) == .useRemembered)
        #expect(decide(.oauth, asked: true) == .askPerson(.notPasswordSignIn))
        #expect(decide(remembered: false, asked: true) == .askPerson(.nothingRemembered))
        // Signed in by it a moment ago and refused again already: not by itself, but the
        // button still works.
        #expect(decide(recently: true) == .askPerson(.tooSoon))
        #expect(decide(recently: true, asked: true) == .useRemembered)
        #expect(decide(now: false, recently: true) == .askPerson(.notNow))
    }

    @Test func anExpiredSessionSignsInAgainAfterFaceID() async throws {
        let backend = MemoryRememberedSignInBackend(), auth = FakeAuthenticator()
        let c = try gateway(), co = coordinator(backend, auth: auth)
        try co.vault.remember(secret, for: c.id)
        let used = Recorder<RememberedSignIn>()
        co.signIn = { _, r, _ in used.items.append(r); return GatewaySecrets(accessToken: "new-access", refreshToken: "new-refresh", provider: "basic") }
        let access = CloudflareAccess(clientId: "id", clientSecret: "secret")

        let renewed = try #require(await co.signInAgain(c, access: access))
        #expect(renewed.accessToken == "new-access" && renewed.refreshToken == "new-refresh")
        #expect(renewed.access == access, "the Access headers stay with the gateway")
        #expect(used.items == [secret])
        #expect(auth.reasons == ["Sign in to Home"])
        #expect(backend.readsWithContext == 1, "the Keychain is opened with the check's context")
    }

    @Test func aCancelFallsBackToThePromptAndIsNotAskedAgainByItself() async throws {
        let auth = FakeAuthenticator(); auth.answer = false
        let c = try gateway(), co = coordinator(auth: auth)
        let clock = Clock()
        co.now = { clock.now }
        try co.vault.remember(secret, for: c.id)
        let signIns = Recorder<Int>()
        co.signIn = { _, _, _ in signIns.items.append(1); return GatewaySecrets(accessToken: "a") }

        #expect(await co.signInAgain(c, access: CloudflareAccess()) == nil)
        #expect(await co.signInAgain(c, access: CloudflareAccess()) == nil)
        #expect(auth.reasons.count == 1, "asked again after a cancel")
        #expect(signIns.items.isEmpty)
        #expect(co.vault.contains(c.id), "a cancel keeps the remembered sign-in")

        // The sheet's button asks again, and says what happened.
        await #expect(throws: RememberedSignInError.cancelled) { try await co.signInWithRemembered(c, access: CloudflareAccess()) }
        auth.answer = true
        #expect(try await co.signInWithRemembered(c, access: CloudflareAccess()).accessToken == "a")
        // Signed in: no longer declined, so asked by itself again next time (once the cooldown
        // after any sign-in it made has passed).
        #expect(!co.declined.contains(c.id))
        clock.now += RememberedSignInCoordinator.cooldown
        #expect(co.decision(for: c, asked: false) == .useRemembered)
    }

    /// A sign-in that goes through but does not keep the gateway working (a proxy that refuses
    /// the socket) must not ask for Face ID and send the password on every return to the app.
    @Test func itSignsInByItselfAtMostOnceInTenMinutes() async throws {
        let auth = FakeAuthenticator()
        let c = try gateway(), co = coordinator(auth: auth)
        let clock = Clock()
        co.now = { clock.now }
        try co.vault.remember(secret, for: c.id)
        let signIns = Recorder<Int>()
        co.signIn = { _, _, _ in signIns.items.append(1); return GatewaySecrets(accessToken: "a") }

        #expect(await co.signInAgain(c, access: CloudflareAccess())?.accessToken == "a")
        // Refused again a moment later: not by itself…
        clock.now += 60
        #expect(await co.signInAgain(c, access: CloudflareAccess()) == nil)
        #expect(co.decision(for: c, asked: false) == .askPerson(.tooSoon))
        clock.now += RememberedSignInCoordinator.cooldown - 61
        #expect(await co.signInAgain(c, access: CloudflareAccess()) == nil)
        #expect(auth.reasons.count == 1 && signIns.items.count == 1)
        #expect(co.vault.contains(c.id), "waiting is not forgetting")
        // …but the Sign In sheet's button, whenever it is tapped (which starts the wait again).
        #expect(try await co.signInWithRemembered(c, access: CloudflareAccess()).accessToken == "a")
        #expect(co.decision(for: c, asked: false) == .askPerson(.tooSoon))
        // Ten minutes on: by itself again.
        clock.now += RememberedSignInCoordinator.cooldown
        #expect(await co.signInAgain(c, access: CloudflareAccess())?.accessToken == "a")
        #expect(auth.reasons.count == 3 && signIns.items.count == 3)
        // Signed in by hand in the form: a fresh start, no wait.
        co.didSignIn(c.id)
        #expect(co.decision(for: c, asked: false) == .useRemembered)
        // Per gateway: another one is not held up by this one's wait.
        let other = try gateway(name: "Office")
        try co.vault.remember(secret, for: other.id)
        #expect(await co.signInAgain(c, access: CloudflareAccess()) != nil)
        #expect(co.decision(for: other, asked: false) == .useRemembered)
    }

    /// The password goes only to the address it was typed for: a gateway moved since (here, or
    /// on another device through iCloud) does not take it along.
    @Test func aSignInRememberedForAnotherAddressIsNeverSent() async throws {
        let auth = FakeAuthenticator()
        let moved = try gateway(address: try GatewayURL.normalize("https://elsewhere.example.net"))
        let co = coordinator(auth: auth)
        try co.vault.remember(secret, for: moved.id)
        co.signIn = { _, _, _ in Issue.record("the password was sent to another address"); return GatewaySecrets() }

        #expect(await co.signInAgain(moved, access: CloudflareAccess()) == nil)
        #expect(!co.vault.contains(moved.id), "of no use at the new address, so forgotten")

        // From the Sign In sheet: said in words.
        try co.vault.remember(secret, for: moved.id)
        await #expect(throws: RememberedSignInError.moved) { try await co.signInWithRemembered(moved, access: CloudflareAccess()) }
        #expect(!co.vault.contains(moved.id))

        // One kept before the address was (no address at all): never sent either.
        let backend = MemoryRememberedSignInBackend()
        let c = try gateway(), old = coordinator(backend, auth: auth)
        old.signIn = co.signIn
        let legacy = Data(#"{"provider":"basic","username":"sam-at-home","password":"correct-horse-battery"}"#.utf8)
        #expect(try JSONDecoder().decode(RememberedSignIn.self, from: legacy).gateway == nil)
        try backend.write(legacy, account: RememberedSignInVault.account(c.id))
        old.vault.reload()
        await #expect(throws: RememberedSignInError.moved) { try await old.signInWithRemembered(c, access: CloudflareAccess()) }
        #expect(!old.vault.contains(c.id))
    }

    @Test func aPasswordTheGatewayTurnsDownIsForgotten() async throws {
        let c = try gateway(), co = coordinator()
        try co.vault.remember(secret, for: c.id)
        co.signIn = { _, _, _ in throw HermesAPIError.unauthorized("Invalid credentials") }
        #expect(await co.signInAgain(c, access: CloudflareAccess()) == nil)
        #expect(!co.vault.contains(c.id), "a password the gateway refuses would only ask for Face ID again for nothing")
    }

    @Test func aNetworkFailureKeepsItForNextTime() async throws {
        let c = try gateway(), co = coordinator()
        try co.vault.remember(secret, for: c.id)
        co.signIn = { _, _, _ in throw HermesAPIError.transport("offline") }
        #expect(await co.signInAgain(c, access: CloudflareAccess()) == nil)
        #expect(co.vault.contains(c.id))
        #expect(co.decision(for: c, asked: false) == .askPerson(.declined))
    }

    @Test func nothingIsAskedInTheBackgroundOrForABrowserSignIn() async throws {
        let auth = FakeAuthenticator()
        let co = coordinator(auth: auth)
        let password = try gateway(), browser = try gateway(.oauth, name: "Office")
        try co.vault.remember(secret, for: password.id)
        try co.vault.remember(secret, for: browser.id)
        co.signIn = { _, _, _ in Issue.record("signed in when it should not have"); return GatewaySecrets() }

        co.canPromptNow = { false }
        #expect(await co.signInAgain(password, access: CloudflareAccess()) == nil)
        co.canPromptNow = { true }
        #expect(await co.signInAgain(browser, access: CloudflareAccess()) == nil)
        #expect(auth.reasons.isEmpty)
        // Not now is not a no: in front again, it is used.
        #expect(co.decision(for: password, asked: false) == .useRemembered)
    }

    @Test func aBurstOfRefusedCallsSharesOnePrompt() async throws {
        let auth = FakeAuthenticator(); auth.delay = .milliseconds(200)
        let c = try gateway(), co = coordinator(auth: auth)
        try co.vault.remember(secret, for: c.id)
        co.signIn = { _, _, _ in GatewaySecrets(accessToken: "a") }
        async let one = co.signInAgain(c, access: CloudflareAccess())
        async let two = co.signInAgain(c, access: CloudflareAccess())
        let (a, b) = await (one, two)
        #expect(a?.accessToken == "a" && b?.accessToken == "a")
        #expect(auth.reasons.count == 1)
    }

    // MARK: The runtime's refresh path

    @Test func theRuntimeSignsInAgainWhenTheRefreshIsTurnedDown() async throws {
        let store = ConnectionStore()
        store.remembered = RememberedSignInVault(backend: MemoryRememberedSignInBackend())
        let c = GatewayConnection(name: "test remembered sign-in", gateway: try GatewayURL.normalize("http://127.0.0.1:1"), authMode: .password)
        defer { store.delete(id: c.id) }
        // Nothing saved for it, so no refresh token: the renewal is turned down at once, without
        // a request.
        let rt = GatewayRuntime(connection: c, store: store)

        // Without the hook: today's "Sign in again".
        await #expect(throws: HermesAPIError.self) { try await rt.refreshSession() }

        let asked = Recorder<String>()
        rt.signInAgain = { conn, _ in asked.items.append(conn.name); return nil }
        await #expect(throws: HermesAPIError.self) { try await rt.refreshSession() }

        rt.signInAgain = { _, _ in GatewaySecrets(accessToken: "fresh", refreshToken: "r2", provider: "basic", access: CloudflareAccess(clientId: "other", clientSecret: "other")) }
        try await rt.refreshSession()
        #expect(rt.secrets.accessToken == "fresh" && rt.secrets.refreshToken == "r2")
        #expect(rt.secrets.access == CloudflareAccess(), "the gateway's own Access headers are kept")
        #expect(asked.items == ["test remembered sign-in"])
        #if os(iOS)
        // Through the real Keychain, which an unsigned Mac test build does not have.
        #expect(store.secrets(for: c.id).accessToken == "fresh", "saved for the next launch")
        #endif
    }

    // MARK: Never travels, and goes with the gateway

    @Test func removingTheGatewayForgetsIt() throws {
        let store = ConnectionStore()
        store.remembered = RememberedSignInVault(backend: MemoryRememberedSignInBackend())
        let id = UUID()
        try store.remembered.remember(secret, for: id)
        store.delete(id: id)
        #expect(!store.remembered.contains(id))
    }

    /// What the iCloud copy and the watch's context are made from has no field a remembered
    /// sign-in could slip into: a new one fails here first.
    @Test func theSecretsThatTravelHaveNoPlaceForIt() throws {
        let full = GatewaySecrets(sessionToken: "s", accessToken: "a", refreshToken: "r", expiresAt: 1, provider: "p", userId: "u",
                                  access: CloudflareAccess(clientId: "i", clientSecret: "c"))
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
        #expect(Set(object.keys) == ["sessionToken", "accessToken", "refreshToken", "expiresAt", "provider", "userId", "access"])
    }

    #if os(iOS)
    // These two go through the real Keychain, which an unsigned Mac test build does not have.

    @Test func theICloudCopyCarriesNoRememberedSignIn() throws {
        let store = ConnectionStore()
        store.remembered = RememberedSignInVault(backend: MemoryRememberedSignInBackend())
        let c = GatewayConnection(name: "test cloud copy", gateway: try GatewayURL.normalize("https://gateway.example.com"), authMode: .password)
        try store.upsert(c, secrets: GatewaySecrets(accessToken: "a", refreshToken: "r", provider: "basic"))
        defer { store.delete(id: c.id) }
        try store.remembered.remember(secret, for: c.id)

        var file = CloudGatewayFile()
        let suite = "remembered-cloud-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        CloudGateways.reconcile(store: store, importNew: false, storage: .init(load: { file }, save: { file = $0 }), defaults: defaults)
        #expect(file.gateways.contains { $0.connection.id == c.id }, "the gateway itself goes up")
        let sent = String(decoding: try JSONEncoder().encode(file), as: UTF8.self)
        #expect(!sent.contains(secret.password) && !sent.contains(secret.username))
    }

    @Test func theWatchGetsNoRememberedSignIn() throws {
        let store = ConnectionStore()
        store.remembered = RememberedSignInVault(backend: MemoryRememberedSignInBackend())
        let c = GatewayConnection(name: "test watch copy", gateway: try GatewayURL.normalize("http://127.0.0.1:1"), authMode: .password)
        try store.upsert(c, secrets: GatewaySecrets(accessToken: "a", refreshToken: "r", provider: "basic"))
        defer { store.delete(id: c.id) }
        try store.remembered.remember(secret, for: c.id)
        let sent = String(decoding: try JSONEncoder().encode(WatchSync.contextSecrets(store)), as: UTF8.self)
        #expect(sent.contains("\"a\""), "the watch still gets what signs a call")
        #expect(!sent.contains(secret.password) && !sent.contains(secret.username))
    }
    #endif
}
