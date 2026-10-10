import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Reasoning effort as its own item in the chat's menu (#301): which levels are listed, and
/// what the item says.
@Suite struct ReasoningEffortTests {
    @Test func theStandardLevelsComeFirstThenTheGatewaysExtras() {
        #expect(ReasoningEffort.levels(offered: nil) == ["low", "medium", "high"])
        #expect(ReasoningEffort.levels(offered: ["", "minimal", "low", "medium", "high", "xhigh", "max"]) == ["low", "medium", "high", "minimal", "xhigh", "max"])
        // Repeats and blanks are dropped; the gateway's own order is kept for the extras.
        #expect(ReasoningEffort.levels(offered: ["max", " ", "high", "xhigh", "max"]) == ["low", "medium", "high", "max", "xhigh"])
    }

    @Test func theTitleSaysTheLevelOrThatNoneIsSet() {
        #expect(ReasoningEffort.title(current: "medium") == "Reasoning: medium")
        #expect(ReasoningEffort.title(current: nil) == "Reasoning: not set")
        #expect(ReasoningEffort.title(current: " ") == "Reasoning: not set")
    }

    @Test func theOfferedLevelsAreReadFromTheConfigSchema() throws {
        let json = #"{"fields": {"agent.reasoning_effort": {"type": "select", "options": ["", "low", "medium", "high", "max"]}, "model": {"type": "string"}}}"#
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(ReasoningEffort.offered(in: schema) == ["", "low", "medium", "high", "max"])
        let none = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"fields": {}}"#.utf8))
        #expect(ReasoningEffort.offered(in: none) == nil)
    }
}
