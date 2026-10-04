import Foundation
import VoryCore

/// Speaking: the one thing being read right now, started from a bubble's Speak
/// or by "Read replies aloud" when a reply finishes in the chat in front. One at a time: a new
/// one stops the last.
@MainActor
@Observable
final class VoiceCoordinator {
    static let shared = VoiceCoordinator()

    private(set) var speakingText: String?
    private(set) var lastError: String?
    private let player = VoicePlayer()
    private var task: Task<Void, Never>?
    private var observer: Any?

    var isSpeaking: Bool { speakingText != nil }
    func isSpeaking(_ text: String) -> Bool { speakingText == text }

    /// Speak this text, or stop if it is the one being spoken.
    func toggleSpeaking(_ text: String) {
        if isSpeaking(text) { stop() } else { speak(text) }
    }

    /// Reads a reply aloud through the engine of the active gateway (its providers or the
    /// device's), the markdown taken out first.
    func speak(_ markdown: String) {
        guard let engine = AppModel.shared.runtime?.voice else { lastError = "Connect a gateway first."; return }
        stop()
        let spoken = SpokenText.forSpeech(markdown)
        guard !spoken.isEmpty else { return }
        speakingText = markdown
        task = Task { [weak self] in
            do { try await self?.player.play(engine.speak(spoken)) }
            catch { self?.lastError = error.localizedDescription }
            if self?.speakingText == markdown { self?.speakingText = nil }
        }
    }

    /// Plays one chunk (a voice preview); stops whatever was being read.
    func play(_ chunk: AudioChunk) {
        stop()
        speakingText = "\u{200B}preview"
        task = Task { [weak self] in
            try? await self?.player.play(AsyncThrowingStream { c in c.yield(chunk); c.finish() })
            if self?.speakingText == "\u{200B}preview" { self?.speakingText = nil }
        }
    }

    /// The last finished reply in a chat: what "Speak Last Reply" reads.
    nonisolated static func lastReply(in items: [TranscriptItem]) -> String? {
        for item in items.reversed() {
            if case .assistant(let text, _, let streaming) = item.kind, !streaming {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    func stop() {
        AppModel.shared.runtime?.voice.stop()
        player.stop()
        task?.cancel(); task = nil
        speakingText = nil
    }

    /// "Read replies aloud": a reply that finished in the chat on screen is spoken.
    func observeReplies() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .hermesReplyCompleted, object: nil, queue: .main) { [weak self] n in
            guard VoiceSettings.readAloud, let id = n.userInfo?["storedID"] as? String, let text = n.userInfo?["text"] as? String else { return }
            Task { @MainActor in
                guard AppModel.shared.visibleChatID == id else { return }
                #if os(iOS)
                // Hands-free speaks its own replies: not twice.
                if HandsFreeSession.shared.isActive { return }
                #endif
                self?.speak(text)
            }
        }
    }
}
