import ImageIO
import SwiftUI
import UIKit
import VoryCore

/// Last known session list per gateway + profile, so the Chats tab draws instantly on launch
/// and refreshes behind it. Small JSON in UserDefaults; Settings › Appearance can clear it.
enum SessionCache {
    static let prefix = "sessions.cache."

    static func key(connection: UUID, profile: String?) -> String { prefix + connection.uuidString + "." + (profile ?? "-") }

    static func load(connection: UUID, profile: String?) -> [StoredSession] {
        guard let data = UserDefaults.standard.data(forKey: key(connection: connection, profile: profile)) else { return [] }
        return (try? JSONDecoder().decode([StoredSession].self, from: data)) ?? []
    }

    /// Any cached list for this gateway, whichever bot it was for: shown at a cold launch when
    /// the exact one is missing, so the page is never empty while the first load runs.
    static func loadAny(connection: UUID) -> [StoredSession] {
        let head = prefix + connection.uuidString + "."
        var best: [StoredSession] = []
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where k.hasPrefix(head) {
            if let data = v as? Data, let list = try? JSONDecoder().decode([StoredSession].self, from: data), list.count > best.count { best = list }
        }
        return best
    }

    static func save(_ sessions: [StoredSession], connection: UUID, profile: String?) {
        if let data = try? JSONEncoder().encode(sessions) { UserDefaults.standard.set(data, forKey: key(connection: connection, profile: profile)) }
    }

    static func clearAll() {
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix(prefix) { d.removeObject(forKey: k) }
    }

    static var approximateBytes: Int {
        let d = UserDefaults.standard
        return d.dictionaryRepresentation().filter { $0.key.hasPrefix(prefix) }.values.compactMap { ($0 as? Data)?.count }.reduce(0, +)
    }
}

/// A bot avatar rendered to a UIImage, for places SwiftUI cannot draw a view — menu item icons.
enum BotAvatarImage {
    @MainActor private static let cache = NSCache<NSString, UIImage>()
    /// `make`, memoised by look: the thread draws one of these beside every reply, and a live
    /// bot view per row (glass, timeline) is what made a long thread stutter while scrolling.
    @MainActor static func cached(profile: String, size: CGFloat = 28, scheme: ColorScheme = .light) -> UIImage {
        let key = "\(profile)|\(size)|\(scheme == .dark ? "d" : "l")|\(BotAvatarStore.choice(for: profile).raw)|\(BotColors.hex(for: profile))|\(BotAvatarStore.glassAll)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img = make(profile: profile, size: size, scheme: scheme)
        cache.setObject(img, forKey: key)
        return img
    }

    @MainActor static func make(profile: String, size: CGFloat = 28, scheme: ColorScheme = .light) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        if BotAvatarStore.choice(for: profile) == .photo, let photo = BotAvatarStore.photo(for: profile) {
            return renderer.image { ctx in
                ctx.cgContext.addEllipse(in: CGRect(x: 0, y: 0, width: size, height: size)); ctx.cgContext.clip()
                photo.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
            }.withRenderingMode(.alwaysOriginal)
        }
        // The studio bot itself, painted (glass cannot render offscreen), at 3x for the menu.
        let spec = BotAvatarStore.choice(for: profile).spec(hex: BotColors.hex(for: profile))
        let r = ImageRenderer(content: BotFaceView(spec: spec, size: size, active: false, drawn: true).environment(\.colorScheme, scheme))
        r.scale = 3
        r.isOpaque = false
        return (r.uiImage ?? renderer.image { _ in }).withRenderingMode(.alwaysOriginal)
    }
}

/// Floating glass "↓" that appears once the transcript is scrolled away from the bottom.
struct JumpToBottomButton: View {
    var visible: Bool
    var action: () -> Void
    var body: some View {
        if visible {
            Button(action: action) {
                Image(systemName: "chevron.down").font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Jump to latest")
            .transition(.scale.combined(with: .opacity))
        }
    }
}

/// The whole message as plain, selectable text — for copying just a part of it.
/// Text you can select by range, with the handles and the Copy/Look Up menu UIKit gives: SwiftUI's
/// own selectable text offers Copy and Share for the whole thing and nothing in between (a
/// tester: "the select text window doesn't work").
struct SelectableText: UIViewRepresentable {
    var text: String
    var monospaced = false
    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.isScrollEnabled = true
        v.alwaysBounceVertical = true
        v.backgroundColor = .clear
        v.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        v.dataDetectorTypes = [.link]
        v.adjustsFontForContentSizeCategory = true
        return v
    }
    func updateUIView(_ v: UITextView, context: Context) {
        v.font = monospaced ? UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular) : UIFont.preferredFont(forTextStyle: .body)
        v.textColor = .label
        if v.text != text { v.text = text }
    }
}

struct SelectTextSheet: View {
    var text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            SelectableText(text: text)
            .navigationTitle("Select Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { UIPasteboard.general.string = text } label: { Label("Copy all", systemImage: "doc.on.doc") } }
            }
        }
    }
}

/// Small decoded previews of attachment images, by file and size, so a row never holds the
/// full-resolution bitmap.
enum AttachmentThumbs {
    @MainActor private static let cache = NSCache<NSString, UIImage>()
    @MainActor static func image(at url: URL, side: CGFloat) -> UIImage? {
        let key = "\(url.path)|\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let pixels = Int(side * UIScreen.main.scale)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCache: false]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: key)
        return image
    }
}
