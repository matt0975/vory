import SwiftUI

/// A sheet that is as tall as what it holds, with its content hung from the top.
///
/// A centred stack inside a medium detent overflows at both ends once it is taller than the
/// detent: on a short phone the bot at the top slid under the grabber and the last line was
/// cut off. Here the content is measured, the detent follows it (the full height when it
/// would not fit), the top always clears the grabber, and it scrolls if it must. The
/// background is opaque enough that the screen behind does not show through the words.
struct FittedSheet<Content: View>: View {
    private let content: Content
    @State private var height: CGFloat = 420

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    /// Room for the grabber and a breath under it.
    private static var topClearance: CGFloat { 40 }

    var body: some View {
        ScrollView {
            content
                .padding(.top, Self.topClearance)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        #if os(macOS)
        // A Mac sheet is as big as its content asks to be, and a scroll view asks for nothing.
        .frame(width: 460, height: min(height, 640))
        #endif
        .presentationDetents([.height(height), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thickMaterial)
    }
}
