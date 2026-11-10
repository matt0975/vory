import SwiftUI

/// The chat list's settings, backed by UserDefaults under the same keys the rest of the app
/// uses (Settings toggles some of them): read once, written on change, and refreshed from the
/// defaults when another screen writes one. One observable object, so the list's view holds no
/// property wrappers that SwiftUI cannot compare.
@Observable @MainActor
final class ChatListPrefs {
    static let shared = ChatListPrefs()
    private let d = UserDefaults.standard
    private var observer: Any?

    var allBots: Bool { didSet { if allBots != oldValue { d.set(allBots, forKey: "chats.allBots") } } }
    var aiTitles: Bool { didSet { if aiTitles != oldValue { d.set(aiTitles, forKey: ChatSummarizer.titlesKey) } } }
    var aiPreviews: Bool { didSet { if aiPreviews != oldValue { d.set(aiPreviews, forKey: ChatSummarizer.previewsKey) } } }
    var pinnedOnly: Bool { didSet { if pinnedOnly != oldValue { d.set(pinnedOnly, forKey: "chats.filter.pinned") } } }
    var needsYouOnly: Bool { didSet { if needsYouOnly != oldValue { d.set(needsYouOnly, forKey: "chats.filter.needsYou") } } }
    var liveOnly: Bool { didSet { if liveOnly != oldValue { d.set(liveOnly, forKey: "chats.filter.live") } } }
    var showArchived: Bool { didSet { if showArchived != oldValue { d.set(showArchived, forKey: "chats.filter.archived") } } }
    var sortKey: String { didSet { if sortKey != oldValue { d.set(sortKey, forKey: "chats.sort") } } }
    var groupsOnly: Bool { didSet { if groupsOnly != oldValue { d.set(groupsOnly, forKey: "chats.filter.groups") } } }
    var projectFilter: String { didSet { if projectFilter != oldValue { keepOwn(projectFilter, "chats.filter.project") } } }
    var byProject: Bool { didSet { if byProject != oldValue { d.set(byProject, forKey: "chats.byProject") } } }
    var collapsedRaw: String { didSet { if collapsedRaw != oldValue { keepOwn(collapsedRaw, "chats.byProject.collapsed") } } }
    var archivedRoomsRaw: String { didSet { if archivedRoomsRaw != oldValue { keepOwn(archivedRoomsRaw, "chats.archivedRooms") } } }
    /// The Scheduled section open (#673): closed until it's opened, then as it was left, on this device. Not a setting.
    var scheduledOpen: Bool { didSet { if scheduledOpen != oldValue { d.set(scheduledOpen, forKey: "chats.scheduled.open") } } }
    /// While the demo runs, the filter by project, the folded projects and the archived rooms are the demo's, for its life
    /// (#494): its projects and rooms are not the person's, and kept they left the person's list filtered to a project
    /// they don't have. Leaving it brings the person's own back.
    var inDemo = false {
        didSet {
            guard inDemo != oldValue else { return }
            if inDemo { projectFilter = ""; collapsedRaw = ""; archivedRoomsRaw = "" } else { refresh() }
        }
    }
    /// One of the three, kept outside the demo, and only when it is not what is kept already: coming back from the demo
    /// puts the person's own back from the defaults and wrote them over themselves, an absent one as "" (#494). Never
    /// while the defaults are read back (`refresh`), and "what is kept" is read as the prefs read it: a number or a Bool
    /// under the key reads as no value there, while `string(forKey:)` made it "1", so leaving the demo wrote "" over it (#512).
    private func keepOwn(_ value: String, _ key: String) {
        guard !inDemo, !refreshing, value != (d.object(forKey: key) as? String ?? "") else { return }
        #if DEBUG
        Self.traceOwnWrite(key, was: d.object(forKey: key), now: value, inDemo: inDemo)
        #endif
        d.set(value, forKey: key)
    }
    /// While `refresh` reads the defaults back: what it sets is what is kept, so nothing is written (#512).
    @ObservationIgnored private var refreshing = false
    #if DEBUG
    /// The writes of the three keys through `keepOwn`, the last eight, each with the frames that called it (symbol names
    /// only), and how many there have been: the no-trace tests name them when the person's own keys changed (#512).
    static private(set) var ownWritesForTests: [String] = []
    static private(set) var ownWriteCountForTests = 0
    private static func traceOwnWrite(_ key: String, was: Any?, now: String, inDemo: Bool) {
        let frames = Thread.callStackSymbols.dropFirst(2).prefix(6).map { line in
            line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first.map(String.init) ?? "?"
        }
        ownWriteCountForTests += 1
        ownWritesForTests.append("\(key): \(was.map { "\($0)" } ?? "absent") -> \"\(now)\" (inDemo \(inDemo)) from \(frames.joined(separator: " < "))")
        if ownWritesForTests.count > 8 { ownWritesForTests.removeFirst(ownWritesForTests.count - 8) }
    }
    #endif
    var botColorsRaw: String { didSet { if botColorsRaw != oldValue { d.set(botColorsRaw, forKey: BotColors.storageKey) } } }
    var botAvatarsRaw: String { didSet { if botAvatarsRaw != oldValue { d.set(botAvatarsRaw, forKey: BotAvatarStore.storageKey) } } }
    var glassAll: Bool { didSet { if glassAll != oldValue { d.set(glassAll, forKey: BotAvatarStore.glassAllKey) } } }

    private init() {
        allBots = d.object(forKey: "chats.allBots") as? Bool ?? false
        aiTitles = d.object(forKey: ChatSummarizer.titlesKey) as? Bool ?? ChatSummarizer.titlesOn
        aiPreviews = d.object(forKey: ChatSummarizer.previewsKey) as? Bool ?? ChatSummarizer.previewsOn
        pinnedOnly = d.object(forKey: "chats.filter.pinned") as? Bool ?? false
        needsYouOnly = d.object(forKey: "chats.filter.needsYou") as? Bool ?? false
        liveOnly = d.object(forKey: "chats.filter.live") as? Bool ?? false
        showArchived = d.object(forKey: "chats.filter.archived") as? Bool ?? true
        sortKey = d.object(forKey: "chats.sort") as? String ?? "recent"
        groupsOnly = d.object(forKey: "chats.filter.groups") as? Bool ?? false
        projectFilter = d.object(forKey: "chats.filter.project") as? String ?? ""
        byProject = d.object(forKey: "chats.byProject") as? Bool ?? false
        collapsedRaw = d.object(forKey: "chats.byProject.collapsed") as? String ?? ""
        archivedRoomsRaw = d.object(forKey: "chats.archivedRooms") as? String ?? ""
        scheduledOpen = d.bool(forKey: "chats.scheduled.open")
        botColorsRaw = d.object(forKey: BotColors.storageKey) as? String ?? ""
        botAvatarsRaw = d.object(forKey: BotAvatarStore.storageKey) as? String ?? ""
        glassAll = d.object(forKey: BotAvatarStore.glassAllKey) as? Bool ?? false
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: d, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Another screen wrote one of the keys: take the new value, only where it differs.
    private func refresh() {
        refreshing = true
        defer { refreshing = false }
        let new_allBots = d.object(forKey: "chats.allBots") as? Bool ?? false; if new_allBots != allBots { allBots = new_allBots }
        let new_aiTitles = d.object(forKey: ChatSummarizer.titlesKey) as? Bool ?? ChatSummarizer.titlesOn; if new_aiTitles != aiTitles { aiTitles = new_aiTitles }
        let new_aiPreviews = d.object(forKey: ChatSummarizer.previewsKey) as? Bool ?? ChatSummarizer.previewsOn; if new_aiPreviews != aiPreviews { aiPreviews = new_aiPreviews }
        let new_pinnedOnly = d.object(forKey: "chats.filter.pinned") as? Bool ?? false; if new_pinnedOnly != pinnedOnly { pinnedOnly = new_pinnedOnly }
        let new_needsYouOnly = d.object(forKey: "chats.filter.needsYou") as? Bool ?? false; if new_needsYouOnly != needsYouOnly { needsYouOnly = new_needsYouOnly }
        let new_liveOnly = d.object(forKey: "chats.filter.live") as? Bool ?? false; if new_liveOnly != liveOnly { liveOnly = new_liveOnly }
        let new_showArchived = d.object(forKey: "chats.filter.archived") as? Bool ?? true; if new_showArchived != showArchived { showArchived = new_showArchived }
        let new_sortKey = d.object(forKey: "chats.sort") as? String ?? "recent"; if new_sortKey != sortKey { sortKey = new_sortKey }
        let new_groupsOnly = d.object(forKey: "chats.filter.groups") as? Bool ?? false; if new_groupsOnly != groupsOnly { groupsOnly = new_groupsOnly }
        let new_byProject = d.object(forKey: "chats.byProject") as? Bool ?? false; if new_byProject != byProject { byProject = new_byProject }
        let new_scheduledOpen = d.bool(forKey: "chats.scheduled.open"); if new_scheduledOpen != scheduledOpen { scheduledOpen = new_scheduledOpen }
        if !inDemo {
            let new_projectFilter = d.object(forKey: "chats.filter.project") as? String ?? ""; if new_projectFilter != projectFilter { projectFilter = new_projectFilter }
            let new_collapsedRaw = d.object(forKey: "chats.byProject.collapsed") as? String ?? ""; if new_collapsedRaw != collapsedRaw { collapsedRaw = new_collapsedRaw }
            let new_archivedRoomsRaw = d.object(forKey: "chats.archivedRooms") as? String ?? ""; if new_archivedRoomsRaw != archivedRoomsRaw { archivedRoomsRaw = new_archivedRoomsRaw }
        }
        let new_botColorsRaw = d.object(forKey: BotColors.storageKey) as? String ?? ""; if new_botColorsRaw != botColorsRaw { botColorsRaw = new_botColorsRaw }
        let new_botAvatarsRaw = d.object(forKey: BotAvatarStore.storageKey) as? String ?? ""; if new_botAvatarsRaw != botAvatarsRaw { botAvatarsRaw = new_botAvatarsRaw }
        let new_glassAll = d.object(forKey: BotAvatarStore.glassAllKey) as? Bool ?? false; if new_glassAll != glassAll { glassAll = new_glassAll }
    }
}
