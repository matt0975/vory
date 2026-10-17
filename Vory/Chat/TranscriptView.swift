import Combine
import QuickLook
import SwiftUI
import VoryCore

struct TranscriptView: View {
    @Bindable var chat: ChatSession
    /// Long-press › "Edit & resend" (with the message's id: the composer edits it in place) or "Copy to message" (nil:
    /// the words only, for a new message) hands the text to the composer (#556).
    var onEditMessage: (String, String?) -> Void = { _, _ in }
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
    private var visibleBottom: CGFloat { min(scrollBottom, windowGeometry.bounds.height - autoInset) }
    /// The window as it is now: its height for the bottom edge above, its keyboard for the
    /// margin below. Read from the window on every layout, so a fold or a resize moves both.
    @Environment(\.windowGeometry) private var windowGeometry
    @Environment(\.wideLayout) private var wide
    /// The scroll view's top edge in window space, for the header's bottom edge measured the
    /// same way (`headerBottom`): the top margin is the distance between the two, whatever
    /// safe area or camera strip the header sits in.
    @State private var scrollTop: CGFloat = 0
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
    /// Height of the floating header (the nav bar is hidden in a chat), used until the header
    /// has been measured.
    var topInset: CGFloat = 96
    /// The floating header's bottom edge in window space (0 = not measured): the thread's top
    /// margin ends there, however much safe area the header stands in.
    var headerBottom: CGFloat = 0
    /// False where the keyboard never covers the thread: onboarding's tour (#388) lifts its chat, dock and all, over
    /// the keyboard, so the floor below (the keyboard's height, for a thread that runs to the window's bottom) would
    /// push its last line out of a frame that size.
    var keyboardFloors = true
    /// The header band's fade (`ChatStyle.bandFade` on iOS, 0 where there is no band): added to
    /// the top margin so the first row reads whole. The bottom has no fade above the bar (the
    /// thread shows through the field's glass, Matt 2026-10-10): the last row ends 8 pt above
    /// the dock, as before.
    var bandFade: CGFloat = 0
    /// `scrollTop` is 0 when the thread starts at the window's top edge (it runs under the status
    /// bar), which is the usual case, so only the header's measurement gates this.
    private var effectiveTopInset: CGFloat { headerBottom > 0 ? max(0, headerBottom - scrollTop) : topInset }
    /// Locked to the bottom: the thread follows every new token, tool call and card. Only the
    /// user's own drag releases it; the jump button (or scrolling back down) locks it again.
    @State private var awayFromBottom = false
    /// A card is opening or closing: the thread's size changes anchor at the top meanwhile, so the card keeps its place
    /// (`holdCard`). Bumped per toggle, so an earlier toggle's release stands down.
    @State private var holdingCard = false
    /// While a chat's history lands under the rows it opened with, the thread is out of sight until it is at its end (#449).
    @State private var landingOutOfSight = false
    @State private var landingReveal: Task<Void, Never>?
    @State private var landingCap: Task<Void, Never>?
    @State private var cardHold = 0
    /// A row arrived during a hold: the thread follows it once the hold is over (`holdCard`).
    @State private var followAfterHold = false
    /// Scrolling is by content edge, not by the "bottom" marker view: with the lazy stack a
    /// marker that is not yet laid out gets an estimated position, and the jump-to-bottom button
    /// overshot and bounced back up.
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var insetSettle: Task<Void, Never>?
    /// The scroll figures that change every frame (offset, distance to the end, sizes). A plain
    /// object, not view state: writing view state per frame re-evaluated this whole body, and
    /// every row with it, on every frame of a flick.
    @State private var metrics = ScrollMetrics()
    #if os(macOS)
    /// Whether the thread is scrolling, read only by the rows' hit-test gate (`ThreadHitGate`).
    @State private var hitGate = ThreadHitGate()
    #endif
    /// While the chat is still settling after it opened (history arriving, header and dock
    /// measuring), every adjustment lands without animation; animated ones fought each other.
    @State private var openedAt = Date()
    private var settling: Bool { Date().timeIntervalSince(openedAt) < 1.5 }
    @State private var jumpTask: Task<Void, Never>?
    /// Where the part of the thread that is not lazy starts (see `threadRows`), once the thread
    /// has set it: it moves only while the thread rests at its end. `TranscriptRowModel.split`
    /// says when it is not used.
    @State private var tailFrom: Int?
    @State private var overscrollTask: Task<Void, Never>?
    /// When the keyboard last moved: its own spring carries a stuck thread to the end, so a
    /// small overshoot is not landed against it.
    @State private var keyboardMovedAt = Date.distantPast
    /// Until when the eased landing of an overshoot is under way: no landing in the same update
    /// meets it (the two fought, a step at each frame of the ease).
    @State private var overscrollEaseUntil = Date.distantPast
    /// How much of the scroll view the keyboard covers (beyond the home-indicator safe area). The
    /// thread moves up with the keyboard and, when it was at the bottom, stays there.
    @State private var keyboardInset: CGFloat = 0
    /// Reasoning disclosures that are open, keyed by item id — kept here so a re-rendered row
    /// does not forget it (the earlier "can't collapse again" bug).
    @State private var openReasoning: Set<String> = []
    /// The rows' actions, one object for the view's life (see `RowContext`).
    @State private var actions = RowActions()
    /// The rows as last built (see `rows`).
    @State private var rowCache = RowCache()
    @State private var selectText: SelectTextItem?
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
    /// How wide a bubble may grow: no limit on the phone (the window is the limit), about
    /// two thirds of the reading column on a wide layout (the Mac, iPad, the open Duo), like
    /// Messages.
    private var bubbleCap: CGFloat {
        wide ? (wideReplies ? columnWidth : max(320, columnWidth * 0.72)) : .infinity
    }

    private var visibleItems: [TranscriptItem] {
        chat.items.filter { item in
            switch item.kind {
            case .tool(let act): return showToolCalls && (!currentStepOnly || act.status == .running)
            case .subagent: return showToolCalls
            case .system: return showSystemNotes
            // A step that only thought is its Reasoning card and nothing else: with reasoning off
            // (or only the current step's), no row and no gap.
            case .assistant where item.isThinkingOnly: return showReasoning && !currentStepOnly
            default: return true
            }
        }
    }
    static func isStreaming(_ item: TranscriptItem) -> Bool {
        if case .assistant(_, _, let streaming) = item.kind { return streaming }
        return false
    }

    /// The thread's rows, built again only when the chat's items, the settings that pick them or the day change
    /// (#439). The view is evaluated far more often than that (the thread scrolling, the status line, a card
    /// toggled), and each build walked the whole thread: an old chat of a few thousand rows spent most of its main
    /// thread there. A streaming reply changes the items at every token, so while one streams the rows are built at
    /// every pass, as before.
    private var rows: [TranscriptRowModel] {
        // Read on a hit too: the view is told when the items change.
        _ = chat.items
        let day = Calendar.current.startOfDay(for: Date())
        let key = RowCache.Key(chat: ObjectIdentifier(chat), items: chat.itemsRevision, showToolCalls: showToolCalls,
                               currentStepOnly: currentStepOnly, showSystemNotes: showSystemNotes,
                               showReasoning: showReasoning, day: day)
        return rowCache.rows(for: key) { TranscriptRowModel.build(visibleItems, now: day) }
    }
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
                    // Not while the history is still on its way: a reopened chat showed "Say
                    // something" for a few frames before its rows landed (Matt, 2026-10-11).
                    if chat.items.isEmpty, chat.resumeError == nil, !chat.isResuming {
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
                            // The words beside it say what's under way; on its own the spinner was an element with no
                            // name and a 14-point hit area to the audit.
                            ProgressView().controlSize(.small).accessibilityHidden(true)
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
                // A reopened chat whose history is still on its way shows nothing, then the rows
                // land as one (the fade is the only animation of the stack, see below). Its history
                // landing under the rows it opened with, nothing either until it is at its end (#449).
                .opacity((chat.isResuming && chat.items.isEmpty) || landingOutOfSight || historyArriving ? 0 : 1)
                .animation(.easeOut(duration: 0.25), value: chat.items.isEmpty)
                // A reading column in the middle of the pane on a wide layout, a page wide however
                // wide the window is; the full width on the phone.
                .frame(maxWidth: wide ? ChatStyle.readingColumn : .infinity)
                .onGeometryChange(for: CGFloat.self) { ($0.size.width / 20).rounded() * 20 } action: { columnWidth = $0 }
                .frame(maxWidth: .infinity)
                #if os(macOS)
                .modifier(ThreadHitGate.Gate(gate: hitGate))
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
                .background(ScrollViewProbe(metrics: metrics, dockTop: dockTop, headerBottom: headerBottom))
                }
            }
            .scrollPosition($scrollPosition)
            // `bottomInset` is the dock's measured reach into the thread, keyboard included; the
            // scroll view adds its own safe-area inset under that.
            .contentMargins(.bottom, bottomInset + 8, for: .scrollContent)
            .modifier(ThreadTopEdge(inset: effectiveTopInset + bandFade + 8))
            // The keyboard is handled by hand (below) so the last message rides up with it instead
            // of vanishing under the composer; SwiftUI's own avoidance would then double the inset.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            #if DEBUG
            .modifier(ThreadGeometryWatch(chat: chat, metrics: metrics, position: String(describing: scrollPosition),
                                          hidden: (chat.isResuming && chat.items.isEmpty) || landingOutOfSight))
            #endif
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.bottom } action: { _, v in
                metrics.reportedInsetBottom = v
                guard autoInsetFixed == nil, dockTop > 0 else { return }
                #if os(iOS)
                let raw = max(0, v - (bottomInset + 8))
                let safe = windowGeometry.safeArea.bottom
                autoInsetFixed = safe > 0 && raw > safe / 2 ? safe : 0
                #else
                autoInsetFixed = 0   // no home indicator under a window
                #endif
            }
            // The window around the thread (`WindowGeometry`): its own frame in window space, the
            // window's shape (a fold, a resize or an inset that moves makes the automatic inset
            // measure again), and the keyboard as the window has it (in window space, only when
            // it sits on the window's bottom edge), the same value the dock moves by.
            .modifier(ThreadWindowWatch(geometry: windowGeometry,
                                        frame: { scrollTop = $0.minY; scrollBottom = $0.maxY },
                                        shapeChanged: { autoInsetFixed = nil },
                                        keyboard: { keyboardMoved(to: $0) }))
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.y, $0.contentInsets.top] } action: { _, new in
                metrics.offsetY = new[0]; metrics.insetTop = new[1]
            }
            // Your own message brings the thread to the end, as in Messages, however far up it
            // was scrolled: a tester sent one from up the thread, saw nothing happen, and had to
            // find the arrow to see the reply.
            .onReceive(NotificationCenter.default.publisher(for: .hermesMessageSent)) { n in
                guard (n.object as? ChatSession) === chat, !metrics.stickToBottom || metrics.distanceFromBottom > 24 else { return }
                jumpToBottom()
            }
            // The thread's height, its window's and its distance from the end, from one reading of the scroll geometry,
            // all written before anything is decided from them (#453, #452). Read by two handlers, each told of a change in
            // its own turn, the height missed the last change of a burst while the distance had it: under load it held
            // 20,091 pt with the scroll view at 20,030, and in a Bot Chat it stayed 69 pt off for good, so a thread still
            // being measured read as still and was shown, and one at rest read as not landed.
            // Insets included in the distance: the bottom margin (dock plus home indicator) is about the size of
            // the threshold, so without it a slightly taller dock showed the arrow at the very end.
            .onScrollGeometryChange(for: ThreadGeometry.self) { g in
                ThreadGeometry(height: g.contentSize.height, container: g.containerSize.height,
                               distance: g.contentSize.height + g.contentInsets.bottom - g.visibleRect.maxY)
            } action: { old, now in
                metrics.contentHeight = now.height; metrics.containerHeight = now.container
                metrics.distanceFromBottom = now.distance
                // Out of sight while a history lands: the lazy stack is still measuring its rows, so the quiet time
                // before the thread is shown starts again (#449).
                if landingOutOfSight, old.height != now.height { landingReveal?.cancel(); landingReveal = nil }
                if landingOutOfSight { revealIfLanded() }
                // The rest follows the distance alone, as it did: nothing to do when only the height moved under a
                // thread that kept its place.
                let was = old.distance, distance = now.distance
                guard distance != was else { return }
                // Past the end with no finger on it, by any amount: a scroll-to-bottom that used the
                // lazy stack's estimated height lands beyond the real content and the thread shows
                // nothing until a drag bounces it back ("chats open blank until you scroll"), and
                // content that shrinks under a thread at rest (a chat's stored rows landing shorter
                // than its first layout) leaves an empty band over the composer that the first
                // touch snapped away (Matt on 1.5 (21): "a weird jump"). Land it. The scroll that
                // followed every change of the last row hid the small ones until it went with the
                // per-token scroll.
                if distance < -1, !metrics.userScrolling { landPastTheEnd(distance) }
                let away = distance > 120 && !metrics.probing
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
                #if os(macOS)
                if hitGate.scrolling != touching { hitGate.scrolling = touching }
                #endif
                // Shared with the lists: idle faces hold their blink while the thread moves.
                BotAmbient.shared.scrolling = touching
                if !touching, metrics.distanceFromBottom < 4 { metrics.stickToBottom = true }
            }
            // The working bot: one spot at the bottom-left of the thread for the whole turn, in
            // the same pose as the bot on the header pill, gone once the turn ends. It used to sit
            // beside whichever row was live and hopped between them as the turn went on.
            .overlay(alignment: .bottomLeading) {
                ZStack {
                    if showBots, chat.isRunning {
                        // Plain while the reply writes (the thread's own typing bubble says so, decision A).
                        BotAvatar(profile: chat.profileName, size: 28, active: true, mood: BotFaceView.Mood(session: chat.storedID, state: chat.botState == .streaming ? .working : chat.botState))
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
            #if DEBUG
            .overlay(alignment: .topLeading) {
                if PieceProbe.shared.on {
                    Text(PieceProbe.shared.summary).font(.system(size: 8)).padding(.top, 140).accessibilityIdentifier("debug.pieces")
                }
            }
            #endif
            .overlay(alignment: .bottomTrailing) {
                JumpToBottomButton(visible: awayFromBottom) { jumpToBottom() }
                .padding(.trailing, 16).padding(.bottom, dockReach + 12)
            }
            .sheet(item: $selectText) { SelectTextSheet(title: $0.title, text: $0.text, monospaced: $0.monospaced).sheetFrame(.wide).withAppModel() }
            .sheet(isPresented: $showModelSheet) { ModelSheet(chat: chat).sheetFrame().withAppModel() }
            .sheet(isPresented: $showAwayGrace) { AwayGraceSheet(runtime: chat.runtime).sheetFrame(.compact).withAppModel() }
            #if os(iOS)
            // Under the status bar, behind the floating header. The Mac's toolbar is not a place to run under.
            .ignoresSafeArea(.container, edges: .top)
            #endif
            .scrollDismissesKeyboard(.interactively)
            // Starts at the end and follows it. While a card opens or closes, size changes anchor at the top instead,
            // so the tapped card stays where it is and the rows below glide (#437).
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .defaultScrollAnchor(holdingCard ? .top : .bottom, for: .sizeChanges)
            // Streaming text, and the tokens/sec footer landing after it, follow by the anchor for
            // size changes (`.defaultScrollAnchor(.bottom)` above), with no scroll asked per token:
            // that write ran the transcript's body a second time on every token. A new message
            // fades in where it belongs and the thread eases up to it (`followRows`).
            .onChange(of: rows.count) { old, new in historyLanding(from: old, to: new); followRows(from: old, to: new) }
            // Again when the turn ends: rows cross into the lazy stack between turns only.
            .task(id: [rows.count, chat.isRunning ? 1 : 0]) { await settleTail() }
            .onAppear {
                openedAt = Date(); refreshMentionNames()
                // A chat opening with its history still to come and only a few rows (or none) to show meanwhile waits out
                // of sight until the history has landed and the thread is at its end (#449, see `historyLanding`); a
                // history slow to come (1.5 s), the rows it has are shown meanwhile, and its landing hides it again.
                metrics.shownItems = chat.items.count; metrics.landings = 0; metrics.probed = false
                if chat.isResuming, rows.count < 20 { landingOutOfSight = true; capLanding(after: 1500) }
            }
            .onChange(of: chat.isResuming) { _, now in
                guard !now, landingOutOfSight else { return }
                capLanding()
                revealIfLanded()
            }
            // The thread's place after a layout switch rebuilt it: the distance from the end it
            // had (`ChatViewMemory`), put back once the content is laid out; at the end, nothing.
            .onDisappear { ChatViewMemory.setDistanceFromEnd(metrics.stickToBottom || metrics.distanceFromBottom < 24 ? nil : metrics.distanceFromBottom, for: chat) }
            .task { await restoreDistanceFromEnd() }
            // The names "@" can mean: the gateway's bots (name and label) and the person's own.
            .onChange(of: chat.runtime.profiles.map(\.name)) { _, _ in refreshMentionNames() }
            // Once the history is in and laid out, make sure the end is really on screen.
            .task(id: chat.isResuming) { await landAfterResume() }
            .onChange(of: chat.statusLine) { _, _ in
                if mayFollowNow() { withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) } }
            }
            // The turn ending takes the typing bubble and status line out from under the last
            // reply; a locked thread follows so no blank band is left there.
            .onChange(of: chat.isRunning) { _, running in
                if !running, collapseAfterTurn { withAnimation(.snappy) { openReasoning = []; openTools = [] } }
                if mayFollowNow() { withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) } }
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
                    if holdingCard { followAfterHold = true; return }
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
            OlderRows(rows: rowCache.older(than: split), context: ctx.forOlderRows(tail: all[split...])).equatable()
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
        actions.onSelectText = { selectText = SelectTextItem(text: $0) }
        actions.onShowAll = { title, text in selectText = SelectTextItem(title: title, text: text, monospaced: title.hasPrefix("Code")) }
        // Called inside the card's own animation: the hold and the change land in one update (`holdCard`).
        actions.setReasoningOpen = { id, on in holdCard(opening: on); if on { openReasoning.insert(id) } else { openReasoning.remove(id) } }
        actions.setToolOpen = { id, on in holdCard(opening: on); if on { openTools.insert(id) } else { openTools.remove(id) } }
        return RowContext(profile: showBots ? chat.profileName : nil, bot: chat.profileName,
                          botLabel: chat.runtime.profiles.first { $0.name == chat.profileName }?.label ?? chat.profileName, typingTool: typingTool, showReasoning: showReasoning, currentStepOnly: currentStepOnly,
                          showStats: showTurnStats, interruptCause: chat.interruptCause, lastID: chat.items.last?.id,
                          resendableID: chat.runtime.undoUnsupported ? nil : chat.lastResendableID,
                          openReasoning: openReasoning, openTools: openTools, showToolOutput: showToolOutput, compactTools: compactTools,
                          wide: wideReplies, maxBubble: bubbleCap, actions: actions)
    }

    /// A card opening or closing keeps its place: for the length of the toggle's animation the thread's size changes
    /// anchor at its top, so the tapped card's top does not move and the rows below it glide; and since that anchor holds
    /// the thread's top, not the card, the card's own top is kept as well (`CardHold`): rows above it measured in the same
    /// pass (the lazy stack's estimate for rows not yet measured, as soon after an open) moved it by their correction, 175
    /// to 251 pt under load and once 1,310 pt (#473). Anchored at the end, a
    /// card that grew pushed itself up and was pulled back a frame later, and one near the bottom was scrolled into view
    /// after it opened, a second motion (#437). A close with the thread at its very end keeps the end anchored: the
    /// thread is shorter after it, so the rows above come down, in the same animation as the close.
    /// Once the hold ends, a thread still locked to its end follows a running turn again, eased as `followRows` does
    /// (rows that arrived meanwhile were held back): a card toggled near the end while a turn streams does not stop the
    /// thread following it. With no turn running, nothing moves after the toggle.
    private func holdCard(opening: Bool) {
        guard opening || metrics.distanceFromBottom >= 4 else { CardHold.shared.end(); return }
        cardHold += 1
        let hold = cardHold
        holdingCard = true
        // The tapped card's own place, kept against any change above it (`CardHold`): moved by n pt, the thread goes to
        // the offset that puts it back, from the offset of the same pass, so a move reported again before the scroll has
        // landed asks for the same place, once. At once, unanimated: it lands in the run-loop turn of the move, so the
        // moved layout is never drawn. Asked in the toggle's animation instead, the scroll itself was drawn as a slide
        // (near the end, frames' similarity 0.66 over a second against 1.00), and could be dropped altogether. A finger on
        // the thread ends it.
        // An ask that has not moved the thread at all two frames on is asked again (a scroll can be dropped: the card once
        // stayed 330 pt low, below the dock). Until then a repeat of the same place is not asked twice.
        var asked: CGFloat?
        CardHold.shared.begin { delta in
            guard !metrics.userScrolling else { CardHold.shared.end(); return }
            let target = metrics.offsetY + delta
            if let asked, abs(asked - target) < 1 { return }
            asked = target
            let from = metrics.offsetY
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { scrollPosition.scrollTo(y: max(0, target + metrics.insetTop)) }
            Task { @MainActor in
                for _ in 0..<2 { await FrameClock.next() }
                guard CardHold.shared.holding, let pending = asked, abs(pending - target) < 1,
                      abs(metrics.offsetY - from) < 1, abs(metrics.offsetY - target) >= 1 else { return }
                withTransaction(still) { scrollPosition.scrollTo(y: max(0, target + metrics.insetTop)) }
            }
        }
        #if DEBUG
        CardMotionProbe.holding = true
        #endif
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard cardHold == hold else { return }
            holdingCard = false
            CardHold.shared.end()
            // Past its end at the hold's end (rows above measured shorter while the card was held): landed now, as it
            // would have been meanwhile.
            if metrics.distanceFromBottom < -1, !metrics.userScrolling { landPastTheEnd(metrics.distanceFromBottom) }
            #if DEBUG
            CardMotionProbe.holding = false
            #endif
            // A turn running under a thread locked to its end goes on being followed (eased, as `followRows` does); with
            // no turn running the thread stays where the card left it.
            let follow = followAfterHold || chat.isRunning
            followAfterHold = false
            if follow, mayFollow(), metrics.distanceFromBottom > 4 { withAnimation(.easeOut(duration: 0.28)) { scrollPosition.scrollTo(edge: .bottom) } }
        }
    }

    /// Puts the thread back where it was before a layout switch (see `ChatViewMemory`).
    private func restoreDistanceFromEnd() async {
        guard let d = ChatViewMemory.distanceFromEnd[ChatViewMemory.key(for: chat)], d > 24 else { return }
        ChatViewMemory.setDistanceFromEnd(nil, for: chat)
        // The content is laid out and the default anchor has it at the end.
        for _ in 0..<40 {
            if metrics.contentHeight > metrics.containerHeight, metrics.offsetY > 0 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard metrics.contentHeight > metrics.containerHeight else { return }
        metrics.stickToBottom = false
        scrollPosition.scrollTo(y: max(0, metrics.offsetY - d))
    }

    private func landAfterResume() async {
        guard !chat.isResuming else { return }
        for delay in [300, 900] {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, metrics.stickToBottom, !metrics.userScrolling else { return }
            // Eased, not snapped: a tap that moved a little on its way in nudged the thread,
            // and the two snaps back read as a jump (Matt, 2026-10-12, "opening a chat and
            // moving my finger a bit").
            if metrics.distanceFromBottom < -8 || metrics.distanceFromBottom > 8 { withAnimation(.easeOut(duration: 0.25)) { scrollPosition.scrollTo(edge: .bottom) } }
        }
    }

    private func refreshMentionNames() {
        // Every name a bot answers to: its folder name, the gateway's display name and the one
        // given in Vory (#315), without repeats.
        let bots = Mentions.botNames(for: chat.runtime.profiles)
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
        // Not while the chat's history is coming in: the rows arriving under a thread that was
        // still at the top of the first ones read as a reader up the thread, with no finger on
        // it, and the end it was locked to was lost (1.5 (23), the open's blank).
        if metrics.distanceFromBottom > reach { if !chat.isResuming { metrics.stickToBottom = false }; return false }
        return true
    }

    /// `mayFollow`, and no card holding its place (`holdCard`): the thread follows once the hold is over. Every follow of
    /// the end a turn sets off goes through here (rows, the status line, the turn's end, the dock), so a card toggled
    /// while a turn streams stays where it is: the status line's follow at each tool step scrolled it away (#437).
    private func mayFollowNow() -> Bool {
        guard mayFollow() else { return false }
        if holdingCard { followAfterHold = true; return false }
        return true
    }

    /// A row came or went under a locked thread: the thread eases to its end with it.
    /// The keyboard now covers `inset` of the window above the bottom safe area (`WindowGeometry`).
    /// The keyboard moves on UIKit's own spring; this spring tracks it closely, so the thread and
    /// the composer arrive together instead of the composer overlapping.
    private func keyboardMoved(to inset: CGFloat) {
        // Only a move: the window's geometry reports the inset as a chat opens too, with no
        // keyboard, and stamped as one it held off the open's own landing (1.5 (23): a chat at
        // rest went a screen past its end, blank, a moment after it opened).
        if inset != keyboardInset { keyboardMovedAt = Date() }
        withAnimation(.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)) {
            keyboardInset = inset
            if metrics.stickToBottom { scrollPosition.scrollTo(edge: .bottom) }
        }
        floorTask?.cancel()
        if inset == 0 || !keyboardFloors { keyboardFloor = 0 } else {
            floorTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                keyboardFloor = inset
                if metrics.stickToBottom, !metrics.userScrolling { scrollPosition.scrollTo(edge: .bottom) }
            }
        }
    }

    /// A chat's history landing under the few rows it opened with (#449): the thread goes out of sight at once, until it is
    /// at its end. Landing, it was thrown to the top of its content for a few frames when it had opened shorter than the
    /// screen and the push's top inset changed meanwhile (a Bot Chat, about half its opens), or a few screens up and back
    /// as the lazy stack measured its rows (a long chat); the landing that followed was the way back. Not a turn's rows
    /// (only while the chat resumes) and not a few (20 or more).
    ///
    /// A chat that opened with only a few rows is out of sight from the start (`onAppear`): the history then lands unseen.
    /// Opened with more (rows kept from before), the landing itself puts it out of sight, the same update or the next.
    private func historyLanding(from old: Int, to new: Int) {
        guard chat.isResuming, new - old >= 20 else { return }
        // Landings count from the history's coming, out of sight already (opened with few rows) or not, and its rows are
        // measured once before it is shown (`probeMeasuring`).
        metrics.landings = 0; metrics.probed = false
        guard !landingOutOfSight else { return }
        landingOutOfSight = true
        landingReveal?.cancel(); landingReveal = nil
        capLanding()
    }

    /// Out of sight 700 ms at most from the history's end (resuming over) or its landing; 1.5 s from opening while it is
    /// still to come.
    private func capLanding(after ms: Int = 700) {
        landingCap?.cancel()
        landingCap = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(ms))
            guard !Task.isCancelled, landingOutOfSight else { return }
            reveal("cap")
        }
    }

    /// How far a landing's layout may still move the thread's height for the landing to count as stuck (#453).
    static let settledStep: CGFloat = 12
    /// The measuring scroll's rounds at most, out of sight before a long history is shown (#468, `probeMeasuring`).
    static let probeRounds = 4

    /// At its end, or, the history in, shorter than the screen, and still so two frames later with its content's height
    /// unchanged meanwhile (a change starts the wait again, from the geometry handler, and from here): the thread is
    /// shown, faded in. The throw to the top came in the same layout as a first frame at the end, and the lazy stack
    /// measuring the rows that had just come left a thread shown at its end 556 pt past it a moment later (#449).
    ///
    /// If the thread had to be landed past its end meanwhile, the landing must also have stuck: the layout after it moved
    /// the height by less than `settledStep` (#453). Under load the lazy stack measures in bursts, each set off by the
    /// landing before it (rows newly in the window measure shorter, the end moves up, the thread is landed again), and the
    /// bursts came 30 to 230 ms apart, so two quiet frames fell between two of them and the thread was shown 81 to 99 pt
    /// from where it would settle, still moving. Bursts shrink as they go (209, 226, 127, 61, 35, 23, 19, 9 pt): the
    /// thread is shown once one is under a line, or at the cap.
    ///
    /// The wait is in frames, not milliseconds (#453): under load the lazy stack's reports of its height came farther
    /// apart than the 80 ms the wait used to be, while the height was still falling, so the quiet read as settled and the
    /// thread was shown 99 to 185 pt past its end, its correction in sight. A frame comes as often as the app gets to draw,
    /// so two of them stretch with the load; with none, they are 17 to 33 ms. Only SwiftUI's own report counts, read with
    /// the distance in one reading (the geometry handler): a check against the UIKit scroll view refused every frame where
    /// a separate height handler had missed the last change (69 pt in a Bot Chat), and left the thread to its cap.
    private func revealIfLanded() {
        guard !metrics.probing else { return }
        if landedAtEnd() {
            guard landingReveal == nil else { return }
            landingReveal = Task { @MainActor in
                let height = metrics.contentHeight
                for _ in 0..<2 {
                    await FrameClock.next()
                    guard !Task.isCancelled else { return }
                }
                guard metrics.contentHeight == height, landedAtEnd() else {
                    landingReveal = nil
                    revealIfLanded()
                    return
                }
                // A history taller than two screens is measured before it is shown (#468): see `probeMeasuring`.
                if !metrics.probed, metrics.contentHeight > metrics.containerHeight * 2 {
                    metrics.probed = true
                    landingReveal = nil
                    probeMeasuring()
                    return
                }
                // Landed past its end since the history came: shown once the layout after the last landing has moved the
                // height by less than a line; more, and this height is the one the next quiet frames must hold.
                if metrics.landings > 0, abs(height - metrics.landedHeight) >= Self.settledStep {
                    metrics.landedHeight = height
                    landingReveal = nil
                    revealIfLanded()
                    return
                }
                reveal(metrics.landings > 0 ? "landing" : "frames")
            }
        } else {
            landingReveal?.cancel(); landingReveal = nil
        }
    }

    /// A history arriving under the rows the thread was shown with (#449, #453): out of sight in the update that brings
    /// it, not the next. `historyLanding` puts the thread out of sight from the rows' count, an update later, and a thread
    /// shown with its few stored rows flashed 15,703 pt past its end for 15 ms as its history landed. Counted in items,
    /// which the rows are made from, as `rows` is built afresh on every read.
    private var historyArriving: Bool { chat.isResuming && chat.items.count >= metrics.shownItems + 20 }

    /// At its end, or, the history in, shorter than the screen.
    private func landedAtEnd() -> Bool {
        let short = !chat.isResuming && metrics.contentHeight <= metrics.containerHeight + 1
        return short || abs(metrics.distanceFromBottom) < 10
    }

    private func reveal(_ why: String = "now") {
        landingCap?.cancel(); landingReveal?.cancel(); landingReveal = nil
        // The cap during a probe: back at the end first, so the thread is never shown a screen up its history.
        if metrics.probing {
            metrics.probeTask?.cancel(); metrics.probeTask = nil; metrics.probing = false
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { scrollPosition.scrollTo(edge: .bottom) }
        }
        #if DEBUG
        if ThreadGeometryWatch.log { Perf.stamp("SHOWN \(chat.title) by \(why)") }
        #endif
        metrics.shownItems = chat.items.count
        withAnimation(.easeOut(duration: 0.15)) { landingOutOfSight = false }
    }

    private func followRows(from old: Int, to new: Int) {
        guard mayFollowNow() else { return }
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
        guard !Task.isCancelled else { return }
        let count = rows.count
        let wanted = TranscriptRowModel.tailStart(count)
        // Not set yet while a turn runs: set where the rows already split, wherever the reader
        // is (nothing moves), so the rest of the turn holds its rows out of the lazy stack.
        // Unset, the boundary followed every block of new rows, a reader up the thread or not.
        if tailFrom == nil, chat.isRunning, count > 0 { tailFrom = wanted; return }
        guard metrics.stickToBottom, !metrics.userScrolling, tailFrom != wanted else { return }
        let moves = TranscriptRowModel.split(count: count, tailFrom: tailFrom) != wanted
        if moves, chat.isRunning { return }
        tailFrom = wanted
        if moves { scrollPosition.scrollTo(edge: .bottom) }
    }

    /// The thread came to rest past its end with no finger on it (not tracking, dragging or
    /// decelerating). Locked to the end, or by a small overshoot (rows that landed shorter, a
    /// status row gone), it is landed in the same update, so the last row stays where it was
    /// against the dock with no frame of gap or of blank; a large one with the thread not
    /// following after a moment, once its rows have laid out, eased; either waits while the
    /// keyboard's spring is carrying the thread, and none meets an eased landing under way.
    private func landPastTheEnd(_ distance: CGFloat) {
        guard Date() > overscrollEaseUntil, !CardHold.shared.holding else { return }
        // Locked, any size, once there is more thread than screen (a chat still empty or shorter
        // than the screen reads as past its end until its rows come, and is no landing).
        let locked = metrics.stickToBottom && metrics.contentHeight > metrics.containerHeight
        guard distance >= -60 || locked, Date().timeIntervalSince(keyboardMovedAt) > 0.6 else { scheduleOverscrollFix(); return }
        Perf.tick("overscrollLand")
        noteLanding()
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { scrollPosition.scrollTo(edge: .bottom) }
    }

    /// The lazy stack measures its rows only as a scroll brings them near, and until then a long history's height is its
    /// estimate (40,494 pt for a chat that settles at 19,282). Shown at its end over that, nothing moves while it rests (the
    /// anchor holds the end), but the first scroll measures it: in a pull past the end the scroll view kept its offset while
    /// the content shrank under the finger, 4,404 pt past the end in sight, then snapped back in a frame (#468; Matt's
    /// "stutters instead of rubber-banding" right after opening). So out of sight, at its end and quiet, the thread is
    /// scrolled up and, a frame later, landed back at its end, in rounds. The lazy stack measures a step with each scroll
    /// that moves the view, and the scroll's layout runs in its own turn, so the next frame has it. One round took a long
    /// chat from 40,494 to 22,940 pt and stopped there (the end clamped back, so the landing stuck on a height still 3,600
    /// pt off, and the first pull measured the rest in sight), so the rounds go on, each two screens deeper than the last,
    /// until one from the second on moves the height by less than a line, at most `probeRounds`. Two frames a round: rounds
    /// of two frames each way had a loaded open shown at 1,025 to 1,140 ms against 606 to 709 without them. Then the
    /// landing waits for one that sticks (`revealIfLanded`). Unanimated and out of sight, with no finger, so no arrow,
    /// haptic or lock changes; the cap meanwhile lands it first (`reveal`).
    private func probeMeasuring() {
        guard landingOutOfSight, !metrics.probing else { return }
        metrics.probing = true
        metrics.probeTask = Task { @MainActor in
            var still = Transaction()
            still.disablesAnimations = true
            for round in 1...Self.probeRounds {
                let before = metrics.contentHeight
                withTransaction(still) { scrollPosition.scrollTo(y: max(0, metrics.offsetY + metrics.insetTop - metrics.containerHeight * CGFloat(2 * round))) }
                await FrameClock.next()
                guard !Task.isCancelled else { return }
                withTransaction(still) { scrollPosition.scrollTo(edge: .bottom) }
                await FrameClock.next()
                guard !Task.isCancelled else { return }
                // Never on the first round: the thread's end is its tail (rows never lazy, always measured), which can be
                // taller than a screen, and a round inside it measures nothing new and reads as settled (a long chat
                // shown at 21,088 pt that way had the rest measured by the first pull's bounce, 1,770 pt past the end).
                if round > 1, abs(metrics.contentHeight - before) < Self.settledStep { break }
            }
            metrics.probing = false; metrics.probeTask = nil
            guard landingOutOfSight else { return }
            noteLanding()
            withTransaction(still) { scrollPosition.scrollTo(edge: .bottom) }
            revealIfLanded()
        }
    }

    /// A landing past the end while the thread is out of sight: the reveal waits for one that sticks (`revealIfLanded`).
    private func noteLanding() {
        guard landingOutOfSight else { return }
        metrics.landings += 1
        metrics.landedHeight = metrics.contentHeight
    }

    private func scheduleOverscrollFix() {
        guard overscrollTask == nil else { return }
        overscrollTask = Task { @MainActor in
            defer { overscrollTask = nil }
            // Past the keyboard's spring too (up to a second and a half), rechecked each time.
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, !metrics.userScrolling, metrics.distanceFromBottom < -1 else { return }
                if Date().timeIntervalSince(keyboardMovedAt) > 0.6 { break }
            }
            guard !Task.isCancelled, !metrics.userScrolling, metrics.distanceFromBottom < -1, !CardHold.shared.holding else { return }
            Perf.tick("overscrollFix")
            noteLanding()
            // Eased, so it reads as the thread settling rather than a jump of its own; from more
            // than a screen past (a thread showing nothing) at once, as an animated scroll through
            // rows still being laid out glitched them (`jumpToBottom`).
            if -metrics.distanceFromBottom < metrics.containerHeight {
                overscrollEaseUntil = Date().addingTimeInterval(0.25)
                withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) }
            } else {
                scrollPosition.scrollTo(edge: .bottom)
            }
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
    var onEdit: (String, String?) -> Void = { _, _ in }
    var onOpenBot: (String) -> Void = { _ in }
    var onReply: (String) -> Void = { _ in }
    var onChooseModel: () -> Void = {}
    var onKeepRunning: () -> Void = {}
    var onSelectText: (String) -> Void = { _ in }
    /// The whole of a text a fold shows only the start of, on the Select Text sheet under a title (#361).
    var onShowAll: (_ title: String, _ text: String) -> Void = { _, _ in }
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
    /// The chat's bot as the person knows it, for the title of its reasoning's sheet.
    var botLabel: String?
    var typingTool: String?
    var showReasoning: Bool
    var currentStepOnly: Bool
    var showStats: Bool
    var interruptCause: InterruptedTurn.Cause?
    var lastID: String?
    /// The message Edit & resend is offered on (`ChatSession.lastResendableID`, none where the gateway can't take a
    /// message back); every other bubble of the person's own offers Copy to message (#556).
    var resendableID: String?
    var openReasoning: Set<String>
    var openTools: Set<String>
    var showToolOutput: Bool
    var compactTools: Bool
    var wide: Bool
    var maxBubble: CGFloat
    var actions: RowActions

    static func == (a: RowContext, b: RowContext) -> Bool {
        a.actions === b.actions && a.profile == b.profile && a.bot == b.bot && a.botLabel == b.botLabel && a.typingTool == b.typingTool && a.showReasoning == b.showReasoning
            && a.currentStepOnly == b.currentStepOnly && a.showStats == b.showStats && a.interruptCause == b.interruptCause && a.lastID == b.lastID
            && a.resendableID == b.resendableID
            && a.openReasoning == b.openReasoning && a.openTools == b.openTools && a.showToolOutput == b.showToolOutput
            && a.compactTools == b.compactTools && a.wide == b.wide && a.maxBubble == b.maxBubble
    }

    /// The tool name for the typing bubble, given only to the row that draws it: a reply with no words yet, still
    /// streaming. Every row compares what it is given (`TranscriptRow.==`), and the name changes at every tool step of
    /// a turn ("terminal", nothing, "terminal"…), so a row that never draws the bubble gets nil and stays equal: with
    /// the name on every row, each step rebuilt the whole thread (#422, 900 to 1,400 row evaluations a second while a
    /// long turn streamed).
    func bubbleTool(for item: TranscriptItem) -> String? {
        guard case .assistant(let text, _, let streaming) = item.kind, streaming, text.isEmpty else { return nil }
        return typingTool
    }

    /// Why the turn was cut short, for the last row only: the others get nil and stay equal when a new row arrives.
    func interruptCause(for id: String) -> InterruptedTurn.Cause? { id == lastID ? interruptCause : nil }

    /// The context the older, lazy rows are drawn with: what only the thread's last row uses left out (the typing
    /// bubble's tool, which row is last, why a turn was cut short). An older row is never the last one. With them in,
    /// `OlderRows` compared unequal at every tool step and every new row, and every older row the lazy stack had drawn
    /// was rebuilt with it (#422). Nor the open cards of the rows after them (`tail`): a card toggled at the end left the
    /// older rows' context unequal, the lazy stack laid itself out again, and the height of its rows not yet measured
    /// went back to its estimate (a cold open's first toggle: 22,500 pt to the whole history's 41,065, the thread blank
    /// for four seconds; at rest 330 pt taller or 1,072 pt shorter), moving the tapped card by as much (#473).
    func forOlderRows(tail: ArraySlice<TranscriptRowModel>) -> RowContext {
        var c = self
        c.typingTool = nil
        c.lastID = nil
        c.interruptCause = nil
        // The message Edit & resend is on, only when it's one of them: it's usually among the last rows, and the older
        // rows' context then stays equal as a new message comes and goes.
        if let r = resendableID, tail.contains(where: { $0.item.id == r }) { c.resendableID = nil }
        if !openReasoning.isEmpty || !openTools.isEmpty {
            let ids = Set(tail.map(\.item.id))
            c.openReasoning = openReasoning.subtracting(ids)
            c.openTools = openTools.subtracting(ids)
        }
        return c
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
                      typingTool: bubbleTool(for: row.item), resendable: id == resendableID,
                      showReasoning: showReasoning && (!currentStepOnly || TranscriptView.isStreaming(row.item)), showStats: showStats,
                      onEdit: actions.onEdit, onOpenBot: actions.onOpenBot, onReply: actions.onReply, onChooseModel: actions.onChooseModel,
                      interruptCause: interruptCause(for: id), onKeepRunning: actions.onKeepRunning,
                      reasoningOpen: openReasoning.contains(id), setReasoningOpen: { actions.setReasoningOpen(id, $0) },
                      onSelectText: actions.onSelectText,
                      onShowAll: actions.onShowAll, botLabel: botLabel,
                      toolOpen: openTools.contains(id), setToolOpen: { actions.setToolOpen(id, $0) },
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
    var dockTop: CGFloat = 0
    var headerBottom: CGFloat = 0
    var body: some View { Color.clear }
}
#else
/// Finds the UIKit scroll view behind the thread and hands it to the metrics box. It also carries the tap that closes the
/// on-screen keyboard (#350, `ThreadKeyboardTap`), attached to that scroll view while the thread is in a window, with the
/// dock's top and the header's bottom it must leave alone.
private struct ScrollViewProbe: UIViewRepresentable {
    let metrics: ScrollMetrics
    var dockTop: CGFloat = 0
    var headerBottom: CGFloat = 0
    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView(); v.metrics = metrics; v.keyboardTap = context.coordinator; v.isUserInteractionEnabled = false; return v
    }
    func updateUIView(_ v: ProbeView, context: Context) {
        v.metrics = metrics
        context.coordinator.dockTop = dockTop
        context.coordinator.headerBottom = headerBottom
    }
    func makeCoordinator() -> ThreadKeyboardTap { ThreadKeyboardTap() }
    static func dismantleUIView(_ v: ProbeView, coordinator: ThreadKeyboardTap) { coordinator.detach() }
    final class ProbeView: UIView {
        var metrics: ScrollMetrics?
        weak var keyboardTap: ThreadKeyboardTap?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var s = superview
            while let x = s, !(x is UIScrollView) { s = x.superview }
            metrics?.scrollView = s as? UIScrollView
            if window != nil, let sv = s as? UIScrollView { keyboardTap?.attach(to: sv) } else { keyboardTap?.detach() }
        }
    }
}
#endif

#if os(macOS)
/// While the thread scrolls, its rows take no hit tests. AppKit routes every scroll event by a hit test, and SwiftUI
/// answered by walking every row's content shape and every reply's two hover trackers: a third of the main thread
/// during a drag on the Mac (1.5 (23), measured). The scroll view still gets its events; a click or a hover works
/// again the moment the thread stops. Observable on its own so only the gate's modifier reads it, not the thread.
@Observable final class ThreadHitGate {
    var scrolling = false
    struct Gate: ViewModifier {
        let gate: ThreadHitGate
        func body(content: Content) -> some View { content.allowsHitTesting(!gate.scrolling) }
    }
}
#endif

/// The figures a scroll changes every frame. Not observable on purpose (see `TranscriptView.metrics`).
/// The thread's scroll geometry as one reading (#453): its content height, its window's height, and how far its end is
/// below the window's bottom, insets included.
struct ThreadGeometry: Equatable {
    var height: CGFloat
    var container: CGFloat
    var distance: CGFloat
}

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
    /// The scroll view's top inset (the header's room), with `offsetY`: a scroll to an offset goes to `offsetY` plus it,
    /// as `ScrollPosition.scrollTo(y:)` counts from the content's top under the inset, not from the scroll view's edge.
    var insetTop: CGFloat = 0
    /// The thread's landings past its end while out of sight since its history came, and the height at the last one
    /// (#453, `revealIfLanded`).
    var landings = 0
    var landedHeight: CGFloat = 0
    /// The out-of-sight scroll that makes the lazy stack measure a history before it is shown (#468, `probeMeasuring`):
    /// done once per history, under way, and its task.
    var probed = false
    var probing = false
    var probeTask: Task<Void, Never>?
    /// The chat's item count when the thread was last shown (or opened): a history arriving under it hides the thread in
    /// the same update (`historyArriving`).
    var shownItems = 0
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
    /// A send puts the on-screen keyboard away (#350); off by default, so a quick follow-up needs no tap. The demo's
    /// and the tour's chats put it away either way (`ComposerFocusRule`).
    static let closeKeyboardAfterSend = "chat.closeKeyboardAfterSend"
    static let showReasoning = "chat.showReasoning"
    static let showTurnStats = "chat.showTurnStats"
    /// The message bar's context figure as tokens ("18/200K") instead of a percentage.
    static let contextAsTokens = "chat.contextAsTokens"
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
    /// The reading column on a wide layout (the Mac, iPad, the open Duo): thread and composer
    /// share it, centred in the pane.
    static let readingColumn: CGFloat = 860
    /// The soft edge of the header's band on iOS: the page's background fades out over this
    /// much thread below the header. The thread's top margin clears it, so the first row reads
    /// whole, not through the fade. (The dock's band sits below the bar and has no fade above
    /// it: the thread shows through the field's glass.)
    static let bandFade: CGFloat = 28
    /// "small", "default" or "large": one Dynamic Type step down or up for the thread only.
    static let textSize = "chat.textSize"
    /// "tailed" (Messages), "rounded" (no tails) or "plain" (replies without a bubble, like a page).
    static let bubbleStyle = "chat.bubbleStyle"
    /// Reply bubbles take a wash of the bot's own colour instead of grey.
    static let botTint = "chat.botTint"

    /// The hex a reply bubble is washed with, or nil for the plain grey bubble.
    ///
    /// `bot` is the chat's bot, drawn beside the bubble or not (`RowContext.bot`: the same field the
    /// pictures use, and always there), and `scopeHex` the colour a demo's own look gives it
    /// (`BotLookScope`). Never the drawn face: "Bot beside replies" is off by default, and reading the
    /// wash off it made this setting do nothing for most people.
    static func replyTintHex(on: Bool, bot: String?, scopeHex: String?) -> String? {
        guard on, let bot else { return nil }
        return scopeHex ?? BotColors.hex(for: bot)
    }

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

/// The thread's rows as last built and what they were built from (#439). A class, so filling it while the view is
/// evaluated is no change to the view's state.
@MainActor final class RowCache {
    struct Key: Equatable {
        var chat: ObjectIdentifier
        /// The chat's `itemsRevision`.
        var items: Int
        var showToolCalls: Bool
        var currentStepOnly: Bool
        var showSystemNotes: Bool
        var showReasoning: Bool
        /// The day the separators were written on ("Today", "Yesterday", a weekday).
        var day: Date
    }
    private var key: Key?
    private var built: [TranscriptRowModel] = []
    private(set) var builds = 0
    private var olderSplit: Int?
    private var older: [TranscriptRowModel] = []

    func rows(for key: Key, build: () -> [TranscriptRowModel]) -> [TranscriptRowModel] {
        if key != self.key {
            built = build()
            self.key = key
            olderSplit = nil
            builds += 1
        }
        return built
    }

    /// The rows before `split` of those `rows(for:build:)` last returned, as the same array while they and the split
    /// hold: `OlderRows` compared with its last pass is then equal at once (Array's `==` sees its own storage), not
    /// after comparing every row in full.
    func older(than split: Int) -> [TranscriptRowModel] {
        if split != olderSplit {
            older = Array(built[..<split])
            olderSplit = split
        }
        return older
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
        case .assistant: return item.isThinkingOnly ? "reasoning" : "reply"
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
    /// Rows the end keeps when it outgrows `tailCap`: a few screens' worth, so the rows that
    /// cross then are far above the screen.
    static let tailKeep = 48
    /// Where the rows that are not lazy would start if nothing held them, `keep` rows (or up to
    /// a block more) from the end: whole blocks, so the boundary moves once in a block of rows.
    static func tailStart(_ count: Int, keep: Int = tailBlock) -> Int {
        max(0, (count - keep) / tailBlock * tailBlock)
    }
    /// Index of the first row that is not lazy. The thread's own boundary (`tailFrom`) stands
    /// while it leaves a sensible end: a thread that has not set one goes by whole blocks. Past
    /// `tailCap` rows (a turn longer than the end holds, a history that arrived or rows that
    /// piled up while the reader was up the thread) only the rows a few screens up cross: a
    /// coding bot's turn of a hundred rows used to hand all but the last 16 to the lazy stack
    /// mid-turn, which laid the newest rows out from its guessed heights, over a long reply
    /// (#410). The rest cross at rest (`settleTail`).
    static func split(count: Int, tailFrom: Int?) -> Int {
        let wanted = tailStart(count)
        guard let tailFrom, tailFrom <= wanted else { return wanted }
        if count - tailFrom <= tailCap { return tailFrom }
        return max(tailFrom, tailStart(count, keep: tailKeep))
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
        // the last one; a run of the person's messages gets one tail the same way. A step that
        // only thought is no reply: no bot beside its card, and the run goes on past it.
        func passedOver(_ item: TranscriptItem) -> Bool {
            if case .tool = item.kind { return true }
            return item.isThinkingOnly
        }
        for i in out.indices {
            if out[i].item.isThinkingOnly { out[i].lastOfRun = false; continue }
            var next = i + 1
            while next < out.count, passedOver(out[next].item) { next += 1 }
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

struct SelectTextItem: Identifiable {
    var title = "Select Text"
    let text: String
    /// Code and logs read in a fixed-width font.
    var monospaced = false
    var id: String { title + "\u{0}" + text }
}

struct TranscriptRow: View, Equatable {
    static func == (a: TranscriptRow, b: TranscriptRow) -> Bool {
        a.item == b.item && a.profile == b.profile && a.bot == b.bot && a.botLabel == b.botLabel && a.botShown == b.botShown && a.typingTool == b.typingTool
            && a.resendable == b.resendable
            && a.showReasoning == b.showReasoning && a.showStats == b.showStats
            && a.reasoningOpen == b.reasoningOpen && a.toolOpen == b.toolOpen
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
    /// The person's own message that Edit & resend is offered on: the chat's last of theirs (`RowContext.resendableID`).
    /// Their other bubbles offer Copy to message.
    var resendable = false
    var showReasoning = true
    var showStats = true
    var onEdit: (String, String?) -> Void = { _, _ in }
    var onOpenBot: (String) -> Void = { _ in }
    var onReply: (String) -> Void = { _ in }
    var onChooseModel: () -> Void = {}
    /// For a turn the gateway cut short: why, when this device knows, and the way to its setting.
    var interruptCause: InterruptedTurn.Cause? = nil
    var onKeepRunning: () -> Void = {}
    @AppStorage(ChatStyle.bubbleStyle) private var bubbleStyle = "tailed"
    @AppStorage(ChatStyle.botTint) private var botTint = false
    /// The looks of the chat this row is in, where it has its own (`BotLookScope`: the tour's demo over a gateway in use).
    @Environment(\.botLookScope) private var lookScope
    /// The reply bubble's fill: grey, or the bot's colour at a wash. The bot's identity here is the
    /// chat's bot, not the face beside the bubble: with bots hidden a tinted reply is the only sign of
    /// whose words they are, so the setting has to work there too.
    private var replyFill: Color {
        let owner = bot ?? profile
        guard let hex = ChatStyle.replyTintHex(on: botTint, bot: owner, scopeHex: owner.flatMap { lookScope?.color(for: $0) }),
              let color = Color(hex: hex) else { return Color(.systemGray5) }
        return color.opacity(scheme == .dark ? 0.22 : 0.16)
    }
    /// Open states as values with a setter, not Bindings: a Binding made in the parent's body is
    /// a new value every evaluation, and SwiftUI re-ran every visible row for it on each frame
    /// of a keyboard drag ("reasoningOpen, toolOpen changed", 854 times in one run).
    var reasoningOpen = false
    var setReasoningOpen: (Bool) -> Void = { _ in }
    var onSelectText: (String) -> Void = { _ in }
    /// A text's whole on the Select Text sheet under a title, from a fold that shows its start (#361).
    var onShowAll: (_ title: String, _ text: String) -> Void = { _, _ in }
    /// The chat's bot as the person knows it: the reasoning sheet's title.
    var botLabel: String? = nil
    var toolOpen = false
    var setToolOpen: (Bool) -> Void = { _ in }
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
            InjectedNoteRow(note: InjectedNote.parse(text)!, onShowAll: onShowAll)
        case .user(let text, let attachments) where attachments.isEmpty && AgentMessage.parse(text) != nil:
            // Another bot wrote in: a compact notice with the words folded under it, not a
            // bubble of ours.
            let m = AgentMessage.parse(text)!
            BotMessageNotice(handle: m.key, label: m.sender, headline: "Message from \(m.sender)", body: m.body, pending: false, onOpen: onOpenBot, onShowAll: onShowAll)
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
                        let shown = TextPieces.capped(shownText)
                        VStack(alignment: .leading, spacing: 6) {
                            LongText(shown.text)
                            if shown.more > 0 { MoreTextNote(more: shown.more) { onShowAll("Your message", text) } }
                        }
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .foregroundStyle(.white)
                            .bubble(AppTheme.current, side: .trailing, tailed: botShown && bubbleStyle == "tailed") {
                                Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                                Button { onSelectText(text) } label: { Label("Select Text", systemImage: "selection.pin.in.out") }
                                // The last message can be edited and sent in its own place, since only the last turn can be
                                // taken back; any message's words can be copied into a new one (#556).
                                if resendable {
                                    Button { onEdit(text, item.id) } label: { Label("Edit & resend", systemImage: "pencil") }
                                }
                                Button { onEdit(text, nil) } label: { Label("Copy to message", systemImage: "square.and.pencil") }
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
                        if let scope = lookScope, let raw = scope.avatar(for: profile), let hex = scope.color(for: profile) {
                            Image(uiImage: BotAvatarImage.cached(spec: BotAvatarChoice(raw: raw).spec(hex: hex), size: 28, scheme: scheme, closed: false, keep: true))
                                .resizable().frame(width: 28, height: 28)
                        } else {
                            Image(uiImage: BotAvatarImage.cached(profile: profile, size: 28, scheme: scheme))
                                .resizable().frame(width: 28, height: 28)
                        }
                    } else {
                        Color.clear.frame(width: 28, height: 1)
                    }
                }
                if text.isEmpty {
                    // Nothing to read yet: the typing bubble (dark with a badge while a tool
                    // runs), the reasoning above it when there is some, the live count below.
                    // A step that only thought keeps its card here once its tool begins, in the
                    // same place, so an open card stays open (#424); no reply, so no menu.
                    VStack(alignment: .leading, spacing: 6) {
                        if showReasoning, let reasoning, !reasoning.isEmpty {
                            ReasoningDisclosure(text: reasoning, open: Binding(get: { reasoningOpen }, set: setReasoningOpen), onShowAll: { onShowAll("\(botLabel ?? "Bot") · Reasoning", $0) })
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(bubbleStyle == "plain" ? Color.clear : replyFill, in: MessageBubbleShape(side: .leading, tailed: false))
                        }
                        if streaming {
                            TypingBubble(tool: typingTool)
                            if showStats, let s = item.stats {
                                Text(s.label).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).padding(.leading, 6)
                                    .contentTransition(.numericText())
                                    .accessibilityLabel("Turn statistics: \(s.label)")
                            }
                        }
                    }
                    Spacer(minLength: wide ? 0 : 40)
                } else {
                VStack(alignment: .leading, spacing: 6) {
                    if showReasoning, let reasoning, !reasoning.isEmpty { ReasoningDisclosure(text: reasoning, open: Binding(get: { reasoningOpen }, set: setReasoningOpen), onShowAll: { onShowAll("\(botLabel ?? "Bot") · Reasoning", $0) }) }
                    // Pictures the bot sent (MEDIA: lines, markdown images, bare paths) show under
                    // the words as thumbnails fetched through the gateway.
                    let media = TranscriptMedia.images(in: text)
                    // Other files the bot hands back are cards under the words (#309).
                    let files = TranscriptMedia.files(in: text)
                    MarkdownView(text: media.isEmpty && files.isEmpty ? text : MediaScan.textWithoutMedia(text), inlineSelection: false, onShowAll: onShowAll).equatable()
                    if !media.isEmpty { MediaThumbStrip(refs: media, profile: bot) }
                    if !files.isEmpty { FileCardStrip(refs: files, profile: bot) }
                    if showStats, let s = item.stats {
                        Text(s.label).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            .accessibilityLabel("Turn statistics: \(s.label)")
                    }
                }
                .padding(.horizontal, bubbleStyle == "plain" ? 4 : 14).padding(.vertical, bubbleStyle == "plain" ? 4 : 9)
                // On the Mac the whole bubble takes the right-click, padding and gaps too: on the
                // words its selectable text gives its own menu, which has no Copy for the reply (#255).
                .bubble(bubbleStyle == "plain" ? Color.clear : replyFill, side: .leading, tailed: botShown && bubbleStyle == "tailed", wholeOnMac: true) {
                    Button { onReply(text) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    Button { VoiceCoordinator.shared.toggleSpeaking(text) } label: {
                        Label(VoiceCoordinator.shared.isSpeaking(text) ? "Stop Speaking" : "Speak", systemImage: VoiceCoordinator.shared.isSpeaking(text) ? "speaker.slash" : "speaker.wave.2")
                    }
                    #if os(macOS)
                    Button { UIPasteboard.general.string = TranscriptMedia.copyText(text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    // Copy itself copies the markdown (#255); this, the words as they read (#402).
                    Button { UIPasteboard.general.string = TranscriptMedia.copyPlainText(text) } label: { Label("Copy as Plain Text", systemImage: "doc.plaintext") }
                    #else
                    Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                    #endif
                    Button { onSelectText(text) } label: { Label("Select Text", systemImage: "selection.pin.in.out") }
                    ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                #if os(macOS)
                // Copy on hover, beside the bubble's trailing edge (#255, #402); not while it streams.
                .modifier(ReplyCopyHover(text: text, enabled: !streaming, onSelectText: { onSelectText(text) }))
                #endif
                #if os(macOS)
                // The controls' place is the row's trailing margin.
                Spacer(minLength: 0)
                #else
                Spacer(minLength: wide ? 0 : 24)
                #endif
                }
            }
        case .steer(let text, let status):
            HStack {
                Spacer(minLength: 56)
                VStack(alignment: .trailing, spacing: 3) {
                    LongText(text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .bubble(Color(.systemGray4), side: .trailing) {
                            Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                            // A steer isn't a turn the gateway can take back: its words go into a new message.
                            Button { onEdit(text, nil) } label: { Label("Copy to message", systemImage: "square.and.pencil") }
                        }
                    Label(status == "queued" ? "Steered · queued" : "Steered", systemImage: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .tool(let act) where act.delivery != nil:
            // A message to another bot: "Messaging X…", then "Messaged X", then X's answer.
            let d = act.delivery!
            VStack(spacing: 4) {
                BotMessageNotice(handle: d.target, label: d.target, headline: act.status == .running ? "Messaging \(d.target)…" : "Messaged \(d.target)", body: d.message, pending: act.status == .running, onOpen: onOpenBot, onShowAll: onShowAll)
                if let reply = act.deliveryReply {
                    BotMessageNotice(handle: d.target, label: d.target, headline: "Message from \(d.target)", body: reply, pending: false, onOpen: onOpenBot, onShowAll: onShowAll)
                }
            }
        case .tool(let act):
            ToolCardView(activity: act, open: Binding(get: { toolOpen }, set: setToolOpen), showOutput: showToolOutput, compact: compactTools)
        case .system(let text, let symbol) where symbol == "terminal":
            // A slash command's reply: reading size, selectable, with Copy; the terminal mark
            // and a quiet background keep it apart from the bot's words (a tester could neither
            // read nor copy the small grey line it was).
            VStack(alignment: .leading, spacing: 6) {
                Label("Command", systemImage: "terminal").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LongText(text).font(.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).padding(.trailing, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            .overlay(alignment: .topTrailing) { CopyButton(text: text).padding(6) }
        case .system(let text, let symbol):
            HStack(spacing: 6) {
                // The words say it; the icon read its own name ("Info", "Cpu Chip", #409).
                Image(systemName: symbol).accessibilityHidden(true)
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
                LongText(TextPieces.capped(raw).text, code: true).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
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
        .voryGlassEffect(.regular, in: .rect(cornerRadius: 12))
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
    /// The whole output on the Select Text sheet, under the note's title, when the note shows only its start.
    var onShowAll: ((_ title: String, _ text: String) -> Void)? = nil
    @State private var open = false
    /// The pill's own width and the row's: the glass animates between the two. The row's is the width the list
    /// offers the note, measured on an empty view the row places at that width (`OfferedWidthRow`), never on the
    /// note or on anything the note can widen: a note that came out wider than its row once kept that width as the
    /// width to lay its details out at, and the whole chat stayed wider than the screen (#433, #440).
    @State private var pillWidth: CGFloat = 0
    @State private var rowWidth: CGFloat = 0
    var body: some View {
        // One piece of glass that grows out from its centre both ways and folds back the same
        // way. The title never moves: it stays centred, and the details are laid out at the
        // row's full width underneath from the start, so the widening glass reveals them
        // (Matt, 2026-10-11: "stay centered and it expands on both sides to reveal the text").
        let open = open
        let title = HStack(spacing: 6) {
            Image(systemName: note.title.contains("failed") ? "exclamationmark.circle" : note.title.hasPrefix("Scheduled") ? "clock" : note.title.hasPrefix("Subagent") ? "person.2" : "gearshape.2")
            Text(note.title).font(.caption)
            Image(systemName: "chevron.down").font(.caption2.weight(.bold)).rotationEffect(.degrees(open ? 180 : 0))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        // Its own width, wrapping only where the row is narrower than the title (the largest text sizes).
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pillWidth = $0 }
        // The offered width, from a view with nothing in it that the row places at exactly that width (`OfferedWidthRow`),
        // whatever the note's own size (a background would get the note's).
        OfferedWidthRow {
            Color.clear.frame(height: 0).frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                Button { withAnimation(.snappy(duration: 0.32)) { self.open.toggle() } } label: { title.contentShape(.rect) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(note.title). \(open ? "Hides" : "Shows") the details")
                // A background process's output can run to megabytes: its start, in pieces (#361).
                let body = TextPieces.capped(note.body)
                VStack(alignment: .leading, spacing: 4) {
                    LongText(body.text, code: true).font(.caption.monospaced()).textSelection(.enabled)
                    if body.more > 0 { MoreTextNote(more: body.more, action: onShowAll.map { f in { f(note.title, note.body) } }) }
                }
                    .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 10)
                    .frame(width: rowWidth > 0 ? rowWidth : nil, alignment: .leading)
                    // Revealed by the glass, not faded or moved: it is already in place.
                    .folded(open: open, keep: body.text.utf8.count <= 6_000, fade: false)
            }
            .frame(width: rowWidth > 0 && pillWidth > 0 ? (open ? rowWidth : min(pillWidth, rowWidth)) : nil)
            .clipShape(.rect(cornerRadius: open ? 14 : 20))
            // Plain glass, not interactive: the button inside takes the tap, and interactive glass
            // on the wrapper hid that button from accessibility (and the UI test).
            .voryGlassEffect(.regular, in: .rect(cornerRadius: open ? 14 : 20))
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 2)
    }
}

/// A background process's note in its row, as wide as the row is offered whatever the note's own width (#440). The
/// first view, empty, is placed at exactly the width offered, and the note measures it as the width to lay its details
/// out at; the second, the note, goes on top, centred. A ZStack placed both at its own size: a note laid out wider than
/// its row (its details still at an older row's width, an iPad turned back to portrait with a note open) made the stack
/// that wide, the empty view measured that, and the width held, the thread and then the whole chat wider than their
/// column. Here a note wider than its row lasts one pass: the measure is the row's, and the details follow it.
private struct OfferedWidthRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let note = subviews.count > 1 ? subviews[1].sizeThatFits(proposal) : .zero
        guard let width = proposal.width, width.isFinite else { return note }
        return CGSize(width: width, height: note.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: 0))
        guard subviews.count > 1 else { return }
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                          proposal: ProposedViewSize(width: bounds.width, height: proposal.height))
    }
}

/// The folded part of a note, a tool card or a reasoning fold: laid out at its full size from
/// the first frame and still there through the close, so the container's moving edge reveals
/// it and covers it again. A plain `if open` with an identity transition pulled it out on the
/// close's first frame, and an empty box collapsed (seen frame by frame on the phone).
struct Folded: ViewModifier {
    var open: Bool
    /// The parent stack's spacing: a zero-height child would still get it, so it is taken back.
    var spacing: CGFloat = 0
    /// Kept laid out through the close, so the edge covers it. Not for a big fold: a few screens of text laid out and
    /// animated only to be covered, the close went with the fold at once (#361).
    var keep = true
    /// The content fades in as the edge uncovers it and out as the edge covers it, in the same animation: uncovered at
    /// full strength, text read as cut by a moving line (#437). Off where the edge itself is the reveal (a background
    /// process's note, revealed by its widening glass).
    var fade = true
    /// Mounted while open and for the close animation after; not before the first open.
    @State private var shown = false
    /// Bumped on every change, so a close's delayed unmount stands down when it reopened since.
    @State private var gen = 0
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            // No transition of its own, and its natural height whatever the fold proposes: it is
            // in place at full size and the edge does the rest (a Text offered the shrinking
            // height re-wrapped to fewer lines mid-close).
            if open || shown { content.fixedSize(horizontal: false, vertical: true).opacity(fade && !open ? 0 : 1).transition(.identity) }
        }
        .frame(height: open ? nil : 0, alignment: .top)
        .clipped()
        .padding(.top, open ? 0 : -spacing)
        .onChange(of: open, initial: true) { _, now in
            gen += 1
            if now { shown = true } else if !keep { shown = false } else {
                let g = gen
                Task { try? await Task.sleep(for: .milliseconds(650)); if gen == g { shown = false } }
            }
        }
    }
}

extension View {
    func folded(open: Bool, spacing: CGFloat = 0, keep: Bool = true, fade: Bool = true) -> some View { modifier(Folded(open: open, spacing: spacing, keep: keep, fade: fade)) }
}

/// The tapped card's place while the thread holds it (#437, #473). The thread's hold anchors its size changes at its top,
/// which keeps a card where it is as it grows, unless rows above it are measured in the same pass (the lazy stack's
/// estimate for rows not yet measured, right after an open or far up a long chat): then the card moved by their
/// correction. Each card keeps its top on screen in a box (`Top`, no redraw; a number stored and a flag read per move, so
/// a long chat's cards cost next to nothing while it scrolls); the one tapped is armed with its top before its toggle;
/// while the thread holds it, a move of its top is answered by scrolling the thread to the offset that puts it back,
/// counted from the offset of the pass that reported it (`TranscriptView.holdCard`), so a move reported again before
/// the scroll has landed asks for the same place, once. The thread's other scrolls wait meanwhile (`holding`). The hold's
/// end, or a finger on the thread, ends it.
@MainActor final class CardHold {
    static let shared = CardHold()
    /// A card's last top on screen, and the top it is held at while armed.
    final class Top {
        var y: CGFloat?
        fileprivate(set) var heldAt: CGFloat?
        var armed: Bool { heldAt != nil }
    }
    private weak var held: Top?
    private var correct: ((CGFloat) -> Void)?
    /// A hold under way: the thread's other scrolls (landing past the end, the overscroll fix) wait for its end.
    var holding: Bool { correct != nil }

    func arm(_ card: Top) {
        held?.heldAt = nil
        card.heldAt = card.y
        held = card
        correct = nil
    }
    func begin(_ correct: @escaping (CGFloat) -> Void) {
        guard held?.heldAt != nil else { return }
        self.correct = correct
    }
    func end() {
        held?.heldAt = nil
        held = nil
        correct = nil
    }
    func moved(_ card: Top, to y: CGFloat) {
        guard card === held, let top = card.heldAt, let correct else { return }
        let delta = y - top
        if abs(delta) >= 0.5 { correct(delta) }
    }
}

#if DEBUG
/// DEBUG, for the card checks (#437): with `-vory-card-probe`, a card toggled in the last second writes its top and
/// height on screen to the perf log at every layout ("card-motion …"), so a test can say whether its top moved while it
/// opened or closed, frame by frame.
@MainActor
enum CardMotionProbe {
    nonisolated static let isOn = ProcessInfo.processInfo.arguments.contains("-vory-card-probe")
    /// Each toggled card's top and height at each layout, and when (seconds after the first tap). Toggles within a
    /// second of each other add to the same record (open, close, open; two cards), each card under its own key.
    private(set) static var samples: [(key: String, t: Double, top: CGFloat, height: CGFloat)] = []
    private static var began = Date.distantPast
    /// Whether the thread is holding a card's place now (`TranscriptView.holdCard`).
    static var holding = false
    static func begin() { if Date().timeIntervalSince(began) > 1 { samples = []; began = Date() } }
    static func note(_ kind: String, _ f: CGRect, until: Date) {
        guard isOn, Date() < until else { return }
        samples.append((kind, Date().timeIntervalSince(began), f.minY, f.height))
        Perf.note("card-motion \(kind) top \(String(format: "%.2f", f.minY)) height \(String(format: "%.2f", f.height))")
    }
    /// "holding|key,t,top,height;…", read by a UI test after the animation (`Readout`).
    static var summary: String { (holding ? "1|" : "0|") + samples.map { "\($0.key)," + String(format: "%.3f,%.2f,%.2f", $0.t, $0.top, $0.height) }.joined(separator: ";") }

    #if os(iOS)
    /// A 1 pt element ("debug.cardmotion") whose value is `summary`, taken when it is read.
    final class ReadoutView: UIView {
        override var isAccessibilityElement: Bool { get { true } set {} }
        override var accessibilityIdentifier: String? { get { "debug.cardmotion" } set {} }
        override var accessibilityLabel: String? { get { "Card motion" } set {} }
        override var accessibilityValue: String? { get { MainActor.assumeIsolated { CardMotionProbe.summary } } set {} }
    }
    struct Readout: UIViewRepresentable {
        func makeUIView(context: Context) -> ReadoutView { ReadoutView() }
        func updateUIView(_ v: ReadoutView, context: Context) {}
    }
    #endif
}
#endif

#if DEBUG
/// DEBUG, for the open checks (#449): with `-vory-coldopen-probe`, how the thread moved in the minute after a chat
/// appeared: its moves of 80 pt or more with no finger on it, when it last moved more than 10 pt from where it settled,
/// and the largest throw up the thread once the whole history was in (a move away from the end with the content's height
/// unchanged). Read by a UI test at "debug.coldopen" after the open has settled.
@MainActor
enum ColdOpenProbe {
    nonisolated static let isOn = ProcessInfo.processInfo.arguments.contains("-vory-coldopen-probe")
    private static var title = ""
    private static var began = Date.distantPast
    /// (ms since the chat appeared, distance from the end, content height, items, a finger on the thread, in sight)
    private static var samples: [(ms: Int, dist: CGFloat, height: CGFloat, items: Int, touch: Bool, seen: Bool)] = []

    static func begin(_ chat: String) { title = chat; began = Date(); samples = [] }
    static func note(dist: CGFloat, height: CGFloat, items: Int, touch: Bool, seen: Bool) {
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        guard isOn, ms <= 60_000 else { return }
        samples.append((ms, dist, height, items, touch, seen))
    }
    /// "title|items|moves|settle ms|throw pt|shown ms", worked out when it is read, from what was in sight: a move counts
    /// when the thread was in sight at both ends of it; settle and shown are from the chat appearing.
    static var summary: String {
        let full = samples.map(\.items).max() ?? 0
        var moves = 0, thrown: CGFloat = 0
        for (a, b) in zip(samples, samples.dropFirst()) where !a.touch && !b.touch && a.seen && b.seen {
            if abs(b.dist - a.dist) >= 80 { moves += 1 }
            if a.items == full, b.items == full, abs(b.height - a.height) < 500 { thrown = max(thrown, b.dist - a.dist) }
        }
        let seen = samples.filter(\.seen)
        let final = samples.last?.dist ?? 0
        let settle = seen.last { abs($0.dist - final) > 10 }?.ms ?? 0
        let shown = seen.first { $0.items == full }?.ms ?? -1
        return "\(title)|\(full)|\(moves)|\(settle)|\(Int(thrown))|\(shown)"
    }

    #if os(iOS)
    /// A 1 pt element ("debug.coldopen") whose value is `summary`, taken when it is read.
    final class ReadoutView: UIView {
        override var isAccessibilityElement: Bool { get { true } set {} }
        override var accessibilityIdentifier: String? { get { "debug.coldopen" } set {} }
        override var accessibilityLabel: String? { get { "Cold open" } set {} }
        override var accessibilityValue: String? { get { MainActor.assumeIsolated { ColdOpenProbe.summary } } set {} }
    }
    struct Readout: UIViewRepresentable {
        func makeUIView(context: Context) -> ReadoutView { ReadoutView() }
        func updateUIView(_ v: ReadoutView, context: Context) {}
    }
    #endif
}

/// DEBUG: the thread's geometry for the open checks. With `-vory-geometry-log`, every change of the scroll geometry, every
/// scroll asked for, the thread appearing and going, its history being fetched and its rows changing, to the perf log on
/// the uptime clock (`Perf.stamp`), for a timeline of an open; with `-vory-coldopen-probe`, the same changes to
/// `ColdOpenProbe`. Neither flag: nothing is observed.
struct ThreadGeometryWatch: ViewModifier {
    let chat: ChatSession
    let metrics: ScrollMetrics
    let position: String
    /// The thread out of sight (resuming with no rows, or a history landing, #449): what moves then is not seen.
    let hidden: Bool
    static let log = ProcessInfo.processInfo.arguments.contains("-vory-geometry-log")

    func body(content: Content) -> some View {
        if Self.log || ColdOpenProbe.isOn {
            content
                .onScrollGeometryChange(for: [CGFloat].self) { g in
                    [g.contentOffset.y, g.contentSize.height, g.containerSize.height, g.contentInsets.top, g.contentInsets.bottom]
                } action: { _, v in note(v) }
                .onChange(of: position) { _, new in if Self.log { Perf.stamp("POS \(chat.title) \(new.prefix(160))") } }
                .onChange(of: hidden) { _, new in
                    // The thread coming into sight is no change of its geometry: a sample of its own, so the probe knows when
                    // it was shown and where it was.
                    if !new { ColdOpenProbe.note(dist: metrics.distanceFromBottom, height: metrics.contentHeight, items: chat.items.count, touch: metrics.userScrolling, seen: true) }
                    if Self.log { Perf.stamp("HIDDEN \(chat.title) \(new ? 1 : 0)") }
                }
                .onAppear {
                    ColdOpenProbe.begin(chat.title)
                    if Self.log { Perf.stamp("APPEAR \(chat.title) items \(chat.items.count) resuming \(chat.isResuming ? 1 : 0)") }
                }
                .onDisappear { if Self.log { Perf.stamp("DISAPPEAR \(chat.title)") } }
                .onChange(of: chat.isResuming) { _, new in if Self.log { Perf.stamp("RESUMING \(chat.title) \(new ? 1 : 0) items \(chat.items.count)") } }
                .onChange(of: chat.items.count) { old, new in if Self.log { Perf.stamp("ITEMS \(chat.title) \(old) -> \(new)") } }
        } else {
            content
        }
    }

    private func note(_ v: [CGFloat]) {
        ColdOpenProbe.note(dist: metrics.distanceFromBottom, height: v[1], items: chat.items.count, touch: metrics.userScrolling, seen: !hidden)
        guard Self.log else { return }
        Perf.stamp("GEO \(chat.title) off \(Int(v[0])) h \(Int(v[1])) c \(Int(v[2])) it \(Int(v[3])) ib \(Int(v[4])) end \(Int(v[1] + v[4] - v[0] - v[2])) dist \(Int(metrics.distanceFromBottom)) stick \(metrics.stickToBottom ? 1 : 0) touch \(metrics.userScrolling ? 1 : 0) items \(chat.items.count) vis \(hidden ? 0 : 1)")
    }
}
#endif

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
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
                    // The whole call, however much of it is drawn at a time (#421).
                    ToolbarItem(placement: .primaryAction) { Button { UIPasteboard.general.string = text } label: { Label("Copy all", systemImage: "doc.on.doc") } }
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
    /// The whole message on the Select Text sheet, under its headline, when the notice shows only its start.
    var onShowAll: ((_ title: String, _ text: String) -> Void)?
    @State private var open = false

    init(handle: String, label: String, headline: String, body: String?, pending: Bool, onOpen: @escaping (String) -> Void,
         onShowAll: ((_ title: String, _ text: String) -> Void)? = nil) {
        self.handle = handle; self.label = label; self.headline = headline; self.body_ = body; self.pending = pending; self.onOpen = onOpen
        self.onShowAll = onShowAll
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
                .voryGlassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(headline). Opens \(label)'s chat")
            if let text = body_, !text.isEmpty {
                Button { withAnimation(.snappy) { open.toggle() } } label: {
                    Text(open ? "hide message" : "show message").font(.caption2).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                if open {
                    let shown = TextPieces.capped(text)
                    VStack(alignment: .leading, spacing: 4) {
                        LongText(shown.text).font(.footnote).textSelection(.enabled)
                        if shown.more > 0 { MoreTextNote(more: shown.more, action: onShowAll.map { f in { f(headline, text) } }) }
                    }
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
    /// The whole reasoning, when the fold shows only its start (`TextPieces.foldCap`).
    var onShowAll: ((String) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Its top on screen, kept without redrawing it, for the thread's hold of it (`CardHold`).
    @State private var top = CardHold.Top()
    #if DEBUG
    @State private var probeUntil = Date.distantPast
    #endif
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
            // Models think in markdown (headings, lists, tables): render it, small and quiet.
            // In place from the start; the fold's moving edge reveals and covers it (nothing slides).
            // A long turn's reasoning is shown up to the fold's cap, the rest on the Select Text sheet,
            // and closes at once rather than staying laid out under the closing edge (#361).
            let shown = TextPieces.capped(text)
            VStack(alignment: .leading, spacing: 6) {
                MarkdownView(text: shown.text, style: .reasoning, inlineSelection: false).equatable()
                if shown.more > 0 { MoreTextNote(more: shown.more, action: onShowAll.map { f in { f(text) } }) }
            }
            .folded(open: open, spacing: 4, keep: shown.text.utf8.count <= 6_000)
        }
        // One width, open or closed: the closed card was as wide as its header and the open one as wide as its text, so
        // the width grew with the height and the text, laid out at its final width, showed cut on the right (#437).
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { _, y in
            top.y = y
            if top.armed { CardHold.shared.moved(top, to: y) }
        }
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _, f in CardMotionProbe.note("reasoning-\(abs(text.hashValue) % 100_000)", f, until: probeUntil) }
        #endif
    }

    /// The thread keeps the card where it is meanwhile (`TranscriptView.holdCard`, through the binding). With Reduce
    /// Motion, at once.
    private func toggle() {
        #if DEBUG
        probeUntil = Date().addingTimeInterval(1); CardMotionProbe.begin()
        #endif
        CardHold.shared.arm(top)
        withAnimation(reduceMotion ? nil : .snappy) { open.toggle() }
    }
}

extension Notification.Name {
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

    /// The settled parts of the replies parsed last (a streaming reply's among them): a reply's
    /// next text starts with its settled part, so only the tail after it is parsed. The whole
    /// reply was parsed on every token, a long one's growing with its length.
    @MainActor private static var settled: [MarkdownParser.Settled] = []

    @MainActor static func blocks(_ text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = blockCache.object(forKey: key) { return hit.blocks }
        let prior = settled.indices.filter { settled[$0].isStart(of: text) }.max { settled[$0].text.utf8.count < settled[$1].text.utf8.count }
        let parsed = MarkdownParser.blocks(from: text, after: prior.map { settled[$0] })
        if let prior { settled.remove(at: prior) }
        if let s = parsed.settled {
            settled.append(s)
            if settled.count > 16 { settled.removeFirst() }
        }
        blockCache.setObject(BlocksBox(parsed.blocks), forKey: key, cost: text.utf8.count)
        return parsed.blocks
    }
    @MainActor static func inline(_ text: String) -> AttributedString {
        // Mentions are marked after the cache: they depend on the bots known now, not on the text.
        // Most paragraphs mention nobody: those skip the walk over their runs, which ran over every
        // paragraph of a streaming reply on each token.
        let a = inlineCached(text)
        guard text.utf8.contains(UInt8(ascii: "@")) else { return a }
        return Mentions.mark(a, names: Mentions.names)
    }
    /// The inline text as a view, bot mentions drawn as chips (#321), in pieces when long for the text size (#361).
    @MainActor static func inlineText(_ text: String) -> some View { InlineText(text: text) }
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
    /// A code block's whole text on the Select Text sheet, under a title, when the reply shows only its start (#361).
    var onShowAll: ((_ title: String, _ text: String) -> Void)? = nil

    /// A code block's sheet title: "Code", or "Code · bash" when the fence names a language.
    static func codeTitle(_ lang: String?) -> String {
        guard let lang, !lang.isEmpty, !["text", "txt", "plaintext", "plain"].contains(lang.lowercased()) else { return "Code" }
        return "Code · \(lang)"
    }

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
            Self.inlineText(t).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let t):
            Self.inlineText(t).font(Self.headingFont(level, style: style)).fixedSize(horizontal: false, vertical: true)
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
                // Its start, in pieces: every piece is drawn whole, so a log of thousands of lines cost hundreds of
                // megabytes; the rest is a Show all away (#361).
                let shown = TextPieces.capped(code)
                LongText(shown.text, code: true).font(style.codeFont).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(10)
                if shown.more > 0 {
                    MoreTextNote(more: shown.more, action: onShowAll.map { f in { f(Self.codeTitle(lang), code) } })
                        .padding(.horizontal, 10).padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        listMarker(it)
                        Self.inlineText(it.text)
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
                Self.inlineText(t).foregroundStyle(.secondary)
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

    /// What the reply shows: a table over 16 columns or 60 rows shows that much and says how much more there is; the
    /// whole of it is on the sheet (a wide table made a grid wider than the graphics card draws, #361).
    private var shownTable: MarkdownTable { table.prefix(columns: MarkdownTableMetrics.bubbleColumns, rows: MarkdownTableMetrics.bubbleRows) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if typeSize.isAccessibilitySize {
                MarkdownTableStack(table: shownTable)
            } else {
                card
            }
            let columns = table.header.count - shownTable.header.count, rows = table.rows.count - shownTable.rows.count
            if columns > 0 || rows > 0 {
                Button { full = true } label: {
                    Text([columns > 0 ? "\(columns) more columns" : nil, rows > 0 ? "\(rows) more rows" : nil].compactMap { $0 }.joined(separator: ", ") + " · Open the table")
                        .font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.tint)
            }
        }
        // No menu of its own: a long press keeps the reply's (Reply, Speak, Copy, Share). The
        // corner button opens the table, and its sheet copies it as Markdown.
        // Local, as the html card's is: the row stays alive under its sheet in the lazy thread.
        .sheet(isPresented: $full) { MarkdownTableSheet(table: table).sheetFrame(.wide).withAppModel() }
    }

    private var grid: some View {
        MarkdownTableGrid(table: shownTable, lineLimit: 3, maxColumn: MarkdownTableMetrics.bubbleMaxColumn, headerInset: 22)
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

    @Environment(\.displayScale) private var displayScale
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
            if let decoded = await AttachmentThumbs.imageAsync(at: file, side: 1200, scale: displayScale) { picture = decoded } else { failed = true }
        } catch {
            failed = true
        }
    }
}

struct ToolCardView: View {
    var activity: ToolActivity
    /// Open state owned by the thread (so a recycled row keeps it and the turn's end can fold it).
    var open: Binding<Bool> = .constant(false)
    /// The Output block when open (Appearance › Chat).
    var showOutput = true
    /// One line: name, time and chevron; the context and summary lines only when open.
    var compact = false
    @State private var showFull = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Its top on screen, kept without redrawing it, for the thread's hold of it (`CardHold`).
    @State private var top = CardHold.Top()
    #if DEBUG
    @State private var probeUntil = Date.distantPast
    #endif
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
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
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
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                    if compact, todos == nil, let s = activity.summary, !s.isEmpty { Text(s).font(.caption).lineLimit(3) }
                    // The whole call: the args when the gateway sent them, else the context line in
                    // full (a tester opened a card and got a few more characters of a cut preview).
                    if todos == nil, let a = fullCall, !a.isEmpty {
                        Text(activity.name == "terminal" || activity.name == "bash" ? "Command" : "Arguments").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        CodeBlock(text: a, lineCap: 40, onShowAll: { showFull = true })
                    }
                    if showOutput, let r = activity.resultText, !r.isEmpty {
                        Text("Output").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        CodeBlock(text: r, lineCap: 30, onShowAll: { showFull = true })
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
            // In place from the start; the card's moving edge reveals and covers it (nothing slides).
            .folded(open: expanded, spacing: compact ? 4 : 6)
        }
        .sheet(isPresented: $showFull) { ToolCallSheet(activity: activity, fullCall: fullCall).sheetFrame(.wide).withAppModel() }
        .padding(compact ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A painted card, not glass: a thread can hold dozens of these, and each live glass
        // layer is composited every frame while the thread scrolls (the stutter on device).
        // The opened part is revealed by the card growing, inside the card (Matt, 2026-10-11:
        // tool expands need a proper animation; it faded in before).
        .clipShape(.rect(cornerRadius: compact ? 10 : 14))
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: compact ? 10 : 14))
        .overlay(RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .contentShape(.rect)
        // The thread keeps the card where it is meanwhile (`TranscriptView.holdCard`, through the binding). With Reduce
        // Motion, at once.
        .onTapGesture {
            #if DEBUG
            probeUntil = Date().addingTimeInterval(1); CardMotionProbe.begin()
            #endif
            CardHold.shared.arm(top)
            withAnimation(reduceMotion ? nil : .snappy) { open.wrappedValue.toggle() }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { _, y in
            top.y = y
            if top.armed { CardHold.shared.moved(top, to: y) }
        }
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _, f in CardMotionProbe.note("tool-\(activity.id)", f, until: probeUntil) }
        #endif
        .accessibilityElement(children: .combine)
        // A tap gesture alone gives assistive tech nothing to press (on the Mac the card was plain text).
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            CardHold.shared.arm(top)
            withAnimation(reduceMotion ? nil : .snappy) { open.wrappedValue.toggle() }
        }
        .accessibilityHint(DeviceWords.isMac ? "Expands the tool log" : "Double-tap to expand the tool log")
    }

    @ViewBuilder private var statusIcon: some View {
        switch activity.status {
        case .running: ProgressView().controlSize(.small)
        // Its state in words, as it changes ("Checkmark Circle" before, #409); nothing else in the card says it.
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        }
    }
}

/// Monospaced block with a light background, capped at `lineCap` lines until "Show more" —
/// a terminal transcript can be thousands of lines.
struct CodeBlock: View {
    var text: String
    var lineCap: Int
    /// The whole text on a page of its own (the tool's), when what is shown is capped.
    var onShowAll: (() -> Void)? = nil
    @State private var showAll = false

    var body: some View {
        // Capped in characters as well as lines: a few lines of minified output can be a megabyte. What is shown is
        // drawn in pieces (#361); the whole output is on the tool's page and in Copy. The lines are counted, not
        // split: split on every redraw, a big output took most of a second to open or close its card (#421).
        let lines = TextPieces.lines(text, cap: lineCap)
        let shown = TextPieces.capped(showAll || lines.count <= lineCap ? text : String(lines.head))
        VStack(alignment: .leading, spacing: 4) {
            LongText(shown.text, code: true).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).padding(10).padding(.trailing, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            .overlay(alignment: .topTrailing) { CopyButton(text: text).padding(6) }
            if shown.more > 0 { MoreTextNote(more: shown.more, action: onShowAll) }
            if lines.count > lineCap {
                Button(showAll ? "Show less" : "Show \(lines.count - lineCap) more lines") { withAnimation(.snappy) { showAll.toggle() } }
                    .font(.caption)
            }
        }
    }
}

struct AttachmentStrip: View {
    var attachments: [AttachmentPreview]
    @Environment(\.displayScale) private var displayScale
    @State private var preview: URL?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { a in
                Button { if let u = a.localURL { preview = u } } label: {
                    // A thumbnail, never the full photo: a 12-megapixel bitmap per row is what a
                    // thread of screenshots turns into otherwise.
                    if a.kind == .image, let u = a.localURL, let img = AttachmentThumbs.image(at: u, side: 96, scale: displayScale) {
                        Image(uiImage: img).resizable().scaledToFill().frame(width: 96, height: 96).clipShape(.rect(cornerRadius: 12))
                    } else {
                        Label(a.name, systemImage: a.kind == .pdf ? "doc.richtext" : a.kind == .audio ? "waveform" : a.kind == .video ? "video" : "doc")
                            .font(.caption).lineLimit(1)
                            .padding(8).voryGlassEffect(.regular, in: .rect(cornerRadius: 10))
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
                // A 32 x 28 click target around the glyph (it was 24 x 20); a content shape
                // larger than the frame did not take clicks on the Mac.
                .frame(width: 32, height: 28).contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Laid out at 24 x 20 as before: the code header and the overlays place it by that frame.
        .padding(-4)
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

    /// A step's state in words, where its icon read its own name ("Checkmark Circle, Run the cleanup", #409).
    static func spoken(_ s: String) -> String {
        switch s {
        case "completed", "done": return "Done"
        case "in_progress", "in-progress", "active", "doing": return "In progress"
        case "cancelled", "canceled", "skipped": return "Skipped"
        default: return "To do"
        }
    }

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
                    Image(systemName: sym).foregroundStyle(color).font(.caption).accessibilityLabel(Self.spoken(t.status))
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

/// The thread's window watch, one modifier so the thread's long chain stays within what the
/// type checker will take: the scroll view's frame in window space, the window's shape, and the
/// keyboard overlap, each reported as it changes.
private struct ThreadWindowWatch: ViewModifier {
    let geometry: WindowGeometry
    let frame: (CGRect) -> Void
    let shapeChanged: () -> Void
    let keyboard: (CGFloat) -> Void
    private var shape: [CGFloat] { [geometry.bounds.width, geometry.bounds.height, geometry.safeArea.bottom] }
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame($0) }
            .onChange(of: shape) { shapeChanged() }
            .onChange(of: geometry.keyboardOverlap, initial: true) { _, v in keyboard(v) }
    }
}

/// The thread's room for the floating header (the blur under the header is the conversation's
/// own band, see `ConversationView.headerBand`). On iOS the thread is also masked at its sides: the times wait 20 pt beyond the rows (the
/// slide brings them in), which the screen's edge hid on a phone but the iPhone Duo's side
/// strip and a second column would show. The sides only: the thread keeps running under the
/// header's blur and the dock above and below.
private struct ThreadTopEdge: ViewModifier {
    let inset: CGFloat
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .mask { Rectangle().padding(.vertical, -4000) }
            .contentMargins(.top, inset, for: .scrollContent)
        #else
        content.contentMargins(.top, inset, for: .scrollContent)
        #endif
    }
}
