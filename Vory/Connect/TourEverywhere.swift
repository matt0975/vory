#if os(iOS)
import SwiftUI
import VoryCore

/// Beat 5's places, in order (2026-10-20): where Sprout's ask reaches you (the Dynamic Island, the Lock
/// Screen, the Watch), then the iPad and the Mac, home and away, and iCloud. Each stays until its line has been read.
enum TourPlace: Int, CaseIterable, Hashable {
    case island, lockScreen, watch, devices, homeAway, iCloud

    /// The device the frames show beside the Mac: the one this isn't.
    static var otherDevice: String { DeviceWords.device == "iPad" ? "iPhone" : "iPad" }

    /// The places on this device: an iPad has no Dynamic Island.
    static func all(pad: Bool) -> [TourPlace] { pad ? allCases.filter { $0 != .island } : allCases }

    /// How long the place stays once it's up, in seconds: long enough for its line and caption to be read.
    var dwell: Double {
        switch self {
        case .island: return 3.4
        case .lockScreen: return 2.8
        case .watch, .devices: return 3.0
        case .homeAway: return 3.6
        case .iCloud: return 3.2
        }
    }

    /// The caption under the frame, where the copy has one.
    var caption: String? {
        switch self {
        case .island: return "In the Dynamic Island while a bot works"
        case .lockScreen: return "On your Lock Screen, ready to answer"
        case .watch: return "On your Apple Watch"
        case .homeAway: return "Home: your local network \u{00B7} Away: Tailscale or a Cloudflare Tunnel"
        case .devices, .iCloud: return nil
        }
    }

    /// The small print under the last of the places Sprout's ask reaches.
    var smallPrint: String? {
        self == .watch ? "Notifications and Live Activities need the Vory Companion on your gateway." : nil
    }

    /// What VoiceOver reads for the frame: the frames are pictures, read as their captions.
    var spoken: String {
        switch self {
        case .island: return "Dynamic Island. Sprout needs approval. In the Dynamic Island while a bot works."
        case .lockScreen: return "Lock Screen. Sprout needs approval. On your Lock Screen, ready to answer."
        case .watch: return "Apple Watch. Sprout\u{2019}s approval, with Allow once and Deny. On your Apple Watch."
        case .devices: return "\(TourPlace.otherDevice) and Mac. Vory on both."
        case .homeAway: return "Home and away. Home: your local network. Away: Tailscale or a Cloudflare Tunnel."
        case .iCloud: return "iCloud. The bots move from your \(DeviceWords.device) to your other devices."
        }
    }
}

/// 5. Everywhere: one frame at a time, from the app's own parts. The Island and the Lock Screen are the Live Activity's
/// own views (`LiveTurnViews`), showing Sprout's ask from beats 3 and 4; the Watch, the iPad, the iPhone and the Mac are
/// the apps themselves on the demo, kept as pictures (made by `TourFrameShotsUITests` and `Tools/dev/tour-frames.sh`).
/// The frames show, they don't act: nothing here can be tapped, and no link in them opens.
struct TourEverywhere: View {
    var place: TourPlace
    var size: CGSize
    var reduceMotion: Bool
    var live: Bool
    /// Vory's bubble ends here and the tour's controls start there: the frames and their words stay between.
    var below: CGFloat = 0
    var above: CGFloat = 0

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                frame(place)
                    // Pictures of a device as it looks: at its default text size, whatever the tour's.
                    .dynamicTypeSize(.large)
                    .id(place)
                    // The last frame goes before the next comes, so the two never show at once.
                    .transition(reduceMotion ? .opacity
                                : .asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity).animation(.spring(duration: 0.45, bounce: 0.2).delay(0.18)),
                                              removal: .opacity.animation(.easeOut(duration: 0.15))))
            }
            .frame(maxWidth: 560, maxHeight: .infinity)
            .animation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(duration: 0.5, bounce: 0.2), value: place)
            VStack(spacing: 6) {
                if let caption = place.caption {
                    Text(caption).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                }
                if let small = place.smallPrint {
                    Text(small).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(minHeight: 56, alignment: .top)
            .id(place)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: place)
        }
        .padding(.horizontal, 24)
        // Where the tour's chat sat on beats 3 and 4: under Vory and his bubble, over Continue and the dots.
        .padding(.top, max(size.height * 0.30, below + 10))
        .padding(.bottom, above > 0 ? size.height - above + 10 : 112)
        // Pictures of the app, not the app: no tap, no link.
        .allowsHitTesting(false)
        .environment(\.openURL, OpenURLAction { _ in .discarded })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(place.spoken)
        .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder private func frame(_ place: TourPlace) -> some View {
        switch place {
        case .island: TourIslandFrame(live: live, reduceMotion: reduceMotion)
        case .lockScreen: TourLockScreenFrame()
        case .watch: TourWatchFrame()
        case .devices: TourDevicesFrame()
        case .homeAway: TourHomeAwayFrame(live: live, reduceMotion: reduceMotion)
        case .iCloud: TourCloudFrame(live: live, reduceMotion: reduceMotion)
        }
    }
}

/// Sprout's ask from beats 3 and 4 as the Live Activity carries it: the demo's own bot, look and command.
@MainActor
enum TourActivity {
    static var attributes: HermesTurnAttributes {
        let sprout = DemoBots.all.first { $0.display == "Sprout" }
        return HermesTurnAttributes(sessionTitle: "Disk space", storedSessionID: "tour", connectionID: GatewayConnection.demoID.uuidString,
                                    profile: TourChat.profile, tintHex: sprout?.hex ?? "",
                                    botName: sprout?.display ?? "Sprout",
                                    avatar: sprout.map { "studio:\($0.shape):\($0.eyes)" })
    }

    static var asking: HermesTurnAttributes.ContentState {
        var s = HermesTurnAttributes.ContentState(phase: "waiting", detail: "find ./logs -mtime +30 -delete", outputTokens: 41,
                                                  contextPercent: 9, needsAttention: true, startedAt: Date().addingTimeInterval(-8))
        s.attentionKind = "approval"
        return s
    }
}

// MARK: Frames

/// The Dynamic Island: the compact island, then it opens on Sprout's ask (the Live Activity's own regions), at the top
/// of a phone's screen.
private struct TourIslandFrame: View {
    var live: Bool
    var reduceMotion: Bool
    @State private var open = false

    var body: some View {
        let attributes = TourActivity.attributes, state = TourActivity.asking
        TourPhoneTop(height: 250, maxWidth: 380) {
            Color(.systemBackground)
        } content: {
            ZStack(alignment: .top) {
                if open {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            IslandExpandedLeading(attributes: attributes, state: state)
                            Spacer(minLength: 8)
                            IslandExpandedTrailing(attributes: attributes, state: state)
                        }
                        IslandExpandedBottom(attributes: attributes, state: state)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black, in: .rect(cornerRadius: 40))
                    .transition(.scale(scale: 0.35, anchor: .top).combined(with: .opacity))
                } else {
                    HStack {
                        IslandBot(attributes: attributes, state: state, size: 24).padding(.leading, 2)
                        Spacer()
                        IslandCompactTrailing(state: state)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 200, height: 37)
                    .background(.black, in: .capsule)
                    .transition(.opacity)
                }
            }
            .environment(\.colorScheme, .dark)
            .padding(.top, 11)
            .padding(.horizontal, 10)
        }
        .task(id: live) {
            // Compact first, then it opens, as an ask does when it arrives.
            guard live else { return }
            open = false
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.2 : 0.7))
            withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.5, bounce: 0.25)) { open = true }
        }
    }
}

/// The Lock Screen: the time over a dark wallpaper in the bots' colours, and the Live Activity's own Lock Screen card, at
/// a phone's width so it lays out as it does there.
private struct TourLockScreenFrame: View {
    var body: some View {
        TourPhoneTop(height: 480, maxWidth: 320) {
            LinearGradient(colors: DemoBots.all.prefix(3).compactMap { Color(botHex: $0.hex)?.opacity(0.75) } + [.black],
                           startPoint: .topLeading, endPoint: .bottom)
        } content: {
            VStack(spacing: 18) {
                VStack(spacing: 0) {
                    Text("Tuesday 20 October").font(.headline)
                    Text("9:41").font(.system(size: 86, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.top, 54)
                LockScreenTurnView(attributes: TourActivity.attributes, state: TourActivity.asking)
                    .background(Color.black.opacity(0.35), in: .rect(cornerRadius: 22))
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 22))
                    .padding(.horizontal, 10)
            }
            .environment(\.colorScheme, .dark)
        }
    }
}

/// The Watch: the Watch app's approval, as it shows Sprout's ask.
private struct TourWatchFrame: View {
    var body: some View {
        TourShot(name: "TourWatch")
            .aspectRatio(0.82, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 34))
            .padding(10)
            .background(Color.black, in: .rect(cornerRadius: 44))
            .overlay(alignment: .trailing) {
                // The crown.
                Capsule().fill(Color.gray.opacity(0.6)).frame(width: 7, height: 38).offset(x: 6, y: -24)
            }
            .frame(maxWidth: 210)
    }
}

/// The iPad (or the iPhone, on an iPad) and the Mac side by side, each the app on the demo.
private struct TourDevicesFrame: View {
    var body: some View {
        // Drawn at a phone's width and scaled to the room: on an iPad, larger.
        TourFixedSize(size: CGSize(width: 354, height: 200)) { devices }
            .frame(maxWidth: 540)
    }

    private var devices: some View {
        HStack(alignment: .bottom, spacing: 14) {
            if TourPlace.otherDevice == "iPad" {
                TourShot(name: "TourPad")
                    .aspectRatio(0.69, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 12))
                    .padding(6)
                    .background(Color.black, in: .rect(cornerRadius: 17))
                    .frame(maxWidth: 124)
            } else {
                TourShot(name: "TourPhone")
                    .aspectRatio(0.46, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 16))
                    .padding(5)
                    .background(Color.black, in: .rect(cornerRadius: 21))
                    .frame(maxWidth: 96)
            }
            VStack(spacing: 0) {
                TourShot(name: "TourMac")
                    .aspectRatio(1.6, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 4))
                    .padding(6)
                    .background(Color.black, in: .rect(cornerRadius: 10))
                // The laptop's base.
                UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                    .fill(Color.gray.opacity(0.45))
                    .frame(height: 8)
                    .padding(.horizontal, -12)
            }
            .frame(maxWidth: 210)
        }
    }
}

/// Home and away: the app's own address line for a gateway with a backup address (`AddressChooser.label`), at home,
/// then away.
private struct TourHomeAwayFrame: View {
    var live: Bool
    var reduceMotion: Bool
    @State private var away = false

    private static let home = try? GatewayURL.normalize("http://192.168.1.20:8642")
    private static let tunnel = try? GatewayURL.normalize("https://workshop.tailnet.ts.net")

    var body: some View {
        let address = away ? Self.tunnel : Self.home
        VStack(spacing: 18) {
            HStack(spacing: 28) {
                Image(systemName: "house.fill").foregroundStyle(away ? Color.secondary : Color.blue)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                Image(systemName: "globe").foregroundStyle(away ? Color.blue : Color.secondary)
            }
            .font(.title)
            HStack(spacing: 12) {
                Image(systemName: "server.rack").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Color.indigo, in: .rect(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workshop").font(.body)
                    if let address {
                        Text([AddressChooser.label(for: address), address.description].joined(separator: " \u{00B7} "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
            .frame(maxWidth: 380)
        }
        .task(id: live) {
            guard live else { return }
            away = false
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .snappy) { away = true }
        }
    }
}

/// iCloud: the five demo bots' faces on this device, and their copies flying over to the other two: the looks are the
/// same on every device.
private struct TourCloudFrame: View {
    var live: Bool
    var reduceMotion: Bool
    @State private var synced = false

    private static let size = CGSize(width: 340, height: 250)
    /// Where each device's screen sits in the drawing, and the faces' places on it.
    private static let here = CGPoint(x: 62, y: 178), others = [CGPoint(x: 170, y: 178), CGPoint(x: 280, y: 172)]
    private static let cluster: [CGVector] = [.init(dx: -15, dy: -9), .init(dx: 0, dy: -9), .init(dx: 15, dy: -9),
                                              .init(dx: -7.5, dy: 8), .init(dx: 7.5, dy: 8)]

    var body: some View {
        let bots = DemoBots.all
        TourFixedSize(size: Self.size) {
            ZStack {
                Image(systemName: "icloud.fill").font(.system(size: 46)).foregroundStyle(.cyan).position(x: 170, y: 46)
                outline(DeviceWords.device == "iPad" ? "ipad" : "iphone", at: Self.here)
                outline(TourPlace.otherDevice == "iPad" ? "ipad" : "iphone", at: Self.others[0])
                outline("laptopcomputer", at: CGPoint(x: Self.others[1].x, y: Self.others[1].y + 8))
                ForEach(Array(bots.enumerated()), id: \.element.name) { i, bot in
                    face(bot).position(at(Self.here, i))
                    ForEach(0..<2, id: \.self) { d in
                        face(bot)
                            .position(synced ? at(Self.others[d], i) : at(Self.here, i))
                            .opacity(synced ? 1 : 0)
                            .animation(reduceMotion ? .easeInOut(duration: 0.3)
                                       : .spring(duration: 0.9, bounce: 0.15).delay(Double(i) * 0.1 + Double(d) * 0.25), value: synced)
                    }
                }
            }
        }
        .frame(maxWidth: 520)
        .task(id: live) {
            guard live else { return }
            synced = false
            try? await Task.sleep(for: .seconds(0.7))
            synced = true
        }
    }

    private func at(_ screen: CGPoint, _ i: Int) -> CGPoint {
        let v = Self.cluster[i % Self.cluster.count]
        return CGPoint(x: screen.x + v.dx, y: screen.y + v.dy)
    }

    private func face(_ bot: DemoBot) -> some View {
        BotFaceView(spec: BotLookSpec(shape: bot.shape, eyes: bot.eyes, hex: bot.hex), size: 14, active: false,
                    mood: BotFaceView.Mood(profile: "tour-\(bot.name)"))
    }

    private func outline(_ symbol: String, at p: CGPoint) -> some View {
        Image(systemName: symbol).font(.system(size: 78, weight: .ultraLight)).foregroundStyle(.secondary).position(p)
    }
}

// MARK: Pieces

/// A drawing made at a fixed size and scaled to the room it's given, so what's in it lays out as it does at that size.
private struct TourFixedSize<Content: View>: View {
    var size: CGSize
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geo in
            content
                .frame(width: size.width, height: size.height)
                .scaleEffect(min(geo.size.width / size.width, geo.size.height / size.height))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
    }
}

/// The top of a phone's screen at a phone's width (393 points), in its black rim, fading out below: what's in it lays
/// out as it does on a phone, and the whole is scaled to the room.
private struct TourPhoneTop<Background: View, Content: View>: View {
    var height: CGFloat
    var maxWidth: CGFloat
    @ViewBuilder var background: Background
    @ViewBuilder var content: Content
    var body: some View {
        TourFixedSize(size: CGSize(width: 393 + 16, height: height + 8)) {
            ZStack(alignment: .top) {
                background
                content
            }
            .frame(width: 393, height: height)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 50, topTrailingRadius: 50))
            .padding([.top, .horizontal], 8)
            .background(Color.black, in: UnevenRoundedRectangle(topLeadingRadius: 58, topTrailingRadius: 58))
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .frame(maxWidth: maxWidth)
    }
}

/// One of the apps on the demo, as a picture kept in the asset catalog, in this appearance where it has both.
private struct TourShot: View {
    var name: String
    var body: some View {
        Image(name).resizable().scaledToFill()
    }
}
#endif
