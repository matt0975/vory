import AVFAudio
import Foundation
import VoryCore

/// Where Talk sends the words and hears the reply from: the live chat on the watch's own
/// socket, or the iPhone when the watch has none (the usual case on a real watch).
@MainActor
enum TalkTarget {
    case live(ChatSession)
    case phone(PhoneTalk)

    var api: HermesAPI {
        switch self { case .live(let c): return c.runtime.api; case .phone(let p): return p.runtime.api }
    }
    var profile: String? {
        switch self { case .live(let c): return c.profileName; case .phone(let p): return p.profile }
    }
}

/// Talk through the iPhone: the words go to the phone as a spoken turn, and the reply is read
/// from the chat's history once the turn is over (the watch has no socket to stream it).
@MainActor
struct PhoneTalk {
    let model: WatchModel
    let runtime: GatewayRuntime
    let storedID: String
    let profile: String?

    /// A problem to show, or nil when the phone took it.
    func send(_ words: String) async -> String? {
        do {
            let r = try await model.askPhone(["op": "prompt", "session": storedID, "profile": profile ?? "", "text": words, "voice": true])
            return r["ok"] as? Bool == true ? nil : (r["error"] as? String ?? "The phone could not send it.")
        } catch { return error.localizedDescription }
    }

    /// The reply to `words`, once the turn has finished; nil when it did not come in time or
    /// the wait was given up.
    func reply(to words: String, sentAt: Date, seconds: TimeInterval, cancelled: @escaping @MainActor () -> Bool) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        var sawRunning = false
        var misses = 0
        while Date() < deadline, !cancelled() {
            try? await Task.sleep(for: .seconds(2))
            guard !cancelled() else { return nil }
            let state = try? await model.askPhone(["op": "cards", "session": storedID, "profile": profile ?? ""])
            let running = state?["running"] as? Bool ?? true
            if running { sawRunning = true; misses = 0; continue }
            // Finished (or never seen running after a while: a quick turn ended between polls).
            guard sawRunning || Date().timeIntervalSince(sentAt) > 8 else { continue }
            if let text = await latestReply(to: words, sentAt: sentAt) { return cancelled() ? nil : text }
            // Over with no reply (stopped, failed): a few reads for the gateway to store the
            // row, then the wait ends instead of saying "Thinking…" for three minutes.
            misses += 1
            if misses >= 3 { return nil }
        }
        return nil
    }

    private func latestReply(to words: String, sentAt: Date) async -> String? {
        guard let r: JSONValue = try? await runtime.api.get("/api/sessions/\(storedID)/messages", query: [URLQueryItem(name: "order", value: "latest"), URLQueryItem(name: "limit", value: "8")], profile: profile ?? runtime.selectedProfile) else { return nil }
        let msgs = (r["messages"]?.arrayValue ?? r.arrayValue ?? []).compactMap { try? $0.decode(TranscriptMessage.self) }
        // The gateway's own "interrupted" notice is not the bot's answer: it is never read aloud.
        let items = TranscriptItem.fromHistory(msgs).filter { item in
            if case .assistant(let t, _, _) = item.kind { return InterruptedTurn.parse(t) == nil }
            return true
        }.sorted { $0.timestamp < $1.timestamp }
        return TranscriptItem.reply(in: items, to: words, sentAt: sentAt)
    }
}

/// Talk, on the wrist: hold nothing, tap the mic, say it, tap again. The recording goes to the
/// gateway's transcriber (the watch has no on-device one), the words go to the chat as a
/// spoken turn (short, plain answers), and the reply is read aloud by the watch's own voice.
/// One exchange at a time; no loop, no barge-in: that is the phone's job. It works on the live
/// chat and, without a socket, through the iPhone.
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
    /// The wait for the reply, while there is one; the mic button gives it up.
    private var waiter: ReplyWaiter?
    /// The phone path's wait, given up by the same button.
    private var phoneWaitCancelled = false
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

    /// The mic tapped: start, stop and send, give up the wait, or stop the voice.
    func tap(target: TalkTarget) {
        switch phase {
        case .idle: start()
        case .recording: Task { await stopAndSend(target: target) }
        case .waiting: stopWaiting()
        case .speaking: stopSpeaking()
        default: break
        }
    }

    /// The wait for the reply given up: it lands in the chat when it comes, unspoken. (Before,
    /// only the header's Stop or the 180 s limit ended the wait.)
    func stopWaiting() { waiter?.cancel(); phoneWaitCancelled = true }

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

    private func stopAndSend(target: TalkTarget) async {
        guard phase == .recording, let url = fileURL, let started = startedAt else { return }
        stopTimer?.cancel(); stopTimer = nil
        recorder?.stop(); recorder = nil
        guard Date().timeIntervalSince(started) > 0.4 else { cleanupRecording(); phase = .idle; return }
        phase = .transcribing
        defer { try? FileManager.default.removeItem(at: url); fileURL = nil; startedAt = nil }
        let api = GatewayVoiceAPI(api: target.api, profile: target.profile)
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
        let reply: String?
        switch target {
        case .live(let chat):
            let waiter = ReplyWaiter(storedID: chat.storedID)
            self.waiter = waiter
            defer { self.waiter = nil }
            if let problem = await chat.send(words, voice: VoiceTurn()) { waiter.stop(); error = problem; phase = .idle; return }
            reply = await waiter.wait(seconds: Self.replyWait, chat: chat)
        case .phone(let p):
            phoneWaitCancelled = false
            let sentAt = Date()
            if let problem = await p.send(words) { error = problem; phase = .idle; return }
            reply = await p.reply(to: words, sentAt: sentAt, seconds: Self.replyWait) { [weak self] in self?.phoneWaitCancelled ?? true }
        }
        guard let reply else { phase = .idle; return }
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
        private(set) var cancelled = false

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

        /// Ends the wait with nothing: the reply, if it comes, stays in the chat.
        func cancel() { cancelled = true }

        func wait(seconds: TimeInterval, chat: ChatSession) async -> String? {
            defer { stop() }
            let deadline = Date().addingTimeInterval(seconds)
            var sawRunning = false
            while Date() < deadline, !cancelled {
                if let reply { return reply }
                if chat.isRunning { sawRunning = true } else if sawRunning { return reply }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return cancelled ? nil : reply
        }
    }
}
