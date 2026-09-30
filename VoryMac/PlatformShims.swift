import SwiftUI
import AppKit

// Stand-ins for iOS-only SwiftUI and UIKit spellings used by the shared views in `Vory/`, so those
// files compile in the Mac target without `#if` noise around every modifier. Each one either maps
// to the Mac equivalent or does nothing. Only the Mac target compiles this file; iOS keeps the
// real APIs.

// MARK: - Navigation and toolbar

enum NavigationBarItem {
    enum TitleDisplayMode { case automatic, inline, large }
}

extension View {
    /// Mac windows have no large-title bar; the window title carries the name instead.
    func navigationBarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View { self }
    /// Section spacing is an iOS list trait.
    func listSectionSpacing(_ spacing: CGFloat) -> some View { self }
}

extension ToolbarItemPlacement {
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var topBarLeading: ToolbarItemPlacement { .navigation }
}

/// `.toolbar(.hidden, for: .navigationBar)`: a chat hides the iOS bar because it draws its own
/// header. The Mac window's toolbar stays (the sidebar toggle lives there), so this does nothing.
enum NavigationBarToolbarPlacement { case navigationBar, tabBar }

extension View {
    func toolbar(_ visibility: Visibility, for placement: NavigationBarToolbarPlacement) -> some View { self }
}

/// Own type, not nested under `SearchFieldPlacement`: sharing SwiftUI's nested name makes the
/// lookup ambiguous and its unavailable overload wins.
enum SearchDrawerDisplayMode { case automatic, always }

extension SearchFieldPlacement {
    static func navigationBarDrawer(displayMode: SearchDrawerDisplayMode) -> SearchFieldPlacement { .toolbar }
}

extension ListStyle where Self == InsetListStyle {
    static var insetGrouped: InsetListStyle { .inset }
}

/// Same reason as `SearchDrawerDisplayMode`: a top-level type, not `TabViewStyle.IndexDisplayMode`.
enum PageIndexDisplayMode { case automatic, always, never }

extension TabViewStyle where Self == DefaultTabViewStyle {
    static var page: DefaultTabViewStyle { .automatic }
    static func page(indexDisplayMode: PageIndexDisplayMode) -> DefaultTabViewStyle { .automatic }
}

enum IndexViewStyleShim {
    enum BackgroundDisplayMode { case automatic, always, interactive, never }
    case page(backgroundDisplayMode: BackgroundDisplayMode = .automatic)
}

extension View {
    func indexViewStyle(_ style: IndexViewStyleShim) -> some View { self }
}

// MARK: - Tab bar
//
// The iOS tab bar's view modifiers (in `VoryTabBar.swift`, iOS-only). There is no bar to hide
// or a tab to be the root of here; the sidebar has that job.

extension View {
    func hidesTabBar() -> some View { self }
    func tabRoot(_ tab: AppModel.AppTab) -> some View { self }
}

// MARK: - Text input

struct TextInputAutocapitalization {
    static let never = TextInputAutocapitalization()
    static let words = TextInputAutocapitalization()
    static let sentences = TextInputAutocapitalization()
    static let characters = TextInputAutocapitalization()
}

enum UIKeyboardType { case `default`, URL, decimalPad, numberPad, emailAddress, asciiCapable, numbersAndPunctuation, webSearch }

extension View {
    func textInputAutocapitalization(_ mode: TextInputAutocapitalization?) -> some View { self }
    func keyboardType(_ type: UIKeyboardType) -> some View { self }
}

// MARK: - Edit mode

enum EditMode: Equatable { case inactive, active, transient
    var isEditing: Bool { self != .inactive }
}

/// Lists on the Mac are always editable through context menus; there is no edit toggle to show.
struct EditButton: View {
    var body: some View { EmptyView() }
}

extension EnvironmentValues {
    var editMode: Binding<EditMode>? { nil }
}

// MARK: - Size classes

enum UserInterfaceSizeClass { case compact, regular }

extension EnvironmentValues {
    /// A Mac window is always the regular width; the views use `.compact` for phone layouts.
    var horizontalSizeClass: UserInterfaceSizeClass? { .regular }
}

// MARK: - Colours
//
// `Color(.systemGray5)` resolves against `NSColor` here. AppKit has the system fills since
// macOS 14 but not the numbered greys or the grouped backgrounds, so those get the iOS values.

extension NSColor {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static var systemGray2: NSColor { dynamic(light: rgb(0xAEAEB2), dark: rgb(0x636366)) }
    static var systemGray3: NSColor { dynamic(light: rgb(0xC7C7CC), dark: rgb(0x48484A)) }
    static var systemGray4: NSColor { dynamic(light: rgb(0xD1D1D6), dark: rgb(0x3A3A3C)) }
    static var systemGray5: NSColor { dynamic(light: rgb(0xE5E5EA), dark: rgb(0x2C2C2E)) }
    static var systemGray6: NSColor { dynamic(light: rgb(0xF2F2F7), dark: rgb(0x1C1C1E)) }

    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
    static var tertiarySystemBackground: NSColor { .underPageBackgroundColor }
    static var systemGroupedBackground: NSColor { dynamic(light: rgb(0xF2F2F7), dark: rgb(0x1C1C1E)) }
    static var secondarySystemGroupedBackground: NSColor { dynamic(light: .white, dark: rgb(0x1C1C1E)) }
    static var tertiarySystemGroupedBackground: NSColor { dynamic(light: rgb(0xF2F2F7), dark: rgb(0x2C2C2E)) }
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var separator: NSColor { .separatorColor }
}

// MARK: - Compile-time check
//
// Never shown. It exists so the Mac build fails here, with one clear error, if SwiftUI's own
// `@available(macOS, unavailable)` declaration ever wins over a stand-in above.

private struct ShimSmokeTest: View {
    @Environment(\.editMode) private var editMode
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var text = ""

    var body: some View {
        NavigationStack {
            List {
                TextField("URL", text: $text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                Text(sizeClass == .compact ? "compact" : "regular")
                    .foregroundStyle(Color(.systemGray5))
                    .background(Color(.secondarySystemGroupedBackground))
                if editMode?.wrappedValue.isEditing == true { Text("editing") }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(8)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar(.hidden, for: .navigationBar)
            .hidesTabBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarLeading) { Text("") }
            }
        }
        TabView { Text("a"); Text("b") }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        TabView { Text("c") }
            .tabViewStyle(.page)
    }
}
