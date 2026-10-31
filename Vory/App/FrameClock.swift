import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The next display frame, awaited (#453): a wait measured in the app's passes at the screen, which stretches as the app
/// gets fewer of them under load, where a wait in milliseconds stays the same length and so means less. One display link
/// serves every waiter and runs only while one waits. With no screen to draw on (the app away), no frame comes: callers
/// keep a timed cap of their own.
@MainActor final class FrameClock: NSObject {
    private static let shared = FrameClock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var link: CADisplayLink?

    static func next() async { await shared.next() }

    private func next() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
            guard link == nil else { return }
            #if os(macOS)
            guard let l = NSScreen.main?.displayLink(target: self, selector: #selector(tick)) else { resumeAll(); return }
            #else
            let l = CADisplayLink(target: self, selector: #selector(tick))
            #endif
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    @objc private func tick() {
        link?.invalidate(); link = nil
        resumeAll()
    }

    private func resumeAll() {
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }
}
