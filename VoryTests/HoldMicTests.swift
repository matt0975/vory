import Foundation
import Testing
@testable import VoryCore

/// Settings › Voice › Hold the mic to: what a press of the composer's mic does.
@Suite struct HoldMicTests {
    @Test func aTapDictatesWhateverTheSettingAndAHoldFollowsIt() {
        // The default: a hold is a tap, dictation.
        #expect(VoiceSettings.micAction(held: false, setting: .dictate) == .dictate)
        #expect(VoiceSettings.micAction(held: true, setting: .dictate) == .dictate)
        // Start voice mode: only the hold goes there; a tap still dictates.
        #expect(VoiceSettings.micAction(held: false, setting: .voiceMode) == .dictate)
        #expect(VoiceSettings.micAction(held: true, setting: .voiceMode) == .voiceMode)
    }

    @Test func theSettingDefaultsToDictateReadsItsRawValueAndSyncs() {
        let key = VoiceSettings.holdMicKey
        let before = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(VoiceSettings.holdMic == .dictate)
        UserDefaults.standard.set("voiceMode", forKey: key)
        #expect(VoiceSettings.holdMic == .voiceMode)
        UserDefaults.standard.set("nonsense", forKey: key)
        #expect(VoiceSettings.holdMic == .dictate, "an unknown value is the default, not a crash")
        #expect(VoiceSettings.syncedKeys.contains(key), "it follows the person like the other voice settings")
        #expect(VoiceSettings.HoldMicAction.allCases.map(\.title) == ["Dictate", "Start voice mode"])
    }
}
