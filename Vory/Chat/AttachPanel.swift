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
    /// Whether the panel draws its own glass. The chat's composer draws it instead, as the
    /// shape that grows out of the + button; the New Message sheet takes the default.
    var surface = true
    /// The most height the panel may take; taller than that, its rows scroll. The composer sets
    /// it to the room between the header and the card, so with the keyboard up (which stays up)
    /// the panel never runs into the bot's pill.
    var cap: CGFloat? = nil
    /// Folds the panel away; called before a row's action.
    var close: () -> Void

    /// A row is a 40 pt icon with 8 pt above and below; the stack adds 10 pt at each end.
    private var naturalHeight: CGFloat { Self.naturalHeight(rows: items.count) }
    static func naturalHeight(rows: Int) -> CGFloat { CGFloat(rows) * 56 + 20 }

    /// The room above the card for the panel: from 10 pt above the card's top up to the chat's header. The header's
    /// measured bottom (window space) where it reaches lower than the 60 pt under the safe area the panel always
    /// allowed, so the panel stops under it: on the iPhone 17 Pro the chat's row ends at 129.7 (safe area 62), and with
    /// the keyboard up the old line (122) let the panel reach 7.7 pt over Back and the title; the closed Duo the same;
    /// the open Duo's laptop pose (to 150) and a wide window's title pill (to 92) more.
    static func room(cardTop: CGFloat, safeTop: CGFloat, headerBottom: CGFloat) -> CGFloat {
        cardTop - max(safeTop + 60, headerBottom) - 10
    }

    var body: some View {
        if let cap, naturalHeight > cap {
            ScrollView { rows }
                .scrollIndicators(.hidden)
                .frame(width: 272, height: cap)
                .modifier(PanelSurface(on: surface))
        } else {
            rows
                .frame(width: 272)
                // The panel is an overlay on a 36 pt button, so it is offered 36 pt of height; without
                // its own size the glass was drawn for less than the rows and the last one poked out.
                .fixedSize()
                // `-vory-plain-panel` (measurement only): a plain material instead of glass, to tell
                // whether the glass morph is what holds the panel's animation at 60 Hz on ProMotion.
                .modifier(PanelSurface(on: surface))
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                Button {
                    close()
                    item.action()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: item.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(item.color, in: .circle)
                            .accessibilityHidden(true)
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
    }
}


/// The panel's surface: glass, or a plain material under `-vory-plain-panel` (a frame-rate experiment).
struct PanelSurface: ViewModifier {
    var on = true
    /// The glass shape: the panel's own corners, or the growing shape the composer animates.
    var shape: RoundedRectangle = .rect(cornerRadius: 30)
    static let plain = ProcessInfo.processInfo.arguments.contains("-vory-plain-panel")
    /// `-vory-solid-panel`: a flat colour, no material at all (the same spring drives it).
    static let solid = ProcessInfo.processInfo.arguments.contains("-vory-solid-panel")
    func body(content: Content) -> some View {
        // One modifier whatever `on` says (`.identity` glass when off): switching between a
        // glass branch and a plain one changed the subtree's identity inside the glass
        // container, and the replaced subtree stayed on screen at full size (the "/" rows
        // left over on the card after a close, Matt, 2026-10-11).
        if Self.solid {
            content.background(on ? Color(.secondarySystemBackground) : .clear, in: shape)
        } else if Self.plain {
            content.background(on ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear), in: shape)
        } else {
            content.glassEffect(on ? .regular : .identity, in: shape)
        }
    }
}
