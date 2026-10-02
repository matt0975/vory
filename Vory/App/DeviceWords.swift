import Foundation

/// The words for the device the app runs on, so shared copy reads right on each: "this
/// iPhone", "this iPad" or "this Mac", "tap" or "click", "Settings" or "System Settings". On
/// the Mac there is also no Live Activity to promise.
enum DeviceWords {
    #if os(macOS)
    static let device = "Mac"
    static let settings = "System Settings"
    static let tap = "click"
    static let Tap = "Click"
    /// What the Companion brings, in a sentence.
    static let companionBrings = "notifications and approval cards"
    static let CompanionBrings = "Notifications and approval cards"
    /// "…sends replies as notifications, [keeps the Live Activity up to date, ]and…"
    static let keepsActivity = ""
    static let isMac = true
    /// The SF Symbol for this kind of device.
    static let symbol = "laptopcomputer"
    #else
    /// "iPhone" or "iPad", from the hardware's model name. Read without UIKit (whose device
    /// object belongs to the main actor) so these stay plain constants usable from anywhere.
    static let device: String = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        // The simulator reports the Mac's architecture; it names the simulated model here.
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        return model.hasPrefix("iPad") ? "iPad" : "iPhone"
    }()
    static let settings = "Settings"
    static let tap = "tap"
    static let Tap = "Tap"
    static let companionBrings = "notifications, Live Activities and approval cards"
    static let CompanionBrings = "Notifications, Live Activities and approval cards"
    static let keepsActivity = "keeps the Live Activity up to date, "
    static let isMac = false
    static let symbol = device == "iPad" ? "ipad" : "iphone"
    #endif

    static let this = "this \(device)"
    static let This = "This \(device)"
    /// In a title-case button ("Back Up This iPad Now").
    static let ThisTitle = "This \(device)"
    static let your = "your \(device)"
    static let the = "the \(device)"
    /// The device as a bare word in a sentence ("the iPhone cannot reach the gateway").
    static let kind = device
}
