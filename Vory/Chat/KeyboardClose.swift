import Foundation
#if os(iOS)
import GameController
import UIKit
#endif

/// Whether the message field keeps the keyboard after a send (#350). The app's own chats keep it for the next message
/// unless Settings › Appearance › Close keyboard after sending is on; the demo and the tour put it away either way
/// (`composerFocusesAfterSend` is false there: #490, Matt: swiping it away was hard). The Mac has no on-screen keyboard
/// and never reads the setting.
enum ComposerFocusRule {
    static func afterSend(placeKeepsFocus: Bool, closeAfterSending: Bool) -> Bool {
        placeKeepsFocus && !closeAfterSending
    }
}

#if os(iOS)
/// When the chat closes the on-screen keyboard (#350): a tap in the thread, and VoiceOver's escape (the two-finger Z).
/// Only while a software keyboard is up: a field is editing and no hardware keyboard is attached. With a hardware
/// keyboard there is nothing on screen to close, and taking the field's focus would stop the typing.
enum KeyboardCloseRule {
    /// A tap at `y` (window points) in the thread closes the keyboard, unless it lands on the dock or the header, which
    /// float over the thread: a tap on the dock's glass between its controls reaches the scroll view under it.
    /// `dockTop` and `headerBottom` are 0 until measured, and then rule nothing out.
    static func tapCloses(y: CGFloat, dockTop: CGFloat, headerBottom: CGFloat, fieldEditing: Bool, hardwareKeyboard: Bool) -> Bool {
        guard escapeCloses(fieldEditing: fieldEditing, hardwareKeyboard: hardwareKeyboard) else { return false }
        if dockTop > 0, y >= dockTop { return false }
        if headerBottom > 0, y <= headerBottom { return false }
        return true
    }

    /// VoiceOver's escape closes the keyboard while one is up, and is then used up; otherwise it goes on to what it
    /// does anyway (Back, in a pushed chat).
    static func escapeCloses(fieldEditing: Bool, hardwareKeyboard: Bool) -> Bool {
        fieldEditing && !hardwareKeyboard
    }

    /// A hardware keyboard is attached now.
    @MainActor static var hardwareKeyboard: Bool { GCKeyboard.coalesced != nil }
}

extension UIResponder {
    private static weak var vory_found: UIResponder?
    /// The first responder now, if any: the one the responder chain's first stop answers from.
    static var vory_current: UIResponder? {
        vory_found = nil
        UIApplication.shared.sendAction(#selector(vory_markFirst), to: nil, from: nil, for: nil)
        return vory_found
    }
    @objc private func vory_markFirst() { UIResponder.vory_found = self }
}

/// A tap in the chat closes the on-screen keyboard (#350). A tap recognizer on the thread's scroll view that only
/// watches: it takes no touch from anything (a card, a link, Reasoning, a long press's menu get the same tap as without
/// it), delays nothing, recognizes alongside every other gesture and fails as soon as the finger moves, so scrolling and
/// the swipe that pulls the keyboard down work as before. Attached once to the thread's scroll view and removed when the
/// thread goes (`ScrollViewProbe`).
@MainActor final class ThreadKeyboardTap: NSObject, UIGestureRecognizerDelegate {
    var dockTop: CGFloat = 0
    var headerBottom: CGFloat = 0
    private weak var scrollView: UIScrollView?
    private var tap: UITapGestureRecognizer?

    func attach(to sv: UIScrollView) {
        guard sv !== scrollView else { return }
        detach()
        let t = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        t.cancelsTouchesInView = false
        t.delaysTouchesBegan = false
        t.delaysTouchesEnded = false
        t.delegate = self
        t.name = "vory.keyboardTap"
        sv.addGestureRecognizer(t)
        scrollView = sv
        tap = t
    }

    func detach() {
        if let tap, let scrollView { scrollView.removeGestureRecognizer(tap) }
        tap = nil
        scrollView = nil
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let window = g.view?.window else { return }
        let y = g.location(in: window).y
        guard KeyboardCloseRule.tapCloses(y: y, dockTop: dockTop, headerBottom: headerBottom,
                                          fieldEditing: UIResponder.vory_current is UITextInput,
                                          hardwareKeyboard: KeyboardCloseRule.hardwareKeyboard) else { return }
        // On the next turn, once whatever else took the same tap has acted on the layout it was touched on: closing
        // the keyboard moves the thread (at its end, down by the keyboard's height), and a link in the last reply,
        // resolved after the move, was no longer under the finger. The keyboard went and the link didn't open.
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
