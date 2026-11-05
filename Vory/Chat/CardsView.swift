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
    /// Voice mode's choices (#631, round 3f): their arrangement, which each name follows (one line, shrunk no further than
    /// its bound, or wrapping on words). nil everywhere else, the chat's card included.
    @Entry var voiceChoiceArrangement: VoiceSplit.ChoiceArrangement? = nil
}

private extension View {
    /// An identifier for voice mode's checks (#631), set in voice mode only (round 3e): in a chat the element carries no
    /// identifier modifier at all, so the chat card's accessibility tree is as it was before #631.
    @ViewBuilder func voiceIdentifier(_ id: String, when on: Bool) -> some View {
        if on { accessibilityIdentifier(id) } else { self }
    }
}

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

/// A waiting approval's parts as the card measures them in voice mode's one column (#631), for the screen to size it:
/// the card's whole height first, the conversation giving way to it.
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
    @Environment(\.dynamicTypeSize) private var typeSize
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
    /// The widest choice's name on one line at this text size, a prominent capsule round a sample and the sample alone,
    /// measured off screen (round 3f): the arrangement's widths, the capsule's less the sample's being its insets.
    @State private var widestName: CGFloat = 0
    /// The widest name at the one-line check's scale (round 3i, 3j): measured at the body size's
    /// `VoiceSplit.choiceFitScale`, the body size read through `bodySize`.
    @State private var widestAtFit: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 17
    @State private var capsuleW: CGFloat = 0
    @State private var capsuleSampleW: CGFloat = 0
    /// The width the choices are given (round 3f).
    @State private var choicesW: CGFloat = 0

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
                        // The choices are below the fold here: the scroll's bar flashes as the card appears, so the
                        // card reads as a scroll with more below (round 3c).
                        .scrollIndicatorsFlash(onAppear: true)
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
        .voiceIdentifier("approval.card", when: voiceMode)
    }

    /// The one column's parts (#631), each measured where it stands.
    private var askedPart: some View {
        VStack(alignment: .leading, spacing: VoiceSplit.cardGap) { asked }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.asked = $0 }
    }
    private var coversPart: some View {
        covers.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.covers = $0 }
            // One line of it, measured off screen (round 3k), so its scroll shows whole lines only.
            .background(alignment: .topLeading) {
                Text(verbatim: "Ag").font(.caption2).fixedSize().hidden().accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.coversLine = $0 }
            }
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
            Text(d).font(.subheadline).voiceIdentifier("approval.description", when: voiceMode)
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
            Text("Tool: \(t)").font(.caption).foregroundStyle(quiet).voiceIdentifier("approval.tool", when: voiceMode)
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
            .voiceIdentifier("approval.heading", when: voiceMode)
    }

    @ViewBuilder private var waiting: some View {
        if count > 1 { Text("\(count) waiting").font(.caption).foregroundStyle(quiet) }
    }

    /// Four choices do not fit on one line at iPhone width, and a wrapped name looks broken, so fall back to a 2x2 grid
    /// when the row cannot fit. In voice mode (#631) the four stand the same size, in a row, two by two or one to a row.
    @ViewBuilder private var choices: some View {
        if voiceMode {
            // The four the same size (round 3f): one layout of the same four buttons in every arrangement, so a change of
            // text size or pose moves them rather than building others; every cell as wide as the others and as tall as
            // the tallest. The names stand on one line, shrunk to 0.8 at most, where every name fits so (at its own size
            // at the accessibility sizes); else they wrap on words, never inside one, and never shrink
            // (`VoiceSplit.choiceArrangement`).
            ChoiceCells(columns: arrangement.columns, spacing: VoiceSplit.choiceGap) { choiceButtons }
                .environment(\.voiceChoiceArrangement, arrangement)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { choicesW = $0 }
                .background(alignment: .topLeading) { choiceMeasures }
                #if DEBUG
                .modifier(VoiceChoiceProbe.CardRead(line: probeCardLine))
                #endif
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
    /// Voice mode's arrangement of the choices at this width and text size (round 3f).
    private var arrangement: VoiceSplit.ChoiceArrangement {
        VoiceSplit.choiceArrangement(width: choicesW, widestName: widestName, widestAtFit: widestAtFit, longestWord: longestWord,
                                     insets: capsuleW - capsuleSampleW, count: approval.offeredChoices.count,
                                     accessibility: typeSize.isAccessibilitySize)
    }
    /// The arrangement's measures, off screen and out of VoiceOver's reach (round 3f): the longest word and the widest
    /// name at body, the widest name at the one-line check's point size (round 3i, 3j), and a prominent capsule round a
    /// sample beside the sample alone, for the capsule's own insets.
    private var choiceMeasures: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(choiceWords, id: \.self) { Text($0).font(.body).fixedSize() }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { longestWord = $0 }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(approval.offeredChoices, id: \.self) { Text(label($0)).font(.body).fixedSize() }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widestName = $0 }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(approval.offeredChoices, id: \.self) {
                    Text(label($0)).font(.system(size: bodySize * VoiceSplit.choiceFitScale)).fixedSize()
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widestAtFit = $0 }
            Text(verbatim: "W").font(.body).fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { capsuleSampleW = $0 }
            Button {} label: { Text(verbatim: "W").font(.body).fixedSize() }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).fixedSize().disabled(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { capsuleW = $0 }
        }
        .fixedSize()
        .hidden().accessibilityHidden(true)
    }
    #if DEBUG
    /// The arrangement and its measures, for the rig (#631, round 3g; DEBUG `-vory-voice-frames` only).
    private var probeCardLine: String {
        String(format: "columns %d oneline %@ minscale %.2f width %.1f widest %.1f word %.1f insets %.1f fit %.1f", arrangement.columns,
               arrangement.oneLine ? "yes" : "no", arrangement.minScale, choicesW, widestName, longestWord, capsuleW - capsuleSampleW,
               widestAtFit)
    }
    #endif

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
    @Environment(\.voiceChoiceArrangement) private var arrangement

    /// In a chat a name stays on one line and shrinks a little when it must. In voice mode (#631) it grows with the
    /// text size, on one line or wrapping as the four's arrangement says, in colours that pass on the card's dark fill:
    /// Allow once white on a deep blue of its own, Deny a light red, the rest white.
    @ViewBuilder private var label: some View {
        if voiceMode {
            // On one line, shrunk only as far as its cell needs and never under the bound, when every name fits so;
            // else as many lines as it needs, wrapping on words, never shrunk (round 3). Either way it fills its cell,
            // so the four stand the same size (round 3f).
            Text(title).font(.body).multilineTextAlignment(.center)
                .lineLimit(arrangement?.oneLine == true ? 1 : nil)
                .minimumScaleFactor(arrangement?.minScale ?? 1)
                .fixedSize(horizontal: false, vertical: true)
                #if DEBUG
                .modifier(VoiceChoiceProbe.NameRead(title: title))
                #endif
                .foregroundStyle(choice == "deny" ? VoiceLook.deny.color : .white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if DEBUG
                .modifier(VoiceChoiceProbe.RoomRead(title: title))
                #endif
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

/// Voice mode's choices (#631, round 3f): `columns` to a row, every cell as wide as the others (the row less its gaps,
/// shared out evenly) and as tall as the tallest button at that width, so the four stand the same size whichever name
/// wraps. The same buttons in every arrangement.
struct ChoiceCells: Layout {
    var columns: Int
    var spacing: CGFloat

    private func cells(_ width: CGFloat, _ subviews: Subviews) -> (columns: Int, rows: Int, size: CGSize) {
        let columns = max(1, min(self.columns, subviews.count))
        let rows = (subviews.count + columns - 1) / columns
        let w = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let h = subviews.map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.max() ?? 0
        return (columns, rows, CGSize(width: w, height: h))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width: CGFloat
        if let w = proposal.width, w.isFinite {
            width = w
        } else {
            // No width given (an ideal size): each cell as wide as the widest button's own width.
            let columns = max(1, min(self.columns, subviews.count))
            let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            width = CGFloat(columns) * widest + CGFloat(columns - 1) * spacing
        }
        let c = cells(width, subviews)
        return CGSize(width: width, height: CGFloat(c.rows) * c.size.height + CGFloat(c.rows - 1) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let c = cells(bounds.width, subviews)
        for (i, subview) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(i % c.columns) * (c.size.width + spacing)
            let y = bounds.minY + CGFloat(i / c.columns) * (c.size.height + spacing)
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(c.size))
        }
    }
}

#if DEBUG
/// DEBUG `-vory-voice-frames` (#631, round 3g): voice mode's choices tell the rig what each name drew, by geometry reads
/// only: the card's arrangement and its measures, and each name's own size as laid out beside its one-line natural size
/// (a hidden copy, there only while the flag is on) and the room its cell gave it. The rig works out from them how many
/// lines a name took and whether one was cut. Round 3h: each name is read straight from layout, by a GeometryReader in a
/// background that emits the preference itself, with no state between (round 3g's onGeometryChange and @State kept the
/// first pass's numbers, or none once the card went all-scroll). Nothing here changes a frame, and none of it is in
/// Release.
enum VoiceChoiceProbe {
    static let on = ProcessInfo.processInfo.arguments.contains("-vory-voice-frames")
    struct Name: Equatable {
        var title: String
        var text: CGSize = .zero
        var natural: CGSize = .zero
        /// The width the name was given: its label's, after the frame that fills the cell.
        var room: CGFloat = 0
        var line: String {
            String(format: "%@ text %.1f %.1f natural %.1f %.1f room %.1f", title, text.width, text.height, natural.width, natural.height, room)
        }
    }
    struct Report: Equatable {
        var card = ""
        var names: [Name] = []
        var line: String { card.isEmpty && names.isEmpty ? "none" : ([card] + names.map(\.line)).joined(separator: "|") }
        /// A name's reading put with the others of the same title: each read part (text, natural, room) taken as read.
        mutating func merge(_ n: Name) {
            guard let i = names.firstIndex(where: { $0.title == n.title }) else { names.append(n); return }
            if n.text != .zero { names[i].text = n.text }
            if n.natural != .zero { names[i].natural = n.natural }
            if n.room != 0 { names[i].room = n.room }
        }
    }
    struct Key: PreferenceKey {
        static let defaultValue = Report()
        static func reduce(value: inout Report, nextValue: () -> Report) {
            let next = nextValue()
            if !next.card.isEmpty { value.card = next.card }
            for n in next.names { value.merge(n) }
        }
    }
    /// A name's own size as laid out, and its one-line natural size from a hidden copy, each read by a GeometryReader in
    /// a background and reported up from the layout itself.
    struct NameRead: ViewModifier {
        var title: String
        @ViewBuilder func body(content: Content) -> some View {
            if on {
                content
                    .background {
                        GeometryReader { text in
                            Color.clear.preference(key: Key.self, value: Report(names: [Name(title: title, text: text.size)]))
                        }
                    }
                    .background {
                        Text(title).font(.body).fixedSize().hidden().accessibilityHidden(true)
                            .background {
                                GeometryReader { natural in
                                    Color.clear.preference(key: Key.self, value: Report(names: [Name(title: title, natural: natural.size)]))
                                }
                            }
                    }
            } else {
                content
            }
        }
    }
    /// The room the name was given, read after the frame that fills its cell by a GeometryReader in a background.
    struct RoomRead: ViewModifier {
        var title: String
        @ViewBuilder func body(content: Content) -> some View {
            if on {
                content.background {
                    GeometryReader { room in
                        Color.clear.preference(key: Key.self, value: Report(names: [Name(title: title, room: room.size.width)]))
                    }
                }
            } else {
                content
            }
        }
    }
    /// The card's line, put with its names'.
    struct CardRead: ViewModifier {
        var line: String
        @ViewBuilder func body(content: Content) -> some View {
            if on { content.transformPreference(Key.self) { $0.card = line } } else { content }
        }
    }
}
#endif

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
