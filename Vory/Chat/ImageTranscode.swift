import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import UniformTypeIdentifiers
import VoryCore

/// Images the gateway refuses go up as JPEG instead. The photo library hands over HEIC for
/// most shots; the gateway's image attach knows JPEG, PNG, GIF and WebP.
enum ImageTranscode {
    static let accepted: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]

    static func install() {
        ChatSession.imageTranscoder = { data, name in
            let ext = (name as NSString).pathExtension.lowercased()
            if accepted.contains(ext) { return nil }
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            // Orientation travels in the source's properties; keep it so the photo is not sideways.
            var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.88]
            if let meta = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any], let o = meta[kCGImagePropertyOrientation] { props[kCGImagePropertyOrientation] = o }
            CGImageDestinationAddImage(dest, img, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            let stem = (name as NSString).deletingPathExtension
            return (out as Data, (stem.isEmpty ? "photo" : stem) + ".jpg")
        }
    }
}

/// A soft tick as reply text arrives, like a typewriter under the thumb. Settings › Notifications
/// › Typing haptics (beta). Throttled so a fast stream is a purr, not a rattle; only for the chat
/// on screen, only while the app is in front.
@MainActor
final class TypingHaptics {
    static let shared = TypingHaptics()
    static let key = "chat.typingHaptics"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) && (UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true) }

    #if os(iOS)
    private let generator = UIImpactFeedbackGenerator(style: .soft)
    #endif
    private var last = Date.distantPast
    private var pending = 0

    func start() {
        NotificationCenter.default.addObserver(forName: .hermesStreamDelta, object: nil, queue: .main) { [weak self] n in
            let sid = n.userInfo?["storedID"] as? String
            let count = n.userInfo?["count"] as? Int ?? 1
            Task { @MainActor in self?.tick(storedID: sid, count: count) }
        }
    }

    private func tick(storedID: String?, count: Int) {
        guard Self.isOn, LocalNotifier.isForeground, let sid = storedID, AppModel.shared.visibleChatID == sid else { return }
        pending += count
        let now = Date()
        // At most about eight ticks a second; a bigger burst of text lands a touch firmer.
        guard now.timeIntervalSince(last) > 0.12 else { return }
        last = now
        let intensity = min(1, 0.35 + CGFloat(pending) / 60)
        pending = 0
        #if os(iOS)
        generator.impactOccurred(intensity: intensity)
        generator.prepare()
        #else
        _ = intensity   // no Taptic Engine under the keys
        #endif
    }
}
