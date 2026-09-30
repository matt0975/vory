import SwiftUI

/// The header card at the top of every Settings sub-page, like iOS's own: the icon on a large
/// tile, the page's name and one line on what lives here. Scrolls with the list.
struct SettingsHeaderSection: View {
    var title: String
    var symbol: String
    var color: Color
    var description: String
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 60, height: 60).background(color.gradient, in: .rect(cornerRadius: 14))
                Text(title).font(.title.weight(.bold))
                Text(description).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }
}
