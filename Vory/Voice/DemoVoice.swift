import Foundation
import VoryCore

/// Demo mode's ears and voice in voice mode (#621): a scripted stand-in for the microphone and the speaker, with no
/// audio at all. It "hears" the person say the demo's line, word by word, with a waveform to match, and gives each
/// reply the time it would take to say while its words show. `HandsFreeSession` drives it with the loop's own events,
/// so the screens, the card and the controls are the real ones; nothing here asks for the microphone, opens an audio
/// session or makes a sound.
@MainActor
@Observable
final class DemoVoice {
    /// How long things take: as a person speaks and a bot reads aloud, or a tenth of that for the tests.
    struct Timing: Sendable, Equatable {
        var scale: Double
        static let real = Timing(scale: 1)
        static let quick = Timing(scale: 0.1)
        /// Quiet listening before the person starts.
        var lead: Double { 1.0 * scale }
        /// One word of the person's line.
        var heardWord: Double { 0.3 * scale }
        /// The pause that ends the person's turn, as Settings › Voice has it.
        var endOfTurn: Double { VoiceSettings.endOfTurn.rawValue * scale }
        /// "Got it…" before the words go.
        var transcribing: Double { 0.4 * scale }
        /// One word of a reply, said.
        var saidWord: Double { 0.32 * scale }
        /// How often a reply being said is looked at.
        var poll: Double { 0.05 * scale }
    }

    /// A reply as the demo says it: the words the speech filter lets through (what a real reply's caption shows), the
    /// same way a `SpeechStream` collects them, and no audio.
    @MainActor
    final class Saying {
        private var filter = SpokenText.Incremental()
        private(set) var text = ""
        private(set) var isFinished = false

        func send(delta: String) {
            guard !isFinished else { return }
            for piece in filter.feed(delta) { release(piece) }
        }

        func finish() {
            guard !isFinished else { return }
            isFinished = true
            for piece in filter.finish() { release(piece) }
        }

        private func release(_ piece: String) { text += (text.isEmpty ? "" : " ") + piece }
    }

    let timing: Timing
    /// Loudness for the waveform, newest last, on the listener's scale (0 to 1).
    private(set) var levels: [Float] = []
    /// The line as heard so far: the live caption.
    private(set) var words = ""
    private(set) var hearing = false
    /// The line is said once a session, the first time the loop listens.
    private(set) var lineHeard = false
    private(set) var isOpen = false
    /// A reply began to be said / was said to its end: the loop's audioStarted and audioFinished.
    var onSayingStarted: () -> Void = {}
    var onSayingEnded: () -> Void = {}

    private var tick: Task<Void, Never>?
    private var hearTask: Task<Void, Never>?
    private var afterTask: Task<Void, Never>?
    private var sayTask: Task<Void, Never>?
    private var sayings: [Saying] = []
    private var seed: UInt64 = 621
    private var ticks = 0

    init(timing: Timing = .real) { self.timing = timing }

    // MARK: The ears

    /// The loop opens the microphone: the waveform runs at a quiet room's level, and the line can be heard.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        tick = Task { [weak self] in
            while !Task.isCancelled, let self {
                self.sample()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// The loop closes it (muted, paused, ended): a line half heard is dropped, and heard again next time.
    func close() {
        guard isOpen else { return }
        isOpen = false
        tick?.cancel(); tick = nil
        cancelHearing()
    }

    /// The person says the line, if it has not been said: a moment's quiet, its words one by one with the waveform up,
    /// then the end-of-turn pause. `started` and `ended` are the loop's speechStarted and speechEnded.
    func hearLineIfDue(started: @escaping @MainActor () -> Void, ended: @escaping @MainActor () -> Void) {
        guard isOpen, !lineHeard, hearTask == nil else { return }
        let line = DemoGateway.voiceLine.split(separator: " ").map(String.init)
        hearTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.timing.lead))
            guard !Task.isCancelled, self.isOpen else { return }
            self.hearing = true
            self.words = ""
            started()
            for i in line.indices {
                self.words = line[...i].joined(separator: " ")
                try? await Task.sleep(for: .seconds(self.timing.heardWord))
                if Task.isCancelled { return }
            }
            self.hearing = false
            try? await Task.sleep(for: .seconds(self.timing.endOfTurn))
            guard !Task.isCancelled else { return }
            self.hearTask = nil
            self.lineHeard = true
            ended()
        }
    }

    /// The capture is dropped (muted mid-word, a card): the line will be heard again.
    func cancelHearing() {
        hearTask?.cancel(); hearTask = nil
        hearing = false
        words = ""
    }

    /// The words heard for the turn that just ended, and a clean caption for the next.
    func takeWords() -> String {
        defer { words = "" }
        return lineHeard ? DemoGateway.voiceLine : words
    }

    /// "Got it…" for a moment, then the words go.
    func afterTranscribing(_ then: @escaping @MainActor () -> Void) {
        afterTask?.cancel()
        afterTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.timing.transcribing))
            guard !Task.isCancelled else { return }
            self.afterTask = nil
            then()
        }
    }

    /// One waveform sample: speech while the line is heard, else the room.
    private func sample() {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        ticks += 1
        let jitter = Float(seed >> 40) / Float(1 << 24)
        let level: Float
        if hearing {
            // Syllables: a rise and fall about five times a second, never quite to silence.
            let t = Float(ticks % 20) / 20
            level = 0.35 + 0.45 * abs(sin(t * .pi * 2)) + 0.15 * jitter
        } else {
            level = 0.05 + 0.04 * jitter
        }
        levels.append(min(1, level))
        if levels.count > UtteranceListener.waveformSamples { levels.removeFirst(levels.count - UtteranceListener.waveformSamples) }
    }

    // MARK: The voice

    /// Says the reply after whatever is being said, as the real player plays one stream after another: started when it
    /// has words, ended once it is finished and its words have had their time. A reply with nothing to say ends at once.
    func say(_ saying: Saying) {
        sayings.append(saying)
        guard sayTask == nil else { return }
        sayTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.sayings.isEmpty {
                let s = self.sayings.removeFirst()
                var startedAt: Date?
                while !Task.isCancelled {
                    if startedAt == nil, !s.text.isEmpty { startedAt = Date(); self.onSayingStarted() }
                    if s.isFinished {
                        guard let at = startedAt else { break }
                        let words = s.text.split(whereSeparator: \.isWhitespace).count
                        if Date().timeIntervalSince(at) >= Double(words) * self.timing.saidWord { break }
                    }
                    try? await Task.sleep(for: .seconds(self.timing.poll))
                }
                if Task.isCancelled { return }
                self.onSayingEnded()
            }
            self?.sayTask = nil
        }
    }

    /// Stops what is being said and what waits (barge-in, a pause, End).
    func stopSaying() {
        sayTask?.cancel(); sayTask = nil
        sayings = []
    }

    /// The session ended: everything stops.
    func stop() {
        close()
        stopSaying()
        afterTask?.cancel(); afterTask = nil
    }
}
