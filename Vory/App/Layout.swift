import SwiftUI

/// Whether the window is wide enough for the reading-width layout: a column in the middle,
/// bubbles capped, grids with more columns. True on the Mac; on iOS it follows the horizontal
/// size class (regular on iPad, the open Duo and a large window; compact on a phone, a closed
/// Duo and a narrow window), never the idiom or the screen.
extension EnvironmentValues {
    @Entry var wideLayout: Bool = {
        #if os(macOS)
        true
        #else
        false
        #endif
    }()
}

extension View {
    /// A reading column of `width` in the middle of the page when the layout is wide; the full
    /// width otherwise. Replaces the `#if os(macOS)` column caps so iPad and the open Duo get
    /// the Mac's page shape.
    func readingColumn(_ width: CGFloat) -> some View { modifier(ReadingColumn(width: width)) }
}

private struct ReadingColumn: ViewModifier {
    @Environment(\.wideLayout) private var wide
    let width: CGFloat
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: wide ? width : .infinity)
            .frame(maxWidth: .infinity)
    }
}

/// Grid columns that divide cleanly: an even count on a wide layout, so a fold down the middle
/// of the window (the Duo's book posture) falls between columns and never through a card.
enum EvenColumns {
    /// How many columns of at least `minimum` points (plus `spacing` between them) fit in
    /// `width`, rounded down to an even number and never under `floor`.
    static func count(width: CGFloat, minimum: CGFloat, spacing: CGFloat, floor: Int = 2) -> Int {
        guard width > 0, minimum > 0 else { return floor }
        let fit = Int((width + spacing) / (minimum + spacing))
        return max(floor, fit - fit % 2)
    }

    static func items(_ count: Int, spacing: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: max(1, count))
    }
}

/// Which side edge the system would lay a vertical bar on in this window (the closed iPhone
/// Duo's strip, the open Duo in landscape), or nil where bars run along the bottom. Read from
/// the iOS 27.1 environment; nil on anything older.
struct VerticalBarEdge<Content: View>: View {
    @ViewBuilder var content: (HorizontalEdge?) -> Content

    var body: some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            Reader(content: content)
        } else {
            content(nil)
        }
        #else
        content(nil)
        #endif
    }

    #if os(iOS)
    @available(iOS 27.1, *)
    private struct Reader: View {
        @Environment(\.toolbarVerticalEdge) private var edge
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.windowGeometry) private var windowGeometry
        @ViewBuilder var content: (HorizontalEdge?) -> Content
        /// The edge as last read outside the background, held while the scene is there, as the window's geometry and
        /// `wide` are (`WindowGeometry.held`, #537): the snapshot pass could stand the bars on an edge the window doesn't
        /// have when it comes back, and the rows' room follows the edge. Held too while the window's reader holds back a
        /// turn's passing window (`WindowGeometry.holding`): the system turns its bars to the side before the window
        /// settles, and against the held window's strip (none) our bar took a side inset for a tenth of a second, which
        /// Home's column kept (#548). The bar now moves once, with the window, straight into the strip.
        @State private var shownEdge: HorizontalEdge??
        var body: some View {
            let holding = scenePhase == .background || windowGeometry.holding
            content(WindowGeometry.held(live: edge, holding: holding, last: shownEdge))
                .onChange(of: edge, initial: true) { _, e in if !holding { shownEdge = e } }
                .onChange(of: scenePhase) { _, phase in if phase != .background, !windowGeometry.holding { shownEdge = edge } }
                .onChange(of: windowGeometry.holding) { _, held in if !held, scenePhase != .background { shownEdge = edge } }
        }
    }
    #endif
}

/// How far a tab's pages start under the floating top bar's row (#340). The system keeps a band at the top for its
/// navigation bar, and the bar's row sits over that band; where the system's bars stand in a side strip instead (the
/// closed iPhone Duo, `toolbarVerticalEdge`), there is no band, and a root page's first row and its search field ran
/// under the row. Then the tab's navigation stack starts under the row's bottom (`rowBottom`, in the bar's space) plus
/// the bar's top padding and a gap (`TopBarRoomProbe`, as the stack's own additional safe area, so the system's search
/// drawer moves with the page); anywhere else, 0.
enum TopBarRoom {
    /// The bar's padding over its row (MorphTopBar's top padding): 4, and 11 on the closed Duo, where the row's face then
    /// has 11 over it and 11 under it to the band's opaque bottom, even, as the open Duo upright reads (#558: it sat 4 over
    /// and 11 under). The whole closed row moves with it, the list's and a chat's alike, and the pages' room under it.
    static func barPadding(closed: Bool) -> CGFloat { closed ? 11 : 4 }
    /// The gap between the row's bottom and the page.
    static let gap: CGFloat = 8
    /// The row's room (stage 1's: the row's bottom, in the bar's space, plus the bar's padding and a gap) where nothing
    /// of the system's keeps the page under the row: where its bars stand vertical in a side strip (the closed iPhone
    /// Duo, stage 1), or where its status stands in a top corner of the window (`ReservedRegions.statusInCorner`: the
    /// open Duo upright, flat or half open like a laptop, whose search field stood under the row; the stage 2 probe).
    /// A phone and an iPad have neither: nothing, unchanged. Worked out from the window's shape alone, never read back
    /// from the page: a room keyed on what the page measured flapped, stuck, or missed (the stage 2 A/B).
    /// ASSUMPTION (the one line to change if a device ever breaks it): a status standing in a top corner means the system
    /// keeps no band of its own under the row.
    static func inset(barsVertical: Bool, statusInCorner: Bool, barOn: Bool, rowBottom: CGFloat) -> CGFloat {
        guard barOn, rowBottom > 0 else { return 0 }
        if barsVertical { return (rowBottom + barPadding(closed: true) + gap).rounded() }
        return statusInCorner ? cornerRoom : 0
    }
    /// The root row's bottom in the bar's space (`MorphState.rootRowBottom`) from its slots' measured frames: its tallest
    /// slot's height, as the row stands at that space's top. Not the slots' lowest bottom: each slot's place is measured
    /// on its own, and after the text size grew and came back (an accessibility audit's Dynamic Type pass) the leading
    /// slot's last place stayed where the taller row had centred it, 31.5 pt down. The row read 75.5 for 44, and every
    /// root page on the closed Duo stood 32 pt lower until the row was measured again (#612). Its height stayed right.
    static func rowBottom(of slots: [CGRect]) -> CGFloat { slots.map(\.height).max() ?? 0 }
    /// The closed iPhone Duo (#591): the system's bars stand in the side strip and the window is taller than wide. On its
    /// side and as a book they stand in a strip too, in a window wider than tall. There the Chats list has no search drawer
    /// (the system's search button stands in the side column, as Messages' does) and keeps the row's room itself.
    static func closedStrip(barsVertical: Bool, size: CGSize) -> Bool { barsVertical && size.height > size.width }
    /// The closed Duo's column (#618, #671): how far under Back, middle to middle, More is drawn. The system stands our two
    /// markers in two groups, 70 apart, and two items of one group 52 apart (the iPhone Duo simulator on iOS 27.1,
    /// closed, at default text and XXXL, 2026-11-02). At 52 with circles of 44 the two stood 8 pt apart, inside the bar's
    /// glass spacing (10). At 60 with circles of 48 (`columnSide`) they stand 12 pt apart.
    static let stripPitch: CGFloat = 60
    /// The closed Duo's column: the side of Back's and More's circles there, and of the square each takes a touch across
    /// (#671: 48, a little larger than the row's 44).
    static let columnSide: CGFloat = 48
    /// Whether a page's search keeps the navigation bar while it's presented (`.searchPresentationToolbarBehavior
    /// (.avoidHidingContent)`): under a status in a top corner, with the bar up in the status band (#516), and wherever
    /// the floating top bar stands over the system's band (`floatingBar`, `floatingBarOverBand`: a standard iPhone too,
    /// #648). There the field stands at the safe area's top under the row; with the bar's band hidden by an active search
    /// the field and its Cancel rode up under the row's capsules (into the status band, y 24, with the bar up), and a
    /// room changed to follow the search arrived after UIKit had moved the field (the page jumped as the search started
    /// and ended). On a standard iPhone the field rode up from under the row (y 116) to the band (y 62), its Close under
    /// the row's trailing capsule (+ / Sort / Filters on Chats), which took the tap: the search couldn't be ended until a
    /// relaunch (#648). Keeping the bar, the field stays where it is and nothing changes late. Elsewhere (an iPad or a
    /// wide window, where the floating bar is off; the closed Duo's strip) the system's own behaviour, unchanged.
    static func keepsBarWhileSearching(statusInCorner: Bool, barUp: Bool = false, floatingBar: Bool = false) -> Bool {
        statusInCorner || barUp || floatingBar
    }
    /// Whether the floating top bar stands over the system's navigation bar band (#648): the bar is on (`MorphTopBar
    /// .active`: not a wide window), and the system's bars aren't in the closed Duo's side strip (`closedStrip`), where the
    /// pages keep the row's room themselves. The one rule both search callers use (ChatListView, PhonePageSearchable).
    static func floatingBarOverBand(barOn: Bool, barsVertical: Bool, size: CGSize) -> Bool {
        barOn && !closedStrip(barsVertical: barsVertical, size: size)
    }
    /// The room under a status in a top corner. ASSUMPTION (iOS 27.1 to 27.2, the open Duo upright and as a laptop): UIKit
    /// brings the navigation bar's own title band (58 pt) back under the safe area once any additional inset is set, so
    /// the smallest inset puts the search drawer just under the row: 1 pt leaves it at 141 against the row's 130, where
    /// 56 (the full room) left it at 196, a 66 pt empty band; with no inset the field stood under the row.
    /// TopBarRoomUITests holds the drawer within 16 pt of the row, so an iOS that changes this trips a test.
    static let cornerRoom: CGFloat = 1

    /// The open Duo held upright (#516, replacing the corner room above): the row stands up in the status band at the
    /// window's top, clear of the status, and the pages need no room under it. Keyed on the window alone: a fold reported
    /// across it (active or not), taller than wide, with a top safe area deep enough to hold the row. Never on a status
    /// region: the device reports none in any pose (Matt's 38 readouts), and neither does a plain iPhone.
    static func barUp(regions: ReservedRegions, size: CGSize, safeTop: CGFloat) -> Bool {
        size.height > size.width && safeTop >= bandRowTop + bandRowHeight
            && regions.reported.contains { $0.kind == .fold && $0.frame.width > $0.frame.height }
    }
    /// `barUp` through a launch's first second (#554): the fold is reported about a second after the window is, and the bar
    /// stood under the band until then and stepped up (60 pt) and sideways (122) when it came. Until the regions are read,
    /// the bar stands as it last stood for this window's shape (`SystemBarItems.up`); once they are, the live verdict.
    /// A shape never seen (a phone, an iPad, a first launch) has nothing remembered: the live verdict, as before.
    static func barUpAtLaunch(live: Bool, regionsRead: Bool, remembered: Bool?) -> Bool {
        regionsRead ? live : (remembered ?? live)
    }
    /// The closed Duo's strip through a launch's first second, the same way (#555): the system says its bars stand
    /// vertical about 0.1 s after the first layout, and the row's trailing capsule kept the place it was first measured at
    /// until the regions came, 12 pt short of UIKit's item (the launch gate, 2026-10-31). Until the regions are read, a
    /// window shape last seen as the closed strip (`SystemBarItems.closed`) is the closed strip from the first frame.
    static func stripClosedAtLaunch(live: Bool, regionsRead: Bool, remembered: Bool?) -> Bool {
        barUpAtLaunch(live: live, regionsRead: regionsRead, remembered: remembered)
    }
    /// Whether the pages get the room under a status in a top corner (`statusInCorner`): where the bar isn't up, the
    /// regions report one, and the window is taller than wide, as only the open Duo upright is with its status in a corner.
    /// A turn on its side keeps reporting the upright's corner for about 0.75 s after the window is wide, and the room
    /// that came and went with it in that time left Home's column where it was laid out in the turn (#548).
    static func statusCorner(barUp: Bool, regions: ReservedRegions, size: CGSize) -> Bool {
        !barUp && size.height > size.width && regions.statusInCorner(width: size.width)
    }
    /// The row's top in the band: a 44 pt row centred on y 48, the middle of the status as measured on Matt's two 38
    /// readouts of the open Duo upright (y 27 to 69 in both).
    static let bandRowTop: CGFloat = 26
    static let bandRowHeight: CGFloat = 44
    /// What the row leaves clear at the band's trailing end, from the window's trailing edge: the status's left edge at
    /// its widest in Matt's two 38 readouts (476; the other 553), less 25 for one more indicator (Location, an alarm,
    /// Focus) and an 8 pt gap. The row ends at 443 on the 669 pt window.
    static let statusReserve: CGFloat = 226
    /// How far a row of the bar ends short of its trailing end, for its last control to end where UIKit ends its own
    /// trailing navigation item (`SystemBarItems`, window space): beside the status up in the band, and moved with it when
    /// another app's Live Activity widens it (#554); beside the strip closed (#555). Negative where that is past the bar's
    /// side inset (closed: 4 pt short of the strip, where the inset left 16). `fallback` until the item has been read.
    static func rowTrailingClear(windowWidth: CGFloat, safeTrailing: CGFloat, sideInset: CGFloat, systemItemMaxX: CGFloat?,
                                 fallback: CGFloat) -> CGFloat {
        guard let x = systemItemMaxX else { return fallback }
        return windowWidth - safeTrailing - sideInset - x
    }

    /// How far the bar moves up from its place under the safe area's top to stand in the band; 0 where it doesn't.
    static func lift(barUp: Bool, safeTop: CGFloat) -> CGFloat {
        barUp ? max(0, safeTop + barPadding(closed: false) - bandRowTop) : 0
    }

    /// The room the probe last applied, for the readouts (the DEBUG geometry probe, and Screen layout on a test build),
    /// which redraw when it changes.
    @MainActor static var lastRoom: CGFloat {
        get { AppliedRoom.shared.room }
        set { AppliedRoom.shared.room = newValue }
    }
}

/// The room the top bar's probe last applied (`TopBarRoom.lastRoom`); -1 before it has applied one. Observed so a readout
/// redraws when it changes rather than showing an old room after a pose change.
@MainActor @Observable final class AppliedRoom {
    static let shared = AppliedRoom()
    var room: CGFloat = -1
    /// Each tab root's room as its own probe last applied it. Every root applies one, the hidden ones too, so the last
    /// applied (`room`) can be a hidden tab's: Screen layout shows the front tab's, and names any root that differs.
    var rooms: [AppModel.AppTab: CGFloat] = [:]
}

/// The fold on a partly open iPhone Duo, where it crosses this view's frame (its own
/// coordinates), with Apple's margins for interactive content included; nil when there is no
/// active fold here. Read through the iOS 27.1 geometry; nil on anything older.
struct FoldReader<Content: View>: View {
    @ViewBuilder var content: (_ fold: CGRect?) -> Content

    var body: some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            Reader(content: content)
        } else {
            content(nil)
        }
        #else
        content(nil)
        #endif
    }

    #if os(iOS)
    @available(iOS 27.1, *)
    private struct Reader: View {
        @ViewBuilder var content: (_ fold: CGRect?) -> Content
        var body: some View {
            GeometryReader { proxy in
                let fold = proxy.reservedRegions(kind: .division).first { $0.isActive }?.frame
                content(fold)
            }
        }
    }
    #endif
}

/// Where a floating piece should sit so it stays off `fold`: unchanged when the fold does not
/// cross it, otherwise shifted to whichever side of the fold has more room in `width`.
enum FoldAvoidance {
    static func offset(for frame: CGRect, fold: CGRect?, in width: CGFloat) -> CGFloat {
        guard let fold, fold.intersects(frame) else { return 0 }
        let leftRoom = fold.minX, rightRoom = width - fold.maxX
        if rightRoom >= leftRoom { return fold.maxX - frame.minX }
        return fold.minX - frame.maxX
    }
}

/// The window's reserved regions (iOS 27.1): the fold of a partly open iPhone Duo (`divisions`)
/// and the camera's housing or anything else that covers the display (`occlusions`), in window
/// space, active ones only. Custom floating pieces keep their interactive content outside these
/// frames plus a margin (`ReservedRegions.margin`); system pieces (sheets, menus, lists, the
/// split view) already do. Read once at the root (`RootView`) and handed down the environment;
/// empty on anything older and on the Mac.
struct ReservedRegions: Equatable {
    var divisions: [CGRect] = []
    var occlusions: [CGRect] = []
    /// The division running up the window, active or not (window space): the open Duo on its
    /// side, flat or half open like a book. Layouts that must not reflow at every hinge move key
    /// on this, not on the fold being there (`upFold(_:in:)`).
    var upFold: CGRect? = nil
    /// The window can fold up its middle.
    var foldable: Bool { upFold != nil }
    /// Every region the window reports, active or not, as it reports it (window space): what Settings › Troubleshooting ›
    /// Screen layout shows (#516). The layouts read the active ones above, never these.
    var reported: [Reported] = []
    struct Reported: Equatable {
        enum Kind: Equatable { case fold, occlusion }
        var kind: Kind
        var frame: CGRect
        var active: Bool
    }

    /// The first of `divisions` (active or not, the window's own space) that runs up a window of
    /// `size` and crosses it: a fold across the window (the laptop pose, the open Duo upright)
    /// runs between rows and does not count, nor does one outside the window (the closed Duo
    /// reports none, the probe found).
    static func upFold(_ divisions: [CGRect], in size: CGSize) -> CGRect? {
        let window = CGRect(origin: .zero, size: size)
        return divisions.first { $0.height >= $0.width && $0.intersects(window) }
    }
    /// Room we keep beyond a region's frame for interactive content. 0: the Duo reports each region with Apple's
    /// margin already in its frame (the probe, 2026-10-20: the fold a 40 pt band, 20 pt either side of the hinge
    /// line, `margins` 20/20), so the 8 pt this was counted it twice.
    static let margin: CGFloat = 0
    var isEmpty: Bool { divisions.isEmpty && occlusions.isEmpty }
    var all: [CGRect] { divisions + occlusions }
    /// A fold that runs across the window (a laptop pose): top and bottom halves.
    var horizontalFold: CGRect? { divisions.first { $0.width > $0.height } }
    /// A fold that runs up the window (a book pose): left and right halves.
    var verticalFold: CGRect? { divisions.first { $0.height >= $0.width } }

    /// How far a list growing up from `y` (window space) may reach before a fold across the
    /// window above it, the margin kept: nil with no such fold above `y`. No floor (Duo stage
    /// 2): a floor won over the fold and the + panel opened across it (the 10-12 round). A list
    /// that wants more room than this lifts the dock over the fold instead (`dockLift`).
    func room(under y: CGFloat) -> CGFloat? {
        guard let fold = horizontalFold, y > fold.midY else { return nil }
        return max(0, y - fold.maxY - Self.margin)
    }

    /// How far the chat's dock moves up off a fold across the window (a laptop pose), so that
    /// its bottom edge sits the margin above the fold; 0 where it stays. `dock` is where the
    /// dock stands unlifted (window space). It moves when it is on the fold itself (the
    /// keyboard pushed it there), and when it stands under the fold while an open list (+, "/",
    /// "@") would reach across it: `listTop`, the list's top edge at full size with the dock
    /// unlifted, nil with no list open. `held` keeps a lift made for the list until the list
    /// closes (the decision: the dock rides above the fold while the list is open), so
    /// the list's own resizing after the lift cannot drop the dock back under it. `restingBottom`
    /// is where the dock's bottom edge stands with no keyboard (window space), nil where it isn't known.
    /// A dock standing there and on the fold stays (#669): at rest it's on the fold only because it's
    /// taller than the room under it, and the half above can't hold it either (on the half-open Duo
    /// about 420 pt under the fold and 380 above it, under the top bar). Lifted, it went over the top
    /// bar and into the status band; where it rests, its controls stay in the flat bottom half.
    func dockLift(dock: CGRect, listTop: CGFloat? = nil, held: Bool = false, restingBottom: CGFloat? = nil) -> CGFloat {
        guard let fold = horizontalFold, dock.height > 0 else { return 0 }
        let onFold = dock.minY < fold.maxY + Self.margin && dock.maxY > fold.minY - Self.margin
        if onFold, let rest = restingBottom, dock.maxY >= rest - 0.5 { return 0 }
        let underFold = dock.minY >= fold.maxY + Self.margin
        let listCrosses = listTop.map { held || $0 < fold.maxY + Self.margin } ?? false
        guard onFold || (underFold && listCrosses) else { return 0 }
        return dock.maxY - fold.minY + Self.margin
    }

    /// An active occlusion in the top trailing corner of a window `width` wide: at its top edge, against its right edge
    /// (in the window's own space, whatever the writing direction), less than half its width and wider than tall (a piece
    /// of a status, not a strip down the side). The open iPhone Duo's status corner (535, 0, 134 x 82 of 669; the probe).
    /// Not: a phone's or an iPad's status, one band the window's full width (iOS 27.2); an iPad turned to landscape, whose
    /// status 27.2 reports as a strip 32 wide and the window's full height against a side; a camera under the top edge;
    /// an iPad window's own controls, in its top leading corner, should a system report them as an occlusion.
    func statusInCorner(width: CGFloat) -> Bool {
        if case .corner = statusArea(width: width) { true } else { false }
    }

    /// The status area as the layout reads it (`statusInCorner`'s rule): the corner it stands in, or why none was found.
    /// One reading for the layout and for Settings › Troubleshooting › Screen layout, which shows what the layout decided
    /// (#516: the open Duo upright gave its row no room on a real device, while the simulator did).
    enum StatusArea: Equatable {
        case corner(CGRect)
        case notFound(String)
    }
    func statusArea(width: CGFloat) -> StatusArea {
        let top = occlusions.filter { $0.minY <= 0.5 }
        if let c = top.first(where: { $0.maxX >= width - 0.5 && $0.width < width / 2 && $0.width > $0.height }) { return .corner(c) }
        guard let f = top.first else { return .notFound(occlusions.isEmpty ? "No area reported" : "None at the top edge") }
        let more = top.count > 1 ? " (the first of \(top.count) at the top edge)" : ""
        if f.maxX < width - 0.5 { return .notFound("Not against the right edge" + more) }
        if f.width >= width / 2 { return .notFound("Half the window's width or wider" + more) }
        return .notFound("Not wider than tall" + more)
    }

    /// The width of the list column in two columns when a fold runs up the window (a book
    /// pose): the column ends at the fold's middle, so the fold is the line between the list
    /// and the chat, as Apple advises, rather than running through the chat. `leading` is the
    /// split view's leading edge (window space). Nil with no such fold, or where that width is
    /// outside the column's `range`: the usual width stands.
    func listWidth(leading: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat? {
        guard let fold = verticalFold else { return nil }
        let width = (fold.midX - leading).rounded(.down)
        return range.contains(width) ? width : nil
    }
}

/// Home's six tiles (DashboardView): three to a row, two even rows, on a phone, an iPad and the
/// Mac; two to a row on a window that can fold up its middle (the open Duo on its side), so the
/// fold falls between them and never through one. Keyed
/// to the window being foldable that way, not to the fold being there, so the tiles don't reflow
/// at every hinge move; an active fold up the window counts too, in case a flat Duo reports no
/// division. A fold across the window runs between rows: three stay.
enum HomeTiles {
    static func columns(regions: ReservedRegions) -> Int {
        #if os(macOS)
        3
        #else
        regions.foldable || regions.verticalFold != nil ? 2 : 3
        #endif
    }

    /// The grid's columns for a grid standing at `frame` (window space). Two to a row with a fold up the window
    /// (active or not) crossing the grid: the leading column ends at the fold's leading edge and the trailing one
    /// starts at its far edge, so the fold is the gap between them (Home's column is centred in the safe area, which
    /// a trailing strip moves off the window's middle and the fold). Even columns otherwise, or where a column would
    /// be under `minimum`.
    static func items(regions: ReservedRegions, frame: CGRect, spacing: CGFloat, minimum: CGFloat = 100) -> [GridItem] {
        let n = columns(regions: regions)
        if n == 2, let s = split(frame: frame, fold: regions.upFold ?? regions.verticalFold, minimum: minimum) {
            return [GridItem(.fixed(s.leading), spacing: s.gap), GridItem(.fixed(s.trailing))]
        }
        return EvenColumns.items(n, spacing: spacing)
    }

    /// The two columns' widths and the gap between them with `fold` as the gap; nil where the fold doesn't cross the
    /// grid or a column would be under `minimum`.
    static func split(frame: CGRect, fold: CGRect?, minimum: CGFloat) -> (leading: CGFloat, gap: CGFloat, trailing: CGFloat)? {
        FoldSplit.halves(frame: frame, fold: fold, minimum: minimum)
    }
}

/// Home on a window folded across (the Duo half open like a laptop, Duo stage 4): who's working above the fold, what
/// needs you and the rest of Home below it, so nothing sits on the hinge (the desk). The two halves' heights and the
/// fold's between them, measured in the page (from under our top bar's row to our tab bar's top), or nil for Home as
/// everywhere else: no fold across, a half under its minimum, an accessibility text size (as voice mode's), or Home
/// being edited (the drag needs the one list).
enum DeskSplit {
    /// The top half's content at the largest text short of the accessibility sizes: the scroll's padding (8), the
    /// greeting on one line and the date (4 + 41 + 4 + 26), the gap (16), the panel with one working row and the idle
    /// faces' 44 pt row (16 + 29 + 10 + 53 + 10 + 44 + 16), and 8 over the fold. About 285. At the default text the same
    /// content, with the idle faces' 52 pt row (44 pt faces), measured about 263 on the Duo (2026-10-27).
    static let minTop: CGFloat = 290
    /// One approval card whole at the default text: the padding and the chat's 44 pt line (8 + 44 + 8) and the card (14 +
    /// 22 + 10 + 20 + 10 + 34 + 10 + 16 + 10 + 26 + 10, its four choices two by two at the large size 50 + 8 + 50, and
    /// 14). About 364. At the larger sizes the card's second row of choices is reached by scrolling the half.
    static let minBottom: CGFloat = 365

    static func halves(page: CGRect, fold: CGRect?, accessibilityText: Bool, editing: Bool) -> (top: CGFloat, gap: CGFloat, bottom: CGFloat)? {
        guard !accessibilityText, !editing, let fold, fold.width > fold.height, fold.minY > page.minY, fold.maxY < page.maxY else { return nil }
        let top = fold.minY - page.minY, bottom = page.maxY - fold.maxY
        guard top >= minTop, bottom >= minBottom else { return nil }
        return (top, fold.height, bottom)
    }
}

/// A grid standing at `frame` (window space) cut in two by a fold up the window: the part before the fold, the fold
/// itself as the gap, and the part after it. Nil where the fold doesn't cross the grid or a part would be under
/// `minimum`. Home's tiles (`HomeTiles`) and the Board's column chips (`KanbanChips`) put their halves either side of it.
enum FoldSplit {
    static func halves(frame: CGRect, fold: CGRect?, minimum: CGFloat) -> (leading: CGFloat, gap: CGFloat, trailing: CGFloat)? {
        guard let fold, frame.width > 0, fold.minX > frame.minX, fold.maxX < frame.maxX else { return nil }
        let leading = fold.minX - frame.minX, trailing = frame.maxX - fold.maxX
        guard leading >= minimum, trailing >= minimum else { return nil }
        return (leading, fold.width, trailing)
    }
}

/// A view as wide as it's offered, whatever its own width, and laid out at that width: what a grid's span is read on when
/// its fixed columns are worked out from that span (`FoldSplit`, for Home's tiles and the Board's column chips). Fixed
/// columns add up to the span they're worked out from, so a span read on the grid itself, or on anything a stack placed
/// beside it (a stack places each child at its widest child's width), held itself: the columns of a turn's first pass, at
/// the window's full width, stayed in every pass after it, and the page with them (#548 Home, 42 pt left of the window;
/// #553 the Board's chips, 927 pt wide and partly off its left). Here what's around never sees the grid's own width:
/// columns wider than the offer last one pass, drawn past it, and the span read on this is the offer. Asked with no width
/// or an infinite one (a stack's probe), it gives the grid's own answer. As the transcript's `OfferedWidthRow` (#440).
struct OfferedWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let content = subviews.first?.sizeThatFits(proposal) ?? .zero
        guard let width = proposal.width, width.isFinite else { return content }
        return CGSize(width: width, height: content.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: proposal.height))
    }
}

/// Voice mode on a column folded across (the Duo half open like a laptop, Duo stage 4): the bot above the fold, the
/// conversation and the controls below it, so nothing sits on the hinge. The two halves' heights and the fold's between
/// them, measured in the voice screen's column (inside the safe area, where its content goes), or nil for one column, as
/// everywhere else: no fold across, a half under its minimum at this text size, or an accessibility text size. Decided by
/// the fold and the text size alone, never by what the screen shows, so a session never changes layout mid-way.
enum VoiceSplit {
    /// The bot's face in the split, and its ring with the motion engine off (the same 1.2 as the full 164 and 196).
    static let face: CGFloat = 140
    static let ring: CGFloat = 168
    /// The top half's worst content at each text size, plus 8: the top row, 12, and the bot's block in its tallest state
    /// with the motion engine off (the ring), its lines at two at most, held at its own height (`-vory-voice-worst`,
    /// measured on the Duo half open, 2026-10-26, each listening with an error under it and the waveform): Large 360.3,
    /// xLarge 367.0, xxLarge 374.6, xxxLarge 386.0. Sizes under Large take Large's: they have less text, never more.
    static func minTop(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xLarge: 375
        case .xxLarge: 383
        case .xxxLarge: 394
        default: 369
        }
    }
    /// The controls' height at the largest text short of the accessibility sizes (their words stay on one line, scaled
    /// down to 0.6 at most), measured on the Duo: 134.7 at xxxLarge (127.3 at Large).
    static let controls: CGFloat = 135
    /// Three lines of the conversation under the bot's half, kept while no card waits.
    static let transcriptFloor: CGFloat = 80
    static var minBottom: CGFloat { controls + transcriptFloor }

    static func halves(column: CGRect, fold: CGRect?, size: DynamicTypeSize) -> (top: CGFloat, gap: CGFloat, bottom: CGFloat)? {
        guard !size.isAccessibilitySize, let fold, fold.width > fold.height, fold.minY > column.minY, fold.maxY < column.maxY else { return nil }
        let top = fold.minY - column.minY, bottom = column.maxY - fold.maxY
        guard top >= minTop(for: size), bottom >= minBottom else { return nil }
        return (top, fold.height, bottom)
    }

    /// The least a waiting card gets in one column (#631): its heading and its choices with a few lines of its words over
    /// them, which scroll from their start when there are more.
    static func cardFloor(for size: DynamicTypeSize) -> CGFloat { size.isAccessibilitySize ? 300 : 220 }
    /// What the bot's block gives up at the split's sizes: its ring (with the motion engine off) or its face.
    static func compactSaving(ring: Bool) -> CGFloat { ring ? 196 - VoiceSplit.ring : 164 - VoiceSplit.face }
    /// One column with a card waiting (#631): the bot's block lean (at the split's sizes, its state lines gone: the card's
    /// heading says the same) when, at its full size, it would leave the card too little between the top row and the
    /// controls (the closed Duo's 382 pt column ran 23 pt past the screen at both ends, which clipped the card's words and
    /// put the top row under the status bar). `botFull` is the block at full size. `card` is the card's whole height once
    /// it is measured (`cardWhole`): the conversation gives way to nothing first, and the bot goes lean only when the
    /// whole card still doesn't fit. Until then the card's floor decides. The card is held to what is left either way, so
    /// nothing runs off the screen.
    static func compactOneColumn(room: CGFloat, row: CGFloat, botFull: CGFloat, controls: CGFloat, card: CGFloat = 0,
                                 size: DynamicTypeSize) -> Bool {
        guard room > 0 else { return false }
        let left = room - row - botFull - controls
        return card > 0 ? left - transcriptTop < card : left < cardFloor(for: size)
    }

    /// The conversation's padding over its first line in voice mode (`HandsFreeView`): all it keeps when it gives way.
    static let transcriptTop: CGFloat = 6
    /// The conversation's scroll in voice mode (`VoiceTranscriptView`, round 3l): its padding over its first row, the space
    /// between its rows, and what stands under its newest row (its padding 6, the marker it follows and the space over it).
    static let conversationTop: CGFloat = 20
    static let conversationGap: CGFloat = 12
    static let conversationBottom: CGFloat = 6 + 1 + 12
    /// How much of the conversation shows on the voice screen (round 3l): whole lines only, at its top edge too. Its newest
    /// rows stand at the bottom (the screen follows them), so the rows are walked from the newest up, and when the top edge
    /// would fall inside a row, the height is cut down to where one of its lines starts; the rest stays blank above it.
    /// `rows` are the rows' heights, newest first; `line` one line of them. The room as it is when everything fits, when
    /// the edge falls between rows or under the newest one, and until the line and every row are measured.
    static func conversationShown(room: CGFloat, rows: [CGFloat], line: CGFloat) -> CGFloat {
        guard room > 0, line > 0, !rows.isEmpty, !rows.contains(where: { $0 <= 0 }),
              conversationTop + rows.reduce(0, +) + CGFloat(rows.count - 1) * conversationGap + conversationBottom > room
        else { return max(0, room) }
        var y = conversationBottom
        for h in rows {
            if room <= y { return room }
            if room < y + h { return max(y, y + h - ((y + h - room) / line - 0.01).rounded(.up) * line) }
            y += h + conversationGap
        }
        return room
    }
    /// The space between the bot's face and its state lines (`HandsFreeView`), which goes with them when the bot is lean.
    static let botLinesGap: CGFloat = 18
    /// The bot's block in one column with a card waiting (#631): full (its face and its state lines), lean (the split's
    /// face alone, the lines gone: the card's heading says the same; the mic muted a badge on the face), or hidden (no face
    /// either, whenever what must show wouldn't stand whole beside the lean face, round 3l; the badge on the top row).
    enum BotLevel: Equatable { case full, lean, hidden }
    /// The block's natural height at a level, the 12 over it included: at full the face (164, or its ring's 196 with the
    /// motion engine off) and the state lines (`lines`, the mic muted's capsule among them while muted) with the space
    /// over them; lean the split's face or ring alone, the same height muted or not; hidden nothing.
    static func botBlock(_ level: BotLevel, ring: Bool, lines: CGFloat) -> CGFloat {
        let face: CGFloat = ring ? 196 : 164
        switch level {
        case .full: return 12 + face + botLinesGap + lines
        case .lean: return 12 + face - compactSaving(ring: ring)
        case .hidden: return 0
        }
    }
    /// The bot's level in one column with a card waiting (#631): full while the whole card fits beside the full block (the
    /// conversation gives way first); lean when it doesn't (`compactOneColumn`); hidden when even what must show (what's
    /// asked and the choices) wouldn't stand whole beside the lean face, at any size (round 3l: it was XXXL and larger only,
    /// and the closed Duo at XXL cut the command under the words' fade), within `faceMargin`. The blocks are their natural
    /// heights (`botBlock`), and the controls theirs too (round 3: never squeezed).
    static func oneColumnBotLevel(room: CGFloat, row: CGFloat, full: CGFloat, lean: CGFloat, controls: CGFloat,
                                  whole: CGFloat, need: CGFloat, size: DynamicTypeSize) -> BotLevel {
        guard compactOneColumn(room: room, row: row, botFull: full, controls: controls, card: whole, size: size) else { return .full }
        guard need > 0 else { return .lean }
        return room - row - lean - controls - transcriptTop < need + faceMargin ? .hidden : .lean
    }
    /// How close what must show may come to what's left beside the lean face before the face hides (round 3l): the
    /// decision errs to hiding, as the choices' one-line check errs to wrapping (`choiceFitScale`), so a measure a point
    /// short never leaves what's asked under the fade. Nothing it reads changes with the level (the card's width, its parts
    /// and the controls are the same either way), so the face can't flicker between the two.
    static let faceMargin: CGFloat = 8
    /// The card's padding (`PendingCardView`) and the space between an approval's parts (`ApprovalCardView`).
    static let cardPadding: CGFloat = 14
    static let cardGap: CGFloat = 10

    /// A waiting approval's parts in one column (#631), as `ApprovalCardView` measures them: what's asked (the heading,
    /// the description, the command, the tool, the guardian's flag), what each answer covers, and the choices. 0 until
    /// measured.
    struct CardHeights: Equatable {
        var asked: CGFloat = 0
        var covers: CGFloat = 0
        var choices: CGFloat = 0
        /// One line of what each answer covers (round 3k), so its scroll shows whole lines only. 0 until measured.
        var coversLine: CGFloat = 0
    }
    /// What must show of the card: what's asked and the choices, with the card's padding and the spaces either side of
    /// what each answer covers (scrolled down to nothing). 0 until measured.
    static func cardNeed(_ h: CardHeights) -> CGFloat {
        h.asked > 0 && h.choices > 0 ? h.asked + h.choices + 2 * cardGap + 2 * cardPadding : 0
    }
    /// The whole card, what each answer covers too. 0 until measured.
    static func cardWhole(_ h: CardHeights) -> CGFloat {
        let need = cardNeed(h)
        return need > 0 ? need + h.covers : 0
    }
    /// How a measured card stands in one column (#631): its height, and which of its parts scroll.
    struct OneColumnFit: Equatable {
        var height: CGFloat
        /// What's asked doesn't fit with the choices: it scrolls from the heading, the choices under it.
        var wordsScroll: Bool
        /// Even the choices don't fit with the card's padding (the largest sizes on a short screen): everything scrolls,
        /// from the heading. The last resort, so nothing runs past the screen.
        var allScroll: Bool
    }
    /// The card's height in one column once it is measured (#631): the whole card when what the top row, the bot's
    /// block and the controls leave holds it (the conversation gets the rest, if any), else exactly what is left, so the
    /// column never runs past the screen (round 3: no floor once measured; the floor let the column run long at the
    /// accessibility sizes). nil until measured. Round 3k: when the card is short of its whole height yet holds what must
    /// show, what each answer covers shows whole lines only: its share is cut down to a whole number of its lines, the card
    /// is that much shorter, and the conversation takes the rest (a line cut through under the fade read as clipped text).
    static func oneColumnCard(room: CGFloat, row: CGFloat, bot: CGFloat, controls: CGFloat, heights: CardHeights) -> OneColumnFit? {
        let whole = cardWhole(heights)
        guard room > 0, whole > 0 else { return nil }
        var height = min(whole, max(0, room - row - bot - controls - transcriptTop))
        let need = cardNeed(heights)
        if heights.coversLine > 0, height < whole, height >= need {
            height = need + ((height - need) / heights.coversLine + 0.01).rounded(.down) * heights.coversLine
        }
        let choicesAlone = heights.choices + cardGap + 2 * cardPadding
        return OneColumnFit(height: height, wordsScroll: height < cardNeed(heights), allScroll: height < choicesAlone)
    }
    /// The card's height in one column: what the top row, the bot's block and the controls leave, never under its floor.
    static func oneColumnCardMax(room: CGFloat, row: CGFloat, bot: CGFloat, controls: CGFloat, size: DynamicTypeSize) -> CGFloat? {
        guard room > 0 else { return nil }
        return max(cardFloor(for: size), room - row - bot - controls)
    }

    /// Voice mode's choices, all the same size (#631, round 3f): how many to a row, and whether their names stand on one
    /// line or wrap. The cells share the row evenly and are all as tall as the tallest (`ChoiceCells`), so the widest name
    /// and the longest word decide. `columns` is 4 (a row), 2 (two by two) or 1 (a column) for four choices.
    struct ChoiceArrangement: Equatable {
        var columns: Int
        /// The names stand on one line, each shrunk only as far as its cell needs and never under `minScale`.
        var oneLine: Bool
        var minScale: CGFloat
        /// Before the measures are in: two by two, wrapping.
        static let unmeasured = ChoiceArrangement(columns: 2, oneLine: false, minScale: 1)
        /// Before the measures are in at the accessibility sizes: one column, wrapping (round 3i). A half cell there can be
        /// narrower than a word, and no frame should ever break one.
        static let unmeasuredAccessible = ChoiceArrangement(columns: 1, oneLine: false, minScale: 1)
    }
    /// The furthest a choice's name shrinks to stay on one line, under the accessibility sizes (round 3f).
    static let choiceMinScale: CGFloat = 0.8
    /// The scale the one-line check measures a name at (round 3j), above the drawing bound: a name shrunk to its floor
    /// draws wider than a copy set at that size measures (the closed Duo at XXL: "Allow for this chat" measured 129.7 at
    /// 0.8 against a room of 133, and was cut when drawn). A name stands on one line only where it measures as fitting
    /// here; it still draws down to `choiceMinScale`.
    static let choiceFitScale: CGFloat = 0.85
    /// The space between the choices, across and down.
    static let choiceGap: CGFloat = 8
    /// The choices' arrangement across `width` (round 3f), from the widest name's and the longest word's one-line widths
    /// at the text size, the widest name's at `choiceFitScale` (`widestAtFit`; round 3i, 3j) and the capsule's own insets
    /// (its width less its name's), all measured off screen: one line, in as many columns as there are choices or else
    /// two, when the widest name fits its cell at the fit scale (at the accessibility sizes, at its own size: nothing
    /// shrinks there); else two columns whose names wrap on words, when a half cell holds the longest word; else one
    /// column, wrapping. No name is cut and none breaks inside a word. The width at the fit scale is measured at that
    /// point size, not worked out from the name's own (text grows relatively wider as it shrinks: upright at XL a name the
    /// estimate put on one line was cut, round 3i), and at a scale above the bound the name draws down to (a name drawn
    /// at its floor is wider still: the closed Duo at XXL, round 3j). Before the measures are in, two by two, wrapping, or
    /// one column at the accessibility sizes.
    static func choiceArrangement(width: CGFloat, widestName: CGFloat, widestAtFit: CGFloat, longestWord: CGFloat, insets: CGFloat,
                                  count: Int, accessibility: Bool) -> ChoiceArrangement {
        guard count > 1 else { return ChoiceArrangement(columns: 1, oneLine: false, minScale: 1) }
        guard width > 0, widestName > 0, accessibility || widestAtFit > 0, longestWord > 0, insets > 0 else {
            return accessibility ? .unmeasuredAccessible : .unmeasured
        }
        func room(_ columns: Int) -> CGFloat { (width - CGFloat(columns - 1) * choiceGap) / CGFloat(columns) - insets }
        let minScale = accessibility ? 1 : choiceMinScale
        let need = accessibility ? widestName : widestAtFit
        for columns in [count, 2] where need <= room(columns) {
            return ChoiceArrangement(columns: columns, oneLine: true, minScale: minScale)
        }
        return ChoiceArrangement(columns: longestWord <= room(2) ? 2 : 1, oneLine: false, minScale: 1)
    }

    /// The caps the side controls' captions step down through, largest first (#631, round 3f).
    static let captionCaps: [DynamicTypeSize] = [.accessibility4, .accessibility3, .accessibility2, .accessibility1]
    /// The one cap both side captions take (round 3f), so they are always the same size, whichever words they show:
    /// none when the widest caption (`current`) with 8 pt of margin fits the side's `room`; else the largest of
    /// `captionCaps` at which it does (`capped`: the widest caption's width under each); else the smallest. None until
    /// every width is measured, so a cap is never picked from part of them.
    static func captionCap(room: CGFloat, current: CGFloat, capped: [CGFloat]) -> DynamicTypeSize? {
        guard room > 0, current > 0, current + 8 > room, capped.count == captionCaps.count, !capped.contains(0) else { return nil }
        for (cap, width) in zip(captionCaps, capped) where width + 8 <= room { return cap }
        return captionCaps.last
    }
}

/// Voice mode's colours, chosen for contrast (#631). The screen is always dark, under a gradient from the bot's colour at
/// the top to black; with a light bot colour (yellow, cyan, white) the top was bright enough that white words under 4.5:1
/// failed the audit, and the card's translucent glass took on whatever stood behind it. Everything here is sRGB, 0 to 1,
/// composited as the screen draws it (a colour at an opacity over what is under it), so the unit tests check the very
/// colours drawn. Light bot colours get a darker top; dark ones keep 1.5's.
enum VoiceLook {
    /// The mic muted, in words (#234): the capsule under the bot's title, and VoiceOver's label for the lean bot's badge
    /// (#631).
    static let micMuted = "Mic muted"
    /// The solid fill under the choices other than Allow once in voice mode (#631, round 3): a dark grey that white words
    /// and Deny's red both pass 4.5:1 on, and that, unlike glass, doesn't take on what stands behind the card.
    static let choiceFill = RGB(r: 0.2, g: 0.2, b: 0.2)
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double
        static let white = RGB(r: 1, g: 1, b: 1), black = RGB(r: 0, g: 0, b: 0)
        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
        /// "#RRGGBB" (or "RRGGBB"); nil for anything else.
        init?(hex: String) {
            let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
        }
        var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    }
    /// WCAG relative luminance.
    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    /// `fg` at `alpha` over `bg`.
    static func over(_ fg: RGB, _ alpha: Double, _ bg: RGB) -> RGB {
        RGB(r: fg.r * alpha + bg.r * (1 - alpha), g: fg.g * alpha + bg.g * (1 - alpha), b: fg.b * alpha + bg.b * (1 - alpha))
    }

    /// The gradient's top: the bot's colour at this opacity over black (1.5's 0.55 unless that is too bright).
    static let fullTopOpacity = 0.55
    /// The brightest the top may be (its luminance), so the secondary words pass 4.5:1 there with room to spare.
    static let topLuminanceCap = 0.12
    /// The top's opacity for a bot colour: 0.55, or the most under it that keeps the top under the cap.
    static func topOpacity(for tint: RGB) -> Double {
        if luminance(over(tint, fullTopOpacity, .black)) <= topLuminanceCap { return fullTopOpacity }
        var lo = 0.0, hi = fullTopOpacity
        for _ in 0..<30 { let mid = (lo + hi) / 2; if luminance(over(tint, mid, .black)) <= topLuminanceCap { lo = mid } else { hi = mid } }
        return lo
    }
    static func top(for tint: RGB) -> RGB { over(tint, topOpacity(for: tint), .black) }

    /// The screen's quieter words (what the bot is about, "Tap Resume to keep going.", the controls' names, the empty
    /// conversation's prompt, the person's own words): white at this opacity, in place of `.secondary`.
    static let secondaryOpacity = 0.85
    static var secondary: Color { Color.white.opacity(secondaryOpacity) }
    /// The top row's first line ("Voice mode", or the live provider's name): full white (#631, round 3f). It stands on
    /// the gradient's brightest part; at 0.85 it passed over every tint's top on paper, at under 5:1 for the light ones,
    /// yet the accessibility audit flagged it at the largest text size. Full white has 6.18:1 at worst, as the chat's
    /// name under it has.
    static let topTitle = RGB.white
    /// A note or an error under the bot: orange on a dark capsule of its own, as "Mic muted" stands on one.
    static let orange = RGB(r: 1, g: 0.624, b: 0.039)
    static let noteBackingOpacity = 0.55

    /// The card in voice mode: black at this opacity under its words, over its glass, so it reads the same whatever is
    /// behind it. The glass is taken as a light veil over the backdrop (white at 0.08) for the checks.
    static let cardFillOpacity = 0.6
    static let glassVeil = 0.08
    static func cardSurface(over backdrop: RGB) -> RGB { over(.black, cardFillOpacity, over(.white, glassVeil, backdrop)) }
    /// The card's words in voice mode: its heading in orange, its quieter lines in white at 0.8, Deny's name in a light red,
    /// the other choices' names in white, and Allow once white on a deep blue of its own.
    static let cardSecondaryOpacity = 0.8
    static var cardSecondary: Color { Color.white.opacity(cardSecondaryOpacity) }
    static let deny = RGB(r: 1, g: 0.45, b: 0.42)
    static let allowOnceFill = RGB(r: 0, g: 0.35, b: 0.8)
}

/// The Board's column chips (KanbanView): `count` to a row in even columns. On a window that can fold up its middle (the
/// open Duo on its side), with the fold crossing the chips, half of them stand each side of it and the fold is the gap
/// between the halves, so no chip lies across it (Duo stage 4, as Home's tiles). Keyed to the window being foldable,
/// not to the hinge, so the chips don't reflow as it moves. Even columns where the fold misses the chips or a chip
/// would be under `minimum`.
enum KanbanChips {
    static let minimum: CGFloat = 70

    static func items(regions: ReservedRegions, frame: CGRect, count: Int, spacing: CGFloat) -> [GridItem] {
        #if os(iOS)
        let perHalf = count / 2
        if perHalf > 0, count % 2 == 0, regions.foldable || regions.verticalFold != nil {
            let between = CGFloat(perHalf - 1) * spacing
            if let s = FoldSplit.halves(frame: frame, fold: regions.upFold ?? regions.verticalFold, minimum: CGFloat(perHalf) * minimum + between) {
                let leading = (s.leading - between) / CGFloat(perHalf), trailing = (s.trailing - between) / CGFloat(perHalf)
                return (0..<perHalf).map { GridItem(.fixed(leading), spacing: $0 == perHalf - 1 ? s.gap : spacing) }
                    + (0..<perHalf).map { _ in GridItem(.fixed(trailing), spacing: spacing) }
            }
        }
        #endif
        return EvenColumns.items(count, spacing: spacing)
    }
}

extension EnvironmentValues {
    @Entry var reservedRegions = ReservedRegions()
    /// The window's status stands in a top corner (`ReservedRegions.statusInCorner`: the open Duo upright), worked out once
    /// at the root (`StatusCornerEnvironment`), so the tab roots that give the top bar's row its room read one value that
    /// almost never changes rather than the window's geometry (#516).
    @Entry var statusInCorner = false
    /// How far the top bar stands up from its place, into the status band (`TopBarRoom.barUp`: the open Duo upright); 0
    /// everywhere else. Worked out once at the root with `statusInCorner`.
    @Entry var barLift: CGFloat = 0
}

/// Puts `statusInCorner` and `barLift` into the environment from the window's regions, size and safe area. The bar
/// standing up in the band replaces the corner's room (#516): one or the other, never both.
struct StatusCornerEnvironment: ViewModifier {
    @Environment(\.reservedRegions) private var regions
    @Environment(\.windowGeometry) private var windowGeometry
    func body(content: Content) -> some View {
        let g = windowGeometry
        let live = TopBarRoom.barUp(regions: regions, size: g.bounds.size, safeTop: g.safeArea.top)
        #if os(iOS)
        let key = SystemBarItems.shapeKey(size: g.bounds.size, safeTop: g.safeArea.top, safeTrailing: g.safeArea.trailing)
        let up = TopBarRoom.barUpAtLaunch(live: live, regionsRead: !regions.reported.isEmpty, remembered: SystemBarItems.shared.up(for: key))
        #else
        let up = live
        #endif
        content
            .environment(\.statusInCorner, TopBarRoom.statusCorner(barUp: up, regions: regions, size: g.bounds.size))
            .environment(\.barLift, TopBarRoom.lift(barUp: up, safeTop: g.safeArea.top))
    }
}

/// Reads the window's reserved regions at the root and publishes them (window space) through
/// the environment, with margins left for the pieces that read them.
struct ReservedRegionsReader<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            Reader(content: content)
        } else {
            content()
        }
        #else
        content()
        #endif
    }

    #if os(iOS)
    @available(iOS 27.1, *)
    private struct Reader: View {
        @ViewBuilder var content: () -> Content
        @Environment(\.scenePhase) private var scenePhase
        /// The regions as last read outside the background, held while the scene is there, as the window's geometry and
        /// `wide` are (`WindowGeometry.held`): the background's snapshot pass lays the window out at another size (#537).
        @State private var shownRegions: ReservedRegions?
        var body: some View {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                let all = proxy.reservedRegions(kind: .division, options: .includeInactive).map { (ReservedRegions.Reported.Kind.fold, $0) }
                    + proxy.reservedRegions(kind: .occlusion, options: .includeInactive).map { (ReservedRegions.Reported.Kind.occlusion, $0) }
                let regions = ReservedRegions(
                    divisions: proxy.reservedRegions(kind: .division).filter(\.isActive).map { $0.frame.offsetBy(dx: origin.x, dy: origin.y) },
                    occlusions: proxy.reservedRegions(kind: .occlusion).filter(\.isActive).map { $0.frame.offsetBy(dx: origin.x, dy: origin.y) },
                    upFold: ReservedRegions.upFold(proxy.reservedRegions(kind: .division, options: .includeInactive).map(\.frame), in: proxy.size)?
                        .offsetBy(dx: origin.x, dy: origin.y),
                    reported: all.map { .init(kind: $0.0, frame: $0.1.frame.offsetBy(dx: origin.x, dy: origin.y), active: $0.1.isActive) })
                content().environment(\.reservedRegions, WindowGeometry.held(live: regions, holding: scenePhase == .background, last: shownRegions))
                    .onChange(of: regions, initial: true) { _, r in if scenePhase != .background { shownRegions = r } }
                    .onChange(of: scenePhase) { _, phase in if phase != .background { shownRegions = regions } }
            }
        }
    }
    #endif
}
