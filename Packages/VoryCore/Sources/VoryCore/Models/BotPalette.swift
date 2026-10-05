import Foundation

/// The colours a bot gets when none was picked for it: one list for every device, so the phone,
/// the watch and the Mac draw the same bot the same (the watch's own copy had drifted by a
/// digit per colour).
public enum BotPalette {
    public static let hexes: [String] = ["#7C5CFF", "#0A84FF", "#30D158", "#FF9F0A", "#FF375F", "#64D2FF", "#BF5AF2", "#FFD60A", "#FF6B35", "#5AC8FA"]

    /// Deterministic pick: same name, same colour, on every device.
    public static func defaultHex(for profile: String) -> String {
        var hash: UInt64 = 5381
        for b in profile.utf8 { hash = (hash &* 33) &+ UInt64(b) }
        return hexes[Int(hash % UInt64(hexes.count))]
    }
}
