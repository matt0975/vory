import Foundation
import Observation
import VoryCore

/// Onboarding's own demo (#388, beats 3 and 4): a runtime of its own on the demo's gateway, for a real chat with Sprout
/// on the app's real chat parts. It is never the app's gateway in use: none of the app's reporters, notifiers or push
/// are attached (no Live Activity, notification, Watch hand-off or iCloud write), its store keeps nothing
/// (`ConnectionStore.demoOnly()`), and the demo's core leaves nothing behind once it stops. Started as the chat beats
/// come up, stopped as the tour moves past them or goes, and started afresh on the way back.
@MainActor
@Observable
final class TourChat {
    /// The ready-made message of beat 3.
    static let readyMessage = "What\u{2019}s taking up the most space on my server?"
    /// Sprout, the demo's research bot, whose chat the tour shows: its folder, from the demo's own list.
    static var profile: String { DemoBots.all.first { $0.display == "Sprout" }?.name ?? "default" }
    /// Beat 4's mention, after the answer: Gizmo, the demo's home-server bot, asked to keep an eye on disk space.
    static var mentionBot: DemoBot? { DemoBots.all.first { $0.display == "Gizmo" } }
    static let mentionDraft = "can you keep an eye on disk space?"
    /// How long the message bar's list of bots stays up, "@Gi" typed, before Gizmo is picked from it. The UI tests hold
    /// it longer (`-vory-tour-list-hold <seconds>`, DEBUG only): reading the screen there can take two seconds.
    static var listHold: TimeInterval {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-vory-tour-list-hold"), i + 1 < args.count, let s = TimeInterval(args[i + 1]) { return s }
        #endif
        return 1.4
    }
    /// What the tour's one ask offers: Allow once and Deny, so the real card shows those two (Matt, 2026-10-20). Try a
    /// demo keeps all four.
    static let approvalChoices = ["once", "deny"]

    private(set) var runtime: GatewayRuntime?
    private(set) var chat: ChatSession?

    /// The demo's looks were turned on by this tour, and go off when it stops.
    @ObservationIgnored private(set) var looksOn = false
    private let pace: DemoGateway.Pace
    /// A gateway is in use (the tour is shown over it only in a debug launch).
    private let appHasGateway: @MainActor () -> Bool
    /// The app's own demo is running (Try a demo, from the tour's last beat).
    private let appInDemo: @MainActor () -> Bool

    init(pace: DemoGateway.Pace = .real, appHasGateway: @escaping @MainActor () -> Bool, appInDemo: @escaping @MainActor () -> Bool) {
        self.pace = pace
        self.appHasGateway = appHasGateway
        self.appInDemo = appInDemo
    }

    /// Starts and stops, one after the other: a swipe back and forth while one is under way never leaves a runtime
    /// running unseen, or none where the chat is shown.
    @ObservationIgnored private var queue: Task<Void, Never>?

    private func serially(_ job: @escaping @MainActor @Sendable () async -> Void) async {
        let before = queue
        let next = Task { @MainActor in
            await before?.value
            await job()
        }
        queue = next
        await next.value
    }

    /// The tour's demo and its chat with Sprout; whatever of them is missing.
    func start() async {
        await serially { [self] in
            if runtime == nil {
                wearLooks()
                let rt = GatewayRuntime(connection: .demo, store: .demoOnly(),
                                        transport: .demo(DemoGateway(pace: pace, approvalChoices: Self.approvalChoices)))
                runtime = rt
                await rt.start()
            }
            guard let rt = runtime, chat == nil else { return }
            chat = try? await rt.newChat(profile: Self.profile)
        }
    }

    /// Sprout wears its own look in the tour's chat, in memory only (`DemoLooks`): only with no gateway in use, which is
    /// the only time the tour is shown but for a debug launch, where that gateway's bots keep their looks; and not when
    /// they are on already (the app's own demo), which keeps them.
    func wearLooks() {
        guard !looksOn, !appHasGateway(), !DemoLooks.isOn else { return }
        DemoLooks.set(on: true)
        looksOn = true
    }

    /// The looks this tour put on go, unless the app's own demo runs now (Try a demo), which wears the same ones.
    func dropLooks() {
        guard looksOn else { return }
        looksOn = false
        if !appInDemo() { DemoLooks.set(on: false) }
    }

    /// Stops the tour's demo: its looks (`dropLooks`), its chat, and with the core's own clean-up its scratch files.
    func stop() async {
        await serially { [self] in
            dropLooks()
            guard let rt = runtime else { return }
            runtime = nil
            chat = nil
            await rt.stop()
        }
    }
}

/// Where the tour's chat has got to, for Vory's lines (`TourLines.chatMoved`) and the tour's move on to beat 4.
enum TourChatPhase: Equatable {
    /// The ready-made message waits in the message bar.
    case ready
    /// Sprout is on it.
    case working
    /// Sprout replied and asked nothing (another message than the ready-made one).
    case replied
    /// The approval card is up.
    case asked
    /// The card was answered and the turn has ended: one of the allows, or Deny.
    case answered(allowed: Bool)

    /// The phase for a reading of the chat, given how many tool rows it had when its card came up (nil: no card yet).
    /// An allowed card runs its command, which is a tool row more; the chat's own note of the answer says so too where
    /// it makes one (an answer that goes through the approval queue makes none).
    static func of(_ r: TourChatReading, toolsWhenAsked: Int?) -> TourChatPhase {
        if r.asked { return .asked }
        if let before = toolsWhenAsked {
            if r.running { return .working }
            return .answered(allowed: r.answer.map { $0 != "deny" } ?? (r.tools > before))
        }
        if !r.sent { return r.running ? .working : .ready }
        return r.running || !r.replied ? .working : .replied
    }

    /// The choice of the chat's last answered approval, from the line the chat notes it with ("Approval: once").
    static func lastAnswer(in items: [TranscriptItem]) -> String? {
        let mark = "Approval: "
        for item in items.reversed() {
            if case .system(let text, _) = item.kind, text.hasPrefix(mark) { return String(text.dropFirst(mark.count)) }
        }
        return nil
    }
}

/// What the tour reads of its chat, as plain values: it changes as the chat moves on, not with every streamed word.
struct TourChatReading: Equatable {
    /// An approval card is up.
    var asked = false
    var running = false
    /// A message of the person's is in the chat, and Sprout has said something since.
    var sent = false
    var replied = false
    /// The chat's tool rows.
    var tools = 0
    /// The chat's note of its last answer ("once", "deny"), where it made one.
    var answer: String?

    init() {}

    @MainActor init(_ chat: ChatSession) {
        asked = chat.cards.contains { $0.method == "approval" }
        running = chat.isRunning
        let items = chat.items
        if let last = items.lastIndex(where: { if case .user = $0.kind { return true }; return false }) {
            sent = true
            replied = items[(last + 1)...].contains { if case .assistant(let t, _, _) = $0.kind { return !t.isEmpty }; return false }
        }
        tools = items.reduce(0) { n, item in if case .tool = item.kind { return n + 1 }; return n }
        answer = TourChatPhase.lastAnswer(in: items)
    }
}

/// Follows readings of the tour's chat to its phase, keeping how many tool rows it had when its card came up.
struct TourChatTracker {
    private(set) var toolsWhenAsked: Int?

    mutating func phase(for r: TourChatReading) -> TourChatPhase {
        if r.asked, toolsWhenAsked == nil { toolsWhenAsked = r.tools }
        return TourChatPhase.of(r, toolsWhenAsked: toolsWhenAsked)
    }
}
