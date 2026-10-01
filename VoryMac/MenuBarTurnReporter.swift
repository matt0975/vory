import AppKit
import SwiftUI
import VoryCore

/// The Mac's stand-in for the Live Activity: every running turn and every waiting approval on
/// one board. The menu-bar item lists them, and the Dock badge counts the ones that need you.
@MainActor
@Observable
final class TurnBoard {
    static let shared = TurnBoard()

    struct Turn: Identifiable {
        let id: String
        var title: String
        var bot: String
        var profile: String
        var detail: String
        var attention: Bool
        let startedAt: Date
        weak var chat: ChatSession?
    }

    private(set) var turns: [Turn] = []
    var running: Int { turns.filter { !$0.attention }.count }
    var attention: Int { turns.filter(\.attention).count }

    func upsert(_ t: Turn) {
        if let i = turns.firstIndex(where: { $0.id == t.id }) { turns[i] = t } else { turns.append(t) }
        badge()
    }

    func remove(_ id: String) {
        turns.removeAll { $0.id == id }
        badge()
    }

    private func badge() {
        NSApp.dockTile.badgeLabel = attention > 0 ? "\(attention)" : nil
    }
}

/// One per chat, made by the runtime through `activityReporterFactory`; it keeps its chat's
/// row on the board for the length of the turn.
@MainActor
final class MenuBarTurnReporter: TurnActivityReporting {
    private var id: String?
    private var startedAt = Date()

    func start(for chat: ChatSession) {
        startedAt = Date()
        id = chat.storedID
        TurnBoard.shared.upsert(turn(chat, detail: "Thinking…", attention: false))
    }

    func update(for chat: ChatSession, attention: Bool, detail: String?) {
        guard id != nil else { return }
        let card = chat.firstCard
        let text = detail ?? (attention
            ? (card?.method == "sudo" ? "sudo password needed" : (card?.approval?.description ?? (card?.method == "approval" ? "Approval needed" : "Needs your answer")))
            : (chat.statusLine ?? "Thinking…"))
        TurnBoard.shared.upsert(turn(chat, detail: text, attention: attention))
    }

    func end(for chat: ChatSession, phase: String) {
        BotAmbient.shared.turnFinished(profile: chat.profileName)
        if let id { TurnBoard.shared.remove(id) }
        id = nil
    }

    private func turn(_ chat: ChatSession, detail: String, attention: Bool) -> TurnBoard.Turn {
        let bot = chat.runtime.profiles.first { $0.name == chat.profileName }?.label ?? chat.profileName
        return TurnBoard.Turn(id: chat.storedID, title: chat.title, bot: bot, profile: chat.profileName, detail: detail, attention: attention, startedAt: startedAt, chat: chat)
    }
}

/// What drops down from the menu-bar item: the turns in flight, each with its bot, what it is
/// doing and how long; a waiting approval gets Approve once and Deny right there.
struct TurnMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var board = TurnBoard.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if board.turns.isEmpty {
                HStack(spacing: 10) {
                    BotFaceView(spec: BotLookSpec(shape: "cloud", eyes: "classic", hex: "#3B7BFF", finish: "flat"), size: 28, active: false, mood: BotFaceView.Mood(profile: "vory-menubar"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Nothing running").font(.subheadline.weight(.semibold))
                        Text(model.runtime.map { "\($0.connection.name) · \($0.socketState.label)" } ?? "No gateway").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            } else {
                ForEach(board.turns) { t in
                    row(t)
                    if t.id != board.turns.last?.id { Divider().padding(.horizontal, 12) }
                }
            }
            Divider()
            HStack {
                Button("Open Vory") { open(nil) }.buttonStyle(.plain).font(.caption)
                Spacer()
                Text(board.attention > 0 ? "\(board.attention) need\(board.attention == 1 ? "s" : "") you" : "\(board.running) working").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 320)
    }

    private func row(_ t: TurnBoard.Turn) -> some View {
        HStack(alignment: .top, spacing: 10) {
            BotAvatar(profile: t.profile, size: 30, active: !t.attention, mood: BotFaceView.Mood(state: t.attention ? .awaitingApproval : .working))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(t.bot).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if t.attention { Circle().fill(.yellow).frame(width: 7, height: 7) }
                    Spacer(minLength: 0)
                    Text(t.startedAt, style: .timer).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(t.title).font(.caption).lineLimit(1)
                Text(t.detail).font(.caption).foregroundStyle(t.attention ? .orange : .secondary).lineLimit(2)
                HStack(spacing: 8) {
                    if t.attention, let chat = t.chat, let card = chat.firstCard, card.method == "approval" {
                        Button("Approve once") { Task { await chat.respond(card: card, result: ["choice": "once"]) } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Deny") { Task { await chat.respond(card: card, result: ["choice": "deny"]) } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    Button(t.attention ? "Answer in Vory" : "Open") { open(t.id) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
    }

    /// Brings the app forward, on the chat when one is named.
    private func open(_ storedID: String?) {
        // The window may be closed (the app lives on in the menu bar): this brings it back.
        openWindow(id: MacWindow.main)
        NSApp.activate()
        if let storedID, let url = URL(string: "vory://chat/\(storedID)") { model.open(url) }
    }
}
