import Foundation

/// #641: when a chat that lost its live attach is tried again, how long a try may take, and what the chat shows
/// meanwhile. Pure; the chat's re-attach (`ChatSession`) asks it, on its own clock (`ReattachClock`).
public enum ReattachSchedule {
    /// The wait after the nth failed try in a row (n from 1): 2, 5, 10 and 20 s, then every 30 s. The chat spreads each
    /// by ±`jitter`, so chats that failed together don't try together.
    public static func delay(afterFailures n: Int) -> Double {
        switch n {
        case ...1: return 2
        case 2: return 5
        case 3: return 10
        case 4: return 20
        default: return 30
        }
    }

    public static let jitter = 0.2

    /// How long the nth try's session.resume may take (n from 1): 30 s, then twice as long on each try after, up to
    /// 120 s. A long chat's resume carries its transcript, so a fixed 30 s on a slow link could time out for ever.
    public static func tryTimeout(try n: Int) -> Double { min(120, 30 * pow(2, Double(max(0, n - 1)))) }

    /// Nothing shows for this long into the trouble, so a blip says nothing.
    public static let lineAfter: Double = 2
    /// From this long into the trouble, the banner with Try again.
    public static let bannerAfter: Double = 60

    /// What shows `elapsed` seconds into the trouble. A chat the gateway no longer has shows no re-attach line: it has
    /// its own banner, and isn't tried again.
    public static func show(after elapsed: Double, gone: Bool = false) -> ReattachShow {
        if gone || elapsed < lineAfter { return .none }
        return elapsed < bannerAfter ? .reconnecting : .failed
    }
}

/// What the chat's dock shows of a lost live attach (#641): nothing, the quiet "Reconnecting…" line, or the banner with
/// Try again.
public enum ReattachShow: Equatable, Sendable {
    case none, reconnecting, failed
}

/// The re-attach's clock: the real one in the app, a manual one in the tests.
public struct ReattachClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Double) async throws -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Double) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let live = ReattachClock(now: { Date() }, sleep: { try await Task.sleep(for: .seconds($0)) })
}
