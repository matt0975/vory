import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Siri's catalog and words (#310, #311): what it can name, what it says, and the switches' defaults.
@Suite struct SiriTests {
    @Test func theCatalogRemembersBotsAndRecentChatTitlesOnly() {
        let d = UserDefaults.standard
        let hadBots = d.object(forKey: SiriCatalog.botsKey), hadChats = d.object(forKey: SiriCatalog.chatsKey)
        defer {
            if let hadBots { d.set(hadBots, forKey: SiriCatalog.botsKey) } else { d.removeObject(forKey: SiriCatalog.botsKey) }
            if let hadChats { d.set(hadChats, forKey: SiriCatalog.chatsKey) } else { d.removeObject(forKey: SiriCatalog.chatsKey) }
        }
        SiriCatalog.rememberBots([ProfileInfo(name: "default", displayName: "Main"), ProfileInfo(name: "work")])
        #expect(SiriCatalog.bots().map(\.id) == ["default", "work"])
        #expect(SiriCatalog.bots().map(\.label) == ["Main", "work"])
        let sessions = (0..<60).map { StoredSession(id: "s\($0)", title: "Chat \($0)", preview: "secret words \($0)", profile: $0 % 2 == 0 ? "work" : nil) }
        SiriCatalog.rememberChats(sessions)
        let chats = SiriCatalog.chats()
        #expect(chats.count == SiriCatalog.chatLimit)
        #expect(chats.first?.title == "Chat 0" && chats.first?.bot == "work")
        #expect(chats[1].bot == nil)
        // Titles only: no preview text is kept anywhere in the catalog.
        let raw = d.array(forKey: SiriCatalog.chatsKey) as? [[String]] ?? []
        #expect(!raw.flatMap { $0 }.contains { $0.contains("secret") })
    }

    @Test func theSwitchesDefaultAsAgreed() {
        let d = UserDefaults.standard
        let hadS = d.object(forKey: SiriCatalog.spotlightKey), hadA = d.object(forKey: SiriCatalog.approvalsKey)
        defer {
            if let hadS { d.set(hadS, forKey: SiriCatalog.spotlightKey) } else { d.removeObject(forKey: SiriCatalog.spotlightKey) }
            if let hadA { d.set(hadA, forKey: SiriCatalog.approvalsKey) } else { d.removeObject(forKey: SiriCatalog.approvalsKey) }
        }
        d.removeObject(forKey: SiriCatalog.spotlightKey); d.removeObject(forKey: SiriCatalog.approvalsKey)
        #expect(SiriCatalog.spotlightOn == !DeviceWords.isMac)
        #expect(SiriCatalog.answersApprovals == false)
    }

    @Test func theStatusLineSaysWhatRunsAndWhatWaits() {
        #expect(SiriWords.status(running: [], waiting: 0, bot: nil) == "No bot is running anything.")
        #expect(SiriWords.status(running: [], waiting: 1, bot: "Main") == "Main is not running anything. One approval is waiting for you.")
        #expect(SiriWords.status(running: [(bot: "work", title: "Deploy plan")], waiting: 0, bot: nil) == "work is working on Deploy plan.")
        #expect(SiriWords.status(running: [(bot: "work", title: "Deploy plan"), (bot: "default", title: "Notes")], waiting: 2, bot: nil)
                == "2 chats are running: work on Deploy plan, default on Notes. 2 approvals are waiting for you.")
        // Named bot: only its chats count.
        #expect(SiriWords.status(running: [(bot: "work", title: "Deploy plan"), (bot: "default", title: "Notes")], waiting: 0, bot: "Default") == "default is working on Notes.")
    }

    @Test func theApprovalQuestionNamesTheBotAndTheCommand() throws {
        let req = ApprovalRequest(requestId: "r1", sessionId: "s1", command: "rm -rf build/", description: "Clean the build folder")
        #expect(SiriWords.approvalQuestion(bot: "work", request: req, answer: .approve) == "work wants to run: rm -rf build/. Approve it?")
        #expect(SiriWords.approvalQuestion(bot: "work", request: req, answer: .deny) == "work wants to run: rm -rf build/. Deny it?")
        let long = ApprovalRequest(requestId: "r2", sessionId: "s1", command: String(repeating: "x", count: 200))
        #expect(SiriWords.approvalQuestion(bot: "work", request: long, answer: .approve).count < 170)
        // Nothing to name: still a sentence.
        let bare = ApprovalRequest(requestId: "r3", sessionId: "s1")
        #expect(SiriWords.approvalQuestion(bot: "work", request: bare, answer: .approve) == "work wants to run: a command. Approve it?")
    }
}
