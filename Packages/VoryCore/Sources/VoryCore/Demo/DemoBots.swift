import Foundation

/// The demo's bots as the app shows them (#392), for what draws them outside the demo itself: onboarding's orbit (#388)
/// and the looks the app gives them while the demo runs. Read only; the demo's words stay in `DemoContent`.
public struct DemoBot: Sendable, Hashable {
    /// The gateway's folder for it, which the app keys its look by.
    public let name: String
    public let display: String
    public let title: String
    /// Its look, from the app's own lists (`BotLookSpec.shapes`, `.eyeStyles`): five bodies, five eyes, five colours.
    public let shape: String
    public let eyes: String
    public let hex: String
}

public enum DemoBots {
    public static let all: [DemoBot] = DemoContent.bots.map {
        DemoBot(name: $0.name, display: $0.display, title: $0.title, shape: $0.shape, eyes: $0.eyes, hex: $0.hex)
    }
}
