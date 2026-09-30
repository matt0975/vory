import Foundation

/// The Mac has no Live Activity. What stays is the diagnostics log the shared model and the
/// push registrar write to (`note`), so those files read the same on both platforms; the
/// menu-bar turn reporter lands beside it later.
enum LiveActivityController {
    private static let logLock = NSLock()
    nonisolated(unsafe) private static var logStorage: [String] = []

    /// The last dozen notes, newest last.
    nonisolated static var log: [String] { logLock.lock(); defer { logLock.unlock() }; return logStorage }

    nonisolated static func note(_ what: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        logLock.lock(); defer { logLock.unlock() }
        logStorage.append("\(stamp) \(what)")
        if logStorage.count > 12 { logStorage.removeFirst(logStorage.count - 12) }
    }
}

extension Notification.Name {
    /// Posted by the iOS activity when its push token changes; the registrar observes it on both
    /// platforms and nothing posts it here.
    static let hermesLiveActivityToken = Notification.Name("hermesLiveActivityToken")
}
