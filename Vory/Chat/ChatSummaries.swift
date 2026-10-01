import FoundationModels
import SwiftUI
import VoryCore

/// Vory Summaries (beta): the on-device Apple Intelligence model turns a chat's recent messages
/// into a short title and a two-line summary for the Chats list. Nothing leaves the phone and
/// nothing is written to the gateway; switching it off shows the gateway's own title and
/// preview again. Results are cached per chat and redone only when the chat changes.
@MainActor @Observable
final class ChatSummarizer {
    static let shared = ChatSummarizer()
    static let enabledKey = "chats.aiSummaries"
    /// The two halves, switchable one at a time: the model's title for a chat, and its two-line
    /// preview. Unset, each follows the old single switch.
    static let titlesKey = "chats.aiSummaries.titles"
    static let previewsKey = "chats.aiSummaries.previews"
    static var titlesOn: Bool { UserDefaults.standard.object(forKey: titlesKey) as? Bool ?? UserDefaults.standard.bool(forKey: enabledKey) }
    static var previewsOn: Bool { UserDefaults.standard.object(forKey: previewsKey) as? Bool ?? UserDefaults.standard.bool(forKey: enabledKey) }

    struct Summary: Codable, Equatable { var title: String; var summary: String; var stamp: Double }

    @Generable
    struct Draft {
        @Guide(description: "A title for the conversation in at most six words, no quotes, no trailing period.")
        var title: String
        @Guide(description: "What the conversation is about and where it stands, in one or two short sentences, at most 140 characters.")
        var summary: String
    }

    private(set) var summaries: [String: Summary] = [:]
    private var inFlight: Set<String> = []
    /// One generation at a time, at utility priority: several at once stuttered the list.
    private enum Job { case session(StoredSession, GatewayRuntime, String?); case room(Room, [RoomEvent]) }
    private var pending: [Job] = []
    private var draining = false
    private static let cacheKey = "chats.aiSummaries.cache"

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.cacheKey), let m = try? JSONDecoder().decode([String: Summary].self, from: d) { summaries = m }
    }

    /// Whether the on-device model can run here (Apple Intelligence on, model downloaded).
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This device does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in \(DeviceWords.settings) first."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading its model."
        case .unavailable: return "Apple Intelligence is not available right now."
        }
    }

    var enabled: Bool { Self.titlesOn || Self.previewsOn }

    /// What the row shows: the summary with the switched-off half replaced by the gateway's own text.
    func shown(_ s: Summary?, title: String, preview: String) -> Summary? {
        guard let s, enabled else { return nil }
        return Summary(title: Self.titlesOn ? s.title : title, summary: Self.previewsOn ? s.summary : preview, stamp: s.stamp)
    }

    /// Drops every stored summary; rows fall back to the gateway's text until new ones are made.
    func forgetAll() {
        summaries = [:]
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        #if os(iOS)
        if WatchSync.summariesToWatch { WatchSync.shared.refresh() }
        #endif
    }

    /// The summary for a chat if it is current (same last-activity stamp); nil otherwise.
    func summary(for session: StoredSession) -> Summary? {
        guard enabled, let s = summaries[session.id], s.stamp == (session.lastActive ?? 0) else { return nil }
        return s
    }

    /// Makes (or refreshes) the summary for a chat from its recent messages, in the background.
    func refresh(_ session: StoredSession, runtime: GatewayRuntime, profile: String?) {
        guard enabled, Self.isAvailable, !inFlight.contains(session.id) else { return }
        if let s = summaries[session.id], s.stamp == (session.lastActive ?? 0) { return }
        inFlight.insert(session.id)
        pending.append(.session(session, runtime, profile))
        drain()
    }

    // MARK: Group chats — keyed "room:<id>", stamped with the last event's sequence number.

    static func roomKey(_ room: Room) -> String { "room:\(room.roomId)" }
    static func roomStamp(_ events: [RoomEvent]) -> Double { Double(events.last?.seq ?? 0) }

    func summary(forRoom room: Room, events: [RoomEvent]) -> Summary? {
        guard enabled, let s = summaries[Self.roomKey(room)], s.stamp == Self.roomStamp(events) else { return nil }
        return s
    }

    /// The room's recent messages are already in hand (the list fetched its log), so nothing is
    /// loaded here; the model gets the last ten things said.
    func refreshRoom(_ room: Room, events: [RoomEvent]) {
        let key = Self.roomKey(room)
        guard enabled, Self.isAvailable, !inFlight.contains(key), !events.isEmpty else { return }
        if let s = summaries[key], s.stamp == Self.roomStamp(events) { return }
        inFlight.insert(key)
        pending.append(.room(room, events))
        drain()
    }

    private func drain() {
        guard !draining, !pending.isEmpty else { return }
        draining = true
        let job = pending.removeFirst()
        Task(priority: .utility) {
            switch job {
            case .session(let session, let runtime, let profile):
                await generate(session, runtime: runtime, profile: profile)
                inFlight.remove(session.id)
            case .room(let room, let events):
                await generateRoom(room, events: events)
                inFlight.remove(Self.roomKey(room))
            }
            draining = false
            drain()
        }
    }

    private func generateRoom(_ room: Room, events: [RoomEvent]) async {
        let lines: [String] = events.compactMap { ev in
            guard ev.kind.hasPrefix("message.") else { return nil }
            let text = ev.payload["text"]?.stringValue ?? ev.payload["content"]?.stringValue ?? ""
            guard !text.isEmpty else { return nil }
            if ev.kind == "message.user" { return "User: \(text.prefix(600))" }
            let who = ev.payload["member_id"]?.stringValue ?? ev.actor.id
            let name = room.members.first { $0.memberId == who || $0.handle == who }?.displayName ?? who
            return "\(name): \(text.prefix(600))"
        }
        guard !lines.isEmpty else { return }
        do {
            let ai = LanguageModelSession(instructions: "You summarize a group conversation between a user and several AI assistants for a chat list. Be concrete and neutral. Do not mention that it is a conversation or a summary.")
            let draft = try await ai.respond(to: "Conversation:\n\(lines.suffix(10).joined(separator: "\n"))", generating: Draft.self).content
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".\"'"))
            let text = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !text.isEmpty else { return }
            summaries[Self.roomKey(room)] = Summary(title: title.isEmpty ? room.name : title, summary: text, stamp: Self.roomStamp(events))
            save()
        } catch {
            // The model can refuse or time out; the row keeps the room's own text.
        }
    }

    private func generate(_ session: StoredSession, runtime: GatewayRuntime, profile: String?) async {
        do {
            let messages = await recentMessages(session, runtime: runtime, profile: profile)
            guard !messages.isEmpty else { return }
            let transcript = messages.map { "\($0.role == "user" ? "User" : "Assistant"): \(($0.text ?? "").prefix(600))" }.joined(separator: "\n")
            let ai = LanguageModelSession(instructions: "You summarize a conversation between a user and an AI assistant for a chat list. Be concrete and neutral. Do not mention that it is a conversation or a summary.")
            let draft = try await ai.respond(to: "Conversation:\n\(transcript)", generating: Draft.self).content
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".\"'"))
            let text = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !text.isEmpty else { return }
            summaries[session.id] = Summary(title: title.isEmpty ? session.displayTitle : title, summary: text, stamp: session.lastActive ?? 0)
            save()
        } catch {
            // The model can refuse or time out; the row keeps the gateway's own text.
        }
    }

    private func recentMessages(_ session: StoredSession, runtime: GatewayRuntime, profile: String?) async -> [TranscriptMessage] {
        if let cached = TranscriptCache.load(connection: runtime.connection.id, storedID: session.id), !cached.isEmpty {
            return Array(cached.filter { ($0.role == "user" || $0.role == "assistant") && !($0.text ?? "").isEmpty }.suffix(10))
        }
        guard let r: JSONValue = try? await runtime.api.get("/api/sessions/\(session.id)/messages",
                                                             query: [URLQueryItem(name: "order", value: "latest"), URLQueryItem(name: "limit", value: "14")],
                                                             profile: profile ?? session.profile ?? runtime.selectedProfile) else { return [] }
        let all = (r["messages"]?.arrayValue ?? []).compactMap { try? $0.decode(TranscriptMessage.self) }
        return Array(all.filter { ($0.role == "user" || $0.role == "assistant") && !($0.text ?? "").isEmpty }.suffix(10))
    }

    private func save() {
        // Keep the cache bounded: the newest 300 chats.
        if summaries.count > 300 {
            let keep = summaries.sorted { $0.value.stamp > $1.value.stamp }.prefix(300)
            summaries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let d = try? JSONEncoder().encode(summaries) { UserDefaults.standard.set(d, forKey: Self.cacheKey) }
        #if os(iOS)
        if WatchSync.summariesToWatch { WatchSync.shared.refresh() }
        #endif
    }
}
