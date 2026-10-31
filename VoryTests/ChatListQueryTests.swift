import Foundation
import Testing
@testable import Vory

/// The Chats list asks for archived chats only while the Archived filter shows them (#474): a Hermes that leaves them
/// out unless asked sent none, so the filter showed nothing, and with them hidden the page isn't spent on them.
struct ChatListQueryTests {
    @Test func archivedChatsAreAskedForOnlyWhileShown() {
        let shown = ChatListView.listQuery(limit: 100, showArchived: true)
        #expect(shown.first { $0.name == "archived" }?.value == "include")
        #expect(shown.first { $0.name == "limit" }?.value == "100")
        let hidden = ChatListView.listQuery(limit: 50, showArchived: false)
        #expect(hidden.first { $0.name == "archived" }?.value == "exclude")
        #expect(hidden.first { $0.name == "limit" }?.value == "50")
        #expect(hidden.first { $0.name == "order" }?.value == "recent")
    }
}
