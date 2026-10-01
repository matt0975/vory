import SwiftUI

/// The accent the app is tinted with: buttons, the selected tab, your bubbles, links. Chosen in
/// Settings › Appearance; "Blue" is the app's own.
enum AppTheme {
    static let accentKey = "theme.accent"

    struct Accent: Identifiable, Equatable {
        var id: String
        var name: String
        var color: Color
    }

    static let accents: [Accent] = [
        Accent(id: "blue", name: "Blue", color: Color(red: 0.0, green: 0.478, blue: 1.0)),
        Accent(id: "indigo", name: "Indigo", color: Color(red: 0.345, green: 0.337, blue: 0.839)),
        Accent(id: "teal", name: "Teal", color: Color(red: 0.188, green: 0.69, blue: 0.78)),
        Accent(id: "green", name: "Green", color: Color(red: 0.204, green: 0.78, blue: 0.349)),
        Accent(id: "orange", name: "Orange", color: Color(red: 1.0, green: 0.584, blue: 0.0)),
        Accent(id: "pink", name: "Pink", color: Color(red: 1.0, green: 0.176, blue: 0.333)),
        Accent(id: "purple", name: "Purple", color: Color(red: 0.686, green: 0.322, blue: 0.871)),
        Accent(id: "graphite", name: "Graphite", color: Color(red: 0.557, green: 0.557, blue: 0.576)),
    ]

    static func accent(_ id: String) -> Accent { accents.first { $0.id == id } ?? accents[0] }

    /// The current accent, for views that paint it themselves (the message bubble).
    static var current: Color { accent(UserDefaults.standard.string(forKey: accentKey) ?? "blue").color }
}

extension Color {
    /// The chosen accent as a colour (`.tint` as a style follows it on its own; a fill needs this).
    static var vory: Color { AppTheme.current }
}

/// Settings › Appearance: one swatch per accent, the chosen one ringed.
struct AccentPicker: View {
    @AppStorage(AppTheme.accentKey) private var accentID = "blue"

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(AppTheme.accents) { a in
                    Button { withAnimation(.snappy) { accentID = a.id } } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(a.color).frame(width: 34, height: 34)
                                if accentID == a.id { Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(.white) }
                            }
                            .overlay(Circle().strokeBorder(accentID == a.id ? a.color.opacity(0.5) : .clear, lineWidth: 3).padding(-4))
                            Text(a.name).font(.caption2).foregroundStyle(accentID == a.id ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(a.name)
                    .accessibilityAddTraits(accentID == a.id ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
        }
    }
}
