import Foundation
import Network

/// Whether the device has a usable network path, and when that changes. On first open over a
/// private network (a tailnet) the route is often not up yet: the first connection attempt
/// goes out before it, fails, and then waited longer and longer. The socket's connect loop
/// asks here: while the path is not usable it waits for the next change rather than a
/// growing delay, and retries the moment the path comes up (#305).
public final class NetworkWatch: @unchecked Sendable {
    public static let shared = NetworkWatch()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.vory.network-watch")
    private let lock = NSLock()
    private var usable = true
    private var changes = 0
    private var started = false

    public init() {}

    /// Starts the monitor the first time anything asks.
    private func startIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.usable = path.status == .satisfied
            self.changes += 1
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    /// True when a path is up (and before the monitor has answered at all).
    public var isUsable: Bool {
        startIfNeeded()
        lock.lock(); defer { lock.unlock() }
        return usable
    }

    /// A count that moves with every path change, to wait against.
    public var mark: Int {
        startIfNeeded()
        lock.lock(); defer { lock.unlock() }
        return changes
    }

    /// Returns when the path has changed since `mark`, or after `seconds`, whichever is first.
    public func waitForChange(since mark: Int, upTo seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !Task.isCancelled {
            if self.mark != mark { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}
