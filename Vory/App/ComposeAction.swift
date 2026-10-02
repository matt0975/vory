import Foundation

/// What the New Chat circle beside the tab bar does, on a tap and on a press and hold. Chosen
/// in Settings › Appearance; this device's own, like the tab bar's layout.
enum ComposeAction: String, CaseIterable, Identifiable, Sendable {
    /// Straight into a fresh chat with the current bot, nothing to fill in first.
    case quick
    /// The New Message sheet: bots, a project, a first message and files.
    case sheet
    /// Nothing at all (a press and hold only).
    case none

    var id: String { rawValue }

    static let tapKey = "compose.tap"
    static let holdKey = "compose.hold"
    static let tapChoices: [ComposeAction] = [.quick, .sheet]
    static let holdChoices: [ComposeAction] = [.sheet, .quick, .none]
    static let tapDefault = ComposeAction.quick
    static let holdDefault = ComposeAction.sheet

    var title: String {
        switch self {
        case .quick: "Start a chat"
        case .sheet: "Show options"
        case .none: "Nothing"
        }
    }

    /// For VoiceOver, after "Tap to" or "press and hold to".
    var spoken: String {
        switch self {
        case .quick: "start a fresh chat with the current bot"
        case .sheet: "choose bots, a project or files first"
        case .none: "do nothing"
        }
    }

    /// The stored choice, or the default when nothing is stored or the value is not one a tap
    /// can have (a tap always does something).
    static func tap(_ raw: String?) -> ComposeAction {
        raw.flatMap(ComposeAction.init(rawValue:)).flatMap { tapChoices.contains($0) ? $0 : nil } ?? tapDefault
    }

    static func hold(_ raw: String?) -> ComposeAction {
        raw.flatMap(ComposeAction.init(rawValue:)).flatMap { holdChoices.contains($0) ? $0 : nil } ?? holdDefault
    }
}
