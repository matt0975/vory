import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif

/// The permission prompts read as Matt approved them (#500), each on its own device: the microphone's one sentence, and
/// the speech recognition's naming the device it's on (the iPad reads its own, `~ipad`, from the same Info.plist).
@Suite @MainActor struct PermissionPromptTests {
    private func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

    @Test func theMicrophonePromptIsMattsSentence() {
        #expect(info("NSMicrophoneUsageDescription") == "Talk with your bot, dictate a message or record a voice memo. Audio goes to your gateway, or to Google if you use Live voice with your own key.")
    }

    @Test func theSpeechPromptNamesTheDeviceItIsOn() {
        #if os(iOS)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        let device = "Mac"
        #endif
        #expect(info("NSSpeechRecognitionUsageDescription") == "Turn what you say into text on this \(device). When your gateway has its own speech provider and Speech is set to Automatic or Gateway, your audio goes to the gateway instead.")
    }

    #if os(macOS)
    @Test func theMacAsksForNoCamera() {
        #expect(info("NSCameraUsageDescription") == nil)
    }
    #endif
}
