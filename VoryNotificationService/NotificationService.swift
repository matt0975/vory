import Intents
import os
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
    private var once: HandlerOnce?

    override init() {
        super.init()
        NSELog.line("nse init t+\(NSELog.sinceStart())")
    }

    /// Returns at once (#455): the keychain read and the decrypt run on PushIntake's own queue, and what they find
    /// fills the content there, so the system hears back from `didReceive` however long the Keychain takes.
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let enc = request.content.userInfo["enc"] as? String
        NSELog.line("nse receive t+\(NSELog.sinceStart()) enc \(enc == nil ? 0 : 1)")
        let once = HandlerOnce(contentHandler, asItCame: request.content)
        self.once = once
        // Not Sendable: only the outcome's one path touches it; the expiry gets it only once it's filled (`HandlerOnce`).
        nonisolated(unsafe) let mutable = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        Keychain.accessGroup = Keychain.sharedGroupFromBundle()
        let plainProfile = (request.content.userInfo["hermes"] as? [String: Any])?["profile"] as? String ?? ""
        let read = NSELog.Mark()
        PushIntake.begin(enc: enc, credentials: {
            let began = DispatchTime.now().uptimeNanoseconds
            let creds = Keychain.getCodable(PushRelay.Credentials.self, account: PushRelay.credentialsAccount)
            NSELog.line("nse credentials \(NSELog.ms(since: began)) ms found \(creds == nil ? 0 : 1)")
            read.at = DispatchTime.now().uptimeNanoseconds
            return creds
        }, done: { outcome in
            switch outcome {
            case .plain:
                NotificationService.breadcrumb("plain notification (no enc)")
                NotificationService.deliverAsMessage(mutable, profile: plainProfile, handler: { once.call($0, via: "plain") })
            case .noCredentials:
                NotificationService.breadcrumb("no relay credentials readable (group \(Keychain.accessGroup ?? "none"))")
                once.call(mutable, via: "fallback")
            case .failed(let why):
                NSELog.line("nse decrypt \(NSELog.ms(since: read.at)) ms ok 0")
                NotificationService.breadcrumb("decrypt failed: \(why)")
                once.call(mutable, via: "fallback")
            case .decrypted(let payload):
                NSELog.line("nse decrypt \(NSELog.ms(since: read.at)) ms ok 1")
                NotificationService.breadcrumb("decrypted OK")
                let profile = NotificationService.fill(mutable, from: payload)
                once.filled(mutable)
                NotificationService.deliverAsMessage(mutable, profile: profile, handler: { once.call($0, via: "decrypted") })
            }
        })
    }

    /// The decrypted fields onto the content; the bot's profile, for the message look.
    private static func fill(_ mutable: UNMutableNotificationContent, from payload: [String: JSONValue]) -> String {
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
        return profile
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
        // The looks of the gateway the push comes from (#573), not only the one in use.
        var looks = BotLooks.load().forGateway((content.userInfo["hermes"] as? [String: Any])?["connection_id"] as? String)
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
        NSELog.line("nse render begin")
        let rendering = DispatchTime.now().uptimeNanoseconds
        let png = AvatarRender.image(profile: key, name: bot, looks: looks)
        NSELog.line("nse render \(NSELog.ms(since: rendering)) ms")
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
        let began = DispatchTime.now().uptimeNanoseconds
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(what)"
        try? Keychain.set(Data(line.utf8), account: "push.nse.last")
        NSELog.line("nse breadcrumb \(NSELog.ms(since: began)) ms")
    }

    override func serviceExtensionTimeWillExpire() {
        once?.expire()
    }
}

/// The system's handler, called once (#455): the outcome's path and the expiry can both reach it, the work running on a
/// queue of its own, so whichever comes first delivers and the other is logged as late. It also keeps what the expiry
/// delivers: the push as it came, until the outcome has filled the content (`filled`), so the expiry never hands over
/// a content the queue is still writing.
private final class HandlerOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var latest: UNNotificationContent
    init(_ handler: @escaping (UNNotificationContent) -> Void, asItCame: UNNotificationContent) {
        self.handler = handler
        latest = asItCame
    }

    /// The content with the decrypted fields in, for the expiry from now on.
    func filled(_ content: UNNotificationContent) {
        lock.lock()
        latest = content
        lock.unlock()
    }

    func expire() {
        lock.lock()
        let content = latest
        lock.unlock()
        call(content, via: "expire")
    }

    func call(_ content: UNNotificationContent, via: String) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        guard let handler else { NSELog.line("nse handler late via \(via)"); return }
        NSELog.line("nse handler t+\(NSELog.sinceStart()) via \(via)")
        handler(content)
    }
}

/// The extension's timing (#455), to the system log under dev.vory, category nse: fixed words and numbers only, never
/// a payload, title, body, profile, bot or thread name, key or install id, so every line is public. In Release too: the
/// Mac that was too slow to start is a tester's, and their own log is the only one that shows where the time went.
enum NSELog {
    private static let log = Logger(subsystem: "dev.vory", category: "nse")

    /// When this process started, from the kernel (wall clock, seconds), read once.
    private static let started: Double? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime   // `p_starttime` in C, a macro Swift doesn't import
        return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
    }()

    /// A moment in the work, kept for the next step's time: written by the credentials read, read by the outcome after
    /// it, on the same queue in turn.
    final class Mark: @unchecked Sendable { var at: UInt64 = DispatchTime.now().uptimeNanoseconds }

    static func line(_ words: String) { log.notice("\(words, privacy: .public)") }

    /// Milliseconds since the process started (-1 if the kernel didn't say).
    static func sinceStart() -> Int {
        guard let started else { return -1 }
        return Int((Date().timeIntervalSince1970 - started) * 1000)
    }

    static func ms(since t: UInt64) -> Int { Int((DispatchTime.now().uptimeNanoseconds &- t) / 1_000_000) }
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
        let spec = BotLookSpec.from(choice: choice, hex: looks.color(for: profile))
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
