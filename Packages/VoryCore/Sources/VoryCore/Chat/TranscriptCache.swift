import Foundation

/// The last transcript this device saw for a session, so reopening a chat draws instantly while
/// the live `session.resume` runs. One JSON file per session under Caches; capped at 200 rows.
public enum TranscriptCache {
    static let cap = 200
    /// Encoding and writing happen here, in order, off the main thread: a save came with every
    /// finished reply and every snapshot, and a long chat's 200 rows took the main thread's time
    /// when the app came back and re-read its chats.
    private static let writer = DispatchQueue(label: "dev.vory.transcript-cache", qos: .utility)

    static func url(connection: UUID, storedID: String) -> URL? {
        guard !storedID.isEmpty, let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appending(path: "transcripts/\(connection.uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
            case .assistant(let t, let r, _): return t.isEmpty ? nil : TranscriptMessage(role: "assistant", text: t, timestamp: ts, rowId: item.rowID, reasoning: r)
            case .tool(let a): return TranscriptMessage(role: "tool", text: a.resultText, timestamp: ts, rowId: item.rowID, name: a.name, context: a.context)
            case .system(let t, _): return TranscriptMessage(role: "system", text: t, timestamp: ts, rowId: item.rowID)
            case .steer(let t, _): return TranscriptMessage(role: "user", text: t, timestamp: ts, rowId: item.rowID)
            case .error, .subagent: return nil
            }
        }
        writer.async {
            if let data = try? JSONEncoder().encode(rows) { try? data.write(to: u, options: .atomic) }
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
