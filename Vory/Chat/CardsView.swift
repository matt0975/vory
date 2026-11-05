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
    /// Voice mode's one column (#631): the approval's choices and what it asks never scroll, and the card tells the screen
    /// its parts' heights (`ApprovalCardHeightsKey`). False everywhere else, the split's card too.
    @Entry var approvalInColumn = false
    /// The one column's last resort: what's asked scrolls too, when even it and the choices don't fit.
    @Entry var approvalWordsScroll = false
    /// The one column's very last resort (round 3): the choices scroll too, with what's asked, when even they don't fit.
    @Entry var approvalAllScroll = false
}

/// A waiting approval's parts as the card measures them in voice mode's one column (#631), for the screen to size it:
/// the card's whole height first, the conversation giving way to it.
/// A scroll in voice mode's card that holds more than it shows (#631, round 3): its foot fades out over 12 pt, so its edge
/// reads as a scroll rather than a line cut through its letters.
private struct FootFade: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on {
            content.mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 12)
                }
            }
        } else {
            content
        }
    }
}

struct ApprovalCardHeightsKey: PreferenceKey {
    static let defaultValue = VoiceSplit.CardHeights()
    static func reduce(value: inout VoiceSplit.CardHeights, nextValue: () -> VoiceSplit.CardHeights) {
        let next = nextValue()
        if next != defaultValue { value = next }
    }
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
    /// Voice mode's one column (#631): what's asked (the heading, the description, the command, the tool, the guardian's
    /// flag) and the choices never scroll, so the closed Duo shows them whatever the conversation and the bot take; what
    /// each answer covers scrolls under them when the card is short. Each part's height goes up to voice mode
    /// (`ApprovalCardHeightsKey`), which gives the card its whole height before the conversation gets any.
    @Environment(\.approvalInColumn) private var inColumn
    /// The one column's last resort, when even what's asked and the choices don't fit (the largest text sizes on a short
    /// screen): the words scroll from their start over the choices, as below a fold.
    @Environment(\.approvalWordsScroll) private var wordsScroll
    /// The one column's very last resort (round 3): even the choices don't fit what's left, so everything scrolls from the
    /// heading and nothing runs past the screen.
    @Environment(\.approvalAllScroll) private var allScroll
    @State private var heights = VoiceSplit.CardHeights()
    /// What each answer covers as it shows (round 3): when its scroll cuts it, its foot fades.
    @State private var coversShown: CGFloat = 0
    /// The longest word of the four choices' names at this text size, measured off screen (round 3): what a cell of the
    /// two-by-two grid must hold without breaking a word.
    @State private var longestWord: CGFloat = 0

    /// The card's quieter lines: `.secondary` in a chat, white at 0.8 on voice mode's dark fill (#631).
    private var quiet: AnyShapeStyle { voiceMode ? AnyShapeStyle(VoiceLook.cardSecondary) : AnyShapeStyle(.secondary) }
    private var warning: Color { voiceMode ? VoiceLook.orange.color : .orange }

    var body: some View {
        Group {
            if choicesPinned, inColumn {
                VStack(alignment: .leading, spacing: VoiceSplit.cardGap) {
                    if allScroll {
                        // Everything scrolls from the heading (round 3's last resort), in the order VoiceOver reads it:
                        // what's asked, what each answer covers, the choices.
                        ScrollView {
                            VStack(alignment: .leading, spacing: VoiceSplit.cardGap) { askedPart; coversPart; choicesPart }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .modifier(FootFade(on: true))
                    } else {
                        if wordsScroll {
                            ScrollView {
                                VStack(alignment: .leading, spacing: VoiceSplit.cardGap) { askedPart; coversPart }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            // Its words are taller than its room here: the fade marks the scroll's edge (round 3).
                            .modifier(FootFade(on: true))
                        } else {
                            askedPart.fixedSize(horizontal: false, vertical: true)
                            ScrollView { coversPart.frame(maxWidth: .infinity, alignment: .leading) }
                                .scrollBounceBehavior(.basedOnSize)
                                .frame(maxHeight: heights.covers)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { coversShown = $0 }
                                // Cut by its scroll, its foot fades rather than showing a sliver of a line (round 3).
                                .modifier(FootFade(on: coversShown + 0.5 < heights.covers))
                        }
                        choicesPart.fixedSize(horizontal: false, vertical: true)
                    }
                }
                .preference(key: ApprovalCardHeightsKey.self, value: heights)
            } else if choicesPinned {
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
        .accessibilityIdentifier(voiceMode ? "approval.card" : "")
    }

    /// The one column's parts (#631), each measured where it stands.
    private var askedPart: some View {
        VStack(alignment: .leading, spacing: VoiceSplit.cardGap) { asked }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.asked = $0 }
    }
    private var coversPart: some View {
        covers.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.covers = $0 }
    }
    private var choicesPart: some View {
        choices.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.choices = $0 }
    }

    /// The heading, the description, the command, the tool, the guardian's flag, and what each answer covers.
    /// The items alone, no stack of their own: in a chat the card stays the one flat stack it always was, so the dock's
    /// height squeezes the choices as before (their names scale down) rather than the words.
    @ViewBuilder private var details: some View {
        asked
        covers
    }

    /// What's asked: everything on the card but what each answer covers. In voice mode each part has an identifier, so the
    /// rig can see the closed Duo shows them whole (#631).
    @ViewBuilder private var asked: some View {
        if voiceMode {
            // The heading wraps rather than cuts, and "N waiting" goes under it when the line is short (#631).
            ViewThatFits(in: .horizontal) {
                HStack { heading; Spacer(); waiting }
                VStack(alignment: .leading, spacing: 2) { heading; waiting }
            }
        } else {
            HStack { heading; Spacer(); waiting }
        }
        if let d = approval.description, !d.isEmpty {
            Text(d).font(.subheadline).accessibilityIdentifier(voiceMode ? "approval.description" : "")
        }
        if let cmd = approval.command, !cmd.isEmpty {
            if voiceMode {
                // Wrapped in voice mode, so the whole command is on the card (scrolled sideways, its end was cut off).
                Text(cmd).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .accessibilityIdentifier("approval.command")
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
        if let t = approval.toolName {
            Text("Tool: \(t)").font(.caption).foregroundStyle(quiet).accessibilityIdentifier(voiceMode ? "approval.tool" : "")
        }
        if approval.smartDenied == true { Text("The smart-approval guardian flagged this command.").font(.caption).foregroundStyle(warning) }
    }

    /// What each answer covers, so "Always" is never a surprise: it is a rule on this
    /// bot's gateway profile, not the one command, and it lives on until revoked.
    private var covers: some View {
        Text(scopeLine).font(.caption2).foregroundStyle(quiet).fixedSize(horizontal: false, vertical: voiceMode)
    }

    private var heading: some View {
        Label("Approval needed", systemImage: "exclamationmark.shield.fill").font(.headline).foregroundStyle(warning)
            .fixedSize(horizontal: false, vertical: voiceMode)
            .accessibilityIdentifier(voiceMode ? "approval.heading" : "")
    }

    @ViewBuilder private var waiting: some View {
        if count > 1 { Text("\(count) waiting").font(.caption).foregroundStyle(quiet) }
    }

    /// Four choices do not fit on one line at iPhone width, and a wrapped name looks broken, so fall back to a 2x2 grid
    /// when the row cannot fit. In voice mode a name may take two lines rather than shrink (#631), and when even the grid
    /// is too wide the choices stand one to a row.
    @ViewBuilder private var choices: some View {
        if voiceMode {
            // In voice mode a choice's name wraps, never shrinks or cuts (round 3): one row when the four fit at their
            // names' own widths; else two by two, each cell half the card's width and as tall as its wrapped name; one
            // column of four only when a cell couldn't hold the longest word of a name (the grid's ideal width is two of
            // those words with a button's insets, so the grid is picked whenever its cells can hold them).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { choiceButtons }
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { choiceButtons(Array(approval.offeredChoices.prefix(2))) }
                    GridRow { choiceButtons(Array(approval.offeredChoices.dropFirst(2))) }
                }
                .frame(minWidth: 0, idealWidth: 2 * (longestWord + Self.choiceInsets) + 8, maxWidth: .infinity)
                VStack(spacing: 8) { choiceButtons }
            }
            .background(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(choiceWords, id: \.self) { Text($0).font(.body).fixedSize() }
                }
                .hidden().accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { longestWord = $0 }
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

    /// Each word of the offered choices' names, once each (round 3): the longest is what a grid cell must hold.
    private var choiceWords: [String] {
        var seen = Set<String>()
        return approval.offeredChoices.flatMap { label($0).split(separator: " ").map(String.init) }.filter { seen.insert($0).inserted }
    }
    /// A prominent capsule button's insets either side of its name, with room to spare (round 3).
    private static let choiceInsets: CGFloat = 40

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
            // As many lines as its name needs at the text size, never shrunk or cut (round 3).
            Text(title).font(.body).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(choice == "deny" ? VoiceLook.deny.color : .white)
                .frame(maxWidth: .infinity)
        } else {
            Text(title).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
        }
    }

    var body: some View {
        if voiceMode {
            // In voice mode a solid fill of its own under each name (round 3), stock: a prominent bordered capsule in our
            // colour, which, unlike glass, doesn't take on what stands behind the card. Allow once on its deep blue, first
            // and prominent; the rest on a dark grey (VoiceLook.choiceFill); each name at 4.5:1 or more on its fill
            // (VoiceLookTests). Deny's destructive role is left off here: with it the stock fill would be red, under its
            // red words.
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(choice == "once" ? VoiceLook.allowOnceFill.color : VoiceLook.choiceFill.color)
        } else if choice == "once" {
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
