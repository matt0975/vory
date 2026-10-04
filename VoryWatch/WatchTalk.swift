import AVFAudio
import Foundation
import VoryCore

/// Talk, on the wrist: hold nothing, tap the mic, say it, tap again. The recording goes to the
/// gateway's transcriber (the watch has no on-device one), the words go to the chat as a
/// spoken turn (short, plain answers), and the reply is read aloud by the watch's own voice.
/// One exchange at a time; no loop, no barge-in: that is the phone's job.
@MainActor
@Observable
final class WatchTalk {
    enum Phase: Equatable { case idle, recording, transcribing, waiting, speaking }
    private(set) var phase: Phase = .idle
    var error: String?
    /// What was heard, for the row under the mic.
    private(set) var heard: String?
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var startedAt: Date?
    private let synthesizer = AVSpeechSynthesizer()
    private let synthesizerDelegate = SpeechDelegate()
    private var stopTimer: Task<Void, Never>?
    static let maximumSeconds: TimeInterval = 30
    static let replyWait: TimeInterval = 180

    init() {
        synthesizer.delegate = synthesizerDelegate
        synthesizerDelegate.onDone = { [weak self] in Task { @MainActor in self?.spoke() } }
    }

    var isBusy: Bool { phase != .idle }

    var phaseText: String {
        switch phase {
        case .idle: return ""
        case .recording: return "Listening…"
        case .transcribing: return "Hearing…"
        case .waiting: return "Thinking…"
        case .speaking: return "Speaking"
        }
    }

    /// The mic tapped: start, or stop and send.
    func tap(chat: ChatSession) {
        switch phase {
        case .idle: start()
        case .recording: Task { await stopAndSend(chat: chat) }
        case .speaking: stopSpeaking()
        default: break
        }
    }

    private func start() {
        error = nil
        Task { [weak self] in
            guard await AVAudioApplication.requestRecordPermission() else { self?.error = "Microphone access denied."; return }
            guard let self else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
                try session.setActive(true)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("talk-\(UUID().uuidString).m4a")
                let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                               AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
                let r = try AVAudioRecorder(url: url, settings: settings)
                guard r.record() else { throw HermesAPIError.transport("The recorder would not start.") }
                self.recorder = r
                self.fileURL = url
                self.startedAt = Date()
                self.phase = .recording
                // A tap forgotten: the recording ends on its own.
                self.stopTimer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.maximumSeconds))
                    guard let self, !Task.isCancelled, self.phase == .recording else { return }
                    self.recorder?.stop()
                    self.error = "That was long; tap the mic and say it again."
                    self.cleanupRecording()
                    self.phase = .idle
                }
            } catch {
                self.error = error.localizedDescription
                self.phase = .idle
            }
        }
    }

    private func cleanupRecording() {
        stopTimer?.cancel(); stopTimer = nil
        recorder?.stop(); recorder = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        startedAt = nil
    }

    private func stopAndSend(chat: ChatSession) async {
        guard phase == .recording, let url = fileURL, let started = startedAt else { return }
        stopTimer?.cancel(); stopTimer = nil
        recorder?.stop(); recorder = nil
        guard Date().timeIntervalSince(started) > 0.4 else { cleanupRecording(); phase = .idle; return }
        phase = .transcribing
        defer { try? FileManager.default.removeItem(at: url); fileURL = nil; startedAt = nil }
        let api = GatewayVoiceAPI(api: chat.runtime.api, profile: chat.profileName)
        let words: String
        do {
            let data = try Data(contentsOf: url)
            let t = try await api.transcribe(data, mimeType: "audio/m4a")
            words = t.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            self.error = VoiceRouting.isNoProvider(error) ? "The gateway has no speech-to-text provider; type instead." : error.localizedDescription
            phase = .idle
            return
        }
        guard !words.isEmpty else { error = "Nothing was heard."; phase = .idle; return }
        heard = words
        phase = .waiting
        let waiter = ReplyWaiter(storedID: chat.storedID)
        if let problem = await chat.send(words, voice: VoiceTurn()) { waiter.stop(); error = problem; phase = .idle; return }
        guard let reply = await waiter.wait(seconds: Self.replyWait, chat: chat) else { phase = .idle; return }
        speak(SpokenText.forSpeech(reply))
    }

    /// The reply, read by the watch's best voice for the language.
    func speak(_ text: String) {
        guard !text.isEmpty else { phase = .idle; return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = DeviceSpeaker.voice(identifier: nil)
        phase = .speaking
        synthesizer.speak(utterance)
    }

    /// The utterance finished (or was cut): back to the mic.
    private func spoke() {
        guard phase == .speaking else { return }
        phase = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        spoke()
    }

    /// The synthesizer's end-of-speech callback, from whatever thread it uses.
    private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        var onDone: @Sendable () -> Void = {}
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { onDone() }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { onDone() }
    }

    /// The chat's next finished reply, or its turn ending without one.
    @MainActor
    final class ReplyWaiter {
        private var reply: String?
        private var observer: Any?
        private let storedID: String

        init(storedID: String) {
            self.storedID = storedID
            observer = NotificationCenter.default.addObserver(forName: .hermesReplyCompleted, object: nil, queue: .main) { [weak self] n in
                guard let id = n.userInfo?["storedID"] as? String, let text = n.userInfo?["text"] as? String else { return }
                Task { @MainActor in
                    guard let self, id == self.storedID else { return }
                    self.reply = text
                }
            }
        }

        func stop() {
            if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        }

        func wait(seconds: TimeInterval, chat: ChatSession) async -> String? {
            defer { stop() }
            let deadline = Date().addingTimeInterval(seconds)
            var sawRunning = false
            while Date() < deadline {
                if let reply { return reply }
                if chat.isRunning { sawRunning = true } else if sawRunning { return reply }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return reply
        }
    }
}
