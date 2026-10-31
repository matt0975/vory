#if os(iOS)
import Foundation
import SwiftUI
import UIKit
import VoryCore

/// Coming back to the chat that was open, after the system ended the app in the background.
///
/// iOS ends a suspended app when another needs the memory, and the next open is a cold launch.
/// Vory started those on the chat list, which a tester reads as "it crashed in the background"
/// (#371). The chat on screen is remembered as the app leaves the screen; a cold launch within
/// the hour opens it again, through the route Siri and Spotlight use (`openStoredChat`). After
/// two launches in a row that ended within a minute in front (a crash, perhaps in that very
/// chat), the app starts on the list instead.
///
/// Swiping the app away starts fresh, as iOS does (call #33): the chat is also kept in the
/// scene's own storage (`RestoreSceneKeeper`), which the system keeps across its own ends and
/// drops when the person swipes the app away, and both have to agree.
@MainActor
enum AppRestore {
    struct Saved: Codable, Equatable {
        var storedID: String
        var profile: String?
        var connectionID: UUID
        /// The gateway's address too: the demo copy adds its gateway afresh at every launch.
        var gateway: String?
        var leftAt: Date
        /// The chat's title, for its header as it reopens (a record from before it reads nil).
        var title: String?
    }

    nonisolated static let savedKey = "restore.openChat"
    /// The launch in front that has not yet lasted a minute or left the screen: still set at
    /// the next launch, it ended in front within a minute.
    nonisolated static let launchedAtKey = "restore.launchedAt"
    /// Launches in a row that ended that way.
    nonisolated static let shortLaunchesKey = "restore.shortLaunches"
    nonisolated static let longestAway: TimeInterval = 60 * 60
    nonisolated static let shortLaunch: TimeInterval = 60

    /// Whether to open `saved` again: the same gateway (the saved connection, or one at the same
    /// address), under an hour away, and not after a crash loop.
    nonisolated static func reopening(_ saved: Saved?, now: Date, connection: UUID?, gateway: String?, shortLaunches: Int) -> Saved? {
        guard let saved, shortLaunches < 2, connection != nil else { return nil }
        guard saved.connectionID == connection || (saved.gateway != nil && saved.gateway == gateway) else { return nil }
        let away = now.timeIntervalSince(saved.leftAt)
        return away >= 0 && away < longestAway ? saved : nil
    }

    private static var reopened = false
    /// The chat the scene's storage held at launch ("" for none); nil until a window says.
    private(set) static var sceneChatAtLaunch: String?

    /// A window's scene storage as the app launched: the first one seen in this process.
    static func sceneAppeared(holding storedID: String) {
        if sceneChatAtLaunch == nil { sceneChatAtLaunch = storedID }
    }

    /// Whether the scene agrees: the chat is the one its storage kept (none after a swipe away).
    nonisolated static func sceneAgrees(_ saved: Saved, sceneChat: String?) -> Bool {
        sceneChat == saved.storedID
    }

    /// Judges the launch before this one (still marked: it ended in front within a minute) and
    /// marks this one.
    nonisolated static func startLaunch(defaults: UserDefaults) {
        let previousEndedShort = defaults.object(forKey: launchedAtKey) != nil
        defaults.set(previousEndedShort ? defaults.integer(forKey: shortLaunchesKey) + 1 : 0, forKey: shortLaunchesKey)
        defaults.set(Date().timeIntervalSince1970, forKey: launchedAtKey)
    }

    /// This launch lasted a minute in front, or left the screen in one piece.
    nonisolated static func lasted(defaults: UserDefaults) {
        guard defaults.object(forKey: launchedAtKey) != nil else { return }
        defaults.removeObject(forKey: launchedAtKey)
        defaults.set(0, forKey: shortLaunchesKey)
    }

    /// The app in front again in a process that already looked at the saved chat: what the last
    /// time away saved is not this process's end, so it goes. A chat is reopened only after an end
    /// while the app was away, never one in front (a crash there, or a test ending the app), which
    /// would reopen a chat left behind long before.
    static func cameToFront(defaults: UserDefaults = .standard) {
        if reopened { defaults.removeObject(forKey: savedKey) }
    }

    /// The app leaving the screen: the chat on it (or none) is remembered.
    static func leftFront(_ model: AppModel, defaults: UserDefaults = .standard) {
        lasted(defaults: defaults)
        guard let saved = kept(id: model.visibleChatID, chat: model.visibleChat, runtime: model.runtime) else {
            defaults.removeObject(forKey: savedKey)
            return
        }
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: savedKey) }
    }

    /// What is kept of the chat on screen as the app leaves it: nothing for the demo (#494: its chat, under its gateway's
    /// id, stayed on the device until the next launch).
    static func kept(id: String?, chat: ChatSession?, runtime rt: GatewayRuntime?, now: Date = Date()) -> Saved? {
        guard let id, !id.isEmpty, let rt, !rt.isEphemeral else { return nil }
        let chat = chat?.storedID == id ? chat : nil
        return Saved(storedID: id, profile: chat?.profileName ?? rt.selectedProfile, connectionID: rt.connection.id,
                     gateway: rt.connection.gateway.description, leftAt: now, title: chat?.title)
    }

    /// Once per process, the first time it is in front with the saved gateway up (whichever of
    /// the two comes last calls it): opens the remembered chat when it is due and nothing else (a
    /// notification, a link, Siri) has asked for a chat first.
    static func reopenIfDue(_ model: AppModel, defaults: UserDefaults = .standard) {
        guard !reopened, model.runtime != nil, UIApplication.shared.applicationState != .background else { return }
        reopened = true
        // This launch is judged and marked here, the first time it is in front, until it lasts a
        // minute or leaves the screen.
        startLaunch(defaults: defaults)
        Task {
            try? await Task.sleep(for: .seconds(shortLaunch))
            lasted(defaults: defaults)
        }
        let saved = defaults.data(forKey: savedKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        // Read once: what was open is only worth reopening after this one end.
        defaults.removeObject(forKey: savedKey)
        guard model.pendingRoute == nil, model.visibleChatID == nil,
              let chat = reopening(saved, now: Date(), connection: model.runtime?.connection.id, gateway: model.runtime?.connection.gateway.description,
                                   shortLaunches: defaults.integer(forKey: shortLaunchesKey)),
              sceneAgrees(chat, sceneChat: sceneChatAtLaunch) else { return }
        model.openStoredChat(id: chat.storedID, profile: chat.profile, title: chat.title)
    }
}

/// The open chat in the scene's own storage, for `AppRestore`: the system keeps it when it ends
/// the app itself and drops it when the person swipes the app away. Kept current while a chat is
/// open and at every phase change, so the system's copy, taken as the scene goes to the
/// background, is never one write behind.
struct RestoreSceneKeeper: ViewModifier {
    let model: AppModel
    @Environment(\.scenePhase) private var phase
    @SceneStorage("restore.openChat") private var sceneChat = ""

    func body(content: Content) -> some View {
        content
            .onAppear { AppRestore.sceneAppeared(holding: sceneChat) }
            .onChange(of: model.visibleChatID) { _, _ in sceneChat = held }
            .onChange(of: phase) { _, _ in sceneChat = held }
    }

    /// The chat on screen, or none in the demo (#494).
    private var held: String { AppRestore.kept(id: model.visibleChatID, chat: nil, runtime: model.runtime)?.storedID ?? "" }
}
#endif
