import Combine
import QuickLook
import SwiftUI
import VoryCore

struct TranscriptView: View {
    @Bindable var chat: ChatSession
    /// Long-press › "Edit & resend" hands the text back to the composer.
    var onEditMessage: (String) -> Void = { _ in }
    /// A "Messaged X" or "Message from X" notice was tapped: open X's chat.
    var onOpenBot: (String) -> Void = { _ in }
    /// Reply on a bubble: the composer quotes it above the next message.
    var onReply: (String) -> Void = { _ in }
    @State private var showModelSheet = false
    @State private var showAwayGrace = false
    /// The dock's top edge in screen coordinates (0 = unknown). The thread's bottom margin is the
    /// distance from its own bottom edge to this: measured, not derived from a dock height added
    /// onto some inset, which left a blank band under the last reply on some phones.
    var dockTop: CGFloat = 0
    /// What to use until the dock has been measured.
    var fallbackInset: CGFloat = 60
    @State private var scrollBottom: CGFloat = 0
    /// What the scroll view insets its content by on its own (safe area, ancestors' margins),
    /// found by subtracting the margin this view set from the inset it reports. Without this,
    /// on phones where the scroll view already inset the safe area, the last reply sat a home
    /// indicator's height above the composer.
    /// Measured once, from the first report, and quantised to 0 or the home indicator's height.
    /// Not re-derived on every report: while the dock resizes (the slash list opening, say) a
    /// report lags the margin by a frame, and a value fed straight back into the margin chased
    /// itself frame after frame.
    private var autoInset: CGFloat { autoInsetFixed ?? 0 }
    @State private var autoInsetFixed: CGFloat?
    /// How far the dock reaches up into the scroll view's frame: what the overlays clear.
    private var dockReach: CGFloat { dockTop > 0 && scrollBottom > dockTop ? scrollBottom - dockTop : fallbackInset }
    /// Where the content's last line can actually sit: the frame's bottom, unless the frame runs
    /// under the home indicator, in which case the automatic inset ends it above that. Two
    /// layouts seen in the wild: a frame that stops at the safe area (the inset is virtual) and
    /// one that runs to the screen edge (the inset is real). This reads the same in both.
    private var visibleBottom: CGFloat { min(scrollBottom, UIScreen.main.bounds.height - autoInset) }
    /// The margin to add so the last line ends 8 pt above the dock. Never less than the keyboard
    /// plus a one-line composer: a tester's first message in a new chat sat under both, which
    /// no dock position this view had measured could explain, so the floor holds on its own.
    private var bottomInset: CGFloat {
        let measured = dockTop > 0 && visibleBottom > dockTop ? visibleBottom - dockTop : fallbackInset
        return max(measured, keyboardFloor > 0 ? keyboardFloor + 44 : 0)
    }
    /// The keyboard's height once it has settled. The floor is not applied while the keyboard
    /// rises: a content margin does not animate, so the thread jumped up a beat before the
    /// dock's spring brought the composer there.
    @State private var keyboardFloor: CGFloat = 0
    @State private var floorTask: Task<Void, Never>?
    /// Height of the floating header (the nav bar is hidden in a chat).
    var topInset: CGFloat = 96
    /// Locked to the bottom: the thread follows every new token, tool call and card. Only the
    /// user's own drag releases it; the jump button (or scrolling back down) locks it again.
    @State private var awayFromBottom = false
    /// The card being opened and where its top was when the tap landed.
    @State private var revealAnchor: (id: String, top: CGFloat)?
    /// Scrolling is by content edge, not by the "bottom" marker view: with the lazy stack a
    /// marker that is not yet laid out gets an estimated position, and the jump-to-bottom button
    /// overshot and bounced back up.
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var insetSettle: Task<Void, Never>?
    /// The scroll figures that change every frame (offset, distance to the end, sizes). A plain
    /// object, not view state: writing view state per frame re-evaluated this whole body, and
    /// every row with it, on every frame of a flick.
    @State private var metrics = ScrollMetrics()
    /// While the chat is still settling after it opened (history arriving, header and dock
    /// measuring), every adjustment lands without animation; animated ones fought each other.
    @State private var openedAt = Date()
    private var settling: Bool { Date().timeIntervalSince(openedAt) < 1.5 }
    @State private var jumpTask: Task<Void, Never>?
    /// Where the part of the thread that is not lazy starts (see `threadRows`), once the thread
    /// has set it: it moves only while the thread rests at its end. `TranscriptRowModel.split`
    /// says when it is not used.
    @State private var tailFrom: Int?
    @State private var revealTask: Task<Void, Never>?
    @State private var overscrollTask: Task<Void, Never>?
    /// How much of the scroll view the keyboard covers (beyond the home-indicator safe area). The
    /// thread moves up with the keyboard and, when it was at the bottom, stays there.
    @State private var keyboardInset: CGFloat = 0
    /// Reasoning disclosures that are open, keyed by item id — kept here so a re-rendered row
    /// does not forget it (the earlier "can't collapse again" bug).
    @State private var openReasoning: Set<String> = []
    /// The rows' actions, one object for the view's life (see `RowContext`).
    @State private var actions = RowActions()
    @State private var selectText: String?
    @AppStorage(ChatStyle.showToolCalls) private var showToolCalls = true
    @AppStorage(ChatStyle.showReasoning) private var showReasoning = true
    @AppStorage(ChatStyle.showTurnStats) private var showTurnStats = true
    @AppStorage(ChatStyle.showSystemNotes) private var showSystemNotes = true
    @AppStorage(ChatStyle.showBots) private var showBots = false
    @AppStorage(ChatStyle.collapseAfterTurn) private var collapseAfterTurn = false
    @AppStorage(ChatStyle.showToolOutput) private var showToolOutput = true
    @AppStorage(ChatStyle.compactTools) private var compactTools = false
    @AppStorage(ChatStyle.currentStepOnly) private var currentStepOnly = false
    @AppStorage(ChatStyle.wideReplies) private var wideReplies = false
    @AppStorage(ChatStyle.textSize) private var textSize = "default"
    @Environment(\.dynamicTypeSize) private var phoneTypeSize
    /// Tool cards that are open, keyed by item id: lifted out of the card so a recycled row
    /// keeps it and the turn's end can fold them all.
    @State private var openTools: Set<String> = []
    /// The Mac's reading column as laid out, for the bubbles' share of it.
    @State private var columnWidth: CGFloat = 760
    /// How wide a bubble may grow: no limit on the phone (the screen is the limit), about
    /// two thirds of the column on the Mac, like Messages.
    private var bubbleCap: CGFloat {
        #if os(macOS)
        return wideReplies ? columnWidth : max(320, columnWidth * 0.72)
        #else
        return .infinity
        #endif
    }

    private var visibleItems: [TranscriptItem] {
        chat.items.filter { item in
            switch item.kind {
            case .tool(let act): return showToolCalls && (!currentStepOnly || act.status == .running)
            case .subagent: return showToolCalls
            case .system: return showSystemNotes
            default: return true
            }
        }
    }
    static func isStreaming(_ item: TranscriptItem) -> Bool {
        if case .assistant(_, _, let streaming) = item.kind { return streaming }
        return false
    }

    private var rows: [TranscriptRowModel] { TranscriptRowModel.build(visibleItems) }
    /// True while the last item is a reply still waiting for its first words (that row shows
    /// the typing bubble itself).
    private var lastIsEmptyStreamingReply: Bool {
        if case .assistant(let t, _, let streaming) = chat.items.last?.kind { return streaming && t.isEmpty }
        return false
    }
    /// The tool the bot is running, for the dark typing bubble ("Running terminal…" → "terminal").
    private var typingTool: String? {
        guard chat.botState == .usingTool, let s = chat.statusLine else { return nil }
        return s.replacingOccurrences(of: "Running ", with: "").replacingOccurrences(of: "Preparing ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "… "))
    }

    var body: some View {
        let _ = Perf.tick("transcript")
        return Group {
            ScrollView {
                TimeRevealColumn {
                ThreadStack(alignment: .leading, spacing: 10) {
                    if chat.items.isEmpty, chat.resumeError == nil {
                        VStack(spacing: 8) {
                            BotAvatar(profile: chat.profileName, size: 56)
                            Text("Say something to \(chat.runtime.profiles.first { $0.name == chat.profileName }?.label ?? chat.profileName)").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    threadRows
                    // Working with no bubble to fill (between parts, during a tool): the typing
                    // bubble stands on its own, dark with the badge while a tool runs.
                    if chat.isRunning, !lastIsEmptyStreamingReply {
                        HStack(alignment: .bottom, spacing: 10) {
                            // The working bot is pinned at the bottom-left of the thread (below);
                            // this only keeps the bubble in the bot column.
                            if showBots { Color.clear.frame(width: 28, height: 1) }
                            TypingBubble(tool: typingTool)
                            Spacer(minLength: 40)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("thread.typing")
                        .id("typing")
                        // No transition: it hands over to the empty reply that takes its place
                        // (that row draws the same bubble on the same spot), and a fade or a
                        // slide there drew one bubble over the other.
                    }
                    if let s = chat.statusLine, chat.isRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            #if os(macOS)
                            // The Mac has no header pill over the thread: what the bot is working
                            // on, when the on-device model has written it, sits here with the step.
                            if let goal = ChatGoals.shared.goal(for: chat.storedID) {
                                Label(goal, systemImage: "sparkles").font(.caption).foregroundStyle(.tint).lineLimit(1)
                                Text("·").font(.caption).foregroundStyle(.tertiary)
                            }
                            #endif
                            Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                        // Clear of the bot column when the pinned working bot sits there.
                        .padding(.leading, showBots ? 38 : 4).padding(.trailing, 4)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("thread.status")
                    }
                    Color.clear.frame(height: 0).id("bottom")
                }
                .padding(.horizontal, wideReplies ? 10 : 16)
                .padding(.top, 8)
                #if os(macOS)
                // A reading column in the middle of the pane, a page wide however wide the window is.
                .frame(maxWidth: ChatStyle.macColumn)
                .onGeometryChange(for: CGFloat.self) { ($0.size.width / 20).rounded() * 20 } action: { columnWidth = $0 }
                .frame(maxWidth: .infinity)
                #endif
                .dynamicTypeSize(ChatStyle.stepped(phoneTypeSize, textSize))
                // No animation for the stack as a whole. One used to run whenever the row count
                // changed, and it animated everything else that changed in the same update: when
                // a tool card arrived, the reply above it got its last words in that update too,
                // and while the bubble, its footer and every row under it slid from their old
                // places, the new lines of text were drawn at once at their final ones, over
                // the footer, the typing bubble and the card (testers' screenshots of a reply
                // over their own bubble and of cards stacked over the reply's text). Rows now
                // land where they belong in every frame and a new row fades in on its own
                // (`rowView`); what moves the thread is scrolling (`followRows`), which moves
                // every row together.
                .background(ScrollViewProbe(metrics: metrics))
                }
            }
            .scrollPosition($scrollPosition)
            // `bottomInset` is the dock's measured reach into the thread, keyboard included; the
            // scroll view adds its own safe-area inset under that.
            .contentMargins(.bottom, bottomInset + 8, for: .scrollContent)
            .contentMargins(.top, topInset + 8, for: .scrollContent)
            // The keyboard is handled by hand (below) so the last message rides up with it instead
            // of vanishing under the composer; SwiftUI's own avoidance would then double the inset.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { scrollBottom = $0 }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.bottom } action: { _, v in
                metrics.reportedInsetBottom = v
                guard autoInsetFixed == nil, dockTop > 0 else { return }
                #if os(iOS)
                let raw = max(0, v - (bottomInset + 8))
                let safe = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }.first ?? 0
                autoInsetFixed = safe > 0 && raw > safe / 2 ? safe : 0
                #else
                autoInsetFixed = 0   // no home indicator under a window
                #endif
            }
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentSize.height, $0.containerSize.height] } action: { _, v in
                metrics.contentHeight = v[0]; metrics.containerHeight = v[1]
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
                guard let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
                let screen = UIScreen.main.bounds
                // The same rule as the dock's: a frame that is not a keyboard's (a floating or
                // hardware keyboard's bar, another scene's, the whole screen) must not count.
                let onScreen = end.intersection(screen)
                guard end.height < screen.height * 0.66, onScreen.isNull || onScreen.maxY >= screen.maxY - 1 || end.minY >= screen.maxY else { return }
                let covered = max(0, screen.maxY - end.minY)
                let safeBottom = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }.first ?? 0
                let inset = max(0, covered - safeBottom)
                // The keyboard moves on UIKit's own spring; this spring tracks it closely, so the
                // thread and the composer arrive together instead of the composer overlapping.
                withAnimation(.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)) {
                    keyboardInset = inset
                    if metrics.stickToBottom { scrollPosition.scrollTo(edge: .bottom) }
                }
                floorTask?.cancel()
                if inset == 0 { keyboardFloor = 0 } else {
                    floorTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled else { return }
                        keyboardFloor = inset
                        if metrics.stickToBottom, !metrics.userScrolling { scrollPosition.scrollTo(edge: .bottom) }
                    }
                }
            }
            #endif
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in
                metrics.offsetY = new
                if metrics.userScrolling { BotAmbient.shared.scrolled(dy: new - old) }
            }
            // A tool card or reasoning block that opened low on the screen grew under the
            // composer; once its height has settled, the thread scrolls just enough to show
            // its bottom edge. Collapsing posts nothing, so the thread stays put then.
            .onReceive(NotificationCenter.default.publisher(for: .hermesRevealRow)) { revealRow($0) }
            // Your own message brings the thread to the end, as in Messages, however far up it
            // was scrolled: a tester sent one from up the thread, saw nothing happen, and had to
            // find the arrow to see the reply.
            .onReceive(NotificationCenter.default.publisher(for: .hermesMessageSent)) { n in
                guard (n.object as? ChatSession) === chat, !metrics.stickToBottom || metrics.distanceFromBottom > 24 else { return }
                jumpToBottom()
            }
            // Insets included: the bottom margin (dock plus home indicator) is about the size of
            // the threshold, so without it a slightly taller dock showed the arrow at the very end.
            .onScrollGeometryChange(for: CGFloat.self) { g in
                g.contentSize.height + g.contentInsets.bottom - g.visibleRect.maxY
            } action: { was, distance in
                metrics.distanceFromBottom = distance
                // Past the end with no finger on it: a scroll-to-bottom that used the lazy stack's
                // estimated height lands beyond the real content and the thread shows nothing
                // until a drag bounces it back ("chats open blank until you scroll"). Land it.
                if distance < -60, !metrics.userScrolling { scheduleOverscrollFix() }
                let away = distance > 120
                if away != awayFromBottom { withAnimation(.snappy) { awayFromBottom = away } }
                // Content growing under a locked thread also reads as "away" for a frame; only a
                // finger on the thread unlocks it: any upward pull from where the touch began
                // (a tester scrolling up during a reply was pulled back to the end until the
                // drag had covered 24 pt, and again whenever a token landed between touches).
                // Scrolling back to the end, finger off, locks it again.
                if metrics.userScrolling, distance > 24 || distance > metrics.touchStartDistance + 6 { metrics.stickToBottom = false }
                // Only a distance that closed smoothly, not one that fell to nothing in a step:
                // the content shrinking for a frame (a re-read of the chat replacing its rows,
                // a lazy row re-measured) clamps the offset to the new end, read as "at the
                // end", locked the thread, and the next token pulled a reader who was up the
                // thread to the bottom (#277, "you have to fight against Vory to scroll").
                if distance < 4, !metrics.userScrolling, was < 60 { metrics.stickToBottom = true }
            }
            .onScrollPhaseChange { _, phase in
                // A finger on the thread counts from the touch, before it has moved.
                let touching = phase == .tracking || phase == .interacting || phase == .decelerating
                if touching, !metrics.userScrolling { metrics.touchStartDistance = metrics.distanceFromBottom }
                metrics.userScrolling = touching
                if !touching, metrics.distanceFromBottom < 4 { metrics.stickToBottom = true }
            }
            // The working bot: one spot at the bottom-left of the thread for the whole turn, in
            // the same pose as the bot on the header pill, gone once the turn ends. It used to sit
            // beside whichever row was live and hopped between them as the turn went on.
            .overlay(alignment: .bottomLeading) {
                ZStack {
                    if showBots, chat.isRunning {
                        BotAvatar(profile: chat.profileName, size: 28, active: true, mood: BotFaceView.Mood(state: chat.botState))
                            .padding(.leading, 16).padding(.bottom, dockReach + 12)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                // Only the pinned bot animates with the turn. On the whole thread this animated
                // the turn's last words too (they land in the same update as the end of the
                // turn), and the reply's text was drawn over the rows sliding under it.
                .animation(.snappy, value: chat.isRunning)
            }
            .overlay(alignment: .topLeading) {
                // The readout names UIScrollView's insets, which the Mac's scroll view does not have.
                #if DEBUG && os(iOS)
                if ProcessInfo.processInfo.arguments.contains("-vory-geometry") {
                    Text("dockTop \(Int(dockTop)) scrollBottom \(Int(scrollBottom)) inset \(Int(bottomInset)) dist \(Int(metrics.distanceFromBottom)) top \(Int(topInset)) sv \(Int(metrics.scrollView?.convert(metrics.scrollView?.bounds ?? .zero, to: nil).minY ?? -1))/\(Int(metrics.scrollView?.bounds.height ?? -1)) adj \(Int(metrics.scrollView?.adjustedContentInset.top ?? -1))/\(Int(metrics.scrollView?.adjustedContentInset.bottom ?? -1)) rep \(Int(metrics.reportedInsetBottom))")
                        .font(.caption2.monospacedDigit()).padding(4).background(.yellow).foregroundStyle(.black).padding(.top, 120)
                }
                #endif
            }
            .overlay(alignment: .bottomTrailing) {
                JumpToBottomButton(visible: awayFromBottom) { jumpToBottom() }
                .padding(.trailing, 16).padding(.bottom, dockReach + 12)
            }
            .sheet(item: Binding(get: { selectText.map { SelectTextItem(text: $0) } }, set: { selectText = $0?.text })) { SelectTextSheet(text: $0.text).sheetFrame(.wide).withAppModel() }
            .sheet(isPresented: $showModelSheet) { ModelSheet(chat: chat).sheetFrame().withAppModel() }
            .sheet(isPresented: $showAwayGrace) { AwayGraceSheet(runtime: chat.runtime).sheetFrame(.compact).withAppModel() }
            #if os(iOS)
            // Under the status bar, behind the floating header. The Mac's toolbar is not a place to run under.
            .ignoresSafeArea(.container, edges: .top)
            #endif
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            // Whole item, not just `.kind`: the tokens/sec footer lands after the text does and
            // must pull the bottom back into view too.
            // Streaming text follows unanimated (tokens arrive faster than an animated scroll
            // settles); a new message fades in where it belongs and the thread eases up to it.
            .onChange(of: chat.items.last) { _, _ in
                if mayFollow() { scrollPosition.scrollTo(edge: .bottom) }
            }
            .onChange(of: visibleItems.count) { old, new in followRows(from: old, to: new) }
            // Again when the turn ends: rows cross into the lazy stack between turns only.
            .task(id: [visibleItems.count, chat.isRunning ? 1 : 0]) { await settleTail() }
            .onAppear { openedAt = Date(); refreshMentionNames() }
            // The names "@" can mean: the gateway's bots (name and label) and the person's own.
            .onChange(of: chat.runtime.profiles.map(\.name)) { _, _ in refreshMentionNames() }
            // Once the history is in and laid out, make sure the end is really on screen.
            .task(id: chat.isResuming) { await landAfterResume() }
            .onChange(of: chat.statusLine) { _, _ in
                if mayFollow() { withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) } }
            }
            // The turn ending takes the typing bubble and status line out from under the last
            // reply; a locked thread follows so no blank band is left there.
            .onChange(of: chat.isRunning) { _, running in
                if !running, collapseAfterTurn { withAnimation(.snappy) { openReasoning = []; openTools = [] } }
                if mayFollow() { withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) } }
            }
            // The dock changing height (an approval card arriving or leaving) moves the bottom
            // margin; a locked thread follows, so no blank band opens under the last row. Once
            // the height has settled, not per frame of the card's grow animation: a scroll per
            // frame against a moving margin overshot into blank space.
            .onChange(of: bottomInset) { _, _ in
                guard metrics.stickToBottom, !metrics.userScrolling else { return }
                insetSettle?.cancel()
                insetSettle = Task {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled, metrics.stickToBottom, !metrics.userScrolling else { return }
                    if settling { scrollPosition.scrollTo(edge: .bottom) }
                    else { withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) } }
                }
            }
        }
    }
}

extension TranscriptView {
    /// The thread's rows. Lazy: a long session (hundreds of replies and tool rows) used to build
    /// every row at once, and the layer tree that made could exhaust memory in the render
    /// commit (abort in CA::Render::Encoder::grow, three crash reports on 1.1 (6)).
    @ViewBuilder private var threadRows: some View {
        // Only the older rows are lazy. A lazy stack gives a row it has not drawn the average
        // height of the ones it has, and a row added under a pinned thread starts out undrawn:
        // after one long reply the thread claimed hundreds of points it did not have, the
        // scroll to the end went there, and the thread showed its top or nothing for a moment
        // (any new message, most plainly one sent from another device). On the Mac, where
        // the whole thread was one lazy stack, a long history never settled at all: each scroll
        // to the end re-laid out the stack, which moved the end, which scrolled again, and
        // the app sat at full CPU until it was force-quit (a tester's "beachball on send").
        // Rows the lazy stack takes over start out undrawn too, so their height changes as
        // they cross: that happens between turns (`settleTail`), not while one streams.
        let all = rows
        let split = TranscriptRowModel.split(count: all.count, tailFrom: tailFrom)
        let ctx = rowContext
        if split > 0 {
            // The older rows in a view of their own, equal when nothing they draw with has
            // changed: a token landing in the reply at the end used to re-evaluate every row
            // the lazy stack had drawn, which with a long history was most of a core for the
            // whole reply (the Mac's "beachball on send"). Now a token touches the tail only.
            OlderRows(rows: Array(all[..<split]), context: ctx).equatable()
        }
        let entering = Self.enteringRowID(all, opening: settling || chat.isResuming)
        ForEach(Array(all[split...])) { row in ctx.rowView(row, entering: row.id == entering) }
    }

    /// The row that fades in if it is new: the last one, once the chat has opened and synced
    /// (`opening` false). Not an empty reply: it takes the place of the standalone typing bubble
    /// and draws the same bubble on the same spot, so a fade there was a blink. Rows that move
    /// between the lazy part and the tail, and a history arriving, appear as they are.
    static func enteringRowID(_ rows: [TranscriptRowModel], opening: Bool) -> String? {
        guard let last = rows.last, !opening, !isEmptyStreaming(last.item) else { return nil }
        return last.id
    }
    static func isEmptyStreaming(_ item: TranscriptItem) -> Bool {
        if case .assistant(let t, _, true) = item.kind { return t.isEmpty }
        return false
    }

    /// Everything the rows are drawn with, apart from the rows themselves. The actions live in
    /// one object kept for the view's life, so their closures do not make the context unequal.
    private var rowContext: RowContext {
        actions.onEdit = onEditMessage
        actions.onOpenBot = onOpenBot
        actions.onReply = onReply
        actions.onChooseModel = { showModelSheet = true }
        actions.onKeepRunning = { showAwayGrace = true }
        actions.onSelectText = { selectText = $0 }
        actions.setReasoningOpen = { id, on in if on { openReasoning.insert(id) } else { openReasoning.remove(id) } }
        actions.setToolOpen = { id, on in if on { openTools.insert(id) } else { openTools.remove(id) } }
        return RowContext(profile: showBots ? chat.profileName : nil, bot: chat.profileName, typingTool: typingTool, showReasoning: showReasoning, currentStepOnly: currentStepOnly,
                          showStats: showTurnStats, interruptCause: chat.interruptCause, lastID: chat.items.last?.id,
                          openReasoning: openReasoning, openTools: openTools, showToolOutput: showToolOutput, compactTools: compactTools,
                          wide: wideReplies, maxBubble: bubbleCap, actions: actions)
    }

    /// A tool card or reasoning block opened: keeps its top where the finger found it while it
    /// grows, then shows its bottom edge if that ran under the composer.
    private func revealRow(_ n: Notification) {
        guard let bottom = n.userInfo?["bottom"] as? CGFloat, let id = n.userInfo?["id"] as? String else { return }
        let top = n.userInfo?["top"] as? CGFloat ?? bottom
        // While the card grows, its top stays where the finger found it: the thread is
        // anchored at its bottom, so the growth used to push the card up by its own
        // height and the reveal then pulled it back down, a visible jitter on every
        // expand. Each frame of the growth is countered on the scroll view directly.
        if revealAnchor?.id != id { revealAnchor = (id, top); metrics.stickToBottom = false }
        #if os(iOS)
        if let a = revealAnchor, a.id == id, let sv = metrics.scrollView, abs(top - a.top) > 0.5 {
            let y = max(-sv.adjustedContentInset.top, sv.contentOffset.y + (top - a.top))
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: y), animated: false)
        }
        #endif
        let settledBottom = bottom - (top - (revealAnchor?.top ?? top))
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            revealAnchor = nil
            // Only when the opened row runs under the composer; then its bottom edge is
            // aligned to the visible bottom (the scroll view resolves the row itself,
            // so no offset arithmetic across coordinate spaces).
            let limit = (dockTop > 0 ? dockTop : UIScreen.main.bounds.height - fallbackInset) - 8
            let overshoot = settledBottom - limit
            guard overshoot > 0 else { return }
            #if os(iOS)
            if let sv = metrics.scrollView {
                let maxY = max(0, sv.contentSize.height + sv.adjustedContentInset.bottom - sv.bounds.height)
                sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: min(maxY, sv.contentOffset.y + overshoot)), animated: true)
                return
            }
            #endif
            withAnimation(.easeOut(duration: 0.25)) { scrollPosition.scrollTo(id: id, anchor: .bottom) }
        }
    }

    private func landAfterResume() async {
        guard !chat.isResuming else { return }
        for delay in [300, 900] {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, metrics.stickToBottom, !metrics.userScrolling else { return }
            if metrics.distanceFromBottom < -8 || metrics.distanceFromBottom > 8 { scrollPosition.scrollTo(edge: .bottom) }
        }
    }

    private func refreshMentionNames() {
        var bots: [String] = []
        for p in chat.runtime.profiles {
            bots.append(p.name)
            if p.label != p.name { bots.append(p.label) }
        }
        let person = UserDefaults.standard.string(forKey: "user.name")
        Mentions.names = Mentions.Names(bots: bots, person: person)
    }

    /// Whether a change at the end of the thread may scroll the thread to it: locked, no finger
    /// on it, and within reach. A token adds a line or two between frames; a thread that is a
    /// screen and a half or more from its end has a reader up it, and a lock that says
    /// otherwise is stale (set by a frame in which the content shrank, see the geometry
    /// handler). The lock goes then, not the reader's place (#277).
    private func mayFollow() -> Bool {
        guard metrics.stickToBottom, !metrics.userScrolling else { return false }
        let reach = max(900, metrics.containerHeight * 1.5)
        if metrics.distanceFromBottom > reach { metrics.stickToBottom = false; return false }
        return true
    }

    /// A row came or went under a locked thread: the thread eases to its end with it.
    private func followRows(from old: Int, to new: Int) {
        guard mayFollow() else { return }
        // Rows crossing into the lazy stack change the height above the screen: the thread
        // lands at its end at once then, with nothing to glide through.
        let crossed = TranscriptRowModel.split(count: old, tailFrom: tailFrom) != TranscriptRowModel.split(count: new, tailFrom: tailFrom)
        if settling || crossed { scrollPosition.scrollTo(edge: .bottom) }
        else { withAnimation(.easeOut(duration: 0.28)) { scrollPosition.scrollTo(edge: .bottom) } }
    }

    /// Hands the older rows of the thread's end to the lazy stack once the thread has been
    /// still for a moment, and only while it rests at its end: the rows that cross are above
    /// the screen then, and the thread is put back on its end in the same pass, so nothing
    /// shows. Not while the reader is up the thread, where the rows on screen would shift, and
    /// not while a turn runs: a tool call taking a moment looked like rest, and the rows that
    /// crossed then were laid out from the lazy stack's guesses for a frame, over their
    /// neighbours, and the thread lost its end mid-reply. During a turn only a boundary not yet
    /// set is set, where the rows already split.
    private func settleTail() async {
        try? await Task.sleep(for: .milliseconds(400))
        let count = visibleItems.count
        let wanted = TranscriptRowModel.tailStart(count)
        guard !Task.isCancelled, metrics.stickToBottom, !metrics.userScrolling, tailFrom != wanted else { return }
        let moves = TranscriptRowModel.split(count: count, tailFrom: tailFrom) != wanted
        if moves, chat.isRunning { return }
        tailFrom = wanted
        if moves { scrollPosition.scrollTo(edge: .bottom) }
    }

    private func scheduleOverscrollFix() {
        guard overscrollTask == nil else { return }
        overscrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            defer { overscrollTask = nil }
            guard !Task.isCancelled, !metrics.userScrolling, metrics.distanceFromBottom < -8 else { return }
            Perf.tick("overscrollFix")
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    /// The jump arrow: a long animated scroll through a lazy thread laid rows out mid-flight and
    /// the bubbles glitched. From far away the thread first lands, unanimated, a screen short of
    /// the end, then the last stretch scrolls fast and smooth.
    private func jumpToBottom() {
        metrics.stickToBottom = true
        jumpTask?.cancel()
        let far = metrics.distanceFromBottom > 900
        jumpTask = Task { @MainActor in
            if far {
                // From far away (a chat that grew while the app was away) the lazy stack's
                // height is an estimate, so no animated glide: land flat at the end, then keep
                // landing as rows lay out and the end moves, until the thread stops short of
                // nothing. A tester's arrow did nothing after a few hours away.
                scrollPosition.scrollTo(edge: .bottom)
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(70))
                    guard !Task.isCancelled else { return }
                    if metrics.userScrolling { return }
                    if metrics.distanceFromBottom <= 24 { break }
                    scrollPosition.scrollTo(edge: .bottom)
                }
                if metrics.distanceFromBottom > 24 { scrollPosition.scrollTo(id: "bottom", anchor: .bottom) }
                return
            }
            withAnimation(.easeOut(duration: 0.35)) { scrollPosition.scrollTo(edge: .bottom) }
            // If it did not land (a lazy row laid out late, an older iOS), finish the job flat.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, metrics.distanceFromBottom > 24 else { return }
            scrollPosition.scrollTo(edge: .bottom)
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, metrics.distanceFromBottom > 24 else { return }
            scrollPosition.scrollTo(id: "bottom", anchor: .bottom)
        }
    }
}

/// What holds the thread: a plain stack with the lazy part inside it (see `threadRows`), on
/// both platforms.
private typealias ThreadStack<Content: View> = VStack<Content>

/// The thread's older rows, lazy, in a view that is equal as long as the rows and what they
/// are drawn with are: a reply streaming at the end then leaves them alone.
@MainActor
private struct OlderRows: View, Equatable {
    var rows: [TranscriptRowModel]
    var context: RowContext

    static func == (a: OlderRows, b: OlderRows) -> Bool { a.context == b.context && a.rows == b.rows }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in context.rowView(row) }
        }
    }
}

/// How a new row comes into a chat thread: a short fade where it belongs, and nothing else. It
/// carries its own animation, so nothing around it is animated with it. It never slides (a row
/// moving in from below was drawn over the rows under it) and never fades out (a row fading where
/// it was while its neighbours took its place was drawn over them).
@MainActor
enum ChatRowTransition {
    static let fadeIn = AnyTransition.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2)), removal: .identity)
}

/// What a row does when tapped: one object for the thread's life, so the context that carries
/// it compares equal from one update to the next (closures never do).
final class RowActions {
    var onEdit: (String) -> Void = { _ in }
    var onOpenBot: (String) -> Void = { _ in }
    var onReply: (String) -> Void = { _ in }
    var onChooseModel: () -> Void = {}
    var onKeepRunning: () -> Void = {}
    var onSelectText: (String) -> Void = { _ in }
    var setReasoningOpen: (String, Bool) -> Void = { _, _ in }
    var setToolOpen: (String, Bool) -> Void = { _, _ in }
}

/// Everything a row is drawn with apart from the row: the settings, what the chat is doing,
/// which cards are open, and the actions. Equatable, so a thread update that changed none of
/// it leaves the rows it already drew alone.
@MainActor
struct RowContext: Equatable {
    /// The bot beside its bubbles when bots are shown; nil hides it.
    var profile: String?
    /// The chat's bot whatever is shown: pictures live in its images dir on the gateway (with
    /// bots hidden, a stored attachment of a non-default bot's chat came back as a placeholder).
    var bot: String?
    var typingTool: String?
    var showReasoning: Bool
    var currentStepOnly: Bool
    var showStats: Bool
    var interruptCause: InterruptedTurn.Cause?
    var lastID: String?
    var openReasoning: Set<String>
    var openTools: Set<String>
    var showToolOutput: Bool
    var compactTools: Bool
    var wide: Bool
    var maxBubble: CGFloat
    var actions: RowActions

    static func == (a: RowContext, b: RowContext) -> Bool {
        a.actions === b.actions && a.profile == b.profile && a.bot == b.bot && a.typingTool == b.typingTool && a.showReasoning == b.showReasoning
            && a.currentStepOnly == b.currentStepOnly && a.showStats == b.showStats && a.interruptCause == b.interruptCause && a.lastID == b.lastID
            && a.openReasoning == b.openReasoning && a.openTools == b.openTools && a.showToolOutput == b.showToolOutput
            && a.compactTools == b.compactTools && a.wide == b.wide && a.maxBubble == b.maxBubble
    }

    /// One row of the thread: the time separator before it when there is one, and the message
    /// with the time waiting past its right edge. `entering`: the row fades in if it is new
    /// (see `TranscriptView.enteringRowID`); every other row appears and goes as it is.
    @ViewBuilder func rowView(_ row: TranscriptRowModel, entering: Bool = false) -> some View {
        if let sep = row.separator {
            Text(sep).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        let id = row.item.id
        let actions = actions
        TranscriptRow(item: row.item, profile: profile, bot: bot, botShown: row.lastOfRun,
                      typingTool: typingTool,
                      showReasoning: showReasoning && (!currentStepOnly || TranscriptView.isStreaming(row.item)), showStats: showStats,
                      onEdit: actions.onEdit, onOpenBot: actions.onOpenBot, onReply: actions.onReply, onChooseModel: actions.onChooseModel,
                      interruptCause: id == lastID ? interruptCause : nil, onKeepRunning: actions.onKeepRunning,
                      reasoningOpen: Binding(get: { [open = openReasoning.contains(id)] in open }, set: { actions.setReasoningOpen(id, $0) }),
                      onSelectText: actions.onSelectText,
                      toolOpen: Binding(get: { [open = openTools.contains(id)] in open }, set: { actions.setToolOpen(id, $0) }),
                      showToolOutput: showToolOutput, compactTools: compactTools, wide: wide, maxBubble: maxBubble)
            // Equatable on what it draws (the closures and the binding are
            // compared by value): a row whose message did not change is not
            // rebuilt when the thread re-evaluates for a scroll or a token.
            .equatable()
            .id(id)
            // One element per message, by kind: a group for VoiceOver, and what the UI tests
            // compare frame by frame to check that no row is ever drawn over another.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("thread.row." + row.kindTag)
            .transition(entering ? ChatRowTransition.fadeIn : .identity)
            #if os(macOS)
            // The Mac has no slide for times: hovering a message says when it arrived. The
            // words are made once per minute of the day, not once per row per token.
            .help(TimeLabels.hover(row.item.timestamp))
            #else
            // The time waits just past the right edge; the column slides left to show it.
            .overlay(alignment: .trailing) {
                Text(row.item.timestamp, style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    // Its leading edge sits 20 pt past the row (beyond the screen's
                    // 16 pt margin), so nothing of it shows until the column slides.
                    .fixedSize().alignmentGuide(.trailing) { d in d[.leading] - 20 }
                    .accessibilityHidden(true)
            }
            #endif
    }
}

/// Formatted times, kept: formatting goes through ICU and a thread re-evaluates rows often.
@MainActor
enum TimeLabels {
    private static var hover: [Int: String] = [:]

    /// "Oct 3, 2026 at 5:34 PM", once per minute of the day.
    static func hover(_ date: Date) -> String {
        let key = Int(date.timeIntervalSinceReferenceDate / 60)
        if let s = hover[key] { return s }
        if hover.count > 4096 { hover.removeAll(keepingCapacity: true) }
        let s = date.formatted(date: .abbreviated, time: .shortened)
        hover[key] = s
        return s
    }
}

#if os(macOS)
/// No UIKit scroll view to find here: scrolling by a measured distance falls back to the
/// SwiftUI scroll position, which is what the probe's absence means below.
private struct ScrollViewProbe: View {
    let metrics: ScrollMetrics
    var body: some View { Color.clear }
}
#else
/// Finds the UIKit scroll view behind the thread and hands it to the metrics box.
private struct ScrollViewProbe: UIViewRepresentable {
    let metrics: ScrollMetrics
    func makeUIView(context: Context) -> ProbeView { let v = ProbeView(); v.metrics = metrics; v.isUserInteractionEnabled = false; return v }
    func updateUIView(_ v: ProbeView, context: Context) { v.metrics = metrics }
    final class ProbeView: UIView {
        var metrics: ScrollMetrics?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var s = superview
            while let x = s, !(x is UIScrollView) { s = x.superview }
            metrics?.scrollView = s as? UIScrollView
        }
    }
}
#endif

/// The figures a scroll changes every frame. Not observable on purpose (see `TranscriptView.metrics`).
final class ScrollMetrics {
    #if os(iOS)
    /// The UIKit scroll view under the SwiftUI one, for a scroll by a measured distance: its
    /// offset and the rows' global frames are in the same points, so a delta is just a delta.
    weak var scrollView: UIScrollView?
    #endif
    /// Locked to the bottom: the thread follows every new token, tool call and card. Only the
    /// user's own drag releases it; the jump button (or scrolling back down) locks it again.
    var stickToBottom = true
    var userScrolling = false
    var distanceFromBottom: CGFloat = 0
    /// How far from the end the thread was when the current touch began.
    var touchStartDistance: CGFloat = 0
    var offsetY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var containerHeight: CGFloat = 0
    var reportedInsetBottom: CGFloat = 0
}

/// Drag the thread left to peek at each message's time, as in Messages: one transform on the
/// whole column (the bubbles slide left about 80 pt) with the times laid out just past the right
/// edge, so a drag re-renders nothing but this wrapper. The drag is a UIKit pan on the enclosing
/// scroll view, so it behaves the same in every thread: it begins only on a leftward, mostly
/// horizontal drag while the thread is at rest (not scrolling or decelerating), the column never
/// moves right, and once it runs the scroll view's own pan lets go of the touch. A drag that
/// starts on something scrolling sideways (a wide table) is left to it.
struct TimeRevealColumn<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var reveal: CGFloat = 0
    @AppStorage(ChatStyle.timeReveal) private var enabled = true
    var body: some View {
        content
            .offset(x: -reveal * 80)
            #if os(iOS)
            .background(TimeRevealPan(reveal: $reveal, enabled: enabled))
            #endif
    }
}

#if os(iOS)
private struct TimeRevealPan: UIViewRepresentable {
    @Binding var reveal: CGFloat
    var enabled = true

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.isUserInteractionEnabled = false
        v.coordinator = context.coordinator
        return v
    }
    func updateUIView(_ v: Probe, context: Context) { context.coordinator.reveal = $reveal; context.coordinator.enabled = enabled }
    func makeCoordinator() -> Coordinator { Coordinator(reveal: $reveal) }

    final class Probe: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { coordinator?.attach(from: self) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var reveal: Binding<CGFloat>
        var enabled = true
        private weak var scrollView: UIScrollView?
        private weak var pan: UIPanGestureRecognizer?
        private var offsetObservation: NSKeyValueObservation?
        private var lastScrollAt = Date.distantPast
        private var lastOffset: CGFloat = 0
        init(reveal: Binding<CGFloat>) { self.reveal = reveal }

        func attach(from v: UIView) {
            var s = v.superview
            while let x = s, !(x is UIScrollView) { s = x.superview }
            guard let sv = s as? UIScrollView, sv !== scrollView else { return }
            if let pan, let old = scrollView { old.removeGestureRecognizer(pan) }
            scrollView = sv
            let p = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            p.maximumNumberOfTouches = 1
            p.delegate = self
            p.name = "vory.timeReveal"
            sv.addGestureRecognizer(p)
            pan = p
            lastOffset = sv.contentOffset.y
            offsetObservation = sv.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                guard let self else { return }
                if abs(sv.contentOffset.y - self.lastOffset) > 0.5 { self.lastOffset = sv.contentOffset.y; self.lastScrollAt = Date() }
            }
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === pan, let sv = scrollView, let p = g as? UIPanGestureRecognizer else { return true }
            guard enabled else { return false }
            // Only while the thread is still: not decelerating, and not moved in the last moment.
            guard !sv.isDecelerating, Date().timeIntervalSince(lastScrollAt) > 0.3 else { return false }
            // A clearly sideways start: a diagonal scroll (a thumb drifting while it reads) used
            // to grab the thread and slide it, which read as the chat "moving side to side".
            let t = p.translation(in: sv), v = p.velocity(in: sv)
            return t.x < -10 && v.x < 0 && abs(t.x) > abs(t.y) * 3
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other === scrollView?.panGestureRecognizer
        }
        /// A touch that lands on something scrolling sideways (a table wider than its bubble)
        /// is that scroller's: the reveal never sees it, so the drag moves the table and not
        /// the thread.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard g === pan else { return true }
            return !Self.startsInSideScroller(touch.view, below: scrollView)
        }
        static func startsInSideScroller(_ view: UIView?, below thread: UIScrollView?) -> Bool {
            var v = view
            while let x = v, x !== thread {
                if let inner = x as? UIScrollView, inner.contentSize.width > inner.bounds.width + 1 { return true }
                v = x.superview
            }
            return false
        }

        @objc private func handle(_ p: UIPanGestureRecognizer) {
            guard let sv = scrollView else { return }
            switch p.state {
            case .began:
                // The scroll view's pan lets go of this touch, so the column moves alone.
                sv.panGestureRecognizer.isEnabled = false
                sv.panGestureRecognizer.isEnabled = true
                reveal.wrappedValue = min(1, max(0, -p.translation(in: sv).x / 100))
            case .changed:
                reveal.wrappedValue = min(1, max(0, -p.translation(in: sv).x / 100))
            default:
                withAnimation(.snappy) { reveal.wrappedValue = 0 }
            }
        }
    }
}
#endif

/// UserDefaults keys for the Appearance › Chat toggles.
extension ChatStyle { static let headerShowsTitle = "chatHeaderShowsTitle" }
enum ChatStyle {
    static let showToolCalls = "chat.showToolCalls"
    /// The on-screen keyboard's Return sends (as it did before 1.4) instead of adding a line; off
    /// by default. A hardware keyboard's Return sends and Shift-Return adds a line either way.
    static let returnSends = "chat.returnSends"
    static let showReasoning = "chat.showReasoning"
    static let showTurnStats = "chat.showTurnStats"
    static let showSystemNotes = "chat.showSystemNotes"
    /// The bot beside each reply bubble.
    static let showBots = "chat.showBots"
    /// Pull the thread left to see message times.
    static let timeReveal = "chat.timeReveal"
    /// Tool cards and reasoning fold up when the turn ends.
    static let collapseAfterTurn = "chat.collapseAfterTurn"
    /// The Output block inside an opened tool card.
    static let showToolOutput = "chat.showToolOutput"
    /// One-line tool cards.
    static let compactTools = "chat.compactTools"
    /// Only the step running now: finished tool cards and the reasoning of finished replies are hidden.
    static let currentStepOnly = "chat.currentStepOnly"
    /// Reply bubbles run to the edge instead of leaving a margin on the right.
    static let wideReplies = "chat.wideReplies"
    /// The Mac's reading column: thread and composer share it, centred in the pane.
    static let macColumn: CGFloat = 860
    /// "small", "default" or "large": one Dynamic Type step down or up for the thread only.
    static let textSize = "chat.textSize"
    /// "tailed" (Messages), "rounded" (no tails) or "plain" (replies without a bubble, like a page).
    static let bubbleStyle = "chat.bubbleStyle"
    /// Reply bubbles take a wash of the bot's own colour instead of grey.
    static let botTint = "chat.botTint"

    /// The thread's type size for a `textSize` choice, relative to the phone's own setting.
    static func stepped(_ base: DynamicTypeSize, _ choice: String) -> DynamicTypeSize {
        let all = DynamicTypeSize.allCases
        guard let i = all.firstIndex(of: base) else { return base }
        switch choice {
        case "small": return all[max(0, i - 1)]
        case "large": return all[min(all.count - 1, i + 1)]
        default: return base
        }
    }
}

/// A transcript item plus the "Tue, Sep 22 at 6:30 PM" separator that precedes it when the
/// conversation paused for a while, the way Messages breaks up a thread.
struct TranscriptRowModel: Identifiable, Equatable {
    var item: TranscriptItem
    var separator: String?
    /// The last reply before something that is not a reply (the bot sits beside this one).
    var lastOfRun = true
    var id: String { item.id }
    /// The row's kind in one word, for its accessibility identifier.
    var kindTag: String {
        switch item.kind {
        case .user: return "user"
        case .assistant: return "reply"
        case .tool: return "tool"
        case .system: return "note"
        case .error: return "error"
        case .subagent: return "helper"
        case .steer: return "steer"
        }
    }

    static let gap: TimeInterval = 15 * 60

    /// Rows the end of the thread keeps out of the lazy stack, at least: enough to fill the
    /// screen, so a thread at its end shows no lazy row.
    static let tailBlock = 16
    /// The most rows the end of the thread holds before the lazy stack takes some regardless.
    /// Room for a long turn of tool calls (one can add dozens of rows), whose rows would
    /// otherwise cross while it streams (see `settleTail`).
    static let tailCap = 96
    /// Where the rows that are not lazy would start if nothing held them: whole blocks, so
    /// the boundary moves once in a block of rows.
    static func tailStart(_ count: Int) -> Int {
        max(0, (count - tailBlock) / tailBlock * tailBlock)
    }
    /// Index of the first row that is not lazy. The thread's own boundary (`tailFrom`) stands
    /// while it leaves a sensible end: a thread that has not set one, a history that just
    /// arrived, or rows that piled up while the reader was up the thread, go by whole blocks.
    static func split(count: Int, tailFrom: Int?) -> Int {
        let wanted = tailStart(count)
        guard let tailFrom, tailFrom <= wanted, count - tailFrom <= tailCap else { return wanted }
        return tailFrom
    }

    static func build(_ items: [TranscriptItem], now: Date = Date()) -> [TranscriptRowModel] {
        var out: [TranscriptRowModel] = []
        var last: Date?
        var seen = Set<String>()
        for (i, original) in items.enumerated() {
            var item = original
            // Never two rows with one id: SwiftUI cannot tell such rows apart and may lay one
            // out where the other belongs. (A gateway that sends the same tool call twice, say.)
            if !seen.insert(item.id).inserted { item.id += "~\(i)"; seen.insert(item.id) }
            var sep: String?
            if last == nil || item.timestamp.timeIntervalSince(last!) > gap {
                sep = label(for: item.timestamp, now: now)
            }
            last = item.timestamp
            out.append(TranscriptRowModel(item: item, separator: sep))
        }
        // A run of replies (with tool cards between them) shows the bot and the tail once, on
        // the last one; a run of the person's messages gets one tail the same way.
        for i in out.indices {
            var next = i + 1
            while next < out.count, case .tool = out[next].item.kind { next += 1 }
            guard next < out.count else { continue }
            switch (out[i].item.kind, out[next].item.kind) {
            case (.assistant, .assistant), (.user, .user): out[i].lastOfRun = false
            default: break
            }
        }
        return out
    }

    static func label(for date: Date, now: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "Yesterday \(time)" }
        if let w = cal.date(byAdding: .day, value: -6, to: now), date > w { return date.formatted(.dateTime.weekday(.wide)) + " \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " at \(time)"
    }
}

struct SelectTextItem: Identifiable { let text: String; var id: String { text } }

struct TranscriptRow: View, Equatable {
    static func == (a: TranscriptRow, b: TranscriptRow) -> Bool {
        a.item == b.item && a.profile == b.profile && a.bot == b.bot && a.botShown == b.botShown && a.typingTool == b.typingTool
            && a.showReasoning == b.showReasoning && a.showStats == b.showStats
            && a.reasoningOpen.wrappedValue == b.reasoningOpen.wrappedValue
            && a.toolOpen.wrappedValue == b.toolOpen.wrappedValue
            && a.showToolOutput == b.showToolOutput && a.compactTools == b.compactTools && a.wide == b.wide
            && a.maxBubble == b.maxBubble && a.interruptCause == b.interruptCause
    }
    var item: TranscriptItem
    /// The bot beside its bubble, as in a group chat; nil for none. Only the last bubble of a
    /// run of replies gets the bot (`botShown`); the others keep the same left margin.
    var profile: String? = nil
    /// The chat's bot, for the pictures (its images dir on the gateway), shown or not.
    var bot: String? = nil
    var botShown = true
    /// While the reply has no text yet: nil = a grey typing bubble, a name = the dark one with
    /// the tool badge.
    var typingTool: String? = nil
    var showReasoning = true
    var showStats = true
    var onEdit: (String) -> Void = { _ in }
    var onOpenBot: (String) -> Void = { _ in }
    var onReply: (String) -> Void = { _ in }
    var onChooseModel: () -> Void = {}
    /// For a turn the gateway cut short: why, when this device knows, and the way to its setting.
    var interruptCause: InterruptedTurn.Cause? = nil
    var onKeepRunning: () -> Void = {}
    @AppStorage(ChatStyle.bubbleStyle) private var bubbleStyle = "tailed"
    @AppStorage(ChatStyle.botTint) private var botTint = false
    /// The reply bubble's fill: grey, or the bot's colour at a wash.
    private var replyFill: Color {
        if botTint, let profile { return BotColors.color(for: profile).opacity(scheme == .dark ? 0.22 : 0.16) }
        return Color(.systemGray5)
    }
    var reasoningOpen: Binding<Bool> = .constant(false)
    var onSelectText: (String) -> Void = { _ in }
    var toolOpen: Binding<Bool> = .constant(false)
    var showToolOutput = true
    var compactTools = false
    /// Reply bubbles run to the right edge.
    var wide = false
    /// The widest a bubble or card may be (the Mac's share of the reading column).
    var maxBubble: CGFloat = .infinity
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        #if os(macOS)
        // Like Messages: mine to the right, the bot's to the left, neither wider than its share;
        // notices stay centred across the column.
        let side = macSide
        content
            .frame(maxWidth: side == .center ? .infinity : maxBubble, alignment: side)
            .frame(maxWidth: .infinity, alignment: side)
        #else
        content
        #endif
    }

    #if os(macOS)
    private var macSide: Alignment {
        switch item.kind {
        case .user(let text, let attachments):
            return attachments.isEmpty && (InjectedNote.parse(text) != nil || AgentMessage.parse(text) != nil) ? .center : .trailing
        case .steer: return .trailing
        case .system(_, let symbol): return symbol == "terminal" ? .leading : .center
        case .tool(let act): return act.delivery != nil ? .center : .leading
        default: return .leading
        }
    }
    #endif

    @ViewBuilder private var content: some View {
        let _ = Perf.tick("row")
        switch item.kind {
        case .user(let text, let attachments) where attachments.isEmpty && InjectedNote.parse(text) != nil:
            // The gateway speaking in the user's seat (a background process reporting in): a
            // folded notice, not a blue bubble of the person's own words.
            InjectedNoteRow(note: InjectedNote.parse(text)!)
        case .user(let text, let attachments) where attachments.isEmpty && AgentMessage.parse(text) != nil:
            // Another bot wrote in: a compact notice with the words folded under it, not a
            // bubble of ours.
            let m = AgentMessage.parse(text)!
            BotMessageNotice(handle: m.key, label: m.sender, headline: "Message from \(m.sender)", body: m.body, pending: false, onOpen: onOpenBot)
        case .user(let text, let attachments):
            HStack {
                Spacer(minLength: 56)
                VStack(alignment: .trailing, spacing: 6) {
                    // A stored row keeps "[User attached image: name]" where the picture was: the
                    // picture comes back from the gateway's images dir, the mark leaves the bubble.
                    let attached = attachments.isEmpty ? TranscriptMedia.attachedImages(in: text, profile: bot) : []
                    let shownText = attached.isEmpty ? text : MediaScan.userTextWithoutAttachments(text)
                    if !attachments.isEmpty { AttachmentStrip(attachments: attachments) }
                    if !attached.isEmpty { MediaThumbStrip(refs: attached, profile: bot, side: 120, alignment: .trailing) }
                    if !shownText.isEmpty {
                        Text(shownText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .foregroundStyle(.white)
                            .background(AppTheme.current, in: MessageBubbleShape(side: .trailing, tailed: botShown && bubbleStyle == "tailed"))
                            .contextMenu {
                                Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                                Button { onSelectText(text) } label: { Label("Select Text", systemImage: "selection.pin.in.out") }
                                Button { onEdit(text) } label: { Label("Edit & resend", systemImage: "pencil") }
                                Button { onReply(text) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                                ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                            }
                    }
                }
            }
        case .assistant(let text, _, false) where InterruptedTurn.parse(text) != nil:
            InterruptedTurnCard(turn: InterruptedTurn.parse(text)!, cause: interruptCause, onKeepRunning: onKeepRunning)
        case .assistant(let text, let reasoning, let streaming):
            HStack(alignment: .bottom, spacing: 10) {
                if let profile {
                    if botShown, streaming {
                        // The live bot is the pinned one at the bottom of the thread; keep the column.
                        Color.clear.frame(width: 28, height: 1)
                    } else if botShown {
                        // A finished reply keeps a painted bot: a live one per row is what stuttered.
                        Image(uiImage: BotAvatarImage.cached(profile: profile, size: 28, scheme: scheme))
                            .resizable().frame(width: 28, height: 28)
                    } else {
                        Color.clear.frame(width: 28, height: 1)
                    }
                }
                if streaming && text.isEmpty {
                    // Nothing to read yet: the typing bubble (dark with a badge while a tool
                    // runs), the reasoning above it when there is some, the live count below.
                    VStack(alignment: .leading, spacing: 6) {
                        if showReasoning, let reasoning, !reasoning.isEmpty {
                            ReasoningDisclosure(text: reasoning, open: reasoningOpen, itemID: item.id)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(bubbleStyle == "plain" ? Color.clear : replyFill, in: MessageBubbleShape(side: .leading, tailed: false))
                        }
                        TypingBubble(tool: typingTool)
                        if showStats, let s = item.stats {
                            Text(s.label).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).padding(.leading, 6)
                                .contentTransition(.numericText())
                                .accessibilityLabel("Turn statistics: \(s.label)")
                        }
                    }
                    Spacer(minLength: wide ? 0 : 40)
                } else {
                VStack(alignment: .leading, spacing: 6) {
                    if showReasoning, let reasoning, !reasoning.isEmpty { ReasoningDisclosure(text: reasoning, open: reasoningOpen, itemID: item.id) }
                    // Pictures the bot sent (MEDIA: lines, markdown images, bare paths) show under
                    // the words as thumbnails fetched through the gateway.
                    let media = TranscriptMedia.images(in: text)
                    MarkdownView(text: media.isEmpty ? text : MediaScan.textWithoutMedia(text), inlineSelection: false).equatable()
                    if !media.isEmpty { MediaThumbStrip(refs: media, profile: bot) }
                    if showStats, let s = item.stats {
                        Text(s.label).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            .accessibilityLabel("Turn statistics: \(s.label)")
                    }
                }
                .padding(.horizontal, bubbleStyle == "plain" ? 4 : 14).padding(.vertical, bubbleStyle == "plain" ? 4 : 9)
                .background(bubbleStyle == "plain" ? Color.clear : replyFill, in: MessageBubbleShape(side: .leading, tailed: botShown && bubbleStyle == "tailed"))
                #if os(macOS)
                // The whole bubble takes the right-click, padding and gaps too: on the words the
                // Mac's selectable text gives its own menu, which has no Copy for the reply (#255).
                .contentShape(.rect)
                #endif
                .contextMenu {
                    Button { onReply(text) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    Button { VoiceCoordinator.shared.toggleSpeaking(text) } label: {
                        Label(VoiceCoordinator.shared.isSpeaking(text) ? "Stop Speaking" : "Speak", systemImage: VoiceCoordinator.shared.isSpeaking(text) ? "speaker.slash" : "speaker.wave.2")
                    }
                    #if os(macOS)
                    Button { UIPasteboard.general.string = TranscriptMedia.copyText(text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    #else
                    Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                    #endif
                    Button { onSelectText(text) } label: { Label("Select Text", systemImage: "selection.pin.in.out") }
                    ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                #if os(macOS)
                // Copy on hover, past the bubble's trailing edge (#255); not while it streams.
                .modifier(ReplyCopyHover(text: text, enabled: !streaming))
                #endif
                Spacer(minLength: wide ? 0 : 24)
                }
            }
        case .steer(let text, let status):
            HStack {
                Spacer(minLength: 56)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color(.systemGray4), in: MessageBubbleShape(side: .trailing))
                        .contextMenu {
                            Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                            Button { onEdit(text) } label: { Label("Edit & resend", systemImage: "pencil") }
                        }
                    Label(status == "queued" ? "Steered · queued" : "Steered", systemImage: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .tool(let act) where act.delivery != nil:
            // A message to another bot: "Messaging X…", then "Messaged X", then X's answer.
            let d = act.delivery!
            VStack(spacing: 4) {
                BotMessageNotice(handle: d.target, label: d.target, headline: act.status == .running ? "Messaging \(d.target)…" : "Messaged \(d.target)", body: d.message, pending: act.status == .running, onOpen: onOpenBot)
                if let reply = act.deliveryReply {
                    BotMessageNotice(handle: d.target, label: d.target, headline: "Message from \(d.target)", body: reply, pending: false, onOpen: onOpenBot)
                }
            }
        case .tool(let act):
            ToolCardView(activity: act, itemID: item.id, open: toolOpen, showOutput: showToolOutput, compact: compactTools)
        case .system(let text, let symbol) where symbol == "terminal":
            // A slash command's reply: reading size, selectable, with Copy; the terminal mark
            // and a quiet background keep it apart from the bot's words (a tester could neither
            // read nor copy the small grey line it was).
            VStack(alignment: .leading, spacing: 6) {
                Label("Command", systemImage: "terminal").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).font(.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).padding(.trailing, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            .overlay(alignment: .topTrailing) { CopyButton(text: text).padding(6) }
        case .system(let text, let symbol):
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(text)
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        case .error(let text) where StartFailure.parse(text) != nil:
            StartFailureCard(failure: StartFailure.parse(text)!, raw: text, onChooseModel: onChooseModel)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.12), in: .rect(cornerRadius: 12))
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .subagent(let a):
            SubagentRow(activity: a)
        }
    }
}

/// The bot's model could not start on the gateway (a provider whose CLI or key is not there):
/// what is wrong in plain words, a way to carry on with another model, and the gateway fix.
struct StartFailureCard: View {
    var failure: StartFailure
    var raw: String
    var onChooseModel: () -> Void
    @State private var showRaw = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This bot's model could not start", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.red)
            if let p = failure.provider {
                Text("The bot is set to the provider \(p), which needs its command-line tool installed and configured on the gateway machine. That is not something the app can do from here.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(failure.reason).font(.footnote).foregroundStyle(.secondary)
            }
            Text("Pick another model for this chat, or set the provider up on the gateway with hermes setup, or in Settings › Model.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(action: onChooseModel) { Label("Choose another model", systemImage: "cpu") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button { withAnimation(.snappy) { showRaw.toggle() } } label: { Text(showRaw ? "Hide details" : "Details").font(.caption) }
                    .buttonStyle(.borderless)
            }
            if showRaw {
                Text(raw).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.10), in: .rect(cornerRadius: 12))
    }
}

/// A gateway note that arrived in the user's seat: one quiet line, the words folded under it.
/// A helper the bot spun up: its goal, what it is on while it runs, and its report once it is
/// back, folded under the row like a tool card's output.
struct SubagentRow: View {
    var activity: SubagentActivity
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: activity.isRunning ? "person.2.circle" : activity.failed ? "person.2.slash" : "person.2.circle.fill")
                    .font(.body).frame(width: 22)   // the slash glyph is wider: the text lines up across states
                    .foregroundStyle(activity.failed ? Color.red : activity.isRunning ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(activity.goal).lineLimit(3)
                    if let line = activity.detailLine {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .contentTransition(.opacity)
                    }
                }
                Spacer(minLength: 4)
                if activity.isRunning {
                    ProgressView().controlSize(.small)
                } else if activity.summary?.isEmpty == false {
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            if open, let s = activity.summary, !s.isEmpty {
                Text(s).font(.caption).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .font(.footnote)
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .contentShape(.rect)
        .onTapGesture { if activity.summary?.isEmpty == false { withAnimation(.snappy) { open.toggle() } } }
        // The detail line changes as the helper reports in, without an animation of its own: one
        // here resized the card on its own while the rows around it jumped, so a card whose line
        // got shorter was drawn over the row under it until it caught up.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Subagent: \(activity.goal). \(activity.detailLine ?? "")")
    }
}

struct InjectedNoteRow: View {
    var note: InjectedNote
    @State private var open = false
    var body: some View {
        VStack(spacing: 6) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: note.title.contains("failed") ? "exclamationmark.circle" : note.title.hasPrefix("Scheduled") ? "clock" : note.title.hasPrefix("Subagent") ? "person.2" : "gearshape.2")
                    Text(note.title).font(.caption)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2.weight(.bold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(note.title). \(open ? "Hides" : "Shows") the details")
            if open {
                Text(note.body).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

/// The whole tool call on its own page: the command or arguments and the output, as text you
/// can select by range and share.
struct ToolCallSheet: View {
    var activity: ToolActivity
    var fullCall: String?
    @Environment(\.dismiss) private var dismiss
    private var text: String {
        var parts: [String] = []
        if let c = fullCall, !c.isEmpty { parts.append((activity.name == "terminal" || activity.name == "bash" ? "# Command\n" : "# Arguments\n") + c) }
        if let r = activity.resultText, !r.isEmpty { parts.append("# Output\n" + r) }
        if let s = activity.summary, !s.isEmpty, parts.isEmpty { parts.append(s) }
        return parts.joined(separator: "\n\n")
    }
    var body: some View {
        NavigationStack {
            SelectableText(text: text, monospaced: true)
                .navigationTitle(activity.displayName).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") } }
                }
        }
    }
}

/// A centred, quiet line for bot-to-bot traffic ("Messaged work", "Message from work") with the
/// other bot's face; the words fold under it, and a tap opens that bot's own chat.
struct BotMessageNotice: View {
    var handle: String
    var label: String
    var headline: String
    var body_: String?
    var pending: Bool
    var onOpen: (String) -> Void
    @State private var open = false

    init(handle: String, label: String, headline: String, body: String?, pending: Bool, onOpen: @escaping (String) -> Void) {
        self.handle = handle; self.label = label; self.headline = headline; self.body_ = body; self.pending = pending; self.onOpen = onOpen
    }

    var body: some View {
        VStack(spacing: 6) {
            Button { onOpen(handle) } label: {
                HStack(spacing: 6) {
                    BotAvatar(profile: handle, size: 18, active: pending)
                    Text(headline).font(.caption).foregroundStyle(.secondary)
                    if pending { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(headline). Opens \(label)'s chat")
            if let text = body_, !text.isEmpty {
                Button { withAnimation(.snappy) { open.toggle() } } label: {
                    Text(open ? "hide message" : "show message").font(.caption2).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                if open {
                    Text(text).font(.footnote).textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: 360, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

struct ReasoningDisclosure: View {
    var text: String
    @Binding var open: Bool
    var itemID: String? = nil
    @State private var revealing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // One full-width hit target, edge to edge, rather than DisclosureGroup's label-only one.
            Button { toggle() } label: {
                HStack {
                    Label("Reasoning", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Hide reasoning" : "Show reasoning")
            if open {
                // Models think in markdown (headings, lists, tables): render it, small and quiet.
                MarkdownView(text: text, style: .reasoning, inlineSelection: false).equatable()
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _, f in
            if revealing, let itemID { NotificationCenter.default.post(name: .hermesRevealRow, object: nil, userInfo: ["bottom": f.maxY, "top": f.minY, "id": itemID]) }
        }
    }

    private func toggle() {
        if !open { revealing = true; Task { try? await Task.sleep(for: .milliseconds(600)); revealing = false } }
        withAnimation(.snappy) { open.toggle() }
    }
}

extension Notification.Name {
    /// A row that just expanded reports its bottom edge (global y) so the thread can show it.
    static let hermesRevealRow = Notification.Name("hermesRevealRow")
    /// A message left the composer (object: its chat): the thread goes to the end for it.
    static let hermesMessageSent = Notification.Name("hermesMessageSent")
}

/// Renders markdown blocks; inline styling from AttributedString(markdown:).
struct MarkdownView: View, Equatable {
    var text: String
    var style: Style = .reply

    /// How the blocks are dressed. A reply keeps the thread's own text size and colour; a
    /// Reasoning card is footnote-sized and secondary, with small headings, and its html fences
    /// stay code: a live web card does not belong in a model's notes to itself.
    enum Style: Equatable {
        case reply, reasoning
        var showsCards: Bool { self == .reply }
        var codeFont: Font { self == .reply ? .system(.footnote, design: .monospaced) : .system(.caption, design: .monospaced) }
    }

    /// Parsed blocks and inline styling, kept for the text they came from: a row that scrolls
    /// off and back (the lazy stack rebuilds it) does not parse its markdown again, and a
    /// finished reply is parsed once for as long as it is in the cache.
    // Bounded: a streaming reply makes a new entry per token, and a long day of chats made
    // thousands that nothing ever read again. By size too (the cost is the text's length): a
    // long report streaming for minutes made hundreds of entries, each the whole reply so far
    // twice over (the key and its blocks), and 400 of those ran to tens of megabytes.
    private static let blockCache: NSCache<NSString, BlocksBox> = {
        let c = NSCache<NSString, BlocksBox>(); c.countLimit = 400; c.totalCostLimit = 4_000_000; return c
    }()
    private static let inlineCache: NSCache<NSString, InlineBox> = {
        let c = NSCache<NSString, InlineBox>(); c.countLimit = 2000; c.totalCostLimit = 2_000_000; return c
    }()
    final class BlocksBox { let blocks: [MarkdownBlock]; init(_ b: [MarkdownBlock]) { blocks = b } }
    final class InlineBox { let text: AttributedString; init(_ t: AttributedString) { text = t } }

    static func blocks(_ text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = blockCache.object(forKey: key) { return hit.blocks }
        let b = MarkdownParser.blocks(from: text)
        blockCache.setObject(BlocksBox(b), forKey: key, cost: text.utf8.count)
        return b
    }
    @MainActor static func inline(_ text: String) -> AttributedString {
        // Mentions are marked after the cache: they depend on the bots known now, not on the text.
        Mentions.mark(inlineCached(text), names: Mentions.names)
    }
    static func inlineCached(_ text: String) -> AttributedString {
        let key = text as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.text }
        let a = MarkdownParser.inline(text)
        inlineCache.setObject(InlineBox(a), forKey: key, cost: text.utf8.count)
        return a
    }

    /// Cards (fenced html) whose source is showing instead, by block position.
    @State private var sourceShown: Set<Int> = []

    /// Selectable in place. Chat bubbles on the iPhone turn it off (see `selectable`).
    var inlineSelection = true

    static func == (a: MarkdownView, b: MarkdownView) -> Bool { a.text == b.text && a.style == b.style && a.inlineSelection == b.inlineSelection }

    var body: some View {
        let _ = Perf.tick("markdown")
        let blocks = Self.blocks(text)
        let stack = VStack(alignment: .leading, spacing: style == .reasoning ? 6 : 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                render(block, at: i)
            }
        }
        // A reply sets no font of its own: the thread's text size setting reaches it unchanged.
        if style == .reasoning {
            selectable(stack).font(.footnote).foregroundStyle(.secondary)
        } else {
            selectable(stack)
        }
    }

    /// Selectable in place, except in an iPhone chat bubble: there the selection's own touch
    /// handling took the taps of everything else in the bubble, so a Reasoning card above a
    /// reply could not be opened (or closed). Text there is selected with Select Text in the
    /// bubble's menu; the Mac keeps selection in place.
    @ViewBuilder private func selectable(_ v: some View) -> some View {
        #if os(macOS)
        v.textSelection(.enabled)
        #else
        if inlineSelection { v.textSelection(.enabled) } else { v }
        #endif
    }

    @ViewBuilder private func render(_ block: MarkdownBlock, at index: Int) -> some View {
        switch block {
        case .paragraph(let t):
            // Never squeezed to a line: on the Mac a reply under an opened Reasoning card lost
            // all but the first line of its last paragraph.
            Text(Self.inline(t)).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let t):
            Text(Self.inline(t)).font(Self.headingFont(level, style: style)).fixedSize(horizontal: false, vertical: true)
        case .code(let lang, let code, let closed) where style.showsCards && closed && HTMLCard.isCard(language: lang) && !sourceShown.contains(index):
            // A card the bot drew in HTML, once its fence has closed; while it streams it is
            // the code block below. Show Source turns it back into one.
            HTMLCardView(html: code, onShowSource: { withAnimation(.snappy) { _ = sourceShown.insert(index) } })
                .contextMenu {
                    Button { withAnimation(.snappy) { _ = sourceShown.insert(index) } } label: { Label("Show Source", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Button { UIPasteboard.general.string = code } label: { Label("Copy HTML", systemImage: "doc.on.doc") }
                }
        case .code(let lang, let code, let closed):
            // Wrapped, not side-scrolling: code is read down the page and copied whole, so long
            // lines wrap rather than hide past the edge (tables are what scroll sideways, and the
            // time reveal stands aside for them). A copy button sits in the corner.
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if let lang, !lang.isEmpty { Text(lang).font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if style.showsCards, closed, HTMLCard.isCard(language: lang) {
                        Button { withAnimation(.snappy) { _ = sourceShown.remove(index) } } label: {
                            Label("Show Card", systemImage: "rectangle.on.rectangle").font(.caption2).labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain).foregroundStyle(.tint).padding(.trailing, 6)
                    }
                    if closed { CopyButton(text: code) } else { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 10).padding(.top, 6)
                Text(code).font(style.codeFont).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        listMarker(it)
                        Text(Self.inline(it.text))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(it.depth) * 18)
                }
            }
        case .table(let table):
            MarkdownTableView(table: table)
        case .image(let alt, let url, let link):
            MarkdownImageView(alt: alt, url: url, link: link)
        case .quote(let t):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.secondary).frame(width: 3)
                Text(Self.inline(t)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Divider()
        }
    }
}

extension MarkdownView {
    /// h1 and h2 keep their original look; h3 to h6 step down so they stay distinguishable.
    static func headingFont(_ level: Int) -> Font {
        switch level {
        case ...1: .title2.weight(.bold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        case 4: .subheadline.weight(.semibold)
        case 5: .subheadline.weight(.medium)
        default: .footnote.weight(.semibold)
        }
    }

    /// A Reasoning card's headings stay near its footnote text: a title-sized line in the
    /// middle of the model's notes read louder than the reply under them.
    static func headingFont(_ level: Int, style: Style) -> Font {
        guard style == .reasoning else { return headingFont(level) }
        switch level {
        case ...1: return .subheadline.weight(.bold)
        case 2: return .subheadline.weight(.semibold)
        case 3: return .footnote.weight(.bold)
        default: return .footnote.weight(.semibold)
        }
    }

    @ViewBuilder func listMarker(_ item: MarkdownListItem) -> some View {
        switch item.marker {
        case .bullet:
            Text(item.depth == 0 ? "•" : item.depth == 1 ? "◦" : "▪")
        case .number(let n):
            Text("\(n).").monospacedDigit()
        case .task(let checked):
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                .accessibilityLabel(checked ? "Done" : "Not done")
        }
    }
}

/// A markdown table as a small card. Each column is as wide as its longest cell asks (held
/// between about 64 and 220 pt; a longer cell wraps, three lines at most here), so a wide table
/// no longer squeezes every column into the bubble and breaks words letter by letter. A table
/// that fits fills the bubble; a wider one scrolls sideways inside the card, the side with more
/// to see fading out, and the thread's time reveal stands aside for that drag. The corner button
/// shows the whole table on its own sheet. At the accessibility text
/// sizes each row becomes a card of "Header: value" lines instead, which needs no scrolling.
struct MarkdownTableView: View {
    var table: MarkdownTable
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var full = false
    @State private var more = MarkdownTableMetrics.Overflow()

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                MarkdownTableStack(table: table)
            } else {
                card
            }
        }
        // No menu of its own: a long press keeps the reply's (Reply, Speak, Copy, Share). The
        // corner button opens the table, and its sheet copies it as Markdown.
        // Local, as the html card's is: the row stays alive under its sheet in the lazy thread.
        .sheet(isPresented: $full) { MarkdownTableSheet(table: table).sheetFrame(.wide).withAppModel() }
    }

    private var grid: some View {
        MarkdownTableGrid(table: table, lineLimit: 3, maxColumn: MarkdownTableMetrics.bubbleMaxColumn, headerInset: 22)
    }

    private var card: some View {
        // The grid alone when its columns fit (it then stretches to the bubble's width), else
        // the same grid in a sideways scroll view. Deciding here, rather than always scrolling,
        // keeps a narrow table free of a scroll view that would catch the thread's drags.
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) { grid }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: MarkdownTableMetrics.Overflow.self) { g in
                    MarkdownTableMetrics.overflow(contentWidth: g.contentSize.width, visibleMinX: g.visibleRect.minX, visibleMaxX: g.visibleRect.maxX)
                } action: { _, now in more = now }
                .mask { fade.animation(.easeOut(duration: 0.15), value: more) }
        }
        .background(Color(.systemBackground).opacity(0.5))
        .clipShape(.rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color(.separator), lineWidth: 0.5) }
        .overlay(alignment: .topTrailing) {
            Button { full = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(.thinMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel("Open the table full screen")
            .help("Open Table")
        }
        .accessibilityElement(children: .contain)
        // Not selectable in the bubble: on the Mac each selectable cell is an AppKit text view
        // with its own accessibility, and inside the sideways scroll view VoiceOver's reading of
        // them recursed until the app crashed. The full-screen sheet keeps selection and copy.
        .textSelection(.disabled)
    }

    /// Opaque in the middle; an edge with more of the table past it fades to nothing.
    private var fade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(more.leading ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing).frame(width: 24)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(more.trailing ? 0 : 1)], startPoint: .leading, endPoint: .trailing).frame(width: 24)
        }
    }
}

/// A standalone markdown image. It is fetched only after the user taps it: a reply can embed an
/// arbitrary URL, and auto-loading one would let injected content leak chat data through the
/// query string (and reveal the device IP) without any interaction. Optionally a link.
struct MarkdownImageView: View {
    var alt: String
    var url: String
    var link: String?
    @Environment(\.openURL) private var openURL
    @State private var loadRequested = false
    /// Set when a requested load has been pending past `loadTimeout`.
    @State private var timedOut = false

    var body: some View {
        // Only remote https images load: a reply must not make the app read local paths, and
        // App Transport Security rejects cleartext http anyway.
        if let u = URL(string: url), u.scheme?.lowercased() == "https", let host = u.host() {
            if loadRequested {
                loaded(u)
            } else {
                Button { loadRequested = true } label: {
                    Label(alt.isEmpty ? "Load image from \(host)" : "\(alt) (load from \(host))", systemImage: "photo")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Loads the image from \(host)")
            }
        } else {
            placeholder
        }
    }

    /// What a standalone image shows. Pure, so the decision can be unit-tested without a network.
    enum Display: Equatable { case image, spinner, placeholder }

    /// A finished load wins (even a late one); a failure or a stalled load (`timedOut`) shows the placeholder;
    /// otherwise the spinner keeps turning.
    static func display(success: Bool, failure: Bool, timedOut: Bool) -> Display {
        if success { return .image }
        if failure || timedOut { return .placeholder }
        return .spinner
    }

    static func placeholderTitle(alt: String) -> String { alt.isEmpty ? "Image unavailable" : alt }

    /// The one fallback for every image that cannot be shown: a blocked scheme, a failed load, a stalled load.
    private var placeholder: some View {
        Label(Self.placeholderTitle(alt: alt), systemImage: "photo")
            .font(.footnote).foregroundStyle(.secondary)
    }

    /// AsyncImage has no timeout of its own: past this, a stalled load shows the placeholder, and an image that
    /// still arrives later replaces it.
    private static let loadTimeout: Duration = .seconds(15)

    @State private var picture: UIImage?
    @State private var failed = false

    @ViewBuilder private func loaded(_ u: URL) -> some View {
        // Fetched to the caches and decoded downsampled, off the main thread, like a picture
        // from the gateway: AsyncImage decoded the whole bitmap in the row.
        let image = Group {
            switch Self.display(success: picture != nil, failure: failed, timedOut: timedOut) {
            case .image: if let picture { Image(uiImage: picture).resizable().scaledToFit().clipShape(.rect(cornerRadius: 8)) }
            case .placeholder: placeholder
            case .spinner: ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: u) { await fetch(u) }
        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
        if let link, let target = URL(string: link), ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
            Button { openURL(target) } label: { image }.buttonStyle(.plain)
        } else {
            image
        }
    }

    private func fetch(_ u: URL) async {
        let clock = Task { try? await Task.sleep(for: Self.loadTimeout); timedOut = true }
        defer { clock.cancel() }
        do {
            let (data, _) = try await URLSession.shared.data(from: u)
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("vory-web-images", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var name = u.absoluteString.utf8.reduce(UInt64(5381)) { ($0 << 5) &+ $0 &+ UInt64($1) }.description
            if !u.pathExtension.isEmpty { name += "." + u.pathExtension }
            let file = dir.appendingPathComponent(name)
            try data.write(to: file)
            guard !Task.isCancelled else { return }
            if let decoded = await AttachmentThumbs.imageAsync(at: file, side: 1200) { picture = decoded } else { failed = true }
        } catch {
            failed = true
        }
    }
}

struct ToolCardView: View {
    var activity: ToolActivity
    /// The transcript row this card is, for the reveal after it opens.
    var itemID: String? = nil
    /// Open state owned by the thread (so a recycled row keeps it and the turn's end can fold it).
    var open: Binding<Bool> = .constant(false)
    /// The Output block when open (Appearance › Chat).
    var showOutput = true
    /// One line: name, time and chevron; the context and summary lines only when open.
    var compact = false
    /// Set while the card opens: its frame changes are reported so the thread can reveal it.
    @State private var revealing = false
    @State private var showFull = false
    private var expanded: Bool { open.wrappedValue }
    /// What the tool was asked: the command out of the args when they are JSON with one, the
    /// args as sent, or the context line.
    private var fullCall: String? {
        if let a = activity.argsText, !a.isEmpty {
            if let m = a.firstMatch(of: /"command"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
                return String(m.1).replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\t", with: "\t")
            }
            return a
        }
        return activity.context
    }
    /// The todo tool's items, when this card is one: drawn as a checklist, not as JSON.
    private var todos: [TodoItem]? { TodoItem.parse(name: activity.name, argsText: activity.argsText) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 8) {
                statusIcon
                Text(activity.displayName).font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
                if let risk = activity.risk { Text(risk).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.orange.opacity(0.2), in: .capsule) }
                if compact, !expanded, let c = activity.context, !c.isEmpty {
                    Text(c).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let d = activity.durationSeconds { Text(String(format: "%.1fs", d)).font(.caption2).foregroundStyle(.secondary) }
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            if let todos {
                TodoChecklist(items: todos, all: expanded || compact == false && todos.count <= 4)
            }
            if todos == nil, let c = activity.context, !c.isEmpty, !expanded, !compact {
                Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if todos == nil, let s = activity.summary, !s.isEmpty, !expanded, !compact {
                Text(s).font(.caption).lineLimit(2)
            }
            if expanded {
                if compact, todos == nil, let s = activity.summary, !s.isEmpty { Text(s).font(.caption).lineLimit(3) }
                // The whole call: the args when the gateway sent them, else the context line in
                // full (a tester opened a card and got a few more characters of a cut preview).
                if todos == nil, let a = fullCall, !a.isEmpty {
                    Text(activity.name == "terminal" || activity.name == "bash" ? "Command" : "Arguments").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    CodeBlock(text: a, lineCap: 40)
                }
                if showOutput, let r = activity.resultText, !r.isEmpty {
                    Text("Output").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    CodeBlock(text: r, lineCap: 30)
                    // A tool that made or found pictures (a screenshot, a render): shown, not just named.
                    let shots = MediaScan.imagePaths(inToolOutput: r)
                    if !shots.isEmpty { MediaThumbStrip(refs: shots, profile: nil, side: 110) }
                }
                Button { showFull = true } label: {
                    Label("Open the full call", systemImage: "arrow.up.left.and.arrow.down.right").font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
        }
        .sheet(isPresented: $showFull) { ToolCallSheet(activity: activity, fullCall: fullCall).sheetFrame(.wide).withAppModel() }
        .padding(compact ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A painted card, not glass: a thread can hold dozens of these, and each live glass
        // layer is composited every frame while the thread scrolls (the stutter on device).
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: compact ? 10 : 14))
        .overlay(RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .contentShape(.rect)
        .onTapGesture {
            if !expanded { revealing = true; Task { try? await Task.sleep(for: .milliseconds(600)); revealing = false } }
            withAnimation(.snappy) { open.wrappedValue.toggle() }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { _, y in
            if revealing, let itemID { NotificationCenter.default.post(name: .hermesRevealRow, object: nil, userInfo: ["bottom": y, "id": itemID]) }
        }
        .accessibilityElement(children: .combine)
        // A tap gesture alone gives assistive tech nothing to press (on the Mac the card was plain text).
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { withAnimation(.snappy) { open.wrappedValue.toggle() } }
        .accessibilityHint(DeviceWords.isMac ? "Expands the tool log" : "Double-tap to expand the tool log")
    }

    @ViewBuilder private var statusIcon: some View {
        switch activity.status {
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// Monospaced block with a light background, capped at `lineCap` lines until "Show more" —
/// a terminal transcript can be thousands of lines.
struct CodeBlock: View {
    var text: String
    var lineCap: Int
    @State private var showAll = false

    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }
    private var shown: String {
        showAll || lines.count <= lineCap ? String(text.prefix(20_000)) : lines.prefix(lineCap).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shown).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).padding(10).padding(.trailing, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            .overlay(alignment: .topTrailing) { CopyButton(text: text).padding(6) }
            if lines.count > lineCap {
                Button(showAll ? "Show less" : "Show \(lines.count - lineCap) more lines") { withAnimation(.snappy) { showAll.toggle() } }
                    .font(.caption)
            }
        }
    }
}

struct AttachmentStrip: View {
    var attachments: [AttachmentPreview]
    @State private var preview: URL?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { a in
                Button { if let u = a.localURL { preview = u } } label: {
                    // A thumbnail, never the full photo: a 12-megapixel bitmap per row is what a
                    // thread of screenshots turns into otherwise.
                    if a.kind == .image, let u = a.localURL, let img = AttachmentThumbs.image(at: u, side: 96) {
                        Image(uiImage: img).resizable().scaledToFill().frame(width: 96, height: 96).clipShape(.rect(cornerRadius: 12))
                    } else {
                        Label(a.name, systemImage: a.kind == .pdf ? "doc.richtext" : a.kind == .audio ? "waveform" : a.kind == .video ? "video" : "doc")
                            .font(.caption).lineLimit(1)
                            .padding(8).glassEffect(.regular, in: .rect(cornerRadius: 10))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .quickLookPreview($preview)
    }
}

/// Small clipboard button that flips to a check mark for a moment after copying.
struct CopyButton: View {
    var text: String
    @State private var copied = false
    var body: some View {
        Button {
            UIPasteboard.general.string = text
            withAnimation(.snappy) { copied = true }
            Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { copied = false } }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption).foregroundStyle(copied ? .green : .secondary)
                .frame(width: 24, height: 20).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy code")
    }
}


/// One line of the todo tool's list.
struct TodoItem: Identifiable, Hashable {
    var id: String
    var content: String
    var status: String

    /// The tool's arguments as items, for the todo tool only ({"todos": [{content, id, status}]}).
    static func parse(name: String, argsText: String?) -> [TodoItem]? {
        guard name.lowercased().hasPrefix("todo"), let a = argsText, let data = a.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["todos"] as? [[String: Any]], !list.isEmpty else { return nil }
        return list.enumerated().map { i, t in
            TodoItem(id: (t["id"] as? String) ?? String(describing: t["id"] ?? i), content: (t["content"] as? String) ?? (t["title"] as? String) ?? "",
                     status: ((t["status"] as? String) ?? "pending").lowercased())
        }
    }
}

/// The todo tool as a checklist: done, in progress, pending. Collapsed, the first four and a count.
struct TodoChecklist: View {
    var items: [TodoItem]
    var all: Bool

    private func symbol(_ s: String) -> (String, Color) {
        switch s {
        case "completed", "done": return ("checkmark.circle.fill", .green)
        case "in_progress", "in-progress", "active", "doing": return ("arrow.right.circle.fill", .blue)
        case "cancelled", "canceled", "skipped": return ("xmark.circle", .secondary)
        default: return ("circle", .secondary)
        }
    }

    var body: some View {
        let shown = all ? items : Array(items.prefix(4))
        let done = items.filter { ["completed", "done"].contains($0.status) }.count
        VStack(alignment: .leading, spacing: 5) {
            ForEach(shown) { t in
                let (sym, color) = symbol(t.status)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: sym).foregroundStyle(color).font(.caption)
                    Text(t.content).font(.caption)
                        .strikethrough(["completed", "done"].contains(t.status), color: .secondary)
                        .foregroundStyle(["completed", "done"].contains(t.status) ? .secondary : .primary)
                        .lineLimit(all ? nil : 2)
                }
            }
            if items.count > shown.count || !all {
                Text("\(done) of \(items.count) done" + (items.count > shown.count ? ", \(items.count - shown.count) more" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Todo list, \(done) of \(items.count) done")
    }
}
