#if os(iOS)
import SwiftUI
import VoryCore

// Morph prototype, option A proper (`-vory-morph-root`): the top controls of
// the Chats list and of an open chat are drawn here, over the pages and outside every
// NavigationStack, as three persistent glass capsules in ONE GlassEffectContainer. Each capsule
// is drawn at the frame interpolated by `t` between its two measured end states (0 the chat's
// controls, 1 the list's), its contents cross-fading, so a swipe back scrubs the morph with
// the finger (Matt, 2026-10-12: "follow the finger") and a push, a Back button or a release
// animate the same `t`. Reduce Motion: a cross-fade between the two sets, no interpolation.
// Visual apart from Back; nothing here runs without the flag.

/// A control's place in the bar: the leading circle, the middle capsule, the trailing one; and, on the closed Duo, a
/// chat's Back and More in the status column under the time and Wi-Fi (#542), which only a chat has.
enum MorphSlot: Hashable, CaseIterable {
    case lead, mid, trail, columnBack, columnMore
    var inColumn: Bool { self == .columnBack || self == .columnMore }
}

/// What a root page keeps in the bar's leading and trailing slots (the middle is its title).
/// A tab switch morphs one page's set into the next; a slot a page does not have fades.
enum TabLead { case botMenu, filesHome }
enum TabTrail { case chatActions, plus(String), filesActions, boardActions, sessionsOptions }
@MainActor func tabChrome(_ tab: AppModel.AppTab) -> (lead: TabLead?, trail: TabTrail?) {
    switch tab {
    case .chats: (.botMenu, .chatActions)
    // No New bot in the demo (#494): its look editor wrote the person's own bot's look.
    case .bots: (nil, AppModel.shared.isInDemo ? nil : .plus("New bot"))
    case .files: (.filesHome, .filesActions)
    case .projects: (nil, .plus("Add project"))
    case .kanban: (nil, .boardActions)
    case .sessions: (nil, .sessionsOptions)
    // Only where the gateway in use can make a task (#428): none rather than one that can't work.
    case .cron: (nil, CronCreateSupport.shared.onActiveGateway ? .plus("Add scheduled task") : nil)
    default: (nil, nil)
    }
}

/// A pushed page's own control, drawn by the bar in its trailing capsule as the page comes in (#435): it
/// arrives in the one morph with the Back circle, where the page's own bar item came in by UIKit's
/// cross-fade a beat after the slide (Matt on 27: "a second animation"). A button, or a menu of buttons.
struct MorphPageAction: Identifiable {
    struct Item { var label: String; var symbol: String; var action: () -> Void }
    /// Its accessibility identifier.
    var id: String
    var symbol: String
    var label: String
    var enabled = true
    /// A menu's items; none for a plain button.
    var menu: [Item] = []
    var action: () -> Void = {}
    /// What the bar redraws on: the controls and whether they are on.
    var signature: String { "\(id)|\(enabled)|\(menu.map(\.label).joined(separator: ","))" }
}

extension View {
    /// The page's own controls for the morph bar while the page is up on its tab (#435); `on` where the
    /// bar draws them (a page pushed under it), and the page keeps its own bar items everywhere else.
    func morphPageActions(_ actions: [MorphPageAction], on: Bool) -> some View {
        modifier(MorphPageActions(actions: actions, on: on))
    }
}

private struct MorphPageActions: ViewModifier {
    @Environment(AppModel.self) private var model
    var actions: [MorphPageAction]
    var on: Bool
    @State private var token = UUID()
    @State private var tab: AppModel.AppTab?
    private func declare() {
        let state = MorphState.shared
        if on {
            let tab = self.tab ?? model.selectedTab
            self.tab = tab
            state.pageActions[tab] = .init(token: token, actions: actions)
        } else if let tab, state.pageActions[tab]?.token == token {
            state.pageActions[tab] = nil
        }
    }
    func body(content: Content) -> some View {
        content
            // At the push's start (the page's appearance), so the bar morphs the controls in with its Back.
            .onAppear { declare() }
            .onChange(of: on) { _, _ in declare() }
            .onChange(of: actions.map(\.signature)) { _, _ in declare() }
            .onDisappear {
                if let tab, MorphState.shared.pageActions[tab]?.token == token { MorphState.shared.pageActions[tab] = nil }
            }
    }
}

/// The morph's state: which chat (if any) the chat end state is for, and how far along the
/// list end state the capsules are. Scrubbed by RootView's FullScreenPop handler; animated by
/// the push, the Back button and the release.
@MainActor @Observable final class MorphState {
    static let shared = MorphState()
    var chat: ChatSession?
    /// A page pushed on a tab other than Chats: the title capsule becomes its Back (Matt,
    /// 2026-10-12: "it should morph into the back arrow on all pages and then morph back").
    var pushedTab: AppModel.AppTab?
    /// The tabs other than Chats with a page pushed, kept by their roots' probes whether or not
    /// the bar is up: a tab switch, or the bar's return after the window widened and narrowed
    /// again, finds the right state at once (`showTab`).
    @ObservationIgnored var pushedTabs: Set<AppModel.AppTab> = []
    /// A chat's page is up on Chats without its chat yet (it shows "Opening…"): the bar is away
    /// as over a page pushed on another tab, its title capsule the Back, until the chat comes and
    /// its controls form. Stepped aside there, the bar left the page with no Back and showed
    /// empty glass as the page came in (the frame check's BLANK and LONE runs at a cold push).
    var opening = false
    /// Up in the band, a chat's opening holds the list's side capsules until the chat comes, for `holdLimit` at
    /// most: a slow or failed load ("Opening…", "Could not open chat") lets them go as before, so the list's controls
    /// never stand untappable for long. Set by `open()`, cleared by a timer of that opening only.
    var holdingSides = false
    static let holdLimit: TimeInterval = 0.6
    /// The opening whose hold the timer may end (a later opening has its own).
    @ObservationIgnored private var holdToken = 0
    /// Away from a root page: a chat or a pushed page is up (or on its way).
    var away: Bool { chat != nil || pushedTab != nil || opening }
    /// 0 = the chat's (or the pushed page's) controls, 1 = the root page's. The value the bar
    /// is heading for: the bar draws the animated one (`MorphProgress`), so a transition that
    /// starts mid-flight carries on from where the bar is, with its speed.
    var t: CGFloat = 1
    /// Bumped by every transition that starts: a transition settles (`settleOnRoot`, a pop's or
    /// a release's end) only while it is still the latest. Settled on a timer, an earlier pop's
    /// settle landed inside the next push and took its chat away (Matt on 1.5 (21): in and out
    /// of a chat quickly left the Back circle alone, or no controls at all).
    @ObservationIgnored private var generation = 0
    /// The finger has the pop: `t` follows it and nothing is tappable.
    var scrubbing = false
    /// The bottom of the root page's row of controls (the bot circle, the title, the page's own) in the bar's space
    /// (`.named("morph")`, whose top is the bar's padding under the safe area's top). Where the system's bars stand in a
    /// side strip (the closed iPhone Duo) nothing else keeps a band for the row, and the root pages start under it by
    /// this much (`TopBarRoom`, #340). Kept, not cleared, over a chat or a pushed page, so a root page coming back has
    /// its room at once.
    var rootRowBottom: CGFloat = 0
    /// The bottom of a chat's row (Back, the title pill, More) in the bar's space, for what may grow up under it (the
    /// + panel's cap, `AttachPanel.room`).
    var chatRowBottom: CGFloat = 0
    /// A swipe back to a tab's root page is under way (its root probe saw it start). Only that
    /// swipe, or a chat's, is the bar's to follow: a swipe from a page three deep back to the one
    /// under it moved the bar to the root's title and left it there, over a page still pushed
    /// (the full-screen pan reports every swipe, whatever its depth).
    @ObservationIgnored var rootPopInFlight = false
    /// The tabs whose page in front keeps its own bar: a form with its own Cancel, Done or Save
    /// (`.pushedPage(keepsOwnBar: true)`), or a page pushed from one. The bar steps aside there,
    /// as it does over a group chat on Chats: the morph Back stood over Edit Gateway's Cancel
    /// (Matt on 1.5 (18): "the formatting is off in the add a gateway"). Kept by the tabs' root
    /// probes; the bar's own state under it is left as it was, so it comes back as it went.
    var ownBarTabs: Set<AppModel.AppTab> = []
    /// The controls of the page in front on each tab, declared by a page pushed under the bar
    /// (`morphPageActions`); its token keeps a page that left from taking away the next one's.
    struct PageActions { var token: UUID; var actions: [MorphPageAction] }
    var pageActions: [AppModel.AppTab: PageActions] = [:]
    /// `-vory-ownbar-off` puts the bar's Back over
    /// those pages again, as in (18) and (19).
    static let ownBarOff = ProcessInfo.processInfo.arguments.contains("-vory-ownbar-off")

    /// The Chats stack, handed over by its root (`ChatsStackProbe`): a chat's push and pop there
    /// are followed frame by frame, the page's own slide being the bar's progress. Timed on a
    /// spring of its own, the bar ran apart from the page whenever UIKit turned a transition
    /// around (a quick in and out): both sets half drawn over each other (Matt on 1.5 (21)).
    @ObservationIgnored weak var chatsNav: UINavigationController?
    /// The bar's progress as the page's slide puts it, while a push or a pop is followed. The bar
    /// draws this; `t` keeps where it is heading, which decides the taps.
    var followed: CGFloat?
    @ObservationIgnored private var followLink: CADisplayLink?
    @ObservationIgnored private let followTicker = FollowTicker()
    /// The transition has been seen moving; frames without one before it count down a grace.
    @ObservationIgnored private var followSeen = false
    @ObservationIgnored private var followIdle = 0
    /// `-vory-morph-timed`: the Chats morph on its own spring again, as in 1.5 (22), to compare.
    static let follows = !ProcessInfo.processInfo.arguments.contains("-vory-morph-timed")

    func push(_ c: ChatSession) {
        // The chat under a chat being swiped away comes into view as the swipe starts: it takes the bar once the finger
        // lets go and the swipe goes through. Taken at once, a swipe called off left it over the chat still on top,
        // whose Back then went to it (#448).
        if chat != nil, chat !== c, let tc = chatsNav?.transitionCoordinator, tc.isInteractive, chatBelow {
            tc.notifyWhenInteractionChanges { [weak self] ctx in
                guard let self, !ctx.isCancelled, self.chat !== c else { return }
                self.push(c)
            }
            return
        }
        generation += 1
        // The chat came to a page already in (it was opening): its controls form from the Back.
        if opening, followed == nil, t <= 0 {
            withAnimation(.snappy(duration: 0.22)) { chat = c; opening = false; pushedTab = nil }
            return
        }
        chat = c; pushedTab = nil; opening = false
        // With the page, in the same update. The bar draws every frame from its progress, so the
        // chat's end frames, measured a layout later, are taken up on the way (the first frames
        // are still at the list's). Started a turn later, the list's own search row went with the
        // page while the bar stood still (Matt on 1.5 (21): a partial bar at each push).
        // Heading for the chat already (a push followed since the page opened): nothing to start.
        guard !scrubbing, t > 0 else { return }
        if !follow(to: 0) { toAway() }
    }
    /// A chat's page is coming in on Chats before its chat is there: the bar goes with it.
    func open() {
        guard chat == nil, !scrubbing else { return }
        generation += 1
        opening = true; pushedTab = nil
        holdToken += 1; holdingSides = true
        let h = holdToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdLimit) { [weak self] in
            guard let self, self.holdToken == h else { return }
            self.holdingSides = false
        }
        guard t > 0 else { return }
        if !follow(to: 0) { toAway() }
    }
    /// The page that came in is a group chat, which keeps its own header: the bar steps aside
    /// (and is at the list's state when it comes back).
    func roomShown() {
        guard chat == nil, opening else { return }
        endFollow()
        var tr = Transaction(); tr.disablesAnimations = true
        withTransaction(tr) { opening = false; t = 1 }
    }
    func pushPage(_ tab: AppModel.AppTab) {
        guard chat == nil else { return }
        generation += 1
        // The page and its morph in one transaction: set apart, the bar went over to the pushed
        // page unanimated and jumped to the Back circle in one frame while the page slid (in (17)
        // too), where the pop morphs back over its slide (Matt on 18: "the reverse of going out").
        if UIAccessibility.isReduceMotionEnabled { withAnimation(.easeInOut(duration: 0.2)) { pushedTab = tab; t = 0 } }
        else { withAnimation(.spring(duration: 0.32, bounce: 0)) { pushedTab = tab; t = 0 } }
    }
    private func toAway() {
        if UIAccessibility.isReduceMotionEnabled { withAnimation(.easeInOut(duration: 0.2)) { t = 0 } }
        // Quick, as the system's own glass morphs are (Matt, 2026-10-12: "too slow").
        else { withAnimation(.spring(duration: 0.32, bounce: 0)) { t = 0 } }
    }
    private func settleOnRoot() { chat = nil; pushedTab = nil; opening = false }
    /// The tab in front changed, or the bar came back: away over that tab's pushed page, at its
    /// root otherwise. With the capsules' own tab move, not the push's morph: a page pushed on
    /// Settings left its Back standing over Chats. A chat belongs to Chats (`open`, the chat up
    /// there): on another tab the bar is that tab's, even while a chat is still closing (a chat
    /// composed from a pushed page closes back onto it), and back on Chats the chat's returns.
    func showTab(_ tab: AppModel.AppTab, chat open: ChatSession?, opening opens: Bool = false) {
        guard !scrubbing else { return }
        endFollow()
        generation += 1
        let g = generation
        if let open {
            // The tab move (0.22 s) like any other tab switch, not the push's 0.32 s morph; on the
            // next turn, so a chat set just now has its end state measured first (push's reason).
            pushedTab = nil
            if chat !== open { chat = open }
            guard t != 0 else { return }
            Perf.stamp("bar: Chats with a chat up, the tab move")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == g, self.chat === open, !self.scrubbing, self.t != 0 else { return }
                withAnimation(.snappy(duration: 0.22)) { self.t = 0 }
            }
            return
        }
        let pushed = pushedTabs.contains(tab)
        // Chats with a chat's page up whose chat is not there yet: away, with its Back.
        let awayHere = pushed || opens
        guard chat != nil || pushedTab != (pushed ? tab : nil) || opening != opens || t != (awayHere ? 0 : 1) else { return }
        withAnimation(.snappy(duration: 0.22)) {
            chat = nil
            opening = opens
            holdingSides = false
            pushedTab = pushed ? tab : nil
            t = awayHere ? 0 : 1
        }
    }
    /// A chat is under the one going back: a Bot Chat opened from a "Messaged X" notice sits over the chat it came
    /// from. The swipe back from it ends on that chat, not on the list, so the bar stays a chat's and the chat
    /// underneath takes it as it comes in (`push`, from the chat in front changing), as Back does. Followed as a pop to
    /// the list, the bar headed for the list's look and settled there, its chat gone, over the chat still up: no
    /// Back, no pill, no ⋯ (#448). The Chats stack says it, in two ways for two moments, and neither does alone: while
    /// a pop runs, where it is going, from the transition itself (the stack's list then already reads as if the pop
    /// had happened, which a swipe called off undoes); with none running, what the stack holds (a flick that has
    /// already popped, a pan that never did), where there is no transition to ask.
    private var chatBelow: Bool {
        guard chat != nil, let nav = chatsNav else { return false }
        if let to = nav.transitionCoordinator?.viewController(forKey: .to) { return to !== nav.viewControllers.first }
        return nav.viewControllers.count > 1
    }
    func scrub(_ fraction: CGFloat) {
        guard away, chat != nil || opening || rootPopInFlight else { return }
        if chatBelow { return }
        if !scrubbing { generation += 1; endFollow() }
        scrubbing = true
        if UIAccessibility.isReduceMotionEnabled { withAnimation(.easeInOut(duration: 0.2)) { t = fraction >= 0.5 ? 1 : 0 } }
        else { var tr = Transaction(); tr.disablesAnimations = true; withTransaction(tr) { t = fraction } }
    }
    /// The swipe let go: finish to the list (fraction 1) or back to the chat (0) over what is
    /// left of the transition.
    func release(_ fraction: CGFloat, over duration: Double) {
        guard away, chat != nil || opening || rootPopInFlight else { return }
        // Back to the chat underneath (or a swipe from the one on top called off): a chat's bar either way (#448).
        if chatBelow {
            scrubbing = false
            if t != 0 { generation += 1; withAnimation(.spring(duration: 0.2, bounce: 0)) { t = 0 } }
            return
        }
        scrubbing = false
        // With the page: the bar finishing ahead of the slide made the list's controls land
        // before the list (Matt, 2026-10-12: "the nav bar reappears weirdly").
        let d = min(0.4, max(0.18, duration))
        let end: CGFloat = fraction >= 1 ? 1 : 0
        generation += 1
        let g = generation
        // Settled for certain once the transition is over: a trailing event from the second
        // recognizer (the edge gesture and the full-screen pan both drive the pop) could leave
        // `t` or `scrubbing` part-way, which switched the bar's hit testing off (Back after a
        // cancelled swipe did nothing on the phone). Only while this is still the latest
        // transition: a tab switch (showTab) or a new push has put the bar where it belongs.
        withAnimation(.spring(duration: d, bounce: 0), completionCriteria: .logicallyComplete) { t = end } completion: { [weak self] in
            guard let self, self.generation == g else { return }
            self.scrubbing = false
            if end >= 1 { self.t = 1; self.settleOnRoot() } else if self.away { self.t = 0 }
        }
    }
    /// What the bar is doing, for a diagnostic.
    var debugLine: String { "chat=\(chat?.storedID ?? "nil") pushed=\(pushedTab?.rawValue ?? "nil") opening=\(opening) t=\(t) followed=\(followed.map { "\($0)" } ?? "nil") scrubbing=\(scrubbing)" }
    /// A pop that was not a swipe (the Back button): the timed morph.
    func pop() {
        // Once per pop: a page pushed on another tab reported its pop twice (the transition's
        // start and its completion), each starting the morph again.
        guard away, !scrubbing, t < 1 else { return }
        generation += 1
        if follow(to: 1) { return }
        timedPop()
    }
    private func timedPop() {
        let g = generation
        withAnimation(.spring(duration: 0.32, bounce: 0), completionCriteria: .logicallyComplete) { t = 1 } completion: { [weak self] in
            guard let self, self.generation == g, self.t >= 1 else { return }
            self.settleOnRoot()
        }
    }

    // MARK: Following the Chats stack

    /// Follows the Chats stack's push or pop to `end`, if there is one to follow; false otherwise
    /// (a page pushed on another tab, Reduce Motion, no stack), and the bar times its own morph.
    /// The bar heads for `end` at once (taps go to the set that is coming, and a tap can turn it
    /// around); what it draws is the page's place, from where it stands now.
    private func follow(to end: CGFloat) -> Bool {
        guard Self.follows, !UIAccessibility.isReduceMotionEnabled, chat != nil || opening,
              let nav = chatsNav, nav.view.window != nil else { return false }
        var tr = Transaction(); tr.disablesAnimations = true
        withTransaction(tr) {
            if followed == nil { followed = t }
            t = end
        }
        followSeen = false; followIdle = 0
        if followLink == nil {
            followTicker.tick = { [weak self] in self?.followTick() }
            let l = CADisplayLink(target: followTicker, selector: #selector(FollowTicker.fire))
            l.add(to: .main, forMode: .common)
            followLink = l
        }
        return true
    }

    /// Each frame of a followed transition: the bar is where the chat's page is. Once the stack
    /// is still, the bar settles on it; a transition that never came (a path set without one)
    /// gets the timed morph from where the bar stands.
    private func followTick() {
        guard let nav = chatsNav, nav.view.window != nil, !scrubbing, chat != nil || opening else { endFollow(); return }
        if let c = nav.transitionCoordinator {
            // A finger has it: FullScreenPop scrubs.
            guard !c.isInteractive else { endFollow(); return }
            let root = nav.viewControllers.first
            let to = c.viewController(forKey: .to), from = c.viewController(forKey: .from)
            // The chat's page: coming in on a push, going out on a pop. Not before it is laid out
            // in its place (its first frame reads half a width off to the left).
            let rtl = nav.view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            guard let page = to !== root ? to : from, page !== root, abs(page.view.frame.minX) < 1,
                  let x = Self.slide(of: page.view, in: nav.view).map({ rtl ? -$0 : $0 }), x > -0.01 else { return }
            followSeen = true; followIdle = 0
            var tr = Transaction(); tr.disablesAnimations = true
            withTransaction(tr) { followed = min(1, max(0, x)) }
            return
        }
        followIdle += 1
        // The push or the pop starts on a turn after the bar heard of it: a few frames' grace.
        guard followSeen || followIdle > 3 else { return }
        let end: CGFloat = nav.viewControllers.count > 1 ? 0 : 1
        let seen = followSeen
        followLink?.invalidate(); followLink = nil
        var tr = Transaction(); tr.disablesAnimations = true
        if seen {
            withTransaction(tr) {
                followed = nil
                t = end
                if end >= 1 { settleOnRoot() }
            }
        } else {
            withTransaction(tr) { t = followed ?? t; followed = nil }
            if end >= 1 { timedPop() } else { toAway() }
        }
    }

    /// Stops following and leaves the bar where it is drawn (`t` takes the place it was at).
    private func endFollow() {
        followLink?.invalidate(); followLink = nil
        guard let f = followed else { return }
        var tr = Transaction(); tr.disablesAnimations = true
        withTransaction(tr) { t = f; followed = nil }
    }

    /// Where a page of the stack is on screen, as a fraction of the stack's width (0 in place, 1
    /// off the trailing edge), read through the presentation layers: the transition slides a
    /// wrapper around the page, whose own frame stays at 0.
    static func slide(of v: UIView, in root: UIView) -> CGFloat? {
        var p = CGPoint.zero
        var layer: CALayer? = v.layer
        while let l = layer, l !== root.layer {
            let shown = l.presentation() ?? l
            p = shown.convert(p, to: shown.superlayer)
            layer = l.superlayer
        }
        guard layer != nil else { return nil }
        return p.x / max(1, root.bounds.width)
    }
}

/// The display link's target (it must be an object of Objective-C's).
@MainActor private final class FollowTicker: NSObject {
    var tick: () -> Void = {}
    @objc func fire() { tick() }
}

/// Under the Chats list in its own stack (a phone, the closed Duo): hands the stack to the bar,
/// which follows a chat's push and pop in it frame by frame (`MorphState.follow`).
struct ChatsStackProbe: UIViewRepresentable {
    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var r: UIResponder? = self
            while let n = r {
                if let vc = n as? UIViewController { if let nav = vc.navigationController { MorphState.shared.chatsNav = nav }; return }
                r = n.next
            }
        }
    }
    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.isUserInteractionEnabled = false
        v.isAccessibilityElement = false
        v.accessibilityElementsHidden = true
        return v
    }
    func updateUIView(_ v: Probe, context: Context) {}
}

struct MorphTopBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// At the accessibility sizes the bar's type is capped and a long press shows the Large
    /// Content Viewer instead, so the pill's long-press menu steps aside (its items are in …).
    @Environment(\.dynamicTypeSize) private var typeSize
    private var axSize: Bool { typeSize.isAccessibilitySize }
    /// The open Duo upright (#516): the bar stands this much higher, in the status band (`TopBarRoom.barUp`); 0 elsewhere.
    @Environment(\.barLift) private var lift
    /// The bar's inset from the window's sides.
    static let sideInset: CGFloat = 16
    /// Up in the band, every row (a root's, a pushed page's, a chat's) ends short of the status (`TopBarRoom.statusReserve`,
    /// from the window's trailing edge).
    private var statusClear: CGFloat { lift > 0 ? TopBarRoom.statusReserve - Self.sideInset : 0 }
    /// The bar up in the status band (the open Duo upright, or half open like a laptop): a chat's row stands in it too.
    private var inBand: Bool { lift > 0 }
    /// Between Back and the face, up in the band.
    static let faceGap: CGFloat = 8
    @Environment(\.windowGeometry) private var windowGeometry
    /// The closed Duo: the system's bars stand in a status strip at the window's side (`VoryTabBar.statusStrip`).
    private var stripClosed: Bool {
        model.tabBarVertical && VoryTabBar.statusStrip(windowGeometry.safeArea) != nil
    }
    /// A chat's bar like Messages' on the Duo (Matt, 2026-10-28, #542): no pill. Up in the band, Back, the face with no
    /// glass behind it (as a contact's photo is), then the bot's name and the chat's title as plain text, and More. Closed, the face and the
    /// name at the top left, and Back and More in the status column (`columnFrame`). Elsewhere (a phone, an iPad) the pill
    /// with the face seated on it, as before.
    private var messagesBar: Bool { inBand || stripClosed }
    /// The slot whose place the face stands in: the title capsule's up in the band, the bot circle's when closed. It keeps
    /// its frame through the morph and draws no glass while a chat shows (`CapsuleFrame.bare`).
    private var faceSlot: MorphSlot { stripClosed && !inBand ? .lead : .mid }
    /// The bot's name and the chat's title, as laid out beside the face (the bar's space).
    @State private var nameFrame: CGRect = .zero
    /// A chat's band, like Messages' (`ChatBand`): from the window's top to a quarter of the face under the row; closed,
    /// not down the status column, where Back and More stand on their own glass. It comes in with the chat. Drawn behind
    /// the bar, from the bar's own top-left (the safe area's), out to the window's edges.
    @ViewBuilder private var chatBand: some View {
        if messagesBar, state.chat != nil, let lead = chatFrames[.lead] {
            let g = windowGeometry
            let top = g.safeArea.top + TopBarRoom.barPadding
            ChatBand(width: g.bounds.width, bottom: top + max(lead.maxY, nameFrame.maxY) + ChatBand.below)
                .offset(x: -g.safeArea.leading, y: -g.safeArea.top)
                .opacity(Double(max(0, 1 - shown * 2.4)))
        }
    }
    /// Which slots a chat's state has.
    private func chatHas(_ slot: MorphSlot) -> Bool {
        switch slot {
        case .lead: return true
        case .mid, .trail: return !(stripClosed && !inBand)
        case .columnBack, .columnMore: return stripClosed && !inBand
        }
    }
    /// A chat's Back or More in the closed Duo's status column, in the bar's space: 44 pt, centred
    /// `VoryTabBar.stripCentreFromEdge` from the window's edge on the strip's side, its top where UIKit's own navigation
    /// items stand under the time and Wi-Fi (`TopBarRoom.statusColumnTops`). The bar's space starts at the safe area's
    /// leading edge and top, inside the bar's side inset and padding.
    private func columnFrame(_ slot: MorphSlot) -> CGRect? {
        guard slot.inColumn, stripClosed, !inBand else { return nil }
        let g = windowGeometry, tops = TopBarRoom.statusColumnTops(closed: true)
        let onTrailing = g.safeArea.trailing >= g.safeArea.leading
        let centreX = onTrailing ? g.bounds.width - VoryTabBar.stripCentreFromEdge : VoryTabBar.stripCentreFromEdge
        return CGRect(x: centreX - 22 - g.safeArea.leading - Self.sideInset, y: (slot == .columnBack ? tops[0] : tops[1]) - g.safeArea.top - TopBarRoom.barPadding,
                      width: 44, height: 44)
    }
    /// On by default (Matt, 2026-10-12: "the morphing is perfect"); `-vory-morph-off` brings the
    /// shipped chrome back for a comparison.
    static var on: Bool { !ProcessInfo.processInfo.arguments.contains("-vory-morph-off") }
    /// The bar runs where a chat pushes over the list (a phone, the closed Duo's strip): that is
    /// the only place a morph exists. On a wide window (iPad, the open Duo) the list and the
    /// chat stand in their own columns with the shipped chrome, each over its column.
    static func active(_ model: AppModel) -> Bool { on && !model.wideLayout }
    /// The pages swap at once on a tab switch while the bar morphs (Matt's pick, "Instant
    /// swap", 2026-10-12); `-vory-morph-fade` keeps the old cross-fade for a comparison.
    static var cutsPages: Bool { on && !ProcessInfo.processInfo.arguments.contains("-vory-morph-fade") }
    private var state: MorphState { MorphState.shared }
    /// The bots' stored looks, read so the seated face follows a shape change.
    @AppStorage(BotAvatarStore.storageKey) private var avatarsRaw = ""
    /// The list's title capsule: one height on every tab, scaled with the headline.
    @ScaledMetric(relativeTo: .headline) private var titleHeight: CGFloat = 38
    /// The two end states' capsule frames, measured from invisible copies laid out underneath.
    @State private var chatFrames: [MorphSlot: CGRect] = [:]
    /// A pushed page's end state (its Back circle), kept apart from a chat's.
    @State private var pageFrames: [MorphSlot: CGRect] = [:]
    @State private var listFrames: [MorphSlot: CGRect] = [:]
    /// Where a slot last was, so a page without it can fade its capsule out in place.
    @State private var lastListFrames: [MorphSlot: CGRect] = [:]

    /// The bar's progress as drawn this frame (`MorphProgress`): frames, opacities and which
    /// set is mounted follow it, so a push or a pop that starts mid-flight carries on from the
    /// frame on screen. Read from the state's target, every frame started from an end state:
    /// the outgoing set was taken down and the incoming one put up at the start, and a quick
    /// in and out showed both sets half drawn, empty capsules or no controls (Matt on 1.5 (21)).
    @Environment(\.morphProgress) private var drawn
    private var t: CGFloat { state.away ? drawn : 1 }
    /// Where the bar is heading: which set takes taps and which slots are there follow it, so a
    /// tap mid-flight lands on the set that is coming (and can turn the bar around).
    private var target: CGFloat { state.away ? state.t : 1 }
    /// The away state's frames: the chat's, or a pushed page's.
    private var awayFrames: [MorphSlot: CGRect] { state.chat != nil ? chatFrames : pageFrames }
    private var settled: Bool { target <= 0 || target >= 1 }
    /// Where the outgoing set has faded out (`1 - shown * 2.4`) and the incoming one starts: one
    /// control at a time in each capsule, the next one coming in as the last is gone. A gap
    /// between them (the list's set came in from the half) drew empty glass at every switch.
    static let handoff: CGFloat = 1 / 2.4
    /// Reduce Motion: the two sets cross-fade at the halfway point instead of interpolating.
    private var shown: CGFloat { reduceMotion ? (t < 0.5 ? 0 : 1) : t }
    private var shownTarget: CGFloat { reduceMotion ? (target < 0.5 ? 0 : 1) : target }

    var body: some View {
        let _ = Perf.tick("morphbar-body")
        GlassEffectContainer(spacing: 10) {
            ZStack(alignment: .topLeading) {
                // The end states, for their frames only. Up in the status band (the open Duo upright) the whole bar
                // stands `lift` higher, a chat's row with it (like Messages, #542), so nothing travels between the list and
                // a chat.
                listLayout.padding(.trailing, statusClear).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                if let chat = state.chat { chatLayout(chat).padding(.trailing, statusClear).opacity(0).allowsHitTesting(false).accessibilityHidden(true) }
                // A pushed page's end state is the same on every page: laid out always, so the
                // first push already knows where its Back goes.
                pushedLayout.padding(.trailing, statusClear).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                // The capsules that are seen, one per slot, at the frame between the two.
                ForEach(MorphSlot.allCases, id: \.self) { slot in capsule(slot) }
            }
            .coordinateSpace(.named("morph"))
            .padding(.horizontal, Self.sideInset).padding(.top, TopBarRoom.barPadding)
        }
        // The seated face rides above the middle capsule in the chat state: outside the glass
        // container, which composites its glass over anything drawn inside it (the face sat
        // behind its pill, Matt 2026-10-12). Same inset as the measured space.
        .overlay(alignment: .topLeading) {
            if let chat = state.chat, messagesBar, let a = chatFrames[faceSlot] {
                // Like Messages (#542): the face on its slot's glass, then the name as plain text, one Chat info button
                // over both. The name comes in as the morph lands, where it stays.
                let circle = lerp(a, listFrames[faceSlot] ?? lastListFrames[faceSlot] ?? a, shown)
                ZStack(alignment: .topLeading) {
                    face(chat, over: circle)
                    #if DEBUG
                    Color.clear.frame(width: 44, height: 44)
                        .modifier(MorphFramesProbe.RecordFace(shown: shown < 0.02))
                        .position(faceCentre(chat, circle)).allowsHitTesting(false)
                    #endif
                    nameButton(chat, face: a)
                        .opacity(Double(max(0, 1 - shown * 2.4)))
                        .allowsHitTesting(shown < 0.02 && !state.scrubbing)
                }
                .padding(.horizontal, Self.sideInset).padding(.top, TopBarRoom.barPadding)
            } else if let chat = state.chat, let a = chatFrames[.mid], let b = listFrames[.mid] {
                let mid = lerp(a, b, shown)
                ZStack(alignment: .topLeading) {
                    face(chat, over: mid)
                    // A tap on the seated face does what a tap on the pill does (#339): Bot info,
                    // and the face reacts. Only with the chat at rest.
                    FaceTapArea { openBotInfo(chat) }
                        .frame(width: 44, height: 44)
                        #if DEBUG
                        .modifier(MorphFramesProbe.RecordFace(shown: shown < 0.02))
                        #endif
                        .position(faceCentre(chat, mid))
                        .allowsHitTesting(shown < 0.02 && !state.scrubbing)
                }
                .padding(.horizontal, Self.sideInset).padding(.top, TopBarRoom.barPadding)
            }
        }
        .background(alignment: .topLeading) { chatBand }
        // Up in the status band on the open Duo upright (0 elsewhere): drawn, hit and read by VoiceOver there.
        .offset(y: -lift)
        // The bar's type stops at XXXL, as the system's own bar does: at the accessibility
        // sizes the three capsules no longer fit one row (the actions ran off the right edge
        // and the pill hid the circles, AX3 on the simulator).
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        // Taps reach the controls at rest only; mid-scrub they go nowhere. The bar stays a
        // container for accessibility throughout: hiding and showing it around a scrub made
        // the system fold the Back button into one element the width of the bar (its frame
        // read 370 pt wide after a cancelled swipe, and a tap at its centre hit the pill).
        .allowsHitTesting(settled && !state.scrubbing)
        .accessibilityElement(children: .contain)
        // With a chat shown it is the chat's header for the UI tests (ThreadLayoutUITests
        // measures the thread's first row against the header's bottom).
        .accessibilityIdentifier(state.chat != nil ? "chat.header" : "morph.bar")
        .onChange(of: model.chatsPathOpen) { _, open in
            if open, let c = model.visibleChat { state.push(c) }
            // A chat whose page comes in before its chat (and, for a frame, a group chat, which
            // then steps the bar aside: `roomShown`).
            else if open, model.roomsOnScreen == 0 { state.open() }
            // Also before the push's morph has begun: the pop turns it back (it starts on the
            // next turn), where waiting for it left the chat's controls over the list.
            else if !open, state.chat != nil || state.opening, !state.scrubbing { state.pop() }
        }
        .onChange(of: model.roomsOnScreen) { _, n in if n > 0, model.chatsPathOpen { state.roomShown() } }
        // The root row's bottom for the pages under it (#340): from the root row's own frames only, never mid-scrub
        // (the row's height doesn't change while `t` moves).
        .onChange(of: listFrames, initial: true) { _, f in
            guard !state.scrubbing else { return }
            let bottom = f.values.map(\.maxY).max() ?? 0
            if abs(bottom - state.rootRowBottom) > 0.5 { state.rootRowBottom = bottom }
        }
        .onChange(of: chatFrames, initial: true) { _, f in
            guard !state.scrubbing else { return }
            // Like Messages on the Duo, the thread starts under the chat's band, not under its row (Matt, 2026-10-28).
            let bottom = (f.values.map(\.maxY).max() ?? 0) + (messagesBar ? ChatBand.reach : 0)
            if bottom > 0, abs(bottom - state.chatRowBottom) > 0.5 { state.chatRowBottom = bottom }
        }
        // Initial too: the bar is made afresh when a wide window narrows again.
        .onChange(of: model.selectedTab, initial: true) { _, tab in
            let chats = tab == .chats && model.chatsPathOpen
            state.showTab(tab, chat: chats ? model.visibleChat : nil,
                          opening: chats && model.visibleChat == nil && model.roomsOnScreen == 0)
        }
        .onChange(of: model.visibleChat?.storedID) { _, id in
            // The chat lands a beat after the path opens on a fresh push. And the chat in front
            // can change with the path still open: a Bot Chat opened from a "Messaged X" notice
            // sits over the chat it came from, and back from it that chat is in front again. The
            // bar is the one in front's: kept on the chat underneath, its Back reached that chat
            // and took both pages away (#346, Matt on 1.5 (23): Back went to the list). The Chats
            // tab's own only: with a chat left open on Chats (the Overview widget's link goes to
            // Home and leaves it there), a chat pushed on another tab's stack (from a bot's page or
            // its compose) took the bar, and after its Back the chat's bar stayed over the page
            // (#386). On another tab a chat gets the page's own Back.
            if id != nil, model.chatsPathOpen, model.selectedTab == .chats, let c = model.visibleChat, state.chat !== c { state.push(c) }
        }
    }

    // MARK: The capsules

    @ViewBuilder private func capsule(_ slot: MorphSlot) -> some View {
        // Whether this page (or the chat) has the slot at all: from the page's chrome, not from
        // the measured frames (a slot that went away left a faint empty capsule on Settings).
        let chrome = tabChrome(model.selectedTab)
        let pageHas = !slot.inColumn && (slot == .mid || (slot == .lead ? chrome.lead != nil : chrome.trail != nil))
        // Over a group chat on Chats the bar steps aside: that page keeps its own header.
        // Inside the glass container neither a capsule's opacity nor a transition is
        // honoured, so there is no capsule at all there. A page pushed on another tab is an
        // "away" state like a chat: the title capsule becomes its Back and the others go.
        // So does it over a page that keeps its own bar (a form with its Cancel and Save).
        // A chat's page whose chat is not there yet is away, with its Back (`opening`).
        let pushedAway = (model.selectedTab == .chats && model.chatsPathOpen && state.chat == nil && !state.opening) || state.ownBarTabs.contains(model.selectedTab)
        // Up in the band (the open Duo upright), a chat's page that opens before its chat is there keeps the list's side
        // capsules standing, their controls in them, until the chat comes (for `MorphState.holdLimit` at most); then they
        // turn into Back and More level with the row. Gone at once, they grew back from nothing as the chat came: 22 pt of
        // travel in the band (#516).
        // Closed too (#542): there the bot circle becomes the face's, in the same place.
        let holdSides = messagesBar && state.opening && state.holdingSides && state.chat == nil && state.pushedTab == nil && (slot == .lead || slot == .trail)
        // A chat has its own slots (`chatHas`): closed, its Back and More stand in the status column and the list's title
        // and trailing capsules go where they are; nothing moves from one place to another (#542).
        let awayHas = state.chat != nil ? chatHas(slot) : (holdSides ? true : (state.pushedTab != nil || state.opening ? slot == .mid || (slot == .trail && pushedActions != nil) : pageHas))
        let present = !pushedAway && (shownTarget < 0.5 ? awayHas : pageHas)
        // Going away (a page pushed on another tab), a slot the away state does not have goes at
        // once, at the push's start: its glass cannot fade inside the container, and shrinking
        // it with the morph left the Bots + standing beside the Back as it formed (Matt on 1.5
        // (17): "the back button leave behind a trail button once in the new window"). It comes
        // back with the usual move; a tab switch still shrinks it where it was.
        let goesAtOnce = !present && state.away
        if pushedAway {
            EmptyView()
        } else if let b = slot.inColumn ? columnFrame(slot) : (listFrames[slot] ?? lastListFrames[slot] ?? awayFrames[slot]) {
            // A status-column slot stands where it is: it grows there as a chat comes and shrinks there as it goes.
            let f = slot.inColumn ? b : (awayHas ? awayFrames[slot] : nil).map { lerp($0, listFrames[slot] ?? lastListFrames[slot] ?? $0, shown) } ?? b
            ZStack {
                // Only the state that is showing takes taps: the other sits in the stack at
                // opacity 0 and would otherwise cover it (the Back tap went nowhere).
                // Each set is seen alone: the outgoing one is gone by a third of the way and the
                // incoming one arrives past the half, so the capsule carries one control at a
                // time instead of two half-faded over each other (Matt, 2026-10-12, against the
                // Claude app's morph: crisp, each element fading in place).
                // Settled, only the shown set is mounted: a menu's label in the glass kept a
                // ghost of the other set at opacity 0 (the list's bot chip behind Back, the
                // list's icons behind …; Matt, 2026-10-12).
                // These are functions of the frame drawn (`shown`), not of where the bar is
                // heading: from the end values a push or a pop faded both sets across the whole
                // morph, two half-drawn sets over each other, and a quick in and out restarted
                // them from nothing (Matt on 1.5 (21)).
                // Both sets are up for the whole flight, put up and taken down only where their
                // opacity is 0 and with no transition of their own (a fade in on top of the one
                // here would lag it).
                if shown < 1 {
                    if let chat = state.chat, chatHas(slot) { chatContent(slot, chat).opacity(Double(max(0, 1 - shown * 2.4))).allowsHitTesting(shownTarget < 0.5).transition(.identity) }
                    else if let tab = state.pushedTab ?? (state.opening ? .chats : nil), slot == .mid { pageBack(tab).opacity(Double(max(0, 1 - shown * 2.4))).allowsHitTesting(shownTarget < 0.5).transition(.identity) }
                    else if slot == .trail, let acts = pushedActions { pageActionButtons(acts).opacity(Double(max(0, 1 - shown * 2.4))).allowsHitTesting(shownTarget < 0.5).transition(.identity) }
                }
                // Keyed by tab, so a tab switch cross-fades one page's control into the next's (at
                // a root page only; going away or back the opacity here does it).
                // A side held through a chat's opening keeps the list's control in it, seen, until the chat comes.
                if shown > 0 || holdSides { listContent(slot).id(model.selectedTab).transition(state.away ? .identity : .opacity).opacity(holdSides ? 1 : Double(max(0, (shown - Self.handoff) * 2.4))).allowsHitTesting(shownTarget >= 0.5 && pageHas) }
            }
            // An absent slot shrinks to nothing where it was: a view's opacity does not fade
            // glass (the + panel taught that), so the capsule also drops its glass there, in
            // the one modifier so its identity holds.
            // Absent on this page: shrunk to nothing where it was (a view's opacity does not
            // fade glass, so the capsule also drops its glass there, in the one modifier).
            .modifier(CapsuleFrame(frame: f, present: present, pull: slot == .mid ? model.pullStates[model.selectedTab] : nil, widen: shown, slot: slot,
                                   inPlace: slot.inColumn, bare: messagesBar && slot == faceSlot && state.chat != nil && shownTarget < 0.5))
            .opacity(present ? 1 : 0)
            .animation(.snappy(duration: 0.22), value: model.selectedTab)
            .animation(.snappy(duration: 0.22), value: selecting)
            .animation(goesAtOnce ? nil : .snappy(duration: 0.22), value: present)
        }
    }

    /// How far the chat's face sits into its pill, from the looks read here, so a shape changed on
    /// the bot's card re-seats the face.
    private func seatDrop(_ chat: ChatSession) -> CGFloat {
        BotFace.seatDrop(BotAvatarStore.choice(for: chat.profileName, overrides: BotLookMaps.map(avatarsRaw)).spec(hex: "").shape)
    }

    /// The pill's action: the face reacts and Bot info opens.
    private func openBotInfo(_ chat: ChatSession) {
        BotAmbient.shared.tap(profile: chat.profileName, session: chat.storedID)
        // Bot info covers the face at once: its own face plays the reaction as it lands.
        BotAmbient.shared.markArrival(profile: chat.profileName)
        model.chatRequest = .init(.profile)
    }

    /// Where the face's middle stands: like Messages on the Duo, in its own slot's place (#542); elsewhere over the pill,
    /// seated on its top (its shape's own seat).
    private func faceCentre(_ chat: ChatSession, _ mid: CGRect) -> CGPoint {
        messagesBar ? CGPoint(x: mid.midX, y: mid.midY) : CGPoint(x: mid.midX, y: mid.minY + 10 - 22 + 44 * seatDrop(chat))
    }

    /// The name beside the face, like Messages' contact (#542): the bot's name, and the chat's title or its step (`ChatNameLines`).
    private func nameText(_ chat: ChatSession) -> some View {
        let label = chat.runtime.profiles.first { $0.name == chat.profileName }?.label ?? chat.profileName
        return ChatNameLines(name: label, line: chat.isRunning ? (chat.statusLine ?? "Thinking…") : (chat.showsSyncing ? "Syncing…" : chat.title))
    }

    /// The face and the name as one button, Chat info, as the pill was (#542): a tap opens Bot info and the face
    /// reacts; a long press offers Rename chat and Bot info, and VoiceOver has both as actions. 44 pt tall at least.
    private func nameButton(_ chat: ChatSession, face a: CGRect) -> some View {
        let r = CGRect(x: a.minX, y: min(a.minY, nameFrame.minY), width: max(a.width, nameFrame.maxX - a.minX),
                       height: max(a.height, nameFrame.height))
        let button = Button { openBotInfo(chat) } label: {
            HStack(spacing: ChatNameLines.faceGap) {
                Color.clear.frame(width: 44, height: 44)   // the face's room: `face` draws it
                nameText(chat)
                    #if DEBUG
                    .modifier(MorphFramesProbe.Mark(key: "name"))
                    #endif
            }
            .frame(width: r.width, height: r.height, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(.plain)
        return Group {
            if axSize {
                button.accessibilityShowsLargeContentViewer { Label(chat.title, systemImage: "person.text.rectangle") }
            } else {
                button.contextMenu {
                    Button { model.chatRequest = .init(.rename) } label: { Label("Rename chat", systemImage: "pencil") }
                    Button { model.chatRequest = .init(.profile) } label: { Label("Bot info", systemImage: "person.text.rectangle") }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chat info: \(chat.title), \(chat.subtitle)")
        .accessibilityAddTraits([.isButton, .isHeader])
        .accessibilityAction { openBotInfo(chat) }
        .accessibilityAction(named: "Rename chat") { model.chatRequest = .init(.rename) }
        .accessibilityAction(named: "Bot info") { model.chatRequest = .init(.profile) }
        .accessibilitySortPriority(2)
        .accessibilityIdentifier("chat.titlePill")
        .position(x: r.midX, y: r.midY)
    }

    private func face(_ chat: ChatSession, over mid: CGRect) -> some View {
        BotAvatar(profile: chat.profileName, size: 44, active: chat.isRunning,
                         mood: BotFaceView.Mood(session: chat.storedID, state: chat.botState))
            .scaleEffect(reduceMotion ? 1 : 0.6 + 0.4 * (1 - t))
            // The face lands last: it is seen only once the pill is nearly in place.
            .opacity(Double(max(0, 1 - shown * 2.4)))
            // Seated on the pill by its base, 10 pt over the top edge plus the shape's own seat:
            // a 44-pt face seated this low lets the row sit 18 pt under the bar's top with the
            // head's top at 50 pt, under the Dynamic Island's edge (Matt, 2026-10-12: the
            // buttons were too far down, the head must stay off the island). Like Messages on
            // the Duo, in its own slot's place instead (`faceCentre`).
            .position(faceCentre(chat, mid))
            .allowsHitTesting(false)
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    @ViewBuilder private func chatContent(_ slot: MorphSlot, _ chat: ChatSession) -> some View {
        switch slot {
        // Like Messages (#542): the face's slot carries nothing (`nameButton` takes its taps, `CapsuleFrame.bare` its glass);
        // closed, Back and More stand in the status column, Back first for VoiceOver.
        case _ where slot == faceSlot && messagesBar:
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        // VoiceOver's order in every posture: Back, Chat info (`nameButton`, 2), More.
        case .columnBack:
            chatContent(.lead, chat, plain: true).accessibilitySortPriority(3)
        case .columnMore:
            chatContent(.trail, chat, plain: true).accessibilitySortPriority(1)
        case .lead where messagesBar:
            chatContent(.lead, chat, plain: true).accessibilitySortPriority(3)
        case .trail where messagesBar:
            chatContent(.trail, chat, plain: true).accessibilitySortPriority(1)
        default:
            chatContent(slot, chat, plain: true)
        }
    }

    /// A chat's own control in a slot, wherever the slot stands: Back, the pill, More.
    @ViewBuilder private func chatContent(_ slot: MorphSlot, _ chat: ChatSession, plain: Bool) -> some View {
        switch slot {
        case .lead, .columnBack:
            Button { model.chatRequest = .init(.back) } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 44, height: 44).contentShape(.circle)
            }
            .buttonStyle(MorphPressStyle(kind: .circle))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Back").accessibilityIdentifier("chat.back").accessibilityAddTraits(.isButton)
            // Activation through accessibility (VoiceOver, XCTest's element tap) did not reach
            // the button on the device; a touch did. The action is offered to both.
            .accessibilityAction { model.chatRequest = .init(.back) }
            .accessibilityShowsLargeContentViewer { Label("Back", systemImage: "chevron.left") }
        case .mid:
            // The face seated over the pill reacts to its tap; a tap on the face itself comes in
            // through FaceTapArea (#339).
            let pill = Button { openBotInfo(chat) } label: { pillText(chat).contentShape(.rect) }
                .buttonStyle(.plain)
            Group {
                if axSize {
                    pill.accessibilityShowsLargeContentViewer { Label(chat.title, systemImage: "person.text.rectangle") }
                } else {
                    pill.contextMenu {
                        Button { model.chatRequest = .init(.rename) } label: { Label("Rename chat", systemImage: "pencil") }
                        Button { model.chatRequest = .init(.profile) } label: { Label("Bot info", systemImage: "person.text.rectangle") }
                    }
                }
            }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Chat info: \(chat.title), \(chat.subtitle)")
                .accessibilityAddTraits([.isButton, .isHeader])
                .accessibilityAction { model.chatRequest = .init(.profile) }
                .accessibilityIdentifier("chat.titlePill")
        case .trail, .columnMore:
            Menu {
                ChatMenuItems(chat: chat, onProfile: { model.chatRequest = .init(.profile) }, onRename: { model.chatRequest = .init(.rename) },
                              onContext: { model.chatRequest = .init(.context) }, onNewChat: { model.chatRequest = .init(.newChat) }, onClose: { model.chatRequest = .init(.close) })
            } label: {
                Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 44, height: 44).contentShape(.circle)
            }
            .menuStyle(.button).buttonStyle(MorphPressStyle(kind: .circle))
            .accessibilityLabel("Chat options")
            .accessibilityShowsLargeContentViewer { Label("Chat options", systemImage: "ellipsis") }
            .accessibilityIdentifier("chat.more")
        }
    }

    /// The Chats list's Select mode, while it is the page on show (#408).
    private var selecting: AppModel.ChatsSelect? { model.selectedTab == .chats ? model.chatsSelect : nil }

    @ViewBuilder private func listContent(_ slot: MorphSlot) -> some View {
        let chrome = tabChrome(model.selectedTab)
        switch slot {
        case .lead:
            if selecting != nil {
                // Select mode's Done, where the bot's circle sits (#408).
                Button { model.chatListRequest = .init(.selectDone) } label: {
                    Text("Done").font(.body.weight(.semibold)).padding(.horizontal, 16).frame(height: 44).contentShape(.capsule)
                }
                .buttonStyle(MorphPressStyle(kind: .icon)).foregroundStyle(.tint)
                .accessibilityIdentifier("chats.select.done")
            } else {
            switch chrome.lead {
            case .botMenu:
                Menu { ChatListProfileItems() } label: {
                    BarFaceCircle(profile: model.listChipProfile ?? "?", size: 26, scheme: scheme)
                        .frame(width: 44, height: 44).contentShape(.circle)
                }
                .menuStyle(.button).buttonStyle(MorphPressStyle(kind: .circle))
                .accessibilityLabel("Profile: \(model.listChipProfile ?? "none")")
                .accessibilityShowsLargeContentViewer { Label("Profile", systemImage: "person.crop.circle") }
                .accessibilityIdentifier("chats.profile")
            case .filesHome:
                circleButton("house", label: "Home", id: "files.home") { model.pageRequest = .init(.filesHome) }
            case nil: EmptyView()
            }
            }
        case .mid:
            HStack(spacing: 0) {
                Text(selecting?.title ?? model.selectedTab.title).font(.headline).fixedSize().accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("morph.title")
                PullRefreshWheel(fromBelow: model.pullStates[model.selectedTab])
            }
        case .trail:
            if let sel = selecting {
                // The selection's actions, where the list's sit; none until a chat is picked.
                trailButtons((sel.canMove ? [("folder", "Move to Project", "chats.select.move", { model.chatListRequest = .init(.selectMove) })] : [])
                             + [("archivebox", "Archive", "chats.select.archive", { model.chatListRequest = .init(.selectArchive) }),
                                ("trash", "Delete", "chats.select.delete", { model.chatListRequest = .init(.selectDelete) })])
                    // The bar's button style does not dim a disabled button: done here.
                    .disabled(!sel.canAct).opacity(sel.canAct ? 1 : 0.35)
            } else {
            switch chrome.trail {
            case .chatActions: liveActions
            case .plus(let label):
                trailButtons([("plus", label, pageRequestID(for: model.selectedTab), { self.plusRequest(for: model.selectedTab) })])
            case .filesActions:
                trailButtons([(model.filesShowHidden ? "eye" : "eye.slash", model.filesShowHidden ? "Hide hidden files" : "Show hidden files", "files.hidden", { model.pageRequest = .init(.filesToggleHidden) }),
                              ("square.and.arrow.up", "Upload", "files.upload", { model.pageRequest = .init(.filesUpload) })])
            case .boardActions:
                // The board's … menu needs its store (nudge, refresh): the page's own until wired.
                trailButtons([("ellipsis.circle", "Board options", "board.options", {}),
                              ("plus", "Add task", "board.new", { model.pageRequest = .init(.boardNew) })])
            case .sessionsOptions:
                Menu {
                    Button { model.pageRequest = .init(.sessionsAdvanced) } label: { Label("Advanced", systemImage: "internaldrive") }
                } label: { Image(systemName: "gearshape").contentShape(.rect) }
                .menuStyle(.button).buttonStyle(MorphPressStyle(kind: .icon)).barIconHitArea()
                .font(.body.weight(.medium)).foregroundStyle(.tint)
                .padding(.horizontal, BarIcon.endPadding).frame(height: 44)
                .accessibilityLabel("Options").accessibilityIdentifier("sessions.options")
                .accessibilityShowsLargeContentViewer { Label("Options", systemImage: "gearshape") }
            case nil: EmptyView()
            }
            }
        // Only a chat has the status column's slots.
        case .columnBack, .columnMore:
            EmptyView()
        }
    }

    private func pageRequestID(for tab: AppModel.AppTab) -> String {
        switch tab { case .bots: "bots.newBot"; case .projects: "projects.new"; case .cron: "cron.add"; default: "\(tab.rawValue).plus" }
    }
    private func plusRequest(for tab: AppModel.AppTab) {
        switch tab {
        case .bots: model.pageRequest = .init(.botsNewBot)
        case .projects: model.pageRequest = .init(.projectsNew)
        case .cron: model.pageRequest = .init(.cronNew)
        default: break
        }
    }

    /// A circle button in a leading or trailing slot, with the accessibility it needs.
    private func circleButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.body.weight(.medium)).foregroundStyle(.tint).frame(width: 44, height: 44).contentShape(.circle) }
            .buttonStyle(MorphPressStyle(kind: .circle))
            .accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .accessibilityShowsLargeContentViewer { Label(label, systemImage: symbol) }
            .accessibilityIdentifier(id)
    }

    /// A page's trailing buttons, live, with the footprint `trailIcons` is measured with.
    private func trailButtons(_ items: [(symbol: String, label: String, id: String, action: () -> Void)]) -> some View {
        HStack(spacing: BarIcon.spacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(action: item.action) { Image(systemName: item.symbol).contentShape(.rect) }
                    .buttonStyle(MorphPressStyle(kind: .icon)).barIconHitArea()
                    .accessibilityElement(children: .ignore).accessibilityLabel(item.label).accessibilityAddTraits(.isButton)
                    .accessibilityAction { item.action() }
                    .accessibilityShowsLargeContentViewer { Label(item.label, systemImage: item.symbol) }
                    .accessibilityIdentifier(item.id)
            }
        }
        .font(.body.weight(.medium)).foregroundStyle(.tint)
        .padding(.horizontal, BarIcon.endPadding).frame(height: 44)
    }

    /// A pushed page's own controls, live, with the footprint `trailIcons` is measured with (#435).
    private func pageActionButtons(_ acts: [MorphPageAction]) -> some View {
        HStack(spacing: BarIcon.spacing) {
            ForEach(acts) { a in
                if a.menu.isEmpty {
                    Button(action: a.action) { Image(systemName: a.symbol).contentShape(.rect) }
                        .buttonStyle(MorphPressStyle(kind: .icon)).barIconHitArea()
                        .accessibilityElement(children: .ignore).accessibilityLabel(a.label).accessibilityAddTraits(.isButton)
                        .accessibilityAction { if a.enabled { a.action() } }
                        .accessibilityShowsLargeContentViewer { Label(a.label, systemImage: a.symbol) }
                        .accessibilityIdentifier(a.id)
                        // The bar's button style does not dim a disabled button: done here.
                        .disabled(!a.enabled).opacity(a.enabled ? 1 : 0.35)
                } else {
                    Menu {
                        ForEach(Array(a.menu.enumerated()), id: \.offset) { _, item in
                            Button { item.action() } label: { Label(item.label, systemImage: item.symbol) }
                        }
                    } label: { Image(systemName: a.symbol).contentShape(.rect) }
                    .menuStyle(.button).buttonStyle(MorphPressStyle(kind: .icon)).barIconHitArea()
                    .accessibilityLabel(a.label).accessibilityIdentifier(a.id)
                    .accessibilityShowsLargeContentViewer { Label(a.label, systemImage: a.symbol) }
                    .disabled(!a.enabled).opacity(a.enabled ? 1 : 0.35)
                }
            }
        }
        .font(.body.weight(.medium)).foregroundStyle(.tint)
        .padding(.horizontal, BarIcon.endPadding).frame(height: 44)
    }

    /// A page's trailing icons (visual in this pass, measured and morphed like the list's).
    private func trailIcons(_ names: [String], label: String) -> some View {
        HStack(spacing: BarIcon.spacing) { ForEach(names, id: \.self) { Image(systemName: $0).barIconSlot() } }
            .font(.body.weight(.medium)).foregroundStyle(.tint)
            .padding(.horizontal, BarIcon.endPadding).frame(height: 44)
            .accessibilityLabel(label)
            .accessibilityShowsLargeContentViewer { Label(label, systemImage: names.first ?? "circle") }
    }

    /// The + / sort / filters capsule with its controls live: the same footprint as `actions`,
    /// which the layout is measured with.
    private var liveActions: some View {
        HStack(spacing: BarIcon.spacing) {
            // No New bot in the demo (#494), here and in `actions`, which the layout is measured with.
            if !model.isInDemo {
            Button { model.chatListRequest = .init(.newBot) } label: { Image(systemName: "plus").contentShape(.rect) }
                .buttonStyle(MorphPressStyle(kind: .icon)).barIconHitArea()
                .accessibilityElement(children: .ignore).accessibilityLabel("New bot").accessibilityAddTraits(.isButton)
                .accessibilityAction { model.chatListRequest = .init(.newBot) }
                .accessibilityShowsLargeContentViewer { Label("New bot", systemImage: "plus") }
                .accessibilityIdentifier("chats.newBot")
            }
            Menu { ChatListSortItems() } label: { Image(systemName: "arrow.up.arrow.down").contentShape(.rect) }
                .menuStyle(.button).buttonStyle(MorphPressStyle(kind: .icon)).barIconHitArea()
                .accessibilityLabel("Sort").accessibilityIdentifier("chats.sort")
                .accessibilityShowsLargeContentViewer { Label("Sort", systemImage: "arrow.up.arrow.down") }
            Menu { ChatListFilterItems() } label: { Image(systemName: "line.3.horizontal.decrease.circle").contentShape(.rect) }
                .menuStyle(.button).buttonStyle(MorphPressStyle(kind: .icon)).barIconHitArea()
                .accessibilityLabel("Filters").accessibilityIdentifier("chats.filters")
                .accessibilityShowsLargeContentViewer { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }
        }
        .font(.body.weight(.medium)).foregroundStyle(.tint)
        .padding(.horizontal, BarIcon.endPadding).frame(height: 44)
    }

    // MARK: The end states (laid out, not seen)

    private var listLayout: some View {
        let chrome = tabChrome(model.selectedTab)
        // At least a control's height on every page, so the title capsule sits on the same line
        // whether or not the page has round controls beside it (Matt on 1.5 (17): "the title
        // headings like bot and settings they should all be on the exact same spot"; centred in a
        // row of 44 pt circles, Bots' sat 4 pt below Settings' bare one).
        return HStack(spacing: 10) {
            if let _ = selecting {
                Text("Done").font(.body.weight(.semibold)).padding(.horizontal, 16).frame(height: 44).hidden()
                    .measured(.lead, into: $listFrames, last: $lastListFrames)
            } else if chrome.lead != nil { Color.clear.frame(width: 44, height: 44).measured(.lead, into: $listFrames, last: $lastListFrames) }
            // The title alone: the pull's wheel widens the seen capsule itself (CapsuleFrame), so
            // a pull never changes what is measured here. Hidden, not only unseen: at opacity 0 under
            // accessibilityHidden it stayed in the tree as a second title, a "Settings" text over a
            // pushed page's Back.
            Text(selecting?.title ?? model.selectedTab.title).font(.headline).fixedSize().hidden()
            // A set height, not the text's measured one: measured afresh on each tab switch it
            // came out a few points taller for a moment and the capsule breathed (Matt,
            // 2026-10-12: "the height of the bubble from bot to settings seems to change").
            .padding(.horizontal, 12).frame(height: titleHeight)
            .measured(.mid, into: $listFrames, last: $lastListFrames)
            Spacer(minLength: 0)
            if let sel = selecting {
                trailIcons((sel.canMove ? ["folder"] : []) + ["archivebox", "trash"], label: "").measured(.trail, into: $listFrames, last: $lastListFrames)
            } else {
            switch chrome.trail {
            case .chatActions: actions.measured(.trail, into: $listFrames, last: $lastListFrames)
            case .plus: trailIcons(["plus"], label: "").measured(.trail, into: $listFrames, last: $lastListFrames)
            case .filesActions: trailIcons(["eye.slash", "square.and.arrow.up"], label: "").measured(.trail, into: $listFrames, last: $lastListFrames)
            case .boardActions: trailIcons(["ellipsis.circle", "plus"], label: "").measured(.trail, into: $listFrames, last: $lastListFrames)
            case .sessionsOptions: trailIcons(["gearshape"], label: "").measured(.trail, into: $listFrames, last: $lastListFrames)
            case nil: EmptyView()
            }
            }
        }
        .frame(minHeight: 44)
    }

    /// The controls the page in front declared, when a page is pushed on this tab (#435).
    private var pushedActions: [MorphPageAction]? {
        guard let tab = state.pushedTab, let acts = state.pageActions[tab]?.actions, !acts.isEmpty else { return nil }
        return acts
    }

    /// A pushed page's controls: a Back circle where the chat's Back sits, on the root row (no
    /// face to clear), and the page's own controls at the trailing end, if it declared any.
    private var pushedLayout: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 44, height: 44).measured(.mid, into: $pageFrames)
            Spacer(minLength: 0)
            if let acts = pushedActions { trailIcons(acts.map(\.symbol), label: "").measured(.trail, into: $pageFrames) }
        }
    }

    /// The pushed page's Back, live: pops its stack one page (the probe under the root does it).
    /// On Chats, a chat's page still opening: its path goes back to the list.
    private func pageBack(_ tab: AppModel.AppTab) -> some View {
        let back = {
            if tab == .chats { if !model.chatPath.isEmpty { model.chatPath.removeLast() } }
            else { model.popOne[tab, default: 0] += 1 }
        }
        return Button { back() } label: {
            Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 44, height: 44).contentShape(.circle)
        }
        .buttonStyle(MorphPressStyle(kind: .circle))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Back").accessibilityIdentifier(tab == .chats ? "chat.back" : "page.back").accessibilityAddTraits(.isButton)
        .accessibilityAction { back() }
        .accessibilityShowsLargeContentViewer { Label("Back", systemImage: "chevron.left") }
    }

    @ViewBuilder private func chatLayout(_ chat: ChatSession) -> some View {
        if messagesBar {
            // Like Messages (#542), level with the list's row: nothing is seated over anything. Up in the band: Back (the
            // bot circle's place), the face in the title capsule's place, the name, More. Closed: the face in the bot
            // circle's place and the name; Back and More stand in the status column (`columnFrame`).
            HStack(spacing: 0) {
                Color.clear.frame(width: 44, height: 44).measured(.lead, into: $chatFrames)
                if inBand {
                    Color.clear.frame(width: 44, height: 44).measured(.mid, into: $chatFrames).padding(.leading, Self.faceGap)
                }
                nameText(chat).hidden()
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("morph")) } action: { nameFrame = $0 }
                    .padding(.leading, ChatNameLines.faceGap)
                Spacer(minLength: 8)
                if inBand { Color.clear.frame(width: 44, height: 44).measured(.trail, into: $chatFrames) }
            }
        } else {
            seatedChatLayout(chat)
        }
    }

    /// Elsewhere (a phone, an iPad window): the pill with the face seated on it.
    private func seatedChatLayout(_ chat: ChatSession) -> some View {
        // The chat's row sits a little lower than the list's: the seated face rises over the
        // pill's top, and at the list's height it went up under the Dynamic Island.
        HStack(spacing: 12) {
            Color.clear.frame(width: 44, height: 44).measured(.lead, into: $chatFrames)
            Spacer(minLength: 0)
            pillText(chat).measured(.mid, into: $chatFrames)
            Spacer(minLength: 0)
            Color.clear.frame(width: 44, height: 44).measured(.trail, into: $chatFrames)
        }
        .padding(.top, 18)
    }

    /// The pill's words: the bot's name and the chat's title (or step), as `ChatHeader` shows them.
    private func pillText(_ chat: ChatSession) -> some View {
        let label = chat.runtime.profiles.first { $0.name == chat.profileName }?.label ?? chat.profileName
        let status = chat.isRunning ? (chat.statusLine ?? "Thinking…") : (chat.showsSyncing ? "Syncing…" : chat.title)
        return VStack(spacing: 1) {
            HStack(spacing: 3) {
                Text(label.count > 26 ? String(label.prefix(25)) + "…" : label).font(.caption.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            Text(status.count > 42 ? String(status.prefix(41)) + "…" : status).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 6)
        // Its height is its own; its width gives way, so a long title truncates between the
        // circles instead of pushing the row past the edges (Back sat at x 8 at an
        // accessibility size, HeaderTextSizeUITests).
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: BarIcon.spacing) {
            if !model.isInDemo { Image(systemName: "plus").barIconSlot() }
            Image(systemName: "arrow.up.arrow.down").barIconSlot()
            Image(systemName: "line.3.horizontal.decrease.circle").barIconSlot()
        }
        .font(.body.weight(.medium)).foregroundStyle(.tint)
        .padding(.horizontal, BarIcon.endPadding).frame(height: 44)
    }
}

/// The bar with its progress drawn: the state's `t`, animated here and handed down each frame
/// (`morphProgress`), so the bar's body draws the frame between, not only the ends. While a
/// chat's push or pop is followed, the page's place instead, frame by frame.
struct MorphBarHost: View {
    var body: some View {
        let s = MorphState.shared
        MorphTopBar().modifier(MorphProgress(t: s.away ? (s.followed ?? s.t) : 1))
    }
}

private struct MorphProgress: ViewModifier, Animatable {
    var t: CGFloat
    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }
    func body(content: Content) -> some View { content.environment(\.morphProgress, t) }
}

extension EnvironmentValues {
    /// The top bar's morph as drawn this frame (1 at a root page, 0 over a chat or pushed page).
    @Entry var morphProgress: CGFloat = 1
}

/// A seen capsule's frame, glass and place. The title's capsule widens here for the pull's wheel
/// (as wide as the wheel and its gap, grown to the right so the title keeps its leading edge),
/// in its own view, so a pull never runs the bar again: with the wheel inside the measured title,
/// every frame of a pull went through the bar's state. It opens in one snappy step, as the
/// wheel's slot does; grown with the finger, the glass resized on every frame and fast pulls
/// hitched on the phone.
private struct CapsuleFrame: ViewModifier {
    let frame: CGRect
    let present: Bool
    var pull: PullRefreshState?
    /// How far the bar is toward the page's own state (1 at the root, 0 over a chat or a pushed
    /// page): the wheel's room goes with the morph. Given in full, a refresh still running as a
    /// chat opened widened its pill to the right, off its words, until the refresh ended.
    var widen: CGFloat = 1
    /// The capsule's slot, for the DEBUG frames readout (`MorphFramesProbe`).
    var slot: MorphSlot? = nil
    /// A status-column slot (the closed Duo, #542): it keeps its frame where it stands and grows from its own middle as a
    /// chat comes, shrinking there as it goes. From a zero frame its corner rode from its middle into place, 22 pt down
    /// and right of where it rests at first (the gate's frame log).
    var inPlace = false
    /// The face's slot while a chat shows on the Duo: its frame as ever, so nothing in the morph moves, but no glass, so
    /// the face stands on nothing, as a contact's photo does in Messages (Matt, 2026-10-28, #542).
    var bare = false
    /// The wheel's side, as PullRefreshWheel's: it grows with the title's type.
    @ScaledMetric(relativeTo: .headline) private var side: CGFloat = 15
    func body(content: Content) -> some View {
        let open = pull.map { $0.refreshing || $0.shown > 0 } ?? false
        let width = inPlace ? frame.width : present ? frame.width + (open ? side * 1.4 * widen : 0) : 0
        content
            .frame(width: width, height: present || inPlace ? frame.height : 0)
            #if DEBUG
            .modifier(MorphFramesProbe.Record(slot: slot, present: present))
            #endif
            // The page's glass under the capsule stays still when it is touched (#344).
            .barShieldShape()
            .clipShape(.capsule)
            .glassEffect(present && !bare ? .regular : .identity, in: .capsule)
            .scaleEffect(inPlace && !present ? 0.01 : 1)
            .position(x: present || inPlace ? frame.minX + width / 2 : frame.midX, y: frame.midY)
            // With the wheel's own slot: one snappy step open, and closed after the refresh.
            .animation(.snappy(duration: 0.3), value: open)
    }
}

/// The icons in the bar's capsules (+, sort, filters, a page's own): each in a slot of its own, the capsule's height and
/// at least `width` wide, which is also what's hit. The glyph alone was the hit area, and the audit's hit region failed
/// the sort arrows (24 × 19) and, once those were the capsule's height, the + (18 wide). The slots are closer together
/// and the capsule's ends a little narrower, so the glyphs stand where they did and the capsule is its old width.
enum BarIcon {
    static let width: CGFloat = 28
    static let spacing: CGFloat = 12
    static let endPadding: CGFloat = 11
}

extension View {
    /// An icon control's slot in a capsule (`BarIcon`): on the control, outside its button style, so the pressed square
    /// still hugs the glyph.
    func barIconHitArea() -> some View { frame(minWidth: BarIcon.width, minHeight: 44).contentShape(.rect) }
    /// The same slot in the capsules laid out for measuring (`trailIcons`, `actions`).
    func barIconSlot() -> some View { frame(minWidth: BarIcon.width) }
}

/// The bar's controls pressed (Matt on 1.5 (18): "at touching indication on the top right icons
/// for the chat page"): a soft fill behind the control touched, not its whole shared capsule, and
/// a slight grow, like the system's glass controls, at touch-down; gone on lift or when the finger
/// slides off. A fill, never glass taken to 0 (the glass reference). Reduce Motion: the fill
/// alone. `-vory-press-style-off` brings back (18)'s
/// plain controls.
struct MorphPressStyle: ButtonStyle {
    enum Kind {
        /// A 44 pt round control (Back, the bot circle, the chat's …): a circle just inside it.
        case circle
        /// An icon in a shared capsule (+, sort, filter): a rounded square around the glyph.
        case icon
    }
    var kind: Kind
    /// The pressed control's size, the one number to change the look by.
    static let pressedScale: CGFloat = 1.05
    static let off = ProcessInfo.processInfo.arguments.contains("-vory-press-style-off")
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && !Self.off
        let fill = scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? Self.pressedScale : 1)
            .background {
                Group {
                    switch kind {
                    case .circle: Circle().fill(fill).padding(3)
                    case .icon: RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill).padding(-8)
                    }
                }
                .opacity(pressed ? 1 : 0)
            }
            .animation(.easeOut(duration: pressed ? 0.08 : 0.2), value: pressed)
    }
}

private extension View {
    /// Reports this view's frame in the bar's space under its slot. A change after the first
    /// measurement animates (a tab switch moves and resizes the capsules: the morph); a slot
    /// that goes away leaves its last frame so its capsule can fade out where it was.
    func measured(_ slot: MorphSlot, into frames: Binding<[MorphSlot: CGRect]>, last: Binding<[MorphSlot: CGRect]>? = nil) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("morph")) } action: { f in
            guard frames.wrappedValue[slot] != f else { return }
            if frames.wrappedValue[slot] != nil || last?.wrappedValue[slot] != nil {
                withAnimation(.snappy(duration: 0.22)) { frames.wrappedValue[slot] = f }
            } else {
                frames.wrappedValue[slot] = f
            }
            last?.wrappedValue[slot] = f
        }
        // The frame is not cleared when the view goes: on a tab switch the old view's
        // disappearance landed after the new view's measurement and wiped it, which left the
        // capsule drawn from memory with its hit testing off (the Bots +). Whether a page has
        // the slot comes from its chrome (`tabChrome`), not from the frames.
    }
}
/// The seated face's touch area in a chat (#339): a tap there does what the pill does. A UIKit view
/// with a tap recognizer, out of the accessibility tree (the pill is the element): the pill's own
/// touch shape, stretched over the face, did not reach outside the bar's glass, and a SwiftUI tap
/// gesture here would read to VoiceOver as an unnamed element.
private struct FaceTapArea: UIViewRepresentable {
    var action: () -> Void
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        v.accessibilityElementsHidden = true
        v.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
        return v
    }
    func updateUIView(_ v: UIView, context: Context) { context.coordinator.action = action }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}

#if DEBUG
/// DEBUG `-vory-morph-frames` (#516's checks; DEBUG only, checked absent from Release at each cut): each of the top bar's
/// capsules as drawn, in the window's space, for the UI tests to hold the page's headings and search fields against. The
/// capsules are glass shapes, not accessibility elements, and the title's text is narrower than its capsule. Read through
/// a 1 pt element, "debug.morphframes", whose value is "lead x y w h;mid …;trail …" for the capsules shown.
enum MorphFramesProbe {
    nonisolated static let isOn = ProcessInfo.processInfo.arguments.contains("-vory-morph-frames")
    @MainActor static var frames: [MorphSlot: CGRect] = [:]
    /// The chat's face (its tap area, where the face is drawn), while the chat is at rest; nil otherwise.
    @MainActor static var face: CGRect?
    /// With `-vory-morph-log` too: every drawn frame of every capsule and of the face, "<wall time> <slot> x y w h", as
    /// they change (a push's or a pop's every frame), the latest 4,000; read through "debug.morphlog". A capsule that
    /// goes logs a zero frame under its name, so a capsule that vanishes reads as travel there; one that stands still
    /// logs nothing.
    nonisolated static let logs = ProcessInfo.processInfo.arguments.contains("-vory-morph-log")
    @MainActor static var log: [String] = []
    @MainActor static func note(_ name: String, _ f: CGRect) {
        guard logs else { return }
        log.append(String(format: "%.3f %@ %.1f %.1f %.1f %.1f", Date().timeIntervalSince1970, name, f.minX, f.minY, f.width, f.height))
        if log.count > 4000 { log.removeFirst(log.count - 4000) }
    }
    /// Other frames by name, while they're drawn: the chat's band (its opaque part, `ChatBand`) and the name beside the
    /// face, on the Duo (#542).
    @MainActor static var marks: [String: CGRect] = [:]
    @MainActor static var summary: String {
        let f = { (n: String, r: CGRect) in "\(n) \(Int(r.minX.rounded())) \(Int(r.minY.rounded())) \(Int(r.width.rounded())) \(Int(r.height.rounded()))" }
        return (MorphSlot.allCases.compactMap { s in frames[s].map { f("\(s)", $0) } } + [face.map { f("face", $0) }].compactMap { $0 }
                + marks.keys.sorted().compactMap { k in marks[k].map { f(k, $0) } })
            .joined(separator: ";")
    }
    /// A named frame for the readout (`marks`) while the view is drawn.
    struct Mark: ViewModifier {
        let key: String
        @ViewBuilder func body(content: Content) -> some View {
            if isOn {
                content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in MorphFramesProbe.marks[key] = f.width > 0 ? f : nil }
                    .onDisappear { MorphFramesProbe.marks[key] = nil }
            } else {
                content
            }
        }
    }
    /// The face's frame for the readout while `shown` (the chat at rest).
    struct RecordFace: ViewModifier {
        let shown: Bool
        /// Its last frame, so a face that comes to rest without moving (closed, in the bot circle's place) is read then
        /// too: measured only on a change, it was left out of the readout there.
        @State private var last: CGRect = .zero
        @ViewBuilder func body(content: Content) -> some View {
            if isOn {
                content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                    last = f
                    MorphFramesProbe.face = shown && f.width > 0 ? f : nil
                    if shown && f.width > 0 { MorphFramesProbe.note("face", f) }
                }
                .onChange(of: shown) { _, now in
                    MorphFramesProbe.face = now && last.width > 0 ? last : nil
                    if now && last.width > 0 { MorphFramesProbe.note("face", last) }
                }
                .onDisappear { MorphFramesProbe.face = nil }
            } else {
                content
            }
        }
    }
    struct Record: ViewModifier {
        let slot: MorphSlot?
        let present: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if isOn, let slot {
                content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                    MorphFramesProbe.frames[slot] = present && f.width > 0 ? f : nil
                    if present && f.width > 0 { MorphFramesProbe.note("\(slot)", f) }
                }
                // A capsule that hides without moving isn't measured again: it leaves the readout at once, so no check
                // reads a capsule that's gone. The frame log gets a zero frame under its name as it goes.
                .onChange(of: present) { _, shown in if !shown { MorphFramesProbe.frames[slot] = nil; MorphFramesProbe.note("\(slot)", .zero) } }
            } else {
                content
            }
        }
    }
    final class ReadoutView: UIView {
        override var isAccessibilityElement: Bool { get { true } set {} }
        override var accessibilityIdentifier: String? { get { "debug.morphframes" } set {} }
        override var accessibilityLabel: String? { get { "Top bar frames" } set {} }
        override var accessibilityValue: String? { get { MainActor.assumeIsolated { MorphFramesProbe.summary } } set {} }
    }
    struct Readout: UIViewRepresentable {
        func makeUIView(context: Context) -> ReadoutView { ReadoutView() }
        func updateUIView(_ v: ReadoutView, context: Context) {}
    }
    /// The frame log (`-vory-morph-log`), one line per drawn change.
    final class LogView: UIView {
        override var isAccessibilityElement: Bool { get { true } set {} }
        override var accessibilityIdentifier: String? { get { "debug.morphlog" } set {} }
        override var accessibilityLabel: String? { get { "Top bar frame log" } set {} }
        override var accessibilityValue: String? { get { MainActor.assumeIsolated { MorphFramesProbe.log.joined(separator: "\n") } } set {} }
    }
    struct LogReadout: UIViewRepresentable {
        func makeUIView(context: Context) -> LogView { LogView() }
        func updateUIView(_ v: LogView, context: Context) {}
    }
}
#endif
#else
import SwiftUI
import VoryCore

/// The Mac keeps its window toolbar and its own chrome: the bar is never on there, so the
/// pages' `if !MorphTopBar.active(model)` guards read as always-shown.
enum MorphTopBar {
    static var on: Bool { false }
    static var cutsPages: Bool { false }
    static func active(_ model: AppModel) -> Bool { false }
}
/// No bar, no chat shown by it: the chat's request handler never matches.
@MainActor final class MorphState {
    static let shared = MorphState()
    var chat: ChatSession? { nil }
}
/// A page's own control for the phone's morph bar; the Mac keeps its toolbar.
struct MorphPageAction: Identifiable {
    struct Item { var label: String; var symbol: String; var action: () -> Void }
    var id: String
    var symbol: String
    var label: String
    var enabled = true
    var menu: [Item] = []
    var action: () -> Void = {}
}
extension View {
    func morphPageActions(_ actions: [MorphPageAction], on: Bool) -> some View { self }
}
#endif
