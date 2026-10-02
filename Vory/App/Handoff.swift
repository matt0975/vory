import SwiftUI
import VoryCore

/// Handoff: the chat open on one device is offered on the person's others (the Dock on a Mac,
/// the app switcher on an iPhone), and picking it up opens the same chat there. The system
/// carries it between devices signed in to the same iCloud account; nothing goes through Vory.
@MainActor
enum ChatHandoff {
    nonisolated static let activityType = "com.vorantx.vory.chat"

    /// What travels: which chat, whose, and on which gateway (its address, since each device
    /// keeps its own id for a saved gateway).
    static func fill(_ activity: NSUserActivity, chat: ChatSession) {
        activity.title = chat.title
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.userInfo = [
            "session": chat.storedID,
            "profile": chat.profileName,
            "gateway": chat.runtime.connection.gateway.description,
        ]
        activity.requiredUserInfoKeys = ["session"]
    }

    /// Opens the chat an activity names. A chat on another saved gateway switches to it first;
    /// one on a gateway this device does not have is left alone.
    static func open(_ activity: NSUserActivity, model: AppModel) {
        guard let info = activity.userInfo, let session = info["session"] as? String, !session.isEmpty else { return }
        var parts = URLComponents()
        parts.scheme = "vory"
        parts.host = "chat"
        parts.path = "/" + session
        if let profile = info["profile"] as? String, !profile.isEmpty { parts.queryItems = [URLQueryItem(name: "profile", value: profile)] }
        guard let url = parts.url else { return }
        let gateway = info["gateway"] as? String
        if let gateway, model.runtime?.connection.gateway.description != gateway {
            guard let saved = model.store.connections.first(where: { $0.gateway.description == gateway }) else { return }
            Task { await model.activate(saved); model.open(url) }
        } else {
            model.open(url)
        }
    }
}

extension View {
    /// Offers this chat to the person's other devices while it is on screen.
    func handsOff(_ chat: ChatSession) -> some View {
        // A fresh chat has no stored id until its first message: nothing to hand over yet.
        userActivity(ChatHandoff.activityType, isActive: !chat.storedID.isEmpty) { activity in
            ChatHandoff.fill(activity, chat: chat)
        }
    }

    /// Picks up a chat handed over from another device.
    func continuesHandoff(_ model: AppModel) -> some View {
        onContinueUserActivity(ChatHandoff.activityType) { activity in
            ChatHandoff.open(activity, model: model)
        }
    }
}
