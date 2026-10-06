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
    @AppStorage(VoiceSettings.quickAnswersKey) private var quickAnswers = true
    @AppStorage(VoiceSettings.holdMicKey) private var holdMicRaw = VoiceSettings.HoldMicAction.dictate.rawValue
    @AppStorage(VoiceSettings.lastSessionKey) private var lastSession = ""
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var personalVoice: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus = .notDetermined
    /// The key lives in the Keychain; this is the field's copy while one is being entered.
    @State private var geminiKey = ""
    @State private var savedKeySuffix: String?
    @State private var editingKey = false
    @State private var keyStatus: ActionStatus?
    @State private var previewStatus: ActionStatus?
    @State private var checkingKey = false
    @State private var previewing = false

    /// One action's outcome: a sentence, and Google's own words when there were some.
    struct ActionStatus { var headline: String; var ok: Bool; var raw: String? }
    @State private var gatewayLive: GatewayVoiceAPI.LiveStatus?
    @State private var gatewayLiveError: String?

    /// Where voice mode starts from, in this platform's words.
    static var voiceModeWhere: String {
        #if os(macOS)
        "Voice mode is in the Chat menu (⇧⌘V), the Voice Chat button over the chat list, or a chat's + panel."
        #else
        UserDefaults.standard.object(forKey: VoryTabBar.showVoiceKey) as? Bool ?? true
            ? "Voice mode is in a chat's + panel and the mic beside the compose button; with Hold the mic to set to Start voice mode, holding a chat's mic starts it too."
            : "Voice mode is in a chat's + panel; with Hold the mic to set to Start voice mode, holding a chat's mic starts it too."
        #endif
    }
    private var speech: SpeechSource { SpeechSource(rawValue: speechRaw) ?? .automatic }
    private var engine: VoiceEngine? { model.runtime?.voice }
    private var conversation: ConversationMode { ConversationMode(rawValue: conversationRaw) ?? .automatic }
    private var liveProvider: LiveProvider { VoiceSettings.provider(stored: liveProviderRaw) }

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
                #if os(iOS)
                Picker("Hold the mic to", selection: $holdMicRaw) {
                    ForEach(VoiceSettings.HoldMicAction.allCases) { a in Text(a.title).tag(a.rawValue) }
                }
                #endif
            } header: { Text("Chats") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Read replies aloud speaks each reply as it finishes in the chat you have open. Send after dictation sends what you dictated as soon as it is in words, with nothing to tap.")
                    #if os(iOS)
                    Text("Hold the mic to: a tap on the composer's mic always dictates into the field; Dictate makes a hold do the same, Start voice mode makes a hold open the whole conversation by voice on that chat, as the + panel does.")
                    #endif
                }
            }
            Section {
                Picker("Pause that ends your turn", selection: $endOfTurn) {
                    ForEach(VoiceSettings.EndOfTurn.allCases) { p in Text(p.title).tag(p.rawValue) }
                }
                Toggle("Talking over the bot stops it", isOn: $bargeIn)
                Toggle("Quick answers", isOn: $quickAnswers)
            } header: { Text("Voice mode") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.voiceModeWhere + " Standard listens, sends what you said when you pause, speaks the reply, and listens again. Approvals are never taken by voice: the card shows on screen and it waits.")
                    Text("Quick answers make voice replies come faster with less deep reasoning: while voice mode runs, that chat thinks at low effort with fast replies on, and goes back to its own settings after. Turn it off here, or ask the bot to take its time.")
                    #if os(iOS)
                    // The phone's audio session (category, route, the silent switch's doing); a Mac has none.
                    if !lastSession.isEmpty { Text("Last voice session: \(lastSession)").font(.caption2) }
                    #endif
                }
            }
            Section {
                Picker("Conversation", selection: $conversationRaw) {
                    ForEach(ConversationMode.allCases) { m in Text(m.title).tag(m.rawValue) }
                }
                // A provider not built yet is listed greyed out ("coming later") and cannot be
                // picked; a choice of it synced from another device still resolves to one offered.
                // A menu of buttons, not a Picker: a disabled Picker option looked like any other
                // on the Mac.
                LabeledContent("Live provider") {
                    Menu {
                        ForEach(LiveProvider.listed) { p in
                            Button { liveProviderRaw = p.rawValue } label: {
                                if p == liveProvider { Label(p.menuTitle, systemImage: "checkmark") } else { Text(p.menuTitle) }
                            }
                            .disabled(!p.isOffered)
                        }
                    } label: {
                        Text(liveProvider.menuTitle)
                    }
                    .fixedSize()
                    .accessibilityIdentifier("voice.liveProvider")
                }
            } header: { Text("Live voice") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live is a real back-and-forth with a lifelike voice: a voice model of your own listens and talks, and hands every real request to the bot. Automatic uses Live when your Gemini key is saved, otherwise Standard. Live runs on your own Gemini key, billed to you by Google.")
                    if LiveProvider.comingLater.contains(.openai) { Text("OpenAI Live through your gateway is coming in a later update.") }
                }
            }
            if liveProvider == .gemini {
                Section {
                    // A saved key is shown as saved (a tester could not tell one was there), with
                    // Change and Remove; the field only while one is being entered.
                    if let suffix = savedKeySuffix, !editingKey {
                        LabeledContent("Gemini API key") { Text("Saved · ends in ••\(suffix)").foregroundStyle(.secondary) }
                        HStack {
                            Button("Change") { geminiKey = ""; editingKey = true }
                            Spacer()
                            Button("Remove", role: .destructive) { GeminiLive.Key.value = nil; savedKeySuffix = nil; geminiKey = ""; keyStatus = nil; previewStatus = nil }
                        }
                    } else {
                        SecureField("Gemini API key", text: $geminiKey)
                            .textContentType(.password).autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .onSubmit { saveKey() }
                        HStack {
                            Button("Save key") { saveKey() }.disabled(geminiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                            Spacer()
                            if savedKeySuffix != nil { Button("Cancel") { editingKey = false; geminiKey = "" } }
                        }
                    }
                    // Each action shows its own result: the key check's next to Check key, the
                    // preview's next to Preview, Google's prose behind Details.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Button { checkKey() } label: { Label(checkingKey ? "Checking…" : "Check key", systemImage: "checkmark.seal") }
                                .disabled(savedKeySuffix == nil || checkingKey)
                            Spacer()
                            if let keyStatus { Text(keyStatus.headline).font(.caption).foregroundStyle(keyStatus.ok ? Color.green : Color.orange).multilineTextAlignment(.trailing) }
                        }
                        if let raw = keyStatus?.raw { ActionDetails(raw: raw) }
                    }
                    Link(destination: GeminiLive.Key.getURL) { Label("Get a key at Google AI Studio", systemImage: "arrow.up.right.square") }
                    Picker("Voice", selection: $geminiVoice) {
                        ForEach(GeminiLive.voices, id: \.name) { v in Text("\(v.name) · \(v.character)").tag(v.name) }
                    }
                    // Another voice picked mid-sample: the sample stops before the next can start.
                    .onChange(of: geminiVoice) { _, _ in VoiceCoordinator.shared.stop() }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            // While a sample plays the button says so and takes no second tap, so
                            // two samples can never sound at once (#239).
                            Button { previewVoice() } label: {
                                if VoiceCoordinator.shared.isSpeaking {
                                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Playing…") }
                                } else {
                                    Label(previewing ? "Fetching…" : "Preview the voice", systemImage: "play.circle")
                                }
                            }
                            .disabled(savedKeySuffix == nil || previewing || VoiceCoordinator.shared.isSpeaking)
                            Spacer()
                            if let previewStatus { Text(previewStatus.headline).font(.caption).foregroundStyle(previewStatus.ok ? Color.secondary : Color.orange).multilineTextAlignment(.trailing) }
                        }
                        if let raw = previewStatus?.raw { ActionDetails(raw: raw) }
                    }
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
                .onChange(of: deviceVoice) { _, _ in VoiceCoordinator.shared.stop() }
                if personalVoice != .authorized {
                    Button {
                        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in Task { @MainActor in personalVoice = status; voices = DeviceSpeaker.voices() } }
                    } label: { Label("Allow Personal Voice", systemImage: "person.wave.2") }
                    .disabled(personalVoice == .denied || personalVoice == .unsupported)
                }
                Button {
                    VoiceCoordinator.shared.speak("Hi, this is how I sound on \(DeviceWords.this).")
                } label: {
                    if VoiceCoordinator.shared.isSpeaking { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Playing…") } }
                    else { Label("Try the voice", systemImage: "play.circle") }
                }
                .disabled(VoiceCoordinator.shared.isSpeaking)
            } header: { Text("Voice on \(DeviceWords.this)") } footer: {
                Text(personalVoice == .denied ? "Personal Voice is off for Vory in Settings › Accessibility › Personal Voice."
                     : "Used when speech is handled on \(DeviceWords.this). Automatic picks the best installed voice for your language; a Personal Voice comes first once it is allowed.")
            }
        }
        .task {
            voices = DeviceSpeaker.voices()
            personalVoice = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
            savedKeySuffix = GeminiLive.Key.suffix
            // The gateway's GPT-Live status matters only while OpenAI is offered.
            if LiveProvider.offered.contains(.openai) { await loadGatewayLive() }
        }
    }

    private func saveKey() {
        let key = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        GeminiLive.Key.value = key
        savedKeySuffix = GeminiLive.Key.suffix
        geminiKey = ""
        editingKey = false
        keyStatus = nil
        previewStatus = nil
    }

    private func checkKey() {
        guard let key = GeminiLive.Key.value else { return }
        checkingKey = true
        keyStatus = nil
        Task {
            switch await GeminiLive.Key.check(key) {
            case .success: keyStatus = ActionStatus(headline: "Key works", ok: true, raw: nil)
            case .failure(let f):
                let plain = GeminiLive.Trouble.plain(f.message, what: "key checks")
                keyStatus = ActionStatus(headline: plain.headline, ok: false, raw: plain.raw)
            }
            checkingKey = false
        }
    }

    /// A voice is fetched once and replayed from the device after that, so flicking through
    /// the voices does not spend the free tier's few calls a minute.
    private func previewVoice() {
        guard !VoiceCoordinator.shared.isSpeaking else { return }
        let voice = geminiVoice
        if let cached = GeminiLive.Key.cachedPreview(voice: voice) {
            previewStatus = ActionStatus(headline: "\(voice), from the device", ok: true, raw: nil)
            VoiceCoordinator.shared.play(cached)
            return
        }
        guard let key = GeminiLive.Key.value, !previewing else { return }
        previewing = true
        previewStatus = nil
        Task {
            do {
                let chunk = try await GeminiLive.Key.preview(voice: voice, key: key)
                GeminiLive.Key.storePreview(chunk, voice: voice)
                previewStatus = ActionStatus(headline: "\(voice), fetched once; replays are free", ok: true, raw: nil)
                VoiceCoordinator.shared.play(chunk)
            } catch {
                let plain = GeminiLive.Trouble.plain(error.localizedDescription)
                previewStatus = ActionStatus(headline: plain.headline, ok: false, raw: plain.raw)
            }
            previewing = false
        }
    }

    private func loadGatewayLive() async {
        guard let rt = model.runtime else { return }
        do { gatewayLive = try await GatewayVoiceAPI(api: rt.api, profile: rt.selectedProfile).liveStatus() }
        catch { gatewayLiveError = "The gateway did not answer about live voice: \(error.localizedDescription)" }
    }

    /// Google's own words, folded away under the plain sentence.
    private struct ActionDetails: View {
        var raw: String
        @State private var open = false
        var body: some View {
            DisclosureGroup("Details", isExpanded: $open) {
                Text(raw).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
        }
    }

    static func name(of v: AVSpeechSynthesisVoice) -> String {
        var tags: [String] = []
        if v.voiceTraits.contains(.isPersonalVoice) { tags.append("Personal Voice") }
        switch v.quality { case .premium: tags.append("Premium"); case .enhanced: tags.append("Enhanced"); default: break }
        return tags.isEmpty ? v.name : "\(v.name) · \(tags.joined(separator: ", "))"
    }
}
