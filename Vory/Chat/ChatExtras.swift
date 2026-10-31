import ImageIO
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import VoryCore

/// Last known session list per gateway + profile, so the Chats tab draws instantly on launch
/// and refreshes behind it. Small JSON in UserDefaults; Settings › Appearance can clear it. Never the demo's (#493):
/// nothing of it is kept, and a list an older build saved for it kept its chats' first times, so they aged.
enum SessionCache {
    static let prefix = "sessions.cache."

    static func key(connection: UUID, profile: String?) -> String { prefix + connection.uuidString + "." + (profile ?? "-") }

    static func load(connection: UUID, profile: String?) -> [StoredSession] {
        guard connection != GatewayConnection.demoID,
              let data = UserDefaults.standard.data(forKey: key(connection: connection, profile: profile)) else { return [] }
        return (try? JSONDecoder().decode([StoredSession].self, from: data)) ?? []
    }

    /// Any cached list for this gateway, whichever bot it was for: shown at a cold launch when
    /// the exact one is missing, so the page is never empty while the first load runs.
    static func loadAny(connection: UUID) -> [StoredSession] {
        guard connection != GatewayConnection.demoID else { return [] }
        let head = prefix + connection.uuidString + "."
        var best: [StoredSession] = []
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where k.hasPrefix(head) {
            if let data = v as? Data, let list = try? JSONDecoder().decode([StoredSession].self, from: data), list.count > best.count { best = list }
        }
        return best
    }

    static func save(_ sessions: [StoredSession], connection: UUID, profile: String?) {
        guard connection != GatewayConnection.demoID else { return }
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
    /// The faces kept across the background: a bot's own (`cached(profile:)`) and a fixed look's that asks to be
    /// kept (`cached(spec:keep:)`), each by its place (profile or spec, size, appearance, blink) with the look it
    /// was drawn for. A dictionary, not the NSCache: an NSCache empties itself as the app goes to the background,
    /// just before the system draws the app-switcher snapshot, so every leave drew every face again inside the
    /// snapshot, the off-screen tabs' menus included (#422). A place is drawn again only when its bot's look
    /// changes (`look(for:)`); a few bots' faces at a few sizes, a few MB at most. Emptied on memory pressure,
    /// to be drawn again as they are next asked for.
    @MainActor private(set) static var kept: [String: (look: String, image: UIImage)] = [:]
    /// Each place's other appearance, drawn once at idle after the first (`drawTwins`): the snapshot draws the
    /// app under both, and a face it finds missing is drawn inside it.
    @MainActor private static var twins: [() -> Void] = []
    @MainActor private static var twinsQueued = false
    @MainActor private static let pressure: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { kept.removeAll() } }
        source.activate()
        return source
    }()

    /// `make`, memoised by place and look: the thread draws one of these beside every reply, and a live
    /// bot view per row (glass, timeline) is what made a long thread stutter while scrolling.
    /// `closed`: the same face mid-blink, for a list row's blink by picture swap.
    @MainActor static func cached(profile: String, size: CGFloat = 28, scheme: ColorScheme = .light, closed: Bool = false) -> UIImage {
        face(profile: profile, size: size, scheme: scheme, closed: closed, twin: true)
    }

    @MainActor private static func face(profile: String, size: CGFloat, scheme: ColorScheme, closed: Bool, twin: Bool) -> UIImage {
        let place = "\(profile)|\(size)|\(scheme == .dark ? "d" : "l")|\(closed ? "shut" : "open")"
        let look = look(for: profile)
        if let hit = kept[place], hit.look == look { return hit.image }
        BotFace.stillBlink = closed ? 1 : 0
        let img = make(profile: profile, size: size, scheme: scheme)
        BotFace.stillBlink = 0
        keep(img, at: place, look: look)
        if twin {
            queueTwin { _ = face(profile: profile, size: size, scheme: scheme == .dark ? .light : .dark, closed: closed, twin: false) }
        }
        return img
    }

    /// What a bot's face is drawn from: its choice (with the all-bots glass setting), its colour, and its photo.
    @MainActor static func look(for profile: String) -> String {
        "\(BotAvatarStore.choice(for: profile).raw)|\(BotColors.hex(for: profile))|\(BotAvatarStore.glassAll)|\(BotAvatarStore.photoGeneration)"
    }

    /// A look that is not a bot's own (the Look tab's shape and eye tiles, the Companion card's
    /// bot): memoised by its spec. `closed`: mid-blink, for the blink by picture swap. `keep`: kept across the
    /// background with its other appearance drawn at idle, as a bot's own face is (the Companion card, on the
    /// Settings tab, is in the switcher snapshot); the Look tab's tiles (eighteen per colour, on a pushed page)
    /// stay in the NSCache.
    @MainActor static func cached(spec: BotLookSpec, size: CGFloat, scheme: ColorScheme, closed: Bool = false, keep keeps: Bool = false) -> UIImage {
        specFace(spec: spec, size: size, scheme: scheme, closed: closed, keep: keeps, twin: keeps)
    }

    @MainActor private static func specFace(spec: BotLookSpec, size: CGFloat, scheme: ColorScheme, closed: Bool, keep keeps: Bool, twin: Bool) -> UIImage {
        let key = "spec|\(spec.shape)|\(spec.eyes)|\(spec.hex)|\(spec.finish)|\(size)|\(scheme == .dark ? "d" : "l")|\(closed ? "shut" : "open")"
        if keeps, let hit = kept[key] { return hit.image }
        if !keeps, let hit = cache.object(forKey: key as NSString) { return hit }
        BotFace.stillBlink = closed ? 1 : 0
        let r = ImageRenderer(content: BotFaceView(spec: spec, size: size, active: false, drawn: true).environment(\.colorScheme, scheme))
        r.scale = 3
        r.isOpaque = false
        let img = (r.uiImage ?? UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in }).withRenderingMode(.alwaysOriginal)
        BotFace.stillBlink = 0
        if keeps {
            keep(img, at: key, look: "")
            if twin {
                queueTwin { _ = specFace(spec: spec, size: size, scheme: scheme == .dark ? .light : .dark, closed: closed, keep: true, twin: false) }
            }
        } else {
            cache.setObject(img, forKey: key as NSString)
        }
        return img
    }

    @MainActor private static func keep(_ image: UIImage, at place: String, look: String) {
        _ = pressure
        kept[place] = (look, image)
    }

    /// Draws the queued twins about a second after the first is queued, one per turn of the main actor, so a
    /// screen of new faces never draws its other appearance in one go.
    @MainActor private static func queueTwin(_ draw: @escaping @MainActor () -> Void) {
        twins.append(draw)
        guard !twinsQueued else { return }
        twinsQueued = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            while !twins.isEmpty {
                twins.removeFirst()()
                await Task.yield()
            }
            twinsQueued = false
        }
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
                    .voryGlassEffect(.regular.interactive(), in: .circle)
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
///
/// A text one text view cannot hold safely (`fitsOneView`) is drawn as #361's pieces in a lazy stack instead
/// (`PiecedText`, #421).
struct SelectableText: View {
    var text: String
    var monospaced = false
    /// What VoiceOver calls the text (the sheet's title).
    var label = "Text"
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if Self.fitsOneView(text, TextPieces.Limits.for(typeSize)) {
                SelectableTextView(text: text, monospaced: monospaced, label: label)
            } else {
                PiecedText(text: text, monospaced: monospaced, label: label)
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    /// Whether one text view can hold `text`. It lays a paragraph out as one block: a tool's output on one line of
    /// 2 MB (minified JSON) held the main thread for 4 s and drew blank, past the graphics card's largest texture,
    /// and a whole of megabytes made the view's accessibility tree too big to read (#421). A paragraph of twice a
    /// piece's characters is well under the limit here (a piece is worked out for a 150 pt column, a sheet is
    /// 300 pt or wider), so an ordinary reply keeps the text view and its selection across paragraphs. Counted in
    /// UTF-8 bytes, which are never fewer than the characters.
    static func fitsOneView(_ text: String, _ limits: TextPieces.Limits) -> Bool {
        let bytes = text.utf8.count
        if bytes > 100_000 { return false }
        let longest = 2 * limits.chars
        if bytes <= longest { return true }
        var run = 0
        for b in text.utf8 {
            if b == 0x0A { run = 0 } else { run += 1; if run > longest { return false } }
        }
        return true
    }
}

/// A whole text too big for one text view, as #361's pieces (`TextPieces.strings`) in a lazy stack: only the pieces
/// near the screen are laid out, drawn and in the accessibility tree, each its own element in reading order, and
/// none past the graphics card's largest texture. The cut runs off the main thread (a 10 MB output is many seconds
/// of it). A piece selects on its own; Copy and Share carry the whole text.
struct PiecedText: View {
    var text: String
    var monospaced: Bool
    var label: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var pieces: [String]?

    /// What the cut reads: a new text, or the text size's limits.
    private struct Cut: Hashable { var bytes: Int; var head: String; var tail: String; var limits: TextPieces.Limits; var code: Bool }

    var body: some View {
        let limits = TextPieces.Limits.for(typeSize)
        ScrollView {
            if let pieces {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(pieces.indices, id: \.self) { i in
                        Text(pieces[i])
                            .font(monospaced ? .system(.footnote, design: .monospaced) : .body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(PieceProbe.Measure())
                    }
                }
                .padding(12)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
                .accessibilityIdentifier("sheet.pieces")
                if PieceProbe.shared.on {
                    Text(PieceProbe.shared.summary).font(.system(size: 8)).accessibilityIdentifier("debug.pieces.sheet")
                }
            } else {
                Label("Laying out \(ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file))…", systemImage: "text.alignleft")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .task(id: Cut(bytes: text.utf8.count, head: String(text.prefix(64)), tail: String(text.suffix(64)), limits: limits, code: monospaced)) {
            let whole = text, code = monospaced
            pieces = await Task.detached(priority: .userInitiated) { TextPieces.strings(whole, code: code, limits) }.value
        }
    }
}

#if os(macOS)
/// On the Mac an AppKit text view too, as on the iPhone: SwiftUI's selectable `Text` drew the whole text as one
/// picture, and a long output past the graphics card's largest texture was an empty box (#361). The text view lays
/// out and draws only what is on screen (but a paragraph whole: `fitsOneView`), and selects by range as before.
private struct SelectableTextView: NSViewRepresentable {
    var text: String
    var monospaced: Bool
    var label: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        if let v = scroll.documentView as? NSTextView {
            v.isEditable = false
            v.isSelectable = true
            v.drawsBackground = false
            v.textContainerInset = NSSize(width: 12, height: 12)
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let v = scroll.documentView as? NSTextView else { return }
        if v.string != text { v.string = text }
        // Only when it changes: setting the font lays the whole text out again (100 KB on a Show all sheet).
        let font: NSFont = monospaced ? .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
                                      : .preferredFont(forTextStyle: .body)
        if v.font != font { v.font = font }
        if v.textColor != .labelColor { v.textColor = .labelColor }
        if v.accessibilityLabel() != label { v.setAccessibilityLabel(label) }
    }
}
#else
private struct SelectableTextView: UIViewRepresentable {
    var text: String
    var monospaced: Bool
    var label: String
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
        // Only what changed: setting the font lays the whole text out again (100 KB on a Show all sheet).
        let font = monospaced ? UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular) : UIFont.preferredFont(forTextStyle: .body)
        if v.font != font { v.font = font }
        if v.textColor != .label { v.textColor = .label }
        if v.accessibilityLabel != label { v.accessibilityLabel = label }
        if v.text != text { v.text = text }
    }
}
#endif

struct SelectTextSheet: View {
    /// What the text is: "Select Text" for a message's own, the bot's name and "Reasoning" for a reasoning shown whole.
    var title = "Select Text"
    var text: String
    var monospaced = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            SelectableText(text: text, monospaced: monospaced, label: title)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Done, a swipe down on the phone, Escape on the Mac.
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .primaryAction) { Button { UIPasteboard.general.string = text } label: { Label("Copy all", systemImage: "doc.on.doc") } }
            }
        }
    }
}

/// Small decoded previews of attachment images, by file and size, so a row never holds the
/// full-resolution bitmap.
/// `scale` is the display's scale where the picture will show (`\.displayScale` in the view
/// that asks), not the main screen's: an external display or the Duo's other display can differ.
enum AttachmentThumbs {
    @MainActor private static let cache = NSCache<NSString, UIImage>()
    private static func key(_ url: URL, _ side: CGFloat, _ scale: CGFloat) -> NSString { "\(url.path)|\(Int(side))|\(scale)" as NSString }

    @MainActor static func image(at url: URL, side: CGFloat, scale: CGFloat) -> UIImage? {
        let key = key(url, side, scale)
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = decode(at: url, pixels: Int(side * scale)) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// The same, decoded off the main thread: a row's thumbnails and the viewer's picture are
    /// made where a scroll does not wait for them.
    @MainActor static func imageAsync(at url: URL, side: CGFloat, scale: CGFloat) async -> UIImage? {
        let key = key(url, side, scale)
        if let hit = cache.object(forKey: key) { return hit }
        let pixels = Int(side * scale)
        let box = await Task.detached(priority: .userInitiated) { Box(decode(at: url, pixels: pixels)) }.value
        if let image = box.image { cache.setObject(image, forKey: key) }
        return box.image
    }

    /// The file downsampled to at most `pixels` a side, never the whole bitmap.
    nonisolated static func decode(at url: URL, pixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCache: false]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private final class Box: @unchecked Sendable { let image: UIImage?; init(_ image: UIImage?) { self.image = image } }
}
