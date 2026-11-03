import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// #615: across a fold SwiftUI can show the same chat on two pages for a moment, in either order; the chat stays the one on
/// screen while any page still shows it, and only the last page's going clears it, as one page's going always did.
@MainActor @Suite struct ChatOnScreenTests {
    private func chat(_ storedID: String) throws -> ChatSession {
        let conn = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let rt = GatewayRuntime(connection: conn, store: ConnectionStore())
        return ChatSession(runtime: rt, storedID: storedID, title: nil)
    }

    @Test func aPageGoingLeavesTheChatWhileAnotherShowsIt() throws {
        let c = try chat("s1")
        let a = UUID(), b = UUID()
        // Either page appearing first, and either going first.
        for (first, second) in [(a, b), (b, a)] {
            for (goes, stays) in [(a, b), (b, a)] {
                let m = AppModel()
                m.chatAppeared(c, page: first)
                m.chatAppeared(c, page: second)
                #expect(m.chatGone(c, page: goes))
                #expect(m.visibleChat === c && m.visibleChatID == "s1")
                #expect(!m.chatGone(c, page: stays))
                #expect(m.visibleChat == nil && m.visibleChatID == nil)
            }
        }
    }

    /// The order seen on the Duo, from closed to its side: the closed page goes, the page beside the list and a full-width
    /// one appear, and the full-width one goes.
    @Test func theFoldFromClosedToItsSide() throws {
        let c = try chat("s1")
        let m = AppModel()
        let closed = UUID(), beside = UUID(), full = UUID()
        m.chatAppeared(c, page: closed)
        #expect(!m.chatGone(c, page: closed))
        #expect(m.visibleChat == nil)
        m.chatAppeared(c, page: beside)
        m.chatAppeared(c, page: full)
        #expect(m.chatGone(c, page: full))
        #expect(m.visibleChat === c && m.visibleChatID == "s1")
    }

    /// Another chat's page going leaves the chat on screen as it is, as before.
    @Test func anotherChatGoingLeavesTheOneOnScreen() throws {
        let x = try chat("s1"), y = try chat("s2")
        let m = AppModel()
        let p = UUID(), q = UUID()
        m.chatAppeared(x, page: p)
        m.chatAppeared(y, page: q)
        #expect(!m.chatGone(x, page: p))
        #expect(m.visibleChat === y && m.visibleChatID == "s2")
        #expect(!m.chatGone(y, page: q))
        #expect(m.visibleChat == nil && m.visibleChatID == nil)
    }

    /// A page appearing again (back from a page pushed over it) counts once.
    @Test func aPageAppearingAgainCountsOnce() throws {
        let c = try chat("s1")
        let m = AppModel()
        let p = UUID()
        m.chatAppeared(c, page: p)
        m.chatAppeared(c, page: p)
        #expect(!m.chatGone(c, page: p))
        #expect(m.visibleChat == nil && m.visibleChatID == nil)
        m.chatAppeared(c, page: p)
        #expect(m.visibleChat === c)
    }
}
