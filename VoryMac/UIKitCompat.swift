import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// The UIKit spellings the shared views use that have a direct AppKit twin, so those files read
// the same on both platforms: an image, the pasteboard, the screen scale, an offscreen renderer.
// Anything without a twin (scroll-view probes, the keyboard, gestures) is `#if os(iOS)` in place.

typealias UIImage = NSImage

extension NSImage {
    enum RenderingMode { case automatic, alwaysOriginal, alwaysTemplate }

    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Template rendering is a per-`Image` choice in SwiftUI on the Mac; the image itself is unchanged.
    func withRenderingMode(_ mode: RenderingMode) -> NSImage { self }

    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cg = cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    func pngData() -> Data? {
        guard let cg = cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// A copy scaled to fit inside `size` in pixels, aspect kept (what UIKit's `preparingThumbnail` does).
    func preparingThumbnail(of size: CGSize) -> NSImage? {
        guard self.size.width > 0, self.size.height > 0 else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let box = CGSize(width: size.width / scale, height: size.height / scale)
        let ratio = min(box.width / self.size.width, box.height / self.size.height, 1)
        let points = CGSize(width: self.size.width * ratio, height: self.size.height * ratio)
        let source = self
        return NSImage(size: points, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            return true
        }
    }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

extension ImageRenderer {
    @MainActor var uiImage: NSImage? { nsImage }
}

extension QLThumbnailRepresentation {
    var uiImage: NSImage { nsImage }
}

/// `UIGraphicsImageRenderer`: an image drawn by a closure, in points, with UIKit's top-left
/// origin. Backed by a drawing-handler image, so it renders at whatever scale it is shown at.
final class UIGraphicsImageRendererFormat {
    var scale: CGFloat = 0
    init() {}
}

final class UIGraphicsImageRenderer {
    struct Context { let cgContext: CGContext }
    let size: CGSize

    init(size: CGSize) { self.size = size }
    init(size: CGSize, format: UIGraphicsImageRendererFormat) { self.size = size }

    func image(actions: @escaping (Context) -> Void) -> NSImage {
        NSImage(size: size, flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            actions(Context(cgContext: cg))
            return true
        }
    }
}

/// The general pasteboard, with UIKit's questions answered from `NSPasteboard`.
struct UIPasteboard {
    static var general: UIPasteboard { UIPasteboard() }
    private var pb: NSPasteboard { NSPasteboard.general }

    var string: String? {
        get { pb.string(forType: .string) }
        nonmutating set {
            pb.clearContents()
            if let newValue { pb.setString(newValue, forType: .string) }
        }
    }
    var image: NSImage? { NSImage(pasteboard: pb) }
    var hasStrings: Bool { pb.string(forType: .string) != nil }
    var hasImages: Bool { pb.canReadObject(forClasses: [NSImage.self], options: nil) }
    var hasURLs: Bool { pb.canReadObject(forClasses: [NSURL.self], options: nil) }
    var numberOfItems: Int { pb.pasteboardItems?.count ?? 0 }
    /// Each item's data by type identifier, UIKit's shape.
    var items: [[String: Any]] {
        (pb.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t.rawValue, $0 as Any) } })
        }
    }
    /// The pasteboard's items as providers, for the types the composer accepts.
    var itemProviders: [NSItemProvider] {
        (pb.pasteboardItems ?? []).map { item in
            let p = NSItemProvider()
            for t in item.types {
                guard let ut = UTType(t.rawValue) else { continue }
                p.registerDataRepresentation(forTypeIdentifier: ut.identifier, visibility: .all) { done in
                    done(item.data(forType: t), nil); return nil
                }
            }
            return p
        }
    }
}

/// `UIScreen.main`: the main display's scale and frame.
struct UIScreen {
    static let main = UIScreen()
    var scale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }
    var bounds: CGRect { NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900) }
}
