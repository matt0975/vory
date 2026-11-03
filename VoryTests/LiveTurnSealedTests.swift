#if os(iOS)
import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// A relay-mode push's sealed names and goal line (#497), opened for the Live Activity, and what it shows when they
/// can't be opened. The opener is passed in; the real one reads this install's key from the Keychain.
@Suite struct LiveTurnSealedTests {
    /// The Companion's vector (PushRelayCryptoTests): a zero key and a zero nonce over {"title":"hi","body":"there"}.
    let vector = "AAAAAAAAAAAAAAAAtYU0VDkMDkw9bK26mN+/eh0EeugNhF4ctNCQrAgnBvQ6vurB94SMNXCYlKJV"
    let zeroKey = Data(repeating: 0, count: 32).base64EncodedString()

    /// A push-started activity as a relay-mode Companion 1.0.40 sends it: the names empty, sealed beside them.
    func sealedAttributes(_ blob: String) -> HermesTurnAttributes {
        var a = HermesTurnAttributes(sessionTitle: "", storedSessionID: "3f6c2a1e9b", connectionID: "C0FFEE00", profile: "",
                                     tintHex: "", botName: "", avatar: "")
        a.sealed = blob
        return a
    }

    func sealedState(_ blob: String) -> HermesTurnAttributes.ContentState {
        var s = HermesTurnAttributes.ContentState(phase: "tool", detail: "Running a tool…", outputTokens: 0, contextPercent: nil, needsAttention: false)
        s.sealed = blob
        return s
    }

    @Test func theSealedNamesAndGoalAreOpened() {
        let names: [String: JSONValue] = ["title": "Rewrite the nightly export job", "bot": "Archivist", "profile": "archivist",
                                          "hex": "#FF8800", "avatar": "animated:pebble"]
        let a = sealedAttributes("blob").unsealed { _ in names }
        #expect(a.sessionTitle == "Rewrite the nightly export job")
        #expect(a.displayBotName == "Archivist")
        #expect(a.profile == "archivist")
        #expect(a.tintHex == "#FF8800")
        #expect(a.avatar == "animated:pebble")
        #expect(a.sealed == nil)
        #expect(a.storedSessionID == "3f6c2a1e9b")
        #expect(a.connectionID == "C0FFEE00")
        let s = sealedState("blob").unsealed { _ in ["goal": "Finding why the export times out"] }
        #expect(s.shownGoal == "Finding why the export times out")
        #expect(s.sealed == nil)
    }

    /// With no key on this phone (or one that can't open it), the activity reads "Chat" with the default bot and look,
    /// and no goal line. No field holds the sealed text, and the chat's title isn't empty.
    @Test func whatCantBeOpenedFallsBackToTheGenericWords() {
        let blob = vector
        let a = sealedAttributes(blob).unsealed { _ in nil }
        #expect(a.sessionTitle == "Chat")
        #expect(a.displayBotName == "Hermes")
        #expect(a.botName == nil && a.avatar == nil)
        #expect(a.profile.isEmpty && a.tintHex.isEmpty)
        #expect(![a.sessionTitle, a.profile, a.tintHex, a.botName ?? "", a.avatar ?? ""].contains(blob))
        let s = sealedState(blob).unsealed { _ in nil }
        #expect(s.goal == nil && s.shownGoal == nil)
        #expect(s.detail == "Running a tool…")
    }

    @Test func theCompanionsSealOpensWithThisInstallsKey() {
        // The real opener's chain (PushRelay.decrypt) with the key the vector was sealed with: its "title" fills the chat.
        let a = sealedAttributes(vector).unsealed { try? PushRelay.decrypt($0, keyBase64: zeroKey) }
        #expect(a.sessionTitle == "hi")
        #expect(a.displayBotName == "Hermes")
    }

    /// A reinstall mints a new key: a blob sealed for the old install doesn't open with it. Nor does a damaged blob.
    @Test func anotherInstallsKeyOrADamagedBlobFallsBack() {
        let otherKey = Data((0..<32).map { UInt8($0) }).base64EncodedString()
        #expect(sealedAttributes(vector).unsealed { try? PushRelay.decrypt($0, keyBase64: otherKey) }.sessionTitle == "Chat")
        // Empty, not base64, cut short, and one character of the ciphertext changed (its tag no longer matches).
        for damaged in ["", "not base64 at all", String(vector.dropLast(4)), vector.replacingOccurrences(of: "tYU0", with: "tYU1")] {
            #expect(sealedAttributes(damaged).unsealed { try? PushRelay.decrypt($0, keyBase64: zeroKey) }.sessionTitle == "Chat")
            #expect(sealedState(damaged).unsealed { try? PushRelay.decrypt($0, keyBase64: zeroKey) }.goal == nil)
        }
    }

    /// The plain names of an older Companion, or of the app's own activity, are kept as they are.
    @Test func withNothingSealedTheActivityIsUnchanged() {
        let plain = HermesTurnAttributes(sessionTitle: "Disk cleanup", storedSessionID: "s", connectionID: "c", profile: "archivist",
                                         tintHex: "#00AAFF", botName: "Archivist", avatar: "initial")
        let a = plain.unsealed { _ in Issue.record("nothing to open"); return nil }
        #expect(a.sessionTitle == "Disk cleanup")
        #expect(a.botName == "Archivist")
        #expect(a.profile == "archivist")
        #expect(a.tintHex == "#00AAFF")
        #expect(a.avatar == "initial")
    }

    @Test func aSealedPushDecodes() throws {
        let state = #"{"phase":"tool","detail":"Running a tool…","outputTokens":3,"needsAttention":false,"startedAtUnix":1792700000,"sealed":"QUJD"}"#
        #expect(try JSONDecoder().decode(HermesTurnAttributes.ContentState.self, from: Data(state.utf8)).sealed == "QUJD")
        let attrs = #"{"sessionTitle":"","storedSessionID":"s","connectionID":"c","profile":"","model":"","tintHex":"","botName":"","avatar":"","sealed":"QUJD"}"#
        #expect(try JSONDecoder().decode(HermesTurnAttributes.self, from: Data(attrs.utf8)).sealed == "QUJD")
    }
}
#endif
