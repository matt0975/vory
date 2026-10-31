import SwiftUI
import VoryCore
import WatchKit

/// The bot's face on the watch: the look the iPhone sent (shape, eyes, colour, or a photo),
/// drawn still. Falls back to the default shape in the bot's palette colour.
struct WatchBotFace: View {
    @Environment(WatchModel.self) private var model
    var profile: String
    var label: String? = nil
    var size: CGFloat = 24

    var body: some View {
        let looks = model.looks
        let key = looks.key(profile: profile, label: label ?? "") ?? profile
        if looks.avatars[key] == "photo", let data = looks.photos[key], let img = WatchPhotoCache.image(key: key, data: data) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(.circle)
        } else {
            let hex = looks.colors[key] ?? WatchBotColor.hex(for: profile)
            BotFaceView(spec: BotLookSpec.from(choice: looks.avatars[key], hex: hex), size: size, active: false, drawn: true)
                .frame(width: size, height: size)
        }
    }
}

/// A bot's photo, decoded once: a list of chats used to decode the same JPEG for every row on
/// every redraw.
@MainActor
enum WatchPhotoCache {
    private static var images: [String: (bytes: Int, image: UIImage)] = [:]
    static func image(key: String, data: Data) -> UIImage? {
        if let hit = images[key], hit.bytes == data.count { return hit.image }
        guard let img = UIImage(data: data) else { return nil }
        images[key] = (data.count, img)
        return img
    }
}

/// The same deterministic palette the phone uses when no colour was picked for a bot: the
/// phone's list itself, from VoryCore (a copy here had every colour off by a digit).
enum WatchBotColor {
    static func hex(for profile: String) -> String { BotPalette.defaultHex(for: profile) }
    static func color(for profile: String) -> Color { Color(botHex: hex(for: profile)) ?? .accentColor }
}
