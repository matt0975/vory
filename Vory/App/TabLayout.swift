import Foundation
import SwiftUI
import VoryCore

/// Which tabs sit in the bottom bar and in what order. Persisted as a comma-separated list of
/// `AppModel.AppTab` raw values under `tabLayout`; Chats and Settings are always present so the
/// user can never lock themselves out of a screen that gets them back here.
struct TabLayout: Equatable, Sendable {
    static let storageKey = "tabLayout"
    static let required: [AppModel.AppTab] = [.chats, .settings]
    /// Four on the bar, like Messages, with the compose button floating beside it.
    static let maxTabs = 4

    var isFull: Bool { tabs.count >= Self.maxTabs }
    static let `default` = TabLayout(tabs: [.dashboard, .chats, .bots, .settings])
    /// Set once the one-time switch to the Home-first default has run on this phone.
    static let homeFirstAppliedKey = "tabLayout.homeFirstApplied"

    private(set) var tabs: [AppModel.AppTab]

    init(tabs: [AppModel.AppTab]) {
        self.tabs = Self.normalize(tabs)
    }

    /// Parses the stored string; unknown names are dropped, missing required tabs are re-added.
    static func parse(_ raw: String?) -> TabLayout {
        guard let raw, !raw.isEmpty else { return .default }
        return TabLayout(tabs: raw.split(separator: ",").compactMap { AppModel.AppTab(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
    }

    var encoded: String { tabs.map(\.rawValue).joined(separator: ",") }

    func contains(_ tab: AppModel.AppTab) -> Bool { tabs.contains(tab) }

    /// Tabs to render. Bots lists the gateway's profiles, so it is always available; `hasBotMode`
    /// is kept for callers that still pass it and only gates the hosted-rooms section inside.
    func visible(hasBotMode: Bool = true) -> [AppModel.AppTab] { tabs }

    mutating func set(_ tab: AppModel.AppTab, enabled: Bool) {
        if Self.required.contains(tab) { return }
        if enabled, !tabs.contains(tab) {
            if isFull { return }
            // New tabs go before Settings so Settings stays last, like the system apps.
            let at = tabs.firstIndex(of: .settings) ?? tabs.endIndex
            tabs.insert(tab, at: at)
        } else if !enabled {
            tabs.removeAll { $0 == tab }
        }
    }

    mutating func move(fromOffsets: IndexSet, toOffset: Int) {
        tabs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        tabs = Self.normalize(tabs)
    }

    /// De-duplicates and keeps Chats and Settings present; any order is fine, theirs included.
    private static func normalize(_ input: [AppModel.AppTab]) -> [AppModel.AppTab] {
        var seen = Set<AppModel.AppTab>()
        var out = input.filter { seen.insert($0).inserted }
        if !out.contains(.chats) { out.insert(.chats, at: 0) }
        if !out.contains(.settings) { out.append(.settings) }
        // A layout saved by an earlier build could hold five; drop optional tabs from the end
        // until it fits, keeping Chats and Settings.
        while out.count > maxTabs, let i = out.lastIndex(where: { !required.contains($0) }) { out.remove(at: i) }
        return out
    }
}
