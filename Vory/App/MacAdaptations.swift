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
        Form { content }
            .formStyle(.grouped)
            // A button in a row is the row (a session, a key, a bot), as on the phone; the Mac's
            // default would draw each as a push button. Explicit styles keep their own.
            .buttonStyle(SettingsRowButtonStyle())
            .scrollContentBackground(.hidden)
            .frame(maxWidth: SettingsList<EmptyView>.width)
            .frame(maxWidth: .infinity)
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

    /// A row's actions: a swipe on the phone, a right-click menu on the Mac (whose settings
    /// forms do not swipe).
    @ViewBuilder func rowActions<Actions: View>(allowsFullSwipe: Bool = true, @ViewBuilder _ actions: () -> Actions) -> some View {
        #if os(macOS)
        contextMenu { actions() }
        #else
        swipeActions(edge: .trailing, allowsFullSwipe: allowsFullSwipe) { actions() }
        #endif
    }

    /// Pull to refresh on the phone; a Refresh button in the toolbar (⌘R) on the Mac.
    @ViewBuilder func reloadable(_ action: @escaping @MainActor () async -> Void) -> some View {
        #if os(macOS)
        toolbar { ToolbarItem(placement: .automatic) { ReloadButton(action: action) } }
        #else
        refreshable { await action() }
        #endif
    }
}
