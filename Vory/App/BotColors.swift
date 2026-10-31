import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import VoryCore

/// One accent colour per bot (profile). Stored in UserDefaults as `{profile: "#RRGGBB"}` under
/// `botColors`; profiles without a saved colour get a stable pick from the palette so two bots
/// never look alike by accident. Used by the chat title pill, the Bots list, notifications' tint
/// and the Live Activity.
/// The bot look maps (colours, avatar choices) as stored: one JSON string each, decoded once per
/// distinct string and kept. Every face on screen read its map by decoding the string again on
/// each body evaluation, which a list of a hundred rows did on every frame of a fling.
enum BotLookMaps {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [String: String]] = [:]

    static func map(_ raw: String?) -> [String: String] {
        guard let raw, !raw.isEmpty else { return [:] }
        lock.lock(); defer { lock.unlock() }
        if let m = cache[raw] { return m }
        let m = (raw.data(using: .utf8)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        if cache.count > 16 { cache.removeAll() }
        cache[raw] = m
        return m
    }
}

enum BotColors {
    static let storageKey = "botColors"
    /// The watch and the Mac pick from the same list (VoryCore's), so a bot is one colour everywhere.
    static let palette: [String] = BotPalette.hexes

    static func stored() -> [String: String] {
        BotLookMaps.map(UserDefaults.standard.string(forKey: storageKey))
    }

    @MainActor static func save(_ map: [String: String]) {
        if let data = try? JSONEncoder().encode(map), let s = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: storageKey)
        }
        BotLooksMirror.mirror()
    }

    static func hex(for profile: String, overrides: [String: String]? = nil) -> String {
        if let h = DemoLooks.color(for: profile) { return h }
        if let h = (overrides ?? stored())[profile], !h.isEmpty { return h }
        return defaultHex(for: profile)
    }

    /// Deterministic palette pick: same name, same colour, on every device.
    static func defaultHex(for profile: String) -> String { BotPalette.defaultHex(for: profile) }

    static func color(for profile: String, overrides: [String: String]? = nil) -> Color {
        Color(hex: hex(for: profile, overrides: overrides)) ?? .accentColor
    }

    @MainActor static func set(_ color: Color, for profile: String) {
        if DemoLooks.keep(color: color.hexString, for: profile) { return }
        var map = stored()
        map[profile] = color.hexString
        save(map)
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        (NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}

/// A bot's avatar: the studio bot (body, eyes, colour) that moves while `active` (the bot is
/// working), or the photo the user chose.
struct BotAvatar: View {
    var profile: String
    var size: CGFloat = 28
    var active: Bool = false
    /// Draw this choice instead of the stored one (the picker's previews).
    var override: BotAvatarChoice? = nil
    /// Thinking squint, finish spin (by profile), tilt-following eyes.
    var mood: BotFaceView.Mood = BotFaceView.Mood()
    /// Paint the glass finish instead of using real glass: for a bot inside another glass
    /// surface (a toolbar button), where glass on glass goes murky.
    var drawn = false
    @AppStorage(BotColors.storageKey) private var raw = ""
    @AppStorage(BotAvatarStore.storageKey) private var avatarsRaw = ""
    @AppStorage(BotAvatarStore.glassAllKey) private var glassAll = false

    private var overrides: [String: String] { BotLookMaps.map(raw) }
    private var effectiveMood: BotFaceView.Mood {
        var m = mood; if m.profile == nil { m.profile = profile }; return m
    }
    /// The looks of the chat this face is in, where it has its own (`BotLookScope`: the tour's demo over a gateway in use).
    @Environment(\.botLookScope) private var lookScope
    private var choice: BotAvatarChoice {
        if let override { return override }
        if let scoped = lookScope?.avatar(for: profile) { return BotAvatarChoice(raw: BotAvatarStore.effective(scoped, glassAll: glassAll)) }
        // The demo's bots wear the demo's looks while it runs (`DemoLooks`), as `BotAvatarStore.choice` has them: read
        // from the stored map here, a live face (working, large, drawn, or just tapped) took the stored body in the
        // demo's colour, and a bot changed shape as it started work.
        if let demo = DemoLooks.avatar(for: profile) { return BotAvatarChoice(raw: BotAvatarStore.effective(demo, glassAll: glassAll)) }
        let m = BotLookMaps.map(avatarsRaw)
        return BotAvatarChoice(raw: BotAvatarStore.effective(m[profile] ?? "", glassAll: glassAll))
    }

    @Environment(\.colorScheme) private var colorScheme
    /// A small idle face blinks by picture: the eyes-shut still for a moment, then the open one.
    /// The live view is mounted only for a finish spin or a tap, see `restsAsImage` (mounted
    /// around each blink, it drew a shade brighter than the still: Matt, 2026-10-12, "randomly
    /// loading the bot colors ... it should just load it once and keep it").
    @State private var eyesShut = false
    /// The live view under a row's face has drawn: its cached still can go.
    @State private var liveDrawn = false

    /// A small idle face in a list draws as a picture: one cached image per look, no Canvas, no
    /// shadow filter pass on every scrolled frame (the phone's list fling spent its frames on
    /// the rows' faces, 2026-10-11). The live view comes back only for the moments it is needed:
    /// a blink (held while the list scrolls), the finish spin, a tap. Faces that stand for a
    /// working session, bigger faces and the painted twin keep the live view.
    private var restsAsImage: Bool {
        // Any size: the Bots page's cards (78 pt) and the dashboard's faces rest as pictures
        // too; a face that leans with the device keeps its live view while it leans (with tilt
        // off, or the device at its hold, the Bots page's live faces cost 9% at rest).
        guard !active, !drawn, override == nil, !(mood.followsTilt && BotAmbient.shared.tiltKeepsLive), choice != .photo, mood.state == .idle else { return false }
        let now = Date()
        let a = BotAmbient.shared
        if let s = mood.session, let d = a.finishedSessions[s], now.timeIntervalSince(d) < 1.2 { return false }
        if mood.session == nil, let d = a.finished[profile], now.timeIntervalSince(d) < 1.2 { return false }
        // The live view for a tap's reaction only where one plays (not still, not under Reduce Motion).
        if BotMotionModel.Reaction.plays, !StillBlink.reduceMotionOn, let d = a.lastTap(profile: profile, session: mood.session), now.timeIntervalSince(d) < 1.2 { return false }
        return true
    }
    /// The same seed the live view blinks on, so the picture and the live face agree on when.
    private var blinkSeed: Int {
        let spec = choice.spec(hex: "")
        let raw = spec.shape.utf8.reduce(0) { $0 + Int($1) } + spec.eyes.utf8.reduce(0) { $0 + Int($1) }
            + (effectiveMood.profile ?? "").utf8.reduce(0) { $0 &* 31 &+ Int($1) }
        return Int(UInt(bitPattern: raw) % 1_000_003)
    }

    var body: some View {
        let hex = lookScope?.color(for: profile) ?? BotColors.hex(for: profile, overrides: overrides)
        Group {
            if let scope = lookScope, scope.avatar(for: profile) != nil {
                // A scoped look (the tour's demo): drawn from its own spec, never the stored look's memoised picture.
                if restsAsImage {
                    Image(uiImage: BotAvatarImage.cached(spec: choice.spec(hex: hex), size: size, scheme: colorScheme, closed: eyesShut, keep: true))
                        .resizable().frame(width: size, height: size)
                } else {
                    BotFaceView(spec: choice.spec(hex: hex), size: size, active: active, drawn: drawn, mood: effectiveMood)
                }
            } else if choice == .photo, let image = BotAvatarStore.photo(for: profile) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
            } else if restsAsImage {
                Image(uiImage: BotAvatarImage.cached(profile: profile, size: size, scheme: colorScheme, closed: eyesShut))
                    .resizable().frame(width: size, height: size)
            } else if size <= 40, !drawn, override == nil {
                // A row's face: the cached still stays underneath while the live view mounts
                // (a finish spin, a tap, or when the app comes forward), so the row never draws
                // empty for a frame (Matt, 2026-10-12, after an app switch), and only then: left
                // under a working face, its idle outline and eyes showed around and through the
                // moving pose (the toolbox read as a blob with two pairs of eyes, on the phone).
                ZStack {
                    if !liveDrawn {
                        Image(uiImage: BotAvatarImage.cached(profile: profile, size: size, scheme: colorScheme)).resizable().frame(width: size, height: size)
                    }
                    // Drawn but not shown until it takes over: the body is painted a little
                    // translucent, so for the moment both were up the still showed through it
                    // and the face read darker (a ~65 ms flash as a green bot started work on the
                    // Mac, 1.5 (21)). Not quite 0, so it renders and is ready the frame it shows;
                    // two frames are enough, and the start of a working morph stays in view.
                    BotFaceView(spec: choice.spec(hex: hex), size: size, active: active, drawn: drawn, mood: effectiveMood)
                        .opacity(liveDrawn ? 1 : 0.001)
                        .task { try? await Task.sleep(for: .milliseconds(34)); if !Task.isCancelled { liveDrawn = true } }
                        .onDisappear { liveDrawn = false }
                }
            } else {
                BotFaceView(spec: choice.spec(hex: hex), size: size, active: active, drawn: drawn, mood: effectiveMood)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .modifier(StillBlink(shut: $eyesShut, seed: blinkSeed, key: "\(profile)|\(size)|\(active)|\(mood.state == .idle)",
                             on: !active && !drawn && !(mood.followsTilt && BotAmbient.shared.tiltKeepsLive) && mood.state == .idle))
    }
}

/// The top bar's bot circle (Chats' profile menu): the bot's cached picture, exactly as before at rest. It blinks only
/// as a foldable phone opens (Duo stage 4, `BotAmbient.opened`), by swapping to its eyes-shut twin for 120 ms, as a list
/// row's still does, under the same gates; it has no blinks of its own.
struct BarFaceCircle: View {
    let profile: String
    let size: CGFloat
    let scheme: ColorScheme
    @State private var shut = false
    #if DEBUG
    /// Which circle this is in the blink probe's lines: more than one can be on screen as the bar settles.
    @State private var probeID = "bar-" + UUID().uuidString.prefix(6)
    #endif

    var body: some View {
        Image(uiImage: BotAvatarImage.cached(profile: profile, size: size, scheme: scheme, closed: shut)).renderingMode(.original)
            #if os(iOS)
            #if DEBUG
            .onAppear { BotAmbient.blinkLog("FACEUP still face \(probeID) front true on true") }
            .onDisappear { BotAmbient.blinkLog("FACEDOWN still face \(probeID)") }
            #endif
            .onChange(of: BotAmbient.shared.opened) { _, d in
                #if DEBUG
                let skip: String? = d == nil ? "nil"
                    : Date().timeIntervalSince(d!) >= BotMotionModel.Reaction.blinkLength ? String(format: "late %.3f", Date().timeIntervalSince(d!))
                    : !BotMotionModel.Reaction.plays ? "plays" : UIAccessibility.isReduceMotionEnabled ? "reduceMotion" : BotAmbient.shared.scrolling ? "scrolling" : nil
                if let skip { BotAmbient.blinkLog("FACESKIP still face \(probeID) \(skip)") }
                #endif
                guard let d, Date().timeIntervalSince(d) < BotMotionModel.Reaction.blinkLength, BotMotionModel.Reaction.plays,
                      !UIAccessibility.isReduceMotionEnabled, !BotAmbient.shared.scrolling else { return }
                Task {
                    shut = true
                    #if DEBUG
                    BotAmbient.blinkLog("FACEBLINK still face \(probeID)")
                    #endif
                    try? await Task.sleep(for: .milliseconds(120))
                    shut = false
                }
            }
            #endif
    }
}

/// A fixed look's face at rest, not a bot's own (the Companion card's Vory bot): a cached
/// picture that blinks by swapping to its eyes-shut twin, as a list row's face does. The live
/// glass face redrew the whole Settings page on every frame at rest (18% CPU on the simulator).
struct BotStill: View {
    let spec: BotLookSpec
    let size: CGFloat
    @State private var shut = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Image(uiImage: BotAvatarImage.cached(spec: spec, size: size, scheme: colorScheme, closed: shut, keep: true))
            .resizable().frame(width: size, height: size)
            .accessibilityHidden(true)
            .modifier(StillBlink(shut: $shut, seed: (spec.shape + spec.eyes).utf8.reduce(0) { $0 &* 31 &+ Int($1) } & 0xFFFFF,
                                 key: "\(spec.shape)|\(spec.eyes)|\(size)", on: true))
    }
}

/// The picture blink: between blinks the open picture, at each blink the shut one for 120 ms
/// (one wakeup per blink), skipped while a list is moving. Only on the page in front: the loop
/// starts again as its page comes forward or goes (a face mounted behind another tab never
/// blinked, and one that started in front kept waking behind a hidden tab, #248). The Mac stays
/// still at rest (Matt, 2026-10-12: "Stay still on the Mac"): its faces blink only while a bot
/// is working, as its live faces do.
private struct StillBlink: ViewModifier {
    @Binding var shut: Bool
    let seed: Int
    /// What the face is (a change starts the loop again).
    let key: String
    let on: Bool
    @Environment(\.botsLive) private var pageLive
    #if DEBUG
    /// Which face this is in the blink probe's lines (`-vory-blink-probe`): each one must blink once per opening.
    @State private var probeID = UUID().uuidString.prefix(8)
    #endif
    static var reduceMotionOn: Bool {
        #if os(iOS)
        UIAccessibility.isReduceMotionEnabled
        #else
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }
    func body(content: Content) -> some View {
        content.task(id: "\(key)|\(on)|\(pageLive)|\(BotAmbient.shared.decorativeActive)") {
            guard on, pageLive, BotAmbient.shared.decorativeActive else { return }
            while !Task.isCancelled {
                let now = Date().timeIntervalSinceReferenceDate
                let next = BotMotionModel.nextBlink(after: now + 0.1, seed: seed)
                try? await Task.sleep(for: .seconds(max(0.05, next - now)))
                if Task.isCancelled { return }
                // Reduce Motion holds the eyes open on the live face too (no blink).
                if BotAmbient.shared.scrolling || !BotAmbient.shared.enabled || Self.reduceMotionOn { continue }
                shut = true
                try? await Task.sleep(for: .milliseconds(120))
                shut = false
            }
        }
        #if os(iOS)
        #if DEBUG
        // For the hinge legs: a face is there to blink (FACEUP), with whether its page is in front and its blink is on;
        // its page coming forward or going back (FACEFRONT), and the face going (FACEDOWN).
        .onAppear { BotAmbient.blinkLog("FACEUP still face \(probeID) front \(pageLive) on \(on)") }
        .onChange(of: pageLive) { _, f in BotAmbient.blinkLog("FACEFRONT still face \(probeID) \(f)") }
        .onDisappear { BotAmbient.blinkLog("FACEDOWN still face \(probeID)") }
        #endif
        // A foldable phone opened (Duo stage 4): one blink by picture, as the live faces blink, on the page in front
        // only, never with the bots still, under Reduce Motion or while the list is moving.
        .onChange(of: BotAmbient.shared.opened) { _, d in
            #if DEBUG
            // Why a face didn't blink, the first gate that stopped it (the hinge legs).
            let skip: String? = !on ? "on" : !pageLive ? "live" : d == nil ? "nil"
                : Date().timeIntervalSince(d!) >= BotMotionModel.Reaction.blinkLength ? String(format: "late %.3f", Date().timeIntervalSince(d!))
                : !BotMotionModel.Reaction.plays ? "plays" : Self.reduceMotionOn ? "reduceMotion" : BotAmbient.shared.scrolling ? "scrolling" : nil
            if let skip { BotAmbient.blinkLog("FACESKIP still face \(probeID) \(skip)") }
            #endif
            guard on, pageLive, let d, Date().timeIntervalSince(d) < BotMotionModel.Reaction.blinkLength, BotMotionModel.Reaction.plays,
                  !Self.reduceMotionOn, !BotAmbient.shared.scrolling else { return }
            Task {
                shut = true
                #if DEBUG
                BotAmbient.blinkLog("FACEBLINK still face \(probeID)")
                #endif
                try? await Task.sleep(for: .milliseconds(120))
                shut = false
            }
        }
        #endif
    }
}

/// Copies the bot colours, avatar choices and photo thumbnails into the shared keychain
/// (`BotLooks`) for the notification extensions. Never while the demo runs (#494): its looks come first while it does,
/// and its bots' names would go to the extensions and the Watch; leaving it copies the person's own again.
@MainActor
enum BotLooksMirror {
    static func mirror() {
        guard !DemoLooks.isOn else { owedAfterDemo = true; return }
        // The all-bots glass setting is baked in here, for every profile the gateway knows, so
        // the extensions (which only read this mirror) draw the same bot as the app.
        var avatars = BotAvatarStore.stored()
        var colors = BotColors.stored()
        let profiles = AppModel.shared.runtime?.profiles ?? []
        let known = Set(avatars.keys).union(profiles.map(\.name))
        for profile in known {
            avatars[profile] = BotAvatarStore.effective(avatars[profile] ?? "")
            if colors[profile] == nil { colors[profile] = BotColors.hex(for: profile) }
        }
        var photos: [String: Data] = [:]
        for (profile, choice) in avatars where choice == "photo" {
            if let image = BotAvatarStore.photo(for: profile), let data = thumbnail(image) { photos[profile] = data }
        }
        // The push names a bot by its profile name; a companion that only knows the label still
        // finds it, so every look is stored under both.
        for p in profiles where p.label != p.name && !p.label.isEmpty {
            avatars[p.label] = avatars[p.name]; colors[p.label] = colors[p.name]; photos[p.label] = photos[p.name]
        }
        BotLooks(colors: colors, avatars: avatars, photos: photos).save()
        #if os(iOS)
        WatchSync.shared.refresh()
        #endif
        // A look changed (a photo replaced leaves no setting behind to notice): iCloud gets it.
        CloudSync.shared.looksChanged()
    }

    /// A copy asked for while the demo ran, and so not made (#494): made when the demo ends (`mirrorIfOwed`).
    private static var owedAfterDemo = false

    /// After the demo, the copy asked for while it ran, if any. A demo that changed none of the person's looks writes
    /// nothing as it ends: the copy written on every leave was a first write of their default looks (the copy at launch
    /// holds stored looks only), which #487's replay check saw as a change the demo made.
    static func mirrorIfOwed() {
        guard owedAfterDemo else { return }
        owedAfterDemo = false
        mirror()
    }

    private static func thumbnail(_ image: UIImage) -> Data? {
        let side: CGFloat = 128
        let scale = side / max(image.size.width, image.size.height)
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let small = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return small.jpegData(compressionQuality: 0.75)
    }
}

/// Tells BotAmbient that the page it sits in has landed: its controller's viewDidAppear, after the
/// push or the sheet has finished, so a waiting arrival (`BotAmbient.markArrival`) plays in full on
/// a still page. Nothing waits on a pop back or a sheet shown again.
struct ArrivalProbe: View {
    let profile: String
    var body: some View { Probe(profile: profile).frame(width: 0, height: 0).accessibilityHidden(true) }

    #if os(iOS)
    private struct Probe: UIViewControllerRepresentable {
        let profile: String
        func makeUIViewController(context: Context) -> Controller { Controller(profile: profile) }
        func updateUIViewController(_ c: Controller, context: Context) { c.profile = profile }
        final class Controller: UIViewController {
            var profile: String
            init(profile: String) { self.profile = profile; super.init(nibName: nil, bundle: nil) }
            required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
            override func loadView() { let v = UIView(); v.isUserInteractionEnabled = false; v.isHidden = true; view = v }
            override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); BotAmbient.shared.arrive(profile: profile) }
        }
    }
    #else
    private struct Probe: NSViewControllerRepresentable {
        let profile: String
        func makeNSViewController(context: Context) -> Controller { Controller(profile: profile) }
        func updateNSViewController(_ c: Controller, context: Context) { c.profile = profile }
        final class Controller: NSViewController {
            var profile: String
            init(profile: String) { self.profile = profile; super.init(nibName: nil, bundle: nil) }
            required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
            override func loadView() { let v = NSView(); v.isHidden = true; view = v }
            override func viewDidAppear() { super.viewDidAppear(); BotAmbient.shared.arrive(profile: profile) }
        }
    }
    #endif
}
