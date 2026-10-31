import SwiftUI
import VoryCore

/// The Chats tab on iOS: the chat list and the open chat as the two columns of a split view.
/// On a wide window (iPad, the open iPhone Duo) they stand side by side, like Mail; on a
/// narrow one (any phone, the closed Duo, a narrow iPad window) the split view collapses to
/// one column and the chat is pushed over the list, as it always was. One view serves both,
/// never two roots switched by size class: that would throw the open chat away on every fold.
///
/// The detail path lives in `AppModel.chatPath`, so collapsing and expanding keep the open
/// chat, and `ChatNavigation` (shared with the Mac) decides what selecting a row does to it.
struct ChatsSplitPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowGeometry) private var windowGeometry
    @Environment(\.wideLayout) private var wide
    @Environment(\.reservedRegions) private var regions
    @State private var columns = NavigationSplitViewVisibility.doubleColumn
    @Environment(\.scenePhase) private var scenePhase
    /// The columns as they stood when the scene went into the background, kept until it is active again. In the
    /// background the system lays the scene out for its snapshot at its own compact size class (the open Duo on its
    /// side), the split view collapses there, and it came back showing the chat alone, the list column gone (#537). For
    /// that trip the split view's writes are let go, and the page's own visibility is put back once the scene is
    /// active. While the scene is active (a narrowed iPad window, a turn, the sidebar button) every write is taken.
    @State private var columnsBeforeBackground: NavigationSplitViewVisibility?
    private var columnsBinding: Binding<NavigationSplitViewVisibility> {
        Binding(get: { columns }, set: { if columnsBeforeBackground == nil { columns = $0 } })
    }
    /// The split view's leading edge in the window (a bar down the leading side moves it in).
    @State private var leading: CGFloat = 0

    /// The list's column: 380 pt where the window is wide enough for both columns at that (the
    /// iPad, the open Duo in landscape), narrower on a window like the open Duo in portrait
    /// (669 pt), where a 380 pt list left the split view no room for the chat and it put the
    /// list over the chat as a dimmed overlay instead of beside it.
    /// With a fold up the window (the open Duo half open like a book) the list ends at the
    /// fold instead, so the fold is the line between the list and the chat rather than running
    /// through the chat (Duo stage 2, `ReservedRegions.listWidth`).
    private var listWidth: (min: CGFloat, ideal: CGFloat) {
        let w = windowGeometry.bounds.width
        let atFold = regions.listWidth(leading: leading, range: 280...480)
        return (280, atFold ?? min(380, max(280, (w * 0.42).rounded(.down))))
    }

    /// The model's path as a binding: the list selects into it, the detail stack shows it.
    private var chatPath: Binding<NavigationPath> {
        Binding(get: { model.chatPath }, set: { model.chatPath = $0 })
    }

    var body: some View {
        if wide {
            NavigationSplitView(columnVisibility: columnsBinding) {
                ChatListView(detailPath: chatPath)
                    .onChange(of: model.chatPath.isEmpty, initial: true) { _, empty in
                        model.chatsPathOpen = !empty; model.tabAtRoot[.chats] = empty
                    }
                    .navigationSplitViewColumnWidth(min: listWidth.min, ideal: listWidth.ideal, max: 480)
            } detail: {
                ChatDetailStack(path: chatPath) { NoChatPlaceholder() }
            }
            .navigationSplitViewStyle(.balanced)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { leading = $0 }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, columnsBeforeBackground == nil { columnsBeforeBackground = columns }
                if phase == .active, let held = columnsBeforeBackground { columnsBeforeBackground = nil; columns = held }
            }
        } else {
            // One column (a phone, the closed Duo, the open Duo upright, a narrow window): the
            // list's own stack on the same path. The split view collapsed to one column left
            // its empty detail column (the placeholder, with a back button) in front after a
            // chat's Back, instead of the list. The open chat is `AppModel.chatPath`, the draft
            // `ComposerDrafts` and the cursor and scroll place `ChatViewMemory`, so the switch
            // between the two roots loses nothing the person had.
            NavigationStack(path: chatPath) {
                ChatListView(inModelStack: true)
                    // The bar starts coming back the instant a pop begins (the path empties at
                    // the start of the transition), reported for the list and the bar.
                    .onChange(of: model.chatPath.isEmpty, initial: true) { _, empty in
                        Perf.stamp("pop: path empty=\(empty)")
                        model.chatsPathOpen = !empty; model.tabAtRoot[.chats] = empty
                    }
                    .navigationDestination(for: ChatRoute.self) { route in ConversationView(route: route).countsChatOnScreen() }
                    .navigationDestination(for: RoomRoute.self) { r in RoomView(room: r.room, initialText: r.initialText).countsChatOnScreen(room: true) }
                    // The bar follows a chat's push and pop in this stack (`MorphState.follow`).
                    .chatsStackProbe()
            }
            // Two columns again for the next wide window: collapsing on a turn upright, the split view writes "detail only",
            // and with the pages no longer rebuilt as the bar moves (#533) the next turn on its side came back with the
            // list hidden (#547). The open chat is the model's path, so nothing the person had goes with it.
            .onAppear { columns = .doubleColumn }
        }
    }
}

/// The detail column before a chat is chosen (a wide window only; collapsed, the list is in front).
struct NoChatPlaceholder: View {
    private static let vory = BotLookSpec(shape: "cloud", eyes: "classic", hex: "#3B7BFF", finish: "flat")

    var body: some View {
        VStack(spacing: 12) {
            BotFaceView(spec: Self.vory, size: 72, mood: BotFaceView.Mood(profile: "vory-empty-detail", state: .idle))
            Text("No chat selected").font(.title3.weight(.semibold))
            Text("Pick one from the list, or start a new one.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chats.noChat")
    }
}

/// Counts a chat or room pushed on the Chats tab's own stack while it is on screen
/// (`AppModel.chatsOnScreen`): the bar's reserved size comes back only once it has gone. A group
/// chat is counted apart too (`roomsOnScreen`): it keeps its own header, and the morph bar steps
/// aside from it.
struct CountsChatOnScreen: ViewModifier {
    @Environment(AppModel.self) private var model
    var room = false
    @State private var counted = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !counted else { return }
                counted = true; model.chatsOnScreen += 1
                if room { model.roomsOnScreen += 1 }
            }
            .onDisappear {
                guard counted else { return }
                counted = false; model.chatsOnScreen = max(0, model.chatsOnScreen - 1)
                if room { model.roomsOnScreen = max(0, model.roomsOnScreen - 1) }
            }
    }
}

extension View {
    func countsChatOnScreen(room: Bool = false) -> some View { modifier(CountsChatOnScreen(room: room)) }

    /// Hands the Chats stack to the morph bar (iPhone only; the Mac has no bar).
    @ViewBuilder func chatsStackProbe() -> some View {
        #if os(iOS)
        background(ChatsStackProbe().frame(width: 0, height: 0).accessibilityHidden(true))
        #else
        self
        #endif
    }
}
