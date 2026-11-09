import Foundation

/// A relay push's work in the notification service extensions (#455): the shared Keychain read of this install's
/// relay credentials and the decrypt of the payload the gateway sealed (#497), handed back once as an outcome. The
/// extensions call it from `didReceive`, so what `begin` costs before it returns is what `didReceive` costs.
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

    /// Reads the credentials, opens `enc` with them, and calls `done` once with the outcome, on the caller's thread,
    /// before it returns.
    public static func begin(enc: String?, credentials: @escaping @Sendable () -> PushRelay.Credentials?,
                             done: @escaping @Sendable (Outcome) -> Void) {
        done(outcome(enc: enc, credentials: credentials))
    }

    static func outcome(enc: String?, credentials: () -> PushRelay.Credentials?) -> Outcome {
        guard let enc else { return .plain }
        guard let creds = credentials() else { return .noCredentials }
        do { return .decrypted(try PushRelay.decrypt(enc, keyBase64: creds.payloadKey)) }
        catch { return .failed(error.localizedDescription) }
    }
}
