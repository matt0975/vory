import SwiftUI
import VoryCore

/// Renames a chat: a small sheet whose name field has the focus and its text selected as it
/// opens, so typing replaces the name; Return saves, Escape cancels. It was an alert with a
/// text field, whose field could not take the focus on the Mac (the dialog opened on Cancel:
/// Return cancelled and typing went nowhere until a click), so it is a sheet of its own on
/// every platform (#308). Opened from the chat's … menu, a long press on the title pill, and
/// the card's Name row.
struct RenameChatSheet: View {
    @Bindable var chat: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename chat").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
                .accessibilityIdentifier("rename.name")
            Text("The new name shows in the chat list and the header.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
        .onAppear {
            name = chat.title
            focused = true
        }
        #if os(iOS)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.hidden)
        // The whole name is selected as the field takes the focus, so typing replaces it (the
        // Mac's field selects all on its own when the focus reaches it by keyboard).
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { n in
            (n.object as? UITextField)?.selectAll(nil)
        }
        #endif
    }

    private func save() {
        let n = trimmed
        guard !n.isEmpty else { return }
        Task { await chat.rename(n) }
        dismiss()
    }
}
