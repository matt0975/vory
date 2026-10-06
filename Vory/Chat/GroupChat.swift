import SwiftUI
import VoryCore

/// Who in a group chat is working right now, read from the room's log. In order of trust:
///
/// - The gateway's word about a member: a turn it opened for them (`turn.started`) until it
///   closes it (`turn.settled`, `turn.failed`, `turn.cancelled`, `turn.deferred`) or they
///   speak; or a `room.activity` that names a member (by id or handle in its payload, or
///   "<name> is typing…") with a working status, until a resting one.
/// - When the gateway files only the ends of turns (a hosted room files no start), its turn
///   order: the bots answer a message one at a time, the ones it @mentions (all of them when it
///   mentions none) in the room's order, so the first of those not heard from since is the one
///   working; after them, a bot another bot @mentioned that has not answered yet. A room that
///   has said it settled, or a message nothing has followed for `guessWindow`, has nobody
///   working.
enum GroupActivity {
    /// How long an unanswered message keeps its guessed bot working: past it, the room's driver
    /// is more likely down than the bot still at it.
    static let guessWindow: TimeInterval = 10 * 60
    private static let workingWords = ["typing", "thinking", "working", "composing", "writing", "running", "responding"]
    private static let restingWords = ["settled", "bounded", "idle", "done", "stopped", "finished", "failed", "cancelled", "canceled"]
    private static let closingTurns: Set<String> = ["turn.settled", "turn.failed", "turn.cancelled", "turn.deferred", "member.unavailable"]

    /// One member, the same however an event names it.
    static func key(_ m: RoomMember) -> String { m.memberId ?? m.handle ?? m.profile ?? m.displayName ?? "" }
    /// The bot whose face a member wears.
    static func profile(of m: RoomMember) -> String { m.profile ?? m.handle ?? "?" }
    static func name(of m: RoomMember) -> String { m.displayName ?? m.handle ?? m.profile ?? "Bot" }
    /// "Alpha", "Alpha and Beta", "Alpha, Beta and Gamma".
    static func names(_ members: [RoomMember]) -> String { members.map(name(of:)).formatted(.list(type: .and)) }

    /// The member a word names: its id, handle, bot or name, with or without an @.
    static func member(_ name: String?, in members: [RoomMember]) -> RoomMember? {
        guard var k = name?.trimmingCharacters(in: .whitespaces).lowercased(), !k.isEmpty else { return nil }
        if k.hasPrefix("@") { k.removeFirst() }
        return members.first { [$0.memberId, $0.handle, $0.profile, $0.displayName].compactMap { $0?.lowercased() }.contains(k) }
    }

    /// The member an event is about: the one its payload names, else its actor when that is a member.
    static func subject(of ev: RoomEvent, in members: [RoomMember]) -> RoomMember? {
        for field in ["member_id", "handle", "member", "profile"] {
            if let m = member(ev.payload[field]?.stringValue, in: members) { return m }
        }
        return ev.actor.kind == "member" ? member(ev.actor.id, in: members) : nil
    }

    /// The members a message @mentions, in the room's order (everyone for @all or @everyone):
    /// the handles the gateway itself resolves, by the same pattern.
    static func mentioned(in text: String, members: [RoomMember]) -> [RoomMember] {
        let handles = Set(text.matches(of: /@([A-Za-z0-9][A-Za-z0-9._:-]*)/).map { String($0.1).lowercased() })
        guard !handles.isEmpty else { return [] }
        if handles.contains("all") || handles.contains("everyone") { return members }
        return members.filter { handles.contains(($0.handle ?? $0.profile ?? "").lowercased()) }
    }

    private static func status(_ ev: RoomEvent) -> String {
        (ev.payload["status"]?.stringValue ?? ev.payload["state"]?.stringValue ?? ev.payload["text"]?.stringValue ?? "").lowercased()
    }
    private static func text(_ ev: RoomEvent) -> String {
        ev.payload["text"]?.stringValue ?? ev.payload["content"]?.stringValue ?? ""
    }

    /// The members working now, in the room's order.
    static func working(members: [RoomMember], events: [RoomEvent], now: Date = Date()) -> [RoomMember] {
        var active = Set<String>()
        // Once the room has said who started (a turn opened, someone typing), it is taken at
        // its word; a room that never does is read by the gateway's turn order instead.
        var reportsStarts = false
        var question: RoomEvent?
        var heard = Set<String>()
        var lastSaid: [String: Int] = [:]
        var citedAt: [String: Int] = [:]
        var lastAt: Double = 0
        let ordered = zip(events, events.dropFirst()).allSatisfy { $0.seq <= $1.seq } ? events : events.sorted { $0.seq < $1.seq }
        for ev in ordered {
            let who = subject(of: ev, in: members)
            switch ev.kind {
            case "message.user":
                question = ev; heard = []; lastSaid = [:]; citedAt = [:]; lastAt = ev.createdAt
            case "message.member":
                lastAt = ev.createdAt
                guard let who else { break }
                let k = key(who)
                active.remove(k); heard.insert(k); lastSaid[k] = ev.seq
                for m in mentioned(in: text(ev), members: members) where key(m) != k { citedAt[key(m)] = ev.seq }
            case "turn.started":
                lastAt = ev.createdAt
                reportsStarts = true
                if let who { active.insert(key(who)) }
            case _ where closingTurns.contains(ev.kind):
                lastAt = ev.createdAt
                if let who { let k = key(who); active.remove(k); heard.insert(k); lastSaid[k] = max(lastSaid[k] ?? 0, ev.seq) }
            case "room.activity":
                let s = status(ev)
                let named = who ?? member(s.split(separator: " ").first.map(String.init), in: members)
                if workingWords.contains(where: s.contains) {
                    if let named { active.insert(key(named)); reportsStarts = true }
                } else if restingWords.contains(where: s.contains) {
                    if let named { active.remove(key(named)) } else {
                        active.removeAll()
                        // The room settled the message it names (or, naming none, the one it is on).
                        let about = ev.payload["discussion_event_id"]?.stringValue
                        if about == nil || about == question?.eventId { question = nil }
                    }
                }
            case "room.stop_requested", "room.disbanded":
                active.removeAll(); question = nil
            default:
                break
            }
        }
        let working = members.filter { active.contains(key($0)) }
        guard working.isEmpty, !reportsStarts, let question, now.timeIntervalSince1970 - lastAt < guessWindow else { return working }
        let asked = mentioned(in: text(question), members: members)
        let next = (asked.isEmpty ? members : asked).first { !heard.contains(key($0)) }
            ?? members.first { m in citedAt[key(m)].map { $0 > (lastSaid[key(m)] ?? 0) } ?? false }
        return next.map { [$0] } ?? []
    }
}

/// A group chat's typing indicator, the one a single chat has: the working bot beside a typing
/// bubble with its name over it, or, when more than one is at it, their bots side by side with
/// all their names over the one bubble.
struct GroupTypingRow: View {
    var members: [RoomMember]

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Array(members.prefix(4).enumerated()), id: \.offset) { i, m in
                    BotAvatar(profile: GroupActivity.profile(of: m), size: 28, active: true,
                              mood: BotFaceView.Mood(profile: "room-typing-\(GroupActivity.key(m))", state: .thinking, groupIndex: i, groupCount: members.count))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(GroupActivity.names(members)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 6)
                TypingBubble()
            }
            Spacer(minLength: 40)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(GroupActivity.names(members)) \(members.count == 1 ? "is" : "are") typing")
        .accessibilityIdentifier("group.typing")
    }
}

/// The members' faces as overlapping circles, the first in front, like a group's picture in
/// Messages. A bot that is working moves; the others keep still.
struct GroupFaces: View {
    var members: [RoomMember]
    var working: [RoomMember] = []
    var size: CGFloat = 40
    var limit = 4
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shown = Array(members.prefix(limit))
        let busy = Set(working.map(GroupActivity.key))
        HStack(spacing: -size * 0.3) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, m in
                let on = busy.contains(GroupActivity.key(m))
                let profile = GroupActivity.profile(of: m)
                BotAvatar(profile: profile, size: size * 0.76, active: on,
                          mood: BotFaceView.Mood(profile: "room-face-\(GroupActivity.key(m))", state: on ? .thinking : .idle, still: !on && i != 0))
                    .frame(width: size, height: size)
                    .background(BotColors.color(for: profile).opacity(scheme == .dark ? 0.28 : 0.18), in: .circle)
                    .background(Color(.systemBackground), in: .circle)
                    .clipShape(.circle)
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                    .zIndex(Double(shown.count - i))
            }
            if members.count > limit {
                Text("+\(members.count - limit)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color(.secondarySystemBackground), in: .circle)
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A group chat's header on the phone, the way Messages heads a group: the bots' faces
/// overlapping above the chat's name, the members named under it, and the whole plate a button
/// for the member list. The back circle is a single chat's.
struct GroupChatHeader: View {
    var room: Room
    var working: [RoomMember]
    var onBack: () -> Void
    var onMembers: () -> Void

    private static func short(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…" : s }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain).accessibilityLabel("Back").accessibilityIdentifier("group.back")
            Spacer(minLength: 0)
            Button(action: onMembers) {
                // The faces sit on the plate's top edge, as a single chat's bot does.
                VStack(spacing: -8) {
                    GroupFaces(members: room.members, working: working, size: 38)
                        .zIndex(1)
                        .allowsHitTesting(false)
                    VStack(spacing: 1) {
                        HStack(spacing: 3) {
                            Text(Self.short(room.name, 26)).font(.caption.weight(.semibold)).lineLimit(1)
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        }
                        // Shortened in code, not by a frame: the plate hugs its text (fixedSize).
                        Text(Self.short(GroupActivity.names(room.members), 42)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 6)
                    .fixedSize()
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(room.name): \(GroupActivity.names(room.members))")
            .accessibilityHint("Shows the members")
            .accessibilityIdentifier("group.header")
            Spacer(minLength: 0)
            // As wide as the back circle, so the plate stays in the middle.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        // One surface: a tap on the bar stays on it and never reaches the thread under it.
        .contentShape(.rect)
        .onTapGesture {}
    }
}

/// The Mac's group header, in the middle of the toolbar where a single chat shows its bot: the
/// faces and the chat's name, a click for the member list.
struct GroupToolbarTitle: View {
    var room: Room
    var working: [RoomMember]
    var onMembers: () -> Void

    var body: some View {
        Button(action: onMembers) {
            HStack(spacing: 8) {
                GroupFaces(members: room.members, working: working, size: 24)
                Text(room.name).font(.headline).lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .help(GroupActivity.names(room.members))
        .accessibilityLabel("\(room.name): \(GroupActivity.names(room.members))")
        .accessibilityHint("Shows the members")
        .accessibilityIdentifier("group.header")
    }
}

/// Who is in a group chat: each bot with its handle and model, and whether it is working now. A
/// bot of this gateway opens its profile page, the one a single chat's header opens.
struct GroupMembersSheet: View {
    var room: Room
    var working: [RoomMember]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsList {
                Section {
                    ForEach(Array(room.members.enumerated()), id: \.offset) { _, m in
                        if let p = model.runtime?.profiles.first(where: { $0.name == m.profile }) {
                            NavigationLink { ProfileCardView(profileName: p.name) } label: { row(m, model: p.model) }
                        } else {
                            row(m, model: nil)
                        }
                    }
                } header: {
                    Text(room.members.count == 1 ? "1 bot" : "\(room.members.count) bots")
                } footer: {
                    Text("Mention a bot with @ and its handle to ask it alone.")
                }
            }
            .navigationTitle(room.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ m: RoomMember, model: String?) -> some View {
        let on = working.contains { GroupActivity.key($0) == GroupActivity.key(m) }
        let handle = m.handle ?? m.profile
        return HStack(spacing: 12) {
            BotAvatar(profile: GroupActivity.profile(of: m), size: 36, active: on,
                      mood: BotFaceView.Mood(profile: "room-member-\(GroupActivity.key(m))", state: on ? .thinking : .idle))
            VStack(alignment: .leading, spacing: 2) {
                Text(GroupActivity.name(of: m)).font(.body.weight(.medium))
                Text([handle.map { "@" + $0 }, model.map { $0.split(separator: "/").last.map(String.init) ?? $0 }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if on {
                Text("Working").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: .capsule).foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
