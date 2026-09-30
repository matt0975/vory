import Combine
import QuickLook
import SwiftUI
import VoryCore

struct TranscriptView: View {
    @Bindable var chat: ChatSession
    /// Long-press › "Edit & resend" hands the text back to the composer.
    var onEditMessage: (String) -> Void = { _ in }
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
    /// The margin to add so the last line ends 8 pt above the dock.
    private var bottomInset: CGFloat { dockTop > 0 && visibleBottom > dockTop ? visibleBottom - dockTop : fallbackInset }
    /// Height of the floating header (the nav bar is hidden in a chat).
    var topInset: CGFloat = 96
    /// Locked to the bottom: the thread follows every new token, tool call and card. Only the
    /// user's own drag releases it; the jump button (or scrolling back down) locks it again.
    @State private var awayFromBottom = false
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
    @State private var revealTask: Task<Void, Never>?
    @State private var overscrollTask: Task<Void, Never>?
    /// How much of the scroll view the keyboard covers (beyond the home-indicator safe area). The
    /// thread moves up with the keyboard and, when it was at the bottom, stays there.
    @State private var keyboardInset: CGFloat = 0
    /// Reasoning disclosures that are open, keyed by item id — kept here so a re-rendered row
    /// does not forget it (the earlier "can't collapse again" bug).
    @State private var openReasoning: Set<String> = []
    @State private var selectText: String?
    @AppStorage(ChatStyle.showToolCalls) private var showToolCalls = true
    @AppStorage(ChatStyle.showReasoning) private var showReasoning = true
    @AppStorage(ChatStyle.showTurnStats) private var showTurnStats = true
    @AppStorage(ChatStyle.showSystemNotes) private var showSystemNotes = true
    @AppStorage(ChatStyle.showBots) private var showBots = false

    private var visibleItems: [TranscriptItem] {
        chat.items.filter { item in
            switch item.kind {
            case .tool, .subagent: return showToolCalls
            case .system: return showSystemNotes
            default: return true
            }
        }
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
                // Lazy: a long session (hundreds of replies and tool rows) used to build every
                // row at once, and the layer tree that made could exhaust memory in the render
                // commit (abort in CA::Render::Encoder::grow, three crash reports on 1.1 (6)).
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.items.isEmpty, chat.resumeError == nil {
                        VStack(spacing: 8) {
                            BotAvatar(profile: chat.profileName, size: 56)
                            Text("Say something to \(chat.profileName)").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    ForEach(rows) { row in
                        if let sep = row.separator {
                            Text(sep).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        TranscriptRow(item: row.item, profile: showBots ? chat.profileName : nil, botShown: row.lastOfRun,
                                      typingTool: typingTool,
                                      showReasoning: showReasoning, showStats: showTurnStats, onEdit: onEditMessage,
                                      reasoningOpen: Binding(get: { openReasoning.contains(row.item.id) },
                                                             set: { if $0 { openReasoning.insert(row.item.id) } else { openReasoning.remove(row.item.id) } }),
                                      onSelectText: { selectText = $0 })
                            // Equatable on what it draws (the closures and the binding are
                            // compared by value): a row whose message did not change is not
                            // rebuilt when the thread re-evaluates for a scroll or a token.
                            .equatable()
                            .id(row.item.id)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                            // The time waits just past the right edge; the column slides left to show it.
                            .overlay(alignment: .trailing) {
                                Text(row.item.timestamp, style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    // Its leading edge sits 20 pt past the row (beyond the screen's
                                    // 16 pt margin), so nothing of it shows until the column slides.
                                    .fixedSize().alignmentGuide(.trailing) { d in d[.leading] - 20 }
                                    .accessibilityHidden(true)
                            }
                    }
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
                        .id("typing")
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if let s = chat.statusLine, chat.isRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(s).font(.caption).foregroundStyle(.secondary)
                        }
                        // Clear of the bot column when the pinned working bot sits there.
                        .padding(.leading, showBots ? 38 : 4).padding(.trailing, 4)
                    }
                    Color.clear.frame(height: 0).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .animation(.snappy(duration: 0.28), value: chat.items.count)
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
                let covered = max(0, UIScreen.main.bounds.maxY - end.minY)
                let safeBottom = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }.first ?? 0
                let inset = max(0, covered - safeBottom)
                // The keyboard moves on UIKit's own spring; this spring tracks it closely, so the
                // thread and the composer arrive together instead of the composer overlapping.
                withAnimation(.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)) {
                    keyboardInset = inset
                    if metrics.stickToBottom { scrollPosition.scrollTo(edge: .bottom) }
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
            .onReceive(NotificationCenter.default.publisher(for: .hermesRevealRow)) { n in
                guard let bottom = n.userInfo?["bottom"] as? CGFloat, let id = n.userInfo?["id"] as? String else { return }
                revealTask?.cancel()
                revealTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    // Only when the opened row runs under the composer; then its bottom edge is
                    // aligned to the visible bottom (the scroll view resolves the row itself,
                    // so no offset arithmetic across coordinate spaces).
                    let limit = (dockTop > 0 ? dockTop : UIScreen.main.bounds.height - fallbackInset) - 8
                    let overshoot = bottom - limit
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
            // Insets included: the bottom margin (dock plus home indicator) is about the size of
            // the threshold, so without it a slightly taller dock showed the arrow at the very end.
            .onScrollGeometryChange(for: CGFloat.self) { g in
                g.contentSize.height + g.contentInsets.bottom - g.visibleRect.maxY
            } action: { _, distance in
                metrics.distanceFromBottom = distance
                // Past the end with no finger on it: a scroll-to-bottom that used the lazy stack's
                // estimated height lands beyond the real content and the thread shows nothing
                // until a drag bounces it back ("chats open blank until you scroll"). Land it.
                if distance < -60, !metrics.userScrolling { scheduleOverscrollFix() }
                let away = distance > 120
                if away != awayFromBottom { withAnimation(.snappy) { awayFromBottom = away } }
                // Content growing under a locked thread also reads as "away" for a frame; only a
                // finger on the thread unlocks it. Scrolling back to the end locks it again.
                if metrics.userScrolling, distance > 24 { metrics.stickToBottom = false }
                if distance < 4 { metrics.stickToBottom = true }
            }
            .onScrollPhaseChange { _, phase in
                metrics.userScrolling = phase == .interacting || phase == .decelerating
            }
            // The working bot: one spot at the bottom-left of the thread for the whole turn, in
            // the same pose as the bot on the header pill, gone once the turn ends. It used to sit
            // beside whichever row was live and hopped between them as the turn went on.
            .overlay(alignment: .bottomLeading) {
                if showBots, chat.isRunning {
                    BotAvatar(profile: chat.profileName, size: 28, active: true, mood: BotFaceView.Mood(state: chat.botState))
                        .padding(.leading, 16).padding(.bottom, dockReach + 12)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.snappy, value: chat.isRunning)
            .overlay(alignment: .topLeading) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-vory-geometry") {
                    Text("dockTop \(Int(dockTop)) scrollBottom \(Int(scrollBottom)) inset \(Int(bottomInset)) dist \(Int(metrics.distanceFromBottom))")
                        .font(.caption2.monospacedDigit()).padding(4).background(.yellow).foregroundStyle(.black).padding(.top, 120)
                }
                #endif
            }
            .overlay(alignment: .bottomTrailing) {
                JumpToBottomButton(visible: awayFromBottom) { jumpToBottom() }
                .padding(.trailing, 16).padding(.bottom, dockReach + 12)
            }
            .sheet(item: Binding(get: { selectText.map { SelectTextItem(text: $0) } }, set: { selectText = $0?.text })) { SelectTextSheet(text: $0.text) }
            #if os(iOS)
            // Under the status bar, behind the floating header. The Mac's toolbar is not a place to run under.
            .ignoresSafeArea(.container, edges: .top)
            #endif
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            // Whole item, not just `.kind`: the tokens/sec footer lands after the text does and
            // must pull the bottom back into view too.
            // Streaming text follows unanimated (tokens arrive faster than an animated scroll
            // settles); a new message glides: the bubble slides in and the thread eases up with it.
            .onChange(of: chat.items.last) { _, _ in
                if metrics.stickToBottom, !metrics.userScrolling { scrollPosition.scrollTo(edge: .bottom) }
            }
            .onChange(of: chat.items.count) { _, _ in
                guard metrics.stickToBottom, !metrics.userScrolling else { return }
                if settling { scrollPosition.scrollTo(edge: .bottom) }
                else { withAnimation(.easeOut(duration: 0.28)) { scrollPosition.scrollTo(edge: .bottom) } }
            }
            .onAppear { openedAt = Date() }
            // Once the history is in and laid out, make sure the end is really on screen.
            .task(id: chat.isResuming) {
                guard !chat.isResuming else { return }
                for delay in [300, 900] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard !Task.isCancelled, metrics.stickToBottom, !metrics.userScrolling else { return }
                    if metrics.distanceFromBottom < -8 || metrics.distanceFromBottom > 8 { scrollPosition.scrollTo(edge: .bottom) }
                }
            }
            .onChange(of: chat.statusLine) { _, _ in
                if metrics.stickToBottom, !metrics.userScrolling { withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) } }
            }
            // The turn ending takes the typing bubble and status line out from under the last
            // reply; a locked thread follows so no blank band is left there.
            .onChange(of: chat.isRunning) { _, _ in
                if metrics.stickToBottom, !metrics.userScrolling { withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) } }
            }
            // The dock changing height (an approval card arriving or leaving) moves the bottom
            // margin; a locked thread follows, so no blank band opens under the last row. Once
            // the height has settled, not per frame of the card's grow animation: a scroll per
            // frame against a moving margin overshot into blank space.
            .onChange(of: bottomInset) { _, _ in
                guard metrics.stickToBottom else { return }
                insetSettle?.cancel()
                insetSettle = Task {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    if settling { scrollPosition.scrollTo(edge: .bottom) }
                    else { withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) } }
                }
            }
        }
    }
}

extension TranscriptView {
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
                // A fast scroll, not a fade: from far away the thread first jumps (unanimated,
                // before the next frame draws) to one screen short of the end, worked out from
                // the geometry rather than by landing first, then scrolls the last stretch.
                let end = metrics.contentHeight + metrics.reportedInsetBottom - metrics.containerHeight
                scrollPosition.scrollTo(y: max(0, end - 900))
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
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
/// moves right, and once it runs the scroll view's own pan lets go of the touch.
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
    static let showReasoning = "chat.showReasoning"
    static let showTurnStats = "chat.showTurnStats"
    static let showSystemNotes = "chat.showSystemNotes"
    /// The bot beside each reply bubble.
    static let showBots = "chat.showBots"
    /// Pull the thread left to see message times.
    static let timeReveal = "chat.timeReveal"
}

/// A transcript item plus the "Tue, Sep 22 at 6:30 PM" separator that precedes it when the
/// conversation paused for a while, the way Messages breaks up a thread.
struct TranscriptRowModel: Identifiable {
    var item: TranscriptItem
    var separator: String?
    /// The last reply before something that is not a reply (the bot sits beside this one).
    var lastOfRun = true
    var id: String { item.id }

    static let gap: TimeInterval = 15 * 60

    static func build(_ items: [TranscriptItem], now: Date = Date()) -> [TranscriptRowModel] {
        var out: [TranscriptRowModel] = []
        var last: Date?
        for item in items {
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
        a.item == b.item && a.profile == b.profile && a.botShown == b.botShown && a.typingTool == b.typingTool
            && a.showReasoning == b.showReasoning && a.showStats == b.showStats
            && a.reasoningOpen.wrappedValue == b.reasoningOpen.wrappedValue
    }
    var item: TranscriptItem
    /// The bot beside its bubble, as in a group chat; nil for none. Only the last bubble of a
    /// run of replies gets the bot (`botShown`); the others keep the same left margin.
    var profile: String? = nil
    var botShown = true
    /// While the reply has no text yet: nil = a grey typing bubble, a name = the dark one with
    /// the tool badge.
    var typingTool: String? = nil
    var showReasoning = true
    var showStats = true
    var onEdit: (String) -> Void = { _ in }
    var reasoningOpen: Binding<Bool> = .constant(false)
    var onSelectText: (String) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let _ = Perf.tick("row")
        switch item.kind {
        case .user(let text, let attachments):
            HStack {
                Spacer(minLength: 56)
                VStack(alignment: .trailing, spacing: 6) {
                    if !attachments.isEmpty { AttachmentStrip(attachments: attachments) }
                    if !text.isEmpty {
                        Text(text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: MessageBubbleShape(side: .trailing, tailed: botShown))
                            .contextMenu {
                                Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                                Button { onSelectText(text) } label: { Label("Select Text", systemImage: "selection.pin.in.out") }
                                Button { onEdit(text) } label: { Label("Edit & resend", systemImage: "pencil") }
                                ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                            }
                    }
                }
            }
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
                                .background(Color(.systemGray5), in: MessageBubbleShape(side: .leading, tailed: false))
                        }
                        TypingBubble(tool: typingTool)
                        if showStats, let s = item.stats {
                            Text(s.label).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).padding(.leading, 6)
                                .contentTransition(.numericText())
                                .accessibilityLabel("Turn statistics: \(s.label)")
                        }
                    }
                    Spacer(minLength: 40)
                } else {
                VStack(alignment: .leading, spacing: 6) {
                    if showReasoning, let reasoning, !reasoning.isEmpty { ReasoningDisclosure(text: reasoning, open: reasoningOpen, itemID: item.id) }
                    MarkdownView(text: text).equatable()
                    if showStats, let s = item.stats {
                        Text(s.label).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            .accessibilityLabel("Turn statistics: \(s.label)")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(.systemGray5), in: MessageBubbleShape(side: .leading, tailed: botShown))
                .contextMenu {
                    Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { onSelectText(text) } label: { Label("Select Text", systemImage: "selection.pin.in.out") }
                    ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                Spacer(minLength: 24)
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
        case .tool(let act):
            ToolCardView(activity: act, itemID: item.id)
        case .system(let text, let symbol):
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(text)
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.12), in: .rect(cornerRadius: 12))
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .subagent(let goal, let status):
            HStack(spacing: 8) {
                Image(systemName: status == "running" ? "person.2.circle" : "person.2.circle.fill")
                Text(goal).lineLimit(2)
                Spacer()
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
            .font(.footnote)
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
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
            Button {
                if !open { revealing = true; Task { try? await Task.sleep(for: .milliseconds(600)); revealing = false } }
                withAnimation(.snappy) { open.toggle() }
            } label: {
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
                Text(text).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { _, y in
            if revealing, let itemID { NotificationCenter.default.post(name: .hermesRevealRow, object: nil, userInfo: ["bottom": y, "id": itemID]) }
        }
    }
}

extension Notification.Name {
    /// A row that just expanded reports its bottom edge (global y) so the thread can show it.
    static let hermesRevealRow = Notification.Name("hermesRevealRow")
}

/// Renders markdown blocks; inline styling from AttributedString(markdown:).
struct MarkdownView: View, Equatable {
    var text: String

    /// Parsed blocks and inline styling, kept for the text they came from: a row that scrolls
    /// off and back (the lazy stack rebuilds it) does not parse its markdown again, and a
    /// finished reply is parsed once for as long as it is in the cache.
    private static let blockCache = NSCache<NSString, BlocksBox>()
    private static let inlineCache = NSCache<NSString, InlineBox>()
    final class BlocksBox { let blocks: [MarkdownBlock]; init(_ b: [MarkdownBlock]) { blocks = b } }
    final class InlineBox { let text: AttributedString; init(_ t: AttributedString) { text = t } }

    static func blocks(_ text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = blockCache.object(forKey: key) { return hit.blocks }
        let b = MarkdownParser.blocks(from: text)
        blockCache.setObject(BlocksBox(b), forKey: key, cost: text.utf8.count)
        return b
    }
    static func inline(_ text: String) -> AttributedString {
        let key = text as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.text }
        let a = MarkdownParser.inline(text)
        inlineCache.setObject(InlineBox(a), forKey: key, cost: text.utf8.count)
        return a
    }

    var body: some View {
        let _ = Perf.tick("markdown")
        let blocks = Self.blocks(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let t):
            Text(Self.inline(t))
        case .heading(let level, let t):
            Text(Self.inline(t)).font(level <= 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.semibold) : .headline)
        case .code(let lang, let code, let closed):
            // Wrapped, not side-scrolling: a horizontal pan inside a bubble used to fight the
            // timestamp reveal. Long lines wrap; a copy button sits in the corner.
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if let lang, !lang.isEmpty { Text(lang).font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if closed { CopyButton(text: code) } else { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 10).padding(.top, 6)
                Text(code).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); Text(Self.inline(it)) }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("\(i + 1).").monospacedDigit(); Text(Self.inline(it)) }
                }
            }
        case .quote(let t):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.secondary).frame(width: 3)
                Text(Self.inline(t)).foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        }
    }
}

struct ToolCardView: View {
    var activity: ToolActivity
    /// The transcript row this card is, for the reveal after it opens.
    var itemID: String? = nil
    @State private var expanded = false
    /// Set while the card opens: its frame changes are reported so the thread can reveal it.
    @State private var revealing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon
                Text(activity.displayName).font(.subheadline.weight(.medium))
                if let risk = activity.risk { Text(risk).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.orange.opacity(0.2), in: .capsule) }
                Spacer()
                if let d = activity.durationSeconds { Text(String(format: "%.1fs", d)).font(.caption2).foregroundStyle(.secondary) }
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            if let c = activity.context, !c.isEmpty, !expanded {
                Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let s = activity.summary, !s.isEmpty, !expanded {
                Text(s).font(.caption).lineLimit(2)
            }
            if expanded {
                if let a = activity.argsText, !a.isEmpty {
                    Text(activity.name == "terminal" || activity.name == "bash" ? "Command" : "Arguments").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    CodeBlock(text: a, lineCap: 40)
                }
                if let r = activity.resultText, !r.isEmpty {
                    Text("Output").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    CodeBlock(text: r, lineCap: 30)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A painted card, not glass: a thread can hold dozens of these, and each live glass
        // layer is composited every frame while the thread scrolls (the stutter on device).
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .contentShape(.rect)
        .onTapGesture {
            if !expanded { revealing = true; Task { try? await Task.sleep(for: .milliseconds(600)); revealing = false } }
            withAnimation(.snappy) { expanded.toggle() }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { _, y in
            if revealing, let itemID { NotificationCenter.default.post(name: .hermesRevealRow, object: nil, userInfo: ["bottom": y, "id": itemID]) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-tap to expand the tool log")
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
