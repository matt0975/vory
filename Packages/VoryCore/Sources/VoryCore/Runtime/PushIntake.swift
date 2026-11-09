import Foundation

/// A relay push's work in the notification service extensions (#455): the shared Keychain read of this install's
/// relay credentials and the decrypt of the payload the gateway sealed (#497), handed back once as an outcome. The
/// extensions call it from `didReceive`, which returns as soon as `begin` does: the system hears back at once, however
/// long the Keychain takes.
public enum PushIntake {
    public enum Outcome: Sendable, Equatable {
        /// No `enc`: a plain push, shown as it came.
        case plain
        /// The payload's fields.
        case decrypted([String: JSONValue])
        /// No relay credentials could be read from the shared group.
        case noCredentials
        /// The payload didn't open, and why.
        case failed(String)
    }

    /// Reads the credentials and opens `enc` with them on a queue of its own, then calls `done` once with the outcome,
    /// there. It returns at once, before any of that work.
    public static func begin(enc: String?, credentials: @escaping @Sendable () -> PushRelay.Credentials?,
                             done: @escaping @Sendable (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { done(outcome(enc: enc, credentials: credentials)) }
    }

    static func outcome(enc: String?, credentials: () -> PushRelay.Credentials?) -> Outcome {
        guard let enc else { return .plain }
        guard let creds = credentials() else { return .noCredentials }
        do { return .decrypted(try PushRelay.decrypt(enc, keyBase64: creds.payloadKey)) }
        catch { return .failed(error.localizedDescription) }
    }
}
