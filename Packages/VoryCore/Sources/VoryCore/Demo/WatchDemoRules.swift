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

    /// What the phone's context says of the gateway in use: its id for "active", and whether it is the demo. The demo's
    /// id is sent like any other, with the flag, so the Watch never takes it for a gateway of its own.
    public static func context(activeID: UUID?) -> (active: String?, demo: Bool) {
        (activeID?.uuidString, activeID == GatewayConnection.demoID)
    }

    /// What the Watch runs after a context.
    public enum Target: Equatable, Sendable {
        /// The phone's demo, read through the phone.
        case demo
        /// A gateway of the person's: the phone's choice when it names one, else the Watch's own (nil).
        case gateway(UUID?)
    }

    /// The Watch's target from a context's flag and "active". A context naming the demo without the flag (an older
    /// phone) is no gateway of the person's: the Watch stays with its own.
    public static func target(demo: Bool, active: UUID?) -> Target {
        if demo { return .demo }
        return .gateway(active == GatewayConnection.demoID ? nil : active)
    }

    /// Whether the Watch keeps anything for a gateway it runs: its chat list's cache, the phone's last choice, the looks
    /// it was sent, its push registration, the usage numbers in the complications' snapshot. Never for the demo.
    public static func keepsState(for connection: GatewayConnection) -> Bool {
        !connection.isDemo
    }

    /// The key the Watch saves a gateway's chat list under: that gateway's id and the bot the list is for ("-" when none
    /// is picked yet, "*" for every bot). The gateway is the one whose runtime fetched the rows, never the one running
    /// when they land: a list landing after a switch is never saved under the next gateway's key.
    public static func listKey(gateway: UUID, profile: String?) -> String {
        listKeyPrefix(gateway) + (profile ?? "-")
    }

    /// Of the keys the Watch has stored, the demo's saved lists, which it removes at launch: before this rule, a list of
    /// the person's landing after the move into the demo could be saved under the demo's key, and the demo's list then
    /// read it back under the demo's name. Only keys under the demo's own id; a real gateway's lists are left as they are.
    public static func demoListKeys(in keys: [String]) -> [String] {
        let prefix = listKeyPrefix(GatewayConnection.demoID)
        return keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    private static func listKeyPrefix(_ gateway: UUID) -> String { "watch.sessions." + gateway.uuidString + "." }

    /// Whether the phone's answer to a request for `requested` says the demo has ended there: asked for the demo by a
    /// Watch that hasn't had the context yet, with the phone on a gateway of the person's again.
    public static func demoEnded(requested: UUID?, phoneInDemo: Bool) -> Bool {
        requested == GatewayConnection.demoID && !phoneInDemo
    }

    /// Whether the context this phone last sent names the demo while the phone isn't in it: the app ended in the
    /// demo, which is held in memory only, so nothing told the Watch it was over. Then a fresh context goes, with no
    /// demo flag.
    public static func contextIsStale(lastSent: [String: Any], phoneInDemo: Bool) -> Bool {
        lastSent[demoKey] as? Bool == true && !phoneInDemo
    }

    /// Whether an answer from the phone carries that word: the Watch leaves the demo at once, before the context lands.
    public static func endsDemo(_ answer: [String: Any]) -> Bool {
        answer[demoEndedKey] as? Bool == true
    }

    /// One move at a time into or out of the demo on the Watch. A second word that the demo ended (every request made
    /// while the Watch is still on the demo's runtime answers so) or a second context saying the demo began, while that
    /// move is under way, starts nothing: each would start the activation again and the nearly done one would give way.
    /// The move ends when any activation lands (`landed`): the last one started wins (the Watch's activation token), so any
    /// move under way is over then, whichever way it went. A move the other way takes over from one under way.
    public struct DemoMove: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case entering, leaving }
        public private(set) var under: Kind?
        public init() {}

        /// Whether a move of `kind` may start now; if so, it is the one under way.
        public mutating func begin(_ kind: Kind) -> Bool {
            if under == kind { return false }
            under = kind
            return true
        }

        /// An activation landed, of the demo or not (the Watch's own pick, a route change, the move itself): whatever move
        /// was under way is over. Kept to its own kind, a move into the demo overtaken by the Watch's own pick would never
        /// end, and every later context would start nothing.
        public mutating func landed() {
            under = nil
        }
    }
}
