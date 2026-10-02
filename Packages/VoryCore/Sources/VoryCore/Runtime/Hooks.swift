import Foundation

/// Drives a platform's "turn in progress" surface (a Live Activity on iOS, a menu-bar item on
/// macOS, nothing on the watch). The core calls these; it never imports ActivityKit.
@MainActor
public protocol TurnActivityReporting: AnyObject {
    func start(for chat: ChatSession)
    func update(for chat: ChatSession, attention: Bool, detail: String?)
    func end(for chat: ChatSession, phase: String)
}

public extension TurnActivityReporting {
    func update(for chat: ChatSession, attention: Bool) { update(for: chat, attention: attention, detail: nil) }
}

/// Local (foreground-only) notifications for cards and finished turns.
@MainActor
public protocol CardNotifying: AnyObject {
    func cardArrived(_ card: PendingCard, chat: ChatSession)
    func turnFinished(chat: ChatSession, error: String?)
    /// A card this device was showing went without being answered here (answered on another
    /// device): whatever was posted for it (a notification with Approve on it) is out of date.
    func cardSettled(_ card: PendingCard, chat: ChatSession)
}

public extension CardNotifying {
    func cardSettled(_ card: PendingCard, chat: ChatSession) {}
}

/// Publishes the device's push registration to the gateway after capabilities are known.
@MainActor
public protocol PushRegistrationSyncing: AnyObject {
    func syncRegistration(runtime: GatewayRuntime) async
    /// A prompt just went out for `session` from this device: the gateway is told which device
    /// drives the chat now (the Companion quiets a phone that asked for it while a Mac does).
    func noteSend(session: String, runtime: GatewayRuntime)
    /// An approval was answered on this device: the gateway is told which device did, so the
    /// Companion can take the request down on the others and leave this one alone.
    func noteAnswer(requestID: String, session: String, runtime: GatewayRuntime)
}

public extension PushRegistrationSyncing {
    func noteSend(session: String, runtime: GatewayRuntime) {}
    func noteAnswer(requestID: String, session: String, runtime: GatewayRuntime) {}
}

/// Default when a platform has no turn surface.
@MainActor
public final class NoTurnActivity: TurnActivityReporting {
    public init() {}
    public func start(for chat: ChatSession) {}
    public func update(for chat: ChatSession, attention: Bool, detail: String?) {}
    public func end(for chat: ChatSession, phase: String) {}
}
