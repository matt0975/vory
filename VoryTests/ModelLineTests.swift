import Foundation
import Testing
@testable import Vory

/// Settings › Model › Current: the gateway's model id names its provider already.
@Suite struct ModelLineTests {
    @Test func theCurrentLineDoesNotRepeatTheProvider() {
        #expect(ModelSettingsView.currentModelLine(provider: "anthropic", model: "anthropic/claude-sonnet-4.6") == "anthropic/claude-sonnet-4.6")
        #expect(ModelSettingsView.currentModelLine(provider: "workshop", model: "workshop/assistant") == "workshop/assistant")
        // An id without its provider gets it in front; no provider, the id alone; no model, "not set".
        #expect(ModelSettingsView.currentModelLine(provider: "openai", model: "gpt-5.1") == "openai/gpt-5.1")
        #expect(ModelSettingsView.currentModelLine(provider: nil, model: "local/assistant") == "local/assistant")
        #expect(ModelSettingsView.currentModelLine(provider: "anthropic", model: "") == "not set")
        #expect(ModelSettingsView.currentModelLine(provider: nil, model: nil) == "not set")
    }
}
