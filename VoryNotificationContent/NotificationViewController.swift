import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI
import VoryCore

/// The expanded (long-press) view of a finished-turn notification, laid out like a message
/// thread: the bot's avatar and name, the chat it came from, and the reply as a bubble. The
/// "Reply" text field underneath is the system's, from the notification category's text action.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var host: UIHostingController<ReplyCard>?

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        let hermes = content.userInfo["hermes"] as? [String: Any] ?? [:]
        // The reply card's face is a live one: the 1.5 motion, as in the app (only the app set
        // this, so the extension still ran the 1.4 drawing with its turn).
        BotFace.motionEngine = true
        Keychain.accessGroup = Keychain.sharedGroupFromBundle()
        let looks = BotLooks.load()
        let profile = hermes["profile"] as? String ?? ""
        let bot = content.title.isEmpty ? (profile.isEmpty ? "Hermes" : profile) : content.title
        let key = looks.key(profile: profile, label: bot.components(separatedBy: " · ").first ?? bot) ?? profile
        let model = ReplyCard.Model(
            bot: bot,
            chatTitle: (hermes["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? content.subtitle,
            text: (hermes["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.stripTitle(content.body),
            tintHex: looks.color(for: key, profile: profile),
            avatar: looks.avatars[key] ?? "initial",
            failed: content.categoryIdentifier == "HERMES_ERROR",
            when: notification.date)
        let card = ReplyCard(model: model)
        if let host {
            host.rootView = card
        } else {
            let h = UIHostingController(rootView: card)
            h.view.backgroundColor = .clear
            addChild(h)
            view.addSubview(h.view)
            // Pinned with constraints: the view's bounds are still zero when this runs, and an
            // autoresizing mask scaled from zero stays zero (a blank window).
            h.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                h.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                h.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                h.view.topAnchor.constraint(equalTo: view.topAnchor),
                h.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            h.didMove(toParent: self)
            host = h
        }
        let width = view.bounds.width > 0 ? view.bounds.width : sceneBounds.width - 16
        preferredContentSize = CGSize(width: width, height: fittedHeight(width: width))
    }

    /// The scene this extension's view is in, as it is now: what the card's size is a share of.
    /// Before the view is in a window (the first layout) its own bounds stand in.
    private var sceneBounds: CGRect {
        if let scene = view.window?.windowScene { return scene.effectiveGeometry.coordinateSpace.bounds }
        return view.bounds
    }

    /// The card's natural height, capped at what iOS shows above the reply field and keyboard.
    private func fittedHeight(width: CGFloat) -> CGFloat {
        let h = host?.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height ?? 120
        let cap = max(200, sceneBounds.height * 0.29)
        return min(max(h, 96), cap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0 else { return }
        let size = CGSize(width: view.bounds.width, height: fittedHeight(width: view.bounds.width))
        if abs(size.height - preferredContentSize.height) > 1 { preferredContentSize = size }
    }

    /// The banner body is "chat title: reply"; older companions send no separate text.
    private static func stripTitle(_ body: String) -> String {
        if let r = body.range(of: ": "), body.distance(from: body.startIndex, to: r.lowerBound) < 80 { return String(body[r.upperBound...]) }
        return body
    }
}

/// The reply as one message from the bot: avatar and name up top, the chat it came from and the
/// time on the right, then the text in a bubble that reads like Messages.
struct ReplyCard: View {
    struct Model {
        var bot: String
        var chatTitle: String
        var text: String
        var tintHex: String
        var avatar: String
        var failed: Bool
        var when: Date
    }
    var model: Model

    private var tint: Color { Color(hexString: model.tintHex) ?? .purple }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                LookAvatar(avatar: model.avatar, initial: String(model.bot.prefix(1)).uppercased(), tintHex: model.tintHex, size: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.bot).font(.headline)
                    Text(model.chatTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.when, style: .time).font(.caption).foregroundStyle(.secondary)
                    if model.failed {
                        Label("Failed", systemImage: "xmark.circle.fill").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 0) {
                ScrollView {
                    Text(model.text.replacingOccurrences(of: "\n\n", with: "\n"))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .background(Color(uiColor: .secondarySystemFill), in: BubbleShape())
                .clipShape(BubbleShape())
                .frame(maxWidth: 300, alignment: .leading)
                Spacer(minLength: 36)
            }
        }
        .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A message bubble like Messages: rounded, with a small curl of a tail at the bottom corner,
/// drawn as one outline so the tail and the body are a single piece.
struct BubbleShape: Shape {
    var tailOnRight = false
    func path(in r: CGRect) -> Path {
        let radius: CGFloat = 17
        var p = Path()
        p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        if tailOnRight {
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 10))
            p.addQuadCurve(to: CGPoint(x: r.maxX + 6, y: r.maxY), control: CGPoint(x: r.maxX + 1, y: r.maxY - 2))
            p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX - 4, y: r.maxY))
        } else {
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
            p.addArc(center: CGPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        if tailOnRight {
            p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
            p.addArc(center: CGPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        } else {
            p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX - 6, y: r.maxY), control: CGPoint(x: r.minX + 4, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - 10), control: CGPoint(x: r.minX - 1, y: r.maxY - 2))
        }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addArc(center: CGPoint(x: r.minX + radius, y: r.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// The bot's avatar; it animates here because this is a real view, not a widget.
struct LookAvatar: View {
    var avatar: String
    var initial: String
    var tintHex: String
    var size: CGFloat

    var body: some View {
        BotFaceView(spec: BotLookSpec.from(choice: avatar, hex: tintHex), size: size, active: true)
    }
}

extension Color {
    init?(hexString: String) {
        var s = hexString; if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
