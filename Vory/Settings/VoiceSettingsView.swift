import SwiftUI
import AVFAudio
import VoryCore

/// Settings › Voice: where speech is handled, what is read aloud, and the voice on this device.
struct VoiceSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(VoiceSettings.speechKey) private var speechRaw = SpeechSource.automatic.rawValue
    @AppStorage(VoiceSettings.readAloudKey) private var readAloud = false
    @AppStorage(VoiceSettings.sendAfterDictationKey) private var sendAfterDictation = false
    @AppStorage(VoiceSettings.deviceVoiceKey) private var deviceVoice = ""
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var personalVoice: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus = .notDetermined

    private var speech: SpeechSource { SpeechSource(rawValue: speechRaw) ?? .automatic }
    private var engine: VoiceEngine? { model.runtime?.voice }

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Voice", symbol: "waveform", color: .pink,
                                  description: "Dictate messages and have replies read aloud, with the gateway's speech providers or \(DeviceWords.this)'s own.")
            Section {
                Picker("Speech", selection: $speechRaw) {
                    ForEach(SpeechSource.allCases) { s in Text(s.title).tag(s.rawValue) }
                }
                .pickerStyle(.inline).labelsHidden()
            } header: { Text("Speech") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(speech.blurb)
                    if let e = engine, e.lastSTT != nil || e.lastTTS != nil {
                        Text([e.lastSTT.map { "Last dictation: \($0)" }, e.lastTTS.map { "Last speech: \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    if let err = engine?.lastError { Text(err).foregroundStyle(.orange) }
                }
            }
            Section {
                Toggle("Read replies aloud", isOn: $readAloud)
                Toggle("Send after dictation", isOn: $sendAfterDictation)
            } header: { Text("Chats") } footer: {
                Text("Read replies aloud speaks each reply as it finishes in the chat you have open. Send after dictation sends what you dictated as soon as it is in words, with nothing to tap.")
            }
            Section {
                Picker("Voice", selection: $deviceVoice) {
                    Text("Automatic").tag("")
                    ForEach(voices, id: \.identifier) { v in
                        Text(Self.name(of: v)).tag(v.identifier)
                    }
                }
                if personalVoice != .authorized {
                    Button {
                        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in Task { @MainActor in personalVoice = status; voices = DeviceSpeaker.voices() } }
                    } label: { Label("Allow Personal Voice", systemImage: "person.wave.2") }
                    .disabled(personalVoice == .denied || personalVoice == .unsupported)
                }
                Button {
                    VoiceCoordinator.shared.toggleSpeaking("Hi, this is how I sound on \(DeviceWords.this).")
                } label: { Label(VoiceCoordinator.shared.isSpeaking ? "Stop" : "Try the voice", systemImage: VoiceCoordinator.shared.isSpeaking ? "stop.circle" : "play.circle") }
            } header: { Text("Voice on \(DeviceWords.this)") } footer: {
                Text(personalVoice == .denied ? "Personal Voice is off for Vory in Settings › Accessibility › Personal Voice."
                     : "Used when speech is handled on \(DeviceWords.this). Automatic picks the best installed voice for your language; a Personal Voice comes first once it is allowed.")
            }
        }
        .task {
            voices = DeviceSpeaker.voices()
            personalVoice = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        }
    }

    static func name(of v: AVSpeechSynthesisVoice) -> String {
        var tags: [String] = []
        if v.voiceTraits.contains(.isPersonalVoice) { tags.append("Personal Voice") }
        switch v.quality { case .premium: tags.append("Premium"); case .enhanced: tags.append("Enhanced"); default: break }
        return tags.isEmpty ? v.name : "\(v.name) · \(tags.joined(separator: ", "))"
    }
}
