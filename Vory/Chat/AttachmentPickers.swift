import AVFoundation
import Speech
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import VoryCore

#if os(iOS)
/// System camera capture. (The Mac imports from the iPhone through Continuity Camera later.)
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage, let data = img.jpegData(compressionQuality: 0.9) {
                parent.onImage(data, "camera-\(Int(Date().timeIntervalSince1970)).jpg")
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif

/// Voice memo recorder (AAC .m4a).
struct AudioRecorderSheet: View {
    var onFinished: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recorder: AVAudioRecorder?
    @State private var recording = false
    @State private var elapsed: TimeInterval = 0
    @State private var url: URL?
    @State private var error: String?
    @State private var timer: Timer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: recording ? "waveform.circle.fill" : "waveform.circle").font(.system(size: 72)).foregroundStyle(recording ? .red : .secondary)
                    .symbolEffect(.variableColor.iterative, isActive: recording)
                Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond))).font(.largeTitle.monospacedDigit())
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                HStack(spacing: 16) {
                    Button(recording ? "Stop" : "Record") { recording ? stop() : start() }.buttonStyle(.glassProminent).tint(recording ? .red : .accentColor)
                    if let url, !recording { Button("Attach") { onFinished(url); dismiss() }.buttonStyle(.glass) }
                }
            }
            .padding()
            .navigationTitle("Record Audio")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { stop(); dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private func start() {
        Task {
            guard await AVAudioApplication.requestRecordPermission() else { error = "Microphone access denied."; return }
            do {
                #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try session.setActive(true)
                #endif
                let u = FileManager.default.temporaryDirectory.appendingPathComponent("memo-\(Int(Date().timeIntervalSince1970)).m4a")
                let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
                let r = try AVAudioRecorder(url: u, settings: settings)
                r.record()
                recorder = r; url = u; recording = true; elapsed = 0
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in Task { @MainActor in elapsed = r.currentTime } }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func stop() {
        recorder?.stop(); recorder = nil; recording = false
        timer?.invalidate(); timer = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// Dictation for the composer: the mic records (the field shows the waveform), and when it
/// stops the recording is turned into words by the gateway's provider or this device's own,
/// as Settings › Voice says. The recording never outlives the transcription.
@MainActor
@Observable
final class DictationController {
    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private var fileURL: URL?
    var transcript = ""
    var isListening = false
    /// Between the stop and the words: the composer shows a spinner in the mic's slot.
    var isTranscribing = false
    var error: String?
    /// Recent loudness samples, newest last, for the waveform in the composer.
    var levels: [Float] = []
    var startedAt: Date?
    static let waveformSamples = 64

    func start() {
        Task {
            guard await AVAudioApplication.requestRecordPermission() else { error = "Microphone access denied."; return }
            do {
                #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                #endif
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).m4a")
                let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1,
                                               AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
                let r = try AVAudioRecorder(url: url, settings: settings)
                r.isMeteringEnabled = true
                guard r.record() else { throw HermesAPIError.transport("The recorder would not start.") }
                recorder = r; fileURL = url
                transcript = ""; levels = []; startedAt = Date(); isListening = true
                // Loudness for the waveform, twenty times a second: the average power in dB mapped to 0…1.
                meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let r = self.recorder, self.isListening else { return }
                        r.updateMeters()
                        let level = min(1, max(0, (r.averagePower(forChannel: 0) + 50) / 50))
                        self.levels.append(level)
                        if self.levels.count > Self.waveformSamples { self.levels.removeFirst(self.levels.count - Self.waveformSamples) }
                    }
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Stops the recording and turns it into words through `engine`; empty when nothing was heard.
    func stop(engine: VoiceEngine?) async -> String {
        meter?.invalidate(); meter = nil
        recorder?.stop(); recorder = nil
        isListening = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        guard let url = fileURL else { return "" }
        fileURL = nil
        defer { try? FileManager.default.removeItem(at: url) }
        guard let engine else { error = "Connect a gateway to dictate."; return "" }
        guard let started = startedAt, Date().timeIntervalSince(started) > 0.4 else { return "" }
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            transcript = try await engine.transcribe(file: url)
            if transcript.isEmpty { error = "Nothing was heard. Try again a little closer to the mic." }
        } catch {
            self.error = error.localizedDescription
            transcript = ""
        }
        return transcript
    }

    /// Drops a recording without transcribing it (the composer went away).
    func cancel() {
        meter?.invalidate(); meter = nil
        recorder?.stop(); recorder = nil
        isListening = false
        if let url = fileURL { try? FileManager.default.removeItem(at: url); fileURL = nil }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// The mic in the composer: a tap starts listening (the field becomes a waveform), the red stop
/// ends it and the transcript lands in the field. Messages' audio-message bar is the pattern.
/// With `onHold` (Settings › Voice › Hold the mic to: Start voice mode) a press held for
/// half a second starts voice mode instead; letting go then does nothing, and a tap still
/// dictates. Without it a hold is a tap: a button's own long press never beat it.
struct TalkButton: View {
    var dictation: DictationController
    var engine: VoiceEngine?
    var onHold: (() -> Void)? = nil
    var onTranscript: (String) -> Void
    /// The press became a hold: its release is not a tap.
    @State private var held = false

    var body: some View {
        if let onHold {
            face
                .contentShape(.circle)
                .onTapGesture { if held { held = false } else { tapped() } }
                .gesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in held = true; onHold() })
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { tapped() }
                .accessibilityAction(named: "Start voice mode") { onHold() }
                .accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate")
                .accessibilityHint(dictation.isListening ? "Stops listening and puts the words in the field" : "Records, then turns it into words as Settings › Voice says. Hold to start voice mode")
        } else {
            Button { tapped() } label: { face }
                .buttonStyle(.plain)
                .contentShape(.circle)
                .accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate")
                .accessibilityHint(dictation.isListening ? "Stops listening and puts the words in the field" : "Records, then turns it into words as Settings › Voice says")
        }
    }

    private func tapped() {
        if dictation.isListening {
            Task {
                let t = await dictation.stop(engine: engine)
                if !t.isEmpty { onTranscript(t) }
            }
        } else {
            dictation.start()
        }
    }

    @ViewBuilder private var face: some View {
        if dictation.isListening {
            ZStack {
                Circle().fill(.red)
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10)
            }
            .frame(width: 28, height: 28)
        } else {
            Image(systemName: "mic")
                .font(.body.weight(.medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
        }
    }
}

/// Live waveform while dictating: thin red bars, the newest at the right, sliding left as the
/// samples arrive, with the elapsed time beside them.
struct DictationWaveform: View {
    var dictation: DictationController

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                let count = DictationController.waveformSamples
                let step = geo.size.width / CGFloat(count)
                let levels = dictation.levels
                HStack(alignment: .center, spacing: 0) {
                    ForEach(0..<count, id: \.self) { i in
                        let idx = i - (count - levels.count)
                        let level = idx >= 0 && idx < levels.count ? CGFloat(levels[idx]) : 0
                        Capsule().fill(.red)
                            .frame(width: max(1.5, step * 0.45), height: max(3, 3 + level * (geo.size.height - 6)))
                            .frame(width: step)
                    }
                }
                .frame(height: geo.size.height)
            }
            .frame(height: 22)
            .animation(.linear(duration: 0.05), value: dictation.levels.count)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let s = Int(max(0, ctx.date.timeIntervalSince(dictation.startedAt ?? ctx.date)))
                Text(String(format: "%d:%02d", s / 60, s % 60)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Listening")
    }
}
