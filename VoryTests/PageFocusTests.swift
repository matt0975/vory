#if os(macOS)
import AppKit
import Testing
@testable import Vory

/// The keyboard focus across page switches on the Mac (#640): a page that hides never keeps it, and gets back what it
/// had when it shows again. On a window made here and never ordered in: nothing on screen, nothing brought forward.
@MainActor @Suite struct PageFocusTests {
    enum Page { case chats, settings, bots }

    /// A window with two text fields, never shown.
    private func window() -> (NSWindow, NSTextField, NSTextField) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        let a = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        let b = NSTextField(frame: NSRect(x: 10, y: 50, width: 200, height: 24))
        w.contentView?.addSubview(a)
        w.contentView?.addSubview(b)
        return (w, a, b)
    }

    private func holder(_ w: NSWindow) -> NSView? { PageFocus.holder(of: w.firstResponder) }

    @Test func aPageGetsBackTheFieldItHadWhenItWasLeft() {
        let (w, a, _) = window()
        #expect(w.makeFirstResponder(a))
        #expect(holder(w) === a, "a field being edited is held by the field, not the shared editor")
        let focus = PageFocus()
        #expect(focus.leave(Page.chats, in: w))
        #expect(focus.back(Page.chats, in: w))
        #expect(holder(w) === a)
    }

    @Test func thePageThatHidesNeverKeepsTheFocus() {
        let (w, a, _) = window()
        #expect(w.makeFirstResponder(a))
        let focus = PageFocus()
        #expect(focus.leave(Page.chats, in: w))
        #expect(w.firstResponder === w, "the window holds the focus while the page is hidden")
    }

    @Test func aFieldGoneFromTheWindowIsNotGivenBack() {
        let (w, a, _) = window()
        #expect(w.makeFirstResponder(a))
        let focus = PageFocus()
        focus.leave(Page.chats, in: w)
        a.removeFromSuperview()
        #expect(!focus.back(Page.chats, in: w))
        #expect(w.firstResponder === w)
    }

    @Test func aPageWithNothingKeptGetsNothing() {
        let (w, _, _) = window()
        let focus = PageFocus()
        #expect(focus.leave(Page.settings, in: w), "nothing had the focus: the window has it")
        #expect(!focus.back(Page.settings, in: w))
        #expect(!focus.back(Page.bots, in: w), "a page never left gets nothing")
        #expect(w.firstResponder === w)
    }

    @Test func onePagesFocusNeverGoesToAnother() {
        let (w, a, b) = window()
        let focus = PageFocus()
        #expect(w.makeFirstResponder(a))
        focus.leave(Page.chats, in: w)
        #expect(w.makeFirstResponder(b))
        focus.leave(Page.settings, in: w)
        #expect(!focus.back(Page.bots, in: w))
        #expect(focus.back(Page.settings, in: w))
        #expect(holder(w) === b)
        focus.leave(Page.settings, in: w)
        #expect(focus.back(Page.chats, in: w))
        #expect(holder(w) === a)
        #expect(!focus.back(Page.chats, in: w), "given back once")
    }
}
#endif
