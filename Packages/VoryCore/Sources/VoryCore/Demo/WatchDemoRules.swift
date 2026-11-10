import Foundation

/// The Apple Watch while the iPhone runs the demo (#502). The phone tells it so in the application context, and the Watch
/// shows the demo's bots, chats and approvals, read through the phone (the demo is answered in process there, so the
/// Watch can't reach it on a route of its own), and keeps nothing of it: when the phone leaves the demo, the Watch goes
/// back to its saved gateway as it was (#494's no-trace rule, on the Watch too).
public enum WatchDemoRules {
    /// The context's flag: the gateway in use on the phone is the demo.
    public static let demoKey = "demo"
    /// The flag on the phone's answer to a request made for the demo after the demo ended there.
    public static let demoEndedKey = "demoEnded"

    /// What the phone's context says of the gateway in use: its id for "active", and whether it is the demo. Today's:
    /// never the demo (WatchSync.push leaves "active" out for it, #392), and no flag.
    public static func context(activeID: UUID?) -> (active: String?, demo: Bool) {
        (activeID == GatewayConnection.demoID ? nil : activeID?.uuidString, false)
    }

    /// What the Watch runs after a context.
    public enum Target: Equatable, Sendable {
        /// The phone's demo, read through the phone.
        case demo
        /// A gateway of the person's: the phone's choice when it names one, else the Watch's own (nil).
        case gateway(UUID?)
    }

    /// The Watch's target from a context's flag and "active". Today's: the flag isn't read, so never the demo.
    public static func target(demo: Bool, active: UUID?) -> Target {
        .gateway(active == GatewayConnection.demoID ? nil : active)
    }

    /// Whether the Watch keeps anything for a gateway it runs: its chat list's cache, the phone's last choice, the looks
    /// it was sent, its push registration, the usage numbers in the complications' snapshot. Today's: always.
    public static func keepsState(for connection: GatewayConnection) -> Bool {
        true
    }

    /// Whether the phone's answer to a request for `requested` says the demo has ended there. Today's: never.
    public static func demoEnded(requested: UUID?, phoneInDemo: Bool) -> Bool {
        false
    }

    /// Whether an answer from the phone carries that word: the Watch leaves the demo at once, before the context lands.
    public static func endsDemo(_ answer: [String: Any]) -> Bool {
        answer[demoEndedKey] as? Bool == true
    }

    /// One move at a time into or out of the demo on the Watch. Today's: none is ever held back, so every word that the
    /// demo began or ended starts a move.
    public struct DemoMove: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case entering, leaving }
        public private(set) var under: Kind?
        public init() {}

        /// Whether a move of `kind` may start now. Today's: always.
        public mutating func begin(_ kind: Kind) -> Bool {
            under = kind
            return true
        }

        /// An activation landed. Today's: nothing is held, so nothing to end.
        public mutating func landed() {
            under = nil
        }
    }
}
