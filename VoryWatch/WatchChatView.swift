import SwiftUI
import VoryCore
import WatchKit

/// One chat: the tail of the transcript, the card when one is waiting, and a composer pinned to the bottom edge so the
/// thread opens at its end. Its data and the one thing that drives it are the chat's feed (`WatchChatFeed`, #387): on
/// the Watch's own socket or through the iPhone, read when something changed rather than every few seconds. The view
/// only shows the feed and acts through it; the wrist buzzes only for the feed's arrivals (`WatchChatFeed.event`).
struct WatchChatView: View {
    @Environment(WatchModel.self) private var model
    var storedID: String
    @State private var feed: WatchChatFeed?
    @State private var text = ""
    /// Talk: a recording to the gateway, the reply read aloud here.
    @State private var talk = WatchTalk()
    /// What Talk could not do, under the thread until tapped.
    @State private var talkNote: String?
    /// The bottom bar's top edge and the thread's bottom edge, on screen: the room the thread leaves under its last row
    /// (the conversation ends above the composer, never under it).
    @State private var barTop: CGFloat = 0
    @State private var threadBottom: CGFloat = 0
    /// The person moved the thread (a scroll, Show earlier) since the first read landed: the late settle leaves it.
    @State private var movedByPerson = false

    var body: some View {
        Group {
            if let feed { thread(feed) } else { ProgressView() }
        }
        // Leaving the chat ends Talk's wait and voice: the reply would otherwise be read out later with no screen to
        // stop it from.
        .onDisappear { talk.stopWaiting(); talk.stopSpeaking() }
        // A feed of its own for each runtime (a new route or address): the old one ends with its task.
        .task(id: model.runtime.map(ObjectIdentifier.init)) {
            let f = WatchChatFeed(storedID: storedID, model: model)
            feed = f
            await f.run()
        }
    }

    private func thread(_ feed: WatchChatFeed) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if feed.hasEarlier {
                        // The last few messages first; the rest a page at a time from the top.
                        Button { movedByPerson = true; Task { await feed.loadEarlier() } } label: { Label("Show earlier", systemImage: "arrow.up.circle") }.font(.caption)
                    }
                    ForEach(feed.items) { item in WatchTranscriptRow(item: item, profile: feed.profile).id(item.id) }
                    if feed.isWorking { Text(Self.workingLine(feed)).font(.caption2).foregroundStyle(.secondary) }
                    // What went wrong (a send that did not get through, the iPhone out of reach, a Talk that heard nothing).
                    if let p = feed.problem { Text(p.text).font(.caption2).foregroundStyle(.red).onTapGesture { feed.dismissProblem() } }
                    if let talkNote { Text(talkNote).font(.caption2).foregroundStyle(.red).onTapGesture { self.talkNote = nil } }
                    if let card = feed.cards.first { WatchCardView(feed: feed, card: card).id(card.id) }
                    // Room for the bottom bar under the last row, the bar's own height as measured: the bar is laid over
                    // the content, and the last lines (or a card's buttons) ran under it. With the bar gone for a card,
                    // a little room for the screen's rounded edge.
                    Color.clear.frame(height: barShown(feed) ? max(8, threadBottom - barTop + 6) : 8).id("bottom")
                }
            }
            // The thread opens on its end and sits at the bottom when short. As it changes size it keeps its end in
            // view, but while a card waits it keeps its top: the bar giving way to the card changed the size, and held by
            // the end, the card slid back to its last two choices with the ask and Allow once out of sight.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .defaultScrollAnchor(feed.cards.isEmpty ? .bottom : .top, for: .sizeChanges)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { threadBottom = $0 }
            .onScrollPhaseChange { _, phase in if phase == .interacting { movedByPerson = true } }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            // The first read lands after the view does: land the end again once it is in, and once more when its rows have
            // been laid out. At the largest text the lazy stack placed the first scroll on its estimates of the tall rows,
            // past the content, and the chat opened blank (41 mm, ax); the view before the feed settled it the same way.
            // Restores the settle the view had before the feed (range B dropped it); after the first read only.
            .onChange(of: feed.isLoading) { _, loading in
                guard !loading else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
                movedByPerson = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    // Not over the person's own move in the meantime, nor over a card that came (it lands itself).
                    if !movedByPerson, feed.cards.isEmpty { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: feed.event) { _, event in arrived(event, proxy) }
            // One line, cut at its end, in the room the bar gives it: the system's own title of a long chat ran on as a
            // marquee under Back ("…k cleanup"). VoiceOver reads it whole.
            .navigationTitle {
                Text(feed.title).lineLimit(1).truncationMode(.tail)
                    .accessibilityLabel(feed.title).accessibilityIdentifier("watch.chat.title")
            }
            .toolbar {
                // The bottom bar is where watchOS pins a field to the screen's bottom edge; a safe-area inset sat above
                // a blank band on the Ultra. It gives way to a card (`barShown`).
                if barShown(feed) {
                ToolbarItem(placement: .bottomBar) {
                    composer(feed) {
                        let t = text; text = ""
                        do {
                            try await feed.send(t)
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        } catch { text = t }
                    }
                }
                }
                if feed.isWorking {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { talk.stopWaiting(); Task { await feed.stop() } } label: { Image(systemName: "stop.fill") }.tint(.red)
                    }
                }
            }
        }
    }

    /// The feed's arrivals, each once while the chat is open: the only haptics here, and a scroll to what arrived. A
    /// first read, a wrist raise's read of what was already seen and a switch between the socket and the iPhone have
    /// none (the feed's gate), where the old view buzzed and jumped on every read.
    private func arrived(_ event: WatchFeedEvent?, _ proxy: ScrollViewProxy) {
        guard let event else { return }
        switch event.kind {
        case .replyArrived(let id):
            WKInterfaceDevice.current().play(.success)
            withAnimation { proxy.scrollTo(id, anchor: .top) }
        case .cardArrived(let id):
            WKInterfaceDevice.current().play(.notification)
            // From its top: the ask and Allow once first. A card is taller than the Watch's screen, and landed by its
            // bottom it showed only the last two choices, the ask and Allow once out of sight above. Again once the bar
            // has given way to it (`barShown`), unless the person has moved the thread since.
            withAnimation { proxy.scrollTo(id, anchor: .top) }
            movedByPerson = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                if !movedByPerson { withAnimation { proxy.scrollTo(id, anchor: .top) } }
            }
        case .turnFailed:
            WKInterfaceDevice.current().play(.failure)
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// "Working…", the gateway's own words when it has some, and how many steps this turn has taken.
    private static func workingLine(_ feed: WatchChatFeed) -> String {
        let steps = feed.turnTools.count
        let line = feed.statusLine?.isEmpty == false ? feed.statusLine! : "Working…"
        return steps == 0 ? line : "\(line) · \(steps) \(steps == 1 ? "step" : "steps")"
    }

    /// Talk's and Send's hit area: a finger's worth, where the glyph alone was 19 pt.
    private static let buttonSide: CGFloat = 30

    /// While a card waits the bottom bar gives way to it, as the iPhone's dock turns into the card: laid over the
    /// content, the field and Talk covered the card's Allow once at the largest text (41 mm, ax). The bar comes back
    /// with the answer, the draft kept; it stays while Talk is at work, so a recording can still be stopped
    /// (2026-10-20).
    private static let barGivesWayToCards = true

    private func barShown(_ feed: WatchChatFeed) -> Bool {
        !(Self.barGivesWayToCards && !feed.cards.isEmpty && !talk.isBusy)
    }

    /// The message field, Talk and the send button, one row on the bottom edge. While Talk works the row says what it is
    /// doing instead of the field.
    private func composer(_ feed: WatchChatFeed, send: @escaping () async -> Void) -> some View {
        composerRow(feed, send: send)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { barTop = $0 }
    }

    private func composerRow(_ feed: WatchChatFeed, send: @escaping () async -> Void) -> some View {
        HStack(spacing: 6) {
            if talk.isBusy {
                Text(talk.phaseText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                TextField("Message", text: $text)
                    .accessibilityIdentifier("watch.chat.message")
            }
            // Talk on the live chat, or through the iPhone when this chat is on the phone path.
            if let target = feed.talkTarget {
                // While the reply is awaited the same button gives the wait up (the reply still lands in the chat).
                Button { talk.tap(target: target) } label: {
                    Image(systemName: talk.phase == .recording ? "stop.circle.fill" : talk.phase == .speaking ? "speaker.slash.circle.fill" : talk.phase == .waiting ? "xmark.circle.fill" : "mic.circle.fill")
                        .font(.title3)
                        .symbolEffect(.pulse, isActive: talk.phase == .recording || talk.phase == .waiting)
                        // A finger's worth to hit, not the 19 pt glyph alone.
                        .frame(width: Self.buttonSide, height: Self.buttonSide)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(talk.phase == .recording ? Color.red : talk.isBusy ? Color.accentColor : Color.secondary)
                .disabled(talk.phase == .transcribing)
                .accessibilityLabel(talk.phase == .recording ? "Stop and send" : talk.phase == .speaking ? "Stop speaking" : talk.phase == .waiting ? "Stop waiting for the reply" : "Talk")
            }
            if !talk.isBusy {
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title3)
                        .frame(width: Self.buttonSide, height: Self.buttonSide)
                        .contentShape(.circle)
                }
                    .buttonStyle(.plain).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .foregroundStyle(text.isEmpty ? Color.secondary : Color.accentColor)
                    // VoiceOver read the glyph's name ("Arrow Up Circle").
                    .accessibilityLabel("Send")
            }
        }
        .onChange(of: talk.error) { _, e in
            guard let e else { return }
            talkNote = e
            talk.error = nil
        }
    }
}

/// Approval / clarify / secret cards, sized for a wrist, answered through the chat's feed on either path (#387).
/// An approval's two common answers are big (Allow once in green, Deny in red) and the other two the gateway offers sit
/// smaller under them, with the names the iPhone uses; "Always allow…" asks first, as there.
struct WatchCardView: View {
    var feed: WatchChatFeed
    var card: PendingCard
    @State private var answer = ""
    @State private var sending = false
    @State private var failed: String?
    @State private var confirmAlways = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let a = card.approval {
                Label("Approval", systemImage: "checkmark.shield").font(.caption.weight(.semibold))
                Text(a.description?.isEmpty == false ? a.description! : (a.command ?? "")).font(.footnote).lineLimit(6)
                let offered = a.offeredChoices
                if offered.contains("once") {
                    Button { choose("once") } label: { Text("Allow once").frame(maxWidth: .infinity) }.tint(.green)
                }
                if offered.contains("deny") {
                    Button(role: .destructive) { choose("deny") } label: { Text("Deny").frame(maxWidth: .infinity) }.tint(.red)
                }
                if offered.contains("session") {
                    Button("Allow for this chat") { choose("session") }.font(.caption)
                }
                if offered.contains("always") {
                    Button("Always allow…") { confirmAlways = true }.font(.caption)
                        .alert("Always allow \(a.alwaysScope)?", isPresented: $confirmAlways) {
                            Button("Always allow") { choose("always") }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Every chat with this bot runs it without asking, until the rule is removed on the iPhone.")
                        }
                }
            } else if let c = card.clarify {
                Label("Question", systemImage: "questionmark.bubble").font(.caption.weight(.semibold))
                Text(c.question ?? c.questions?.first?.question ?? "").font(.footnote)
                // Offered answers are buttons: one tap, no typing on the wrist.
                ForEach((c.choices ?? c.questions?.first?.choices ?? []).prefix(6), id: \.self) { choice in
                    Button(choice) { choose(choice) }.font(.footnote)
                }
                TextField("Answer", text: $answer)
                Button("Send") { reply(answer) }.disabled(answer.isEmpty)
            } else {
                Label("Input needed", systemImage: "key").font(.caption.weight(.semibold))
                Text(card.valuePrompt?.prompt ?? card.method).font(.footnote)
                SecureField("Value", text: $answer)
                Button("Send") { reply(answer) }.disabled(answer.isEmpty)
            }
            if let failed { Text(failed).font(.caption2).foregroundStyle(.red) }
        }
        .disabled(sending)
        .padding(10)
        .background(.orange.opacity(0.15), in: .rect(cornerRadius: 14))
    }

    /// An approval by the gateway's choice key, or a question by one of its offered answers.
    private func choose(_ choice: String) {
        act { try await feed.answer(card, choice: choice) }
    }

    private func reply(_ text: String) {
        act { try await feed.answer(card, text: text) }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        sending = true; failed = nil
        Task {
            do { try await work() } catch { failed = error.localizedDescription }
            sending = false
        }
    }
}
