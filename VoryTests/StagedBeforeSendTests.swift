import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// A file still staging when its message is sent goes with that message. A large one stages off the main thread, so a
/// Return right after a drop or a paste could beat it: the message went without the file, which then sat staged for
/// the next one.
@MainActor @Suite struct StagedBeforeSendTests {
    @MainActor final class Calls { var names: [String] = [] }

    private static let attached: JSONValue = .object(["session_id": .string("rt1"), "stored_session_id": .string("s1"), "messages": .array([])])

    /// A chat attached through a stand-in for the gateway that keeps the name of every call, in order.
    private func attachedChat() async throws -> (ChatSession, Calls) {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let c = ChatSession(runtime: GatewayRuntime(connection: conn, store: ConnectionStore()), storedID: "s1", title: nil)
        let calls = Calls()
        c.gatewayStandIn = { method, _ in
            calls.names.append(method)
            switch method {
            case "session.resume": return Self.attached
            case "file.attach": return .object(["ref_text": .string("[big.bin]")])
            default: return .object([:])
            }
        }
        c.beginResume()
        await c.awaitResume()
        return (c, calls)
    }

    @Test func aLargeFileStagedJustBeforeSendGoesWithTheMessage() async throws {
        let (c, calls) = try await attachedChat()
        c.stageAttachment(data: Data(count: 2 * 1024 * 1024), name: "big.bin", kind: .file)
        #expect(await c.send("here it is") == nil)
        let attach = try #require(calls.names.firstIndex(of: "file.attach"), "the file never went: \(calls.names)")
        let submit = try #require(calls.names.firstIndex(of: "prompt.submit"), "no message went: \(calls.names)")
        #expect(attach < submit, "the file went after its message: \(calls.names)")
        let sent = c.items.compactMap { if case .user(_, let attachments) = $0.kind { attachments } else { nil } }.last
        #expect(sent?.map(\.name) == ["big.bin"])
        #expect(c.staged.isEmpty, "the file was left staged for the next message")
    }

    /// A staging that never ends (a drop whose provider never answers) holds up one send, for its wait only.
    @Test func aStagingThatNeverEndsHoldsUpOneSendOnly() async throws {
        let (c, _) = try await attachedChat()
        c.stagingBegan()
        let first = Date()
        await c.stagingSettled(upTo: 0.2)
        let waited = Date().timeIntervalSince(first)
        #expect(waited >= 0.15 && waited < 1, "the first wait took \(waited) s")
        let second = Date()
        await c.stagingSettled()
        #expect(Date().timeIntervalSince(second) < 0.1, "the next send waited for a staging already given up")
    }

    @Test func aMessageOfOnlyALargeFileStillStagingIsSent() async throws {
        let (c, calls) = try await attachedChat()
        c.stageAttachment(data: Data(count: 2 * 1024 * 1024), name: "big.bin", kind: .file)
        _ = await c.send("")
        #expect(calls.names.contains("file.attach") && calls.names.contains("prompt.submit"), "nothing went: \(calls.names)")
        #expect(c.staged.isEmpty, "the file was left staged for the next message")
    }
}
