import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import UniformTypeIdentifiers

#if os(macOS)
/// The Mac composer: SwiftUI's own field, growing to `maxLines`. Return sends, Option-Return
/// adds a line; Up and Down go to `onArrow` first (history recall); an image, movie or document
/// pasted with ⌘V goes out through `onPasteData` to become a staged attachment.
struct ComposerTextView: View {
    @Binding var text: String
    var placeholder: String
    @Binding var focused: Bool
    var maxLines = 6
    var accessibilityID: String? = nil
    var onSend: () -> Void = {}
    var onPasteData: @MainActor @Sendable (Data, String, UTType) -> Void = { _, _, _ in }
    var onArrow: (Int) -> Bool = { _ in false }
    @FocusState private var isFocused: Bool

    static let acceptedTypes: [UTType] = [.image, .movie, .pdf, .audio, .plainText, .text, .fileURL, .data]
    private static let attachmentTypes: [UTType] = [.image, .movie, .pdf, .audio]

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...maxLines)
            .focused($isFocused)
            .onSubmit { if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSend() } }
            .onKeyPress(.upArrow) { onArrow(-1) ? .handled : .ignored }
            .onKeyPress(.downArrow) { onArrow(1) ? .handled : .ignored }
            // Shift-Return is a line break, as on a hardware keyboard on iOS (Option-Return too, by default).
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.shift) else { return .ignored }
                text += "\n"
                return .handled
            }
            .onPasteCommand(of: Self.attachmentTypes) { providers in paste(providers) }
            .accessibilityIdentifier(accessibilityID ?? "composer.field")
            .onAppear { isFocused = focused }
            .onChange(of: focused) { _, f in if isFocused != f { isFocused = f } }
            .onChange(of: isFocused) { _, f in if focused != f { focused = f } }
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
        v.returnKeyType = .send
        v.enablesReturnKeyAutomatically = true
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
            // The Send key: a bare newline from the keyboard sends; Shift-Return on a hardware
            // keyboard comes through the key command instead and inserts a line break.
            if s == "\n" {
                if !v.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parent.onSend() }
                return false
            }
            return true
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
        return super.canPerformAction(action, withSender: sender)
    }

    override var keyCommands: [UIKeyCommand]? {
        let up = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(arrowUp))
        let down = UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(arrowDown))
        let newline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(insertLineBreak))
        for c in [up, down] { c.wantsPriorityOverSystemBehavior = true }
        return [up, down, newline]
    }
    @objc private func arrowUp() { if coordinator?.parent.onArrow(-1) != true { moveCursor(up: true) } }
    @objc private func arrowDown() { if coordinator?.parent.onArrow(1) != true { moveCursor(up: false) } }
    @objc private func insertLineBreak() { insertText("\n") }

    private func moveCursor(up: Bool) {
        guard let r = selectedTextRange else { return }
        if let p = tokenizer.position(from: up ? r.start : r.end, toBoundary: .line, inDirection: UITextDirection.layout(up ? .up : .down)) {
            selectedTextRange = textRange(from: p, to: p)
        }
    }
}
#endif
