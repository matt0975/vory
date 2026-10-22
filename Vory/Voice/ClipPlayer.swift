import AVFAudio
import AVFoundation
import Observation

/// The in-chat voice note: one shared player, one clip at a time, with the position kept for
/// the row that draws it. Read-aloud and voice mode stop it by playing through `VoicePlayer`.
@MainActor
@Observable
final class ClipPlayer {
    static let shared = ClipPlayer()
    private(set) var refID: String?
    private(set) var name = ""
    private(set) var isPlaying = false
    private(set) var current = 0.0
    private(set) var duration = 0.0
    private(set) var failure: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: Any?
    private var failureObserver: Any?

    private init() {}

    func toggle(ref: String, file: URL, name: String) {
        if refID != ref {
            load(ref: ref, file: file, name: name)
            play()
        } else if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard let player else { return }
        VoiceCoordinator.shared.stop()
        beginSession()
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
        endSession()
    }

    func stop() {
        pause()
        player?.seek(to: .zero)
        if let o = timeObserver, let player { player.removeTimeObserver(o) }
        timeObserver = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
        if let o = failureObserver { NotificationCenter.default.removeObserver(o) }
        failureObserver = nil
        refID = nil
        name = ""
        current = 0
        duration = 0
        failure = nil
        player = nil
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let s = seconds.isFinite ? seconds : 0
        let target = duration > 0 ? min(max(s, 0), duration) : 0
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        current = target
    }

    private func load(ref: String, file: URL, name: String) {
        stop()
        let item = AVPlayerItem(url: file)
        let player = AVPlayer(playerItem: item)
        self.player = player
        refID = ref
        self.name = name
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { @Sendable [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.tick(seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reachedEnd() }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.failed() }
        }
        Task { [weak self] in
            let seconds = try? await item.asset.load(.duration).seconds
            // The clip may have been replaced (or stopped) while the asset loaded.
            guard let self, self.refID == ref, let seconds, seconds.isFinite, seconds > 0 else { return }
            self.duration = seconds
        }
    }

    private func tick(_ seconds: Double) {
        current = seconds.isFinite ? max(0, seconds) : 0
    }

    private func reachedEnd() {
        guard let player else { return }
        player.pause()
        player.seek(to: .zero)
        current = 0
        isPlaying = false
        endSession()
    }

    private func failed() {
        failure = "Could not play \(name)."
        isPlaying = false
    }

    private func beginSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }

    private func endSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// "0:07", "1:07", "1:02:03"; negative, NaN or infinite reads "0:00".
enum ClipTime {
    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}