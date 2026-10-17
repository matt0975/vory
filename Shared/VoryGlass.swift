import SwiftUI

/// Vory's glass vocabulary with a material fallback for systems before the
/// native Liquid Glass APIs. Keeping the compatibility boundary here lets the
/// rest of the shared UI remain one implementation on iOS, macOS and watchOS.
struct VoryGlass: Sendable {
    enum Kind: Sendable { case regular, clear }

    var kind: Kind
    var color: Color?
    var respondsToInput = false

    static let regular = VoryGlass(kind: .regular, color: nil)
    static let clear = VoryGlass(kind: .clear, color: nil)

    func tint(_ color: Color?) -> VoryGlass {
        var copy = self
        copy.color = color
        return copy
    }

    func interactive(_ enabled: Bool = true) -> VoryGlass {
        var copy = self
        copy.respondsToInput = enabled
        return copy
    }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *)
    fileprivate var native: Glass {
        var value: Glass = kind == .clear ? .clear : .regular
        value = value.tint(color)
        return respondsToInput ? value.interactive() : value
    }
}

/// The native shared sampling container where it exists; a transparent layout
/// container on Sequoia and other older systems.
struct VoryGlassEffectContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

enum VoryGlassTransition: Sendable {
    case identity
    case matchedGeometry
}

private struct VoryGlassFallback<S: Shape>: ViewModifier {
    let glass: VoryGlass
    let shape: S

    func body(content: Content) -> some View {
        content.background {
            shape
                .fill(glass.kind == .clear ? .thinMaterial : .regularMaterial)
                .overlay {
                    if let color = glass.color { shape.fill(color.opacity(0.32)) }
                }
        }
    }
}

extension View {
    /// `safeAreaBar` arrived with macOS 26. Sequoia uses an ordinary inset in
    /// the same position, keeping the list controls visible without linking a
    /// Tahoe-only SwiftUI symbol into the macOS 15 path.
    @ViewBuilder
    func vorySafeAreaTopBar<Bar: View>(spacing: CGFloat? = nil, @ViewBuilder content: () -> Bar) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: .top, spacing: spacing, content: content)
        }
        #else
        safeAreaInset(edge: .top, spacing: spacing, content: content)
        #endif
    }

    @ViewBuilder
    func voryGlassEffect<S: Shape>(_ glass: VoryGlass = .regular, in shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            self.glassEffect(glass.native, in: shape)
        } else {
            modifier(VoryGlassFallback(glass: glass, shape: shape))
        }
    }

    @ViewBuilder
    func voryGlassEffectID<ID: Hashable & Sendable>(_ id: ID?, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func voryGlassEffectTransition(_ transition: VoryGlassTransition) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            switch transition {
            case .identity: glassEffectTransition(.identity)
            case .matchedGeometry: glassEffectTransition(.matchedGeometry)
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func voryGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) }
            else { buttonStyle(.glass) }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
