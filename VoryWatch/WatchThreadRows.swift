import SwiftUI
import VoryCore
import WatchKit

struct WatchTranscriptRow: View {
    var item: TranscriptItem
    /// The bot the reply came from: a small face beside each reply, as on the phone.
    var profile: String? = nil
    var body: some View {
        switch item.kind {
        case .user(let t, _):
            if let notice = WatchNotice.parse(t) {
                // Another bot writing in, or the gateway reporting: a quiet line, not your own bubble.
                VStack(alignment: .leading, spacing: 2) {
                    Label(notice.title, systemImage: notice.symbol).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    if !notice.body.isEmpty { Text(notice.body).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                }
            } else {
                HStack { Spacer(minLength: 24); Text(t).font(.footnote).padding(8).background(Color.accentColor, in: .rect(cornerRadius: 12)).foregroundStyle(.white) }
            }
        case .assistant(let raw, _, let streaming):
            // Pictures the bot sent are names here, not paths: the MEDIA: line stays out.
            let t = MediaScan.textWithoutMedia(raw)
            HStack(alignment: .bottom, spacing: 4) {
                if let profile { WatchBotFace(profile: profile, size: 16).accessibilityHidden(true) }
                // Bold, italics, code and links once the reply is whole; plain while it streams.
                Group {
                    if streaming { Text(t.isEmpty ? "…" : t) } else { Text(WatchMarkdown.inline(t)) }
                }
                .font(.footnote).padding(8).background(Color.gray.opacity(0.25), in: .rect(cornerRadius: 12))
                Spacer(minLength: 12)
            }
        case .tool(let a):
            Label("\(a.displayName)\(a.summary.map { " · \($0)" } ?? "")", systemImage: a.status == .done ? "checkmark.circle" : a.status == .failed ? "xmark.circle" : "gear")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        case .system(let t, let sym):
            Label(t, systemImage: sym).font(.caption2).foregroundStyle(.secondary)
        case .error(let t):
            Label(t, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.red)
        case .subagent(let a):
            Label(a.detailLine.map { "\(a.goal) · \($0)" } ?? a.goal, systemImage: "person.2").font(.caption2).foregroundStyle(.secondary)
        case .steer(let t, _):
            Text(t).font(.caption).padding(6).background(Color.gray.opacity(0.3), in: .rect(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// A message in the user's seat that is not the user's: another bot, or the gateway.
struct WatchNotice {
    var title: String
    var body: String
    var symbol: String

    /// Cheap checks first: almost every message is an ordinary one.
    static func parse(_ text: String) -> WatchNotice? {
        let t = text.drop { $0 == " " || $0 == "\n" }
        if t.hasPrefix("Message from") || t.hasPrefix("[Message from agent") {
            if let m = AgentMessage.parse(text) { return WatchNotice(title: "Message from \(m.sender)", body: m.body, symbol: "bubble.left.and.bubble.right") }
        } else if t.hasPrefix("[") {
            if let n = InjectedNote.parse(text) { return WatchNotice(title: n.title, body: "", symbol: "gearshape.2") }
        }
        return nil
    }
}

/// Inline markdown for finished replies, parsed once per text.
@MainActor
enum WatchMarkdown {
    private static var cache: [Int: AttributedString] = [:]

    static func inline(_ text: String) -> AttributedString {
        let key = text.hashValue
        if let hit = cache[key] { return hit }
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(text)
        if cache.count > 80 { cache.removeAll(keepingCapacity: true) }
        cache[key] = parsed
        return parsed
    }
}
