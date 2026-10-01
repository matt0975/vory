import Foundation

/// The words for the device the app runs on, so shared copy reads right on either: "this
/// phone" and "iOS Settings" on the iPhone, "this Mac" and "System Settings" on the Mac.
enum DeviceWords {
    #if os(macOS)
    static let this = "this Mac"
    static let your = "your Mac"
    static let settings = "System Settings"
    static let kind = "Mac"
    #else
    static let this = "this phone"
    static let your = "your phone"
    static let settings = "iOS Settings"
    static let kind = "phone"
    #endif
}
