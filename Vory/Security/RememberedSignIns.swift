import Foundation
import LocalAuthentication
import VoryCore

/// Face ID, Touch ID or the passcode (on the Mac, the login password), asked before a
/// remembered sign-in is read. Injected: the tests, and the demo copy on a simulator that has
/// neither, answer for the person.
@MainActor
protocol DeviceOwnerAuthenticating: AnyObject {
    /// Whether this device can ask at all, which needs a passcode (and without one the
    /// remembered sign-in is gone anyway: the Keychain deletes it).
    var canAuthenticate: Bool { get }
    /// "Face ID", "Touch ID", "Optic ID", or "Passcode" ("Password" on the Mac), for the copy.
    var methodName: String { get }
    /// Asks. The evaluated context on a yes, so the Keychain opens the item without asking a
    /// second time; nil on a no, a cancel or a lockout.
    func authenticate(reason: String) async -> LAContext?
}

final class SystemDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    var canAuthenticate: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }

    var methodName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return DeviceWords.isMac ? "Password" : "Passcode"
        }
    }

    func authenticate(reason: String) async -> LAContext? {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Not Now"
        do { return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? ctx : nil }
        catch { return nil }
    }
}

#if DEBUG
/// The demo copy on a simulator, which has neither Face ID nor a passcode:
/// `-vory-demo-biometry yes` (or `no`) answers every check for the person, so a UI test can
/// drive the remembered sign-in. Never in a release build.
final class DemoDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    let answer: Bool
    init(answer: Bool) { self.answer = answer }
    var canAuthenticate: Bool { true }
    var methodName: String { "Face ID" }
    func authenticate(reason: String) async -> LAContext? { answer ? LAContext() : nil }

    static func fromLaunchArguments() -> DemoDeviceOwnerAuthenticator? {
        guard DemoMode.isOn else { return nil }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-vory-demo-biometry"), i + 1 < args.count else { return nil }
        return DemoDeviceOwnerAuthenticator(answer: args[i + 1] == "yes")
    }
}
#endif

/// What went wrong with a remembered sign-in, in words for the Sign In sheet.
enum RememberedSignInError: LocalizedError, Equatable {
    case cancelled
    case gone
    case rejected

    var errorDescription: String? {
        switch self {
        case .cancelled: return "The check was cancelled. Try again, or enter the sign-in."
        case .gone: return "\(DeviceWords.This) no longer remembers a sign-in for this gateway. Enter it again."
        case .rejected: return "The gateway did not accept the remembered sign-in, so it was forgotten. Enter the current one."
        }
    }
}

/// Signing a gateway in again by itself, after Face ID, when its session has run out for good
/// and the person asked this device to remember the sign-in (#256). Only a password sign-in
/// can be remembered: a browser sign-in's refresh token is already kept and renewed silently,
/// and once the gateway turns it down only the browser can sign in again.
@MainActor
final class RememberedSignInCoordinator {
    /// What happens when a gateway's session has run out for good.
    enum Decision: Equatable {
        /// Face ID (or the passcode), then the remembered sign-in.
        case useRemembered
        /// The sign-in prompt the app has always shown, and why the remembered one is not used.
        case askPerson(Reason)
    }

    enum Reason: Equatable {
        /// A browser sign-in or a session token: nothing typed to sign in again with.
        case notPasswordSignIn
        case nothingRemembered
        /// No passcode on this device, so nothing can guard a remembered sign-in.
        case noPasscode
        /// The app is not in front, or its own lock is up. Tried again when it comes back.
        case notNow
        /// The check was turned down (or failed) since the last sign-in: not asked again by
        /// itself, only from the Sign In sheet's button.
        case declined
    }

    /// The decision, from facts alone. `asked`: the person tapped the button for it.
    nonisolated static func decide(authMode: AuthMode, remembered: Bool, canAuthenticate: Bool, canPromptNow: Bool, declined: Bool, asked: Bool) -> Decision {
        guard authMode == .password else { return .askPerson(.notPasswordSignIn) }
        guard remembered else { return .askPerson(.nothingRemembered) }
        guard canAuthenticate else { return .askPerson(.noPasscode) }
        if asked { return .useRemembered }
        guard canPromptNow else { return .askPerson(.notNow) }
        guard !declined else { return .askPerson(.declined) }
        return .useRemembered
    }

    let vault: RememberedSignInVault
    var authenticator: any DeviceOwnerAuthenticating
    /// Whether a Face ID prompt may show now: the app in front and not behind its own lock.
    var canPromptNow: @MainActor () -> Bool = { true }
    /// The gateway's password sign-in; replaced in tests.
    var signIn: @MainActor (GatewayConnection, RememberedSignIn, CloudflareAccess) async throws -> GatewaySecrets = { c, r, access in
        try await NativeAuthClient.signInWithPassword(gateway: c.gateway, provider: r.provider, username: r.username, password: r.password, access: access)
    }
    private(set) var declined: Set<UUID> = []
    private var running: [UUID: Task<GatewaySecrets, Error>] = [:]

    init(vault: RememberedSignInVault, authenticator: any DeviceOwnerAuthenticating = RememberedSignInCoordinator.defaultAuthenticator()) {
        self.vault = vault
        self.authenticator = authenticator
    }

    static func defaultAuthenticator() -> any DeviceOwnerAuthenticating {
        #if DEBUG
        if let demo = DemoDeviceOwnerAuthenticator.fromLaunchArguments() { return demo }
        #endif
        return SystemDeviceOwnerAuthenticator()
    }

    func decision(for c: GatewayConnection, asked: Bool) -> Decision {
        Self.decide(authMode: c.authMode, remembered: vault.contains(c.id), canAuthenticate: authenticator.canAuthenticate,
                    canPromptNow: asked || canPromptNow(), declined: declined.contains(c.id), asked: asked)
    }

    /// The session ran out: the remembered sign-in, when the decision allows it. nil sends the
    /// person to the sign-in prompt; a failure is never more than that.
    func signInAgain(_ c: GatewayConnection, access: CloudflareAccess) async -> GatewaySecrets? {
        guard decision(for: c, asked: false) == .useRemembered else { return nil }
        do { return try await run(c, access: access) } catch {
            declined.insert(c.id)
            return nil
        }
    }

    /// The same, asked for from the Sign In sheet: no waiting for a better moment, and what
    /// went wrong in words.
    func signInWithRemembered(_ c: GatewayConnection, access: CloudflareAccess) async throws -> GatewaySecrets {
        guard decision(for: c, asked: true) == .useRemembered else { throw RememberedSignInError.gone }
        return try await run(c, access: access)
    }

    /// Signed in by hand (the gateway's form): it may be signed in again by itself next time.
    func didSignIn(_ id: UUID) { declined.remove(id) }

    /// One prompt per gateway at a time: a burst of refused calls shares it.
    private func run(_ c: GatewayConnection, access: CloudflareAccess) async throws -> GatewaySecrets {
        if let t = running[c.id] { return try await t.value }
        let t = Task { try await attempt(c, access: access) }
        running[c.id] = t
        defer { running[c.id] = nil }
        return try await t.value
    }

    private func attempt(_ c: GatewayConnection, access: CloudflareAccess) async throws -> GatewaySecrets {
        guard let context = await authenticator.authenticate(reason: "Sign in to \(c.name)") else { throw RememberedSignInError.cancelled }
        guard let remembered = try vault.signIn(for: c.id, context: context) else { throw RememberedSignInError.gone }
        do {
            var s = try await signIn(c, remembered, access)
            s.access = access
            declined.remove(c.id)
            return s
        } catch let e as HermesAPIError where e.isUnauthorized {
            // The gateway turned the remembered password down: it was changed. Kept, it would
            // only ask for Face ID again for nothing.
            vault.forget(c.id)
            throw RememberedSignInError.rejected
        }
    }
}

/// The words for what guards a remembered sign-in on this device.
enum RememberedSignInCopy {
    /// "Face ID or the passcode", "the passcode", "Touch ID or your password"…
    static func guardedBy(_ method: String) -> String {
        #if os(macOS)
        return method == "Touch ID" ? "Touch ID or your password" : "your password"
        #else
        return method == "Passcode" ? "the passcode" : "\(method) or the passcode"
        #endif
    }

    /// Under the switch, on.
    static func kept(_ method: String) -> String {
        #if os(macOS)
        return "Kept in this Mac's Keychain behind \(guardedBy(method)), so Vory signs in again by itself when the session ends. Never synced to iCloud."
        #else
        return "Kept in \(DeviceWords.this)'s Keychain behind \(guardedBy(method)), so Vory signs in again by itself when the session ends. Never synced to iCloud or sent to the watch."
        #endif
    }

    /// Under the switch when the device has no passcode.
    static var needsPasscode: String {
        #if os(macOS)
        return "Remembering a sign-in needs a login password on this Mac."
        #else
        return "Remembering a sign-in needs a passcode on \(DeviceWords.this)."
        #endif
    }
}
