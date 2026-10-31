import SwiftUI

// What a page built for the phone needs to sit right on the Mac, in three pieces every page
// can share: the settings container, a sheet's size, and a way to refresh without a pull.
// On the phone each is the plain SwiftUI thing it replaces.

/// A settings page's container: the inset grouped list on the phone; on the Mac the grouped
/// form (System Settings' look: boxed sections, switches, a reading width in the middle of
/// the window).
struct SettingsList<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        #if os(macOS)
        // The form spans the window (so its scroller sits at the window's edge and the bar over
        // it is one piece) and its content keeps to a column in the middle.
        GeometryReader { geo in
            Form { content }
                .formStyle(.grouped)
                // A button in a row is the row (a session, a key, a bot), as on the phone; the Mac's
                // default would draw each as a push button. Explicit styles keep their own.
                .buttonStyle(SettingsRowButtonStyle())
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, max(0, (geo.size.width - SettingsList<EmptyView>.width) / 2), for: .scrollContent)
        }
        #else
        List { content }
        #endif
    }
}

extension SettingsList where Content == EmptyView {
    /// The Mac's settings column.
    static var width: CGFloat { 700 }
}

/// How big a sheet opens on the Mac, where a sheet is as big as its content asks to be and a
/// list asks for nothing.
enum SheetSize {
    /// A form or a list: the usual sheet.
    case form
    /// A few controls (a recorder, a short picker).
    case compact
    /// Something to read (a tool call, a long text, a wizard).
    case wide

    var ideal: CGSize {
        switch self {
        case .form: CGSize(width: 520, height: 600)
        case .compact: CGSize(width: 440, height: 340)
        case .wide: CGSize(width: 720, height: 680)
        }
    }
}

#if os(macOS)
/// A row that is a button: its label as written, the whole row the target, the tint for plain
/// text (what a list row's button has on the phone), red for a destructive one.
struct SettingsRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tint))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.5 : (enabled ? 1 : 0.45))
    }
}

private struct MacSheetFrame: ViewModifier {
    let size: SheetSize
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .frame(minWidth: size.ideal.width * 0.85, idealWidth: size.ideal.width, maxWidth: size.ideal.width * 1.5,
                   minHeight: size.ideal.height * 0.7, idealHeight: size.ideal.height, maxHeight: size.ideal.height * 1.5)
            // Esc closes any sheet, with or without a Cancel button of its own.
            .background {
                Button("") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
    }
}

/// The pull-to-refresh of the phone as a toolbar button (⌘R).
private struct ReloadButton: View {
    let action: @MainActor () async -> Void
    @State private var busy = false

    var body: some View {
        Button {
            guard !busy else { return }
            busy = true
            Task { await action(); busy = false }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(busy)
        .help("Refresh (⌘R)")
    }
}
#endif

extension View {
    /// Gives a sheet's content its size on the Mac; nothing on the phone, where detents do it.
    @ViewBuilder func sheetFrame(_ size: SheetSize = .form) -> some View {
        #if os(macOS)
        modifier(MacSheetFrame(size: size))
        #else
        self
        #endif
    }

    /// A page that names itself in its content (the settings pages' header card): no title in
    /// the bar. On the Mac an empty title would fall back to the window's name, so the title
    /// is taken out of the toolbar instead.
    @ViewBuilder func untitledPage() -> some View {
        #if os(macOS)
        modifier(MacUntitledPage())
        #else
        navigationTitle("").navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// A row's actions: a swipe on the phone, a right-click menu on the Mac (whose settings
    /// forms do not swipe).
    @ViewBuilder func rowActions<Actions: View>(allowsFullSwipe: Bool = true, @ViewBuilder _ actions: () -> Actions) -> some View {
        #if os(macOS)
        contextMenu { actions() }
        #else
        swipeActions(edge: .trailing, allowsFullSwipe: allowsFullSwipe) { actions() }
        #endif
    }

    /// Pull to refresh on the phone (Vory's own, the wheel beside the title: `PullRefresh`); a
    /// Refresh button in the toolbar (⌘R) on the Mac.
    @ViewBuilder func reloadable(_ action: @escaping @MainActor () async -> Void) -> some View {
        #if os(macOS)
        modifier(MacReloadable(action: action))
        #else
        pullRefresh(ownWheel: true, action)
        #endif
    }
}

extension View {
    /// A page's search field: the phone's drawer under the title; on the Mac a field in the
    /// window's toolbar, declared only while the page is on show. The Mac keeps visited pages
    /// mounted, and the window's toolbar takes one search field: a second (a kept page's beside
    /// the shown page's) stopped the app (NSToolbar: "Duplicate items of this type are not
    /// allowed", 2026-10-12).
    @ViewBuilder func pageSearchable(text: Binding<String>, prompt: LocalizedStringKey? = nil, always: Bool = false) -> some View {
        #if os(macOS)
        modifier(MacPageSearchable(text: text, prompt: prompt))
        #else
        modifier(PhonePageSearchable(text: text, prompt: prompt, always: always))
        #endif
    }
}

#if os(iOS)
/// The phone's search drawer, and the page's own Back hidden SwiftUI's way where the top bar has the Back (#481).
/// SwiftUI writes a page's `hidesBackButton` from its preferences whenever they change, which a page with its search
/// field always shown did when something walked its accessibility tree (VoiceOver, Voice Control, Full Keyboard
/// Access): the bar's own hiding of it (`VoryTabBar`'s page probe) was undone, and the system's Back stood under the
/// bar's. On a wide window the bar is off and the page keeps its Back. A page with a search field never keeps its own
/// bar (`pushedPage(keepsOwnBar:)`), nor sits on one that does: there the bar would step aside and this would still
/// hide the Back. A root page has no Back to hide.
private struct PhonePageSearchable: ViewModifier {
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.statusInCorner) private var statusInCorner
    @Environment(\.barLift) private var barLift
    var text: Binding<String>
    var prompt: LocalizedStringKey?
    var always: Bool
    func body(content: Content) -> some View {
        content
            .searchable(text: text, placement: .navigationBarDrawer(displayMode: always ? .always : .automatic), prompt: prompt.map { Text($0) })
            // Under a status in a top corner, or with the bar up in the status band (the open Duo upright), the bar and its
            // title band stay while the search is presented, so the field doesn't move under the top bar's row (#516,
            // `TopBarRoom.keepsBarWhileSearching`).
            .searchPresentationToolbarBehavior(TopBarRoom.keepsBarWhileSearching(statusInCorner: statusInCorner, barUp: barLift > 0) ? .avoidHidingContent : .automatic)
            .navigationBarBackButtonHidden(model.map { MorphTopBar.active($0) } ?? false)
    }
}
#endif

extension View {
    /// `.toolbar` for a page and the pages pushed on it. On the Mac its items stand in the window's
    /// toolbar only while the page is on show: visited pages stay mounted behind the one in front
    /// (MainSplitView), and their items stood in its bar. On the phone, `.toolbar` as it is.
    func pageToolbar<Items: ToolbarContent>(@ToolbarContentBuilder _ items: () -> Items) -> some View {
        modifier(PageToolbar(items: items()))
    }
}

private struct PageToolbar<Items: ToolbarContent>: ViewModifier {
    @Environment(\.macPageShown) private var shown
    let items: Items
    func body(content: Content) -> some View { content.toolbar { if shown { items } } }
}

extension View {
    /// A page pushed on a page's stack. On the Mac its Back stands in the window's toolbar only
    /// while its page is on show: visited pages stay mounted with what was pushed on them (as the
    /// phone's tabs do), and a hidden page's Back stood over the page in front. On the phone the
    /// morph bar owns Back, except on a page that `keepsOwnBar`: one with its own Cancel, Done or
    /// Save (a form) keeps the system bar, its items, title and back, and the morph bar steps
    /// aside while it is up (the root's probe reads the marker). The Mac ignores it.
    @ViewBuilder func pushedPage(keepsOwnBar: Bool = false) -> some View {
        #if os(macOS)
        modifier(MacPushedPage())
        #else
        // One structure whether or not it is set, so a page whose answer changes (the Board, once
        // it knows it has several boards) keeps its state.
        background { if keepsOwnBar { OwnBarMarker().frame(width: 0, height: 0).accessibilityHidden(true) } }
        #endif
    }
}

#if os(macOS)
private struct MacPushedPage: ViewModifier {
    @Environment(\.macPageShown) private var shown
    func body(content: Content) -> some View { content.navigationBarBackButtonHidden(!shown) }
}
#endif

#if os(macOS)
/// See `untitledPage`. The title comes out of the toolbar only while the page is on show: the Mac
/// keeps visited pages mounted, and a hidden Home took the title out of every page's bar.
private struct MacUntitledPage: ViewModifier {
    @Environment(\.macPageShown) private var shown
    func body(content: Content) -> some View {
        content.navigationTitle("").toolbar(removing: shown ? .title : nil)
            // Pushed on a hidden page's stack, its Back must not stand over the page on show.
            .navigationBarBackButtonHidden(!shown)
    }
}
#endif

#if os(macOS)
/// The Refresh button (⌘R) only while its page is on show: the Mac keeps visited pages mounted
/// behind the one in front, and a hidden page's button stood in its toolbar and answered ⌘R.
private struct MacReloadable: ViewModifier {
    @Environment(\.macPageShown) private var shown
    var action: @MainActor () async -> Void
    func body(content: Content) -> some View {
        content.toolbar { if shown { ToolbarItem(placement: .automatic) { ReloadButton(action: action) } } }
    }
}

/// See `pageSearchable`. The field hangs off an empty background, so the page itself keeps its
/// identity (and its state) as the field comes and goes with the page.
private struct MacPageSearchable: ViewModifier {
    @Environment(\.macPageShown) private var shown
    var text: Binding<String>
    var prompt: LocalizedStringKey?
    func body(content: Content) -> some View {
        content.background {
            if shown { Color.clear.searchable(text: text, placement: .toolbar, prompt: prompt.map { Text($0) }) }
        }
    }
}
#endif

/// Whether the Mac page a view sits in is the one on show. The Mac keeps visited pages mounted
/// behind the one in front (MainSplitView); a page that is mounted but hidden declares no window
/// toolbar items while this is false, or its items would stand in the bar beside the shown
/// page's. Always true where nothing sets it: the iPhone, sheets, the page on show.
extension EnvironmentValues {
    @Entry var macPageShown: Bool = true
    /// The tab this page is the root of (`tabRoot`): the phone's morph bar draws a root page's
    /// own actions (its +, its options) in its trailing capsule, and nowhere else. A page pushed
    /// from Settings, shown in a sheet, or on the Mac has nil, and keeps its own toolbar items
    /// (#426: Settings › Projects said "Tap + to make one" with no + on the page).
    @Entry var barTab: AppModel.AppTab? = nil
}

/// A menu item's label with a system symbol. On the iPhone it is `Label(title, systemImage:)`.
/// On the Mac the symbol comes from `SymbolImages`, drawn once per name: SwiftUI looked every
/// menu item's symbol up in the asset catalog again each time a toolbar's menus were rebuilt,
/// some 30 of them each time Chats came back.
struct MenuLabel: View {
    private enum Title { case key(LocalizedStringKey), string(String) }
    private let title: Title
    private let systemImage: String

    init(_ key: LocalizedStringKey, systemImage: String) { title = .key(key); self.systemImage = systemImage }
    @_disfavoredOverload init<S: StringProtocol>(_ string: S, systemImage: String) { title = .string(String(string)); self.systemImage = systemImage }

    var body: some View {
        #if os(macOS)
        if SymbolImages.cached {
            Label { text } icon: { Image(nsImage: SymbolImages.image(systemImage)) }
        } else {
            plain
        }
        #else
        plain
        #endif
    }

    private var text: Text { switch title { case .key(let k): Text(k); case .string(let s): Text(s) } }
    private var plain: Label<Text, Image> {
        switch title { case .key(let k): Label(k, systemImage: systemImage); case .string(let s): Label(s, systemImage: systemImage) }
    }
}

#if os(macOS)
/// The menus' symbols as images, each drawn once. `defaults write <app id> mac.symbolCache.off
/// -bool YES` goes back to SwiftUI's own lookup (the way back).
@MainActor enum SymbolImages {
    static let cached = !UserDefaults.standard.bool(forKey: "mac.symbolCache.off")
    private static var images: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage {
        if let image = images[name] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        images[name] = image
        return image
    }
}
#endif
