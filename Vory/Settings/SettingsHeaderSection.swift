import SwiftUI

/// The header card at the top of every Settings sub-page, like iOS's own: the icon on a large
/// tile, the page's name and one line on what lives here. Scrolls with the list.
struct SettingsHeaderSection: View {
    var title: String
    var symbol: String
    var color: Color
    var description: String
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // At the accessibility text sizes the tile is left out (#644): the title and the description grow
                // with the text and the tile doesn't, and the three stacked pushed the page's first rows off the
                // screen. The tile is decoration; the title says what the page is.
                if !typeSize.isAccessibilitySize {
                    Image(systemName: symbol).font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 60, height: 60).background(color.gradient, in: .rect(cornerRadius: 14))
                        // The title under it says what the page is; the icon read its own name (#409).
                        .accessibilityHidden(true)
                }
                Text(title).font(.title.weight(.bold))
                Text(description).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }
}
