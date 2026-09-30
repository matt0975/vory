import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// What stands in for a bot: its initial in a coloured circle, a photo the user picked, or one of
/// the animated Vory avatars. Stored per profile in UserDefaults (`botAvatars`, `{profile: raw}`)
/// with photos under Application Support/BotAvatars; both stay on this device.
enum BotAvatarChoice: Equatable {
    case photo
    /// `glass`: the Liquid Glass finish (beta), stored as a fourth part of the raw string.
    case studio(shape: String, eyes: String, glass: Bool = false)
    /// Older stored values ("initial", "animated:<style>"); they draw as a studio bot.
    case legacy(String)

    var raw: String {
        switch self {
        case .photo: return "photo"
        case .studio(let shape, let eyes, let glass): return "studio:\(shape):\(eyes)" + (glass ? ":glass" : "")
        case .legacy(let r): return r
        }
    }

    init(raw: String) {
        if raw == "photo" { self = .photo; return }
        let spec = BotLookSpec.from(choice: raw, hex: "")
        if raw.hasPrefix("studio:") { self = .studio(shape: spec.shape, eyes: spec.eyes, glass: spec.isGlass) }
        else if raw.isEmpty || raw == "initial" { self = .studio(shape: BotLookSpec.defaultShape, eyes: BotLookSpec.defaultEyes) }
        else { self = .legacy(raw) }
    }

    /// The look this choice draws, for a given colour.
    func spec(hex: String) -> BotLookSpec { BotLookSpec.from(choice: raw, hex: hex) }
    static let `default` = BotAvatarChoice.studio(shape: BotLookSpec.defaultShape, eyes: BotLookSpec.defaultEyes)

    var isGlass: Bool { if case .studio(_, _, let g) = self { return g } else { return false } }
}

enum BotAvatarStore {
    static let storageKey = "botAvatars"
    /// NSCache is thread-safe; the wrapper just says so to the compiler.
    private struct Cache: @unchecked Sendable { let store = NSCache<NSString, UIImage>() }
    private static let cache = Cache()
    private static var photoCache: NSCache<NSString, UIImage> { cache.store }

    static func stored() -> [String: String] {
        guard let raw = UserDefaults.standard.string(forKey: storageKey), let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    @MainActor static func save(_ map: [String: String]) {
        if let data = try? JSONEncoder().encode(map), let s = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: storageKey)
        }
        BotLooksMirror.mirror()
    }

    static func choice(for profile: String, overrides: [String: String]? = nil) -> BotAvatarChoice {
        BotAvatarChoice(raw: effective((overrides ?? stored())[profile] ?? ""))
    }

    /// Settings › Bots › "Liquid Glass for all bots": every studio bot draws as glass, whatever
    /// its own switch says.
    static let glassAllKey = "bots.glassAll"
    static var glassAll: Bool { UserDefaults.standard.bool(forKey: glassAllKey) }

    /// The raw choice with the all-bots glass setting applied.
    static func effective(_ raw: String, glassAll: Bool = glassAll) -> String {
        guard glassAll else { return raw }
        let c = BotAvatarChoice(raw: raw)
        if case .studio(let shape, let eyes, _) = c { return BotAvatarChoice.studio(shape: shape, eyes: eyes, glass: true).raw }
        return raw
    }

    @MainActor static func set(_ choice: BotAvatarChoice, for profile: String) {
        var map = stored()
        map[profile] = choice.raw
        save(map)
    }

    static func photoURL(for profile: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appending(path: "BotAvatars", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = profile.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return dir.appending(path: "\(safe).jpg")
    }

    /// Downscales to 320 px and writes a JPEG; the same profile's cached image is dropped.
    static func savePhoto(_ data: Data, for profile: String) throws {
        guard let url = photoURL(for: profile), let image = UIImage(data: data) else { throw CocoaError(.fileWriteUnknown) }
        let side: CGFloat = 320
        let scale = max(side / image.size.width, side / image.size.height)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let squared = renderer.image { _ in
            image.draw(in: CGRect(x: (side - target.width) / 2, y: (side - target.height) / 2, width: target.width, height: target.height))
        }
        guard let jpeg = squared.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileWriteUnknown) }
        try jpeg.write(to: url, options: .atomic)
        photoCache.removeObject(forKey: profile as NSString)
    }

    static func photo(for profile: String) -> UIImage? {
        if let cached = photoCache.object(forKey: profile as NSString) { return cached }
        guard let url = photoURL(for: profile), let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        photoCache.setObject(image, forKey: profile as NSString)
        return image
    }

    static func removePhoto(for profile: String) {
        if let url = photoURL(for: profile) { try? FileManager.default.removeItem(at: url) }
        photoCache.removeObject(forKey: profile as NSString)
    }
}

/// The Creator Studio: pick the bot's body, its eyes and its colour, and watch it come alive.
struct CreatorStudio: View {
    var profile: String
    @Binding var choice: BotAvatarChoice
    @AppStorage(BotColors.storageKey) private var colorsRaw = ""
    @State private var custom: Color = .accentColor
    @State private var photoItem: PhotosPickerItem?
    @State private var photoError: String?
    @State private var photoVersion = 0
    @State private var tab: StudioTab = .body
    @AppStorage(BotAvatarStore.glassAllKey) private var glassAll = false

    enum StudioTab: String, CaseIterable { case body, eyes, colour }

    private var hex: String { BotColors.hex(for: profile) }
    private var current: BotLookSpec { choice.spec(hex: hex) }
    private var shape: String { current.shape }
    private var eyes: String { current.eyes }
    private var glass: Bool { current.isGlass }

    var body: some View {
        VStack(spacing: 14) {
            Picker("", selection: $tab) {
                Label("Body", systemImage: "circle.hexagongrid.fill").tag(StudioTab.body)
                Label("Eyes", systemImage: "eyes").tag(StudioTab.eyes)
                Label("Colour", systemImage: "paintpalette.fill").tag(StudioTab.colour)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            switch tab {
            case .body:
                grid(BotLookSpec.shapes, selected: shape, name: BotLookSpec.name(ofShape:)) { s in
                    BotFaceView(spec: BotLookSpec(shape: s, eyes: eyes, hex: hex, finish: current.finish), size: 58, active: shape == s)
                } pick: { choice = .studio(shape: $0, eyes: eyes, glass: glass) }
                photoRow
            case .eyes:
                grid(BotLookSpec.eyeStyles, selected: eyes, name: BotLookSpec.name(ofEyes:)) { e in
                    BotFaceView(spec: BotLookSpec(shape: shape, eyes: e, hex: hex, finish: current.finish), size: 58, active: eyes == e)
                } pick: { choice = .studio(shape: shape, eyes: $0, glass: glass) }
            case .colour:
                colourRow
            }
            glassRow
            HStack {
                Button("Reset to default") {
                    choice = .default
                    var map = BotColors.stored(); map[profile] = nil; BotColors.save(map)
                    colorsRaw = String(data: (try? JSONEncoder().encode(BotColors.stored())) ?? Data(), encoding: .utf8) ?? ""
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
                Spacer()
                if let photoError { Text(photoError).font(.caption).foregroundStyle(.red) }
            }
        }
        .padding(.vertical, 6)
        .animation(.snappy, value: tab)
        .onAppear { custom = BotColors.color(for: profile) }
    }

    private func grid<V: View>(_ ids: [String], selected: String, name: @escaping (String) -> String, @ViewBuilder preview: @escaping (String) -> V, pick: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
            ForEach(ids, id: \.self) { id in
                Button { pick(id) } label: {
                    VStack(spacing: 6) {
                        // The face carries its own tap (the small turn); here the tap is the pick,
                        // so the face is not a hit target and the button gets it.
                        preview(id)
                            .allowsHitTesting(false)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.tertiarySystemFill).opacity(selected == id ? 1 : 0)))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(selected == id ? Color.accentColor : .clear, lineWidth: 2))
                        Text(name(id)).font(.caption2).foregroundStyle(selected == id ? .primary : .secondary)
                    }
                    // The face is not hit-testable (above), which would leave a hole in the button
                    // exactly where people tap; the whole tile is the target.
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var colourRow: some View {
        let swatches = BotColors.palette + ["#FFFFFF", "#8E8E93", "#A2845E"]
        return VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 7), spacing: 12) {
                ForEach(swatches, id: \.self) { h in
                    Button { setColour(h) } label: {
                        Circle().fill(Color(hex: h) ?? .gray)
                            .frame(width: 34, height: 34)
                            // A hairline so the white swatch shows on a white card.
                            .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 1))
                            .overlay(Circle().stroke(Color.primary.opacity(hex.uppercased() == h.uppercased() ? 0.9 : 0), lineWidth: 2.5).padding(-4))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("", selection: $custom, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 34, height: 34)
                    .onChange(of: custom) { _, c in setColour(c.hexString) }
            }
            HStack(spacing: 14) {
                BotFaceView(spec: current, size: 44, active: true)
                Text("Colour, body and eyes are used everywhere this bot appears: chats, the Island, notifications.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Beta: the bot as Liquid Glass, like the app icon. Real glass in the app; the Island and
    /// notifications get a painted version of it.
    private var glassRow: some View {
        Toggle(isOn: Binding(get: { glass || glassAll }, set: { choice = .studio(shape: shape, eyes: eyes, glass: $0) })) {
            HStack(spacing: 10) {
                BotFaceView(spec: BotLookSpec(shape: shape, eyes: eyes, hex: hex, finish: "glass"), size: 30, active: false)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Liquid Glass").font(.subheadline)
                        Text("BETA").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15))).foregroundStyle(Color.accentColor)
                    }
                    Text(glassAll ? "On for every bot in Settings › Bots." : "The bot as a piece of glass, like the app icon.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(choice == .photo || glassAll)
        .accessibilityIdentifier("studio.glass")
    }

    private var photoRow: some View {
        HStack {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(choice == .photo ? "Change photo" : "Use a photo instead", systemImage: "photo")
                    .font(.subheadline)
            }
            .buttonStyle(.plain).foregroundStyle(.tint)
            Spacer()
            if choice == .photo {
                Button("Back to the bot") { BotAvatarStore.removePhoto(for: profile); choice = .studio(shape: shape, eyes: eyes, glass: glass) }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    try BotAvatarStore.savePhoto(data, for: profile)
                    photoVersion += 1
                    photoError = nil
                    choice = .photo
                } catch { photoError = error.localizedDescription }
                photoItem = nil
            }
        }
    }

    private func setColour(_ h: String) {
        var map = BotColors.stored(); map[profile] = h; BotColors.save(map)
        colorsRaw = String(data: (try? JSONEncoder().encode(BotColors.stored())) ?? Data(), encoding: .utf8) ?? ""
    }
}
