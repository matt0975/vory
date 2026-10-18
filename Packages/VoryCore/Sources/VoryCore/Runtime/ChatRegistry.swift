import Foundation

/// The two ids a live chat carries: the stable stored id the user navigates by, and the
/// gateway's runtime id that every inbound event and server request is stamped with.
@MainActor
public protocol ChatIdentity: AnyObject {
    var runtimeID: String { get }
    var storedID: String { get }
}

/// Open chats, looked up by whichever id the caller has.
///
/// Nothing here is keyed by runtime id on purpose. `session.resume` after a reconnect can hand
/// a chat a NEW runtime id, and a dictionary keyed once by the old one silently dropped every
/// `message.delta` for the rest of the session — the app submitted prompts fine, the gateway
/// ran them, and nothing ever rendered. A handful of open chats makes the scan free.
@MainActor
public struct ChatRegistry<Chat: ChatIdentity> {
    public private(set) var all: [Chat] = []

    /// Session-less events must not match a chat whose runtime id is still awaiting attach.
    public func byRuntime(_ id: String) -> Chat? { id.isEmpty ? nil : all.first(where: { $0.runtimeID == id }) }
    public func byStored(_ id: String) -> Chat? { all.first { $0.storedID == id } }

    /// Registers a chat, replacing any earlier entry for the same stored id.
    public mutating func add(_ chat: Chat) {
        all.removeAll { $0.storedID == chat.storedID }
        all.append(chat)
    }

    public mutating func remove(_ chat: Chat) { all.removeAll { $0 === chat } }
}
