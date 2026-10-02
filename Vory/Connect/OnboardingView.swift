import SwiftUI
import VoryCore

/// First launch: Vory itself walks you through what it does. The cloud sits at the top, talks
/// in a speech bubble (typed out), reacts to each page — a turn on arrival, a squint when the
/// page is about waiting — and under it a small live demo of the feature plays by itself. The
/// last page leads to the gateway form. Nothing here touches a server.
struct OnboardingView: View {
    /// Straight to the tour: the debug hook that shows it over a configured app.
    var skipWelcome = false
    @Environment(AppModel.self) private var model
    @State private var page = 0
    @State private var showForm = false
    /// Past the first screen (Get Started, or a restore that brought no gateway).
    @State private var welcomed = false
    @State private var showRestore = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Page {
        let title: String
        let says: String
        let demo: TourDemoKind
    }

    /// The word the pages use for the device they are on.
    #if os(macOS)
    private static let device = "Mac"
    #else
    private static let device = "phone"
    #endif

    private var pages: [Page] {
        var p = Self.basePages
        if ChatSummarizer.isAvailable {
            // Before the last page, the one that connects.
            p.insert(Page(title: "Summaries, on your \(Self.device).", says: "With Apple Intelligence I can give every chat a short title and a two-line summary, right in the list. It all stays on your \(Self.device). Optional — your call.", demo: .summaries), at: p.count - 1)
        }
        return p
    }
    #if os(macOS)
    // No Dynamic Island page: the menu bar takes that job on the Mac and gets its page with it.
    private static let basePages: [Page] = [
        Page(title: "Hi, I'm Vory.", says: "I'm your Hermes gateway, on your Mac. Every bot you run lives here — step through to see what we can do together.", demo: .bots),
        Page(title: "Chats that stream.", says: "Replies arrive word by word, code and tool calls render as they happen, and every chat is a real session on your gateway.", demo: .chat),
        Page(title: "A yes from anywhere.", says: "When a bot needs permission, the card lands right here. Once, for the session, always, or deny — it waits for you.", demo: .approval),
        Page(title: "Make each bot yours.", says: "Give every bot its own body, eyes and colour in the Creator Studio. They blink, glance, and move while they work.", demo: .studio),
        Page(title: "Let's connect.", says: "Point me at your Hermes dashboard — on your network, over Tailscale, or behind Cloudflare. Your credentials stay in the Keychain.", demo: .connect),
    ]
    #else
    private static let basePages: [Page] = [
        Page(title: "Hi, I'm Vory.", says: "I'm your Hermes gateway, on \(DeviceWords.your). Every bot you run lives here — swipe to see what we can do together.", demo: .bots),
        Page(title: "Chats that stream.", says: "Replies arrive word by word, code and tool calls render as they happen, and every chat is a real session on your gateway.", demo: .chat),
        Page(title: "A yes from anywhere.", says: "When a bot needs permission, the card lands on \(DeviceWords.your). Once, for the session, always, or deny — it waits for you.", demo: .approval),
        Page(title: "I keep you posted.", says: "A Live Activity follows every turn in the Dynamic Island, and the reply comes as a notification you can answer right there.", demo: .island),
        Page(title: "Make each bot yours.", says: "Give every bot its own body, eyes and colour in the Creator Studio. They blink, glance, and move while they work.", demo: .studio),
        Page(title: "Let's connect.", says: "Point me at your Hermes dashboard — on your Wi‑Fi, over Tailscale, or behind Cloudflare. Your credentials stay in the Keychain.", demo: .connect),
    ]
    #endif

    private var isLast: Bool { page == pages.count - 1 }

    var body: some View {
        if welcomed || skipWelcome {
            tour.transition(.opacity)
        } else {
            welcome.transition(.opacity)
        }
    }

    /// The first thing a new device shows: Vory, and the two ways in. Someone coming from
    /// another device restores and is done; everyone else gets the tour and the gateway form.
    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            BotFaceView(spec: BotLookSpec.vory, size: 150, active: true, mood: BotFaceView.Mood(profile: "vory-welcome", state: .guide))
            Text("Vory").font(.system(size: 46, weight: .bold, design: .rounded)).padding(.top, 6)
            Text("Your Hermes bots, on \(DeviceWords.your).")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 2)
            Spacer(minLength: 24)
            GlassEffectContainer(spacing: 14) {
                VStack(spacing: 14) {
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy) { welcomed = true }
                    } label: {
                        Text("Get Started").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("onboarding.getStarted")
                    Button { showRestore = true } label: {
                        Label("Restore from iCloud", systemImage: "icloud.and.arrow.down").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("onboarding.restore")
                }
            }
            .frame(maxWidth: 380)
            Text("Already use Vory on another device? Restore brings your gateways, bot looks and settings from your own iCloud.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 14)
        }
        .padding(.horizontal, 28).padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showRestore) {
            CloudRestoreSheet { outcome in
                if outcome.gateways > 0 {
                    // A gateway is saved now: the root view moves on by itself, and this connects it.
                    Task { await model.activateSavedConnection() }
                } else {
                    // Settings came back but no gateway did: on to the form.
                    page = pages.count - 1
                    welcomed = true
                    showForm = true
                }
            }
            .sheetFrame()
        }
    }

    private var tour: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Vory, talking. A full turn on every page; a squint on the page about waiting.
                VoryGuide(says: pages[page].says, key: page, turnKey: page, thinking: pages[page].demo == .approval, reduceMotion: reduceMotion)
                    .padding(.top, 14)

                #if os(macOS)
                // Nothing to swipe on a Mac: the page in front, cross-faded, with the dots under it.
                VStack(spacing: 12) {
                    pageView(pages[page], index: page)
                        .id(page)
                        .transition(.opacity)
                    HStack(spacing: 6) {
                        ForEach(pages.indices, id: \.self) { i in
                            Circle().fill(Color.primary.opacity(i == page ? 0.9 : 0.25)).frame(width: 7, height: 7)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: .infinity)
                .animation(reduceMotion ? nil : .snappy, value: page)
                #else
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                        pageView(p, index: i).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .animation(reduceMotion ? nil : .snappy, value: page)
                #endif

                VStack(spacing: 10) {
                    Button {
                        if isLast { showForm = true } else { page += 1 }
                    } label: {
                        Text(isLast ? "Connect your gateway" : "Continue")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier(isLast ? "onboarding.addGateway" : "onboarding.continue")
                    if !isLast {
                        Button("Skip") { page = pages.count - 1 }
                            .font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("onboarding.skip")
                    } else {
                        Text(" ").font(.subheadline)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .navigationTitle("Vory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showForm) { GatewayFormView() }
        }
    }

    private func pageView(_ p: Page, index i: Int) -> some View {
        VStack(spacing: 14) {
            Text(p.title).font(.title.weight(.bold)).multilineTextAlignment(.center)
            TourDemo(kind: p.demo, live: page == i, reduceMotion: reduceMotion)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.top, 10)
    }
}

enum TourDemoKind { case bots, chat, approval, island, studio, summaries, connect }

/// One small, self-playing demo per page.
private struct TourDemo: View {
    var kind: TourDemoKind
    var live: Bool
    var reduceMotion: Bool

    var body: some View {
        switch kind {
        case .bots: BotsDemo(live: live)
        case .chat: ChatDemo(live: live, reduceMotion: reduceMotion)
        case .approval: ApprovalDemo(live: live, reduceMotion: reduceMotion)
        case .island: IslandDemo(live: live)
        case .studio: StudioDemo(live: live, reduceMotion: reduceMotion)
        case .summaries: SummariesDemo(live: live, reduceMotion: reduceMotion)
        case .connect: ConnectDemo()
        }
    }
}

/// A handful of bots, each its own shape and colour, each doing its own thing.
private struct BotsDemo: View {
    var live: Bool
    private let looks: [BotLookSpec] = [
        BotLookSpec(shape: "blob", eyes: "classic", hex: "#BF5AF2", finish: "glass"),
        BotLookSpec(shape: "triangle", eyes: "bold", hex: "#FF9F0A", finish: "glass"),
        BotLookSpec(shape: "hexagon", eyes: "round", hex: "#30D158", finish: "glass"),
        BotLookSpec(shape: "drop", eyes: "curious", hex: "#64D2FF", finish: "glass"),
        BotLookSpec(shape: "cloud", eyes: "wide", hex: "#FF375F", finish: "glass"),
        BotLookSpec(shape: "square", eyes: "tall", hex: "#FFD60A", finish: "glass"),
    ]
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(Array(looks.enumerated()), id: \.offset) { i, l in
                BotFaceView(spec: l, size: 72, active: live, mood: BotFaceView.Mood(profile: "tour-bot-\(i)"))
            }
        }
        .padding(.vertical, 22).padding(.horizontal, 18)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }
}

/// A chat playing out: the question pops in, the bot types, a tool card slides in and ticks
/// done, then a second line — and it starts again.
private struct ChatDemo: View {
    var live: Bool
    var reduceMotion: Bool
    @State private var showUser = false
    @State private var typing = false
    @State private var reply = ""
    @State private var showTool = false
    @State private var toolDone = false
    @State private var reply2 = ""
    private let full = "Found 4.2 GB of rotated logs older than 90 days. Clearing those and leaving today's alone."
    private let full2 = "Done — 4.2 GB freed. Want log rotation set up so it stays that way?"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showUser {
                HStack { Spacer(minLength: 50); bubble("Clean up the old logs on the server", user: true) }
                    .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
            }
            if typing || !reply.isEmpty {
                HStack(alignment: .bottom, spacing: 8) {
                    BotFaceView(spec: bot, size: 26, active: typing, mood: BotFaceView.Mood(thinking: typing && reply.isEmpty, profile: "tour-chat"))
                    bubble(reply.isEmpty ? "•••" : reply, user: false)
                    Spacer(minLength: 30)
                }
                .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
            }
            if showTool {
                HStack(spacing: 8) {
                    Image(systemName: toolDone ? "checkmark.circle.fill" : "gearshape.2").foregroundStyle(toolDone ? .green : .secondary)
                        .symbolEffect(.rotate, isActive: !toolDone && live)
                        .contentTransition(.symbolEffect(.replace))
                    Text("terminal").font(.caption.weight(.semibold))
                    Text("find /var/log -mtime +90 -delete").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if toolDone { Text("1.4s").font(.caption2).foregroundStyle(.tertiary) }
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !reply2.isEmpty {
                HStack(alignment: .bottom, spacing: 8) {
                    BotFaceView(spec: bot, size: 26, active: false, mood: BotFaceView.Mood(profile: "tour-chat2"))
                    bubble(reply2, user: false)
                    Spacer(minLength: 30)
                }
                .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .top)
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .task(id: live) {
            guard live else { return }
            while !Task.isCancelled {
                showUser = false; typing = false; reply = ""; showTool = false; toolDone = false; reply2 = ""
                if reduceMotion { showUser = true; reply = full; showTool = true; toolDone = true; reply2 = full2; return }
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { showUser = true }
                try? await Task.sleep(for: .milliseconds(900))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { typing = true }
                try? await Task.sleep(for: .milliseconds(1100))
                for ch in full { guard !Task.isCancelled else { return }; reply.append(ch); try? await Task.sleep(for: .milliseconds(20)) }
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { showTool = true }
                try? await Task.sleep(for: .milliseconds(1400))
                withAnimation(.snappy) { toolDone = true; typing = false }
                try? await Task.sleep(for: .milliseconds(600))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { reply2 = " " }
                for ch in full2 { guard !Task.isCancelled else { return }; reply2.append(ch); try? await Task.sleep(for: .milliseconds(20)) }
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) { showUser = false; typing = false; reply = ""; showTool = false; toolDone = false; reply2 = "" }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    private var bot: BotLookSpec { BotLookSpec(shape: "blob", eyes: "classic", hex: "#BF5AF2", finish: "glass") }
    private func bubble(_ t: String, user: Bool) -> some View {
        Text(t).font(.subheadline)
            .padding(.horizontal, 13).padding(.vertical, 9)
            .foregroundStyle(user ? .white : .primary)
            .background(user ? Color.vory : Color(.systemGray5), in: .rect(cornerRadius: 17))
    }
}

/// The approval card slides in, a finger taps "Once", the card turns green — and again.
private struct ApprovalDemo: View {
    var live: Bool
    var reduceMotion: Bool
    @State private var shown = false
    @State private var pressing = false
    @State private var picked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: picked ? "checkmark.shield.fill" : "exclamationmark.triangle.fill").foregroundStyle(picked ? .green : .yellow)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: !picked)
                Text(picked ? "Allowed once" : "Approval needed").font(.headline).contentTransition(.numericText())
            }
            Text("delete rotated log files older than 90 days").font(.subheadline).foregroundStyle(.secondary)
            Text("find /var/log -name '*.log.*' -mtime +90 -delete").font(.caption.monospaced()).lineLimit(1)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6), in: .rect(cornerRadius: 10))
            HStack(spacing: 8) {
                ForEach(["Once", "Session", "Always", "Deny"], id: \.self) { c in
                    Text(c).font(.subheadline.weight(.medium))
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(picked && c == "Once" ? Color.vory : Color(.systemGray5), in: .capsule)
                        .foregroundStyle(picked && c == "Once" ? .white : .primary)
                        .scaleEffect(pressing && c == "Once" ? 0.88 : 1)
                        .overlay {
                            // The tap itself: a ring that blooms out of the button.
                            if pressing && c == "Once" {
                                Circle().stroke(Color.vory, lineWidth: 2).frame(width: 30, height: 30)
                                    .scaleEffect(2.2).opacity(0)
                                    .animation(.easeOut(duration: 0.5), value: pressing)
                            }
                        }
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .offset(y: shown ? 0 : 60).opacity(shown ? 1 : 0)
        .task(id: live) {
            guard live else { return }
            while !Task.isCancelled {
                shown = false; pressing = false; picked = false
                if reduceMotion { shown = true; picked = true; return }
                try? await Task.sleep(for: .milliseconds(500))
                withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) { shown = true }
                try? await Task.sleep(for: .milliseconds(1900))
                withAnimation(.easeOut(duration: 0.12)) { pressing = true }
                try? await Task.sleep(for: .milliseconds(160))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pressing = false; picked = true }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) { shown = false }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}

/// The Dynamic Island: a compact pill with the bot working, expanding into the full card, then
/// the reply dropping in as a notification, the way it lands on the Home Screen.
private struct IslandDemo: View {
    var live: Bool
    @State private var expanded = false
    @State private var seconds = 0
    @State private var finished = false
    @State private var notified = false
    private let bot = BotLookSpec(shape: "blob", eyes: "classic", hex: "#BF5AF2", finish: "glass")

    var body: some View {
        // On a wallpaper-like panel, so the black Island reads as the Island in both appearances.
        VStack(spacing: 16) {
            // Notification, dropping from the top.
            HStack(spacing: 10) {
                BotFaceView(spec: bot, size: 36, active: false, mood: BotFaceView.Mood(profile: "tour-note"))
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text("Ada").font(.subheadline.weight(.semibold)); Spacer(); Text("now").font(.caption2).foregroundStyle(.secondary) }
                    Text("Done — 4.2 GB freed. Want me to set up log rotation?").font(.caption).lineLimit(2)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 18))
            .opacity(notified ? 1 : 0).offset(y: notified ? 0 : -40)

            // The Island.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    BotFaceView(spec: bot, size: expanded ? 34 : 24, active: live && !finished, mood: BotFaceView.Mood(profile: "tour-island"))
                    if expanded {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Ada").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            Text(finished ? "Finished" : "Writing").font(.caption2).foregroundStyle(.white.opacity(0.7))
                        }
                        .transition(.opacity)
                    }
                    Spacer(minLength: 8)
                    Text(String(format: "0:%02d", seconds)).font(.subheadline.monospacedDigit()).foregroundStyle(.white)
                    Image(systemName: finished ? "checkmark" : "ellipsis.message.fill").foregroundStyle(finished ? .green : Color(botHex: bot.hex) ?? .purple)
                        .symbolEffect(.pulse, isActive: !finished)
                }
                if expanded {
                    Text("Clean up the old logs").font(.caption.weight(.medium)).foregroundStyle(.white)
                    Text(finished ? "Turn finished" : "Clearing 34 rotated files under /var/log…").font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    HStack(spacing: 10) {
                        Label("624 tokens", systemImage: "text.alignleft").font(.caption2)
                        Text("Context").font(.caption2)
                        Capsule().fill(.white.opacity(0.25)).frame(width: 60, height: 4).overlay(alignment: .leading) { Capsule().fill(.green).frame(width: 18) }
                        Spacer()
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, expanded ? 16 : 12).padding(.vertical, expanded ? 14 : 8)
            .background(Color.black, in: .rect(cornerRadius: expanded ? 28 : 22))
            .frame(maxWidth: expanded ? 320 : 180)
        }
        .padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 22)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .top)
        .background(
            LinearGradient(colors: [Color(red: 0.30, green: 0.36, blue: 0.62), Color(red: 0.55, green: 0.32, blue: 0.55), Color(red: 0.92, green: 0.52, blue: 0.40)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 26))
        .task(id: live) {
            guard live else { return }
            while !Task.isCancelled {
                expanded = false; seconds = 0; finished = false; notified = false
                try? await Task.sleep(for: .milliseconds(700))
                for i in 1...2 { try? await Task.sleep(for: .milliseconds(600)); guard !Task.isCancelled else { return }; seconds = i }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { expanded = true }
                for i in 3...5 { try? await Task.sleep(for: .milliseconds(600)); guard !Task.isCancelled else { return }; seconds = i }
                withAnimation(.snappy) { finished = true }
                try? await Task.sleep(for: .milliseconds(700))
                withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { notified = true }
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) { notified = false; expanded = false }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}

/// The Creator Studio at work: a finger picks a body, then a colour, then eyes, and the bot
/// changes each time.
private struct StudioDemo: View {
    var live: Bool
    var reduceMotion: Bool
    @State private var shape = "blob"
    @State private var eyes = "classic"
    @State private var hex = "#7C5CFF"
    @State private var pressed: String?
    private let shapes = ["blob", "cloud", "square", "hexagon", "drop", "triangle"]
    private let eyeStyles = ["classic", "round", "wide", "tall", "curious", "tiny"]
    private let colours = ["#7C5CFF", "#0A84FF", "#FF375F", "#30D158", "#FFD60A", "#FF9F0A"]

    var body: some View {
        VStack(spacing: 16) {
            BotFaceView(spec: BotLookSpec(shape: shape, eyes: eyes, hex: hex, finish: "glass"), size: 104, active: false, mood: BotFaceView.Mood(profile: "tour-studio"))
            HStack(spacing: 10) {
                ForEach(shapes, id: \.self) { s in
                    BotFaceView(spec: BotLookSpec(shape: s, eyes: "classic", hex: hex), size: 30, active: false, drawn: true)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill).opacity(shape == s ? 1 : 0)))
                        .scaleEffect(pressed == "shape-\(s)" ? 0.85 : 1)
                }
            }
            HStack(spacing: 12) {
                ForEach(colours, id: \.self) { c in
                    Circle().fill(Color(botHex: c) ?? .gray).frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.primary.opacity(hex == c ? 0.9 : 0), lineWidth: 2).padding(-3))
                        .scaleEffect(pressed == "colour-\(c)" ? 0.8 : 1)
                }
            }
        }
        .padding(.vertical, 18).padding(.horizontal, 22)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .task(id: live) {
            guard live, !reduceMotion else { return }
            var i = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1300))
                guard !Task.isCancelled else { return }
                let step = i % 3
                if step == 0 {
                    let s = shapes[(shapes.firstIndex(of: shape)! + 1) % shapes.count]
                    withAnimation(.easeOut(duration: 0.12)) { pressed = "shape-\(s)" }
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { pressed = nil; shape = s }
                } else if step == 1 {
                    let c = colours[(colours.firstIndex(of: hex)! + 1) % colours.count]
                    withAnimation(.easeOut(duration: 0.12)) { pressed = "colour-\(c)" }
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { pressed = nil; hex = c }
                } else {
                    withAnimation(.snappy) { eyes = eyeStyles[(eyeStyles.firstIndex(of: eyes)! + 1) % eyeStyles.count] }
                }
                i += 1
            }
        }
    }
}

/// A chat row as the gateway sends it, then Apple Intelligence rewrites its title and preview in
/// place — and the switch that turns the feature on, right here.
private struct SummariesDemo: View {
    var live: Bool
    var reduceMotion: Bool
    @AppStorage(ChatSummarizer.enabledKey) private var enabled = false
    @State private var summarized = false
    @State private var thinking = false
    private let bot = BotLookSpec(shape: "hexagon", eyes: "round", hex: "#30D158", finish: "glass")

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                BotFaceView(spec: bot, size: 40, active: thinking, mood: BotFaceView.Mood(thinking: thinking, profile: "tour-sum"))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(summarized ? "Log cleanup on the web host" : "Clean up the old logs on the server and then tell me wh…")
                            .font(.body.weight(.medium)).lineLimit(1)
                            .contentTransition(.numericText())
                        if summarized { Image(systemName: "sparkles").font(.caption2).foregroundStyle(.secondary).transition(.scale.combined(with: .opacity)) }
                    }
                    Text(summarized ? "Freed 4.2 GB of rotated logs; the bot offered to set up log rotation and is waiting on a yes."
                                    : "Found 4.2 GB of rotated logs older than 90 days. Clearing those and leaving today's alone. Done — 4.2 GB freed. Want log rotation set up so it")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        .contentTransition(.numericText())
                    Text("claude-sonnet · 2 min ago").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            Toggle(isOn: $enabled) {
                HStack(spacing: 6) {
                    Text("Vory Summaries").font(.subheadline.weight(.medium))
                    Text("BETA").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.vory.opacity(0.15))).foregroundStyle(Color.vory)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            Text("You can change this later in Settings › Appearance.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
        .task(id: live) {
            guard live else { return }
            while !Task.isCancelled {
                summarized = false; thinking = false
                if reduceMotion { summarized = true; return }
                try? await Task.sleep(for: .milliseconds(1400))
                thinking = true
                try? await Task.sleep(for: .milliseconds(1300))
                withAnimation(.snappy(duration: 0.5)) { thinking = false; summarized = true }
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) { summarized = false }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }
}

/// The ways to reach a gateway, in one glance.
private struct ConnectDemo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("wifi", "Local network", "Same Wi‑Fi as the gateway machine.")
            row("point.3.connected.trianglepath.dotted", "Tailscale", "From anywhere, over your tailnet.")
            row("cloud", "Cloudflare Access", "A public hostname with a service token.")
            row("globe", "Other", "Any https address that reaches the dashboard.")
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
    private func row(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 28, height: 28).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
