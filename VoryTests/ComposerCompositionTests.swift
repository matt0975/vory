#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Vory

/// A hardware keyboard with an input method composing (Japanese, Chinese, Korean and others):
/// the composer's Return, arrows, Tab and Escape are the input method's until its text is in,
/// so Return takes the candidate instead of sending the half-converted text and the arrows
/// move through the candidates instead of stepping through history or the chooser. Without
/// marked text the keys are the composer's, as before. The simulator's keyboard is English, which
/// has no input method: the tests that compose say the keyboard is an input method's.
@MainActor @Suite struct ComposerCompositionTests {
    /// The keyboard as an input method's or not (see InputComposition.inputMethod); the closure
    /// returned puts it back.
    private func keyboard(inputMethod: Bool) -> () -> Void {
        let kept = InputComposition.inputMethod
        InputComposition.inputMethod = { _ in inputMethod }
        return { InputComposition.inputMethod = kept }
    }

    private final class Calls {
        var sends = 0, returns = 0, tabs = 0, escapes = 0
        var arrows: [Int] = []
        var none: Bool { sends == 0 && returns == 0 && tabs == 0 && escapes == 0 && arrows.isEmpty }
    }

    /// A hardware key as UIKit hands it to the text view (UIKit has no way to make one).
    private final class Key: UIKey {
        private let code: UIKeyboardHIDUsage, flags: UIKeyModifierFlags
        init(_ code: UIKeyboardHIDUsage, _ flags: UIKeyModifierFlags = []) { self.code = code; self.flags = flags; super.init() }
        required init?(coder: NSCoder) { nil }
        override var keyCode: UIKeyboardHIDUsage { code }
        override var modifierFlags: UIKeyModifierFlags { flags }
    }

    private final class Press: UIPress {
        private let k: UIKey
        init(_ k: UIKey) { self.k = k; super.init() }
        override var key: UIKey? { k }
    }

    private func keys(_ code: UIKeyboardHIDUsage, _ flags: UIKeyModifierFlags = []) -> Set<UIPress> { [Press(Key(code, flags))] }

    /// The composer's text view as the representable sets it up, with callbacks that count.
    private func composer(_ calls: Calls, text: String = "", menuOpen: Bool = false, returnSends: Bool = false) -> (PasteTextView, ComposerTextView.Coordinator) {
        let parent = ComposerTextView(text: .constant(text), placeholder: "Type / for commands", focused: .constant(false),
                                      onSend: { calls.sends += 1 },
                                      onArrow: { calls.arrows.append($0); return true },
                                      onReturn: { calls.returns += 1; return false },
                                      returnSends: returnSends,
                                      menuOpen: menuOpen,
                                      onTab: { calls.tabs += 1; return true },
                                      onEscape: { calls.escapes += 1; return true })
        let coordinator = parent.makeCoordinator()
        let v = PasteTextView()
        v.delegate = coordinator
        v.coordinator = coordinator
        v.text = text
        return (v, coordinator)
    }

    private func command(_ v: PasteTextView, _ input: String, _ flags: UIKeyModifierFlags = []) -> UIKeyCommand? {
        v.keyCommands?.first { $0.input == input && $0.modifierFlags == flags }
    }

    private func press(_ v: PasteTextView, _ c: UIKeyCommand) {
        _ = v.perform(c.action)
    }

    private func end(_ v: PasteTextView) -> NSRange { NSRange(location: (v.text as NSString).length, length: 0) }

    /// The view in a key window of its own, the first responder, as while it is typed in; the
    /// closure returned puts things back.
    private func focus(_ v: UIView) throws -> () -> Void {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        v.frame = CGRect(x: 20, y: 100, width: 300, height: 80)
        window.addSubview(v)
        window.makeKeyAndVisible()
        _ = v.becomeFirstResponder()
        return {
            v.resignFirstResponder()
            window.isHidden = true
            previous?.makeKey()
        }
    }

    @Test func withoutMarkedTextTheKeysAreTheComposers() throws {
        let calls = Calls()
        let (v, c) = composer(calls, text: "hello", menuOpen: true)
        #expect(!v.isComposing)
        let send = try #require(command(v, "\r"))
        #expect(v.canPerformAction(try #require(send.action), withSender: send))
        press(v, send)
        // The chooser was asked first (it said no), then the text went.
        #expect(calls.returns == 1 && calls.sends == 1)
        press(v, try #require(command(v, UIKeyCommand.inputUpArrow)))
        press(v, try #require(command(v, UIKeyCommand.inputDownArrow)))
        #expect(calls.arrows == [-1, 1])
        press(v, try #require(command(v, "\t")))
        press(v, try #require(command(v, UIKeyCommand.inputEscape)))
        #expect(calls.tabs == 1 && calls.escapes == 1)
        press(v, try #require(command(v, "\r", .command)))
        #expect(calls.sends == 2)
        _ = c
    }

    @Test func whileComposingNoKeyIsTakenFromTheInputMethod() throws {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        for menuOpen in [false, true] {
            let calls = Calls()
            let (v, c) = composer(calls, menuOpen: menuOpen)
            // The commands as UIKit may still hold them from before the composing began.
            let held = try #require(v.keyCommands)
            #expect(held.count == (menuOpen ? 7 : 5))
            v.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
            #expect(v.markedTextRange != nil && v.isComposing)
            // None is offered while composing, and one still held is declined (its key goes on).
            #expect(v.keyCommands?.isEmpty == true)
            for cmd in held {
                #expect(!v.canPerformAction(try #require(cmd.action), withSender: cmd))
                // Called all the same, it does nothing.
                press(v, cmd)
            }
            #expect(calls.none)
            // The candidate is as it was: no line break or tab added, still marked.
            #expect(v.text == "にほん")
            #expect(v.markedTextRange != nil)
            _ = c
        }
    }

    @Test func onceTheCandidateIsTakenReturnSendsAgain() throws {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let calls = Calls()
        let (v, c) = composer(calls)
        v.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        #expect(command(v, "\r") == nil)
        v.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        #expect(command(v, UIKeyCommand.inputDownArrow) == nil)
        v.unmarkText()
        #expect(v.markedTextRange == nil && v.text == "日本")
        // Every key is the composer's again, each doing what it did before.
        #expect(v.keyCommands?.count == 5)
        press(v, try #require(command(v, "\r")))
        #expect(calls.sends == 1)
        press(v, try #require(command(v, UIKeyCommand.inputUpArrow)))
        #expect(calls.arrows == [-1])
        _ = c
    }

    /// Japanese and Chinese take a Return whole (it confirms the candidate, or the letters as
    /// typed): it is waited on only while the key is down, so a line break that comes later
    /// (the on-screen keyboard's) is a new line, not a send.
    @Test func aReturnTakenWholeIsForgottenWhenTheKeyComesUp() {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let calls = Calls()
        let (v, c) = composer(calls)
        // Without marked text the key commands have the Return: nothing is waited on.
        v.pressesBegan(keys(.keyboardReturnOrEnter), with: nil)
        #expect(v.composedReturn == nil)
        v.pressesEnded(keys(.keyboardReturnOrEnter), with: nil)

        v.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        // Another key while composing (the arrows through the candidates): nothing either.
        v.pressesBegan(keys(.keyboardDownArrow), with: nil)
        #expect(v.composedReturn == nil)
        v.pressesEnded(keys(.keyboardDownArrow), with: nil)

        v.pressesBegan(keys(.keyboardReturnOrEnter), with: nil)
        #expect(v.composedReturn != nil)
        v.unmarkText()
        // A key other than Return coming up leaves it.
        v.pressesEnded(keys(.keyboardDownArrow), with: nil)
        #expect(v.composedReturn != nil)
        v.pressesEnded(keys(.keyboardReturnOrEnter), with: nil)
        #expect(v.composedReturn == nil)
        #expect(c.textView(v, shouldChangeTextIn: end(v), replacementText: "\n") == true)
        #expect(calls.sends == 0)

        // A cancelled press ends it too; the keypad's Enter is a Return.
        v.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        v.pressesBegan(keys(.keypadEnter), with: nil)
        #expect(v.composedReturn != nil)
        v.pressesCancelled(keys(.keypadEnter), with: nil)
        #expect(v.composedReturn == nil)
        #expect(calls.sends == 0 && calls.arrows.isEmpty)
    }

    /// Korean takes its block on Return and then hands the Return on as a line break: that break
    /// is the hardware Return's, so it sends (Shift-Return adds the line, ⌘-Return sends).
    @Test func aReturnHandedOnAfterTheTextIsInFollowsTheHardwareRule() {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let calls = Calls()
        let (v, c) = composer(calls, text: "안")
        func typeAndReturn(_ flags: UIKeyModifierFlags) -> Bool {
            v.setMarkedText("녕", selectedRange: NSRange(location: 1, length: 0))
            v.pressesBegan(keys(.keyboardReturnOrEnter, flags), with: nil)
            #expect(v.composedReturn?.shift == flags.contains(.shift))
            v.unmarkText()
            let inserted = c.textView(v, shouldChangeTextIn: end(v), replacementText: "\n")
            // Taken by that line break, and over when the key comes up all the same.
            #expect(v.composedReturn == nil)
            v.pressesEnded(keys(.keyboardReturnOrEnter, flags), with: nil)
            return inserted
        }
        #expect(typeAndReturn([]) == false)
        #expect(v.text == "안녕" && calls.sends == 1)
        #expect(typeAndReturn(.shift) == true)
        #expect(calls.sends == 1)
        #expect(typeAndReturn(.command) == false)
        #expect(calls.sends == 2)
        // A line break with no hardware Return behind it is the on-screen keyboard's: a new line.
        #expect(c.textView(v, shouldChangeTextIn: end(v), replacementText: "\n") == true)
        #expect(calls.sends == 2)
    }

    /// Shift-Return adds a line whichever the Return key setting is: the line break it puts in
    /// is not the on-screen Return, which sends when the setting says so.
    @Test func aHardwareShiftReturnAddsALineWhicheverTheSetting() throws {
        for returnSends in [false, true] {
            let calls = Calls()
            let (v, c) = composer(calls, text: "hi", returnSends: returnSends)
            // Typed text only lands in a field being typed in.
            let unfocus = try focus(v)
            defer { unfocus() }
            press(v, try #require(command(v, "\r", .shift)))
            #expect(calls.sends == 0, "returnSends \(returnSends)")
            #expect(v.text == "hi\n", "returnSends \(returnSends)")
            _ = c
        }
    }

    /// A Tab with the chooser open, taken by the input method while composing and handed on as a
    /// tab once the text is in (Korean does): it completes the chooser's item, as the key command
    /// does. Taken whole (Japanese, Chinese), or with no chooser, a tab later is a tab.
    @Test func aTabHandedOnCompletesTheChoosersItem() {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let calls = Calls()
        let (v, c) = composer(calls, text: "@", menuOpen: true)
        v.setMarkedText("미", selectedRange: NSRange(location: 1, length: 0))
        v.pressesBegan(keys(.keyboardTab), with: nil)
        #expect(v.composedTab)
        v.unmarkText()
        #expect(c.textView(v, shouldChangeTextIn: end(v), replacementText: "\t") == false)
        #expect(calls.tabs == 1 && !v.composedTab)
        v.pressesEnded(keys(.keyboardTab), with: nil)

        // Taken whole: the key coming up ends the wait.
        v.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        v.pressesBegan(keys(.keyboardTab), with: nil)
        v.unmarkText()
        v.pressesEnded(keys(.keyboardTab), with: nil)
        #expect(!v.composedTab)
        #expect(c.textView(v, shouldChangeTextIn: end(v), replacementText: "\t") == true)
        // Shift-Tab is not the chooser's.
        v.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        v.pressesBegan(keys(.keyboardTab, .shift), with: nil)
        #expect(!v.composedTab)
        v.pressesEnded(keys(.keyboardTab, .shift), with: nil)
        v.unmarkText()
        #expect(calls.tabs == 1 && calls.sends == 0)

        // No chooser open: the Tab is not waited on.
        let (w, d) = composer(calls)
        w.setMarkedText("미", selectedRange: NSRange(location: 1, length: 0))
        w.pressesBegan(keys(.keyboardTab), with: nil)
        #expect(!w.composedTab)
        w.unmarkText()
        #expect(d.textView(w, shouldChangeTextIn: end(w), replacementText: "\t") == true)
        w.pressesEnded(keys(.keyboardTab), with: nil)
        #expect(calls.tabs == 1)
    }

    /// Marked text under a keyboard with no input method is a grey inline prediction (or a dead
    /// key's accent): the keys stay the composer's, as before.
    @Test func markedTextWithoutAnInputMethodLeavesTheKeysTheComposers() throws {
        let restore = keyboard(inputMethod: false)
        defer { restore() }
        let calls = Calls()
        let (v, c) = composer(calls, text: "see you tomor", menuOpen: true)
        v.setMarkedText("row", selectedRange: NSRange(location: 0, length: 0))
        #expect(v.markedTextRange != nil && !v.isComposing)
        #expect(v.keyCommands?.count == 7)
        let up = try #require(command(v, UIKeyCommand.inputUpArrow))
        #expect(v.canPerformAction(try #require(up.action), withSender: up))
        press(v, up)
        #expect(calls.arrows == [-1])
        v.pressesBegan(keys(.keyboardReturnOrEnter), with: nil)
        v.pressesBegan(keys(.keyboardTab), with: nil)
        #expect(v.composedReturn == nil && !v.composedTab)
        _ = c
    }

    /// An English keyboard has no input method; any other may (Japanese, Chinese, Korean and
    /// others), and so may one whose language is not known. Dictation and the emoji keyboard have
    /// none: while dictation runs, ⌘-Return, the chooser's arrows and Escape are the composer's.
    @Test func onlyAnEnglishKeyboardHasNoInputMethod() {
        for language in ["en", "en-US", "en-GB", "en_AU", "dictation", "emoji"] { #expect(!InputComposition.isInputMethod(language: language), "\(language)") }
        for language in ["ja-JP", "zh-Hans", "zh-Hant", "yue-Hant", "ko-KR", "vi-VN", "hi"] { #expect(InputComposition.isInputMethod(language: language), "\(language)") }
        #expect(InputComposition.isInputMethod(language: nil))
    }

    /// The New Message sheet's To: field is SwiftUI's: the focused field is found through the
    /// responder chain, and Backspace leaves the chips alone while it composes.
    @Test func theFocusedFieldIsSeenComposing() throws {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let field = UITextField()
        let unfocus = try focus(field)
        defer { unfocus() }
        #expect(field.isFirstResponder)
        #expect(!InputComposition.isActive)
        field.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        #expect(InputComposition.isActive)
        field.unmarkText()
        #expect(!InputComposition.isActive)
    }
}
#elseif os(macOS)
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import Testing
@testable import Vory

/// The Mac composer's keys step aside while the field editor holds an input method's marked text.
/// SwiftUI runs the composer's key handlers before the input method sees the key; one that takes
/// its text and passes the key on (Korean does) has it reach the field, and there it does what it
/// does when nothing is composing. With no input method on this Mac (the keyboard is a layout),
/// a key sent to a window with marked text in its field does just that: commits the text and goes
/// on to the field. The tests say the keyboard is an input method's where they compose.
@MainActor @Suite(.serialized) struct ComposerCompositionTests {
    /// The keyboard as an input method's or not (see InputComposition.inputMethod); the closure
    /// returned puts it back.
    private func keyboard(inputMethod: Bool) -> () -> Void {
        let kept = InputComposition.inputMethod
        InputComposition.inputMethod = { _ in inputMethod }
        return { InputComposition.inputMethod = kept }
    }

    /// Caps Lock being on and a key sitting on the keypad are modifiers to SwiftUI; to the
    /// composer they are not chords, so a Return or a Tab under them still reaches the chooser,
    /// and the keypad's Enter is the Return key the handler listens for (#275).
    @Test func capsLockAndTheKeypadDoNotMakeAChord() {
        #expect(ComposedKeys.plain([.capsLock, .numericPad]).isEmpty)
        #expect(ComposedKeys.plain([.shift, .capsLock]) == [.shift])
        #expect(ComposedKeys.plain([.command]) == [.command])
        #expect(ComposedKeys.keypadEnter == KeyEquivalent("\u{3}"))
        #expect(ComposedKeys.keypadEnter != .return)
    }

    @Test func aFieldEditorWithMarkedTextIsComposing() {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        #expect(!InputComposition.isComposing(editor))
        editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(InputComposition.isComposing(editor))
        editor.unmarkText()
        #expect(!InputComposition.isComposing(editor))
        #expect(!InputComposition.isComposing(nil))
    }

    /// Marked text under a plain keyboard layout is a grey inline prediction (or a dead key's
    /// accent), not an input method's.
    @Test func markedTextUnderAKeyboardLayoutIsNotComposing() {
        let restore = keyboard(inputMethod: false)
        defer { restore() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        editor.setMarkedText("row", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText() && !InputComposition.isComposing(editor))
        #expect(!InputComposition.isInputMethod(sourceType: kTISTypeKeyboardLayout as String))
        #expect(InputComposition.isInputMethod(sourceType: kTISTypeKeyboardInputMode as String))
        #expect(InputComposition.isInputMethod(sourceType: kTISTypeKeyboardInputMethodWithoutModes as String))
    }

    /// The composer is SwiftUI's TextField: while it is typed in, the window's first responder is
    /// its field editor, which holds the marked text. That is the responder the keys look at.
    @Test func theComposersFieldIsReadThroughTheWindowsFieldEditor() async throws {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ComposerTextView(text: .constant(""), placeholder: "Message", focused: .constant(false)))
        window.contentView = host
        let field = try #require(try await Self.fields(in: host).first)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor !== field && editor.isFieldEditor)
        #expect(!InputComposition.isComposing(window.firstResponder))
        editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(InputComposition.isComposing(window.firstResponder))
        editor.unmarkText()
        #expect(!InputComposition.isComposing(window.firstResponder))
    }

    /// Korean: Shift-Return with the last block still composing takes the block and passes the
    /// key on. It adds a line where it was pressed and sends nothing (it used to reach the
    /// field's submit and send the message).
    @Test func aShiftReturnPassedOnAddsALine() async throws {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let c = try await Composer()
        defer { c.window.close() }
        c.compose("안", marked: "녕")
        try await c.until { c.model.text == "안" }
        try await c.key("\r", 36, .shift)
        try await c.until { c.model.text == "안녕\n" }
        #expect(c.model.sends.isEmpty)
        // In the field itself, the cursor after the line break, and typing goes on from there.
        let editor = try #require(c.editor)
        #expect(editor.string == "안녕\n" && editor.selectedRange() == NSRange(location: 3, length: 0))
        editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await c.until { c.model.text == "안녕\nx" }

        // In the middle of the text: the line break goes in after the block, before the rest.
        // (Text set in the same turn as typing never reaches a SwiftUI field: a beat first.)
        try await Task.sleep(for: .milliseconds(100))
        c.model.text = "ab de"
        try await c.until { c.editor?.string == "ab de" }
        c.editor?.setSelectedRange(NSRange(location: 2, length: 0))
        c.compose("", marked: "c")
        try await c.key("\r", 36, .shift)
        try await c.until { c.model.text == "abc\n de" }
        #expect(c.editor?.selectedRange() == NSRange(location: 4, length: 0))
        #expect(c.model.sends.isEmpty)
    }

    /// Korean: a bare Return passed on takes the chooser's item when it is open, as it does when
    /// nothing is composing (it used to send the half-typed command), and sends otherwise.
    @Test func aReturnPassedOnTakesTheChoosersItemOrSends() async throws {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let c = try await Composer()
        defer { c.window.close() }
        c.model.menuOpen = true
        c.compose("/mo", marked: "d")
        try await c.until { c.model.text == "/mo" }
        try await Task.sleep(for: .milliseconds(200))
        try await c.key("\r", 36)
        try await c.until { c.model.returns == 1 }
        #expect(c.model.sends.isEmpty)
        try await c.until { c.editor?.string == "/model " }
        #expect(c.model.text == "/model " && c.editor?.selectedRange() == NSRange(location: 7, length: 0))

        c.model.text = ""
        try await c.until { c.editor?.string == "" }
        c.compose("안", marked: "녕")
        try await c.key("\r", 36)
        try await c.until { c.model.sends == ["안녕"] }
        #expect(c.model.returns == 1)
    }

    /// Korean: Tab with the chooser open takes the block and passes the key on, and the field
    /// moves the focus on. The focus comes back and the item is completed, as it is when nothing
    /// is composing, with the cursor after it.
    @Test func aTabPassedOnCompletesTheChoosersItem() async throws {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let c = try await Composer()
        defer { c.window.close() }
        c.model.menuOpen = true
        c.compose("/mo", marked: "d")
        try await c.until { c.model.text == "/mo" }
        // The composer is handed the open chooser in SwiftUI's next update.
        try await Task.sleep(for: .milliseconds(200))
        try await c.key("\t", 48)
        try await c.until { c.model.tabs == 1 }
        try await c.until { c.editor?.string == "/model " }
        #expect(c.editor?.delegate as? NSView === c.field)
        #expect(c.editor?.selectedRange() == NSRange(location: 7, length: 0))
        #expect(c.model.text == "/model " && c.model.sends.isEmpty)
    }

    /// A Tab passed on with no item in the chooser for the text: the focus comes back all the
    /// same, and the cursor is where it was, after the block (the field took up its editing with
    /// all of the text selected).
    @Test func aTabPassedOnWithNoItemPutsTheCursorBack() async throws {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let c = try await Composer()
        defer { c.window.close() }
        c.model.matches = false
        c.model.text = "/ab de"
        try await c.until { c.editor?.string == "/ab de" }
        c.editor?.setSelectedRange(NSRange(location: 3, length: 0))
        c.compose("", marked: "c")
        c.model.menuOpen = true
        try await Task.sleep(for: .milliseconds(200))
        try await c.key("\t", 48)
        try await c.until { c.editor?.selectedRange() == NSRange(location: 4, length: 0) }
        #expect(c.editor?.string == "/abc de" && c.editor?.hasMarkedText() == false)
        #expect(c.model.text == "/abc de" && c.model.tabs == 0 && c.model.sends.isEmpty)
    }

    /// The composer alone in its window: a Tab passed on ends the field's editing and the field
    /// takes it up again, so the focus never leaves. The item is completed all the same (it
    /// used to be missed, waiting for the focus to come back).
    @Test func aTabPassedOnWithTheComposerAloneCompletesTheItem() async throws {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let c = try await Composer(alone: true)
        defer { c.window.close() }
        c.model.menuOpen = true
        c.compose("/mo", marked: "d")
        try await c.until { c.model.text == "/mo" }
        try await Task.sleep(for: .milliseconds(200))
        try await c.key("\t", 48)
        try await c.until { c.model.tabs == 1 }
        try await c.until { c.editor?.string == "/model " }
        #expect(c.editor?.selectedRange() == NSRange(location: 7, length: 0))
        #expect(c.model.text == "/model " && c.model.sends.isEmpty)
    }

    /// Japanese and Chinese take Return, Tab and Escape whole while they compose (the candidate,
    /// the next one, the text as typed) and pass nothing on. With the chooser open, none of them
    /// is the chooser's: no item taken or completed, the chooser still open, and the text as the
    /// input method has it (the chooser used to take its item, or close, under the input method).
    @Test func keysTakenWholeAreTheInputMethodsAlone() async throws {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let putBack = Self.inputMethodTakingKeysWhole()
        defer { putBack() }
        for (characters, code) in [("\r", UInt16(36)), ("\t", 48), ("\u{1b}", 53)] {
            let c = try await Composer()
            defer { c.window.close() }
            c.model.menuOpen = true
            c.compose("/", marked: "も")
            try await c.until { c.model.text == "/" }
            try await Task.sleep(for: .milliseconds(200))
            try await c.key(characters, code)
            try await Task.sleep(for: .milliseconds(100))
            #expect(c.model.returns == 0 && c.model.tabs == 0 && c.model.escapes == 0 && c.model.sends.isEmpty, "key \(code)")
            #expect(c.model.text == "/" && c.model.menuOpen, "key \(code)")
            #expect(c.editor?.string == "/も" && c.editor?.hasMarkedText() == true, "key \(code)")
        }
    }

    /// A held Return repeats. Shift-Return held adds a line each time, where the cursor is, and
    /// sends nothing (the repeats reached the field's submit and sent the half-written message);
    /// held while a block composes (Korean), the first press takes the block and the repeats
    /// add lines too. Option-Return held is the field's own line breaks; a bare Return held
    /// sends once.
    @Test func aHeldReturnSendsOnlyOnce() async throws {
        // Only the marked text below is composing.
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let c = try await Composer()
        defer { c.window.close() }
        c.editor?.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await c.until { c.model.text == "hello" }
        try await c.key("\r", 36, .shift, repeats: 3)
        try await c.until { c.model.text == "hello\n\n\n\n" }
        #expect(c.model.sends.isEmpty)
        c.editor?.setSelectedRange(NSRange(location: 2, length: 0))
        try await c.key("\r", 36, .shift, repeats: 1)
        try await c.until { c.model.text == "he\n\nllo\n\n\n\n" }
        try await c.key("\r", 36, .option, repeats: 1)
        try await c.until { c.model.text == "he\n\n\n\nllo\n\n\n\n" }
        #expect(c.model.sends.isEmpty)

        try await Task.sleep(for: .milliseconds(100))
        c.model.text = "안"
        try await c.until { c.editor?.string == "안" }
        c.editor?.setSelectedRange(NSRange(location: 1, length: 0))
        c.compose("", marked: "녕")
        try await c.key("\r", 36, .shift, repeats: 2)
        try await c.until { c.model.text == "안녕\n\n\n" }
        #expect(c.model.sends.isEmpty)

        try await c.key("\r", 36, repeats: 3)
        try await c.until { !c.model.sends.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        #expect(c.model.sends == ["안녕\n\n\n"])
    }

    /// An input method that takes Return, Tab and Escape whole while it composes, as Japanese and
    /// Chinese do: the key goes no further and the text stays as it is. In NSTextInputContext
    /// (this Mac's keyboard is a layout) until the closure returned puts it back.
    private static func inputMethodTakingKeysWhole() -> () -> Void {
        typealias HandleEvent = @convention(c) (NSTextInputContext, Selector, NSEvent) -> Bool
        let selector = #selector(NSTextInputContext.handleEvent(_:))
        guard let method = class_getInstanceMethod(NSTextInputContext.self, selector) else { return {} }
        let original = method_getImplementation(method)
        let handle = unsafeBitCast(original, to: HandleEvent.self)
        let whole: @convention(block) (NSTextInputContext, NSEvent) -> Bool = { context, event in
            MainActor.assumeIsolated {
                if event.type == .keyDown, [36, 48, 53].contains(event.keyCode), (context.client as? NSTextView)?.hasMarkedText() == true { return true }
                return handle(context, selector, event)
            }
        }
        let imp = imp_implementationWithBlock(whole)
        method_setImplementation(method, imp)
        return {
            method_setImplementation(method, original)
            imp_removeBlock(imp)
        }
    }

    /// Japanese and Chinese take a Return whole and pass nothing on: the key coming up ends the
    /// wait, so the next Return is a Return again. A Return while nothing is composing forgets
    /// one left over too.
    @Test func aReturnTakenWholeLeavesNothingBehind() async throws {
        let restore = keyboard(inputMethod: true)
        defer { restore() }
        let keys = ComposedKeys()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Field(model: Model(), keys: keys))
        window.contentView = host
        let field = try #require(try await Self.fields(in: host).first)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(!keys.isComposing && !keys.returnDown([]))

        editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(keys.isComposing)
        #expect(keys.returnDown([.shift]))
        #expect(keys.composedReturn?.shift == true && keys.composedReturn?.tail == 0)
        editor.unmarkText()
        keys.returnUp()
        #expect(keys.takeReturn() == nil)

        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(keys.returnDown([]))
        editor.unmarkText()
        #expect(!keys.returnDown([]))
        #expect(keys.composedReturn == nil)
    }

    /// With marked text under a keyboard layout (a grey prediction), the arrows stay the
    /// composer's; with an input method's, they are its own.
    @Test func theArrowsStepAsideOnlyForAnInputMethod() async throws {
        let c = try await Composer()
        defer { c.window.close() }
        c.compose("see you tomor", marked: "row")
        var restore = keyboard(inputMethod: false)
        try await c.key(String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), 126, [.numericPad, .function])
        restore()
        #expect(c.model.arrows == [-1])
        c.compose("", marked: "ni")
        restore = keyboard(inputMethod: true)
        try await c.key(String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), 125, [.numericPad, .function])
        restore()
        #expect(c.model.arrows == [-1])
    }

    // MARK: The composer in a window

    /// What the composer was asked to do, and its text.
    @MainActor private final class Model: ObservableObject {
        @Published var text = ""
        @Published var menuOpen = false
        /// The chooser has an item for what is typed.
        var matches = true
        var sends: [String] = []
        var returns = 0, tabs = 0, escapes = 0
        var arrows: [Int] = []

        /// The chooser's item, as the chat's chooser takes it.
        func take(tab: Bool) -> Bool {
            guard menuOpen, matches else { return false }
            if tab { tabs += 1 } else { returns += 1 }
            text = "/model "
            menuOpen = false
            return true
        }

        /// Escape closes the chooser.
        func close() -> Bool {
            guard menuOpen else { return false }
            escapes += 1
            menuOpen = false
            return true
        }
    }

    /// A field with the composer's view of its window behind it.
    private struct Field: View {
        @ObservedObject var model: Model
        let keys: ComposedKeys
        var body: some View { TextField("Message", text: $model.text).background(ComposedKeys.Anchor(keys: keys)) }
    }

    /// The composer as a chat has it, with another field after it for Tab to move to (unless it
    /// is `alone`).
    private struct Host: View {
        @ObservedObject var model: Model
        var alone = false
        var body: some View {
            VStack {
                ComposerTextView(text: $model.text, placeholder: "Message", focused: .constant(false),
                                 onSend: { model.sends.append(model.text) },
                                 onArrow: { model.arrows.append($0); return true },
                                 onReturn: { model.take(tab: false) },
                                 menuOpen: model.menuOpen,
                                 onTab: { model.take(tab: true) },
                                 onEscape: { model.close() })
                if !alone { TextField("Other", text: .constant("")) }
            }
            .frame(width: 400)
            .padding()
        }
    }

    /// The composer in a window of its own, being typed in. The window is never key (the keys
    /// are sent to it), and is on screen but off every display: SwiftUI holds back a change of
    /// the field's height (and the text that brings it) until a window is shown.
    @MainActor private final class Composer {
        let model = Model()
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 440, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        let field: NSTextField

        init(alone: Bool = false) async throws {
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: Host(model: model, alone: alone))
            window.contentView = host
            window.orderFront(nil)
            // The composer is the top field.
            let fields = try await ComposerCompositionTests.fields(in: host, count: alone ? 1 : 2)
            field = try #require(fields.max { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY })
            #expect(window.makeFirstResponder(field))
            #expect(editor != nil)
        }

        /// The composer's field editor, while it is typed in.
        var editor: NSTextView? {
            guard let e = window.firstResponder as? NSTextView, e.delegate as? NSView === field else { return nil }
            return e
        }

        /// Text typed, then a block still composing.
        func compose(_ typed: String, marked: String) {
            guard let e = editor else { return }
            if !typed.isEmpty { e.insertText(typed, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            e.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        /// A key pressed and let go, as the window has it from the keyboard; held, it `repeats`
        /// (a beat apart, as the keyboard's repeat waits before it starts).
        func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], repeats: Int = 0) async throws {
            func send(_ type: NSEvent.EventType, repeat: Bool = false) throws {
                window.sendEvent(try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                                               charactersIgnoringModifiers: characters, isARepeat: `repeat`, keyCode: code)))
            }
            try send(.keyDown)
            for _ in 0..<repeats {
                try await Task.sleep(for: .milliseconds(100))
                try send(.keyDown, repeat: true)
            }
            try send(.keyUp)
            try await Task.sleep(for: .milliseconds(100))
        }

        /// Waits for SwiftUI to catch up, up to a few seconds.
        func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
            #expect(condition(), sourceLocation: sourceLocation)
        }
    }

    /// The editable text fields in a hosting view, once SwiftUI has laid them out.
    static func fields(in host: NSView, count: Int = 1) async throws -> [NSTextField] {
        var found: [NSTextField] = []
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            found = editable(in: host)
            if found.count >= count { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return found
    }

    private static func editable(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { v -> [NSTextField] in
            if let f = v as? NSTextField, f.isEditable { return [f] }
            return editable(in: v)
        }
    }
}
#endif
