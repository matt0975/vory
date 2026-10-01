import Foundation

/// The words for the device the app runs on, so shared copy reads right on either: "this
/// phone", "tap" and "iOS Settings" on the iPhone; "this Mac", "click" and "System Settings"
/// on the Mac, where there is also no Live Activity to promise.
enum DeviceWords {
    #if os(macOS)
    static let this = "this Mac"
    static let This = "This Mac"
    static let your = "your Mac"
    static let the = "the Mac"
    static let settings = "System Settings"
    static let kind = "Mac"
    static let tap = "click"
    static let Tap = "Click"
    /// What the Companion brings, in a sentence.
    static let companionBrings = "notifications and approval cards"
    static let CompanionBrings = "Notifications and approval cards"
    /// "…sends replies as notifications, [keeps the Live Activity up to date, ]and…"
    static let keepsActivity = ""
    static let isMac = true
    #else
    static let this = "this phone"
    static let This = "This phone"
    static let your = "your phone"
    static let the = "the phone"
    static let settings = "iOS Settings"
    static let kind = "phone"
    static let tap = "tap"
    static let Tap = "Tap"
    static let companionBrings = "notifications, Live Activities and approval cards"
    static let CompanionBrings = "Notifications, Live Activities and approval cards"
    static let keepsActivity = "keeps the Live Activity up to date, "
    static let isMac = false
    #endif
}
