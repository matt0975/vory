import Foundation

// MARK: Voice settings and routing
//
// Where speech is turned into text and text into speech: the gateway's own STT and TTS
// providers (hermes_cli/web_routers/audio.py) or Apple's engines on this device. The Speech
// setting follows the person between devices through iCloud like the other settings.

/// Settings › Voice › Speech.
public enum SpeechSource: String, CaseIterable, Sendable, Identifiable {
    /// The gateway when it has a provider, otherwise this device.
    case automatic
    /// Always the gateway; an error when it has no provider.
    case gateway
    /// Always this device; no audio ever leaves it.
    case device

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .gateway: return "Gateway"
        case .device: return "On this device"
        }
    }
    public var blurb: String {
        switch self {
        case .automatic: return "The gateway's speech providers when it has them, otherwise Apple's engines here."
        case .gateway: return "Always the gateway's providers. Dictation and speech fail when it has none."
        case .device: return "Apple's engines on this device. No audio is sent to the gateway."
        }
    }
}

public enum VoiceSettings {
    /// `SpeechSource` raw value; synced.
    public static let speechKey = "voice.speech"
    /// Replies in the chat in front are read aloud as they finish; synced.
    public static let readAloudKey = "voice.readAloud"
    /// A dictated message is sent as soon as it is transcribed; synced.
    public static let sendAfterDictationKey = "voice.sendAfterDictation"
    /// The on-device voice's identifier (AVSpeechSynthesisVoice); per device, since voices are installed per device.
    public static let deviceVoiceKey = "voice.deviceVoice"
    /// What was used last, for Settings › Voice's footnote; per device.
    public static let lastSTTKey = "voice.lastSTT"
    public static let lastTTSKey = "voice.lastTTS"
    /// Hands-free: speaking over the bot stops it (on unless turned off); synced.
    public static let bargeInKey = "voice.handsFree.bargeIn"
    /// Hands-free: how long a silence ends the person's turn, in seconds; synced.
    public static let endOfTurnKey = "voice.handsFree.endOfTurn"

    /// Live or Standard conversation (`ConversationMode`); synced.
    public static let conversationKey = "voice.conversation"
    /// Which live provider (`LiveProvider`); synced.
    public static let liveProviderKey = "voice.liveProvider"
    /// The Gemini voice's name; synced.
    public static let geminiVoiceKey = "voice.gemini.voice"
    /// Voice answers come faster with less deep reasoning (the chat's reasoning low and fast
    /// replies on while voice runs, put back after); on unless turned off; synced.
    public static let quickAnswersKey = "voice.quickAnswers"
    /// The audio session the last voice session played through, for Settings › Voice (a tester's
    /// voice mode made no sound with the iPhone's switch on silent); per device.
    public static let lastSessionKey = "voice.lastSession"

    public static let syncedKeys: [String] = [speechKey, readAloudKey, sendAfterDictationKey, bargeInKey, endOfTurnKey, conversationKey, liveProviderKey, geminiVoiceKey, quickAnswersKey]

    public static var conversation: ConversationMode {
        UserDefaults.standard.string(forKey: conversationKey).flatMap(ConversationMode.init(rawValue:)) ?? .automatic
    }
    public static var liveProvider: LiveProvider {
        UserDefaults.standard.string(forKey: liveProviderKey).flatMap(LiveProvider.init(rawValue:)) ?? .gemini
    }
    public static var geminiVoice: String { UserDefaults.standard.string(forKey: geminiVoiceKey)?.nilIfEmpty ?? GeminiLive.defaultVoice }

    public static var speech: SpeechSource {
        UserDefaults.standard.string(forKey: speechKey).flatMap(SpeechSource.init(rawValue:)) ?? .automatic
    }
    public static var readAloud: Bool { UserDefaults.standard.bool(forKey: readAloudKey) }
    public static var sendAfterDictation: Bool { UserDefaults.standard.bool(forKey: sendAfterDictationKey) }
    public static var deviceVoice: String? { UserDefaults.standard.string(forKey: deviceVoiceKey) }
    public static var bargeIn: Bool { UserDefaults.standard.object(forKey: bargeInKey) as? Bool ?? true }
    /// The end-of-turn pause: the choices offered, and the one in force.
    public enum EndOfTurn: Double, CaseIterable, Sendable, Identifiable {
        case short = 0.5, normal = 0.8, long = 1.4
        public var id: Double { rawValue }
        public var title: String {
            switch self { case .short: return "Short"; case .normal: return "Normal"; case .long: return "Long" }
        }
    }
    public static var endOfTurn: EndOfTurn {
        EndOfTurn(rawValue: UserDefaults.standard.double(forKey: endOfTurnKey)) ?? .normal
    }
    public static var quickAnswers: Bool { UserDefaults.standard.object(forKey: quickAnswersKey) as? Bool ?? true }
}

/// Which engine a job goes to.
public enum VoiceRoute: String, Sendable, Equatable {
    case gateway, device
}

/// The one rule behind the Speech setting. The gateway has no cheap "do you have a provider"
/// question that does not hand out its keys (voice-config is never called), so Automatic tries
/// the gateway and falls back to the device when it answers that it has no provider; that
/// answer is remembered for a while (`gatewayUnableUntil`) so every dictation does not pay for
/// a refused call first.
public enum VoiceRouting {
    public static let retryAfter: TimeInterval = 3600

    public static func route(for setting: SpeechSource, gatewayConnected: Bool, gatewayUnableUntil: Date?, now: Date = Date()) -> VoiceRoute {
        switch setting {
        case .device: return .device
        case .gateway: return .gateway
        case .automatic:
            guard gatewayConnected else { return .device }
            if let until = gatewayUnableUntil, until > now { return .device }
            return .gateway
        }
    }

    /// Whether a gateway failure means "no provider" (fall back and remember) rather than a
    /// passing fault (a timeout, a 5xx) that the next attempt may not see.
    public static func isNoProvider(_ error: Error) -> Bool {
        guard let e = error as? HermesAPIError, case .http(let status, let detail) = e else { return false }
        let d = detail.lowercased()
        if status == 404 { return true }
        return d.contains("provider") || d.contains("not configured") || d.contains("no tts") || d.contains("no stt")
            || d.contains("api key") || d.contains("not available") || d.contains("unavailable") || d.contains("not installed")
    }

    /// A line for Settings: "Gateway (whisper)" or "On this device".
    public static func label(route: VoiceRoute, provider: String?) -> String {
        switch route {
        case .device: return "On this device"
        case .gateway: return provider.map { "Gateway (\($0))" } ?? "Gateway"
        }
    }
}
