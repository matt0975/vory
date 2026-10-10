import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Vory Summaries titles are made once and stay (#303): the stored title keeps the one made
/// before, a name the person gave always wins over it, and the preview keeps updating.
@MainActor @Suite struct SummaryTitlesTests {
    private func summary(_ title: String) -> ChatSummarizer.Summary { .init(title: title, summary: "what it was about", stamp: 1) }

    @Test func theTitleMadeBeforeIsKeptAndANewChatTakesTheDraftOrTheFallback() {
        #expect(ChatSummarizer.storedTitle(previous: nil, draft: "", fallback: "New chat") == "New chat")
        #expect(ChatSummarizer.storedTitle(previous: nil, draft: " Deploy plan ", fallback: "New chat") == "Deploy plan")
        #expect(ChatSummarizer.storedTitle(previous: summary("Deploy plan"), draft: "Rollback notes", fallback: "New chat") == "Deploy plan")
        #expect(ChatSummarizer.storedTitle(previous: summary(" "), draft: "Rollback notes", fallback: "New chat") == "Rollback notes")
    }

    @Test func aNameThePersonGaveWinsOverTheMadeTitle() {
        let d = UserDefaults.standard
        let hadTitles = d.object(forKey: ChatSummarizer.titlesKey), hadPreviews = d.object(forKey: ChatSummarizer.previewsKey)
        defer {
            if let hadTitles { d.set(hadTitles, forKey: ChatSummarizer.titlesKey) } else { d.removeObject(forKey: ChatSummarizer.titlesKey) }
            if let hadPreviews { d.set(hadPreviews, forKey: ChatSummarizer.previewsKey) } else { d.removeObject(forKey: ChatSummarizer.previewsKey) }
        }
        d.set(true, forKey: ChatSummarizer.titlesKey); d.set(true, forKey: ChatSummarizer.previewsKey)
        let s = ChatSummarizer.shared
        #expect(s.shown(summary("Deploy plan"), title: "Mine", preview: "p")?.title == "Deploy plan")
        #expect(s.shown(summary("Deploy plan"), title: "Mine", preview: "p", renamed: true)?.title == "Mine")
        // The preview is the made one either way.
        #expect(s.shown(summary("Deploy plan"), title: "Mine", preview: "p", renamed: true)?.summary == "what it was about")
    }

    @Test func aRenameIsRememberedByStoredID() {
        let d = UserDefaults.standard
        let had = d.stringArray(forKey: ChatSession.renamedByPersonKey)
        defer { if let had { d.set(had, forKey: ChatSession.renamedByPersonKey) } else { d.removeObject(forKey: ChatSession.renamedByPersonKey) } }
        d.removeObject(forKey: ChatSession.renamedByPersonKey)
        #expect(!ChatSession.renamedByPerson("20261009_a"))
        ChatSession.markRenamedByPerson("20261009_a")
        ChatSession.markRenamedByPerson("20261009_a")
        ChatSession.markRenamedByPerson("")
        #expect(ChatSession.renamedByPerson("20261009_a"))
        #expect(!ChatSession.renamedByPerson("20261009_b"))
        #expect(d.stringArray(forKey: ChatSession.renamedByPersonKey)?.count == 1)
    }
}
