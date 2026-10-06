import AppKit

/// Continuity Camera ("Import from iPhone or iPad", under the phone's own name) belongs where
/// a photo or a scan can go: the composer's text menu and File › Import from iPhone or iPad.
/// AppKit adds it to every right-click menu in a window that accepts imports, so a reply's,
/// a chat row's or a card's menu listed the user's phone by name for nothing. Those menus have no
/// Paste, which tells them apart from a text field's; the items are taken out of them as the
/// menu opens.
@MainActor
enum ContinuityMenuFilter {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            // Delivered on the main queue; the menu is only touched there.
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated { if let menu { strip(menu) } }
            // AppKit may add the items as the menu comes up: once more after this turn (the main
            // queue is served while a menu tracks).
            DispatchQueue.main.async { MainActor.assumeIsolated { if let menu { strip(menu) } } }
        }
    }

    /// Takes the Continuity Camera items (and the separator they leave) out of a right-click
    /// menu that is not a text field's. The menu bar and its menus are left alone.
    static func strip(_ menu: NSMenu) {
        guard menu.supermenu == nil, menu !== NSApp?.mainMenu, isContextMenuWithoutPaste(menu) else { return }
        let doomed = menu.items.filter(isContinuityItem)
        guard !doomed.isEmpty else { return }
        doomed.forEach(menu.removeItem)
        // No separator at either end, nor two in a row.
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        var previousWasSeparator = false
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = item.isSeparatorItem }
        }
    }

    static func isContextMenuWithoutPaste(_ menu: NSMenu) -> Bool {
        !menu.items.contains { $0.action == #selector(NSText.paste(_:)) }
    }

    static func isContinuityItem(_ item: NSMenuItem) -> Bool {
        func named(_ s: String?) -> Bool { s?.range(of: "importFromDevice", options: .caseInsensitive) != nil }
        if named(item.action.map(NSStringFromSelector)) || named(item.identifier?.rawValue) { return true }
        // The section header AppKit puts over them, and a submenu of them (one per device).
        if item.isSectionHeader, item.title.range(of: "Import from", options: .caseInsensitive) != nil { return true }
        if let sub = item.submenu, !sub.items.isEmpty, sub.items.allSatisfy(isContinuityItem) { return true }
        return false
    }
}
