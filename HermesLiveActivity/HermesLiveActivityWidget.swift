import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HermesLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        HermesTurnLiveActivity()
        StatusWidget()
        AttentionWidget()
        ActivityWidget()
        ContextWidget()
        OverviewWidget()
        BlocksWidget()
    }
}

extension HermesTurnAttributes {
    /// A tap anywhere on the activity opens this chat, on its bot.
    var chatURL: URL? {
        var c = URLComponents(); c.scheme = "vory"; c.host = "chat"; c.path = "/" + storedSessionID
        if !profile.isEmpty { c.queryItems = [URLQueryItem(name: "profile", value: profile)] }
        return c.url
    }
}

/// Lock Screen banner + Dynamic Island for a running agent turn.
struct HermesTurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesTurnAttributes.self) { context in
            LockScreenTurnView(attributes: context.attributes, state: context.state)
                .widgetURL(context.attributes.chatURL)
                // Translucent over the wallpaper rather than a flat black slab; the system
                // still guarantees legibility with its own material underneath.
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            // No centre region: the leading and trailing regions sit beside the sensor cut-out and
            // a third column there only leaves the title a few letters. Everything wide goes below.
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        BotMark(attributes: context.attributes, state: context.state, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(context.attributes.displayBotName).font(.headline).lineLimit(1).minimumScaleFactor(0.6)
                            Text(PhaseText.headline(for: context.state)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.needsAttention, context.state.attentionKind != "input" {
                        ApprovalButtons(attributes: context.attributes)
                            .padding(.trailing, 2)
                    } else if context.state.needsAttention {
                        Image(systemName: "keyboard").font(.title3).foregroundStyle(.yellow).padding(.trailing, 6)
                    } else if context.state.voiceMode != nil {
                        VoiceEndButton(attributes: context.attributes).padding(.trailing, 2)
                    } else {
                        ElapsedTimer(state: context.state)
                            .font(.headline.monospacedDigit())
                            .multilineTextAlignment(.trailing).frame(width: 52)
                            .minimumScaleFactor(0.7)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if context.state.needsAttention {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                                Text(context.state.attentionKind == "input" ? "Needs Your Input" : "Needs Approval").font(.title3.weight(.bold))
                            }
                            Text(context.state.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        } else if let goal = context.state.shownGoal {
                            // What the bot is after leads; the step it is on right now sits under it.
                            Text(goal).font(.subheadline.weight(.medium)).lineLimit(2)
                            Text(context.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            StatsRow(attributes: context.attributes, state: context.state)
                        } else {
                            Text(context.attributes.sessionTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(context.state.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            StatsRow(attributes: context.attributes, state: context.state)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .widgetURL(context.attributes.chatURL)
                }
            } compactLeading: {
                // The island on iPhone 18 Pro is smaller and holds three activities at once, so
                // the compact view is the bot alone with its phase in a corner badge: one glyph
                // per side, nothing that needs width.
                IslandBot(attributes: context.attributes, state: context.state, size: 24)
                    .padding(.leading, 2)
                    .widgetURL(context.attributes.chatURL)
            } compactTrailing: {
                if context.state.needsAttention {
                    Image(systemName: "exclamationmark").font(.caption.weight(.bold)).foregroundStyle(.yellow)
                } else if context.state.voiceMode != nil {
                    Image(systemName: "waveform").font(.caption.weight(.bold)).foregroundStyle(.pink)
                        .symbolEffect(.variableColor.iterative, isActive: context.state.phase == "voice")
                        .padding(.trailing, 2)
                } else {
                    // Ticks while the turn runs; once it ends this is the total time it took.
                    ElapsedTimer(state: context.state).font(.caption2.weight(.medium).monospacedDigit()).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing).frame(width: 32).minimumScaleFactor(0.6)
                        .padding(.trailing, 2)
                }
            } minimal: {
                // Minimal is what each activity gets when several share the island: the bot's
                // face, ringed yellow when it needs you, so three bots read as three bots.
                IslandBot(attributes: context.attributes, state: context.state, size: 22)
                    .widgetURL(context.attributes.chatURL)
            }
            .keylineTint(context.state.needsAttention ? .yellow : PhaseStyle.tint(context.state.phase, bot: context.attributes.tintHex))
        }
    }
}

// MARK: Pieces

extension HermesTurnAttributes {
    /// Bot display name; older activities (or a profile without one) fall back to the profile name.
    var displayBotName: String {
        if let n = botName, !n.isEmpty { return n }
        return profile.isEmpty ? "Hermes" : profile
    }
}

enum PhaseStyle {
    /// The bot's own colour while it works; phase colours take over for done / error / waiting.
    static func tint(_ phase: String, bot hex: String = "") -> Color {
        if !hex.isEmpty, phase == "streaming" || phase == "tool" || phase == "thinking", let c = Color(hexString: hex) { return c }
        switch phase {
        case "tool": return .blue
        case "thinking": return .indigo
        case "done": return .green
        case "error": return .red
        case "waiting": return .yellow
        case "voice": return .pink
        default: return .purple
        }
    }

    static func symbol(_ phase: String, attention: Bool) -> String {
        if attention { return "exclamationmark.triangle.fill" }
        switch phase {
        case "tool": return "wrench.and.screwdriver.fill"
        case "thinking": return "brain.fill"
        case "done": return "checkmark"
        case "error": return "xmark"
        case "voice": return "waveform"
        default: return "ellipsis.message.fill"
        }
    }
}

/// Voice mode's End, from the Lock Screen or the Island: opens the app and ends the conversation.
struct VoiceEndButton: View {
    var attributes: HermesTurnAttributes
    private var url: URL {
        var c = URLComponents(); c.scheme = "vory"; c.host = "voice"
        c.queryItems = [URLQueryItem(name: "session", value: attributes.storedSessionID), URLQueryItem(name: "action", value: "end")]
        return c.url!
    }
    var body: some View {
        Link(destination: url) {
            Label("End", systemImage: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6).frame(minWidth: 68)
                .background(Color.red.opacity(0.85), in: .capsule)
        }
    }
}

extension Color {
    init?(hexString: String) {
        var s = hexString; if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

enum PhaseText {
    static func headline(for s: HermesTurnAttributes.ContentState) -> String {
        if s.needsAttention { return s.attentionKind == "input" ? "Input needed" : "Approval needed" }
        if let v = s.voiceMode { return s.phase == "voice" ? v : "Voice mode" }
        switch s.phase {
        case "tool": return "Running a tool"
        case "thinking": return "Thinking"
        case "done": return "Finished"
        case "error": return "Failed"
        default: return "Writing"
        }
    }
}

enum Format {
    static func tokens(_ n: Int) -> String {
        // 128000 → "128k", 12345 → "12.3k", 1500000 → "1.5M"
        func short(_ v: Double, _ unit: String) -> String {
            let s = v >= 100 || v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
            return s + unit
        }
        return n >= 1_000_000 ? short(Double(n) / 1e6, "M") : n >= 1000 ? short(Double(n) / 1000, "k") : "\(n)"
    }
}

/// Elapsed time that ticks while the turn runs and freezes when it ends.
struct ElapsedTimer: View {
    var state: HermesTurnAttributes.ContentState
    var body: some View {
        if let end = state.endedAt {
            Text(Duration.seconds(max(0, end.timeIntervalSince(state.startedAt))).formatted(.time(pattern: .minuteSecond)))
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
        }
    }
}

/// A small disc painted like the bot's glass: the tint with a lit top and a soft rim, the
/// symbol in white on it. Widgets cannot run Liquid Glass, so this is the painted version the
/// bot beside it uses too.
struct GlassDisc: View {
    var tint: Color
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            Circle().fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05), .clear], startPoint: .top, endPoint: .center))
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.1), .black.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: max(1, size * 0.06))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: size * 0.06, y: size * 0.03)
    }
}

/// The bot in the island's compact and minimal slots: the face at 20 pt with a tiny phase badge
/// on its corner, and a yellow ring while it waits on you.
struct IslandBot: View {
    var attributes: HermesTurnAttributes
    var state: HermesTurnAttributes.ContentState
    var size: CGFloat

    private var spec: BotLookSpec { BotLookSpec.from(choice: attributes.avatar, hex: attributes.tintHex) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, sz in
                BotFace.draw(spec, in: &ctx, size: sz, time: 0, active: false, breathe: false, idleEyes: false, move: false, motion: BotFace.widgetPose(phase: state.phase, attention: state.needsAttention))
            }
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.yellow, lineWidth: state.needsAttention ? 1.5 : 0).padding(-1.5))
            // The phase dot sits inside the face's own square, small, so it reads as a status
            // light on the bot rather than a second blob beside it.
            if !state.needsAttention {
                Circle().fill(PhaseStyle.tint(state.phase, bot: attributes.tintHex))
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(Circle().strokeBorder(.black.opacity(0.9), lineWidth: 1))
                    .offset(x: -size * 0.02, y: -size * 0.02)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Small glyph for the compact/minimal island.
struct PhaseGlyph: View {
    var phase: String
    var attention: Bool
    var botHex: String = ""
    var body: some View {
        let tint = attention ? Color.yellow : PhaseStyle.tint(phase, bot: botHex)
        ZStack {
            GlassDisc(tint: tint, size: 20)
            Image(systemName: PhaseStyle.symbol(phase, attention: attention))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(attention ? .black.opacity(0.8) : .white)
                .symbolEffect(.pulse, isActive: attention || phase == "streaming" || phase == "tool" || phase == "thinking")
        }
    }
}

/// The bot itself as a still frame (WidgetKit views cannot animate), with a small phase badge on
/// the corner. Photos live in the app's own container, which the widget cannot read, so a photo
/// avatar shows the bot's default look instead.
struct BotMark: View {
    var attributes: HermesTurnAttributes
    var state: HermesTurnAttributes.ContentState
    var size: CGFloat

    private var spec: BotLookSpec { BotLookSpec.from(choice: attributes.avatar, hex: attributes.tintHex) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Drawn straight into a Canvas: a TimelineView in a widget blanked the bot for a
            // frame on every state change.
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, sz in
                // One held pose per phase: the squint, the asking lean, the lowered eyes.
                BotFace.draw(spec, in: &ctx, size: sz, time: 0, active: false, breathe: false, idleEyes: false, move: false, motion: BotFace.widgetPose(phase: state.phase, attention: state.needsAttention))
            }
            .frame(width: size, height: size)
            if size >= 28 {
                PhaseBadge(phase: state.phase, attention: state.needsAttention, size: size * 0.42, botHex: attributes.tintHex)
                    .overlay(Circle().strokeBorder(.black.opacity(0.9), lineWidth: 1.5))
                    .offset(x: size * 0.10, y: size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Tinted disc with the phase glyph, used at larger sizes.
struct PhaseBadge: View {
    var phase: String
    var attention: Bool
    var size: CGFloat
    var botHex: String = ""
    var body: some View {
        let tint = attention ? Color.yellow : PhaseStyle.tint(phase, bot: botHex)
        ZStack {
            GlassDisc(tint: tint, size: size)
            Image(systemName: PhaseStyle.symbol(phase, attention: attention))
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(attention ? .black.opacity(0.8) : .white)
                .symbolEffect(.pulse, isActive: !attention && (phase == "streaming" || phase == "tool" || phase == "thinking"))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Output tokens · context bar · model, one line, each figure labelled so the bar reads as
/// "how full the context window is" rather than a mystery progress bar.
struct StatsRow: View {
    var attributes: HermesTurnAttributes
    var state: HermesTurnAttributes.ContentState
    var body: some View {
        HStack(spacing: 12) {
            // The timer already sits in the corner of every layout, so this row is tokens and
            // context, never the time again.
            HStack(spacing: 4) {
                Image(systemName: "text.word.spacing")
                Text("\(Format.tokens(state.outputTokens)) tokens").monospacedDigit()
            }
            .font(.caption)
            // Percent when that is all we know; "12.3k/128k" once the companion or the app has the
            // real window figures.
            let pct = state.contextPercent ?? state.contextUsed.flatMap { u in state.contextMax.map { m in m > 0 ? Int(Double(u) * 100 / Double(m)) : 0 } }
            if let pct {
                HStack(spacing: 5) {
                    Text("Context").font(.caption)
                    ProgressView(value: Double(min(max(pct, 0), 100)), total: 100)
                        .progressViewStyle(.linear)
                        .tint(pct >= 85 ? .red : pct >= 60 ? .orange : PhaseStyle.tint(state.phase, bot: attributes.tintHex))
                        .frame(width: 48)
                    if let used = state.contextUsed, let max = state.contextMax, max > 0 {
                        Text("\(Format.tokens(used))/\(Format.tokens(max))").font(.caption.monospacedDigit())
                    } else {
                        Text("\(pct)%").font(.caption.monospacedDigit())
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Context \(pct) percent full")
            }
            Spacer(minLength: 0)
            if !attributes.model.isEmpty {
                Text(attributes.model).font(.caption2).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
}

struct LockScreenTurnView: View {
    var attributes: HermesTurnAttributes
    var state: HermesTurnAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                BotMark(attributes: attributes, state: state, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attributes.displayBotName).font(.headline).lineLimit(1).minimumScaleFactor(0.6)
                    if state.needsAttention {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            Text(state.attentionKind == "input" ? "Needs Your Input" : "Needs Approval").font(.title3.weight(.bold))
                        }
                    } else if state.shownGoal == nil {
                        Text(attributes.sessionTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let goal = state.shownGoal {
                        // The same three lines as before: the goal takes two, the step one.
                        Text(goal).font(.subheadline).lineLimit(2)
                        Text(state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(state.detail).font(.subheadline).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                if state.needsAttention {
                    if state.attentionKind != "input" { ApprovalButtons(attributes: attributes) }
                } else if state.voiceMode != nil {
                    VStack(alignment: .trailing, spacing: 6) {
                        VoiceEndButton(attributes: attributes)
                        Text(PhaseText.headline(for: state)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    // A fixed width: the ticking timer text otherwise claims the whole row and
                    // squeezes the title down to a few letters.
                    VStack(alignment: .trailing, spacing: 2) {
                        ElapsedTimer(state: state).font(.title3.monospacedDigit().weight(.medium)).multilineTextAlignment(.trailing).minimumScaleFactor(0.7)
                        Text(PhaseText.headline(for: state)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: 66, alignment: .trailing)
                }
            }
            if !state.needsAttention { StatsRow(attributes: attributes, state: state) }
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}

/// Approve / Deny, stacked: each opens the app on that chat's card and applies the choice.
struct ApprovalButtons: View {
    var attributes: HermesTurnAttributes
    private func url(_ choice: String) -> URL {
        var c = URLComponents(); c.scheme = "vory"; c.host = "approval"
        c.queryItems = [URLQueryItem(name: "session", value: attributes.storedSessionID), URLQueryItem(name: "choice", value: choice)]
        return c.url!
    }
    var body: some View {
        VStack(spacing: 6) {
            Link(destination: url("once")) {
                Text("Approve").font(.caption.weight(.semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 12).padding(.vertical, 6).frame(minWidth: 76)
                    .background(Color.yellow, in: .capsule)
            }
            Link(destination: url("deny")) {
                Text("Deny").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6).frame(minWidth: 76)
                    .background(Color.white.opacity(0.18), in: .capsule)
            }
        }
    }
}
