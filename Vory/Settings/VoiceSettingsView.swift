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
    @AppStorage(VoiceSettings.bargeInKey) private var bargeIn = true
    @AppStorage(VoiceSettings.endOfTurnKey) private var endOfTurn = 0.8
    @AppStorage(VoiceSettings.conversationKey) private var conversationRaw = ConversationMode.automatic.rawValue
    @AppStorage(VoiceSettings.liveProviderKey) private var liveProviderRaw = LiveProvider.gemini.rawValue
    @AppStorage(VoiceSettings.geminiVoiceKey) private var geminiVoice = GeminiLive.defaultVoice
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var personalVoice: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus = .notDetermined
    /// The key lives in the Keychain; this is the field's copy.
    @State private var geminiKey = ""
    @State private var keyStatus: String?
    @State private var checkingKey = false
    @State private var gatewayLive: GatewayVoiceAPI.LiveStatus?
    @State private var gatewayLiveError: String?

    private var speech: SpeechSource { SpeechSource(rawValue: speechRaw) ?? .automatic }
    private var engine: VoiceEngine? { model.runtime?.voice }
    private var conversation: ConversationMode { ConversationMode(rawValue: conversationRaw) ?? .automatic }
    private var liveProvider: LiveProvider { LiveProvider(rawValue: liveProviderRaw) ?? .gemini }

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
                Picker("Pause that ends your turn", selection: $endOfTurn) {
                    ForEach(VoiceSettings.EndOfTurn.allCases) { p in Text(p.title).tag(p.rawValue) }
                }
                Toggle("Talking over the bot stops it", isOn: $bargeIn)
            } header: { Text("Voice mode") } footer: {
                Text("Voice mode is in a chat's + menu, or hold the mic. Standard listens, sends what you said when you pause, speaks the reply, and listens again. Approvals are never taken by voice: the card shows on screen and it waits.")
            }
            Section {
                Picker("Conversation", selection: $conversationRaw) {
                    ForEach(ConversationMode.allCases) { m in Text(m.title).tag(m.rawValue) }
                }
                Picker("Live provider", selection: $liveProviderRaw) {
                    ForEach(LiveProvider.allCases) { p in Text(p.title).tag(p.rawValue) }
                }
            } header: { Text("Live voice") } footer: {
                Text("Live is a real back-and-forth with a lifelike voice: a voice model of your own listens and talks, and hands every real request to the bot. Automatic uses Live when your provider is ready, otherwise Standard. Live is billed by your provider to you: Gemini on your key, OpenAI on your gateway's key (about five cents a minute).")
            }
            if liveProvider == .gemini {
                Section {
                    SecureField("Gemini API key", text: $geminiKey)
                        .textContentType(.password).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onChange(of: geminiKey) { _, v in GeminiLive.Key.value = v; keyStatus = nil }
                    HStack {
                        Button { checkKey() } label: { Label(checkingKey ? "Checking…" : "Check key", systemImage: "checkmark.seal") }
                            .disabled(geminiKey.trimmingCharacters(in: .whitespaces).isEmpty || checkingKey)
                        Spacer()
                        if let keyStatus { Text(keyStatus).font(.caption).foregroundStyle(keyStatus == "OK" ? .green : .orange).multilineTextAlignment(.trailing) }
                    }
                    Link(destination: GeminiLive.Key.getURL) { Label("Get a key at Google AI Studio", systemImage: "arrow.up.right.square") }
                    Picker("Voice", selection: $geminiVoice) {
                        ForEach(GeminiLive.voices, id: \.name) { v in Text("\(v.name) · \(v.character)").tag(v.name) }
                    }
                    Button { previewVoice() } label: { Label(VoiceCoordinator.shared.isSpeaking ? "Stop" : "Preview the voice", systemImage: VoiceCoordinator.shared.isSpeaking ? "stop.circle" : "play.circle") }
                        .disabled(geminiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: { Text("Gemini") } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your key stays in your Keychain (and your iCloud Keychain, so your other devices have it). It is sent to Google only, never to the gateway or anyone else.")
                        Text(GeminiLive.Key.freeTierNote)
                        Link("Google's terms", destination: GeminiLive.Key.termsURL)
                    }
                }
            } else {
                Section {
                    if let s = gatewayLive {
                        LabeledContent("On your gateway", value: s.available ? "Ready" : "Not available")
                        if s.available, let m = s.model { LabeledContent("Model", value: m) }
                        if s.available, let v = s.voice { LabeledContent("Voice", value: v) }
                    } else if let gatewayLiveError {
                        Text(gatewayLiveError).foregroundStyle(.orange)
                    } else {
                        LabeledContent("On your gateway", value: "Checking…")
                    }
                } header: { Text("OpenAI") } footer: {
                    Text((gatewayLive?.available == false ? ((gatewayLive?.reason).map { "The gateway says: \($0). " } ?? "") : "")
                         + "OpenAI's live voice runs through your gateway, which holds the key; the gateway's config picks the voice. Vory's OpenAI Live comes in a later build; until then Live falls back to Standard.")
                }
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
            geminiKey = GeminiLive.Key.value ?? ""
            await loadGatewayLive()
        }
    }

    private func checkKey() {
        let key = geminiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        checkingKey = true
        Task {
            switch await GeminiLive.Key.check(key) {
            case .success: keyStatus = "OK"
            case .failure(let f): keyStatus = f.message
            }
            checkingKey = false
        }
    }

    private func previewVoice() {
        if VoiceCoordinator.shared.isSpeaking { VoiceCoordinator.shared.stop(); return }
        let key = geminiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        Task {
            do { VoiceCoordinator.shared.play(try await GeminiLive.Key.preview(voice: geminiVoice, key: key)) }
            catch { keyStatus = error.localizedDescription }
        }
    }

    private func loadGatewayLive() async {
        guard let rt = model.runtime else { return }
        do { gatewayLive = try await GatewayVoiceAPI(api: rt.api, profile: rt.selectedProfile).liveStatus() }
        catch { gatewayLiveError = "The gateway did not answer about live voice: \(error.localizedDescription)" }
    }

    static func name(of v: AVSpeechSynthesisVoice) -> String {
        var tags: [String] = []
        if v.voiceTraits.contains(.isPersonalVoice) { tags.append("Personal Voice") }
        switch v.quality { case .premium: tags.append("Premium"); case .enhanced: tags.append("Enhanced"); default: break }
        return tags.isEmpty ? v.name : "\(v.name) · \(tags.joined(separator: ", "))"
    }
}
