import SwiftUI
import VoryCore

/// The glass card that replaces the composer while the gateway waits on the user.
struct PendingCardView: View {
    @Bindable var chat: ChatSession
    var card: PendingCard

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
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct ApprovalCardView: View {
    var approval: ApprovalRequest
    var count: Int
    /// The bot's display name, for the scope line ("for defender").
    var botName: String = ""
    var onChoice: (String) -> Void
    @State private var confirmAlways = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Approval needed", systemImage: "exclamationmark.shield.fill").font(.headline).foregroundStyle(.orange)
                Spacer()
                if count > 1 { Text("\(count) waiting").font(.caption).foregroundStyle(.secondary) }
            }
            if let d = approval.description, !d.isEmpty { Text(d).font(.subheadline) }
            if let cmd = approval.command, !cmd.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(cmd).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(8)
                }
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            }
            if let t = approval.toolName { Text("Tool: \(t)").font(.caption).foregroundStyle(.secondary) }
            if approval.smartDenied == true { Text("The smart-approval guardian flagged this command.").font(.caption).foregroundStyle(.orange) }
            // What each answer covers, so "Always" is never a surprise: it is a rule on this
            // bot's gateway profile, not the one command, and it lives on until revoked.
            Text(scopeLine).font(.caption2).foregroundStyle(.secondary)
            // Four choices do not fit on one line at iPhone width, and a wrapped "Ses-sion" looks
            // broken, so fall back to a 2x2 grid when the row cannot fit.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { choiceButtons }
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { choiceButtons(Array(approval.offeredChoices.prefix(2))) }
                    GridRow { choiceButtons(Array(approval.offeredChoices.dropFirst(2))) }
                }
            }
        }
        .accessibilityElement(children: .contain)
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
        var parts = ["Once: this command only."]
        if approval.offeredChoices.contains("session") { parts.append("Session: \(approval.alwaysScope) in this chat.") }
        if approval.offeredChoices.contains("always") { parts.append("Always: \(approval.alwaysScope) for \(who), every chat, until revoked in Settings › Approvals.") }
        return parts.joined(separator: " ")
    }

    private func label(_ c: String) -> String {
        switch c { case "once": return "Once"; case "session": return "Session"; case "always": return "Always"; case "deny": return "Deny"; default: return c.capitalized }
    }
}

struct ApprovalChoiceButton: View {
    var choice: String
    var title: String
    var action: () -> Void

    private var label: some View {
        Text(title).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
    }

    var body: some View {
        if choice == "once" {
            Button(action: action) { label }.buttonStyle(.glassProminent)
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
