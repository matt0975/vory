import Foundation

/// The last transcript this device saw for a session, so reopening a chat draws instantly while
/// the live `session.resume` runs. One JSON file per session under Caches; capped at 200 rows.
public enum TranscriptCache {
    static let cap = 200
    /// Encoding and writing happen here, in order, off the main thread: a save came with every
    /// finished reply and every snapshot, and a long chat's 200 rows took the main thread's time
    /// when the app came back and re-read its chats.
    private static let writer = DispatchQueue(label: "dev.vory.transcript-cache", qos: .utility)

    /// Where the session's file goes. Asking makes nothing: the folder is made by a save (#493: a read made a folder
    /// named after the gateway, the demo's too).
    static func url(connection: UUID, storedID: String) -> URL? {
        guard !storedID.isEmpty, let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appending(path: "transcripts/\(connection.uuidString)", directoryHint: .isDirectory)
        let safe = storedID.replacingOccurrences(of: "/", with: "_")
        return dir.appending(path: "\(safe).json")
    }

    public static func load(connection: UUID, storedID: String) -> [TranscriptMessage]? {
        guard let u = url(connection: connection, storedID: storedID), let data = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode([TranscriptMessage].self, from: data)
    }

    public static func save(_ items: [TranscriptItem], connection: UUID, storedID: String) {
        guard let u = url(connection: connection, storedID: storedID) else { return }
        let rows = items.suffix(cap).compactMap { item -> TranscriptMessage? in
            let ts = item.timestamp.timeIntervalSince1970
            switch item.kind {
            case .user(let t, _): return TranscriptMessage(role: "user", text: t, timestamp: ts, rowId: item.rowID)
            // A step that only thought keeps its card, marked as asking for tools: reloaded, its
            // reasoning is never taken for the turn's answer (`TranscriptItem.promotedAnswer`).
            case .assistant(let t, let r, _) where item.isThinkingOnly:
                return TranscriptMessage(role: "assistant", text: t, timestamp: ts, rowId: item.rowID, reasoning: r, finishReason: "tool_calls", hasToolCalls: true)
            case .assistant(let t, let r, _): return t.isEmpty ? nil : TranscriptMessage(role: "assistant", text: t, timestamp: ts, rowId: item.rowID, reasoning: r)
            case .tool(let a): return TranscriptMessage(role: "tool", text: a.resultText, timestamp: ts, rowId: item.rowID, name: a.name, context: a.context)
            case .system(let t, _): return TranscriptMessage(role: "system", text: t, timestamp: ts, rowId: item.rowID)
            case .steer(let t, _): return TranscriptMessage(role: "user", text: t, timestamp: ts, rowId: item.rowID)
            case .error, .subagent: return nil
            }
        }
        writer.async {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(rows) { try? data.write(to: u, options: .atomic) }
        }
    }

    /// The session's last known settings (its model above all), kept beside the transcript so a
    /// chat reopens with its model's name on the chip, not "Model" until the attach answers.
    static func infoURL(connection: UUID, storedID: String) -> URL? {
        url(connection: connection, storedID: storedID)?.deletingPathExtension().appendingPathExtension("info.json")
    }

    public static func loadInfo(connection: UUID, storedID: String) -> SessionLiveInfo? {
        guard let u = infoURL(connection: connection, storedID: storedID), let data = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(SessionLiveInfo.self, from: data)
    }

    public static func saveInfo(_ info: SessionLiveInfo, connection: UUID, storedID: String) {
        guard let u = infoURL(connection: connection, storedID: storedID) else { return }
        writer.async {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(info) { try? data.write(to: u, options: .atomic) }
        }
    }

    /// Waits for the saves already asked for (tests, and a clear that must come after them).
    public static func flush() { writer.sync {} }

    public static func clearAll() {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        // After any save still on its way, which would otherwise put a file back.
        writer.sync { try? FileManager.default.removeItem(at: base.appending(path: "transcripts")) }
    }
}
