import Foundation
import Testing
@testable import VoryCore

/// The public 1.4 build offers Live on Gemini only: OpenAI Live is not built yet.
@Suite struct LiveProviderTests {
    @Test func onlyGeminiIsOfferedAndAnOldOpenAIChoiceGoesOnWithGemini() {
        #expect(LiveProvider.offered == [.gemini])
        #expect(VoiceSettings.provider(stored: nil) == .gemini)
        #expect(VoiceSettings.provider(stored: "gemini") == .gemini)
        // A device that picked OpenAI in an internal build (the setting syncs) is not left
        // on a provider the build does not offer.
        #expect(VoiceSettings.provider(stored: "openai") == .gemini)
        #expect(VoiceSettings.provider(stored: "nonsense") == .gemini)
    }

    /// The menu lists OpenAI greyed out as coming later; only Gemini can be chosen.
    @Test func theMenuShowsOpenAIAsComingLater() {
        #expect(LiveProvider.listed == [.gemini, .openai])
        #expect(LiveProvider.gemini.isOffered)
        #expect(!LiveProvider.openai.isOffered)
        #expect(LiveProvider.gemini.menuTitle == "Gemini (your key)")
        #expect(LiveProvider.openai.menuTitle == "OpenAI (coming later)")
    }
}
