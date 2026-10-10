#if os(iOS)
import Foundation
import UIKit
import VoryCore

/// What happens to a turn when the app leaves the screen.
///
/// iOS suspends the app soon after, which closes its connection to the gateway. A gateway that
/// sees no app on a chat stops the turn after a short wait (an older Hermes: 20 seconds, even
/// while the bot is working). Two things are done about it here:
///
/// - Leaving with a turn running asks the system for background time, so the connection stays
///   up for the half minute iOS allows. A short turn finishes inside it, and by then the
///   Companion (when installed) has attached to the chat and keeps it alive.
/// - Coming back to a turn that was running and now ends in the gateway's "Operation
///   interrupted" marks it as stopped because the app was away, so its card opens already
///   explained instead of leaving the person to guess.
@MainActor
final class AwayWatch {
    static let shared = AwayWatch()

    /// Away for less than this, the gateway cannot have given up on the chat for our absence.
    nonisolated static let shortestAway: TimeInterval = 10
    /// How long after coming back the chats are watched for their re-read from the gateway.
    nonisolated static let settleWindow: TimeInterval = 45

    private var leftRunning: Set<String> = []
    private var leftAt: Date?
    /// Signalled to let the background time go: by the turn's end, the app's return, or the
    /// system saying the time is up.
    private var held: DispatchSemaphore?
    private var hold: Task<Void, Never>?
    private var check: Task<Void, Never>?

    func left(runtime: GatewayRuntime?) {
        check?.cancel()
        let running = runtime?.chats.filter { $0.isRunning && !$0.storedID.isEmpty } ?? []
        leftRunning = Set(running.map(\.storedID))
        leftAt = Date()
        guard !running.isEmpty, held == nil else { return }
        // The background time is held by a block on a queue of its own, and given back from
        // there when the system says the time is up. With beginBackgroundTask that call came
        // on the main thread, and a main thread still busy with a long turn's events could not
        // answer it in the seconds allowed: the system ended the app ("App crashed in
        // background", testers on 1.3 with a long turn running).
        let release = DispatchSemaphore(value: 0)
        held = release
        ProcessInfo.processInfo.performExpiringActivity(withReason: "vory.turn.finishing") { expired in
            if expired { release.signal() } else { _ = release.wait(timeout: .now() + 600) }
        }
        LiveActivityController.note("left with \(running.count) turn(s) running: holding the connection")
        hold = Task { [weak self, weak runtime] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let runtime, runtime.chats.contains(where: \.isRunning) else { break }
            }
            self?.release()
        }
    }

    private func release() {
        hold?.cancel(); hold = nil
        held?.signal()
        held = nil
    }

    func returned(runtime: GatewayRuntime?) {
        release()
        let ids = leftRunning
        let away = Date().timeIntervalSince(leftAt ?? Date())
        leftRunning = []
        guard !ids.isEmpty, let runtime, away >= Self.shortestAway else { return }
        check = Task { [weak runtime] in
            var pending = ids
            let deadline = Date().addingTimeInterval(Self.settleWindow)
            while !pending.isEmpty, Date() < deadline, !Task.isCancelled {
                guard let runtime else { return }
                for id in pending {
                    guard let chat = runtime.chatForStored(id) else { pending.remove(id); continue }
                    // Still running: either it truly is, or the chat has not been re-read yet.
                    guard !chat.isRunning, !chat.isResuming else { continue }
                    pending.remove(id)
                    if chat.interruptCause == nil, Self.endsInterrupted(chat.items) {
                        chat.interruptCause = .appWasAway
                        LiveActivityController.note("“\(chat.title.prefix(24))” was stopped while the app was away")
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Whether the thread's latest reply is the gateway's "Operation interrupted" and nothing else.
    nonisolated static func endsInterrupted(_ items: [TranscriptItem]) -> Bool {
        for item in items.reversed() {
            switch item.kind {
            case .assistant(let text, _, _): return InterruptedTurn.parse(text) != nil
            case .user: return false
            default: continue
            }
        }
        return false
    }
}
#endif
