import SwiftUI
import VoryCore

/// The glass card that replaces the composer while the gateway waits on the user.
struct PendingCardView: View {
    @Bindable var chat: ChatSession
    var card: PendingCard
    /// In voice mode the card has a dark fill under its words, over its glass (#631): its words then read the same
    /// whatever stands behind it. Off everywhere else.
    @Environment(\.cardInVoiceMode) private var voiceMode

    var body: some View {
        Group {
            if let a = card.approval {
                ApprovalCardView(approval: a, count: chat.cards.count,
                                 botName: chat.runtime.profiles.first { $0.name == chat.profileName }?.label ?? chat.profileName) { choice in
                    Task { await chat.respond(card: card, result: ["choice": .string(choice)]) }
                }
            }
            else if let c = card.clarify { ClarifyCardView(request: c) { result in Task { await chat.respond(card: card, result: result) } } }
            else if let v = card.valuePrompt { ValuePromptCardView(method: card.method, request: v) { value in Task { await chat.respond(card: card, result: ["value": .string(value)]) } } }
            else { Text("Unsupported request \(card.method)").font(.footnote) }
        }
        .padding(14)
        .background(voiceMode ? Color.black.opacity(VoiceLook.cardFillOpacity) : Color.clear, in: .rect(cornerRadius: 20))
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

extension EnvironmentValues {
    /// Voice mode pins an approval's choices under its words (`ApprovalCardView`): in its split (Duo stage 4) and, from
    /// #631, in one column too, where the card is held to the room the screen leaves it.
    @Entry var approvalChoicesPinned = false
    /// The card stands in voice mode (#631): its fill, its colours, wrapped choice names and a wrapped command, so it
    /// passes the audit over any bot colour and at any text size. False everywhere else, so the chat's card is unchanged.
    @Entry var cardInVoiceMode = false
}

struct ApprovalCardView: View {
    var approval: ApprovalRequest
    var count: Int
    /// The bot's display name, for the scope line ("for ops").
    var botName: String = ""
    var onChoice: (String) -> Void
    @State private var confirmAlways = false

    /// Voice mode's split (Duo stage 4): the choices stand under the words, which scroll from their start when the card is
    /// taller than its room, so what's allowed is read first and the choices are at hand at rest.
    @Environment(\.approvalChoicesPinned) private var choicesPinned
    @Environment(\.cardInVoiceMode) private var voiceMode

    /// The card's quieter lines: `.secondary` in a chat, white at 0.8 on voice mode's dark fill (#631).
    private var quiet: AnyShapeStyle { voiceMode ? AnyShapeStyle(VoiceLook.cardSecondary) : AnyShapeStyle(.secondary) }
    private var warning: Color { voiceMode ? VoiceLook.orange.color : .orange }

    var body: some View {
        Group {
            if choicesPinned {
                ViewThatFits(in: .vertical) {
                    VStack(alignment: .leading, spacing: 10) { details; choices }
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView { VStack(alignment: .leading, spacing: 10) { details }.frame(maxWidth: .infinity, alignment: .leading) }
                            .scrollBounceBehavior(.basedOnSize)
                        choices
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) { details; choices }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// What's asked: the heading, the description, the command, the tool, the guardian's flag and what each answer covers.
    /// The items alone, no stack of their own: in a chat the card stays the one flat stack it always was, so the dock's
    /// height squeezes the choices as before (their names scale down) rather than the words.
    @ViewBuilder private var details: some View {
        if voiceMode {
            // The heading wraps rather than cuts, and "N waiting" goes under it when the line is short (#631).
            ViewThatFits(in: .horizontal) {
                HStack { heading; Spacer(); waiting }
                VStack(alignment: .leading, spacing: 2) { heading; waiting }
            }
        } else {
            HStack { heading; Spacer(); waiting }
        }
        if let d = approval.description, !d.isEmpty { Text(d).font(.subheadline) }
        if let cmd = approval.command, !cmd.isEmpty {
            if voiceMode {
                // Wrapped in voice mode, so the whole command is on the card (scrolled sideways, its end was cut off).
                Text(cmd).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(cmd).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(8)
                }
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            }
        }
        if let t = approval.toolName { Text("Tool: \(t)").font(.caption).foregroundStyle(quiet) }
        if approval.smartDenied == true { Text("The smart-approval guardian flagged this command.").font(.caption).foregroundStyle(warning) }
        // What each answer covers, so "Always" is never a surprise: it is a rule on this
        // bot's gateway profile, not the one command, and it lives on until revoked.
        Text(scopeLine).font(.caption2).foregroundStyle(quiet).fixedSize(horizontal: false, vertical: voiceMode)
    }

    private var heading: some View {
        Label("Approval needed", systemImage: "exclamationmark.shield.fill").font(.headline).foregroundStyle(warning)
            .fixedSize(horizontal: false, vertical: voiceMode)
    }

    @ViewBuilder private var waiting: some View {
        if count > 1 { Text("\(count) waiting").font(.caption).foregroundStyle(quiet) }
    }

    /// Four choices do not fit on one line at iPhone width, and a wrapped name looks broken, so fall back to a 2x2 grid
    /// when the row cannot fit. In voice mode a name may take two lines rather than shrink (#631), and when even the grid
    /// is too wide the choices stand one to a row.
    @ViewBuilder private var choices: some View {
        if voiceMode {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { choiceButtons }
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { choiceButtons(Array(approval.offeredChoices.prefix(2))) }
                    GridRow { choiceButtons(Array(approval.offeredChoices.dropFirst(2))) }
                }
                VStack(spacing: 8) { choiceButtons }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { choiceButtons }
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { choiceButtons(Array(approval.offeredChoices.prefix(2))) }
                    GridRow { choiceButtons(Array(approval.offeredChoices.dropFirst(2))) }
                }
            }
        }
    }

    @ViewBuilder private var choiceButtons: some View {
        choiceButtons(approval.offeredChoices)
    }

    @ViewBuilder private func choiceButtons(_ choices: [String]) -> some View {
        ForEach(choices, id: \.self) { choice in
            ApprovalChoiceButton(choice: choice, title: label(choice)) {
                if choice == "always" { confirmAlways = true } else { onChoice(choice) }
            }
        }
        .alert("Always allow \(approval.alwaysScope)?", isPresented: $confirmAlways) {
            Button("Always allow") { onChoice("always") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This adds a rule to \(botName.isEmpty ? "this bot" : botName)'s gateway profile: every chat with \(botName.isEmpty ? "it" : botName) runs \(approval.alwaysScope) without asking, until you remove the rule in Settings › Approvals › Always allowed.")
        }
    }

    private var scopeLine: String {
        let who = botName.isEmpty ? "this bot" : botName
        var parts = ["Allow once: this command only."]
        if approval.offeredChoices.contains("session") { parts.append("Allow for this chat: \(approval.alwaysScope) in this chat.") }
        if approval.offeredChoices.contains("always") { parts.append("Always allow: \(approval.alwaysScope) for \(who), every chat, until revoked in Settings › Approvals.") }
        return parts.joined(separator: " ")
    }

    /// One set of names everywhere: "session" was a word for strangers to puzzle over, and in Vory a
    /// session is a chat. "Always allow…" asks first (the alert above).
    private func label(_ c: String) -> String {
        switch c { case "once": return "Allow once"; case "session": return "Allow for this chat"; case "always": return "Always allow…"; case "deny": return "Deny"; default: return c.capitalized }
    }
}

struct ApprovalChoiceButton: View {
    var choice: String
    var title: String
    var action: () -> Void
    @Environment(\.cardInVoiceMode) private var voiceMode

    /// In a chat a name stays on one line and shrinks a little when it must. In voice mode (#631) it grows with the
    /// text size and takes a second line instead, in colours that pass on the card's dark fill: Allow once white on a
    /// deep blue of its own, Deny a light red, the rest white.
    @ViewBuilder private var label: some View {
        if voiceMode {
            Text(title).lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(choice == "deny" ? VoiceLook.deny.color : .white)
                .frame(maxWidth: .infinity)
        } else {
            Text(title).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
        }
    }

    var body: some View {
        if choice == "once" {
            Button(action: action) { label }.buttonStyle(.glassProminent)
                .tint(voiceMode ? VoiceLook.allowOnceFill.color : nil)
        } else if choice == "deny" {
            Button(role: .destructive, action: action) { label }.buttonStyle(.glass)
        } else {
            Button(action: action) { label }.buttonStyle(.glass)
        }
    }
}

struct ClarifyCardView: View {
    var request: ClarifyRequest
    var onAnswer: (JSONValue) -> Void
    @State private var text = ""
    @State private var picked: Set<String> = []
    @State private var batch: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hermes asks", systemImage: "questionmark.bubble.fill").font(.headline).foregroundStyle(.tint)
            if let questions = request.questions, !questions.isEmpty {
                ForEach(questions) { q in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(q.question).font(.subheadline)
                        if let choices = q.choices, !choices.isEmpty {
                            Picker(q.question, selection: Binding(get: { batch[q.qid] ?? "" }, set: { batch[q.qid] = $0 })) {
                                Text("Choose…").tag("")
                                ForEach(choices, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                        } else {
                            TextField("Answer", text: Binding(get: { batch[q.qid] ?? "" }, set: { batch[q.qid] = $0 }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                HStack {
                    Button("Skip", role: .cancel) { onAnswer(["answers": .object([:])]) }.buttonStyle(.glass)
                    Button("Answer") { onAnswer(["answers": .object(batch.mapValues { .string($0) })]) }.buttonStyle(.glassProminent)
                }
            } else {
                Text(request.question ?? "").font(.subheadline)
                if let choices = request.choices, !choices.isEmpty {
                    ForEach(choices, id: \.self) { c in
                        Button {
                            if request.multiSelect == true { if picked.contains(c) { picked.remove(c) } else { picked.insert(c) } }
                            else { onAnswer(["answer": .string(c)]) }
                        } label: {
                            HStack {
                                if request.multiSelect == true { Image(systemName: picked.contains(c) ? "checkmark.circle.fill" : "circle") }
                                Text(c).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(.glass)
                    }
                    if request.multiSelect == true {
                        Button("Answer") { onAnswer(["answer": .string(picked.sorted().joined(separator: ", "))]) }.buttonStyle(.glassProminent)
                    }
                } else {
                    HStack {
                        TextField("Your answer", text: $text, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder)
                        Button { onAnswer(["answer": .string(text)]) } label: { Image(systemName: "arrow.up") }.buttonStyle(.glassProminent)
                    }
                }
                Button("Skip") { onAnswer(["answer": ""]) }.font(.caption)
            }
        }
    }
}

struct ValuePromptCardView: View {
    var method: String
    var request: ValuePromptRequest
    var onValue: (String) -> Void
    @State private var value = ""
    @State private var identifier = ""
    @FocusState private var focused: Bool

    /// The keyboard goes first: the card leaves the dock the moment it answers, and a focused
    /// secure field being torn out mid-morph is a crash candidate on a sudo prompt.
    private func submit(_ v: String) {
        focused = false
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(50)); onValue(v) }
    }

    private var title: String {
        switch method {
        case "sudo": return "sudo password"
        case "secret": return "Secret: \(request.envVar ?? "")"
        case "vault.unlock_prompt": return "Unlock \(request.displayName ?? request.backend ?? "vault")"
        case "vault.save_login": return "Save login for \(request.site ?? request.origin ?? "site")"
        case "vault.code": return "One-time code\(request.site.map { " for \($0)" } ?? "")"
        default: return method
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "key.fill").font(.headline)
            if let p = request.prompt, !p.isEmpty { Text(p).font(.subheadline) }
            if let c = request.command, !c.isEmpty { Text(c).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary) }
            if let h = request.hint, !h.isEmpty { Text(h).font(.caption).foregroundStyle(.secondary) }
            if method == "vault.save_login" {
                TextField("Username / identifier", text: $identifier).textFieldStyle(.roundedBorder).textContentType(.username)
            }
            SecureField(method == "vault.code" ? "Code" : "Value", text: $value).textFieldStyle(.roundedBorder)
                .textContentType(method == "vault.code" ? .oneTimeCode : (method == "sudo" ? nil : .password))
                .focused($focused)
                .onSubmit { if !value.isEmpty { submit(value) } }
            HStack {
                Button("Skip", role: .cancel) { submit("") }.buttonStyle(.glass)
                Button("Submit") {
                    if method == "vault.save_login" {
                        let json = RPCFrames.encode(["identifier": .string(identifier), "password": .string(value)])
                        submit(json)
                    } else { submit(value) }
                }
                .buttonStyle(.glassProminent).disabled(value.isEmpty)
            }
            Text("Sent directly to your gateway; never logged by the app.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
