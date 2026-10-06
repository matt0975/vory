#if os(macOS)
import AppKit
import Testing
@testable import Vory

/// Continuity Camera items stay in a text field's menu and leave every other right-click menu.
@MainActor
struct MacContinuityMenuTests {
    private func continuityItems() -> [NSMenuItem] {
        let header = NSMenuItem.sectionHeader(title: "Import from iPhone or iPad")
        let device = NSMenuItem(title: "A Phone", action: NSSelectorFromString("importFromDeviceText:"), keyEquivalent: "")
        return [.separator(), header, device]
    }

    @Test func aReplyMenuLosesTheContinuityItemsAndTheirSeparator() {
        let menu = NSMenu()
        for t in ["Reply", "Speak", "Copy", "Select Text", "Share"] { menu.addItem(NSMenuItem(title: t, action: nil, keyEquivalent: "")) }
        continuityItems().forEach(menu.addItem)
        ContinuityMenuFilter.strip(menu)
        #expect(menu.items.map(\.title) == ["Reply", "Speak", "Copy", "Select Text", "Share"])
    }

    @Test func aTextFieldMenuKeepsThem() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: ""))
        continuityItems().forEach(menu.addItem)
        ContinuityMenuFilter.strip(menu)
        #expect(menu.items.count == 5)
    }

    @Test func aSubmenuIsLeftAlone() {
        let parent = NSMenu()
        let holder = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        continuityItems().forEach(sub.addItem)
        holder.submenu = sub
        parent.addItem(holder)
        ContinuityMenuFilter.strip(sub)
        #expect(sub.items.count == 3)
    }
}
#endif
