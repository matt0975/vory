import CryptoKit
import Foundation
import Testing
@testable import VoryCore

/// The notification service extensions' push work (#455). `didReceive` hands the shared Keychain read and the decrypt
/// to PushIntake, and `begin` must come back at once while that work runs, so the extension answers the system before
/// a slow Keychain does: the first test. The other four hold what the work finds still while its thread changes.
@Suite struct PushIntakeTests {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: PushIntake.Outcome?
        private var calls = 0
        func set(_ value: PushIntake.Outcome) { lock.lock(); outcome = value; lock.unlock() }
        func get() -> PushIntake.Outcome? { lock.lock(); defer { lock.unlock() }; return outcome }
        func called() { lock.lock(); calls += 1; lock.unlock() }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    private func keyBase64(_ key: SymmetricKey) -> String { key.withUnsafeBytes { Data($0) }.base64EncodedString() }
    private func credentials(_ key: SymmetricKey) -> PushRelay.Credentials {
        PushRelay.Credentials(installID: "test-install", secret: "test-secret", payloadKey: keyBase64(key))
    }
    /// A payload sealed as the gateway seals it: base64(nonce ‖ ciphertext ‖ tag) of the fields' JSON.
    private func sealed(_ fields: [String: JSONValue], with key: SymmetricKey) throws -> String {
        let plain = try JSONEncoder().encode(JSONValue.object(fields))
        return try #require(try AES.GCM.seal(plain, using: key).combined).base64EncodedString()
    }
    /// `begin`'s outcome, waited for up to 2 s.
    private func run(_ enc: String?, _ creds: PushRelay.Credentials?, box: Box = Box()) -> PushIntake.Outcome? {
        let finished = DispatchSemaphore(value: 0)
        PushIntake.begin(enc: enc, credentials: { box.called(); return creds }, done: { box.set($0); finished.signal() })
        _ = finished.wait(timeout: .now() + 2)
        return box.get()
    }

    @Test func beginReturnsBeforeTheCredentialsReadEnds() throws {
        let key = SymmetricKey(size: .bits256)
        let enc = try sealed(["title": .string("Build finished")], with: key)
        let creds = credentials(key)
        let gate = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        // The slow Keychain: its read waits for the gate, which another queue opens after 0.5 s either way.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { gate.signal() }
        let start = DispatchTime.now().uptimeNanoseconds
        PushIntake.begin(enc: enc, credentials: { gate.wait(); return creds }, done: { _ in finished.signal() })
        let returned = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        #expect(returned < 0.1, "begin came back after \(returned) s: it waited for the credentials read")
        #expect(finished.wait(timeout: .now() + 2) == .success, "done never came")
    }

    @Test func aPlainPushIsPlain() {
        let box = Box()
        #expect(run(nil, nil, box: box) == .plain)
        #expect(box.callCount == 0, "a plain push read the credentials")
    }

    @Test func noCredentialsSaysSo() throws {
        let enc = try sealed(["title": .string("Build finished")], with: SymmetricKey(size: .bits256))
        #expect(run(enc, nil) == .noCredentials)
    }

    @Test func aSealedPayloadOpensWithItsKey() throws {
        let key = SymmetricKey(size: .bits256)
        let fields: [String: JSONValue] = ["title": .string("Build finished"), "body": .string("All green"),
                                           "category": .string("HERMES_TURN"), "thread_id": .string("t1")]
        #expect(run(try sealed(fields, with: key), credentials(key)) == .decrypted(fields))
    }

    @Test func aWrongKeyFails() throws {
        let enc = try sealed(["title": .string("Build finished")], with: SymmetricKey(size: .bits256))
        let outcome = run(enc, credentials(SymmetricKey(size: .bits256)))
        var failed = false
        if case .failed = outcome { failed = true }
        #expect(failed, "a payload sealed with another key gave \(String(describing: outcome))")
    }
}
