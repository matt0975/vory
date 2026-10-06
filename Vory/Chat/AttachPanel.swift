import SwiftUI

/// One row of the + panel.
struct AttachItem: Identifiable {
    var title: String
    var symbol: String
    var color: Color
    var disabled = false
    var action: () -> Void
    var id: String { title }
}

/// The + panel: a tall glass sheet of big round icons like the one in Messages, grown out of
/// the button and folded back into it. A chat's composer and the New Message sheet share it.
struct AttachPanel: View {
    var items: [AttachItem]
    /// Folds the panel away; called before a row's action.
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                Button {
                    close()
                    item.action()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: item.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(item.color, in: .circle)
                        Text(item.title).font(.title3).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(item.disabled)
                .opacity(item.disabled ? 0.4 : 1)
                .accessibilityIdentifier("attach." + item.title.lowercased().replacingOccurrences(of: " ", with: "-"))
            }
        }
        .padding(.vertical, 10)
        .frame(width: 272)
        // The panel is an overlay on a 36 pt button, so it is offered 36 pt of height; without
        // its own size the glass was drawn for less than the rows and the last one poked out.
        .fixedSize()
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
    }
}
