import AppKit

/// The keyboard focus across page switches on the Mac. A page that hides gives the focus up: the pages stay mounted,
/// and a hidden one that kept it took keys and pastes out of sight and out of the accessibility tree (the window takes
/// it, as when a page was torn down). What a page had when it was left (its composer, its search field, a form's
/// field) is given back when that page shows again, if it is still in the window; a page with nothing kept gets
/// nothing, so a page's search never takes letters meant for a shortcut.
@MainActor
final class PageFocus {
    private final class Kept { weak var view: NSView? ; init(_ view: NSView) { self.view = view } }
    private var kept: [AnyHashable: Kept] = [:]

    /// The view that holds the focus for a responder: a text field for the field editor that edits it (the editor
    /// is the window's, shared by every field, so it can't be given back), the view itself otherwise; nothing for the
    /// window or anything that isn't a view.
    static func holder(of responder: NSResponder?) -> NSView? {
        if let editor = responder as? NSTextView, editor.isFieldEditor { return editor.delegate as? NSView }
        if responder is NSWindow { return nil }
        return responder as? NSView
    }

    /// The page hides: what had the focus is kept for it, and the window takes the focus. False when the window
    /// couldn't take it.
    @discardableResult
    func leave(_ page: AnyHashable, in window: NSWindow) -> Bool {
        if let view = Self.holder(of: window.firstResponder), view.window === window { kept[page] = Kept(view) } else { kept[page] = nil }
        guard window.firstResponder !== window else { return true }
        return window.makeFirstResponder(nil)
    }

    /// The page shows again: what it had gets the focus back, once, if it is still in this window.
    @discardableResult
    func back(_ page: AnyHashable, in window: NSWindow) -> Bool {
        guard let view = kept.removeValue(forKey: page)?.view, view.window === window else { return false }
        return window.makeFirstResponder(view)
    }
}
