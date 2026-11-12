#if os(iOS)
import SwiftUI
import UIKit
import os

/// The pull's steps in the perf log (DEBUG), so a UI test run can say where a pull stopped.
private let pullLog = Logger(subsystem: "Vory", category: "perf")

// The phone's page chrome: the leading title every tab root shares (the Chats look, decided
// 2026-10-12: "add the heading style of the chats page to all the other pages") and Vory's own
// pull-to-refresh, whose wheel sits beside that title. The Mac keeps its window toolbar, its
// Refresh button and its own search field; nothing here is in its target.

/// What a pull has come to, for the wheel beside the title to draw from. One object per page,
/// read only by the wheel: the page's body does not re-run with every frame of a pull.
@MainActor @Observable final class PullRefreshState {
    /// 0 until a quarter of the way into a full pull, 1 at the trigger.
    var progress: CGFloat = 0
    var refreshing = false
    var armed = false
    var dragging = false
    /// A heading's wheel is drawing this state (so the pull adds no wheel of its own).
    var hosted = false
    /// The arc to show: the pull while the finger is down or the trigger has been passed.
    var shown: CGFloat { refreshing ? 0 : (dragging || armed ? progress : 0) }
}

/// The pull's state, handed up to a heading applied outside it (a tab root whose `.reloadable`
/// sits inside the view, `.tabRoot` outside): the heading hosts the wheel either way.
struct PullRefreshRef: Equatable {
    let state: PullRefreshState?
    static func == (a: PullRefreshRef, b: PullRefreshRef) -> Bool { a.state === b.state }
}
struct PullRefreshKey: PreferenceKey {
    static let defaultValue = PullRefreshRef(state: nil)
    static func reduce(value: inout PullRefreshRef, nextValue: () -> PullRefreshRef) {
        let next = nextValue(); if next.state != nil { value = next }
    }
}

/// Pull to refresh, Vory's own rather than `.refreshable`: the system's pull spinner drew inside
/// the search drawer (2026-10-10). An over-pull past the drawer fills the wheel beside
/// the title as it comes; at the trigger it arms with a haptic tick, and the refresh runs the
/// moment the finger lifts (never mid-pull, never twice on the bounce), the wheel spinning there
/// for at least a breath before it fades. VoiceOver gets a "Refresh" action.
struct PullRefresh: ViewModifier {
    /// Where the pull arms, in points pulled past the top (the haptic and the refresh's trigger).
    static let armAt: CGFloat = 104
    /// Where the title capsule opens for the wheel and the arc starts: a quarter of a full pull as the
    /// finger feels it (feedback on 1.5 (17): "it shouldn't start until it's a quarter of the way into
    /// a full pull down"). The full pull is the finger's travel from rest to the trigger: under
    /// the scroll view's rubber band 104 pt of over-pull takes about 215 pt of finger on a 17 Pro,
    /// and a quarter of that (about 54 pt) pulls the page about 28 pt.
    static let startAt: CGFloat = 28
    let action: @MainActor () async -> Void
    /// A page without a `PageHeading` (a pushed page with the system's title): the wheel goes
    /// at the leading edge on its own.
    var ownWheel = false
    @State private var state = PullRefreshState()

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { old, phase in
                state.dragging = phase == .interacting
                if old == .interacting, phase != .interacting {
                    if state.armed, !state.refreshing { state.armed = false; refresh() }
                    else if !state.refreshing { withAnimation(.snappy(duration: 0.2)) { state.progress = 0 } }
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, v in
                // 0 at the top; negative when over-pulled. The wheel fills from a quarter of
                // a full pull to the trigger, so a short pull only shows search. Armed only while
                // the finger is down: the spring-back does not re-arm it.
                guard !state.refreshing else { return }
                let over = max(0, -v)
                if state.dragging { state.progress = min(1, max(0, (over - Self.startAt) / (Self.armAt - Self.startAt))) }
                if state.progress >= 1, state.dragging, !state.armed {
                    state.armed = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #if DEBUG
                    pullLog.notice("pull armed over=\(Int(over)) hosted=\(state.hosted)")
                    #endif
                }
            }
            .accessibilityAction(named: "Refresh") { if !state.refreshing { refresh() } }
            .toolbar {
                if ownWheel, !state.hosted {
                    ToolbarItem(placement: .topBarLeading) { PullRefreshWheel(hosting: false).environment(state) }
                        .sharedBackgroundVisibility(.hidden)
                }
            }
            .environment(state)
            .preference(key: PullRefreshKey.self, value: PullRefreshRef(state: state))
    }

    private func refresh() {
        #if DEBUG
        pullLog.notice("pull fired hosted=\(state.hosted)")
        #endif
        state.refreshing = true
        // At least a breath of spinner; a UI test can hold it longer (`-vory-refresh-hold <s>`, DEBUG).
        #if DEBUG
        let hold = max(600, Int(UserDefaults.standard.double(forKey: "vory-refresh-hold") * 1000))
        #else
        let hold = 600
        #endif
        Task {
            async let settle: Void = Task.sleep(for: .milliseconds(hold))
            await action()
            try? await settle
            withAnimation(.snappy(duration: 0.2)) { state.refreshing = false }
        }
    }
}

/// The pull-to-refresh wheel beside a page's title: an arc that fills as the pull comes, then
/// the spinner while the refresh runs. Its slot opens once a quarter of a full pull has come (one
/// snappy step: growing it with the finger resized the bar's glass on every frame, and fast pulls
/// hitched on the phone) and closes after the refresh (2026-10-12: no empty space in the
/// Chats capsule at rest); the title keeps its leading edge, so it never moves, and the capsule
/// grows to the right and back.
struct PullRefreshWheel: View {
    /// A heading's wheel claims the state (`hosted`), and the pull then adds no wheel of its
    /// own. The pull's own wheel must not claim it: it would remove itself, come back, and
    /// spin the main thread (the first run of testPageHeadings hung 30 s on Home).
    var hosting = true
    /// The state from a pull inside the heading's view (by preference); else the one around it.
    var fromBelow: PullRefreshState? = nil
    @Environment(PullRefreshState.self) private var around: PullRefreshState?
    private var pull: PullRefreshState? { fromBelow ?? around }
    /// The slot is open while the arc shows or the spinner runs.
    private var open: Bool { guard let pull else { return false }; return pull.refreshing || pull.shown > 0 }
    @State private var claimed: PullRefreshState?
    /// Grows with the title's type (the accessibility sizes), as a glyph beside it would.
    @ScaledMetric(relativeTo: .headline) private var side: CGFloat = 15
    var body: some View {
        ZStack {
            if let pull {
                Circle()
                    .trim(from: 0, to: pull.shown)
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: max(2, side / 7.5), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(Double(min(1, pull.shown * 1.5)))
                if pull.refreshing { ProgressView().controlSize(.small).transition(.opacity) }
            }
        }
        .frame(width: open ? side : 0, height: side)
        .padding(.leading, open ? side * 0.4 : 0)
        .animation(.snappy(duration: 0.3), value: open)
        // The claim follows the state: the bar's one wheel is handed each tab's state in turn
        // (onAppear ran once, so the second tab's pull added its own wheel as well).
        .onChange(of: pull.map(ObjectIdentifier.init), initial: true) { _, _ in
            guard hosting else { return }
            if claimed !== pull { claimed?.hosted = false; claimed = pull; pull?.hosted = true }
        }
        .onDisappear { if hosting { claimed?.hosted = false; claimed = nil } }
        // VoiceOver hears the refresh, not the pull: the arc is decoration, the spinner says so.
        .accessibilityHidden(!(pull?.refreshing ?? false))
        .accessibilityLabel("Refreshing")
    }
}

/// The page's title as a leading toolbar item, in the bar's own type, with the pull-to-refresh
/// wheel after it when the page can refresh. Off on a wide window, where the system title fits.
struct PageHeading: ViewModifier {
    let title: String
    var on = true
    @State private var pullBelow: PullRefreshState?
    func body(content: Content) -> some View {
        if on, !title.isEmpty {
            content
                .onPreferenceChange(PullRefreshKey.self) { pullBelow = $0.state }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        // Its whole width: squeezed by the trailing group on a phone it read "Ch…".
                        HStack(spacing: 0) {
                            Text(title).font(.headline).fixedSize().accessibilityAddTraits(.isHeader)
                            PullRefreshWheel(fromBelow: pullBelow)
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
        } else {
            content
        }
    }
}

extension View {
    func pullRefresh(ownWheel: Bool = false, _ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(PullRefresh(action: action, ownWheel: ownWheel))
    }
    func pageHeading(_ title: String, on: Bool = true) -> some View { modifier(PageHeading(title: title, on: on)) }
}
#endif
