import Intents
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import UserNotifications
import VoryCore

/// Decrypts relay-delivered notifications. The relay only carries `enc`; this rewrites the
/// placeholder title/body with the real ones using the key the app minted for this install, then
/// presents the result like a message from the bot (its avatar as the large icon, the app icon
/// small on it), the way Messages notifications look.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        let mutable = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content = mutable
        Keychain.accessGroup = Keychain.sharedGroupFromBundle()
        guard let enc = request.content.userInfo["enc"] as? String else {
            Self.breadcrumb("plain notification (no enc)")
            Self.deliverAsMessage(mutable, profile: (request.content.userInfo["hermes"] as? [String: Any])?["profile"] as? String ?? "", handler: contentHandler)
            return
        }
        guard let creds = Keychain.getCodable(PushRelay.Credentials.self, account: PushRelay.credentialsAccount) else {
            Self.breadcrumb("no relay credentials readable (group \(Keychain.accessGroup ?? "none"))"); contentHandler(mutable); return
        }
        let payload: [String: JSONValue]
        do { payload = try PushRelay.decrypt(enc, keyBase64: creds.payloadKey) }
        catch { Self.breadcrumb("decrypt failed: \(error.localizedDescription)"); contentHandler(mutable); return }
        Self.breadcrumb("decrypted OK")
        if let t = payload["title"]?.stringValue { mutable.title = t }
        if let s = payload["subtitle"]?.stringValue { mutable.subtitle = s }
        if let b = payload["body"]?.stringValue { mutable.body = b }
        if let c = payload["category"]?.stringValue { mutable.categoryIdentifier = c }
        if let th = payload["thread_id"]?.stringValue, !th.isEmpty { mutable.threadIdentifier = th }
        if payload["interruption"]?.stringValue == "time-sensitive" { mutable.interruptionLevel = .timeSensitive }
        var profile = ""
        if let hermes = payload["hermes"]?.objectValue {
            var info = mutable.userInfo
            info["hermes"] = hermes.mapValues { $0.foundationValue }
            mutable.userInfo = info
            profile = hermes["profile"]?.stringValue ?? ""
        }
        Self.deliverAsMessage(mutable, profile: profile, handler: contentHandler)
    }

    /// Turn/approval/question notifications come from a bot, so they are presented as a message
    /// from it. Anything else (the test notification) keeps the plain app look.
    private static func deliverAsMessage(_ content: UNMutableNotificationContent, profile: String, handler: @escaping (UNNotificationContent) -> Void) {
        let botCategories: Set<String> = ["HERMES_TURN", "HERMES_ERROR", "HERMES_APPROVAL", "HERMES_CLARIFY"]
        guard botCategories.contains(content.categoryIdentifier), !content.title.isEmpty else { handler(content); return }
        let kind = (content.userInfo["hermes"] as? [String: Any])?["kind"] as? String ?? ""
        // The avatar is rendered with SwiftUI's ImageRenderer, which needs the main actor. Neither the
        // content nor the system's handler is Sendable; nothing else touches them after this point.
        nonisolated(unsafe) let content = content
        nonisolated(unsafe) let handler = handler
        Task { @MainActor in
            handler(asMessage(content, profile: profile, kind: kind))
        }
    }

    @MainActor
    private static func asMessage(_ content: UNMutableNotificationContent, profile: String, kind: String) -> UNNotificationContent {
        var looks = BotLooks.load()
        var profile = profile
        if kind == "test" {
            // The test notification comes from no bot in particular: Vory's own little cloud, the
            // same glass one the app shows. No reply action or reply window for a test.
            profile = "vory"
            looks.avatars["vory"] = "studio:cloud:classic:glass"
            looks.colors["vory"] = "#3B7BFF"
            content.categoryIdentifier = "HERMES_TEST"
        }
        // The title is "<bot>" or "<bot> · approval needed": the sender is the part before the dot.
        let bot = content.title.components(separatedBy: " · ").first ?? content.title
        let key = looks.key(profile: profile, label: bot) ?? profile
        breadcrumb("look for profile '\(profile)' / bot '\(bot)' → \(key.isEmpty ? "none" : key) (mirror has \(looks.avatars.count) bots)")
        let png = AvatarRender.image(profile: key, name: bot, looks: looks)
        let handle = INPersonHandle(value: profile.isEmpty ? bot : profile, type: .unknown)
        let sender = INPerson(personHandle: handle, nameComponents: nil, displayName: bot, image: png.map { INImage(imageData: $0) },
                              contactIdentifier: nil, customIdentifier: profile.isEmpty ? bot : profile, isMe: false, suggestionType: .none)
        let conversation = content.threadIdentifier.isEmpty ? (profile.isEmpty ? bot : profile) : content.threadIdentifier
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: content.body,
                                         speakableGroupName: nil, conversationIdentifier: conversation, serviceName: nil,
                                         sender: sender, attachments: nil)
        #if os(iOS)
        if let png { intent.setImage(INImage(imageData: png), forParameterNamed: \.sender) }
        #endif
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        do {
            let styled = try content.updating(from: intent)
            breadcrumb("presented as a message from \(bot)")
            return styled
        } catch {
            breadcrumb("message style failed: \(error.localizedDescription)")
            return content
        }
    }

    /// One line the app reads back (Background Notifications page) to show what happened last time.
    static func breadcrumb(_ what: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(what)"
        try? Keychain.set(Data(line.utf8), account: "push.nse.last")
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let content { handler(content) }
    }
}

/// Renders the bot's avatar (photo thumbnail, or the studio bot as a still frame) to PNG for the
/// notification's sender image.
enum AvatarRender {
    @MainActor
    static func image(profile: String, name: String, looks: BotLooks) -> Data? {
        let choice = looks.avatars[profile] ?? ""
        if choice == "photo", let data = looks.photos[profile] {
            return roundPhoto(data)
        }
        let spec = BotLookSpec.from(choice: choice, hex: looks.colors[profile] ?? "#7C5CFF")
        let renderer = ImageRenderer(content: BotFaceView(spec: spec, size: 128, active: false).padding(6))
        renderer.scale = 2
        renderer.isOpaque = false
        #if canImport(UIKit)
        return renderer.uiImage?.pngData()
        #else
        return renderer.nsImage.flatMap(png)
        #endif
    }

    /// The photo rounded like a contact's, as PNG.
    private static func roundPhoto(_ data: Data) -> Data? {
        let side: CGFloat = 256
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { ctx in
            ctx.cgContext.addEllipse(in: CGRect(x: 0, y: 0, width: side, height: side)); ctx.cgContext.clip()
            let scale = side / min(ui.size.width, ui.size.height)
            let w = ui.size.width * scale, h = ui.size.height * scale
            ui.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }.pngData()
        #else
        guard let ns = NSImage(data: data), ns.size.width > 0, ns.size.height > 0 else { return nil }
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            let scale = side / min(ns.size.width, ns.size.height)
            let w = ns.size.width * scale, h = ns.size.height * scale
            ns.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        return png(img)
        #endif
    }

    #if !canImport(UIKit)
    private static func png(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
    #endif
}

extension Color {
    init?(hexString: String) {
        var s = hexString; if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
