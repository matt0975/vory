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

/// Owns the audio engine and the recognition request, deliberately outside any actor: AVFAudio and
/// Speech call back on their own queues, and a closure formed inside a @MainActor method inherits
/// that isolation and traps at runtime — both TestFlight crashes on the mic button were exactly that.
private final class DictationPipeline: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?

    func start(recognizer: SFSpeechRecognizer, onUpdate: @escaping @Sendable (String?, Bool) -> Void, onLevel: @escaping @Sendable (Float) -> Void = { _ in }) throws {
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        let req = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
            // Loudness of this slice for the waveform: RMS of the first channel, mapped to 0...1.
            if let ch = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
                let db = 20 * log10(max(rms, 1e-6))
                onLevel(min(1, max(0, (db + 50) / 50)))
            }
        }
        engine.prepare()
        try engine.start()
        task = recognizer.recognitionTask(with: req) { result, err in
            onUpdate(result?.bestTranscription.formattedString, err != nil)
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request.endAudio()
        task?.finish()
        task = nil
    }
}

/// On-device speech recognition for hold-to-talk.
@MainActor
@Observable
final class DictationController {
    private var pipeline: DictationPipeline?
    var transcript = ""
    var isListening = false
    var error: String?
    /// Recent loudness samples, newest last, for the waveform in the composer.
    var levels: [Float] = []
    var startedAt: Date?
    static let waveformSamples = 64

    /// TCC invokes the completion on a private queue; built outside any actor for the same reason
    /// as `DictationPipeline`.
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in c.resume(returning: status) }
        }
    }

    func start() {
        Task {
            let auth = await Self.requestSpeechAuthorization()
            guard auth == .authorized else { error = "Speech recognition not authorized."; return }
            guard await AVAudioApplication.requestRecordPermission() else { error = "Microphone access denied."; return }
            guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
                error = "Speech recognizer unavailable."; return
            }
            do {
                #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                #endif
                transcript = ""
                let pipe = DictationPipeline()
                pipeline = pipe
                try pipe.start(recognizer: recognizer, onUpdate: { [weak self] text, failed in
                    Task { @MainActor in
                        guard let self else { return }
                        if let text { self.transcript = text }
                        if failed {
                            // Said, not swallowed: the mic turned itself off with nothing to show.
                            if self.transcript.isEmpty { self.error = "Speech recognition stopped before it heard anything. Check Settings › Vory › Speech Recognition, or try again." }
                            self.stop()
                        }
                    }
                }, onLevel: { [weak self] level in
                    Task { @MainActor in
                        guard let self, self.isListening else { return }
                        self.levels.append(level)
                        if self.levels.count > Self.waveformSamples { self.levels.removeFirst(self.levels.count - Self.waveformSamples) }
                    }
                })
                levels = []
                startedAt = Date()
                isListening = true
            } catch { self.error = error.localizedDescription }
        }
    }

    func stop() {
        pipeline?.stop()
        pipeline = nil
        isListening = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// The mic in the composer: a tap starts listening (the field becomes a waveform), the red stop
/// ends it and the transcript lands in the field. Messages' audio-message bar is the pattern.
struct TalkButton: View {
    var dictation: DictationController
    var onTranscript: (String) -> Void

    var body: some View {
        Button {
            if dictation.isListening {
                dictation.stop()
                let t = dictation.transcript
                if !t.isEmpty { onTranscript(t) }
            } else {
                dictation.start()
            }
        } label: {
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
        .buttonStyle(.plain)
        .contentShape(.circle)
        .accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate")
        .accessibilityHint(dictation.isListening ? "Stops listening and puts the words in the field" : "Listens with on-device speech recognition")
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
