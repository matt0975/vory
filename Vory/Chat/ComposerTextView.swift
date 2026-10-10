import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
import Carbon.HIToolbox
#endif
import UniformTypeIdentifiers

/// What a Return in the composer does on the phone and the iPad, one rule for the on-screen
/// keyboard and a hardware one: Shift-Return adds a line, ⌘-Return sends, a bare Return takes
/// the open picker's item, else a hardware Return sends and the on-screen Return adds a line,
/// unless Settings says the Return key sends (as it did before 1.4).
enum ComposerReturnRule {
    enum Action: Equatable { case send, newline, pick }
    static func action(hardware: Bool, shift: Bool, command: Bool, pickerOpen: Bool, returnSends: Bool) -> Action {
        if shift { return .newline }
        if command { return .send }
        if pickerOpen { return .pick }
        if hardware { return .send }
        return returnSends ? .send : .newline
    }
}

/// An input method (Japanese, Chinese, Korean and others) is composing: the text it has not
/// handed over yet (kana before conversion, a pinyin syllable, a Korean block being built) is
/// marked in the field. Its keys are its own until then: Return takes the candidate, the arrows
/// move through the list, Backspace, Tab and Escape edit or drop it. The composer's and the
/// New Message sheet's own key handling steps aside (Return used to send the half-converted
/// text, and the arrows stepped through history under it).
@MainActor
enum InputComposition {
    /// The focused field (the key window's first responder) is composing.
    static var isActive: Bool { isComposing(focusedResponder) }

    /// Marked text is not always an input method's: a grey inline prediction is shown as marked
    /// text too, and so is a dead key's accent. Neither takes the keys, so marked text counts
    /// only while the keyboard is an input method's: on the Mac, an input source that is not a
    /// plain keyboard layout; on iOS, any keyboard but an English one, dictation or emoji (none
    /// has an input method). Settable for the tests, which cannot change the keyboard.
    static var inputMethod: (Responder) -> Bool = { isInputMethod($0) }

    #if os(macOS)
    typealias Responder = NSResponder

    static func isComposing(_ responder: NSResponder?) -> Bool {
        guard let responder, (responder as? NSTextInputClient)?.hasMarkedText() == true else { return false }
        return inputMethod(responder)
    }

    /// The kind of input source from Text Input Sources: a keyboard layout, or an input method
    /// (with modes or without).
    static func isInputMethod(sourceType: String) -> Bool { sourceType != kTISTypeKeyboardLayout as String }

    /// The Mac has one input source for the app, whichever field is typed in. One Text Input
    /// Sources cannot tell is not an input method's: the keys stay the composer's, as they are
    /// for a dead key's accent or a prediction.
    private static func isInputMethod(_ responder: NSResponder) -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        return isInputMethod(sourceType: Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String)
    }

    /// A SwiftUI field being edited: the window's field editor.
    private static var focusedResponder: NSResponder? { NSApp.keyWindow?.firstResponder }
    #else
    typealias Responder = UIResponder

    static func isComposing(_ responder: UIResponder?) -> Bool {
        guard let responder, (responder as? UITextInput)?.markedTextRange != nil else { return false }
        return inputMethod(responder)
    }

    /// A keyboard in this language (its input mode's primary language) may have an input
    /// method unless it is English; one whose language is not known may too. Dictation and the
    /// emoji keyboard are input modes of their own ("dictation", "emoji"), with no candidates
    /// to take the keys: while one is up, Return, the arrows and Escape are the composer's.
    static func isInputMethod(language: String?) -> Bool {
        guard let language else { return true }
        if language == "dictation" || language == "emoji" { return false }
        return Locale.Language(identifier: language).languageCode != .english
    }

    private static func isInputMethod(_ responder: UIResponder) -> Bool {
        isInputMethod(language: responder.textInputMode?.primaryLanguage)
    }

    /// UIKit has no public first responder: an action sent to no one reaches it first.
    private static var focusedResponder: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.reportFirstResponder), to: nil, from: nil, for: nil)
        return found
    }
    private static weak var found: UIResponder?
    fileprivate static func report(_ responder: UIResponder) { found = responder }
    #endif
}

#if !os(macOS)
extension UIResponder {
    @objc(vory_reportFirstResponder) fileprivate func reportFirstResponder() { InputComposition.report(self) }
}
#endif

#if os(macOS)
/// The Mac composer: SwiftUI's own field, growing to `maxLines`. Return sends, Option-Return
/// adds a line; Up and Down go to `onArrow` first (history recall, or the chooser's mark); an
/// image, movie or document pasted with ⌘V goes out through `onPasteData` to become a staged
/// attachment.
struct ComposerTextView: View {
    @Binding var text: String
    var placeholder: String
    @Binding var focused: Bool
    var maxLines = 6
    var accessibilityID: String? = nil
    var onSend: () -> Void = {}
    var onPasteData: @MainActor @Sendable (Data, String, UTType) -> Void = { _, _, _ in }
    var onArrow: (Int) -> Bool = { _ in false }
    /// A bare Return with a chooser open: its item instead of a send (or the composer's own send
    /// of a typed model name). True when used.
    var onReturn: () -> Bool = { false }
    /// Taken so the call site is one; the Mac's Return always sends (Shift-Return adds a line).
    var returnSends = false
    /// A chooser is open above the field: Tab completes its marked item (never runs it) and
    /// Escape closes it.
    var menuOpen = false
    var onTab: () -> Bool = { false }
    var onEscape: () -> Bool = { false }
    @FocusState private var isFocused: Bool
    /// The keys an input method has while it composes (see ComposedKeys).
    @State private var composed = ComposedKeys()

    static let acceptedTypes: [UTType] = [.image, .movie, .pdf, .audio, .plainText, .text, .fileURL, .data]
    private static let attachmentTypes: [UTType] = [.image, .movie, .pdf, .audio]

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...maxLines)
            .focused($isFocused)
            .background(ComposedKeys.Anchor(keys: composed))
            .onSubmit {
                if let key = composed.takeReturn() { handOn(key); return }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSend() }
            }
            // Every key below is the input method's while it is composing (see InputComposition
            // and ComposedKeys).
            .onKeyPress(.upArrow) { !composed.isComposing && onArrow(-1) ? .handled : .ignored }
            .onKeyPress(.downArrow) { !composed.isComposing && onArrow(1) ? .handled : .ignored }
            // Shift-Return is a line break where the cursor is, as on a hardware keyboard on iOS
            // (Option-Return too, by default). A bare Return with a chooser open takes its item: it
            // used to send the half-typed command under it. A held Return repeats: Shift adds a
            // line each time, Option's line break is the field's own, as on the first press, and
            // any other does nothing more (the repeats reached the field's submit and sent the
            // half-written message, again and again). The line break goes in through the field's
            // editor: `text` here is as of SwiftUI's last update, which repeats can outrun.
            // Keypad Enter (fn-Return) is a Return here too, as on iOS: it went past this handler
            // to the field's submit, past the chooser and the held-key guard. Caps Lock and the
            // keypad count as modifiers to SwiftUI, so they are left out before a key is judged bare.
            .onKeyPress(keys: [.return, ComposedKeys.keypadEnter], phases: [.down, .repeat, .up]) { press in
                guard press.phase != .up else { composed.returnUp(); return .ignored }
                let modifiers = ComposedKeys.plain(press.modifiers)
                if composed.returnDown(modifiers) { return .ignored }
                if modifiers.contains(.shift) {
                    if !composed.insertLineBreak() { text += "\n" }
                    return .handled
                }
                if press.phase == .repeat { return modifiers.contains(.option) ? .ignored : .handled }
                if modifiers.isEmpty, onReturn() { return .handled }
                return .ignored
            }
            // Tab and Escape are the chooser's only while it is open; Tab moves the focus otherwise.
            .onKeyPress(.tab, phases: .down) { press in
                guard menuOpen, ComposedKeys.plain(press.modifiers).isEmpty else { return .ignored }
                if composed.tabDown({ onTab() ? text : nil }) { return .ignored }
                return onTab() ? .handled : .ignored
            }
            .onKeyPress(.escape, phases: .down) { _ in menuOpen && !composed.isComposing && onEscape() ? .handled : .ignored }
            // ⌘V with a picture, a PDF, a movie or a sound on the pasteboard stages it. The field's
            // editor takes `paste:` itself and, with nothing it can insert, does nothing, so the
            // paste command below never reached this view for anything but text (#284 on the Mac:
            // a copied picture pasted into the composer went nowhere).
            .onKeyPress(KeyEquivalent("v"), phases: .down) { press in
                guard ComposedKeys.plain(press.modifiers) == .command, !composed.isComposing else { return .ignored }
                return pasteAttachments(from: NSPasteboard.general) ? .handled : .ignored
            }
            .onPasteCommand(of: Self.attachmentTypes) { providers in paste(providers) }
            .accessibilityIdentifier(accessibilityID ?? "composer.field")
            .onAppear { isFocused = focused }
            .onChange(of: focused) { _, f in if isFocused != f { isFocused = f } }
            .onChange(of: isFocused) { _, f in if focused != f { focused = f } }
    }

    /// A Return the input method passed on once its text was in (Korean does): what a Return
    /// does when nothing is composing. It reached the field as a Return, so the field ended its
    /// editing and took it up again with all of it selected, as after a send: the line break or
    /// the chooser's item waits for that, and goes into the field itself.
    private func handOn(_ key: ComposedKeys.Return) {
        DispatchQueue.main.async {
            if key.shift {
                if !composed.insertLineBreak(key) { text += "\n" }
                return
            }
            if key.bare, onReturn() { composed.show(text); return }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSend() }
        }
    }

    /// What is on the pasteboard, as an attachment when it is one: a picture, a PDF, a movie or a
    /// sound (a picture that also comes as text, as a copied web image does, is the picture).
    /// Plain text is left to the field. True when something was staged.
    private func pasteAttachments(from pasteboard: NSPasteboard) -> Bool {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return false }
        var providers: [NSItemProvider] = []
        for item in items {
            let types = item.types.compactMap { UTType($0.rawValue) }
            guard let type = Self.attachmentTypes.first(where: { t in types.contains { $0.conforms(to: t) } }),
                  let concrete = types.first(where: { $0.conforms(to: type) }),
                  let data = item.data(forType: NSPasteboard.PasteboardType(concrete.identifier)) else { continue }
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: concrete.identifier, visibility: .all) { completion in
                completion(data, nil); return nil
            }
            providers.append(provider)
        }
        guard !providers.isEmpty else { return false }
        paste(providers)
        return true
    }

    /// Same rules as the iOS paste delegate: text pastes as text; anything else is an attachment
    /// named for its kind, with the type's extension.
    private func paste(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) || p.hasItemConformingToTypeIdentifier(UTType.text.identifier),
               !p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                    guard let data, let s = String(data: data, encoding: .utf8) else { return }
                    Task { @MainActor in text += s }
                }
                continue
            }
            guard let type = Self.attachmentTypes.first(where: { p.hasItemConformingToTypeIdentifier($0.identifier) }) else { continue }
            let concrete = p.registeredTypeIdentifiers.compactMap { UTType($0) }.first { $0.conforms(to: type) } ?? type
            let ext = concrete.preferredFilenameExtension ?? type.preferredFilenameExtension ?? "bin"
            let stem = type == .image ? "photo" : type == .movie ? "video" : type == .pdf ? "document" : "audio"
            let name = "\(stem)-\(Int(Date().timeIntervalSince1970)).\(ext)"
            let handler = onPasteData
            p.loadDataRepresentation(forTypeIdentifier: concrete.identifier) { data, _ in
                guard let data, !data.isEmpty else { return }
                Task { @MainActor in handler(data, name, concrete) }
            }
        }
    }
}

/// The Mac composer's keys while an input method composes. SwiftUI runs the composer's key
/// handlers before the input method sees the key, so they step aside and the key goes to it.
/// Japanese and Chinese take a Return or a Tab whole, and that is all. Korean takes its block and
/// passes the key on to the field, where it does what it does when nothing is composing, as on
/// iOS: Shift-Return adds a line, Return takes the chooser's item or sends, Tab completes the
/// item. Without this, a Return passed on reached the field's own submit and sent.
@MainActor
final class ComposedKeys {
    /// The keypad's Enter key as SwiftUI reports it (fn-Return on a MacBook).
    static let keypadEnter = KeyEquivalent("\u{3}")

    /// The modifiers that mean something here: Caps Lock being on and a key being on the keypad
    /// both count as modifiers to SwiftUI, and neither is a chord.
    nonisolated static func plain(_ modifiers: SwiftUI.EventModifiers) -> SwiftUI.EventModifiers {
        modifiers.subtracting([.capsLock, .numericPad])
    }

    /// A Return pressed while composing, until the key comes up. `tail` is the length of the
    /// text after the composed text: the line break goes in before it.
    struct Return {
        var shift: Bool
        var bare: Bool
        var tail: Int
    }

    private(set) var composedReturn: Return?
    private weak var anchor: NSView?
    /// The composer's field, as its editor last had it while composing.
    private weak var field: NSView?

    /// The window's field editor, while a field in it is typed in.
    private var editor: NSTextView? {
        guard let e = anchor?.window?.firstResponder as? NSTextView, e.isFieldEditor else { return nil }
        return e
    }

    /// The editor while it is the composer field's.
    private var fieldEditor: NSTextView? {
        guard let e = editor, let field, e.delegate as? NSView === field else { return nil }
        return e
    }

    var isComposing: Bool { InputComposition.isComposing(editor) }

    /// A Return going down: kept for the field while composing (true), forgotten otherwise.
    func returnDown(_ modifiers: SwiftUI.EventModifiers) -> Bool {
        guard isComposing, let e = editor else { composedReturn = nil; return false }
        field = e.delegate as? NSView
        composedReturn = Return(shift: modifiers.contains(.shift), bare: modifiers.isEmpty,
                                tail: (e.string as NSString).length - NSMaxRange(e.markedRange()))
        return true
    }

    /// The Return coming up: one the input method took whole leaves nothing behind.
    func returnUp() { composedReturn = nil }

    /// The field had the Return (its submit): the input method passed it on.
    func takeReturn() -> Return? {
        defer { composedReturn = nil }
        return composedReturn
    }

    /// A Shift-Return's line break where the cursor is, put in through the window's field
    /// editor (the composer's, while its keys come in) as Option-Return puts one. False when no
    /// field is typed in.
    func insertLineBreak() -> Bool {
        guard let e = editor else { return false }
        e.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    /// A Shift-Return's line break, where the Return was pressed, put in through the field's
    /// editor as Option-Return puts one. False when the field is not being typed in.
    func insertLineBreak(_ key: Return) -> Bool {
        guard let e = fieldEditor else { return false }
        place(key.tail)
        e.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    /// Text set just as the field takes up its editing again can miss the field: it is put in
    /// the editor, with the cursor at the end (the field takes it up with all of it selected).
    func show(_ text: String) {
        guard let e = fieldEditor else { return }
        if e.string != text { e.string = text }
        e.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    /// The cursor in the field's editor, `tail` from the end of its text.
    private func place(_ tail: Int) {
        guard let e = fieldEditor else { return }
        e.setSelectedRange(NSRange(location: max(0, (e.string as NSString).length - tail), length: 0))
    }

    /// A Tab pressed while composing ended the field's editing: the input method passed it on.
    private var tabPassedOn = false
    private var tabEnd: (any NSObjectProtocol)?

    /// A Tab going down with the chooser open: true while composing, and the key goes to the
    /// input method. One that takes its text and passes the key on has the field end its
    /// editing with a Tab, and the focus move on (or the field take up its editing again, when
    /// it is the only one). Then the field is typed in again, `complete` runs (the text it
    /// leaves, nil when it took no item) and the cursor goes after the item, or back where it
    /// was: not all of the text selected, as the field takes it up. One that takes the Tab
    /// whole leaves the field to it. Whether the focus left is not the sign: with the composer
    /// alone in its window, it never does.
    func tabDown(_ complete: @escaping @MainActor () -> String?) -> Bool {
        guard isComposing, let window = anchor?.window, let e = editor, let field = e.delegate as? NSView else { return false }
        self.field = field
        let tail = (e.string as NSString).length - NSMaxRange(e.markedRange())
        tabPassedOn = false
        if let tabEnd { NotificationCenter.default.removeObserver(tabEnd) }
        tabEnd = NotificationCenter.default.addObserver(forName: NSControl.textDidEndEditingNotification, object: field, queue: nil) { [weak self] note in
            let movement = note.userInfo?["NSTextMovement"] as? Int
            MainActor.assumeIsolated { if movement == NSTextMovement.tab.rawValue { self?.tabPassedOn = true } }
        }
        // The input method has had the key by the next turn of the run loop.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            if let tabEnd = self.tabEnd { NotificationCenter.default.removeObserver(tabEnd) }
            self.tabEnd = nil
            guard self.tabPassedOn, let window else { return }
            self.tabPassedOn = false
            guard self.fieldEditor != nil || window.makeFirstResponder(field) else { return }
            if let text = complete() { self.show(text) } else { self.place(tail) }
        }
        return true
    }

    /// A view behind the field, for its window.
    struct Anchor: NSViewRepresentable {
        let keys: ComposedKeys
        func makeNSView(context: Context) -> NSView {
            let view = AnchorView()
            keys.anchor = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) { keys.anchor = view }
    }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#else
/// The composer's text field as a UIKit text view. SwiftUI's TextField lost Paste on the phone
/// and could not take an image from the pasteboard, so the keyboard never offered its
/// "Paste from Screenshots". This one declares a paste configuration for text, images, video
/// and documents: text goes into the field, anything else goes out through `onPasteData` to
/// become a staged attachment. It grows from one line to `maxLines`, then scrolls; Return sends.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var focused: Bool
    var maxLines = 6
    var accessibilityID: String? = nil
    /// Return (and the Send key) with something in the field.
    var onSend: () -> Void = {}
    /// A pasted image, movie or document, with a file name that carries its type's extension.
    var onPasteData: @MainActor @Sendable (Data, String, UTType) -> Void = { _, _, _ in }
    /// Hardware Up (-1) / Down (1): history recall. Return true when handled.
    var onArrow: (Int) -> Bool = { _ in false }
    /// A bare Return with a picker open (slash commands, mentions): the item (or the composer's
    /// own send of a typed model name). True when used.
    var onReturn: () -> Bool = { false }
    /// Settings › Appearance › Return key sends: the on-screen Return sends instead of adding a line.
    var returnSends = false
    /// A chooser is open above the field: a hardware Tab completes its marked item (never runs
    /// it) and Escape closes it
    /// (the key commands are only there while it is open, so Tab keeps its own meaning otherwise).
    var menuOpen = false
    var onTab: () -> Bool = { false }
    var onEscape: () -> Bool = { false }

    static let acceptedTypes: [UTType] = [.image, .movie, .pdf, .audio, .plainText, .text, .fileURL, .data]

    func makeUIView(context: Context) -> PasteTextView {
        let v = PasteTextView()
        v.delegate = context.coordinator
        v.pasteDelegate = context.coordinator
        v.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: Self.acceptedTypes.map(\.identifier))
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.isScrollEnabled = false
        v.alwaysBounceVertical = false
        v.showsVerticalScrollIndicator = true
        // Return adds a line (the key says return), unless the setting makes it send.
        v.returnKeyType = returnSends ? .send : .default
        v.enablesReturnKeyAutomatically = returnSends
        v.accessibilityIdentifier = accessibilityID
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.placeholderLabel.text = placeholder
        v.text = text
        v.placeholderLabel.isHidden = !text.isEmpty
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ v: PasteTextView, context: Context) {
        context.coordinator.parent = self
        if v.text != text {
            v.text = text
            v.placeholderLabel.isHidden = !text.isEmpty
        }
        if v.placeholderLabel.text != placeholder { v.placeholderLabel.text = placeholder }
        let key: UIReturnKeyType = returnSends ? .send : .default
        if v.returnKeyType != key {
            v.returnKeyType = key
            v.enablesReturnKeyAutomatically = returnSends
            v.reloadInputViews()
        }
        if focused, !v.isFirstResponder, v.window != nil {
            DispatchQueue.main.async { v.becomeFirstResponder() }
        } else if !focused, v.isFirstResponder {
            DispatchQueue.main.async { v.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: PasteTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? v.bounds.width
        guard width > 0 else { return nil }
        let line = v.font?.lineHeight ?? 22
        let fit = v.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let cap = ceil(line * CGFloat(maxLines))
        let h = min(max(fit.height, line), cap)
        let scrolls = fit.height > cap + 1
        if v.isScrollEnabled != scrolls { v.isScrollEnabled = scrolls }
        return CGSize(width: width, height: ceil(h))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
        var parent: ComposerTextView
        init(parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ v: UITextView) {
            (v as? PasteTextView)?.placeholderLabel.isHidden = !v.text.isEmpty
            if parent.text != v.text { parent.text = v.text }
        }
        func textViewDidBeginEditing(_ v: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ v: UITextView) { if parent.focused { parent.focused = false } }

        func textView(_ v: UITextView, shouldChangeTextIn range: NSRange, replacementText s: String) -> Bool {
            // A hardware Tab the input method took while composing with the chooser open, handed
            // on as a tab once its text is in: the chooser's item, as through the key commands.
            if s == "\t", (v as? PasteTextView)?.takeComposedTab() == true { return !parent.onTab() }
            // A newline from the on-screen keyboard (a hardware keyboard's Return comes through
            // the key commands instead): the picker's item, a send, or the line break itself.
            guard s == "\n" else { return true }
            // A hardware Return the input method took while composing, handed on as a line break
            // once its text is in (Korean does): the hardware rule, as through the key commands.
            if let key = (v as? PasteTextView)?.takeComposedReturn() {
                if key.shift { return true }
                hardwareReturn(v, shift: false, command: key.command)
                return false
            }
            switch ComposerReturnRule.action(hardware: false, shift: false, command: false, pickerOpen: false, returnSends: parent.returnSends) {
            case .pick: return !parent.onReturn()
            case .send:
                if parent.onReturn() { return false }
                if !v.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parent.onSend() }
                return false
            case .newline:
                // A picker open takes the item even when Return would add a line.
                return !parent.onReturn()
            }
        }

        /// A hardware Return: the picker's item, else a send; Shift-Return and ⌘-Return are decided here too.
        func hardwareReturn(_ v: UITextView, shift: Bool, command: Bool) {
            switch ComposerReturnRule.action(hardware: true, shift: shift, command: command, pickerOpen: false, returnSends: parent.returnSends) {
            case .newline: v.insertText("\n")
            case .pick, .send:
                if parent.onReturn() { return }
                if !v.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parent.onSend() }
            }
        }

        // MARK: UITextPasteDelegate — images and documents from the pasteboard become attachments.

        func textPasteConfigurationSupporting(_ supporting: any UITextPasteConfigurationSupporting, transform item: any UITextPasteItem) {
            let p = item.itemProvider
            // Text, in any of its spellings, pastes as text.
            if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) || p.hasItemConformingToTypeIdentifier(UTType.text.identifier), !p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                item.setDefaultResult()
                return
            }
            let type = [UTType.image, .movie, .pdf, .audio].first { p.hasItemConformingToTypeIdentifier($0.identifier) }
                ?? p.registeredTypeIdentifiers.compactMap { UTType($0) }.first { !$0.conforms(to: .text) && $0 != .fileURL }
            guard let type else { item.setDefaultResult(); return }
            let concrete = p.registeredTypeIdentifiers.compactMap { UTType($0) }.first { $0.conforms(to: type) } ?? type
            let handler = parent.onPasteData
            let ext = concrete.preferredFilenameExtension ?? type.preferredFilenameExtension ?? "bin"
            let stem = type == .image ? "photo" : type == .movie ? "video" : type == .pdf ? "document" : type == .audio ? "audio" : "pasted"
            let name = "\(stem)-\(Int(Date().timeIntervalSince1970)).\(ext)"
            p.loadDataRepresentation(forTypeIdentifier: concrete.identifier) { data, _ in
                guard let data, !data.isEmpty else { return }
                Task { @MainActor in handler(data, name, concrete) }
            }
            item.setNoResult()
        }

        func textPasteConfigurationSupporting(_ supporting: any UITextPasteConfigurationSupporting, shouldAnimatePasteOf attributedString: NSAttributedString, to textRange: UITextRange) -> Bool { false }
    }
}

/// UITextView with a placeholder and the hardware-keyboard commands the composer wants.
final class PasteTextView: UITextView {
    let placeholderLabel = UILabel()
    weak var coordinator: ComposerTextView.Coordinator?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 1
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor),
            placeholderLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.font = font
    }

    /// Paste stays available whenever the pasteboard holds anything at all: with only an image
    /// on it the default check sometimes said no, and the menu had no Paste.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            let pb = UIPasteboard.general
            return pb.hasStrings || pb.hasImages || pb.hasURLs || pb.numberOfItems > 0
        }
        // UIKit can hold on to the key commands from before the composing began: one found then
        // is declined, and its key goes on to the input method.
        if isComposing, Self.keyActions.contains(action) { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    /// An input method is composing in the field (see InputComposition): the keys are its own.
    var isComposing: Bool { InputComposition.isComposing(self) }

    private static let keyActions: Set<Selector> = [
        #selector(arrowUp), #selector(arrowDown), #selector(returnPressed), #selector(shiftReturnPressed),
        #selector(commandReturnPressed), #selector(tabPressed), #selector(escapePressed),
    ]

    override var keyCommands: [UIKeyCommand]? {
        // None while an input method is composing: Return takes its candidate, the arrows move
        // through its list, Tab and Escape are its own. They come back once the text is in.
        if isComposing { return [] }
        let up = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(arrowUp))
        let down = UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(arrowDown))
        // A hardware keyboard, as on the Mac: Return sends, Shift-Return adds a line, ⌘-Return sends.
        let send = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnPressed))
        let newline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(shiftReturnPressed))
        let commandSend = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(commandReturnPressed))
        var commands = [up, down, send, newline, commandSend]
        // With the chooser open and a hardware keyboard (an iPad's, say): Tab completes the marked
        // item and Escape closes the list, as in the Mac app.
        if coordinator?.parent.menuOpen == true {
            commands.append(UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tabPressed)))
            commands.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed)))
        }
        for c in commands where c.modifierFlags.isEmpty { c.wantsPriorityOverSystemBehavior = true }
        return commands
    }
    // Should one be called while composing all the same, it does nothing: nothing is sent,
    // stepped through or picked from under the input method.
    @objc private func arrowUp() { guard !isComposing else { return }; if coordinator?.parent.onArrow(-1) != true { moveCursor(up: true) } }
    @objc private func arrowDown() { guard !isComposing else { return }; if coordinator?.parent.onArrow(1) != true { moveCursor(up: false) } }
    @objc private func returnPressed() { guard !isComposing else { return }; coordinator?.hardwareReturn(self, shift: false, command: false) }
    @objc private func shiftReturnPressed() { guard !isComposing else { return }; coordinator?.hardwareReturn(self, shift: true, command: false) }
    @objc private func commandReturnPressed() { guard !isComposing else { return }; coordinator?.hardwareReturn(self, shift: false, command: true) }
    @objc private func tabPressed() { guard !isComposing else { return }; if coordinator?.parent.onTab() != true { insertText("\t") } }
    @objc private func escapePressed() { guard !isComposing else { return }; _ = coordinator?.parent.onEscape() }

    /// A hardware Return pressed while composing, until the key comes up: an input method that
    /// hands it on as a line break after taking its text has that break count as this Return.
    var composedReturn: (shift: Bool, command: Bool)?
    /// A hardware Tab pressed while composing with the chooser open, the same way: a tab handed
    /// on once the text is in completes the chooser's item.
    var composedTab = false

    func takeComposedReturn() -> (shift: Bool, command: Bool)? {
        defer { composedReturn = nil }
        return composedReturn
    }

    func takeComposedTab() -> Bool {
        defer { composedTab = false }
        return composedTab
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Before the input method sees the key: once it has, the text is no longer marked.
        if isComposing {
            let keys = presses.compactMap(\.key)
            if let key = keys.first(where: Self.isReturn) {
                composedReturn = (key.modifierFlags.contains(.shift), key.modifierFlags.contains(.command))
            }
            if coordinator?.parent.menuOpen == true, keys.contains(where: { Self.isTab($0) && $0.modifierFlags.isDisjoint(with: [.shift, .control, .alternate, .command]) }) {
                composedTab = true
            }
        }
        super.pressesBegan(presses, with: event)
    }
    // Japanese and Chinese take the Return whole: nothing is handed on, and the key coming up
    // ends the wait, so a later line break from the on-screen keyboard is its own.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        keysUp(presses)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
        keysUp(presses)
    }
    private func keysUp(_ presses: Set<UIPress>) {
        let keys = presses.compactMap(\.key)
        if keys.contains(where: Self.isReturn) { composedReturn = nil }
        if keys.contains(where: Self.isTab) { composedTab = false }
    }
    private static func isReturn(_ key: UIKey) -> Bool { key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter }
    private static func isTab(_ key: UIKey) -> Bool { key.keyCode == .keyboardTab }

    private func moveCursor(up: Bool) {
        guard let r = selectedTextRange else { return }
        if let p = tokenizer.position(from: up ? r.start : r.end, toBoundary: .line, inDirection: UITextDirection.layout(up ? .up : .down)) {
            selectedTextRange = textRange(from: p, to: p)
        }
    }
}
#endif
